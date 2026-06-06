#import "SDKCompat.h"
#import "FloatingMenu.h"
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <signal.h>
#include <unistd.h>
#include <string.h>
#include <fcntl.h>

// ── Crash diagnostics ─────────────────────────────────────────────────────────
// Pre-opened FD so signal handler (async-signal-safe) can write without ObjC.
static int gCrashLogFD = -1;

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
}

static FloatingMenu *floatingMenu  = nil;
static BOOL          menuInstalled = NO;

// ── Patch state ───────────────────────────────────────────────────────────────

static id<MTLDevice>       hookedDevice         = nil;
static NSMutableSet       *gBuiltVariantPairs  = nil; // "fHash|vHash" — dedup in-match burst
static _Atomic(uint64_t)   gPatchBuildGen       = 0;  // increments on clear → cancels in-flight async builds
static NSMutableDictionary *capturedSources     = nil; // @(hash) → NSString
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

static LibIMP       origNewLibrary      = NULL;
static LibAsyncIMP  origNewLibraryAsync = NULL;
static LibDataIMP   origNewLibraryData  = NULL;
static LibUrlIMP     origNewLibraryUrl  = NULL;
static NewFuncIMP          origNewFunction          = NULL;
static NewFuncConstIMP     origNewFunctionConst     = NULL;
static NewFuncConstAsyncIMP origNewFunctionConstAsync = NULL;
static PipeIMP      origNewPipeline     = NULL;
static PipeAsyncIMP origNewPipelineAsync = NULL;
static CmdBufIMP    origCmdBuf          = NULL;
static RenderEncIMP origRenderEnc       = NULL;
static SetPipeIMP   origSetPipe         = NULL;
static SetDepthIMP  origSetDepth        = NULL;
static ParallelEncIMP origParallelEnc   = NULL;

// Wallhack: depth stencil state with compareFunctionAlways + no depth write
static id<MTLDepthStencilState> gWallhackDepthState = nil;
// Set to YES when the currently-bound pipeline uses a vertex patch (per render thread)
// gVertexPatchActive removed — replaced by per-encoder kVertPatchKey associated object (see hooked_setRenderPipelineState)

// ── Master hooks switch ────────────────────────────────────────────────────────
// Default OFF: all hooks are pass-through until user enables from UI.
// Prevents crash-on-startup from shader hooks firing before the menu is ready.
static _Atomic(BOOL) gHooksEnabled = NO;

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

// Forward declaration — defined later, after the pipeline-state hook helpers
static id<MTLRenderPipelineState> buildVariantPipeline(id device,
                                                        MTLRenderPipelineDescriptor *base,
                                                        id<MTLLibrary> vLib,
                                                        id<MTLLibrary> fLib);

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

    NSInteger colorBuilt = 0, flashBuilt = 0, noDesc = 0;
    NSMutableDictionary *newPatches = [NSMutableDictionary dictionary];
    NSMutableSet *seenFmts = [NSMutableSet set]; // collect render-target formats for log

    for (NSValue *pk in pipeKeys) {
        MTLRenderPipelineDescriptor *desc = snapDesc[pk];
        if (!desc) { noDesc++; continue; }
        // Collect color attachment format for diagnostics
        MTLPixelFormat pf = desc.colorAttachments[0].pixelFormat;
        [seenFmts addObject:fmFmtName(pf)];

        NSNumber *fh = snapFH[pk];
        NSNumber *vh = snapVH[pk];
        NSMutableDictionary *variants = snapVariants[pk] ?: [NSMutableDictionary dictionary];

        BOOL colorActive = (fh && [snapColorHashes containsObject:fh]) ||
                           (vh && [snapColorHashes containsObject:vh]);
        if (colorActive) {
            id<MTLLibrary> cvLib = vh ? snapColorLibV[vh] : nil;
            id<MTLLibrary> cfLib = fh ? snapColorLibF[fh] : nil;
            if (cvLib || cfLib) {
                id<MTLRenderPipelineState> cp = buildVariantPipeline(hookedDevice, desc, cvLib, cfLib);
                if (cp) { variants[@"color"] = cp; colorBuilt++; }
            }
        } else {
            [variants removeObjectForKey:@"color"];
        }

        if (fh && [snapFlashHashes containsObject:fh]) {
            id<MTLLibrary> flLib = snapFlashLib[fh];
            if (flLib) {
                id<MTLRenderPipelineState> fp = buildVariantPipeline(hookedDevice, desc, nil, flLib);
                if (fp) { variants[@"flash"] = fp; flashBuilt++; }
            }
        } else {
            [variants removeObjectForKey:@"flash"];
        }
        if (variants.count > 0) {
            newPatches[pk] = variants;
        }
        // keys NOT added to newPatches → variants were cleared → must be removed
    }

    // Write results back under lock.
    // CRITICAL: before writing, check that the generation counter for each pKey hasn't
    // changed. If it changed, hooked_newRenderPipelineState registered a NEW pipeline at
    // that address (address reuse after scene transition). Our variant was built for the OLD
    // pipeline descriptor — writing it would put a stale/incompatible variant in
    // pipelinePatches, which crashes Metal when setRenderPipelineState: uses it.
    NSUInteger descReleased = 0;
    @synchronized(gHookLock) {
        for (NSValue *pk in newPatches) {
            if (![pipelineGeneration[pk] isEqual:snapGen[pk]]) continue; // address reused → skip
            pipelinePatches[pk] = newPatches[pk];
            // MTLRenderPipelineState compiled → descriptor is no longer needed for THIS pipeline.
            // MTLRenderPipelineState is a self-contained GPU binary and does NOT retain the source
            // MTLFunction objects after compilation. Releasing the descriptor copy here drops our
            // only strong reference to the game's MTLFunction→MTLLibrary, allowing the OS to free
            // those shader libraries when the game releases its own references (anti-Jetsam/OOM).
            if (pipelineDescriptors[pk]) {
                // Release only the descriptor (holds game's MTLFunction refs → anti-OOM).
                // pipelineFragHash/VertHash are kept: hooked_setRenderPipelineState needs
                // them for the colorOn/isFlash check on every draw call.
                [pipelineDescriptors removeObjectForKey:pk];
                descReleased++;
            }
        }
        for (NSValue *pk in pipeKeys) {
            if (![pipelineGeneration[pk] isEqual:snapGen[pk]]) continue; // address reused → skip
            if (!newPatches[pk]) [pipelinePatches removeObjectForKey:pk];
        }
    }
    if (descReleased > 0)
        fmLog([NSString stringWithFormat:@"[SYS] %lu descriptor rilasciati post-build (anti-OOM)", (unsigned long)descReleased]);

    NSString *fmtsStr = seenFmts.count ? [seenFmts.allObjects componentsJoinedByString:@","] : @"?";
    NSString *msg = [NSString stringWithFormat:
        @"[REBUILD] hash=%04lx  pipe:%lu  color:%ld  flash:%ld  noDesc:%ld  fmt=%@",
        (unsigned long)(hash.unsignedIntegerValue & 0xFFFF),
        (unsigned long)pipeKeys.count, colorBuilt, flashBuilt, noDesc, fmtsStr];
    dispatch_async(dispatch_get_main_queue(), ^{ if (floatingMenu) [floatingMenu addLog:msg]; });
}

// ── Update patches for entry (called from UI on background queue) ─────────────

static void applyPatchesForEntry(ShaderEntry *entry, MTLCompileOptions *opts) {
    NSNumber *hashKey = @(entry.sourceHash);
    BOOL hasColor = (entry.patchFragColor != FragPatchNone) || entry.patchVertex;
    BOOL hasFlash = entry.patchFlash;

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
        NSString *src = buildPatchedSource(entry);
        BOOL injectWorked = ![src isEqualToString:entry.source];

        id<MTLLibrary> lib = nil;

        if (injectWorked) {
            // Normal MSL inject succeeded — compile the modified source
            lib = compileDirect(src, origOpts);
            if (lib) {
                NSString *logMsg = [NSString stringWithFormat:@"[COMPILE] %@ color=%@ → OK ✓", entry.name, colorPatchName];
                dispatch_async(dispatch_get_main_queue(), ^{ if (floatingMenu) [floatingMenu addLog:logMsg]; });
            } else if (entry.patchFragColor != FragPatchNone) {
                // MSL compile failed (UE shaders can be complex) — fall back to const-color replacement.
                // This guarantees the patch is visible even when inject produces invalid MSL.
                float r=0,g=0,b=0;
                if (entry.patchShadeOverride) {
                    r = entry.patchShadeR; g = entry.patchShadeG; b = entry.patchShadeB;
                } else if (entry.patchFragColor==FragPatchRed)   { r=1.0f; }
                else if   (entry.patchFragColor==FragPatchGreen) { g=0.9f; b=0.2f; }
                else if   (entry.patchFragColor==FragPatchBlue)  { r=0.2f; g=0.5f; b=1.0f; }
                lib = FM_CONST_FRAG(r, g, b, "fmColorPatch");
                NSString *logMsg = [NSString stringWithFormat:@"[COMPILE] %@ color=%@ → FAIL, usando const-color", entry.name, colorPatchName];
                dispatch_async(dispatch_get_main_queue(), ^{ if (floatingMenu) [floatingMenu addLog:logMsg]; });
            }

        } else if (entry.patchFragColor != FragPatchNone) {
            // Binary IR / non-MSL: inject failed for fragment color patch.
            // Use a const-color replacement fragment shader ("fmColorPatch").
            float r=0,g=0,b=0;
            if (entry.patchShadeOverride) {
                r = entry.patchShadeR; g = entry.patchShadeG; b = entry.patchShadeB;
            } else if (entry.patchFragColor==FragPatchRed)   { r=1.0f; }
            else if   (entry.patchFragColor==FragPatchGreen) { g=0.9f; b=0.2f; }
            else if   (entry.patchFragColor==FragPatchBlue)  { r=0.2f; g=0.5f; b=1.0f; }
            lib = FM_CONST_FRAG(r, g, b, "fmColorPatch");
            NSString *status = lib ? @"OK ✓ (const-color)" : @"FAIL ✗";
            NSString *logMsg = [NSString stringWithFormat:@"[COMPILE] %@ color=%@ → %@",
                entry.name, colorPatchName, status];
            dispatch_async(dispatch_get_main_queue(), ^{ if (floatingMenu) [floatingMenu addLog:logMsg]; });

        } else if (entry.patchVertex) {
            // Binary IR + vertex-only patch: no shader library needed.
            // gVertexPatchActive is set directly in hooked_setRenderPipelineState
            // when the pipeline's vHash is in activeColorHashes.
            @synchronized(gHookLock) { [activeColorHashes addObject:hashKey]; }
            fmLog([NSString stringWithFormat:@"[PATCH-V] %@ depth-override ON (binary IR)", entry.name]);
        }

        if (lib) {
            objc_setAssociatedObject(lib, &kLibHashKey, hashKey, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            @synchronized(gHookLock) {
                colorLibraries[hashKey] = lib;
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
        NSString *flashSrc = injectFragColor(entry.source, 1.0f, 0.88f, 0.0f);
        BOOL flashInjectWorked = ![flashSrc isEqualToString:entry.source];
        id<MTLLibrary> flib = nil;
        if (flashInjectWorked) {
            flib = compileDirect(flashSrc, origOpts);
        } else {
            // Binary IR: use const-color yellow replacement
            flib = FM_CONST_FRAG(1.0f, 0.88f, 0.0f, "fmFlashPatch");
        }
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
    // Reset variant-dedup so hooked_newRenderPipelineState will build a fresh
    // variant for new pipelines created after this patch change.
    @synchronized(gBuiltVariantPairs) { [gBuiltVariantPairs removeAllObjects]; }
    rebuildVariantsForHash(hashKey);
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
        if (!capturedLibraries[hKey]) {
            capturedLibraries[hKey] = lib;
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
            if (floatingMenu) [floatingMenu captureShaderWithName:dispName source:srcCopy error:nil];
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
    static dispatch_once_t constHookOnce;
    dispatch_once(&constHookOnce, ^{
        Class cls = object_getClass(lib);
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
    origSetPipe(self, _cmd, toUse);
    } // @autoreleasepool
}

// ── Hook: renderCommandEncoderWithDescriptor: (lazy encoder hook) ─────────────

static id<MTLRenderCommandEncoder> hooked_renderCommandEncoder(id self, SEL _cmd,
                                                                MTLRenderPassDescriptor *desc) {
    if (!gHooksEnabled) return origRenderEnc(self, _cmd, desc);
    id<MTLRenderCommandEncoder> enc = origRenderEnc(self, _cmd, desc);
    static dispatch_once_t encHookOnce;
    if (enc) dispatch_once(&encHookOnce, ^{ hookEncClass(object_getClass(enc)); });
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
                // Library never tagged — assign hash and capture it
                libHash = lateTagLibrary(fLib);
                // Ensure newFunctionWithName: hook is installed on this class
                // (may be a different Metal private class than vertex library)
                Class cls = object_getClass(fLib);
                Method m = class_getInstanceMethod(cls, @selector(newFunctionWithName:));
                if (m && (!origNewFunction ||
                          method_getImplementation(m) != (IMP)hooked_newFunctionWithName)) {
                    origNewFunction = (NewFuncIMP)method_getImplementation(m);
                    method_setImplementation(m, (IMP)hooked_newFunctionWithName);
                }
                hookFuncConstMethods(fLib);
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
        pipelineDescriptors[pKey] = [desc copy];
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
                        [pipelineDescriptors removeObjectForKey:k];
                        [pipelineVertHash    removeObjectForKey:k];
                        [pipelineFragHash    removeObjectForKey:k];
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
            cvLib = vHash ? colorLibraries[vHash] : nil;
            cfLib = fHash ? colorLibraries[fHash] : nil;
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

            // Abort if kill switch fired while waiting
            if (gPatchBuildGen != genAtCapture) {
                fmLog([NSString stringWithFormat:@"[ASYNC BUILD] annullato (kill) %@", pairKey]);
                return;
            }

            NSMutableDictionary *variants = [NSMutableDictionary dictionary];
            if (colorNowCopy && (cvLibCopy || cfLibCopy)) {
                id<MTLRenderPipelineState> cp = buildVariantPipeline(selfDevice, descCopy, cvLibCopy, cfLibCopy);
                if (cp) variants[@"color"] = cp;
            }
            if (flLibCopy) {
                id<MTLRenderPipelineState> fp = buildVariantPipeline(selfDevice, descCopy, nil, flLibCopy);
                if (fp) variants[@"flash"] = fp;
            }
            if (variants.count == 0) return;

            // Final cancellation + address-reuse guard before writing
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
                    @"[ASYNC BUILD â] color:%d flash:%d frag=%04lx vert=%04lx",
                    variants[@"color"]!=nil, variants[@"flash"]!=nil,
                    (unsigned long)(fHashCopy ? fHashCopy.unsignedIntegerValue & 0xFFFF : 0),
                    (unsigned long)(vHashCopy ? vHashCopy.unsignedIntegerValue & 0xFFFF : 0)];
                dispatch_async(dispatch_get_main_queue(), ^{ if (floatingMenu) [floatingMenu addLog:msg]; });
            }
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
                            Class cls = object_getClass(fLib);
                            Method m2 = class_getInstanceMethod(cls, @selector(newFunctionWithName:));
                            if (m2 && (!origNewFunction ||
                                       method_getImplementation(m2) != (IMP)hooked_newFunctionWithName)) {
                                origNewFunction = (NewFuncIMP)method_getImplementation(m2);
                                method_setImplementation(m2, (IMP)hooked_newFunctionWithName);
                            }
                            hookFuncConstMethods(fLib);
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
                    @synchronized(gHookLock) {
                        // Clear stale variant + bump generation (same logic as sync hook)
                        if (pipelinePatches[pKey]) [pipelinePatches removeObjectForKey:pKey];
                        NSUInteger gen = [pipelineGeneration[pKey] unsignedIntegerValue] + 1;
                        pipelineGeneration[pKey] = @(gen);
                        if (vHash) pipelineVertHash[pKey]  = vHash;
                        if (fHash) pipelineFragHash[pKey]  = fHash;
                        pipelineDescriptors[pKey] = [desc copy];
                    }
                    // Variants are built lazily when the user toggles a patch
                    // (rebuildVariantsForHash is called from ShaderPage UI).
                    NSString *msg = [NSString stringWithFormat:
                        @"[PIPE ASYNC] tracked frag=%04lx vert=%04lx",
                        (unsigned long)(fHash ? fHash.unsignedIntegerValue & 0xFFFF : 0),
                        (unsigned long)(vHash ? vHash.unsignedIntegerValue & 0xFFFF : 0)];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (floatingMenu) [floatingMenu addLog:msg];
                    });
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
    if (!gHooksEnabled) return origNewLibrary(self, _cmd, source, options, error);
    id<MTLLibrary> lib = origNewLibrary(self, _cmd, source, options, error);
    if (!lib) return lib;

    NSString   *errStr = (error && *error) ? (*error).localizedDescription : nil;
    NSString   *name   = descriptiveShaderName(source);
    NSUInteger  hash   = [source hash];
    NSNumber   *hKey   = @(hash);

    // Lock: multiple Metal threads may call newLibraryWithSource: concurrently
    @synchronized(gHookLock) {
        capturedSources[hKey]   = source;
        capturedLibraries[hKey] = lib;
        if (options) capturedOptions[hKey] = options;
    }
    // Tag the library → functions will inherit the hash via hooked_newFunctionWithName
    objc_setAssociatedObject(lib, &kLibHashKey, hKey, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // Hook newFunctionWithName: once — dispatch_once is thread-safe, static BOOL is not
    static dispatch_once_t funcHookOnce;
    dispatch_once(&funcHookOnce, ^{
        Class cls = object_getClass(lib);
        Method m  = class_getInstanceMethod(cls, @selector(newFunctionWithName:));
        if (m) {
            origNewFunction = (NewFuncIMP)method_getImplementation(m);
            method_setImplementation(m, (IMP)hooked_newFunctionWithName);
        }
        hookFuncConstMethods(lib);
    });

    dispatch_async(dispatch_get_main_queue(), ^{
        if (floatingMenu) [floatingMenu captureShaderWithName:name source:source error:errStr];
    });
    return lib;
}

// ── Hook: newLibraryWithSource:options:completionHandler: (async variant) ─────
// Some engines (e.g. MoltenVK / R6 Mobile) use the async version.

static void hooked_newLibraryWithSourceAsync(id self, SEL _cmd,
                                              NSString *source,
                                              MTLCompileOptions *options,
                                              MTLNewLibraryCompletionHandler handler) {
    if (!gHooksEnabled) { origNewLibraryAsync(self, _cmd, source, options, handler); return; }
    MTLNewLibraryCompletionHandler wrapped = ^(id<MTLLibrary> lib, NSError *err) {
        if (lib && source.length > 0) {
            NSString   *name = descriptiveShaderName(source);
            NSUInteger  hash = [source hash];
            NSNumber   *hKey = @(hash);
            @synchronized(gHookLock) {
                capturedSources[hKey]   = source;
                capturedLibraries[hKey] = lib;
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
                if (floatingMenu) [floatingMenu captureShaderWithName:name source:source error:errStr];
            });
        }
        if (handler) handler(lib, err);
    };
    origNewLibraryAsync(self, _cmd, source, options, wrapped);
}

// ── Hook: newLibraryWithData:error: (precompiled .metallib binaries) ──────────
// Captures binary Metal libraries and displays function names in the UI.
// Color/flash patches are NOT available for binary libs (no MSL source).
// Depth/wallhack patches work via depth stencil override (source-independent).

static id<MTLLibrary> hooked_newLibraryWithData(id self, SEL _cmd,
                                                  dispatch_data_t data,
                                                  NSError **error) {
    if (!gHooksEnabled) return origNewLibraryData(self, _cmd, data, error);
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

    // Build a readable display source listing all contained function names
    // Hash is embedded so each metallib gets a unique stableKey in ShaderPage
    NSMutableString *displaySrc = [NSMutableString string];
    [displaySrc appendString:@"// ⚠️  METALLIB PRECOMPILATA — sorgente MSL non disponibile\n"];
    [displaySrc appendString:@"// I pulsanti R/G/B/⚡ non sono applicabili.\n"];
    [displaySrc appendString:@"// Il pulsante V (wallhack) funziona via depth stencil override.\n//\n"];
    [displaySrc appendFormat:@"// ID libreria: %04lx\n//\n", (unsigned long)h16];
    [displaySrc appendString:@"// Funzioni contenute:\n"];
    for (NSString *fn in funcNames) {
        [displaySrc appendFormat:@"//   %@\n", fn];
    }

    @synchronized(gHookLock) {
        capturedSources[hKey]   = displaySrc;
        capturedLibraries[hKey] = lib;
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

    // dispName includes h16 so each binary metallib gets its own entry (not deduped)
    NSString *firstName = funcNames.firstObject ?: @"binary_lib";
    NSString *dispName  = [NSString stringWithFormat:@"%@ [%04lx]", firstName, (unsigned long)h16];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (floatingMenu) [floatingMenu captureShaderWithName:dispName source:displaySrc error:nil];
    });
    return lib;
}

// ── Hook: parallelRenderCommandEncoderWithDescriptor: ────────────────────────
// Static C function replaces imp_implementationWithBlock (not reliable on LLVM clang)

// ── Hook: newLibraryWithURL:error: (Unreal Engine — pre-compiled .metallib) ──
static id<MTLLibrary>
hooked_newLibraryWithURL(id self, SEL _cmd, NSURL *url, NSError **error) {
    if (!gHooksEnabled) return origNewLibraryUrl(self, _cmd, url, error);
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

    NSMutableString *displaySrc = [NSMutableString string];
    [displaySrc appendString:@"// \xe2\x9a\xa0\xef\xb8\x8f  METALLIB PRECOMPILATA (URL)\n"];
    [displaySrc appendFormat:@"// File: %@\n", fileName];
    [displaySrc appendFormat:@"// ID libreria: %04lx\n", (unsigned long)h16url];
    [displaySrc appendString:@"// R/G/B/flash non disponibili (binary shader).\n"];
    [displaySrc appendString:@"// V (wallhack) funziona via depth stencil override.\n//\n"];
    [displaySrc appendString:@"// Funzioni:\n"];
    for (NSString *fn in funcNames) {
        [displaySrc appendFormat:@"//   %@\n", fn];
    }

    BOOL isNew = NO;
    NSString *srcCopy = nil;
    NSString *firstNameUrl = funcNames.count > 0 ? funcNames.firstObject : fileName;
    NSString *dispName = [NSString stringWithFormat:@"%@ [%04lx]", firstNameUrl, (unsigned long)h16url];
    @synchronized(gHookLock) {
        if (!capturedLibraries[hKey]) {
            capturedSources[hKey]   = displaySrc;
            capturedLibraries[hKey] = lib;
            isNew    = YES;
            srcCopy  = [displaySrc copy];
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
        NSString *cap = srcCopy;
        NSString *nm  = dispName;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (floatingMenu) [floatingMenu captureShaderWithName:nm source:cap error:nil];
        });
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

    Method mp = class_getInstanceMethod(cls, @selector(setRenderPipelineState:));
    if (mp) {
        IMP cur = method_getImplementation(mp);
        if (cur != (IMP)hooked_setRenderPipelineState) {
            if (!origSetPipe) origSetPipe = (SetPipeIMP)cur;
            method_setImplementation(mp, (IMP)hooked_setRenderPipelineState);
        }
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
    if (!gHooksEnabled) return origCmdBuf(self, _cmd);
    // Clear live-active set at the start of each frame so it only reflects
    // the pipelines used in the CURRENT command buffer, not historical ones.
    @synchronized(gHookLock) { [gLiveActiveHashes removeAllObjects]; }
    id<MTLCommandBuffer> buf = origCmdBuf(self, _cmd);
    if (buf) {
        // CRITICAL: dispatch_once prevents double-hook infinite recursion.
        // Without it, two concurrent calls both see origRenderEnc==NULL, both install
        // the hook; the second overwrites origRenderEnc with hooked_renderCommandEncoder
        // itself → hooked_renderCommandEncoder calls origRenderEnc = itself → stack overflow.
        static dispatch_once_t encInstallOnce;
        dispatch_once(&encInstallOnce, ^{
            Class cls = object_getClass(buf);
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
    fmLog(@"[SAFETY] Tutti i patch shader azzerati (deep reset)");
}

// ── Live-active hash accessor (called from ShaderPage LIVE filter) ────────────

// Returns an immutable snapshot of the source hashes seen in the CURRENT frame.
// Thread-safe: snapshot is taken under gHookLock.
NSSet *fmCopyLiveActiveHashes(void) {
    @synchronized(gHookLock) {
        return [gLiveActiveHashes copy];
    }
}

// ── Master switch API (called from FloatingMenu UI) ───────────────────────────

void fmSetHooksEnabled(BOOL enabled) {
    gHooksEnabled = enabled;
    // Persist so next launch restores same state
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:@"FMHooksEnabled"];
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
    // 3. commandBuffer on MTLCommandQueue (lazy path to get encoder class)
    {
        id<MTLCommandQueue> q = [device newCommandQueue];
        if (q) {
            Class qCls = object_getClass(q);
            Method m = class_getInstanceMethod(qCls, @selector(commandBuffer));
            if (m) { origCmdBuf = (CmdBufIMP)method_getImplementation(m);
                     method_setImplementation(m, (IMP)hooked_commandBuffer); }
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
    {
        // Open (or create) the log file for append so signal handler can write sync.
        NSArray *libs = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
        NSString *logPath = [[libs firstObject] stringByAppendingPathComponent:@"FloatingMenuLog.txt"];
        gCrashLogFD = open([logPath fileSystemRepresentation], O_WRONLY | O_CREAT | O_APPEND, 0644);

        struct sigaction sa;
        sa.sa_sigaction = fmSignalHandler;
        sigemptyset(&sa.sa_mask);
        sa.sa_flags = SA_SIGINFO | SA_RESETHAND;
        sigaction(SIGSEGV, &sa, NULL);
        sigaction(SIGBUS,  &sa, NULL);
        sigaction(SIGILL,  &sa, NULL);
        // SIGABRT is raised by ObjC exceptions after the exception handler returns — install both.
        sigaction(SIGABRT, &sa, NULL);
        NSSetUncaughtExceptionHandler(fmExceptionHandler);
    }

    // Start with hooks OFF — prevents crashes in UE's complex Metal init sequence.
    // Hooks are enabled automatically 3s after the menu appears (see below).
    // If the user had explicitly saved YES, we honour it immediately.
    BOOL savedHooks = [[NSUserDefaults standardUserDefaults] boolForKey:@"FMHooksEnabled"];
    // Only start YES if the user explicitly saved YES (key exists AND is true).
    // boolForKey: returns NO for missing keys, so first-launch always starts NO.
    gHooksEnabled = savedHooks; // NO on first launch → safe startup

    gHookLock           = [[NSObject alloc] init];
    capturedSources     = [[NSMutableDictionary alloc] init];
    capturedLibraries   = [[NSMutableDictionary alloc] init];
    capturedOptions     = [[NSMutableDictionary alloc] init];
    colorLibraries      = [[NSMutableDictionary alloc] init];
    flashLibraries      = [[NSMutableDictionary alloc] init];
    pipelinePatches     = [[NSMutableDictionary alloc] init];
    pipelineFragHash    = [[NSMutableDictionary alloc] init];
    pipelineVertHash    = [[NSMutableDictionary alloc] init];
    pipelineDescriptors = [[NSMutableDictionary alloc] init];
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

        // Auto-enable hooks 3s after UI is ready.
        // Starting with hooks OFF prevents crashes during UE's Metal init.
        // After 3s the game is in its render loop and hooks are safe.
        if (!gHooksEnabled) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (!gHooksEnabled) {
                    gHooksEnabled = YES;
                    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"FMHooksEnabled"];
                    if (floatingMenu) [floatingMenu addLog:@"[INFO] Hook abilitati automaticamente — cattura shader attiva"];
                }
            });
        }
    }];
    NSLog(@"[FM] lc_init done");
    } // @autoreleasepool
}
