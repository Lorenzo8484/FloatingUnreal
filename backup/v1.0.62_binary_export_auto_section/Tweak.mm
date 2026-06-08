#import "SDKCompat.h"
#import "FloatingMenu.h"
#import <Metal/Metal.h>
#import <os/lock.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <signal.h>
#include <unistd.h>
#include <string.h>
#include <fcntl.h>

// ── Crash diagnostics ─────────────────────────────────────────────────────────
// Pre-opened FD so signal handler (async-signal-safe) can write without ObjC.
static int gCrashLogFD  = -1;
// ── Crash flag FD ─────────────────────────────────────────────────────────────
// Written by the signal handler (async-signal-safe: only write/fsync).
// Existence of the flag file on the NEXT launch means the previous session crashed.
// lc_init detects it, resets gHooksEnabled=NO so UE4 Metal init is safe.
static int gCrashFlagFD = -1;

static void fmWriteCrashBytes(const char *s) {
    if (gCrashLogFD < 0) return;
    write(gCrashLogFD, s, strlen(s));
}

// Signal handler — only async-signal-safe calls allowed (no ObjC, no malloc).
static void fmSignalHandler(int sig, siginfo_t *info, void *uctx) {
    const char *name = sig == SIGSEGV ? "SIGSEGV" :
                       sig == SIGABRT ? "SIGABRT" :
                       sig == SIGBUS  ? "SIGBUS"  :
                       sig == SIGILL  ? "SIGILL"  : "SIGNAL";
    char buf[128];
    snprintf(buf, sizeof(buf), "\n[FM_CRASH] %s addr=%p\n", name,
             (info ? info->si_addr : (void*)0));
    fmWriteCrashBytes(buf);
    fsync(gCrashLogFD);
    // Mark crash flag so next launch resets hooks to OFF.
    if (gCrashFlagFD >= 0) {
        write(gCrashFlagFD, "1", 1);
        fsync(gCrashFlagFD);
    }
    // Reset to default and re-raise so the OS can generate a crash report.
    struct sigaction sa;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sa.sa_handler = SIG_DFL;
    sigaction(sig, &sa, NULL);
    raise(sig);
}

// ObjC uncaught-exception handler — NOT signal context, ObjC is safe here.
static void fmExceptionHandler(NSException *e) {
    NSArray<NSString*> *stack = [e callStackSymbols];
    NSString *top = stack.count > 0 ? stack[0] : @"?";
    NSString *top2 = stack.count > 1 ? stack[1] : @"?";
    NSString *top3 = stack.count > 2 ? stack[2] : @"?";
    NSString *msg = [NSString stringWithFormat:
        @"\n[FM_CRASH] NSException: %@ | %@\n  #0 %@\n  #1 %@\n  #2 %@\n",
        e.name, e.reason, top, top2, top3];
    if (gCrashLogFD >= 0) {
        const char *u = [msg UTF8String];
        write(gCrashLogFD, u, strlen(u));
        fsync(gCrashLogFD);
    }
    // Also mark crash flag (ObjC context — safe to call write).
    if (gCrashFlagFD >= 0) {
        write(gCrashFlagFD, "1", 1);
        fsync(gCrashFlagFD);
    }
}

static FloatingMenu *floatingMenu  = nil;
static BOOL          menuInstalled = NO;

// ── Patch state ───────────────────────────────────────────────────────────────

static id<MTLDevice>       hookedDevice         = nil;
static NSMutableSet       *gBuiltVariantPairs  = nil; // "fHash|vHash" — dedup in-match burst
static _Atomic(uint64_t)   gPatchBuildGen       = 0;  // increments on clear → cancels in-flight async builds
static NSMutableDictionary *capturedSources     = nil; // @(hash) → NSString (MSL source)
static NSMutableDictionary *capturedSourceNames = nil; // @(hash) → NSString (display name)
static NSMutableDictionary *capturedLibraries   = nil; // @(hash) → id<MTLLibrary>
static NSMutableDictionary *capturedOptions     = nil; // @(hash) → MTLCompileOptions
static NSMutableDictionary *colorLibraries      = nil; // @(hash) → patched color/vertex library
static NSMutableDictionary *flashLibraries      = nil; // @(hash) → yellow flash library
// pipelinePatches: NSValue(pipelinePtr) → NSMutableDictionary{@"color":ps, @"flash":ps}
static NSMutableDictionary *pipelinePatches     = nil;
static NSMutableDictionary *pipelineFragHash    = nil; // NSValue(ps) → @(fragSourceHash)
static NSMutableDictionary *pipelineVertHash    = nil; // NSValue(ps) → @(vertSourceHash)
// pipelineDescriptors: NSValue(pipelinePtr) → MTLRenderPipelineDescriptor copy
// Needed to rebuild variant pipelines when patches are toggled at runtime
static NSMutableDictionary *pipelineDescriptors  = nil;
// pipelineDescByFragHash: @(fragHash) → MTLRenderPipelineDescriptor (last seen for that frag hash)
// Persistent cache NOT cleared by burst detector — used as fallback in rebuildVariantsForHash
// when pipelineDescriptors[pk] was purged. At most ~100 entries (one per unique fragment shader).
static NSMutableDictionary *pipelineDescByFragHash = nil;
static NSMutableDictionary *pipelineGeneration   = nil; // pKey → NSNumber(generation); incremented on every new registration at that address
static NSMutableSet        *flashHashes         = nil; // @(hash) with flash ON
static NSMutableSet        *activeColorHashes   = nil; // @(hash) with color/vertex patch ON
static NSMutableSet        *gLiveActiveHashes   = nil; // @(hash) seen in setRenderPipelineState this frame
static BOOL                 flashVisible        = NO;
static NSTimer             *flashTimer          = nil;
// Burst detector: se 10+ pipeline NUOVE arrivano in 1 secondo → transizione scena
// → svuota i descriptor vecchi (rilascia MTLFunction/MTLLibrary del gioco).
static NSUInteger           gBurstCount         = 0;
static CFAbsoluteTime       gBurstWindowStart   = 0;

// Associated-object keys for tracking function → source hash
static const char kLibHashKey      = 'L'; // on id<MTLLibrary>  → NSNumber(sourceHash)
static const char kFuncHashKey     = 'F'; // on id<MTLFunction> → NSNumber(sourceHash)
static const char kReplaceFuncKey  = 'R'; // on id<MTLLibrary>  → NSString (override function name)
static const char kVertPatchKey    = 'V'; // on MTLRenderCommandEncoder → @YES when V-patch active (per-encoder, no global race)
                                           // Used when the variant lib uses a replacement shader
                                           // (e.g. const-color patch for binary IR shaders)

// ── IMP typedefs ──────────────────────────────────────────────────────────────

typedef id<MTLLibrary>              (*LibIMP)(id,SEL,NSString*,MTLCompileOptions*,NSError**);
typedef void                        (*LibAsyncIMP)(id,SEL,NSString*,MTLCompileOptions*,MTLNewLibraryCompletionHandler);
typedef id<MTLLibrary>              (*LibDataIMP)(id,SEL,dispatch_data_t,NSError**);
typedef id<MTLLibrary>              (*LibUrlIMP)(id,SEL,NSURL*,NSError**);
typedef id<MTLLibrary>              (*LibDefaultIMP)(id,SEL);
typedef id<MTLLibrary>              (*LibDefaultBundleIMP)(id,SEL,NSBundle*,NSError**);
typedef id<MTLFunction>             (*NewFuncIMP)(id,SEL,NSString*);
// Specialization-constant variants — used by R6 Mobile for fragment functions
typedef id<MTLFunction>             (*NewFuncConstIMP)(id,SEL,NSString*,MTLFunctionConstantValues*,NSError**);
typedef void                        (*NewFuncConstAsyncIMP)(id,SEL,NSString*,MTLFunctionConstantValues*,MTLNewFunctionCompletionHandler);
typedef void                        (*PipeAsyncIMP)(id,SEL,MTLRenderPipelineDescriptor*,MTLNewRenderPipelineStateCompletionHandler);
typedef id<MTLRenderPipelineState>  (*PipeIMP)(id,SEL,MTLRenderPipelineDescriptor*,NSError**);
typedef id<MTLCommandBuffer>        (*CmdBufIMP)(id,SEL);
typedef id<MTLRenderCommandEncoder> (*RenderEncIMP)(id,SEL,MTLRenderPassDescriptor*);
typedef void                        (*SetPipeIMP)(id,SEL,id<MTLRenderPipelineState>);
typedef void                        (*SetDepthIMP)(id,SEL,id<MTLDepthStencilState>);
typedef id                          (*ParallelEncIMP)(id,SEL,MTLRenderPassDescriptor*);

static LibIMP              origNewLibrary        = NULL;
static LibAsyncIMP         origNewLibraryAsync   = NULL;
static LibDataIMP          origNewLibraryData    = NULL;
static LibUrlIMP           origNewLibraryUrl     = NULL;
static LibDefaultIMP       origNewDefaultLib     = NULL;
static LibDefaultBundleIMP origNewDefaultBundleLib = NULL;
static NewFuncIMP          origNewFunction          = NULL;
static NewFuncConstIMP     origNewFunctionConst     = NULL;
static NewFuncConstAsyncIMP origNewFunctionConstAsync = NULL;
static PipeIMP      origNewPipeline     = NULL;
static PipeAsyncIMP origNewPipelineAsync = NULL;
static CmdBufIMP    origCmdBuf          = NULL;
static CmdBufIMP    origCmdBufUR        = NULL; // commandBufferWithUnretainedReferences
static RenderEncIMP origRenderEnc       = NULL;
static SetPipeIMP   origSetPipe         = NULL;
static SetDepthIMP  origSetDepth        = NULL;
static ParallelEncIMP origParallelEnc   = NULL;

// Wallhack: depth stencil state with compareFunctionAlways + no depth write
static id<MTLDepthStencilState> gWallhackDepthState = nil;
// Set to YES when the currently-bound pipeline uses a vertex patch (per render thread)
// gVertexPatchActive removed — replaced by per-encoder kVertPatchKey associated object (see hooked_setRenderPipelineState)

// ── Master hooks switch ────────────────────────────────────────────────────────
// gHooksEnabled: user-controlled (saved to NSUserDefaults). Default OFF.
//   Controls: pipeline creation hooks only (newRenderPipelineState / Async, encoder hooks).
//   UE4 games (Battle Prime etc.) crash if pipeline hooks fire during early Metal init.
//   The user must enable manually AFTER the game is fully loaded.
// gCaptureSourceLibs: always YES, never user-controlled.
//   Controls: newLibraryWithSource (MSL) hooks — capture-only, no patching.
//   UE4/MoltenVK compile hundreds of MSL shaders during match loading, BEFORE the user
//   can tap Enable. To catch this burst we hook newLibraryWithSource unconditionally.
//   Safe: Metal Inspector uses the same approach without crashing UE4 games.
// gCaptureBinaryLibs: always YES, never user-controlled.
//   Controls: newLibraryWithData / newDefaultLibrary / newLibraryWithURL hooks.
//   Binary .metallib files load at process startup (before the user can tap Enable),
//   so we must capture them unconditionally. These hooks are read-only (no patching)
//   and do not trigger GPU compilation — safe to run during any game's Metal init.
static _Atomic(BOOL) gHooksEnabled      = NO;  // user toggle — all hooks (MSL + pipeline)
static _Atomic(BOOL) gCaptureSourceLibs = NO;  // mirrors gHooksEnabled — set together
static _Atomic(BOOL) gCaptureBinaryLibs = YES; // binary metallib capture attiva — patch R/G/B via const-color override

// ── Global state lock ─────────────────────────────────────────────────────────
// ALL NSMutableDictionary / NSMutableSet accesses MUST be inside @synchronized(gHookLock).
// Metal fires library/pipeline hooks from multiple background threads concurrently;
// without this lock every dictionary mutation is a guaranteed crash.
static NSObject *gHookLock = nil;

// ── Pixel-format short name (for render-target diagnostics) ───────────────────
static NSString *fmFmtName(MTLPixelFormat f) {
    switch (f) {
        case MTLPixelFormatBGRA8Unorm:       return @"BGRA8";
        case MTLPixelFormatBGRA8Unorm_sRGB:  return @"BGRA8s";
        case MTLPixelFormatRGBA8Unorm:       return @"RGBA8";
        case MTLPixelFormatRGBA8Unorm_sRGB:  return @"RGBA8s";
        case MTLPixelFormatRGBA16Float:      return @"RGF16";
        case MTLPixelFormatRGBA32Float:      return @"RGF32";
        case MTLPixelFormatR16Float:         return @"R16F";
        case MTLPixelFormatR32Float:         return @"R32F";
        case MTLPixelFormatDepth32Float:     return @"D32F";
        case MTLPixelFormatDepth16Unorm:     return @"D16";
        case MTLPixelFormatDepth32Float_Stencil8: return @"D32S8";
        case MTLPixelFormatStencil8:         return @"S8";
        case MTLPixelFormatInvalid:          return @"none";
        default: return [NSString stringWithFormat:@"fmt%lu",(unsigned long)f];
    }
}

// ── MSL injection & diagnostics ───────────────────────────────────────────────

// Dispatch a log line to the floating menu (safe from any thread).
static void fmLog(NSString *msg) {
    dispatch_async(dispatch_get_main_queue(), ^{ if (floatingMenu) [floatingMenu addLog:msg]; });
}

// Walk backwards from end of `str`, return last identifier.
// Accepts ASCII ident chars AND any non-ASCII Unicode char that is not whitespace/punctuation.
// This handles obfuscated MSL (e.g. R6 Mobile) where variable names use Unicode code points.
static NSString *fmLastIdent(NSString *str) {
    NSInteger i = (NSInteger)str.length - 1;
    // Skip trailing whitespace
    while (i >= 0) {
        unichar c = [str characterAtIndex:i];
        if (c != ' ' && c != '\t' && c != '\n' && c != '\r') break;
        i--;
    }
    if (i < 0) return nil;
    NSInteger end = i + 1;
    // Stop characters: ASCII punctuation/operators/brackets that cannot be in an identifier
    // Everything else (ASCII ident chars + any non-ASCII) is accepted as part of the name.
    static NSCharacterSet *stopSet = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        stopSet = [NSCharacterSet characterSetWithCharactersInString:
            @" \t\n\r[](){};,.*&|^~!@#%<>+=/?\\\"'`:-"];
    });
    while (i >= 0) {
        unichar c = [str characterAtIndex:i];
        if ([stopSet characterIsMember:c]) break;
        i--;
    }
    NSInteger len = end - (i + 1);
    if (len <= 0) return nil;
    return [str substringWithRange:NSMakeRange(i + 1, len)];
}

// Search for `attr` anywhere in `src`; return the C identifier immediately preceding it.
// Tries both "[[attr" and "[[ attr" (with space) to handle Unity HLSLcc output format.
static NSString *fmMemberForAttr(NSString *src, NSString *attr) {
    // Unity MSL output uses "[[ color(" and "[[ position" (space after [[)
    NSString *attrSpaced = [attr stringByReplacingOccurrencesOfString:@"[["
                                                           withString:@"[[ "];
    for (NSString *candidate in @[attrSpaced, attr]) {
        NSRange ar = [src rangeOfString:candidate];
        if (ar.location != NSNotFound)
            return fmLastIdent([src substringToIndex:ar.location]);
    }
    return nil;
}

// Parse "program_source:LINE:COL:" from a Metal compile error string; returns -1 on failure.
static NSInteger fmParseErrLine(NSString *err) {
    NSRange r = [err rangeOfString:@"program_source:"];
    if (r.location == NSNotFound) return -1;
    NSUInteger s = r.location + r.length, e = s;
    while (e < err.length && [err characterAtIndex:e] >= '0' && [err characterAtIndex:e] <= '9') e++;
    if (e == s) return -1;
    return [[err substringWithRange:NSMakeRange(s, e - s)] integerValue];
}

// Log N lines of `src` around 1-based `lineNum` (±`ctx` lines), each line prefixed.
static void fmLogSrcCtx(NSString *src, NSInteger lineNum, NSInteger ctx) {
    NSArray *lines = [src componentsSeparatedByString:@"\n"];
    NSInteger total = (NSInteger)lines.count;
    NSInteger from  = MAX(1, lineNum - ctx);
    NSInteger to    = MIN(total, lineNum + ctx);
    fmLog([NSString stringWithFormat:@"[CTX] sorgente linee %ld–%ld (errore L%ld):", (long)from, (long)to, (long)lineNum]);
    for (NSInteger n = from; n <= to; n++) {
        NSString *mark = (n == lineNum) ? @">>>" : @"   ";
        fmLog([NSString stringWithFormat:@"%@ %3ld| %@", mark, (long)n, lines[n - 1]]);
    }
}

// Full source diagnostic: logs all lines that contain "[[" (attribute lines).
// Also reports colorMember and posMember detected, plus key presence flags.
static void fmDiagSource(NSString *src, NSString *tag) {
    if (!src) { fmLog([NSString stringWithFormat:@"[DIAG %@] source NIL", tag]); return; }

    NSString *colorMember = fmMemberForAttr(src, @"[[color(");
    NSString *posMember   = fmMemberForAttr(src, @"[[position");
    BOOL hasFrag          = [src containsString:@"fragment "];
    BOOL hasVert          = [src containsString:@"vertex "];

    fmLog([NSString stringWithFormat:
        @"[DIAG %@] len=%lu frag=%d vert=%d | colorMember=%@ | posMember=%@",
        tag, (unsigned long)src.length, hasFrag, hasVert,
        colorMember ?: @"NIL", posMember ?: @"NIL"]);

    // Log every line that contains "[[" so we can see all MSL attributes
    NSArray *srcLines = [src componentsSeparatedByString:@"\n"];
    NSMutableArray *attrLines = [NSMutableArray array];
    for (NSUInteger i = 0; i < srcLines.count; i++) {
        if ([srcLines[i] containsString:@"[["]) {
            [attrLines addObject:[NSString stringWithFormat:@"  [ATTR L%lu] %@",
                (unsigned long)(i + 1),
                [srcLines[i] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]]];
        }
    }
    if (attrLines.count == 0) {
        fmLog([NSString stringWithFormat:@"[DIAG %@] NESSUN attributo [[ trovato! Sorgente non MSL?", tag]);
        // Log first 10 non-empty lines to understand format
        NSInteger shown = 0;
        for (NSString *l in srcLines) {
            NSString *t = [l stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (t.length > 0) { fmLog([NSString stringWithFormat:@"  [SRC] %@", t]); if (++shown >= 10) break; }
        }
    } else {
        NSInteger max = MIN(25, (NSInteger)attrLines.count);
        for (NSInteger i = 0; i < max; i++) fmLog(attrLines[i]);
        if ((NSInteger)attrLines.count > max)
            fmLog([NSString stringWithFormat:@"  ... e altri %ld attr", (long)attrLines.count - max]);
    }
}

// Find body (between first `{` and matching `}`) of first function with `keyword`.
static BOOL fmFindFuncBody(NSString *src, NSString *keyword,
                           NSUInteger *outBodyStart, NSUInteger *outBodyLen) {
    NSRange kr = [src rangeOfString:keyword];
    if (kr.location == NSNotFound) return NO;
    NSRange br = [src rangeOfString:@"{" options:0
                              range:NSMakeRange(kr.location, src.length - kr.location)];
    if (br.location == NSNotFound) return NO;
    NSUInteger depth = 1, i = br.location + 1, end = NSNotFound;
    while (i < src.length && depth > 0) {
        unichar c = [src characterAtIndex:i++];
        if (c == '{') depth++;
        else if (c == '}' && --depth == 0) end = i - 1;
    }
    if (end == NSNotFound) return NO;
    *outBodyStart = br.location + 1;
    *outBodyLen   = end - br.location - 1;
    return YES;
}

// Find last "return <expr>;" in `body`; fill outExpr (range of expr) and outStmt (full stmt).
static BOOL fmLastReturn(NSString *body, NSRange *outExpr, NSRange *outStmt) {
    NSRange last = NSMakeRange(NSNotFound, 0), search = NSMakeRange(0, body.length), found;
    while ((found = [body rangeOfString:@"return " options:0 range:search]).location != NSNotFound) {
        last   = found;
        search = NSMakeRange(found.location + 1, body.length - found.location - 1);
    }
    if (last.location == NSNotFound) return NO;
    NSUInteger vs = last.location + 7;
    NSRange semi = [body rangeOfString:@";" options:0
                                 range:NSMakeRange(vs, MIN(300, body.length - vs))];
    if (semi.location == NSNotFound) return NO;
    *outExpr = NSMakeRange(vs, semi.location - vs);
    *outStmt = NSMakeRange(last.location, semi.location + 1 - last.location);
    return YES;
}

// Inject RGB color override into last return of the fragment function.
// Runs fmDiagSource first so we always see [[color( attribute search results in log.
static NSString *injectFragColor(NSString *src, float r, float g, float b) {
    // ── Diagnostic: show all [[ attribute lines and detected colorMember ──────
    NSString *colorMember = fmMemberForAttr(src, @"[[color(");
    fmLog([NSString stringWithFormat:@"[INJECT FRAG] colorMember=%@ r=%.2f g=%.2f b=%.2f",
        colorMember ?: @"NIL", r, g, b]);
    if (!colorMember)
        fmDiagSource(src, @"FRAG");  // full attr dump only when member not found

    NSUInteger bodyStart, bodyLen;
    if (!fmFindFuncBody(src, @"fragment ", &bodyStart, &bodyLen)) {
        fmLog(@"[INJECT FRAG] FAIL: 'fragment ' non trovato nel sorgente");
        return src;
    }
    NSString *body = [src substringWithRange:NSMakeRange(bodyStart, bodyLen)];

    NSRange exprR, stmtR;
    if (!fmLastReturn(body, &exprR, &stmtR)) {
        fmLog(@"[INJECT FRAG] FAIL: nessun 'return' trovato nel body");
        return src;
    }

    NSString *origExpr = [[body substringWithRange:exprR]
                          stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    fmLog([NSString stringWithFormat:@"[INJECT FRAG] return expr='%@'",
        origExpr.length > 60 ? [[origExpr substringToIndex:60] stringByAppendingString:@"…"] : origExpr]);

    // Direct in-place assignment on the existing return variable — no struct copy.
    // Works for both half4 and float4 SV_Target0 because (half) cast is explicit.
    // If colorMember not found via [[color( attribute, try common UE/ANGLE output member names
    // so we don't fall back to the broken scalar _fm_v.r path for struct return types.
    if (!colorMember) {
        NSArray *knownColorMembers = @[@"webgl_FragColor", @"webgl_fragcolor",
                                       @"SV_Target0", @"sv_target0",
                                       @"SV_Target",  @"sv_target",
                                       @"out_Color",  @"out_color",
                                       @"fragColor",  @"fragcolor"];
        for (NSString *cm in knownColorMembers) {
            // Only accept if it appears in the body (i.e. the return variable actually has it)
            if ([body containsString:cm]) { colorMember = cm; break; }
        }
        if (colorMember)
            fmLog([NSString stringWithFormat:@"[INJECT FRAG] colorMember found via name lookup: %@", colorMember]);
    }

    NSString *repl;
    if (colorMember) {
        // Direct member assignment — works for both float4 and half4 members.
        // (half)→float promotion is valid in Metal MSL.
        repl = [NSString stringWithFormat:
            @"%@.%@.r=(half)%.4ff; %@.%@.g=(half)%.4ff; %@.%@.b=(half)%.4ff; %@.%@.a=1.0h; return %@;",
            origExpr, colorMember, r,
            origExpr, colorMember, g,
            origExpr, colorMember, b,
            origExpr, colorMember,
            origExpr];
    } else {
        // Last-resort scalar path (works for shaders that return half4/float4 directly,
        // NOT for struct returns — those will fail to compile and trigger FM_CONST_FRAG).
        repl = [NSString stringWithFormat:
            @"{ auto _fm_v=(%@); _fm_v.r=(half)%.4ff; _fm_v.g=(half)%.4ff; _fm_v.b=(half)%.4ff; _fm_v.a=1.0h; return _fm_v; }",
            origExpr, r, g, b];
    }
    fmLog([NSString stringWithFormat:@"[INJECT FRAG] repl(trim)='%@'",
        repl.length > 120 ? [[repl substringToIndex:120] stringByAppendingString:@"…"] : repl]);

    NSUInteger absStart = bodyStart + stmtR.location;
    return [src stringByReplacingCharactersInRange:NSMakeRange(absStart, stmtR.length) withString:repl];
}

// Inject wallhack depth before last return of vertex function.
// Runs fmDiagSource first so we see [[position attribute search results in log.
static NSString *injectVertexDepth(NSString *src) {
    NSString *posMember = fmMemberForAttr(src, @"[[position");
    fmLog([NSString stringWithFormat:@"[INJECT VERT] posMember=%@", posMember ?: @"NIL"]);
    if (!posMember)
        fmDiagSource(src, @"VERT");  // full attr dump only when member not found

    NSUInteger bodyStart, bodyLen;
    if (!fmFindFuncBody(src, @"vertex ", &bodyStart, &bodyLen)) {
        fmLog(@"[INJECT VERT] FAIL: 'vertex ' non trovato nel sorgente");
        return src;
    }
    NSString *body = [src substringWithRange:NSMakeRange(bodyStart, bodyLen)];

    NSRange exprR, stmtR;
    if (!fmLastReturn(body, &exprR, &stmtR)) {
        fmLog(@"[INJECT VERT] FAIL: nessun 'return' nel body");
        return src;
    }

    NSString *var = [[body substringWithRange:exprR]
                     stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    fmLog([NSString stringWithFormat:@"[INJECT VERT] return var='%@' posMember=%@",
        var, posMember ?: @"fallback→position"]);
    if (!var || var.length < 1 || var.length > 60) {
        fmLog(@"[INJECT VERT] FAIL: return var non valida");
        return src;
    }

    if (!posMember) posMember = @"position"; // fallback for plain float4 returns

    NSString *inject = [NSString stringWithFormat:
        @"    %@.%@.z = %@.%@.w * 0.0001f; // FM_WALLHACK\n    ",
        var, posMember, var, posMember];
    fmLog([NSString stringWithFormat:@"[INJECT VERT] inject='%@'", inject]);

    NSUInteger absInsert = bodyStart + stmtR.location;
    return [src stringByReplacingCharactersInRange:NSMakeRange(absInsert, 0) withString:inject];
}

static NSString *buildPatchedSource(ShaderEntry *entry) {
    NSString *src = entry.source;
    BOOL s = entry.patchShadeOverride;
    switch (entry.patchFragColor) {
        case FragPatchRed:
            src = injectFragColor(src, s?entry.patchShadeR:1.0f, s?entry.patchShadeG:0.0f, s?entry.patchShadeB:0.0f); break;
        case FragPatchGreen:
            src = injectFragColor(src, s?entry.patchShadeR:0.0f, s?entry.patchShadeG:0.9f, s?entry.patchShadeB:0.2f); break;
        case FragPatchBlue:
            src = injectFragColor(src, s?entry.patchShadeR:0.2f, s?entry.patchShadeG:0.5f, s?entry.patchShadeB:1.0f); break;
        default: break;
    }
    if (entry.patchVertex) src = injectVertexDepth(src);
    return src;
}

// ── Compile helpers (call origNewLibrary directly → no recursion) ─────────────

static id<MTLLibrary> compileDirect(NSString *src, MTLCompileOptions *opts) {
    if (!hookedDevice || !src || !origNewLibrary) return nil;
    NSError *e = nil;
    id<MTLLibrary> lib = origNewLibrary(hookedDevice,
                                        @selector(newLibraryWithSource:options:error:),
                                        src, opts, &e);
    if (!lib && e) {
        NSString *fullDesc = e.localizedDescription ?: @"errore sconosciuto";
        NSString *desc = fullDesc.length > 200 ? [[fullDesc substringToIndex:200] stringByAppendingString:@"…"] : fullDesc;
        fmLog([NSString stringWithFormat:@"[COMPILE ERR] %@", desc]);
        // Log source lines around the error line for precise diagnosis
        NSInteger errLine = fmParseErrLine(fullDesc);
        if (errLine > 0) fmLogSrcCtx(src, errLine, 5);
    }
    return lib;
}


// ── Crash-surviving diagnostics (NSUserDefaults circular buffer) ─────────────
// Each fmDiag call appends to a 50-entry ring stored under "FMDiagLog" in
// NSUserDefaults. The write is synchronous + synchronize() so lines persist
// even if the process is killed before the main-queue dispatch fires.
// On next launch, fmShowPreCrashLog() reads them back into the inspector.
#define FM_DIAG_KEY  @"FMDiagLog"
#define FM_DIAG_MAX  50
static os_unfair_lock gDiagLock = OS_UNFAIR_LOCK_INIT;

static void fmDiag(NSString *msg) {
    if (!msg) return;
    NSLog(@"[FM-DIAG] %@", msg);
    // Persist to NSUserDefaults synchronously so it survives a crash.
    os_unfair_lock_lock(&gDiagLock);
    @autoreleasepool {
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        NSMutableArray *log = [[ud arrayForKey:FM_DIAG_KEY] mutableCopy]
                               ?: [NSMutableArray array];
        NSString *ts = [NSString stringWithFormat:@"%.3f", CACurrentMediaTime()];
        [log addObject:[NSString stringWithFormat:@"[%@] %@", ts, msg]];
        while (log.count > FM_DIAG_MAX) [log removeObjectAtIndex:0];
        [ud setObject:log forKey:FM_DIAG_KEY];
        [ud synchronize];
    }
    os_unfair_lock_unlock(&gDiagLock);
    // Also push to the live UI panel (may not fire before crash, that's OK).
    dispatch_async(dispatch_get_main_queue(), ^{ if (floatingMenu) [floatingMenu addLog:msg]; });
}

// Call once at UI start — shows pre-crash lines saved in previous session.
static void fmShowPreCrashLog(void) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSArray *saved = [ud arrayForKey:FM_DIAG_KEY];
    if (!saved.count) return;
    // Display all saved lines with [PRE-CRASH] prefix, then clear.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!floatingMenu) return;
        [floatingMenu addLog:@"━━━ PRE-CRASH LOG (sessione precedente) ━━━"];
        for (NSString *line in saved)
            [floatingMenu addLog:[NSString stringWithFormat:@"[PRE] %@", line]];
        [floatingMenu addLog:@"━━━ FINE PRE-CRASH LOG ━━━"];
    });
    // Clear so we don't show stale lines on a clean launch.
    [ud removeObjectForKey:FM_DIAG_KEY];
    [ud synchronize];
}

// Forward declaration — defined later, after the pipeline-state hook helpers
static id<MTLRenderPipelineState> buildVariantPipeline(id device,
                                                        MTLRenderPipelineDescriptor *base,
                                                        id<MTLLibrary> vLib,
                                                        id<MTLLibrary> fLib);
typedef void (^FMPipelineCompletion)(id<MTLRenderPipelineState> _Nullable ps);
static void buildVariantPipelineAsync(id device,
                                       MTLRenderPipelineDescriptor *base,
                                       id<MTLLibrary> vLib,
                                       id<MTLLibrary> fLib,
                                       FMPipelineCompletion completion);

// ── Rebuild all variant pipelines that reference a given source hash ──────────
// Called after colorLibraries/flashLibraries or activeColorHashes/flashHashes change
// so that already-created pipelines receive the patch immediately (real-time).

static void rebuildVariantsForHash(NSNumber *hash) {
    // Snapshot all pipeline keys under lock, then build GPU variants outside
    NSMutableSet *pipeKeys = [NSMutableSet set];
    NSMutableDictionary *snapDesc    = [NSMutableDictionary dictionary];
    NSMutableDictionary *snapFH      = [NSMutableDictionary dictionary];
    NSMutableDictionary *snapVH      = [NSMutableDictionary dictionary];
    NSMutableDictionary *snapVariants = [NSMutableDictionary dictionary];
    NSMutableDictionary *snapColorLibV = [NSMutableDictionary dictionary];
    NSMutableDictionary *snapColorLibF = [NSMutableDictionary dictionary];
    NSMutableDictionary *snapFlashLib  = [NSMutableDictionary dictionary];
    NSMutableSet *snapColorHashes = [NSMutableSet set];
    NSMutableSet *snapFlashHashes = [NSMutableSet set];

    NSMutableDictionary *snapGen = [NSMutableDictionary dictionary]; // pKey → generation at snapshot time
    fmDiag([NSString stringWithFormat:@"[E] rebuildVariantsForHash start hash=%04lx", hash.unsignedIntegerValue & 0xFFFF]);
    @synchronized(gHookLock) {
        [pipelineFragHash enumerateKeysAndObjectsUsingBlock:^(NSValue *pk, NSNumber *fh, BOOL *_) {
            if ([fh isEqualToNumber:hash]) [pipeKeys addObject:pk];
        }];
        [pipelineVertHash enumerateKeysAndObjectsUsingBlock:^(NSValue *pk, NSNumber *vh, BOOL *_) {
            if ([vh isEqualToNumber:hash]) [pipeKeys addObject:pk];
        }];
        for (NSValue *pk in pipeKeys) {
            if (pipelineDescriptors[pk]) snapDesc[pk]    = pipelineDescriptors[pk];
            if (pipelineFragHash[pk])    snapFH[pk]      = pipelineFragHash[pk];
            if (pipelineVertHash[pk])    snapVH[pk]      = pipelineVertHash[pk];
            if (pipelinePatches[pk])     snapVariants[pk] = [pipelinePatches[pk] mutableCopy];
            // Snapshot generation: if it changes by write-time, the address was reused → skip
            snapGen[pk] = pipelineGeneration[pk] ?: @0;
            // Fallback: if pipelineDescriptors[pk] was purged by burst detector, try per-frag-hash cache
            if (!snapDesc[pk]) {
                NSNumber *fh = pipelineFragHash[pk];
                if (fh && pipelineDescByFragHash[fh]) snapDesc[pk] = pipelineDescByFragHash[fh];
            }
        }
        [snapColorHashes unionSet:activeColorHashes];
        [snapFlashHashes unionSet:flashHashes];
        [colorLibraries enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *_) {
            snapColorLibV[k] = v; snapColorLibF[k] = v;
        }];
        [flashLibraries enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *_) {
            snapFlashLib[k] = v;
        }];
    }

    fmDiag([NSString stringWithFormat:@"[E2] snapshot done pipeKeys=%lu colorLibs=%lu flashLibs=%lu", (unsigned long)pipeKeys.count, (unsigned long)snapColorLibF.count, (unsigned long)snapFlashLib.count]);
    __block NSInteger colorBuilt = 0, flashBuilt = 0, noDesc = 0;
    NSMutableDictionary *newPatches = [NSMutableDictionary dictionary];
    NSMutableSet *seenFmts = [NSMutableSet set];
    // Use dispatch_group so we can wait for all async Metal compiles before
    // writing results back under gHookLock.
    dispatch_group_t buildGroup = dispatch_group_create();
    NSObject *patchesLock = [[NSObject alloc] init]; // serialises newPatches writes

    for (NSValue *pk in pipeKeys) {
        MTLRenderPipelineDescriptor *desc = snapDesc[pk];
        if (!desc) { noDesc++;
            fmDiag([NSString stringWithFormat:@"[F] pk=%p NO DESC skip", pk.pointerValue]);
            continue; }
        MTLPixelFormat pf = desc.colorAttachments[0].pixelFormat;
        [seenFmts addObject:fmFmtName(pf)];

        NSNumber *fh = snapFH[pk];
        NSNumber *vh = snapVH[pk];
        NSMutableDictionary *existingVars = snapVariants[pk] ?: [NSMutableDictionary dictionary];

        BOOL colorActive = (fh && [snapColorHashes containsObject:fh]) ||
                           (vh && [snapColorHashes containsObject:vh]);
        BOOL flashActive = fh && [snapFlashHashes containsObject:fh];
        fmDiag([NSString stringWithFormat:@"[F2] pk=%p fmt=%@ colorActive=%d cvLib=%s cfLib=%s flashActive=%d",
            pk.pointerValue, fmFmtName(pf),
            (int)colorActive,
            (vh && snapColorLibV[vh]) ? "OK" : "nil",
            (fh && snapColorLibF[fh]) ? "OK" : "nil",
            (int)flashActive]);

        // Prepare a mutable variants dict that will be populated by async completions
        NSValue *pkCap = pk;
        NSNumber *fhCap = fh, *vhCap = vh;

        // Always start with any already-built variants; remove deactivated ones
        NSMutableDictionary *pendingVars = [existingVars mutableCopy];
        if (!colorActive) [pendingVars removeObjectForKey:@"color"];
        if (!flashActive) [pendingVars removeObjectForKey:@"flash"];

        if (colorActive) {
            id<MTLLibrary> cvLib = vh ? snapColorLibV[vh] : nil;
            id<MTLLibrary> cfLib = fh ? snapColorLibF[fh] : nil;
            // Binary metallib: vHash==fHash, colorLib is an fmColorPatch *fragment* lib.
            // Never pass it as vertex lib — keep the original binary vertex function.
            if (cvLib) {
                NSString *vOvr = objc_getAssociatedObject(cvLib, &kReplaceFuncKey);
                if ([vOvr isEqualToString:@"fmColorPatch"]) cvLib = nil;
            }
            if (cvLib || cfLib) {
                fmDiag([NSString stringWithFormat:@"[G] async color enter pk=%p cvLib=%s cfLib=%s desc.vFn=%@ desc.fFn=%@",
                    pkCap.pointerValue,
                    cvLib ? "OK" : "nil", cfLib ? "OK" : "nil",
                    desc.vertexFunction ? desc.vertexFunction.name : @"nil",
                    desc.fragmentFunction ? desc.fragmentFunction.name : @"nil"]);
                dispatch_group_enter(buildGroup);
                buildVariantPipelineAsync(hookedDevice, desc, cvLib, cfLib, ^(id<MTLRenderPipelineState> cp) {
                    fmDiag([NSString stringWithFormat:@"[H] color done pk=%p ps=%s", pkCap.pointerValue, cp ? "OK" : "nil"]);
                    if (cp) {
                        @synchronized(patchesLock) {
                            NSMutableDictionary *pv = newPatches[pkCap] ?: [NSMutableDictionary dictionary];
                            [pv addEntriesFromDictionary:pendingVars];
                            pv[@"color"] = cp;
                            newPatches[pkCap] = pv;
                            colorBuilt++;
                        }
                    }
                    dispatch_group_leave(buildGroup);
                });
            }
        }
        if (flashActive) {
            id<MTLLibrary> flLib = snapFlashLib[fh];
            if (flLib) {
                dispatch_group_enter(buildGroup);
                buildVariantPipelineAsync(hookedDevice, desc, nil, flLib, ^(id<MTLRenderPipelineState> fp) {
                    if (fp) {
                        @synchronized(patchesLock) {
                            NSMutableDictionary *pv = newPatches[pkCap] ?: [NSMutableDictionary dictionary];
                            [pv addEntriesFromDictionary:pendingVars];
                            pv[@"flash"] = fp;
                            newPatches[pkCap] = pv;
                            flashBuilt++;
                        }
                    }
                    dispatch_group_leave(buildGroup);
                });
            }
        }
        // If only deactivating (no active libs), still record the cleared entry
        if (!colorActive && !flashActive && pendingVars.count == 0 && existingVars.count > 0) {
            // signal removal: write empty dict (handled below when count==0)
            @synchronized(patchesLock) { newPatches[pk] = [NSMutableDictionary dictionary]; }
        }
    }
    // Wait for all async Metal compiles — this blocks the background utility queue,
    // not the game's render thread.
    // FULLY ASYNC: never block any thread. Write back in dispatch_group_notify
    // so Metal's completion handler can fire on any queue without deadlock.
    // (The previous dispatch_group_wait could deadlock when Metal's completion
    //  ran on the same utility queue we were blocking → crash via watchdog.)
    NSMutableSet  *pipeKeysCap  = [pipeKeys mutableCopy];
    NSDictionary  *snapGenCap   = [snapGen copy];
    NSNumber      *hashCap      = hash;
    dispatch_group_notify(buildGroup,
        dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{

        @synchronized(gHookLock) {
            for (NSValue *pk in newPatches) {
                if (![pipelineGeneration[pk] isEqual:snapGenCap[pk]]) continue; // address reused
                if (((NSDictionary *)newPatches[pk]).count > 0) {
                    pipelinePatches[pk] = newPatches[pk];
                } else {
                    [pipelinePatches removeObjectForKey:pk]; // deactivated
                }
                // NOTE: do NOT remove pipelineDescriptors[pk] here — the descriptor must
                // stay so that subsequent toggle-on / color-change calls can rebuild.
                // Anti-OOM is handled by the burst+global caps in hooked_newRenderPipelineStateAsync.
            }
            // Remove patches for pKeys that had no build (fully deactivated, no libs)
            for (NSValue *pk in pipeKeysCap) {
                if (![pipelineGeneration[pk] isEqual:snapGenCap[pk]]) continue;
                if (!newPatches[pk]) [pipelinePatches removeObjectForKey:pk];
            }
        }
        NSString *fmtsStr = seenFmts.count ? [seenFmts.allObjects componentsJoinedByString:@","] : @"?";
        NSString *msg = [NSString stringWithFormat:
            @"[REBUILD â] hash=%04lx pipe:%lu color:%ld flash:%ld noDesc:%ld fmt=%@",
            (unsigned long)(hashCap.unsignedIntegerValue & 0xFFFF),
            (unsigned long)pipeKeysCap.count, colorBuilt, flashBuilt, noDesc, fmtsStr];
        dispatch_async(dispatch_get_main_queue(), ^{ if (floatingMenu) [floatingMenu addLog:msg]; });
    });
}

// ── Update patches for entry (called from UI on background queue) ─────────────

static void applyPatchesForEntry(ShaderEntry *entry, MTLCompileOptions *opts) {
    NSNumber *hashKey = @(entry.sourceHash);
    BOOL hasColor = (entry.patchFragColor != FragPatchNone) || entry.patchVertex;
    BOOL hasFlash = entry.patchFlash;
    fmDiag([NSString stringWithFormat:
        @"[A] applyPatches hash=%04lx name=%@ hasColor=%d vertex=%d fragCol=%ld hasFlash=%d srcLen=%lu",
        hashKey.unsignedIntegerValue & 0xFFFF,
        entry.name ?: @"nil",
        (int)hasColor, (int)entry.patchVertex, (long)entry.patchFragColor, (int)hasFlash,
        (unsigned long)entry.source.length]);

    NSString *colorPatchName = (entry.patchFragColor == FragPatchRed)   ? @"R" :
                               (entry.patchFragColor == FragPatchGreen) ? @"G" :
                               (entry.patchFragColor == FragPatchBlue)  ? @"B" :
                               entry.patchVertex                        ? @"V" : @"OFF";

    // Use original compile options so preprocessor macros/language version match
    MTLCompileOptions *origOpts = capturedOptions[hashKey] ?: opts;

    // ── Helper: compile a const-color MSL fragment replacement for binary IR shaders ──
    // Called when the MSL inject fails (source unchanged = binary IR / non-MSL).
    // The replacement function "fmColorPatch" takes only [[position]] (no stage_in),
    // which is compatible with any vertex shader output.
    #define FM_CONST_FRAG(r,g,b,fnName) (^id<MTLLibrary>() { \
        NSString *_s = [NSString stringWithFormat: \
            @"#include <metal_stdlib>\nusing namespace metal;\n" \
            "fragment half4 " fnName "(float4 pos [[position]]) {\n" \
            "    return half4((half)%.4ff,(half)%.4ff,(half)%.4ff,1.0h);\n}\n", r, g, b]; \
        id<MTLLibrary> _l = compileDirect(_s, nil); \
        if (_l) objc_setAssociatedObject(_l, &kReplaceFuncKey, @(fnName), \
                                          OBJC_ASSOCIATION_RETAIN_NONATOMIC); \
        return _l; \
    })()

    // ---- color / vertex ----
    if (hasColor) {
        id<MTLLibrary> lib = nil;

        if (entry.patchFragColor != FragPatchNone) {
            // Fragment color patch: always use fmColorPatch (const-color, no stage_in).
            // Injecting into the game's MSL and building a mixed-lib pipeline causes the
            // Metal GPU compiler to crash regardless of sync vs async. fmColorPatch is
            // a standalone fragment that takes only [[position]] — Metal always accepts it
            // with any vertex function, and it already works for all binary-IR shaders.
            float r=0,g=0,b=0;
            if (entry.patchShadeOverride) {
                r = entry.patchShadeR; g = entry.patchShadeG; b = entry.patchShadeB;
            } else if (entry.patchFragColor==FragPatchRed)   { r=1.0f; }
            else if   (entry.patchFragColor==FragPatchGreen) { g=0.9f; b=0.2f; }
            else if   (entry.patchFragColor==FragPatchBlue)  { r=0.2f; g=0.5f; b=1.0f; }
            fmDiag([NSString stringWithFormat:@"[B] fmColorPatch build hash=%04lx color=%@",
                hashKey.unsignedIntegerValue & 0xFFFF, colorPatchName]);
            lib = FM_CONST_FRAG(r, g, b, "fmColorPatch");
            NSString *status = lib ? @"OK ✓" : @"FAIL ✗";
            NSString *logMsg = [NSString stringWithFormat:@"[COMPILE] %@ color=%@ → %@",
                entry.name, colorPatchName, status];
            dispatch_async(dispatch_get_main_queue(), ^{ if (floatingMenu) [floatingMenu addLog:logMsg]; });

        } else if (entry.patchVertex) {
            // Vertex-only patch: compile the depth-inject source for reference,
            // but do NOT store in colorLibraries (no pipeline variant built).
            // The depth-override is applied via hooked_setDepthStencilState when
            // activeColorHashes contains this hash (kVertPatchKey path).
            NSString *src = buildPatchedSource(entry);
            BOOL injectWorked = ![src isEqualToString:entry.source];
            if (injectWorked) {
                fmDiag([NSString stringWithFormat:@"[B] compileDirect MSL inject src.len=%lu", (unsigned long)src.length]);
                id<MTLLibrary> vtxLib = compileDirect(src, origOpts);
                fmDiag([NSString stringWithFormat:@"[C] compileDirect done lib=%s", vtxLib ? "OK" : "nil"]);
                if (vtxLib) {
                    NSString *logMsg = [NSString stringWithFormat:@"[COMPILE] %@ color=V → OK ✓", entry.name];
                    dispatch_async(dispatch_get_main_queue(), ^{ if (floatingMenu) [floatingMenu addLog:logMsg]; });
                }
            } else {
                fmDiag([NSString stringWithFormat:@"[B3] vertex patch binary IR hash=%04lx", hashKey.unsignedIntegerValue & 0xFFFF]);
                fmLog([NSString stringWithFormat:@"[PATCH-V] %@ depth-override ON (binary IR)", entry.name]);
            }
            // Activate depth-override path only (no lib stored, no pipeline variant)
            @synchronized(gHookLock) { [activeColorHashes addObject:hashKey]; }
        }

        if (lib) {
            objc_setAssociatedObject(lib, &kLibHashKey, hashKey, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            @synchronized(gHookLock) {
                // Vertex-only patch (no fragment color): do NOT store in colorLibraries.
                // Storing a source-compiled vertex lib causes buildVariantPipelineAsync to
                // link it with the game's binary-AIR fragment function → Metal crash.
                // The depth-override effect is handled entirely by hooked_setDepthStencilState
                // via activeColorHashes + kVertPatchKey — no pipeline variant needed.
                if (entry.patchFragColor != FragPatchNone) {
                    colorLibraries[hashKey] = lib;
                }
                [activeColorHashes addObject:hashKey];
            }
        }
    } else {
        @synchronized(gHookLock) {
            [activeColorHashes removeObject:hashKey];
            [colorLibraries removeObjectForKey:hashKey];
        }
        NSString *logMsg = [NSString stringWithFormat:@"[PATCH OFF] %@ color rimosso", entry.name];
        dispatch_async(dispatch_get_main_queue(), ^{ if (floatingMenu) [floatingMenu addLog:logMsg]; });
    }

    // ---- flash ----
    if (hasFlash) {
        // Flash patch: always use fmFlashPatch (const-color yellow, no stage_in).
        // Same reasoning as fragment color: injecting into the game's MSL and building
        // a mixed-lib pipeline crashes the Metal GPU compiler. fmFlashPatch is a
        // standalone yellow fragment with only [[position]] — safe with any vertex shader.
        id<MTLLibrary> flib = FM_CONST_FRAG(1.0f, 0.88f, 0.0f, "fmFlashPatch");
        NSString *fStatus = flib ? @"OK ✓" : @"FAIL ✗";
        NSString *fMsg = [NSString stringWithFormat:@"[COMPILE] %@ flash → %@", entry.name, fStatus];
        dispatch_async(dispatch_get_main_queue(), ^{ if (floatingMenu) [floatingMenu addLog:fMsg]; });
        if (flib) {
            objc_setAssociatedObject(flib, &kLibHashKey, hashKey, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            @synchronized(gHookLock) {
                flashLibraries[hashKey] = flib;
                [flashHashes addObject:hashKey];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!flashTimer || !flashTimer.isValid) {
                flashTimer = [NSTimer scheduledTimerWithTimeInterval:0.45
                                                             repeats:YES
                                                               block:^(NSTimer *t) {
                    flashVisible = !flashVisible;
                }];
            }
        });
    } else {
        BOOL shouldStopTimer = NO;
        @synchronized(gHookLock) {
            [flashHashes removeObject:hashKey];
            [flashLibraries removeObjectForKey:hashKey];
            shouldStopTimer = (flashHashes.count == 0);
        }
        if (shouldStopTimer) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (flashTimer.isValid) { [flashTimer invalidate]; flashTimer = nil; flashVisible = NO; }
            });
        }
    }

    // Rebuild all existing pipelines that reference this shader — real-time effect
    fmDiag([NSString stringWithFormat:@"[D] pre-rebuild hash=%04lx colorLibs=%lu flashLibs=%lu",
        hashKey.unsignedIntegerValue & 0xFFFF,
        (unsigned long)colorLibraries.count,
        (unsigned long)flashLibraries.count]);
    @synchronized(gBuiltVariantPairs) { [gBuiltVariantPairs removeAllObjects]; }
    fmDiag(@"[D2] gBuiltVariantPairs cleared");
    rebuildVariantsForHash(hashKey);
    fmDiag([NSString stringWithFormat:@"[D3] rebuildVariantsForHash returned hash=%04lx", hashKey.unsignedIntegerValue & 0xFFFF]);
}

// ── Hook: newFunctionWithName: (tags each MTLFunction with source hash) ────────

// ── Late-tag helper ──────────────────────────────────────────────────────────
// Called when newFunctionWithName: fires on a library that wasn't caught by any
// library-creation hook (e.g. loaded from URL or created before injection).
// Assigns a stable hash from functionNames (same algorithm as newLibraryWithData:)
// and registers the library so patches and pipeline tracking work normally.
static NSNumber *lateTagLibrary(id<MTLLibrary> lib) {
    NSArray<NSString *> *names = [lib functionNames];
    if (names.count == 0) return nil;

    // ── Non-destructive: if the library was already tagged by a capture hook
    // (hooked_newLibraryWithData/URL/Source), reuse that hash.
    // Overwriting kLibHashKey here would cause pipelineFragHash to store a
    // DIFFERENT hash than e.sourceHash, breaking the LIVE filter.
    NSNumber *existingTag = objc_getAssociatedObject(lib, &kLibHashKey);
    if (existingTag) {
        @synchronized(gHookLock) {
            if (!capturedSources[existingTag]) {
                // Library was tagged but never captured in the UI — add it now.
                NSMutableString *src = [NSMutableString string];
                [src appendString:@"// ⚠️  LIBRERIA NON-MSL (rilevata via hook funzione)\n"];
                [src appendString:@"// Le patch R/G/B/⚡ usano const-color shader (fmColorPatch).\n"];
                [src appendString:@"// Il pulsante V usa depth stencil override.\n//\n"];
                [src appendString:@"// Funzioni:\n"];
                for (NSString *fn in names) [src appendFormat:@"//   %@\n", fn];
                capturedSources[existingTag] = src;
                NSString *srcCopy  = [src copy];
                NSString *dispName = names.firstObject ?: @"unknown";
                fmLog([NSString stringWithFormat:@"[LIB LATE TAG REUSE] hash=%04lx fns=%@",
                    existingTag.unsignedIntegerValue & 0xFFFF, names]);
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (floatingMenu) [floatingMenu captureShaderWithName:dispName
                        source:srcCopy error:nil libHash:existingTag.unsignedIntegerValue];
                });
            }
        }
        return existingTag;
    }

    NSUInteger h = names.count * 31;
    NSUInteger max = MIN(8, names.count);
    for (NSUInteger i = 0; i < max; i++) h ^= ([names[i] hash] >> i);
    NSNumber *hKey = @(h);
    // Tag the library so future functions from it are also tagged
    objc_setAssociatedObject(lib, &kLibHashKey, hKey, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // Register in captured maps if not already present — lock required (called from Metal threads)
    BOOL isNew = NO;
    NSString *srcCopy = nil;
    NSString *dispName = nil;
    @synchronized(gHookLock) {
        if (!capturedSources[hKey]) { // v1.0.35: guard on sources not capturedLibraries
            NSMutableString *src = [NSMutableString string];
            [src appendString:@"// ⚠️  LIBRERIA NON-MSL (rilevata via hook funzione)\n"];
            [src appendString:@"// Le patch R/G/B/⚡ usano const-color shader (fmColorPatch).\n"];
            [src appendString:@"// Il pulsante V usa depth stencil override.\n//\n"];
            [src appendString:@"// Funzioni:\n"];
            for (NSString *fn in names) [src appendFormat:@"//   %@\n", fn];
            capturedSources[hKey] = src;
            isNew = YES;
            srcCopy  = [src copy];
            dispName = names.firstObject ?: @"unknown";
        }
    }
    if (isNew) {
        fmLog([NSString stringWithFormat:@"[LIB LATE TAG] hash=%04lx fns=%@", h & 0xFFFF, names]);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (floatingMenu) [floatingMenu captureShaderWithName:dispName source:srcCopy error:nil libHash:hKey.unsignedIntegerValue];
        });
    }
    return hKey;
}

static id<MTLFunction> hooked_newFunctionWithName(id self, SEL _cmd, NSString *name) {
    if (!gHooksEnabled) return origNewFunction(self, _cmd, name);
    id<MTLFunction> fn = origNewFunction(self, _cmd, name);
    if (fn) {
        NSNumber *hash = objc_getAssociatedObject(self, &kLibHashKey);
        // ── Late tag: library was created via unhoooked path (URL, early init, etc.) ──
        if (!hash) hash = lateTagLibrary((id<MTLLibrary>)self);
        if (hash) {
            objc_setAssociatedObject(fn, &kFuncHashKey, hash,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            static dispatch_once_t logFnOnce;
            static NSMutableSet *loggedFnPairs = nil;
            dispatch_once(&logFnOnce, ^{ loggedFnPairs = [[NSMutableSet alloc] init]; });
            NSString *fnKey = [NSString stringWithFormat:@"%04lx|%@",
                hash.unsignedIntegerValue & 0xFFFF, name];
            BOOL isNewFn = NO;
            @synchronized(loggedFnPairs) {
                if (![loggedFnPairs containsObject:fnKey]) {
                    [loggedFnPairs addObject:fnKey];
                    isNewFn = YES;
                }
            }
            if (isNewFn) fmLog([NSString stringWithFormat:@"[FN TAG] hash=%04lx name='%@'",
                hash.unsignedIntegerValue & 0xFFFF, name]);
        }
    }
    return fn;
}

// ── Hook: newFunctionWithName:constantValues:error: (specialization constants) ─
// R6 Mobile uses this to create fragment functions with shader constants.
// We tag the result with the library's hash — same logic as plain newFunctionWithName:.

static id<MTLFunction> hooked_newFunctionWithNameConst(id self, SEL _cmd,
                                                        NSString *name,
                                                        MTLFunctionConstantValues *cv,
                                                        NSError **error) {
    if (!gHooksEnabled) return origNewFunctionConst(self, _cmd, name, cv, error);
    id<MTLFunction> fn = origNewFunctionConst(self, _cmd, name, cv, error);
    if (fn) {
        NSNumber *hash = objc_getAssociatedObject(self, &kLibHashKey);
        if (!hash) hash = lateTagLibrary((id<MTLLibrary>)self);
        if (hash) {
            objc_setAssociatedObject(fn, &kFuncHashKey, hash,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            static dispatch_once_t logConstFnOnce;
            static NSMutableSet *loggedConstFnPairs = nil;
            dispatch_once(&logConstFnOnce, ^{ loggedConstFnPairs = [[NSMutableSet alloc] init]; });
            NSString *fnKey = [NSString stringWithFormat:@"%04lx|%@",
                hash.unsignedIntegerValue & 0xFFFF, name];
            BOOL isNewConst = NO;
            @synchronized(loggedConstFnPairs) {
                if (![loggedConstFnPairs containsObject:fnKey]) {
                    [loggedConstFnPairs addObject:fnKey];
                    isNewConst = YES;
                }
            }
            if (isNewConst) fmLog([NSString stringWithFormat:@"[FN TAG CONST] hash=%04lx name='%@'",
                hash.unsignedIntegerValue & 0xFFFF, name]);
        }
    }
    return fn;
}

// ── Hook: newFunctionWithName:constantValues:completionHandler: (async) ─────────
static void hooked_newFunctionWithNameConstAsync(id self, SEL _cmd,
                                                   NSString *name,
                                                   MTLFunctionConstantValues *cv,
                                                   MTLNewFunctionCompletionHandler handler) {
    if (!gHooksEnabled) { origNewFunctionConstAsync(self, _cmd, name, cv, handler); return; }
    MTLNewFunctionCompletionHandler wrapped = ^(id<MTLFunction> fn, NSError *err) {
        if (fn) {
            NSNumber *hash = objc_getAssociatedObject(self, &kLibHashKey);
            if (!hash) hash = lateTagLibrary((id<MTLLibrary>)self);
            if (hash) {
                objc_setAssociatedObject(fn, &kFuncHashKey, hash,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                fmLog([NSString stringWithFormat:@"[FN TAG CONST ASYNC] hash=%04lx name='%@'",
                    hash.unsignedIntegerValue & 0xFFFF, name]);
            }
        }
        if (handler) handler(fn, err);
    };
    origNewFunctionConstAsync(self, _cmd, name, cv, wrapped);
}

// ── Helper: install const-function hooks on a library class (once) ────────────
// Called from every library-creation hook so we cover all paths R6 may take.
static void hookFuncConstMethods(id<MTLLibrary> lib) {
    // v1.0.40: dispatch to MAIN THREAD — method_setImplementation from Metal threads crashes ObjC runtime.
    Class cls = object_getClass(lib);
    static dispatch_once_t constHookOnce;
    dispatch_async(dispatch_get_main_queue(), ^{
        dispatch_once(&constHookOnce, ^{
            // sync
            {
                Method m = class_getInstanceMethod(cls,
                    @selector(newFunctionWithName:constantValues:error:));
                if (m && (!origNewFunctionConst ||
                          method_getImplementation(m) != (IMP)hooked_newFunctionWithNameConst)) {
                    origNewFunctionConst = (NewFuncConstIMP)method_getImplementation(m);
                    method_setImplementation(m, (IMP)hooked_newFunctionWithNameConst);
                }
            }
            // async
            {
                Method m = class_getInstanceMethod(cls,
                    @selector(newFunctionWithName:constantValues:completionHandler:));
                if (m && (!origNewFunctionConstAsync ||
                          method_getImplementation(m) != (IMP)hooked_newFunctionWithNameConstAsync)) {
                    origNewFunctionConstAsync = (NewFuncConstAsyncIMP)method_getImplementation(m);
                    method_setImplementation(m, (IMP)hooked_newFunctionWithNameConstAsync);
                }
            }
        });
    });
}

// Forward declaration (defined later, used in hooked_renderCommandEncoder)
static void hookEncClass(Class cls);

// ── Hook: setDepthStencilState: (wallhack — bypass depth test) ───────────────

static void hooked_setDepthStencilState(id self, SEL _cmd, id<MTLDepthStencilState> state) {
    if (!gHooksEnabled) { origSetDepth(self, _cmd, state); return; }
    // Per-encoder V-patch flag (set in hooked_setRenderPipelineState on same encoder object).
    // Using per-encoder associated object avoids the global-BOOL race with parallel command encoders.
    BOOL vPatch = [objc_getAssociatedObject(self, &kVertPatchKey) boolValue];
    if (vPatch && gWallhackDepthState) {
        static NSTimeInterval lastDepthLog = 0;
        NSTimeInterval now = CACurrentMediaTime();
        if (now - lastDepthLog > 2.0) {
            lastDepthLog = now;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (floatingMenu) [floatingMenu addLog:@"[DEPTH ✓] wallhack depth override attivo"];
            });
        }
        origSetDepth(self, _cmd, gWallhackDepthState);
        return;
    }
    if (vPatch && !gWallhackDepthState) {
        static BOOL nilLogged = NO;
        if (!nilLogged) { nilLogged = YES;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (floatingMenu) [floatingMenu addLog:@"[DEPTH ✗] gWallhackDepthState NIL — wallhack non attivo"];
            });
        }
    }
    origSetDepth(self, _cmd, state);
}

// ── Hook: setRenderPipelineState: ─────────────────────────────────────────────

// Throttle: log once per second when patches are actively swapping at draw time
static NSTimeInterval gLastSwapLogTime = 0;

static void hooked_setRenderPipelineState(id self, SEL _cmd,
                                           id<MTLRenderPipelineState> state) {
    if (!gHooksEnabled || !state) { origSetPipe(self, _cmd, state); return; }
    @autoreleasepool {
    // RESET per-encoder V-patch flag first — clears previous draw call's state on THIS encoder.
    objc_setAssociatedObject(self, &kVertPatchKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    id<MTLRenderPipelineState> toUse = state;
    NSString *swapLogMsg = nil;

    // All dictionary reads under lock: setRenderPipelineState is called per draw call
    // from the render thread — must not race with library/pipeline hook writes.
    @synchronized(gHookLock) {
        NSValue *key = [NSValue valueWithPointer:(__bridge void*)state];

        // Track live-active hashes for the LIVE filter in ShaderPage.
        NSNumber *fH = pipelineFragHash[key];
        NSNumber *vH = pipelineVertHash[key];
        if (fH) [gLiveActiveHashes addObject:fH];
        if (vH) [gLiveActiveHashes addObject:vH];

        // BUG FIX: check BOTH vertex AND fragment hash — the V-patch hash may be either one.
        // (Binary metallib libraries produce a single hash used as both lib hash and function hash;
        //  depending on which side the pipeline lookup found first, it may be stored as frag or vert.)
        NSNumber *vHashEarly = pipelineVertHash[key];
        NSNumber *fHashEarly = pipelineFragHash[key];
        if ((vHashEarly && [activeColorHashes containsObject:vHashEarly]) ||
            (fHashEarly && [activeColorHashes containsObject:fHashEarly])) {
            objc_setAssociatedObject(self, &kVertPatchKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }

        NSDictionary *variants = pipelinePatches[key];
        if (variants) {
            NSNumber *fHash = pipelineFragHash[key];
            NSNumber *vHash = pipelineVertHash[key];

            BOOL isFlash = fHash && [flashHashes containsObject:fHash];
            BOOL colorOn = (fHash && [activeColorHashes containsObject:fHash]) ||
                           (vHash && [activeColorHashes containsObject:vHash]);

            if (isFlash && variants[@"flash"]) {
                toUse = flashVisible ? variants[@"flash"] : state;
            } else if (colorOn && variants[@"color"]) {
                toUse = variants[@"color"];
            }

            if (toUse != state) {
                NSTimeInterval now = CACurrentMediaTime();
                if (now - gLastSwapLogTime > 1.0) {
                    gLastSwapLogTime = now;
                    // Look up pixel format from stored descriptor for diagnostics
                    MTLRenderPipelineDescriptor *swapDesc = pipelineDescriptors[key];
                    NSString *fmtStr = swapDesc ? fmFmtName(swapDesc.colorAttachments[0].pixelFormat) : @"?";
                    swapLogMsg = [NSString stringWithFormat:
                        @"[SWAP ✓] %@ frag=%04lx fmt=%@ | orig=%p → patch=%p",
                        isFlash ? @"flash" : @"color",
                        (unsigned long)(fHash ? fHash.unsignedIntegerValue & 0xFFFF : 0),
                        fmtStr,
                        (__bridge void*)state, (__bridge void*)toUse];
                }
            }
        }
    } // @synchronized

    if (swapLogMsg) dispatch_async(dispatch_get_main_queue(), ^{
        if (floatingMenu) [floatingMenu addLog:swapLogMsg];
    });
    if (toUse != state) {
        NSLog(@"[FM-DIAG][N] SWAP orig=%p → patch=%p", (__bridge void*)state, (__bridge void*)toUse);
    }
    origSetPipe(self, _cmd, toUse);
    } // @autoreleasepool
}

// ── Hook: renderCommandEncoderWithDescriptor: (lazy encoder hook) ─────────────

static id<MTLRenderCommandEncoder> hooked_renderCommandEncoder(id self, SEL _cmd,
                                                                MTLRenderPassDescriptor *desc) {
    id<MTLRenderCommandEncoder> enc = origRenderEnc(self, _cmd, desc);
    if (enc) {
        Class encCls = object_getClass(enc);
        // v1.0.55: hook EVERY unique encoder class the game uses.
        // UE4 Metal may use multiple private MTLRenderCommandEncoder subclasses
        // (e.g. one for init/debug passes, another for actual in-match rendering).
        // The old dispatch_once approach only hooked the FIRST class seen; after
        // origSetPipe was set for that class, !origSetPipe short-circuited and
        // the rendering class was never hooked → setRenderPipelineState never fired
        // in our hook → gLiveActiveHashes permanently empty → LIVE always 0.
        // Fix: track seen classes in a set, dispatch hookEncClass for each new one.
        static NSMutableSet<NSValue *> *sHookedEncClasses;
        static dispatch_once_t sHookedInit;
        dispatch_once(&sHookedInit, ^{ sHookedEncClasses = [NSMutableSet new]; });
        NSValue *clsVal = [NSValue valueWithPointer:(__bridge void *)encCls];
        BOOL isNew;
        @synchronized(gHookLock) {
            isNew = ![sHookedEncClasses containsObject:clsVal];
            if (isNew) [sHookedEncClasses addObject:clsVal];
        }
        if (isNew) {
            dispatch_async(dispatch_get_main_queue(), ^{ hookEncClass(encCls); });
        }
    }
    if (!gHooksEnabled) return enc;
    return enc;
}

// ── Hook: newRenderPipelineStateWithDescriptor:error: ─────────────────────────

static id<MTLRenderPipelineState> buildVariantPipeline(id device,
                                                        MTLRenderPipelineDescriptor *base,
                                                        id<MTLLibrary> vLib,
                                                        id<MTLLibrary> fLib) {
    MTLRenderPipelineDescriptor *d = [base copy];
    if (vLib) {
        // kReplaceFuncKey: const-color replacement for binary IR shaders uses "fmColorPatch"
        NSString *ovr = objc_getAssociatedObject(vLib, &kReplaceFuncKey);
        NSString *fnName = ovr ?: base.vertexFunction.name;
        id<MTLFunction> fn = [vLib newFunctionWithName:fnName];
        if (!fn) {
            NSString *avail = [[vLib functionNames] componentsJoinedByString:@","];
            fmLog([NSString stringWithFormat:@"[VARIANT] vLib fn '%@' NOT FOUND. Disponibili: %@", fnName, avail]);
            return nil;
        }
        d.vertexFunction = fn;
    }
    if (fLib) {
        NSString *ovr = objc_getAssociatedObject(fLib, &kReplaceFuncKey);
        NSString *fnName = ovr ?: base.fragmentFunction.name;
        id<MTLFunction> fn = [fLib newFunctionWithName:fnName];
        if (!fn) {
            NSString *avail = [[fLib functionNames] componentsJoinedByString:@","];
            fmLog([NSString stringWithFormat:@"[VARIANT] fLib fn '%@' NOT FOUND. Disponibili: %@", fnName, avail]);
            return nil;
        }
        d.fragmentFunction = fn;
        // For const-color replacement (fmColorPatch / binary IR): force fully-opaque
        // write so blend state / writeMask from the original pass cannot hide our color.
        if (ovr) {
            for (NSUInteger i = 0; i < 8; i++) {
                MTLRenderPipelineColorAttachmentDescriptor *ca = d.colorAttachments[i];
                if (ca.pixelFormat != MTLPixelFormatInvalid) {
                    ca.blendingEnabled = NO;
                    ca.writeMask = MTLColorWriteMaskAll;
                }
            }
        }
    }
    NSError *err = nil;
    // Log before/after GPU compile so crash log shows which side we were on.
    {
        NSString *vn = (d.vertexFunction && [d.vertexFunction respondsToSelector:@selector(name)]) ? d.vertexFunction.name : @"?";
        NSString *fn = (d.fragmentFunction && [d.fragmentFunction respondsToSelector:@selector(name)]) ? d.fragmentFunction.name : @"?";
        NSString *pre = [NSString stringWithFormat:@"[VARIANT PRE] v='%@' f='%@'", vn, fn];
        const char *u = [pre UTF8String]; if (gCrashLogFD >= 0) { write(gCrashLogFD, u, strlen(u)); write(gCrashLogFD, "\n", 1); }
    }
    id<MTLRenderPipelineState> ps = origNewPipeline(device,
                           @selector(newRenderPipelineStateWithDescriptor:error:),
                           d, &err);
    fmWriteCrashBytes("[VARIANT POST]\n");
    if (!ps || err) {
        NSString *em = [NSString stringWithFormat:@"[VARIANT ERR] %@", err.localizedDescription ?: @"nil"];
        dispatch_async(dispatch_get_main_queue(), ^{ if (floatingMenu) [floatingMenu addLog:em]; });
    }
    return ps;
}

// ── buildVariantPipelineAsync ─────────────────────────────────────────────
// Like buildVariantPipeline but uses Metal's OWN async compilation API
// (newRenderPipelineStateWithDescriptor:completionHandler:) via origNewPipelineAsync.
// This is SAFE to call while a render command encoder is active — Metal
// queues the GPU compile internally and fires completion when done.
// All callers that previously used the sync version during active match
// rendering should use this instead to avoid Metal vertex-function conflicts.

static void buildVariantPipelineAsync(id device,
                                       MTLRenderPipelineDescriptor *base,
                                       id<MTLLibrary> vLib,
                                       id<MTLLibrary> fLib,
                                       FMPipelineCompletion completion) {
    fmDiag([NSString stringWithFormat:@"[I] BVPA device=%p base=%p vLib=%p fLib=%p vFn=%@ fFn=%@",
        (__bridge void*)device, (__bridge void*)base,
        (__bridge void*)vLib, (__bridge void*)fLib,
        base.vertexFunction ? base.vertexFunction.name : @"nil",
        base.fragmentFunction ? base.fragmentFunction.name : @"nil"]);
    if (!base || (!vLib && !fLib)) {
        fmDiag(@"[I-nil] BVPA: base nil or both libs nil — abort");
        if (completion) completion(nil); return; }
    if (!base.vertexFunction) {
        fmDiag(@"[I-nil-vFn] BVPA: base.vertexFunction nil — abort");
        if (completion) completion(nil); return; }
    if (!base.fragmentFunction) {
        fmDiag(@"[I-nil-fFn] BVPA: base.fragmentFunction nil — abort");
        if (completion) completion(nil); return; }
    MTLRenderPipelineDescriptor *d = [base copy];
    if (vLib) {
        NSString *ovr = objc_getAssociatedObject(vLib, &kReplaceFuncKey);
        NSString *fnName = ovr ?: base.vertexFunction.name;
        id<MTLFunction> fn = [vLib newFunctionWithName:fnName];
        if (!fn) {
            fmLog([NSString stringWithFormat:@"[ASYNC VAR] vLib fn '%@' not found", fnName]);
            if (completion) completion(nil); return;
        }
        d.vertexFunction = fn;
    }
    if (fLib) {
        NSString *ovr = objc_getAssociatedObject(fLib, &kReplaceFuncKey);
        NSString *fnName = ovr ?: base.fragmentFunction.name;
        id<MTLFunction> fn = [fLib newFunctionWithName:fnName];
        if (!fn) {
            fmLog([NSString stringWithFormat:@"[ASYNC VAR] fLib fn '%@' not found", fnName]);
            if (completion) completion(nil); return;
        }
        d.fragmentFunction = fn;
        if (ovr) {
            for (NSUInteger i = 0; i < 8; i++) {
                MTLRenderPipelineColorAttachmentDescriptor *ca = d.colorAttachments[i];
                if (ca.pixelFormat != MTLPixelFormatInvalid) {
                    ca.blendingEnabled = NO;
                    ca.writeMask = MTLColorWriteMaskAll;
                }
            }
        }
    }
    // Always use SYNC pipeline creation for our variant builds.
    // origNewPipelineAsync crashes inside Metal's GPU compiler without returning NSError.
    // We are already on a background dispatch queue so sync is safe here.
    fmDiag([NSString stringWithFormat:@"[J] calling Metal pipeline d.vFn=%@ d.fFn=%@ d.smp=%lu sync",
        d.vertexFunction ? d.vertexFunction.name : @"nil",
        d.fragmentFunction ? d.fragmentFunction.name : @"nil",
        (unsigned long)d.rasterSampleCount]);
    NSError *buildErr = nil;
    id<MTLRenderPipelineState> builtPS = origNewPipeline(device,
        @selector(newRenderPipelineStateWithDescriptor:error:), d, &buildErr);
    fmDiag([NSString stringWithFormat:@"[K] sync done ps=%s err=%@",
        builtPS ? "OK" : "nil",
        buildErr.localizedDescription ?: @"no-err"]);
    if (completion) completion(builtPS);
}

static id<MTLRenderPipelineState> hooked_newRenderPipelineState(id self, SEL _cmd,
                                                                  MTLRenderPipelineDescriptor *desc,
                                                                  NSError **error) {
    if (!gHooksEnabled) return origNewPipeline(self, _cmd, desc, error);
    id<MTLRenderPipelineState> orig = origNewPipeline(self, _cmd, desc, error);
    if (!orig || !desc.vertexFunction || !desc.fragmentFunction) return orig;

    // Identify source hashes via associated objects on the MTLFunction
    NSNumber *vHash = objc_getAssociatedObject(desc.vertexFunction,   &kFuncHashKey);
    NSNumber *fHash = objc_getAssociatedObject(desc.fragmentFunction, &kFuncHashKey);

    // ── Fragment late-tag ────────────────────────────────────────────────────
    // If the fragment function has no hash (library was created via an unhooked
    // path OR newFunctionWithName: fired before the hook was installed on its
    // class), recover the hash from the library now and tag retroactively.
    if (!fHash && desc.fragmentFunction) {
        // _MTLFunctionInternal (used by Unity/R6) may not implement -library → guard
        id<MTLLibrary> fLib = [desc.fragmentFunction respondsToSelector:@selector(library)]
            ? ((id<MTLFunction_iOS14>)desc.fragmentFunction).library : nil;
        if (fLib) {
            NSNumber *libHash = objc_getAssociatedObject(fLib, &kLibHashKey);
            if (!libHash) {
                // Library never tagged — assign hash and capture it.
                // v1.0.34: do NOT call method_setImplementation or hookFuncConstMethods here;
                // this path runs from 500+ concurrent pipeline creation threads → race.
                // The function hook is already installed by hooked_newLibraryWithSource's
                // dispatch_once before the first library was returned to the game.
                libHash = lateTagLibrary(fLib);
            }
            if (libHash) {
                fHash = libHash;
                // Retroactively tag this function object so future lookups find it
                objc_setAssociatedObject(desc.fragmentFunction, &kFuncHashKey, fHash,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                fmLog([NSString stringWithFormat:@"[FRAG LATE TAG] hash=%04lx fn='%@'",
                    libHash.unsignedIntegerValue & 0xFFFF,
                    ([desc.fragmentFunction respondsToSelector:@selector(name)] ? desc.fragmentFunction.name : nil) ?: @"?"]);
            }
        }
    }

    if (!vHash && !fHash) return orig;

    NSValue *pKey = [NSValue valueWithPointer:(__bridge void*)orig];

    // Write pipeline metadata under lock — concurrent pipeline creation from multiple threads.
    // Clear any stale variant: when iOS reuses a pipeline-state address after the old object
    // was released (scene transition / going home), pipelinePatches[pKey] would still hold
    // the OLD variant (different shader / vertex format). Passing that to
    // setRenderPipelineState crashes Metal immediately.
    // Also ALWAYS increment pipelineGeneration[pKey]: rebuildVariantsForHash snapshots the
    // generation before building variants. If the generation changed by the time it tries to
    // write back, it skips the write — preventing stale variants from re-appearing after a
    // brief address reuse race.
    // capturedGen is used BELOW (after GPU compile) to guard the write-back against address reuse.
    NSUInteger capturedGen = 0;
    // v1.0.35: copy descriptor BEFORE acquiring lock — [desc copy] can be slow under
    // concurrent pipeline burst (500+ pipelines) and was blocking the render thread
    // in hooked_setRenderPipelineState → Metal GPU watchdog SIGKILL.
    MTLRenderPipelineDescriptor *descCopy = [desc copy];
    @synchronized(gHookLock) {
        // Clear ALL old mappings for this address unconditionally (not just when a patch exists)
        // — on address reuse after a scene transition the old hash/descriptor must be replaced.
        [pipelinePatches     removeObjectForKey:pKey];
        [pipelineVertHash    removeObjectForKey:pKey];
        [pipelineFragHash    removeObjectForKey:pKey];
        [pipelineDescriptors removeObjectForKey:pKey];
        NSUInteger gen = [pipelineGeneration[pKey] unsignedIntegerValue] + 1;
        pipelineGeneration[pKey] = @(gen);
        capturedGen = gen;
        if (vHash) pipelineVertHash[pKey]  = vHash;
        if (fHash) pipelineFragHash[pKey]  = fHash;
        pipelineDescriptors[pKey] = descCopy; // pre-copied outside lock
        // Persistent per-frag-hash cache: survives burst-detector purge.
        // rebuildVariantsForHash uses this as fallback when pipelineDescriptors[pk] is gone.
        if (fHash) pipelineDescByFragHash[fHash] = descCopy;
        // Burst detector: 10+ pipeline nuove in 1 s → transizione scena → svuota i vecchi
        // descriptor per rilasciare i MTLFunction/MTLLibrary del gioco.
        // IMPORTANTE: non toccare pipelinePatches — sono i nostri variant compilati (non
        // memoria del gioco) e lo swap dipende da essi. Rimuovere solo il descriptor (che
        // trattiene MTLFunction/MTLLibrary del gioco) e gli hash mapping associati.
        {
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (now - gBurstWindowStart > 1.0) { gBurstWindowStart = now; gBurstCount = 0; }
            gBurstCount++;
            if (gBurstCount >= 10 && pipelineDescriptors.count > 30) {
                NSUInteger keep = 25;
                if (pipelineDescriptors.count > keep) {
                    NSArray *oldKeys = [pipelineDescriptors.allKeys
                        subarrayWithRange:NSMakeRange(0, pipelineDescriptors.count - keep)];
                    NSUInteger removed = 0;
                    for (id k in oldKeys) {
                        // Salta le chiavi con un variant attivo — il descriptor serve per rebuild.
                        if (pipelinePatches[k] != nil) continue;
                        // Remove ONLY the descriptor (holds MTLFunction/MTLLibrary → OOM risk).
                        // DO NOT remove pipelineFragHash / pipelineVertHash: those are tiny
                        // NSNumber-only maps and are read 60 fps by hooked_setRenderPipelineState
                        // to populate gLiveActiveHashes for the LIVE filter. Removing them here
                        // would leave gLiveActiveHashes permanently empty → LIVE always shows 0.
                        [pipelineDescriptors removeObjectForKey:k];
                        [pipelineGeneration  removeObjectForKey:k];
                        removed++;
                    }
                    if (removed > 0)
                        fmLog([NSString stringWithFormat:
                            @"[SYS] Burst %lu pipe/s — rimossi %lu desc vecchi (anti-OOM)",
                            (unsigned long)gBurstCount, (unsigned long)removed]);
                }
                gBurstCount = 0;
            }
        }
        // Limite dimensione assoluto: max 100 entry.
        if (pipelineDescriptors.count > 100) {
            NSArray *keys = [pipelineDescriptors.allKeys
                             subarrayWithRange:NSMakeRange(0, pipelineDescriptors.count - 75)];
            for (id k in keys) {
                [pipelineDescriptors removeObjectForKey:k];
                [pipelineVertHash    removeObjectForKey:k];
                [pipelineFragHash    removeObjectForKey:k];
                [pipelinePatches     removeObjectForKey:k];
                [pipelineGeneration  removeObjectForKey:k];
            }
        }
    }

    // ── DIAG LOG: unique (vHash, fHash) pairs ────────────────────────────────
    {
        static dispatch_once_t pairSetOnce;
        static NSMutableSet *loggedPipePairs = nil;
        dispatch_once(&pairSetOnce, ^{ loggedPipePairs = [[NSMutableSet alloc] init]; });
        NSString *pairKey = [NSString stringWithFormat:@"%04lx_%04lx",
            vHash ? vHash.unsignedIntegerValue & 0xFFFF : 0xFFFF,
            fHash ? fHash.unsignedIntegerValue & 0xFFFF : 0xFFFF];
        BOOL isNew = NO;
        @synchronized(loggedPipePairs) {
            if (![loggedPipePairs containsObject:pairKey]) {
                [loggedPipePairs addObject:pairKey];
                isNew = YES;
            }
        }
        if (isNew) {
            NSString *pipeMsg = [NSString stringWithFormat:
                @"[PIPE SEEN] v=%@ f=%@ | vFn='%@' fFn='%@'",
                vHash ? [NSString stringWithFormat:@"%04lx", vHash.unsignedIntegerValue & 0xFFFF] : @"---",
                fHash ? [NSString stringWithFormat:@"%04lx", fHash.unsignedIntegerValue & 0xFFFF] : @"---",
                ([desc.vertexFunction   respondsToSelector:@selector(name)] ? desc.vertexFunction.name   : nil) ?: @"?",
                ([desc.fragmentFunction respondsToSelector:@selector(name)] ? desc.fragmentFunction.name : nil) ?: @"?"];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (floatingMenu) [floatingMenu addLog:pipeMsg];
            });
        }
    }

    // Read patch state under lock, then build variants outside (GPU ops must not hold lock)
    id<MTLLibrary> cvLib = nil, cfLib = nil, flLib = nil;
    BOOL colorNow = NO;
    @synchronized(gHookLock) {
        colorNow = (vHash && [activeColorHashes containsObject:vHash]) ||
                   (fHash && [activeColorHashes containsObject:fHash]);
        if (colorNow) {
            id<MTLLibrary> rawV = vHash ? colorLibraries[vHash] : nil;
            id<MTLLibrary> rawF = fHash ? colorLibraries[fHash] : nil;
            // Binary metallib: vHash==fHash, colorLibraries stores an fmColorPatch
            // *fragment* lib. Never pass it as the vertex lib — keep the original
            // binary vertex function so Metal doesn't get a fragment fn as vertex stage.
            if (rawV) {
                NSString *vOvr = objc_getAssociatedObject(rawV, &kReplaceFuncKey);
                if ([vOvr isEqualToString:@"fmColorPatch"]) rawV = nil;
            }
            cvLib = rawV;
            cfLib = rawF;
        }
        if (fHash && [flashHashes containsObject:fHash]) flLib = flashLibraries[fHash];
    }

    // ── Skip depth-only / shadow / compute passes ──────────────────────────────
    // These have no color attachments → fragment color patch is useless AND
    // building a variant for them causes Metal pipeline validation crashes.
    {
        BOOL hasColorOut = NO;
        for (NSUInteger i = 0; i < 8; i++) {
            if (desc.colorAttachments[i].pixelFormat != MTLPixelFormatInvalid) {
                hasColorOut = YES; break;
            }
        }
        if (!hasColorOut) return orig;
    }

    // ── Dedup: one async-build per (fHash,vHash) pair ───────────────────────
    // Prevents 50+ GPU pipeline compiles for the same shader during match load.
    NSString *pairKey = [NSString stringWithFormat:@"%@|%@",
        fHash ? [NSString stringWithFormat:@"%lx", fHash.unsignedIntegerValue] : @"0",
        vHash ? [NSString stringWithFormat:@"%lx", vHash.unsignedIntegerValue] : @"0"];
    {
        BOOL alreadyQueued = NO;
        @synchronized(gBuiltVariantPairs) {
            alreadyQueued = [gBuiltVariantPairs containsObject:pairKey];
            if (!alreadyQueued) [gBuiltVariantPairs addObject:pairKey];
        }
        if (alreadyQueued) {
            fmLog([NSString stringWithFormat:@"[PIPE NEW] già in coda %@, skip", pairKey]);
            return orig;
        }
    }

    // ── ASYNC DELAYED BUILD — THE CORE CRASH FIX ─────────────────────────────
    // Building the variant SYNCHRONOUSLY inside hooked_newRenderPipelineState
    // crashes immediately when the shader first loads in-match:
    //   game thread creates pipeline → our hook builds + swaps variant immediately
    //   → Metal sees pipeline/renderpass mismatch (depth format, sample count,
    //     blend equations not yet finalized) → EXC_BAD_ACCESS / Metal assert.
    //
    // The 500 ms delay gives the game's render pass time to fully stabilize
    // before we install the variant. The game runs with the original pipeline
    // for those first 500 ms (no patch visible yet, but no crash either).
    //
    // gPatchBuildGen: incremented by fmClearAllShaderPatches() / kill-switch.
    // Any async build that finds gPatchBuildGen changed aborts before writing
    // to pipelinePatches — making the kill switch truly instant even for
    // in-flight builds.
    {
        id selfDevice              = self;
        MTLRenderPipelineDescriptor *descCopy = [desc copy]; // snapshot before game mutates
        uint64_t  genAtCapture     = gPatchBuildGen;
        NSValue  *pKeyCopy         = pKey;
        NSNumber *fHashCopy        = fHash;
        NSNumber *vHashCopy        = vHash;
        NSUInteger capturedGenCopy = capturedGen;
        id<MTLLibrary> cvLibCopy   = cvLib;
        id<MTLLibrary> cfLibCopy   = cfLib;
        id<MTLLibrary> flLibCopy   = flLib;
        BOOL colorNowCopy          = colorNow;

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
            dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{

            if (gPatchBuildGen != genAtCapture) {
                fmLog([NSString stringWithFormat:@"[ASYNC BUILD] annullato (kill) %@", pairKey]);
                return;
            }
            fmDiag([NSString stringWithFormat:@"[M] 500ms block pair=%@ colorNow=%d cvLib=%s cfLib=%s flLib=%s",
                pairKey, (int)colorNowCopy,
                cvLibCopy ? "OK" : "nil", cfLibCopy ? "OK" : "nil", flLibCopy ? "OK" : "nil"]);
            if (!colorNowCopy && !flLibCopy) return; // nothing to build

            // Use Metal's own async compilation API — safe while the game's render
            // command encoders are active (no vertex-function conflict).
            __block id<MTLRenderPipelineState> cpResult = nil;
            __block id<MTLRenderPipelineState> fpResult = nil;
            dispatch_group_t grp = dispatch_group_create();

            if (colorNowCopy && (cvLibCopy || cfLibCopy)) {
                dispatch_group_enter(grp);
                buildVariantPipelineAsync(selfDevice, descCopy, cvLibCopy, cfLibCopy,
                    ^(id<MTLRenderPipelineState> ps) { cpResult = ps; dispatch_group_leave(grp); });
            }
            if (flLibCopy) {
                dispatch_group_enter(grp);
                buildVariantPipelineAsync(selfDevice, descCopy, nil, flLibCopy,
                    ^(id<MTLRenderPipelineState> ps) { fpResult = ps; dispatch_group_leave(grp); });
            }

            dispatch_group_notify(grp,
                dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{

                if (gPatchBuildGen != genAtCapture) return;
                NSMutableDictionary *variants = [NSMutableDictionary dictionary];
                if (cpResult) variants[@"color"] = cpResult;
                if (fpResult) variants[@"flash"] = fpResult;
                if (variants.count == 0) return;

                if (gPatchBuildGen != genAtCapture) return;
                BOOL written = NO;
                @synchronized(gHookLock) {
                    if (gPatchBuildGen == genAtCapture &&
                        [pipelineGeneration[pKeyCopy] unsignedIntegerValue] == capturedGenCopy) {
                        pipelinePatches[pKeyCopy] = variants;
                        [pipelineDescriptors removeObjectForKey:pKeyCopy]; // anti-OOM
                        written = YES;
                    }
                }
                if (written) {
                    NSString *msg = [NSString stringWithFormat:
                        @"[BUILD â] color:%d flash:%d frag=%04lx vert=%04lx",
                        cpResult!=nil, fpResult!=nil,
                        (unsigned long)(fHashCopy ? fHashCopy.unsignedIntegerValue & 0xFFFF : 0),
                        (unsigned long)(vHashCopy ? vHashCopy.unsignedIntegerValue & 0xFFFF : 0)];
                    dispatch_async(dispatch_get_main_queue(), ^{ if (floatingMenu) [floatingMenu addLog:msg]; });
                }
            });
        });
    }
    return orig;
}

// ── Hook: newRenderPipelineStateWithDescriptor:completionHandler: (async) ─────
// R6 Mobile (and other Metal games using MoltenVK) may create pipelines
// asynchronously. This hook captures those pipelines into pipelineVertHash/
// pipelineFragHash/pipelineDescriptors for later wallhack/color variant use.

static void hooked_newRenderPipelineStateAsync(id self, SEL _cmd,
                                                MTLRenderPipelineDescriptor *desc,
                                                MTLNewRenderPipelineStateCompletionHandler handler) {
    if (!gHooksEnabled) { origNewPipelineAsync(self, _cmd, desc, handler); return; }
    MTLNewRenderPipelineStateCompletionHandler wrapped =
        ^(id<MTLRenderPipelineState> ps, NSError *err) {
            if (ps && desc && desc.vertexFunction && desc.fragmentFunction) {
                NSNumber *vHash = objc_getAssociatedObject(desc.vertexFunction,   &kFuncHashKey);
                NSNumber *fHash = objc_getAssociatedObject(desc.fragmentFunction, &kFuncHashKey);
                // Fragment late-tag (async path) — same logic as sync hook
                if (!fHash) {
                    id<MTLLibrary> fLib = [desc.fragmentFunction respondsToSelector:@selector(library)]
                        ? ((id<MTLFunction_iOS14>)desc.fragmentFunction).library : nil;
                    if (fLib) {
                        NSNumber *libHash = objc_getAssociatedObject(fLib, &kLibHashKey);
                        if (!libHash) {
                            libHash = lateTagLibrary(fLib);
                            // v1.0.38: do NOT call method_setImplementation or hookFuncConstMethods here.
                            // This completion handler runs on Metal's internal threads — 500+ concurrent
                            // completions → race condition on method_setImplementation → crash.
                            // Stessa fix applicata al hook sync in v1.0.34 (vedi commento riga 1333).
                            // Il function hook è già installato da hooked_newLibraryWithSource/Data
                            // tramite dispatch_once prima che qualsiasi pipeline venga creata.
                        }
                        if (libHash) {
                            fHash = libHash;
                            objc_setAssociatedObject(desc.fragmentFunction, &kFuncHashKey, fHash,
                                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                        }
                    }
                }
                if (vHash || fHash) {
                    NSValue *pKey = [NSValue valueWithPointer:(__bridge void*)ps];
                    MTLRenderPipelineDescriptor *descCopy = [desc copy];
                    NSUInteger capturedGen = 0;

                    // ── Read color/flash libs under lock ──────────────────────
                    id<MTLLibrary> cvLib = nil, cfLib = nil, flLib = nil;
                    BOOL colorNow = NO;
                    @synchronized(gHookLock) {
                        // Clear stale variant + bump generation (same logic as sync hook)
                        if (pipelinePatches[pKey]) [pipelinePatches removeObjectForKey:pKey];
                        NSUInteger gen = [pipelineGeneration[pKey] unsignedIntegerValue] + 1;
                        pipelineGeneration[pKey] = @(gen);
                        capturedGen = gen;
                        if (vHash) pipelineVertHash[pKey]  = vHash;
                        if (fHash) pipelineFragHash[pKey]  = fHash;
                        pipelineDescriptors[pKey] = descCopy;
                        // FIX: populate persistent descriptor cache — fixes rebuildVariantsForHash
                        // when burst-detector has purged pipelineDescriptors (main cause of color:0)
                        if (fHash) pipelineDescByFragHash[fHash] = descCopy;

                        // Read color/flash state for immediate variant build
                        colorNow = (vHash && [activeColorHashes containsObject:vHash]) ||
                                   (fHash && [activeColorHashes containsObject:fHash]);
                        if (colorNow) {
                            id<MTLLibrary> rawV = vHash ? colorLibraries[vHash] : nil;
                            id<MTLLibrary> rawF = fHash ? colorLibraries[fHash] : nil;
                            if (rawV) {
                                NSString *vOvr = objc_getAssociatedObject(rawV, &kReplaceFuncKey);
                                if ([vOvr isEqualToString:@"fmColorPatch"]) rawV = nil;
                            }
                            cvLib = rawV; cfLib = rawF;
                        }
                        if (fHash && [flashHashes containsObject:fHash]) flLib = flashLibraries[fHash];
                    }

                    NSString *msg = [NSString stringWithFormat:
                        @"[PIPE ASYNC] tracked frag=%04lx vert=%04lx colorNow=%d",
                        (unsigned long)(fHash ? fHash.unsignedIntegerValue & 0xFFFF : 0),
                        (unsigned long)(vHash ? vHash.unsignedIntegerValue & 0xFFFF : 0),
                        (int)colorNow];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (floatingMenu) [floatingMenu addLog:msg];
                    });

                    // ── Immediate variant build if patch already active ────────
                    // (mirrors the variant-build path in hooked_newRenderPipelineState)
                    id selfCopy = self; // MTLDevice
                    NSValue *pKeyCopy = pKey;
                    NSUInteger genCopy = capturedGen;
                    if (cvLib || cfLib) {
                        buildVariantPipelineAsync(selfCopy, descCopy, cvLib, cfLib,
                            ^(id<MTLRenderPipelineState> cp) {
                                if (!cp) return;
                                @synchronized(gHookLock) {
                                    if (![pipelineGeneration[pKeyCopy] isEqual:@(genCopy)]) return;
                                    NSMutableDictionary *pv =
                                        [pipelinePatches[pKeyCopy] mutableCopy] ?: [NSMutableDictionary dictionary];
                                    pv[@"color"] = cp;
                                    pipelinePatches[pKeyCopy] = pv;
                                }
                                dispatch_async(dispatch_get_main_queue(), ^{
                                    if (floatingMenu) [floatingMenu addLog:
                                        [NSString stringWithFormat:@"[PIPE ASYNC COLOR ✓] frag=%04lx",
                                         (unsigned long)(fHash ? fHash.unsignedIntegerValue & 0xFFFF : 0)]];
                                });
                            });
                    }
                    if (flLib) {
                        buildVariantPipelineAsync(selfCopy, descCopy, nil, flLib,
                            ^(id<MTLRenderPipelineState> fp) {
                                if (!fp) return;
                                @synchronized(gHookLock) {
                                    if (![pipelineGeneration[pKeyCopy] isEqual:@(genCopy)]) return;
                                    NSMutableDictionary *pv =
                                        [pipelinePatches[pKeyCopy] mutableCopy] ?: [NSMutableDictionary dictionary];
                                    pv[@"flash"] = fp;
                                    pipelinePatches[pKeyCopy] = pv;
                                }
                            });
                    }
                }
            }
            if (handler) handler(ps, err);
        };
    origNewPipelineAsync(self, _cmd, desc, wrapped);
}

// ── Hook: newLibraryWithSource:options:error: ─────────────────────────────────

static NSString *extractMSLFunctionName(NSString *source, NSString *keyword) {
    for (NSString *raw in [source componentsSeparatedByString:@"\n"]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (!([line hasPrefix:[keyword stringByAppendingString:@" "]] ||
              [line hasPrefix:[keyword stringByAppendingString:@"\t"]])) continue;
        NSArray *t = [[line componentsSeparatedByCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]]
                      filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
        if (t.count < 3) continue;
        NSString *c = t[2];
        NSRange p = [c rangeOfString:@"("];
        if (p.location != NSNotFound) c = [c substringToIndex:p.location];
        c = [c stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (c.length > 1 && ![c isEqualToString:keyword] && ![c isEqualToString:@"void"])
            return c;
    }
    return nil;
}

static NSString *descriptiveShaderName(NSString *source) {
    if (!source.length) return @"unnamed";

    // Stable fallback: use source length (not [source hash] — salted per-process on iOS)
    NSString *hex = [NSString stringWithFormat:@"fn_%05lu", (unsigned long)(source.length & 0xFFFFF)];

    NSString *v = extractMSLFunctionName(source, @"vertex");
    if (v) return v;
    NSString *f = extractMSLFunctionName(source, @"fragment");
    if (f) return f;
    NSString *k = extractMSLFunctionName(source, @"kernel");
    if (k) return k;

    // Fallback: unique hex so every shader gets a distinct name
    return hex;
}

static id<MTLLibrary> hooked_newLibraryWithSource(id self, SEL _cmd,
                                                   NSString *source,
                                                   MTLCompileOptions *options,
                                                   NSError **error) {
    // gCaptureSourceLibs is always YES — capture MSL even before user enables pipeline hooks.
    // This catches the big shader compilation burst that happens during match loading.
    if (!gCaptureSourceLibs) return origNewLibrary(self, _cmd, source, options, error);
    id<MTLLibrary> lib = origNewLibrary(self, _cmd, source, options, error);
    if (!lib) return lib;

    NSString   *errStr = (error && *error) ? (*error).localizedDescription : nil;
    NSString   *name   = descriptiveShaderName(source);
    NSUInteger  hash   = [source hash];
    NSNumber   *hKey   = @(hash);

    // Lock: multiple Metal threads may call newLibraryWithSource: concurrently
    @synchronized(gHookLock) {
        capturedSources[hKey]      = source;
        capturedSourceNames[hKey]  = name;   // saved for replay after floatingMenu init
        // v1.0.35: do NOT store strong lib ref — prevents game releasing compiled GPU lib → OOM
        if (options) capturedOptions[hKey] = options;
    }
    // Tag the library → functions will inherit the hash via hooked_newFunctionWithName
    objc_setAssociatedObject(lib, &kLibHashKey, hKey, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // v1.0.40: dispatch method_setImplementation to MAIN THREAD.
    // method_setImplementation from Metal compiler thread (background) races ObjC runtime → crash.
    if (!origNewFunction) {
        id<MTLLibrary> capturedLib = lib; // ARC retains lib in block
        static dispatch_once_t funcHookOnce;
        dispatch_async(dispatch_get_main_queue(), ^{
            dispatch_once(&funcHookOnce, ^{
                Class cls = object_getClass(capturedLib);
                Method m = class_getInstanceMethod(cls, @selector(newFunctionWithName:));
                if (m) {
                    origNewFunction = (NewFuncIMP)method_getImplementation(m);
                    method_setImplementation(m, (IMP)hooked_newFunctionWithName);
                }
                hookFuncConstMethods(capturedLib);
            });
        });
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if (floatingMenu) [floatingMenu captureShaderWithName:name source:source error:errStr libHash:[source hash]];
    });
    return lib;
}

// ── Hook: newLibraryWithSource:options:completionHandler: (async variant) ─────
// Some engines (e.g. MoltenVK / R6 Mobile) use the async version.

static void hooked_newLibraryWithSourceAsync(id self, SEL _cmd,
                                              NSString *source,
                                              MTLCompileOptions *options,
                                              MTLNewLibraryCompletionHandler handler) {
    // gCaptureSourceLibs is always YES — same as sync variant above.
    if (!gCaptureSourceLibs) { origNewLibraryAsync(self, _cmd, source, options, handler); return; }
    MTLNewLibraryCompletionHandler wrapped = ^(id<MTLLibrary> lib, NSError *err) {
        if (lib && source.length > 0) {
            NSString   *name = descriptiveShaderName(source);
            NSUInteger  hash = [source hash];
            NSNumber   *hKey = @(hash);
            @synchronized(gHookLock) {
                capturedSources[hKey]     = source;
                capturedSourceNames[hKey] = name;   // saved for replay after floatingMenu init
                // v1.0.35: do NOT store strong lib ref — prevents game releasing compiled GPU lib → OOM
                if (options) capturedOptions[hKey] = options;
            }
            objc_setAssociatedObject(lib, &kLibHashKey, hKey, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            static dispatch_once_t asyncFuncHookOnce;
            dispatch_once(&asyncFuncHookOnce, ^{
                Class cls = object_getClass(lib);
                Method m  = class_getInstanceMethod(cls, @selector(newFunctionWithName:));
                if (m && method_getImplementation(m) != (IMP)hooked_newFunctionWithName) {
                    origNewFunction = (NewFuncIMP)method_getImplementation(m);
                    method_setImplementation(m, (IMP)hooked_newFunctionWithName);
                }
                hookFuncConstMethods(lib);
            });
            NSString *errStr = err ? err.localizedDescription : nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (floatingMenu) [floatingMenu captureShaderWithName:name source:source error:errStr libHash:[source hash]];
            });
        }
        if (handler) handler(lib, err);
    };
    origNewLibraryAsync(self, _cmd, source, options, wrapped);
}

// ── AIR Reflection: produce pseudo-MSL from MTLRenderPipelineReflection ───────
// Uses the public MTLPipelineOptionArgumentInfo API — same data Metal Inspector uses.
// For each function in a binary library we build a dummy pipeline and extract:
//   • vertex/fragment argument structs (buffers, textures, samplers)
//   • MTLStructType members with names and data types
// The result is a readable pseudo-MSL block shown in the shader panel.

static NSString *fmDataTypeName(MTLDataType dt) {
    switch (dt) {
        case MTLDataTypeNone:      return @"void";
        case MTLDataTypeStruct:    return @"struct";
        case MTLDataTypeArray:     return @"array";
        case MTLDataTypeFloat:     return @"float";
        case MTLDataTypeFloat2:    return @"float2";
        case MTLDataTypeFloat3:    return @"float3";
        case MTLDataTypeFloat4:    return @"float4";
        case MTLDataTypeFloat4x4:  return @"float4x4";
        case MTLDataTypeFloat3x3:  return @"float3x3";
        case MTLDataTypeFloat4x3:  return @"float4x3";
        case MTLDataTypeHalf:      return @"half";
        case MTLDataTypeHalf2:     return @"half2";
        case MTLDataTypeHalf3:     return @"half3";
        case MTLDataTypeHalf4:     return @"half4";
        case MTLDataTypeInt:       return @"int";
        case MTLDataTypeInt2:      return @"int2";
        case MTLDataTypeInt3:      return @"int3";
        case MTLDataTypeInt4:      return @"int4";
        case MTLDataTypeUInt:      return @"uint";
        case MTLDataTypeUInt2:     return @"uint2";
        case MTLDataTypeUInt3:     return @"uint3";
        case MTLDataTypeUInt4:     return @"uint4";
        case MTLDataTypeShort:     return @"short";
        case MTLDataTypeShort2:    return @"short2";
        case MTLDataTypeShort3:    return @"short3";
        case MTLDataTypeShort4:    return @"short4";
        case MTLDataTypeUShort:    return @"ushort";
        case MTLDataTypeUShort2:   return @"ushort2";
        case MTLDataTypeUShort3:   return @"ushort3";
        case MTLDataTypeUShort4:   return @"ushort4";
        case MTLDataTypeChar:      return @"char";
        case MTLDataTypeUChar:     return @"uchar";
        case MTLDataTypeBool:      return @"bool";
        case MTLDataTypeBool2:     return @"bool2";
        case MTLDataTypeBool3:     return @"bool3";
        case MTLDataTypeBool4:     return @"bool4";
        case MTLDataTypeTexture:   return @"texture2d";
        case MTLDataTypeSampler:   return @"sampler";
        default:
            return [NSString stringWithFormat:@"type%lu", (unsigned long)dt];
    }
}

static void fmAppendStructMembers(NSMutableString *out, MTLStructType *st,
                                   NSString *indent, int depth) {
    if (depth > 4) return; // avoid infinite recursion on circular types
    for (MTLStructMember *m in st.members) {
        NSString *typeName = fmDataTypeName(m.dataType);
        if (m.dataType == MTLDataTypeStruct) {
            MTLStructType *nested = [m structType];
            [out appendFormat:@"%@struct { // %@\n", indent, m.name];
            if (nested)
                fmAppendStructMembers(out, nested,
                    [indent stringByAppendingString:@"    "], depth + 1);
            [out appendFormat:@"%@} %@; // offset %lu\n",
                indent, m.name, (unsigned long)m.offset];
        } else if (m.dataType == MTLDataTypeArray) {
            MTLArrayType *arr = [m arrayType];
            NSString *elem = arr ? fmDataTypeName(arr.elementType) : @"?";
            [out appendFormat:@"%@%@[%lu] %@; // offset %lu\n",
                indent, elem, (unsigned long)(arr ? arr.arrayLength : 0),
                m.name, (unsigned long)m.offset];
        } else {
            [out appendFormat:@"%@%@ %@; // offset %lu\n",
                indent, typeName, m.name, (unsigned long)m.offset];
        }
    }
}

// Returns a pseudo-MSL string built from pipeline reflection for one function.
// fnName: "vertex" or "fragment" (used in label).
// fn: the MTLFunction from the binary library.
// device: the MTLDevice to compile dummy pipeline.
static NSString *fmReflectFunction(id<MTLFunction> fn, NSString *fnName,
                                    id<MTLDevice> device) {
    if (!fn || !device) return nil;
    NSMutableString *out = [NSMutableString string];

    // Build minimal pipeline descriptor
    MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
    // We need both vertex and fragment to compile — use a trivial passthrough
    // for whichever stage we DON'T have.
    NSString *passSrc = @"#include <metal_stdlib>\nusing namespace metal;\n"
        @"vertex float4 _fm_pass(uint v [[vertex_id]]) { return float4(0,0,0,1); }\n"
        @"fragment float4 _fm_fpass() { return float4(0); }\n";
    NSError *passErr = nil;
    id<MTLLibrary> passLib = [device newLibraryWithSource:passSrc options:nil error:&passErr];

    BOOL isFrag = (fn.functionType == MTLFunctionTypeFragment);
    if (isFrag) {
        id<MTLFunction> passVert = [passLib newFunctionWithName:@"_fm_pass"];
        if (!passVert) return nil;
        desc.vertexFunction   = passVert;
        desc.fragmentFunction = fn;
    } else {
        id<MTLFunction> passFrag = [passLib newFunctionWithName:@"_fm_fpass"];
        if (!passFrag) return nil;
        desc.vertexFunction   = fn;
        desc.fragmentFunction = passFrag;
    }
    desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

    MTLRenderPipelineReflection *refl = nil;
    NSError *pipeErr = nil;
    id<MTLRenderPipelineState> ps = [device
        newRenderPipelineStateWithDescriptor:desc
        options:MTLPipelineOptionArgumentInfo
        reflection:&refl
        error:&pipeErr];
    if (!ps || !refl) {
        // Pipeline compile failed — usually because this fragment function uses
        // [[stage_in]] (e.g. Mtl_VertexOut) that our _fm_pass vertex stub doesn't provide.
        // Still emit the correct type header so the shader entry gets its
        // hasVertexFunction / hasFragmentFunction flag set → R/G/B/V buttons appear.
        if (isFrag)
            return [NSString stringWithFormat:@"// ── fragment: %@ ──\n"
                "// (reflection non disponibile — stage_in interface mismatch)\n", fn.name];
        return nil;
    }

    // Vertex arguments
    NSArray<MTLArgument *> *vArgs = refl.vertexArguments;
    NSArray<MTLArgument *> *fArgs = refl.fragmentArguments;

    // Always emit the function-type header — even if there are no arguments.
    // Without it, addShaderWithName cannot detect "// ── fragment:" / "// ── vertex:"
    // and the entry stays with hasFragmentFunction=NO → no R/G/B buttons shown.
    if (!isFrag) {
        [out appendFormat:@"// ── vertex: %@ ──\n", fn.name];
        for (MTLArgument *arg in vArgs) {
            if (arg.type == MTLArgumentTypeBuffer) {
                [out appendFormat:@"struct %@ { // buffer(%lu)\n",
                    arg.name, (unsigned long)arg.index];
                MTLStructType *st = arg.bufferStructType;
                if (st) fmAppendStructMembers(out, st, @"    ", 0);
                [out appendString:@"}\n"];
            } else if (arg.type == MTLArgumentTypeTexture) {
                [out appendFormat:@"texture2d<%@> %@; // texture(%lu)\n",
                    fmDataTypeName(arg.textureDataType), arg.name,
                    (unsigned long)arg.index];
            } else if (arg.type == MTLArgumentTypeSampler) {
                [out appendFormat:@"sampler %@; // sampler(%lu)\n",
                    arg.name, (unsigned long)arg.index];
            }
        }
    } else {
        [out appendFormat:@"// ── fragment: %@ ──\n", fn.name];
        for (MTLArgument *arg in fArgs) {
            if (arg.type == MTLArgumentTypeBuffer) {
                [out appendFormat:@"struct %@ { // buffer(%lu)\n",
                    arg.name, (unsigned long)arg.index];
                MTLStructType *st = arg.bufferStructType;
                if (st) fmAppendStructMembers(out, st, @"    ", 0);
                [out appendString:@"}\n"];
            } else if (arg.type == MTLArgumentTypeTexture) {
                [out appendFormat:@"texture2d<%@> %@; // texture(%lu)\n",
                    fmDataTypeName(arg.textureDataType), arg.name,
                    (unsigned long)arg.index];
            } else if (arg.type == MTLArgumentTypeSampler) {
                [out appendFormat:@"sampler %@; // sampler(%lu)\n",
                    arg.name, (unsigned long)arg.index];
            }
        }
    }
    return out.length > 0 ? [out copy] : nil;
}

// Top-level: reflect all functions in a binary library, return combined pseudo-MSL.
// Runs on a background thread (dispatch_get_global_queue) — never on main or Metal thread.
static NSString *fmAirReflect(id<MTLLibrary> lib, id<MTLDevice> device,
                               NSArray<NSString *> *funcNames, NSUInteger h16) {
    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"// ── METALLIB [%04lx] — AIR reflection via MTLPipelineOptionArgumentInfo ──\n",
        (unsigned long)h16];
    [out appendString:@"// Struct e binding estratti automaticamente dal binary AIR.\n"];
    [out appendString:@"// R/G/B disponibili (fmColorPatch) + V wallhack depth-override.\n\n"];

    NSUInteger reflected = 0;
    for (NSString *fnName in funcNames) {
        id<MTLFunction> fn = [lib newFunctionWithName:fnName];
        if (!fn) continue;
        NSString *block = fmReflectFunction(fn, fnName, device);
        if (block.length > 0) {
            [out appendString:block];
            [out appendString:@"\n"];
            reflected++;
        } else {
            // Fallback: emit typed header so ShaderPage detects vertex/fragment → pulsanti B/R/G/V
            NSString *typeTag = (fn.functionType == MTLFunctionTypeFragment) ? @"fragment" : @"vertex";
            [out appendFormat:@"// ── %@: %@ ── (reflection non disponibile)\n", typeTag, fnName];
            reflected++;
        }
    }
    if (reflected == 0)
        [out appendString:@"// Nessun dato di reflection disponibile per questa libreria.\n"];
    return [out copy];
}

// ── Hook: newLibraryWithData:error: (precompiled .metallib binaries) ──────────
// Captures binary Metal libraries and displays function names in the UI.
// Color/flash patches are NOT available for binary libs (no MSL source).
// Depth/wallhack patches work via depth stencil override (source-independent).

static id<MTLLibrary> hooked_newLibraryWithData(id self, SEL _cmd,
                                                  dispatch_data_t data,
                                                  NSError **error) {
    if (!gCaptureBinaryLibs) return origNewLibraryData(self, _cmd, data, error);
    id<MTLLibrary> lib = origNewLibraryData(self, _cmd, data, error);
    if (!lib) return lib;

    NSArray<NSString *> *funcNames = [lib functionNames];
    if (funcNames.count == 0) return lib;

    // Stable hash: mix data size + XOR of first few function-name hashes
    NSUInteger fakeHash = dispatch_data_get_size(data);
    NSUInteger max = MIN(8, funcNames.count);
    for (NSUInteger i = 0; i < max; i++)
        fakeHash ^= ([funcNames[i] hash] >> i);
    NSNumber *hKey = @(fakeHash);
    NSUInteger h16 = fakeHash & 0xFFFF;

    // Placeholder shown immediately; AIR reflection runs in background and updates it.
    NSMutableString *placeholderSrc = [NSMutableString string];
    [placeholderSrc appendFormat:@"// METALLIB [%04lx] — reflection in corso...\n", (unsigned long)h16];
    [placeholderSrc appendString:@"// Funzioni:\n"];
    for (NSString *fn in funcNames)
        [placeholderSrc appendFormat:@"//   %@\n", fn];

    @synchronized(gHookLock) {
        capturedSources[hKey]   = placeholderSrc;
        // v1.0.35: do NOT store strong lib ref
    }
    objc_setAssociatedObject(lib, &kLibHashKey, hKey, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    static dispatch_once_t dataFuncHookOnce;
    dispatch_once(&dataFuncHookOnce, ^{
        Class cls = object_getClass(lib);
        Method m  = class_getInstanceMethod(cls, @selector(newFunctionWithName:));
        if (m && (!origNewFunction || method_getImplementation(m) != (IMP)hooked_newFunctionWithName)) {
            origNewFunction = (NewFuncIMP)method_getImplementation(m);
            method_setImplementation(m, (IMP)hooked_newFunctionWithName);
        }
        hookFuncConstMethods(lib);
    });

    NSString *firstName = funcNames.firstObject ?: @"binary_lib";
    NSString *dispName  = [NSString stringWithFormat:@"%@ [%04lx]", firstName, (unsigned long)h16];

    // Show placeholder immediately, then run AIR reflection in background
    dispatch_async(dispatch_get_main_queue(), ^{
        if (floatingMenu) [floatingMenu captureShaderWithName:dispName source:placeholderSrc error:nil libHash:hKey.unsignedIntegerValue];
    });

    // AIR reflection: runs on utility queue, never blocks Metal or main thread
    id<MTLDevice> devCapture = hookedDevice;
    id<MTLLibrary> libCapture = lib;
    NSArray<NSString *> *namesCapture = [funcNames copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *reflected = fmAirReflect(libCapture, devCapture, namesCapture, h16);
        if (!reflected) return;
        @synchronized(gHookLock) { capturedSources[hKey] = reflected; }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (floatingMenu) [floatingMenu captureShaderWithName:dispName source:reflected error:nil libHash:hKey.unsignedIntegerValue];
        });
    });

    return lib;
}

// ── Hook: parallelRenderCommandEncoderWithDescriptor: ────────────────────────
// Static C function replaces imp_implementationWithBlock (not reliable on LLVM clang)

// ── Hook: newLibraryWithURL:error: (Unreal Engine — pre-compiled .metallib) ──
static id<MTLLibrary>
hooked_newLibraryWithURL(id self, SEL _cmd, NSURL *url, NSError **error) {
    if (!gCaptureBinaryLibs) return origNewLibraryUrl(self, _cmd, url, error);
    id<MTLLibrary> lib = origNewLibraryUrl(self, _cmd, url, error);
    if (!lib) return lib;

    NSArray<NSString *> *funcNames = [lib functionNames];
    NSString *fileName = [url lastPathComponent] ?: @"unknown.metallib";

    NSUInteger fakeHash = [url.absoluteString hash];
    NSUInteger maxF = MIN(8, funcNames.count);
    for (NSUInteger i = 0; i < maxF; i++)
        fakeHash ^= ([funcNames[i] hash] >> i);
    NSNumber *hKey = @(fakeHash);
    NSUInteger h16url = fakeHash & 0xFFFF;

    NSString *firstNameUrl = funcNames.count > 0 ? funcNames.firstObject : fileName;
    NSString *dispName = [NSString stringWithFormat:@"%@ [%04lx]", firstNameUrl, (unsigned long)h16url];

    NSMutableString *placeholderUrl = [NSMutableString string];
    [placeholderUrl appendFormat:@"// METALLIB (URL) [%04lx] — %@ — reflection in corso...\n",
        (unsigned long)h16url, fileName];
    [placeholderUrl appendString:@"// Funzioni:\n"];
    for (NSString *fn in funcNames) [placeholderUrl appendFormat:@"//   %@\n", fn];

    BOOL isNew = NO;
    @synchronized(gHookLock) {
        if (!capturedSources[hKey]) {
            capturedSources[hKey]   = placeholderUrl;
            // v1.0.35: do NOT store strong lib ref
            isNew = YES;
        }
    }
    objc_setAssociatedObject(lib, &kLibHashKey, hKey, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    static dispatch_once_t urlFuncHookOnce;
    dispatch_once(&urlFuncHookOnce, ^{
        Class cls = object_getClass(lib);
        Method m  = class_getInstanceMethod(cls, @selector(newFunctionWithName:));
        if (m && (!origNewFunction || method_getImplementation(m) != (IMP)hooked_newFunctionWithName)) {
            origNewFunction = (NewFuncIMP)method_getImplementation(m);
            method_setImplementation(m, (IMP)hooked_newFunctionWithName);
        }
        hookFuncConstMethods(lib);
    });

    if (isNew) {
        NSString *nm = dispName;
        NSString *ph = [placeholderUrl copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (floatingMenu) [floatingMenu captureShaderWithName:nm source:ph error:nil libHash:hKey.unsignedIntegerValue];
        });
        id<MTLDevice> dev2 = hookedDevice;
        id<MTLLibrary> lib2 = lib;
        NSArray<NSString *> *names2 = [funcNames copy];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSString *reflected = fmAirReflect(lib2, dev2, names2, h16url);
            if (!reflected) return;
            @synchronized(gHookLock) { capturedSources[hKey] = reflected; }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (floatingMenu) [floatingMenu captureShaderWithName:nm source:reflected error:nil libHash:hKey.unsignedIntegerValue];
            });
        });
    }
    return lib;
}

// ── Shared helper: capture a library that has no source/data available ────────
// Used by newDefaultLibrary and newDefaultLibraryWithBundle:error: hooks.
static void captureDefaultLibrary(id<MTLLibrary> lib, NSString *label) {
    NSArray<NSString *> *funcNames = [lib functionNames];
    if (funcNames.count == 0) return;

    // Stable hash: XOR of function-name hashes (first 8)
    NSUInteger fakeHash = 0x44454641UL; // 'DEFA'
    NSUInteger maxF = MIN(8, funcNames.count);
    for (NSUInteger i = 0; i < maxF; i++)
        fakeHash ^= ([funcNames[i] hash] >> i);
    fakeHash ^= [label hash];
    NSNumber *hKey = @(fakeHash);
    NSUInteger h16 = fakeHash & 0xFFFF;

    NSString *firstName = funcNames.firstObject ?: label;
    NSString *dispName  = [NSString stringWithFormat:@"%@ [%04lx]", firstName, (unsigned long)h16];

    NSMutableString *placeholder = [NSMutableString string];
    [placeholder appendFormat:@"// DEFAULT METALLIB [%04lx] — %@ — reflection in corso...\n",
        (unsigned long)h16, label];
    [placeholder appendString:@"// Funzioni:\n"];
    for (NSString *fn in funcNames) [placeholder appendFormat:@"//   %@\n", fn];

    BOOL isNew = NO;
    @synchronized(gHookLock) {
        if (!capturedSources[hKey]) {
            capturedSources[hKey]   = placeholder;
            // v1.0.35: do NOT store strong lib ref
            isNew = YES;
        }
    }
    objc_setAssociatedObject(lib, &kLibHashKey, hKey, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    static dispatch_once_t defFuncHookOnce;
    dispatch_once(&defFuncHookOnce, ^{
        Class cls = object_getClass(lib);
        Method m  = class_getInstanceMethod(cls, @selector(newFunctionWithName:));
        if (m && (!origNewFunction || method_getImplementation(m) != (IMP)hooked_newFunctionWithName)) {
            origNewFunction = (NewFuncIMP)method_getImplementation(m);
            method_setImplementation(m, (IMP)hooked_newFunctionWithName);
        }
        hookFuncConstMethods(lib);
    });

    if (isNew) {
        NSString *nm = dispName;
        NSString *ph = [placeholder copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (floatingMenu) [floatingMenu captureShaderWithName:nm source:ph error:nil libHash:hKey.unsignedIntegerValue];
        });
        id<MTLDevice> dev3 = hookedDevice;
        id<MTLLibrary> lib3 = lib;
        NSArray<NSString *> *names3 = [funcNames copy];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSString *reflected = fmAirReflect(lib3, dev3, names3, h16);
            if (!reflected) return;
            @synchronized(gHookLock) { capturedSources[hKey] = reflected; }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (floatingMenu) [floatingMenu captureShaderWithName:nm source:reflected error:nil libHash:hKey.unsignedIntegerValue];
            });
        });
    }
}

// ── Hook: newDefaultLibrary (loads default.metallib from main bundle) ─────────
static id<MTLLibrary> hooked_newDefaultLibrary(id self, SEL _cmd) {
    id<MTLLibrary> lib = origNewDefaultLib ? origNewDefaultLib(self, _cmd) : nil;
    if (lib && gCaptureBinaryLibs) {
        captureDefaultLibrary(lib, @"default");
    }
    return lib;
}

// ── Hook: newDefaultLibraryWithBundle:error: ──────────────────────────────────
static id<MTLLibrary> hooked_newDefaultLibraryWithBundle(id self, SEL _cmd,
                                                          NSBundle *bundle,
                                                          NSError **error) {
    id<MTLLibrary> lib = origNewDefaultBundleLib
        ? origNewDefaultBundleLib(self, _cmd, bundle, error) : nil;
    if (lib && gCaptureBinaryLibs) {
        NSString *label = bundle.bundleIdentifier ?: bundle.bundlePath ?: @"?";
        captureDefaultLibrary(lib, label);
    }
    return lib;
}


static id hooked_parallelRenderCommandEncoder(id self, SEL _cmd, MTLRenderPassDescriptor *d) {
    if (!gHooksEnabled) return origParallelEnc ? origParallelEnc(self, _cmd, d) : nil;
    if (!origParallelEnc) return nil;
    id<MTLParallelRenderCommandEncoder> penc = origParallelEnc(self, _cmd, d);
    if (penc) {
        id<MTLRenderCommandEncoder> child = [penc renderCommandEncoder];
        if (child) hookEncClass(object_getClass(child));
    }
    return penc;
}

// ── Hook: commandBuffer → lazy path to get encoder class ─────────────────────

// Hook setRenderPipelineState: and setDepthStencilState: on an encoder class (once per class).
static void hookEncClass(Class cls) {
    if (!cls) return;
    fmLog([NSString stringWithFormat:@"[ENC] hookEncClass: trying %s", class_getName(cls)]);

    Method mp = class_getInstanceMethod(cls, @selector(setRenderPipelineState:));
    if (mp) {
        IMP cur = method_getImplementation(mp);
        if (cur != (IMP)hooked_setRenderPipelineState) {
            if (!origSetPipe) origSetPipe = (SetPipeIMP)cur;
            method_setImplementation(mp, (IMP)hooked_setRenderPipelineState);
            fmLog([NSString stringWithFormat:@"[ENC] hookEncClass: INSTALLED setRenderPipelineState on %s origSetPipe=%p",
                  class_getName(cls), (void*)origSetPipe]);
        } else {
            fmLog([NSString stringWithFormat:@"[ENC] hookEncClass: already hooked on %s", class_getName(cls)]);
        }
    } else {
        fmLog([NSString stringWithFormat:@"[ENC] hookEncClass: setRenderPipelineState NOT FOUND on %s", class_getName(cls)]);
    }

    Method md = class_getInstanceMethod(cls, @selector(setDepthStencilState:));
    if (md) {
        IMP cur = method_getImplementation(md);
        if (cur != (IMP)hooked_setDepthStencilState) {
            if (!origSetDepth) origSetDepth = (SetDepthIMP)cur;
            method_setImplementation(md, (IMP)hooked_setDepthStencilState);
        }
    }
}

static id<MTLCommandBuffer> hooked_commandBuffer(id self, SEL _cmd) {
    // v1.0.33: encInstallOnce BEFORE gHooksEnabled check — encoder hook must be installed
    // at first command buffer regardless of hook state so that when the user later enables
    // hooks the setRenderPipelineState hook is already in place.
    id<MTLCommandBuffer> buf = origCmdBuf(self, _cmd);
    if (buf) {
        // v1.0.40: dispatch method_setImplementation to MAIN THREAD.
        // Calling method_setImplementation from Metal's render thread (background) races
        // with ObjC method cache lookups on other threads → crash.
        // dispatch_async + dispatch_once ensures install happens once on main thread.
        // !origRenderEnc fast-check avoids dispatching a block every frame after install.
        if (!origRenderEnc) {
            Class cls = object_getClass(buf);
            static dispatch_once_t encInstallOnce;
            dispatch_async(dispatch_get_main_queue(), ^{
                dispatch_once(&encInstallOnce, ^{
                    Method m = class_getInstanceMethod(cls,
                        @selector(renderCommandEncoderWithDescriptor:));
                    if (m) {
                        origRenderEnc = (RenderEncIMP)method_getImplementation(m);
                        method_setImplementation(m, (IMP)hooked_renderCommandEncoder);
                    }
                    Method pm = class_getInstanceMethod(cls,
                        @selector(parallelRenderCommandEncoderWithDescriptor:));
                    if (pm) {
                        origParallelEnc = (ParallelEncIMP)method_getImplementation(pm);
                        method_setImplementation(pm, (IMP)hooked_parallelRenderCommandEncoder);
                    }
                });
            });
        }

        // ── LIVE filter: per-frame clear of active-hash set ──────────────────
        // Reset gLiveActiveHashes at the start of each command buffer so the
        // LIVE button always reflects CURRENTLY rendered shaders (this frame),
        // not stale shaders from earlier frames.
        //
        // Guard: only clear when origSetPipe is already installed.
        // Before the hook chain is complete (commandBuffer→renderCommandEncoder→
        // setRenderPipelineState), setRenderPipelineState hasn't fired yet.
        // Clearing before any hashes are added would leave the set empty for the
        // first LIVE press — exactly the v1.0.51 regression.
        // Once origSetPipe != NULL the hook is live and will repopulate within
        // this same command buffer, making the per-frame snapshot reliable.
        if (gHooksEnabled && origSetPipe) {
            @synchronized(gHookLock) {
                [gLiveActiveHashes removeAllObjects];
            }
        }
    }
    return buf;
}

// commandBufferWithUnretainedReferences hook — same per-frame clear as hooked_commandBuffer
static id<MTLCommandBuffer> hooked_commandBufferUR(id self, SEL _cmd) {
    id<MTLCommandBuffer> buf = origCmdBufUR(self, _cmd);
    if (buf && gHooksEnabled && origSetPipe) {
        @synchronized(gHookLock) { [gLiveActiveHashes removeAllObjects]; }
    }
    return buf;
}

// ── Deep patch reset (called on double-tap safe mode only) ────────────────────
//
// Clears ALL active patch state — both the C-level hash sets AND the compiled
// variant libraries.  After this call there is nothing left to swap in
// hooked_setRenderPipelineState, so re-enabling hooks is safe even if Metal
// has already freed / recreated the original pipeline objects.
void fmClearAllShaderPatches(void) {
    @synchronized(gHookLock) {
        [activeColorHashes  removeAllObjects];
        [flashHashes        removeAllObjects];
        [pipelinePatches    removeAllObjects];
        [pipelineGeneration removeAllObjects]; // invalidate any in-flight rebuildVariantsForHash
        [colorLibraries     removeAllObjects]; // release stale MTLLibrary objects
        [flashLibraries     removeAllObjects];
        @synchronized(gBuiltVariantPairs) { [gBuiltVariantPairs removeAllObjects]; }
        gPatchBuildGen++; // cancel all in-flight async variant builds
        // Also purge descriptor/hash tables: entries whose addresses are now stale
        // hold strong refs to MTLFunction/MTLLibrary objects and waste memory.
        [pipelineDescriptors removeAllObjects];
        [pipelineVertHash    removeAllObjects];
        [pipelineFragHash    removeAllObjects];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (flashTimer) { [flashTimer invalidate]; flashTimer = nil; }
        flashVisible = NO;
    });
    // Wipe NSUserDefaults so crash loop cannot restart on next launch.
    // Without this, _savedPatchCache reloads the activated shader on restart
    // → patchChangedHandler fires in-match → Metal variant build → crash again.
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"FMSavedPatches_v3"];
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"FMHooksEnabled"];
        [[NSUserDefaults standardUserDefaults] synchronize];
    });
    fmLog(@"[SAFETY] Tutti i patch shader azzerati (deep reset) — NSUserDefaults wipati");
}

// ── Live-active hash accessor (called from ShaderPage LIVE filter) ────────────

// Returns an immutable snapshot of the source hashes seen in the CURRENT frame.
// Thread-safe: snapshot is taken under gHookLock.
// Do NOT clear gLiveActiveHashes here — it is cleared per-frame in hooked_commandBuffer
// (once origSetPipe is installed) so that the snapshot always reflects THIS frame's
// actively rendered shaders, not an accumulated history from prior frames.
NSSet *fmCopyLiveActiveHashes(void) {
    @synchronized(gHookLock) {
        NSSet *snap;
        NSString *mode;
        if (origSetPipe && gLiveActiveHashes.count > 0) {
            // Primary path: setRenderPipelineState hook is live and populated this frame.
            snap = [gLiveActiveHashes copy];
            mode = @"frame";
        } else {
            // Fallback: hook not installed yet (origSetPipe=NIL) or frame set empty.
            // Return ALL fragment pipeline hashes compiled so far — every shader that
            // had a render pipeline compiled for it counts as "active".
            // Less precise than per-frame (shows all pipeline-compiled shaders, not just
            // current-frame ones), but guaranteed non-empty once pipelines exist.
            NSMutableSet *all = [NSMutableSet new];
            for (NSNumber *h in pipelineFragHash.allValues) {
                if (h) [all addObject:h];
            }
            snap = [all copy];
            mode = origSetPipe ? @"allPipes(emptyFrame)" : @"allPipes(noHook)";
        }
        fmLog([NSString stringWithFormat:
            @"[LIVE] snapshot: %lu hash(es), origSetPipe=%s mode=%@",
            (unsigned long)snap.count, origSetPipe ? "OK" : "NIL", mode]);
        return snap;
    }
}

// ── Master switch API (called from FloatingMenu UI) ───────────────────────────

void fmSetHooksEnabled(BOOL enabled) {
    gHooksEnabled      = enabled;
    gCaptureSourceLibs = enabled; // always move together — both off = safe startup
    // Persist so next launch restores same state
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:@"FMHooksEnabled"];
    [[NSUserDefaults standardUserDefaults] synchronize]; // flush immediately (crash safety)
    if (!enabled) {
        // Deactivate all active patches in memory under lock
        @synchronized(gHookLock) {
            [activeColorHashes removeAllObjects];
            [flashHashes removeAllObjects];
            [pipelinePatches removeAllObjects];
        }

        // Stop flash timer on main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            if (flashTimer) { [flashTimer invalidate]; flashTimer = nil; }
            flashVisible = NO;
        });
        NSLog(@"[FM] hooks DISABLED — pass-through attivo");
        fmLog(@"[HOOKS] Disattivati — tutti i patch in memoria azzerati");
        fmLog(@"[HOOKS] Le librerie compilate sono preservate (riattiva dal pannello)");
    } else {
        NSLog(@"[FM] hooks ENABLED");
        fmLog(@"[HOOKS] Attivati — riabilita i shader che vuoi dal pannello");
    }
}

BOOL fmGetHooksEnabled(void) {
    return gHooksEnabled;
}

// ── Install all hooks ─────────────────────────────────────────────────────────

static void installHooks(id<MTLDevice> device) {
    hookedDevice = device;
    Class dCls = [device class];

    // 1a. newLibraryWithSource:options:error: (synchronous)
    {
        Method m = class_getInstanceMethod(dCls, @selector(newLibraryWithSource:options:error:));
        if (m) { origNewLibrary = (LibIMP)method_getImplementation(m);
                 method_setImplementation(m, (IMP)hooked_newLibraryWithSource); }
    }
    // 1b. newLibraryWithSource:options:completionHandler: (async — used by MoltenVK/R6)
    {
        Method m = class_getInstanceMethod(dCls, @selector(newLibraryWithSource:options:completionHandler:));
        if (m) { origNewLibraryAsync = (LibAsyncIMP)method_getImplementation(m);
                 method_setImplementation(m, (IMP)hooked_newLibraryWithSourceAsync); }
    }
    // 1c. newLibraryWithData:error: (precompiled .metallib binaries)
    {
        Method m = class_getInstanceMethod(dCls, @selector(newLibraryWithData:error:));
        if (m) { origNewLibraryData = (LibDataIMP)method_getImplementation(m);
                 method_setImplementation(m, (IMP)hooked_newLibraryWithData); }
    }
    // 1d. newLibraryWithURL:error: (Unreal Engine loads .metallib from disk)
    {
        Method m = class_getInstanceMethod(dCls, @selector(newLibraryWithURL:error:));
        if (m) { origNewLibraryUrl = (LibUrlIMP)method_getImplementation(m);
                 method_setImplementation(m, (IMP)hooked_newLibraryWithURL); }
    }
    // 1e. newDefaultLibrary (loads default.metallib from main bundle — Unity, custom engines)
    {
        Method m = class_getInstanceMethod(dCls, @selector(newDefaultLibrary));
        if (m) { origNewDefaultLib = (LibDefaultIMP)method_getImplementation(m);
                 method_setImplementation(m, (IMP)hooked_newDefaultLibrary); }
    }
    // 1f. newDefaultLibraryWithBundle:error: (loads from framework/plugin bundle)
    {
        Method m = class_getInstanceMethod(dCls, @selector(newDefaultLibraryWithBundle:error:));
        if (m) { origNewDefaultBundleLib = (LibDefaultBundleIMP)method_getImplementation(m);
                 method_setImplementation(m, (IMP)hooked_newDefaultLibraryWithBundle); }
    }
    // 2a. newRenderPipelineStateWithDescriptor:error: (synchronous)
    {
        Method m = class_getInstanceMethod(dCls, @selector(newRenderPipelineStateWithDescriptor:error:));
        if (m) { origNewPipeline = (PipeIMP)method_getImplementation(m);
                 method_setImplementation(m, (IMP)hooked_newRenderPipelineState); }
    }
    // 2b. newRenderPipelineStateWithDescriptor:completionHandler: (async — R6/MoltenVK)
    {
        Method m = class_getInstanceMethod(dCls,
            @selector(newRenderPipelineStateWithDescriptor:completionHandler:));
        if (m) { origNewPipelineAsync = (PipeAsyncIMP)method_getImplementation(m);
                 method_setImplementation(m, (IMP)hooked_newRenderPipelineStateAsync); }
    }
    // 3. commandBuffer / renderCommandEncoderWithDescriptor / setRenderPipelineState
    {
        id<MTLCommandQueue> q = [device newCommandQueue];
        if (q) {
            // 3a. Create temp cmd buffer BEFORE hooking commandBuffer, so we get the real class.
            id<MTLCommandBuffer> tmpBuf = [q commandBuffer];

            Class qCls = object_getClass(q);
            // Hook commandBuffer (base path)
            {
                Method m = class_getInstanceMethod(qCls, @selector(commandBuffer));
                if (m) { origCmdBuf = (CmdBufIMP)method_getImplementation(m);
                         method_setImplementation(m, (IMP)hooked_commandBuffer); }
            }
            // Hook commandBufferWithUnretainedReferences (UE4 perf path — used instead of commandBuffer)
            {
                Method m = class_getInstanceMethod(qCls, @selector(commandBufferWithUnretainedReferences));
                if (m) { origCmdBufUR = (CmdBufIMP)method_getImplementation(m);
                         method_setImplementation(m, (IMP)hooked_commandBufferUR); }
            }

            // 3b. Install renderCommandEncoderWithDescriptor: SYNCHRONOUSLY on the cmd buffer class.
            // This ensures the hook is active even if the game never calls plain -commandBuffer
            // (e.g. uses commandBufferWithUnretainedReferences), so hooked_commandBuffer's lazy path
            // would never fire. Installing it now on the CLASS covers all command buffer instances.
            if (tmpBuf) {
                Class bufCls = object_getClass(tmpBuf);
                Method me = class_getInstanceMethod(bufCls, @selector(renderCommandEncoderWithDescriptor:));
                if (me && !origRenderEnc) {
                    origRenderEnc = (RenderEncIMP)method_getImplementation(me);
                    method_setImplementation(me, (IMP)hooked_renderCommandEncoder);
                    NSLog(@"[FM] installHooks: renderCommandEncoder INSTALLED on %s", class_getName(bufCls));
                }
                Method pm = class_getInstanceMethod(bufCls, @selector(parallelRenderCommandEncoderWithDescriptor:));
                if (pm && !origParallelEnc) {
                    origParallelEnc = (ParallelEncIMP)method_getImplementation(pm);
                    method_setImplementation(pm, (IMP)hooked_parallelRenderCommandEncoder);
                }
            }
        }
    }
    // 4. Build wallhack depth stencil state (compareFunctionAlways, depthWrite=NO)
    {
        MTLDepthStencilDescriptor *dsd = [MTLDepthStencilDescriptor new];
        dsd.depthCompareFunction = MTLCompareFunctionAlways;
        dsd.depthWriteEnabled    = NO;
        gWallhackDepthState = [device newDepthStencilStateWithDescriptor:dsd];
    }
}

// ── Constructor ───────────────────────────────────────────────────────────────

__attribute__((constructor))
static void lc_init() {
    @autoreleasepool {
    NSLog(@"[FM] lc_init start");
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    NSLog(@"[FM] bid=%@", bid);
    // Bundle filter handled by .plist — no hardcoded check needed

    // ── Install crash diagnostics (before anything else) ──────────────────────
    // Also detect previous crash via flag file and reset hooks to OFF if found.
    NSString *libDir = nil;
    {
        NSArray *libs = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
        libDir = [libs firstObject];
        NSString *logPath  = [libDir stringByAppendingPathComponent:@"FloatingMenuLog.txt"];
        NSString *flagPath = [libDir stringByAppendingPathComponent:@"FMCrashedFlag"];

        gCrashLogFD = open([logPath fileSystemRepresentation], O_WRONLY | O_CREAT | O_APPEND, 0644);

        // ── Crash flag check ─────────────────────────────────────────────────
        // We use a flag file whose CONTENT indicates a crash:
        //   • Empty (or absent): previous session exited cleanly (or first launch).
        //   • Non-empty ("1"): signal handler wrote before process was killed → crash.
        //
        // We read BEFORE opening with O_TRUNC so we see the previous session's content.
        // The FD stays open for the ENTIRE session so the signal handler can write at
        // any time (not just within the first 6s). This catches late-match crashes too.
        NSData *flagContent = [NSData dataWithContentsOfFile:flagPath];
        if (flagContent.length > 0) {
            NSLog(@"[FM] ⚠️ Crash flag rilevato (sessione precedente crashata) — solo log, stato utente preservato");
        }
        // Open with O_TRUNC → clears previous crash marker. FD kept open until process ends.
        gCrashFlagFD = open([flagPath fileSystemRepresentation], O_WRONLY | O_CREAT | O_TRUNC, 0644);

        struct sigaction sa;
        sa.sa_sigaction = fmSignalHandler;
        sigemptyset(&sa.sa_mask);
        sa.sa_flags = SA_SIGINFO | SA_RESETHAND;
        sigaction(SIGSEGV, &sa, NULL);
        sigaction(SIGBUS,  &sa, NULL);
        sigaction(SIGILL,  &sa, NULL);
        sigaction(SIGABRT, &sa, NULL);
        NSSetUncaughtExceptionHandler(fmExceptionHandler);
    }

    // ── Hook startup state ─────────────────────────────────────────────────────
    // Semplice: ripristina esattamente lo stato che l'utente ha lasciato.
    // ON → rimane ON. OFF → rimane OFF. Nient'altro.
    NSUserDefaults *hookUD = [NSUserDefaults standardUserDefaults];
    BOOL savedHooks = [hookUD boolForKey:@"FMHooksEnabled"];
    gHooksEnabled      = savedHooks;
    gCaptureSourceLibs = YES;

    gHookLock           = [[NSObject alloc] init];
    capturedSources     = [[NSMutableDictionary alloc] init];
    capturedSourceNames = [[NSMutableDictionary alloc] init];
    capturedLibraries   = [[NSMutableDictionary alloc] init];
    capturedOptions     = [[NSMutableDictionary alloc] init];
    colorLibraries      = [[NSMutableDictionary alloc] init];
    flashLibraries      = [[NSMutableDictionary alloc] init];
    pipelinePatches     = [[NSMutableDictionary alloc] init];
    pipelineFragHash    = [[NSMutableDictionary alloc] init];
    pipelineVertHash      = [[NSMutableDictionary alloc] init];
    pipelineDescriptors   = [[NSMutableDictionary alloc] init];
    pipelineDescByFragHash = [[NSMutableDictionary alloc] init];
    pipelineGeneration  = [[NSMutableDictionary alloc] init];
    flashHashes         = [[NSMutableSet alloc] init];
    activeColorHashes   = [[NSMutableSet alloc] init];
    gLiveActiveHashes   = [[NSMutableSet alloc] init];
    gBuiltVariantPairs  = [[NSMutableSet alloc] init];
    NSLog(@"[FM] dizionari inizializzati");

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    NSLog(@"[FM] device=%@", device);
    if (device) installHooks(device);
    NSLog(@"[FM] hook installati");

    // ── Clear pipelinePatches when app goes to background / home button ─────────
    // This prevents stale variant pipeline states (built for match shaders) from
    // being used when the game returns from background and reuses pipeline-state
    // addresses. activeColorHashes / colorLibraries are preserved so patches
    // re-apply transparently when new pipelines are created on resume.
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationWillResignActiveNotification
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification *note) {
        @synchronized(gHookLock) {
            // Clear TUTTI i dizionari pipeline — non solo patches.
            // pipelineDescriptors/VertHash/FragHash tengono forti riferimenti a
            // MTLFunction/MTLLibrary del gioco che vengono liberati a fine partita.
            // Se non puliti, hooked_newRenderPipelineState accede a oggetti stale
            // → EXC_BAD_ACCESS al caricamento della lobby.
            [pipelinePatches     removeAllObjects];
            [pipelineGeneration  removeAllObjects];
            [pipelineDescriptors removeAllObjects];
            [pipelineVertHash    removeAllObjects];
            [pipelineFragHash    removeAllObjects];
        }
        fmLog(@"[SYS] WillResignActive — tutti i dizionari pipeline svuotati");
    }];

    // ── Memory warning: rilascia subito i descriptor per permettere al gioco di ───
    // liberare le sue MTLLibrary prima che iOS uccida il processo (Jetsam/OOM).
    // activeColorHashes e colorLibraries vengono preservati per riapplicare i patch.
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidReceiveMemoryWarningNotification
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification *note) {
        @synchronized(gHookLock) {
            [pipelinePatches     removeAllObjects];
            [pipelineDescriptors removeAllObjects];
            [pipelineVertHash    removeAllObjects];
            [pipelineFragHash    removeAllObjects];
            [pipelineGeneration  removeAllObjects];
        }
        fmLog(@"[SYS] MemoryWarning — pipeline dicts cleared (anti-Jetsam)");
    }];

    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        if (menuInstalled) return;
        menuInstalled = YES;
        floatingMenu  = [[FloatingMenu alloc] init];

        // ── Replay shaders captured before menu was ready ──────────────────
        // newLibraryWithSource hooks are always-on (gCaptureSourceLibs=YES), so
        // the big MSL compilation burst during match loading fires BEFORE the menu
        // exists. The data is stored in capturedSources/capturedSourceNames but the
        // dispatch_async(main_queue, ^{ if (floatingMenu) ... }) was a no-op then.
        // Replay everything now so the user sees the full shader list immediately.
        {
            NSArray *replayKeys = nil;
            @synchronized(gHookLock) { replayKeys = [capturedSourceNames allKeys]; }
            NSUInteger n = 0;
            for (NSNumber *k in replayKeys) {
                NSString *nm  = nil, *src = nil;
                @synchronized(gHookLock) {
                    nm  = capturedSourceNames[k];
                    src = capturedSources[k];
                }
                if (nm && src) {
                    [floatingMenu captureShaderWithName:nm source:src error:nil libHash:k.unsignedIntegerValue];
                    n++;
                }
            }
            if (n > 0)
                [floatingMenu addLog:[NSString stringWithFormat:
                    @"[INFO] %lu shader MSL catturati durante il loading — visibili ora", (unsigned long)n]];
        }

        __weak FloatingMenu *wm = floatingMenu;
        floatingMenu.shaderPage.patchChangedHandler = ^(ShaderEntry *entry) {
            if (!wm) return;
            MTLCompileOptions *opts = [MTLCompileOptions new];
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                applyPatchesForEntry(entry, opts);
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSString *info = [NSString stringWithFormat:
                        @"[PATCH] %@  R:%d G:%d B:%d ⚡:%d V:%d",
                        entry.name,
                        entry.patchFragColor == FragPatchRed,
                        entry.patchFragColor == FragPatchGreen,
                        entry.patchFragColor == FragPatchBlue,
                        entry.patchFlash, entry.patchVertex];
                    [wm addLog:info];
                });
            });
        };

        [floatingMenu show];
        [floatingMenu addLog:@"[INFO] Menu attivato"];
        fmShowPreCrashLog(); // show logs from crash in previous session

        // Auto-enable REMOVED — causes crash in UE4 games (Battle Prime).
        // UE4 compiles hundreds of pipelines for 10-30s after app launch.
        // Enabling pipeline hooks during this phase (even at 3s) crashes the GPU driver.
        // User must enable manually from the UI after the game fully loads.
        // The crash flag system (gCrashFlagFD) auto-resets hooks to OFF after any crash.
    }];
    NSLog(@"[FM] lc_init done");
    } // @autoreleasepool
}
