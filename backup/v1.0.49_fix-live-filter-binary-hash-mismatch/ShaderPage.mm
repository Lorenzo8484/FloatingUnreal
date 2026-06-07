#import "ShaderPage.h"
#import <objc/runtime.h>

@implementation ShaderEntry
@end

@interface ShaderPage () <UITableViewDelegate, UITableViewDataSource, UITextFieldDelegate, UIGestureRecognizerDelegate> {
    NSInteger             _currentTab;       // 0=Shaders 1=Memory 2=Export
    BOOL                  _expanded;
    CGRect                _originalFrame;
    NSInteger             _fragCount;
    NSInteger             _vertCount;
    NSInteger             _sortMode;          // 0=default  1=↑ smallest first  2=↓ largest first
    BOOL                  _liveFilterActive;  // YES = show only shaders active in current frame
    NSSet                *_liveSnapshotHashes; // immutable snapshot taken when LIVE button tapped
    NSMutableDictionary  *_savedPatchCache;   // keyed by shader name, persisted to NSUserDefaults
    UIView               *_exportView;        // full-panel view for Export tab
    UITextView           *_exportTextView;    // shows the generated .m source
    CGPoint               _savedShaderScrollOffset; // preserves scroll when switching tabs
}
@end

// ── Corner resize handle tags ──────────────────────────────────────────────────
static const NSInteger kTagCornerTL = 9910;
static const NSInteger kTagCornerTR = 9911;
static const NSInteger kTagCornerBL = 9912;
static const NSInteger kTagCornerBR = 9913;
// Resize constraints
static const CGFloat kCornerHandleSize = 24;
static const CGFloat kPanelMinW = 260;
static const CGFloat kPanelMinH = 180;

// ── Layout constants ───────────────────────────────────────────────────────────
static const CGFloat kHeaderH   = 74;   // header: title row + pill row
static const CGFloat kTabH      = 0;    // no separate tab bar (tabs in header)
static const CGFloat kSearchH   = 26;   // search bar
static const CGFloat kListStart  = kHeaderH + kTabH + kSearchH + 1;
static const CGFloat kSizeColW  = 30;   // far-right size column (matches sort btn)
static const CGFloat kDividerH  = 28;

// Cell text layout
static const CGFloat kCellPadV    = 7;   // top/bottom padding
static const CGFloat kNameH       = 17;  // struct name row height
static const CGFloat kMemberLineH = 13;  // each member line height

// Buttons
static const CGFloat kBtnW  = 33;
static const CGFloat kBtnH  = 27;
static const CGFloat kBtnSp = 3;


// Tags
static const NSInteger kTagR     = 3001;
static const NSInteger kTagG     = 3002;
static const NSInteger kTagB     = 3003;
static const NSInteger kTagFlash = 3004;
static const NSInteger kTagVert  = 3005;
static const NSInteger kTagSave  = 3006;
static const NSInteger kTagNum   = 3020;
static const NSInteger kTagBadge = 3010;
static const NSInteger kTagName  = 600;
static const NSInteger kTagSub   = 601;
static const NSInteger kTagVGHdr = 603;
static const NSInteger kTagVG    = 602;
static const NSInteger kTagSep       = 3030;  // vertical separator (before buttons)
static const NSInteger kTagSep2      = 3031;  // vertical separator (between struct and VGlobals)
static const NSInteger kTagSizeSep   = 3037;  // vertical separator before size column (far right)
static const NSInteger kTagLineCount = 3035;  // line count in size column
static const NSInteger kTagLiveDot   = 3039;  // green ● live indicator in cell

static const char kEntryKey    = 'e';
static const char kShadeRKey   = 'r';
static const char kShadeGKey   = 'g';
static const char kShadeBKey   = 'b';
static const char kBaseTagKey2 = 'T';

static NSString * const kReuseVert    = @"FM_V2";
static NSString * const kReuseFrag    = @"FM_F2";
static NSString * const kReuseBoth    = @"FM_B2";
static NSString * const kReuseDivider = @"FM_DIV";

// Forward declarations (defined near detail view code at bottom of file)
static BOOL fmSourceIsObfuscated(NSString *src);
static BOOL fmSourceIsBinary(NSString *src);

// Tweak.xm public accessor — returns immutable snapshot of hashes seen this frame
extern NSSet *fmCopyLiveActiveHashes(void);

// ── Struct parsing helpers ─────────────────────────────────────────────────────

// Extract exact struct name ("struct Foo_Type") from source given a lowercase hint
static NSString *fmStructName(NSString *src, NSString *hintLower) {
    NSString *lower = [src lowercaseString];
    NSRange hintRange = [lower rangeOfString:hintLower];
    if (hintRange.location == NSNotFound) return nil;

    // Find "struct" keyword before the hint (search backwards)
    NSRange before = NSMakeRange(0, NSMaxRange(hintRange));
    NSRange structKw = [lower rangeOfString:@"struct" options:NSBackwardsSearch range:before];
    if (structKw.location == NSNotFound) return nil;

    // Find opening brace after hint
    NSRange searchFwd = NSMakeRange(hintRange.location, src.length - hintRange.location);
    NSRange openBrace = [src rangeOfString:@"{" options:0 range:searchFwd];
    if (openBrace.location == NSNotFound) return nil;

    // "struct Name" = text from struct keyword to just before "{"
    NSString *raw = [[src substringWithRange:
                      NSMakeRange(structKw.location, openBrace.location - structKw.location)]
                     stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return raw; // e.g. "struct Mtl_VertexOut"
}

// Extract raw body lines (each member, trimmed, \n-joined) from a struct
static NSString *fmStructBody(NSString *src, NSString *hintLower) {
    NSString *lower = [src lowercaseString];
    NSRange hintRange = [lower rangeOfString:hintLower];
    if (hintRange.location == NSNotFound) return nil;

    NSRange searchFwd = NSMakeRange(hintRange.location, src.length - hintRange.location);
    NSRange openBrace = [src rangeOfString:@"{" options:0 range:searchFwd];
    if (openBrace.location == NSNotFound) return nil;

    NSRange afterOpen = NSMakeRange(NSMaxRange(openBrace), src.length - NSMaxRange(openBrace));
    NSRange closeBrace = [src rangeOfString:@"}" options:0 range:afterOpen];
    if (closeBrace.location == NSNotFound) return nil;

    NSString *body = [src substringWithRange:
                      NSMakeRange(NSMaxRange(openBrace), closeBrace.location - NSMaxRange(openBrace))];

    NSCharacterSet *ws = [NSCharacterSet whitespaceCharacterSet];
    NSMutableArray *lines = [NSMutableArray array];
    for (NSString *line in [body componentsSeparatedByString:@"\n"]) {
        NSString *t = [line stringByTrimmingCharactersInSet:ws];
        if (t.length == 0) continue;
        // Strip Metal attribute brackets e.g. [[position]], [[color(0)]], [[user(locn0)]]
        // and any trailing semicolon spaces
        NSMutableString *clean = [NSMutableString stringWithString:t];
        NSRegularExpression *re = [NSRegularExpression
            regularExpressionWithPattern:@"\\s*\\[\\[.*?\\]\\]"
            options:0 error:nil];
        NSString *stripped = [re stringByReplacingMatchesInString:clean
            options:0
            range:NSMakeRange(0, clean.length)
            withTemplate:@""];
        // Trim trailing whitespace/semicolons left over
        stripped = [stripped stringByTrimmingCharactersInSet:ws];
        if (stripped.length > 0) [lines addObject:stripped];
    }
    return lines.count > 0 ? [lines componentsJoinedByString:@"\n"] : nil;
}

@implementation ShaderPage

// ── Init ──────────────────────────────────────────────────────────────────────

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _shaders         = [NSMutableArray array];
        _filteredShaders = [NSMutableArray array];
        _currentTab      = 0;
        _expanded        = NO;
        _fragCount       = 0;
        _vertCount       = 0;
        [self _loadPatchCache];
        self.backgroundColor = [UIColor colorWithRed:0.05 green:0.05 blue:0.08 alpha:1];
        self.layer.cornerRadius = 12;
        self.clipsToBounds = YES;
        [self setupListView];
        [self setupDetailView];
        [self setupResizeHandles];
    }
    return self;
}

// ── Corner resize handles (BL and BR only — TL/TR removed to avoid
//    interfering with the header pan gesture) ───────────────────────────────

- (void)setupResizeHandles {
    // Only bottom corners: BL and BR.  Top corners were intercepting the
    // header drag gesture and causing the "content freezes, frame moves" glitch.
    NSInteger tags[] = { kTagCornerBL, kTagCornerBR };
    for (int i = 0; i < 2; i++) {
        UIView *handle = [[UIView alloc] initWithFrame:CGRectZero];
        handle.tag = tags[i];
        handle.backgroundColor = [UIColor clearColor];
        handle.userInteractionEnabled = YES;

        UIColor *lineCol = [UIColor colorWithRed:0.5 green:0.9 blue:1.0 alpha:0.55];
        CGFloat lw = 2.5, ll = 11, sz = kCornerHandleSize;
        UIView *hBar = [[UIView alloc] init]; hBar.backgroundColor = lineCol;
        UIView *vBar = [[UIView alloc] init]; vBar.backgroundColor = lineCol;

        if (tags[i] == kTagCornerBL) { // ↙
            hBar.frame = CGRectMake(2,      sz - lw - 2, ll, lw);
            vBar.frame = CGRectMake(2,      sz - ll - 2, lw, ll);
        } else {                        // ↘
            hBar.frame = CGRectMake(sz - ll - 2, sz - lw - 2, ll, lw);
            vBar.frame = CGRectMake(sz - lw - 2, sz - ll - 2, lw, ll);
        }
        [handle addSubview:hBar];
        [handle addSubview:vBar];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
                                       initWithTarget:self action:@selector(handleCornerPan:)];
        [handle addGestureRecognizer:pan];
        [self addSubview:handle];
    }
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat W  = self.bounds.size.width;
    CGFloat H  = self.bounds.size.height;
    CGFloat sz = kCornerHandleSize;
    // Only BL and BR; TL/TR no longer exist.
    struct { NSInteger tag; CGRect frame; } corners[] = {
        { kTagCornerBL, CGRectMake(0,    H - sz, sz, sz) },
        { kTagCornerBR, CGRectMake(W-sz, H - sz, sz, sz) },
    };
    for (int i = 0; i < 2; i++) {
        UIView *c = [self viewWithTag:corners[i].tag];
        if (c) c.frame = corners[i].frame;
    }
}

- (void)handleCornerPan:(UIPanGestureRecognizer *)pan {
    UIView *parent = self.superview;
    if (!parent) return;

    CGPoint delta = [pan translationInView:parent];
    [pan setTranslation:CGPointZero inView:parent];

    NSInteger corner = pan.view.tag;
    CGRect f = self.frame;
    CGSize screen = [UIScreen mainScreen].bounds.size;

    // Apply delta per corner
    switch (corner) {
        case kTagCornerTL:
            f.origin.x    += delta.x;  f.size.width  -= delta.x;
            f.origin.y    += delta.y;  f.size.height -= delta.y;
            break;
        case kTagCornerTR:
            f.size.width  += delta.x;
            f.origin.y    += delta.y;  f.size.height -= delta.y;
            break;
        case kTagCornerBL:
            f.origin.x    += delta.x;  f.size.width  -= delta.x;
            f.size.height += delta.y;
            break;
        case kTagCornerBR:
            f.size.width  += delta.x;
            f.size.height += delta.y;
            break;
    }

    // Enforce minimum size — restore origin if panel hit the minimum
    if (f.size.width < kPanelMinW) {
        if (corner == kTagCornerTL || corner == kTagCornerBL)
            f.origin.x = CGRectGetMaxX(self.frame) - kPanelMinW;
        f.size.width = kPanelMinW;
    }
    if (f.size.height < kPanelMinH) {
        if (corner == kTagCornerTL || corner == kTagCornerTR)
            f.origin.y = CGRectGetMaxY(self.frame) - kPanelMinH;
        f.size.height = kPanelMinH;
    }

    // Clamp to screen
    f.origin.x    = MAX(0,  f.origin.x);
    f.origin.y    = MAX(16, f.origin.y);
    f.size.width  = MIN(f.size.width,  screen.width  - f.origin.x);
    f.size.height = MIN(f.size.height, screen.height - f.origin.y - 16);

    self.frame = f;

    // Reload table only when gesture ends (not every frame — too expensive)
    if (pan.state == UIGestureRecognizerStateEnded ||
        pan.state == UIGestureRecognizerStateCancelled) {
        [self.shaderList reloadData];
    }
}

// ── Dynamic cell height ────────────────────────────────────────────────────────

- (CGFloat)cellHeightForEntry:(ShaderEntry *)entry {
    if (entry.isDivider) return kDividerH;

    NSInteger structLines = entry.subMembersText.length > 0
        ? (NSInteger)[[entry.subMembersText componentsSeparatedByString:@"\n"] count]
        : 0;

    CGFloat h = kCellPadV + kNameH + (structLines * kMemberLineH) + kCellPadV;

    // VGlobals always visible — take the TALLER of the two columns
    if (entry.vglobalsText.length > 0) {
        NSInteger vgLines = (NSInteger)[[entry.vglobalsText componentsSeparatedByString:@"\n"] count];
        CGFloat vgH = kCellPadV + kNameH + (vgLines * kMemberLineH) + kCellPadV;
        h = MAX(h, vgH);
    }

    return MAX(h, 44);
}

// ── Patch button helpers ───────────────────────────────────────────────────────

static void configurePatchBtn(UIButton *btn, BOOL active, UIColor *color) {
    if (!btn) return;
    btn.backgroundColor = active ? color : [UIColor colorWithWhite:0.13 alpha:1];
    btn.layer.borderColor = active
        ? color.CGColor
        : [UIColor colorWithWhite:0.22 alpha:1].CGColor;
    [btn setTitleColor:active
        ? [UIColor whiteColor]
        : [UIColor colorWithWhite:0.35 alpha:1]
        forState:UIControlStateNormal];
}

static UIButton *makePatchBtn(NSString *label, NSInteger tag, id target, SEL action) {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.tag = tag;
    btn.layer.cornerRadius = 5;
    btn.layer.borderWidth  = 1;
    btn.titleLabel.font    = [UIFont boldSystemFontOfSize:10];
    [btn setTitle:label forState:UIControlStateNormal];
    configurePatchBtn(btn, NO, nil);
    [btn addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    return btn;
}

static UIColor *colorR()     { return [UIColor colorWithRed:1.0 green:0.22 blue:0.22 alpha:1]; }
static UIColor *colorG()     { return [UIColor colorWithRed:0.2  green:0.85 blue:0.35 alpha:1]; }
static UIColor *colorB()     { return [UIColor colorWithRed:0.2  green:0.5  blue:1.0  alpha:1]; }
static UIColor *colorFlash() { return [UIColor colorWithRed:1.0  green:0.85 blue:0.0  alpha:1]; }
static UIColor *colorVert()  { return [UIColor colorWithRed:0.3  green:0.85 blue:1.0  alpha:1]; }

- (void)updatePatchButtonsInContentView:(UIView *)cv forEntry:(ShaderEntry *)entry {
    BOOL rOn = entry.patchFragColor == FragPatchRed;
    UIColor *rCol = (rOn && entry.patchShadeOverride)
        ? [UIColor colorWithRed:entry.patchShadeR green:entry.patchShadeG blue:entry.patchShadeB alpha:1]
        : colorR();
    configurePatchBtn((UIButton *)[cv viewWithTag:kTagR], rOn, rCol);

    BOOL gOn = entry.patchFragColor == FragPatchGreen;
    UIColor *gCol = (gOn && entry.patchShadeOverride)
        ? [UIColor colorWithRed:entry.patchShadeR green:entry.patchShadeG blue:entry.patchShadeB alpha:1]
        : colorG();
    configurePatchBtn((UIButton *)[cv viewWithTag:kTagG], gOn, gCol);

    BOOL bOn = entry.patchFragColor == FragPatchBlue;
    UIColor *bCol = (bOn && entry.patchShadeOverride)
        ? [UIColor colorWithRed:entry.patchShadeR green:entry.patchShadeG blue:entry.patchShadeB alpha:1]
        : colorB();
    configurePatchBtn((UIButton *)[cv viewWithTag:kTagB], bOn, bCol);

    configurePatchBtn((UIButton *)[cv viewWithTag:kTagFlash], entry.patchFlash,   colorFlash());
    configurePatchBtn((UIButton *)[cv viewWithTag:kTagVert],  entry.patchVertex,  colorVert());
}

- (void)patchBtnTapped:(UIButton *)sender {
    ShaderEntry *entry = objc_getAssociatedObject(sender, &kEntryKey);
    if (!entry) return;
    switch (sender.tag) {
        case kTagR:     entry.patchFragColor = (entry.patchFragColor == FragPatchRed)   ? FragPatchNone : FragPatchRed;   break;
        case kTagG:     entry.patchFragColor = (entry.patchFragColor == FragPatchGreen) ? FragPatchNone : FragPatchGreen; break;
        case kTagB:     entry.patchFragColor = (entry.patchFragColor == FragPatchBlue)  ? FragPatchNone : FragPatchBlue;  break;
        case kTagFlash: entry.patchFlash  = !entry.patchFlash;  break;
        case kTagVert:  entry.patchVertex = !entry.patchVertex; break;
    }
    [self updatePatchButtonsInContentView:sender.superview forEntry:entry];
    if (self.patchChangedHandler) self.patchChangedHandler(entry);
    [self _persistEntry:entry];
}

// ── Long-press color picker for R / G / B buttons ─────────────────────────────

- (void)colorBtnLongPressed:(UILongPressGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateBegan) return;
    UIButton *btn = (UIButton *)gr.view;
    ShaderEntry *entry = objc_getAssociatedObject(btn, &kEntryKey);
    if (!entry) return;
    [self showColorPickerNearButton:btn forEntry:entry baseTag:btn.tag];
}

- (void)showColorPickerNearButton:(UIButton *)btn forEntry:(ShaderEntry *)entry baseTag:(NSInteger)tag {
    [self dismissColorPicker];

    // 5 shades: lightest → darkest / most intense
    NSArray<NSArray<NSNumber *> *> *shades;
    if (tag == kTagR) {
        shades = @[@[@(1.0f),@(0.55f),@(0.55f)],
                   @[@(1.0f),@(0.28f),@(0.28f)],
                   @[@(1.0f),@(0.0f), @(0.0f) ],
                   @[@(0.75f),@(0.0f),@(0.0f) ],
                   @[@(0.40f),@(0.0f),@(0.0f) ]];
    } else if (tag == kTagG) {
        shades = @[@[@(0.45f),@(1.0f), @(0.45f)],
                   @[@(0.1f), @(0.95f),@(0.25f)],
                   @[@(0.0f), @(0.85f),@(0.15f)],
                   @[@(0.0f), @(0.65f),@(0.0f) ],
                   @[@(0.0f), @(0.38f),@(0.0f) ]];
    } else {
        shades = @[@[@(0.50f),@(0.72f),@(1.0f) ],
                   @[@(0.2f), @(0.5f), @(1.0f) ],
                   @[@(0.1f), @(0.3f), @(0.92f)],
                   @[@(0.0f), @(0.1f), @(0.72f)],
                   @[@(0.0f), @(0.0f), @(0.42f)]];
    }

    static const CGFloat kSq  = 34;
    static const CGFloat kGap = 5;
    static const CGFloat kPad = 8;
    CGFloat pickerW = kPad * 2 + 5 * kSq + 4 * kGap;
    CGFloat pickerH = kPad * 2 + kSq;

    UIView *picker = [[UIView alloc] initWithFrame:CGRectZero];
    picker.backgroundColor = [UIColor colorWithRed:0.10 green:0.10 blue:0.16 alpha:0.97];
    picker.layer.cornerRadius = 9;
    picker.layer.borderWidth  = 1;
    picker.layer.borderColor  = [UIColor colorWithWhite:0.40 alpha:1].CGColor;
    picker.clipsToBounds = YES;
    picker.tag = 9999;

    for (NSInteger i = 0; i < 5; i++) {
        NSArray<NSNumber *> *rgb = shades[i];
        UIButton *sq = [UIButton buttonWithType:UIButtonTypeCustom];
        sq.frame = CGRectMake(kPad + i * (kSq + kGap), kPad, kSq, kSq);
        sq.backgroundColor = [UIColor colorWithRed:[rgb[0] floatValue]
                                              green:[rgb[1] floatValue]
                                               blue:[rgb[2] floatValue]
                                              alpha:1.0];
        sq.layer.cornerRadius = 6;
        sq.clipsToBounds = YES;
        objc_setAssociatedObject(sq, &kEntryKey,    entry,  OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(sq, &kShadeRKey,   rgb[0], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(sq, &kShadeGKey,   rgb[1], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(sq, &kShadeBKey,   rgb[2], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(sq, &kBaseTagKey2, @(tag), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [sq addTarget:self action:@selector(shadeSquareTapped:) forControlEvents:UIControlEventTouchUpInside];
        [picker addSubview:sq];
    }

    // Position above button (or below if not enough room)
    CGRect btnInSelf = [btn convertRect:btn.bounds toView:self];
    CGFloat pickerX  = btnInSelf.origin.x + btnInSelf.size.width / 2.0 - pickerW / 2.0;
    CGFloat pickerY  = btnInSelf.origin.y - pickerH - 6;
    pickerX = MAX(4, MIN(pickerX, self.bounds.size.width - pickerW - 4));
    if (pickerY < kListStart) pickerY = btnInSelf.origin.y + btnInSelf.size.height + 4;
    picker.frame = CGRectMake(pickerX, pickerY, pickerW, pickerH);

    // Transparent overlay catches tap-outside to dismiss
    UIButton *overlay = [UIButton buttonWithType:UIButtonTypeCustom];
    overlay.frame = self.bounds;
    overlay.backgroundColor = [UIColor clearColor];
    overlay.tag = 9998;
    [overlay addTarget:self action:@selector(dismissColorPicker) forControlEvents:UIControlEventTouchUpInside];

    [self addSubview:overlay];
    [self addSubview:picker];
}

- (void)dismissColorPicker {
    [[self viewWithTag:9998] removeFromSuperview];
    [[self viewWithTag:9999] removeFromSuperview];
}

- (void)shadeSquareTapped:(UIButton *)sq {
    ShaderEntry *entry = objc_getAssociatedObject(sq, &kEntryKey);
    NSNumber *rVal    = objc_getAssociatedObject(sq, &kShadeRKey);
    NSNumber *gVal    = objc_getAssociatedObject(sq, &kShadeGKey);
    NSNumber *bVal    = objc_getAssociatedObject(sq, &kShadeBKey);
    NSNumber *baseTag = objc_getAssociatedObject(sq, &kBaseTagKey2);
    if (!entry || !rVal) { [self dismissColorPicker]; return; }

    entry.patchShadeR        = [rVal floatValue];
    entry.patchShadeG        = [gVal floatValue];
    entry.patchShadeB        = [bVal floatValue];
    entry.patchShadeOverride = YES;

    NSInteger tag = [baseTag integerValue];
    if      (tag == kTagR) entry.patchFragColor = FragPatchRed;
    else if (tag == kTagG) entry.patchFragColor = FragPatchGreen;
    else                   entry.patchFragColor = FragPatchBlue;

    [self dismissColorPicker];

    // Refresh all visible cells for this entry
    for (UITableViewCell *cell in self.shaderList.visibleCells) {
        UIButton *rb = (UIButton *)[cell.contentView viewWithTag:kTagR];
        if (objc_getAssociatedObject(rb, &kEntryKey) == entry)
            [self updatePatchButtonsInContentView:cell.contentView forEntry:entry];
    }
    if (self.patchChangedHandler) self.patchChangedHandler(entry);
    [self _persistEntry:entry];
}

- (void)saveBtnTapped:(UIButton *)sender {
    ShaderEntry *entry = objc_getAssociatedObject(sender, &kEntryKey);
    if (!entry) return;
    entry.isSaved = !entry.isSaved;
    [self applySaveBtnState:sender saved:entry.isSaved];
    if (_currentTab == 1) [self applyFilter];
    [self _persistEntry:entry];
}

static void applyStar(UIButton *btn, BOOL saved) {
    if (!btn) return;
    [btn setTitleColor:saved
        ? [UIColor colorWithRed:1.0 green:0.85 blue:0.0 alpha:1]   // yellow
        : [UIColor colorWithWhite:0.30 alpha:1]                      // dim
        forState:UIControlStateNormal];
}

- (void)applySaveBtnState:(UIButton *)btn saved:(BOOL)saved {
    applyStar(btn, saved);
}

// ── Cell factory (view hierarchy, placeholder frames) ─────────────────────────

- (UITableViewCell *)makeCellForEntry:(ShaderEntry *)entry tableView:(UITableView *)tv {
    BOOL showFrag = entry.hasFragmentFunction;
    BOOL showVert = entry.hasVertexFunction;
    NSString *rID = (showFrag && showVert) ? kReuseBoth : showVert ? kReuseVert : kReuseFrag;

    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:rID];
    if (cell) return cell;

    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:rID];
    cell.backgroundColor = [UIColor clearColor];
    cell.textLabel.hidden = YES;
    cell.accessoryType = UITableViewCellAccessoryNone;
    UIView *selBg = [UIView new];
    selBg.backgroundColor = [UIColor colorWithWhite:1 alpha:0.05];
    cell.selectedBackgroundView = selBg;

    // Type badge (tag kTagBadge) — topmost in left column
    UILabel *badge = [[UILabel alloc] init];
    badge.tag = kTagBadge;
    badge.font = [UIFont boldSystemFontOfSize:7];
    badge.textAlignment = NSTextAlignmentCenter;
    badge.layer.cornerRadius = 3;
    badge.clipsToBounds = YES;
    [cell.contentView addSubview:badge];

    // Number label (tag kTagNum) — TOP of left col, above star+badge row
    UILabel *numLabel = [[UILabel alloc] init];
    numLabel.tag = kTagNum;
    numLabel.font = [UIFont boldSystemFontOfSize:10];
    numLabel.textAlignment = NSTextAlignmentCenter;
    numLabel.textColor = [UIColor colorWithWhite:0.55 alpha:1];
    numLabel.numberOfLines = 2;
    [cell.contentView addSubview:numLabel];

    // ★ Save star (tag kTagSave) — left of badge (side by side)
    UIButton *saveBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    saveBtn.tag = kTagSave;
    [saveBtn setTitle:@"★" forState:UIControlStateNormal];
    saveBtn.titleLabel.font = [UIFont systemFontOfSize:18];
    applyStar(saveBtn, NO);
    [saveBtn addTarget:self action:@selector(saveBtnTapped:)
      forControlEvents:UIControlEventTouchUpInside];
    [cell.contentView addSubview:saveBtn];

    // Struct name label (tag kTagName) — e.g. "struct Mtl_VertexOut"
    UILabel *nameLabel = [[UILabel alloc] init];
    nameLabel.tag = kTagName;
    nameLabel.font = [UIFont fontWithName:@"Courier" size:11];
    nameLabel.textColor = [UIColor colorWithWhite:0.90 alpha:1];
    nameLabel.numberOfLines = 1;
    [cell.contentView addSubview:nameLabel];

    // Struct body label (tag kTagSub) — member lines in column, orange
    UILabel *subLabel = [[UILabel alloc] init];
    subLabel.tag = kTagSub;
    subLabel.font = [UIFont fontWithName:@"Courier" size:9];
    subLabel.textColor = [UIColor colorWithRed:1.0 green:0.55 blue:0.10 alpha:1];
    subLabel.numberOfLines = 0;
    [cell.contentView addSubview:subLabel];

    // VGlobals header label (tag kTagVGHdr) — "struct VGlobals_Type"
    UILabel *vgHdr = [[UILabel alloc] init];
    vgHdr.tag = kTagVGHdr;
    vgHdr.font = [UIFont fontWithName:@"Courier" size:11];
    vgHdr.textColor = [UIColor colorWithRed:0.5 green:0.85 blue:1.0 alpha:1];
    vgHdr.numberOfLines = 1;
    [cell.contentView addSubview:vgHdr];

    // VGlobals body label (tag kTagVG)
    UILabel *vgLabel = [[UILabel alloc] init];
    vgLabel.tag = kTagVG;
    vgLabel.font = [UIFont fontWithName:@"Courier" size:9];
    vgLabel.textColor = [UIColor colorWithRed:0.4 green:0.75 blue:1.0 alpha:0.85];
    vgLabel.numberOfLines = 0;
    [cell.contentView addSubview:vgLabel];

    // Vertical separator between struct col and VGlobals col (tag kTagSep2)
    UIView *sep2 = [[UIView alloc] init];
    sep2.tag = kTagSep2;
    sep2.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10];
    [cell.contentView addSubview:sep2];

    // Vertical separator before buttons (tag kTagSep)
    UIView *sep = [[UIView alloc] init];
    sep.tag = kTagSep;
    sep.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10];
    [cell.contentView addSubview:sep];

    // Patch buttons (no frame yet)
    if (showVert) {
        [cell.contentView addSubview:makePatchBtn(@"V", kTagVert, self, @selector(patchBtnTapped:))];
    }
    if (showFrag) {
        [cell.contentView addSubview:makePatchBtn(@"⚡", kTagFlash, self, @selector(patchBtnTapped:))];

        UIButton *bBtn = makePatchBtn(@"B", kTagB, self, @selector(patchBtnTapped:));
        UILongPressGestureRecognizer *lpB = [[UILongPressGestureRecognizer alloc]
            initWithTarget:self action:@selector(colorBtnLongPressed:)];
        lpB.minimumPressDuration = 0.45;
        [bBtn addGestureRecognizer:lpB];
        [cell.contentView addSubview:bBtn];

        UIButton *gBtn = makePatchBtn(@"G", kTagG, self, @selector(patchBtnTapped:));
        UILongPressGestureRecognizer *lpG = [[UILongPressGestureRecognizer alloc]
            initWithTarget:self action:@selector(colorBtnLongPressed:)];
        lpG.minimumPressDuration = 0.45;
        [gBtn addGestureRecognizer:lpG];
        [cell.contentView addSubview:gBtn];

        UIButton *rBtn = makePatchBtn(@"R", kTagR, self, @selector(patchBtnTapped:));
        UILongPressGestureRecognizer *lpR = [[UILongPressGestureRecognizer alloc]
            initWithTarget:self action:@selector(colorBtnLongPressed:)];
        lpR.minimumPressDuration = 0.45;
        [rBtn addGestureRecognizer:lpR];
        [cell.contentView addSubview:rBtn];
    }

    // Vertical separator before size column (far right, tag kTagSizeSep)
    UIView *sizeSep = [[UIView alloc] init];
    sizeSep.tag = kTagSizeSep;
    sizeSep.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10];
    [cell.contentView addSubview:sizeSep];

    // Line count label in size column (tag kTagLineCount)
    UILabel *lcLabel = [[UILabel alloc] init];
    lcLabel.tag = kTagLineCount;
    lcLabel.font = [UIFont monospacedDigitSystemFontOfSize:8 weight:UIFontWeightRegular];
    lcLabel.textColor = [UIColor colorWithWhite:0.28 alpha:1];
    lcLabel.textAlignment = NSTextAlignmentCenter;
    lcLabel.numberOfLines = 2;
    [cell.contentView addSubview:lcLabel];

    // Live dot (tag kTagLiveDot) — small green pill shown when shader is active this frame
    UILabel *liveDot = [[UILabel alloc] init];
    liveDot.tag = kTagLiveDot;
    liveDot.text = @"●";
    liveDot.font = [UIFont systemFontOfSize:8];
    liveDot.textColor = [UIColor colorWithRed:0.15 green:0.95 blue:0.35 alpha:1];
    liveDot.textAlignment = NSTextAlignmentCenter;
    liveDot.hidden = YES;
    [cell.contentView addSubview:liveDot];

    return cell;
}

// ── Cell configuration (all frames + content) ──────────────────────────────────

- (void)configureCell:(UITableViewCell *)cell forEntry:(ShaderEntry *)e tableWidth:(CGFloat)tvW {
    CGFloat cellH = [self cellHeightForEntry:e];

    // ── Size column (far right, kSizeColW px, aligned with sort btn) ──────────
    CGFloat sizeSepX = tvW - kSizeColW - 1;
    UIView *sizeSepV = (UIView *)[cell.contentView viewWithTag:kTagSizeSep];
    sizeSepV.frame = CGRectMake(sizeSepX, 4, 1, cellH - 8);

    UILabel *lcLabel = (UILabel *)[cell.contentView viewWithTag:kTagLineCount];
    if (lcLabel) {
        NSInteger lineCount = (NSInteger)[[e.source componentsSeparatedByString:@"\n"] count];
        lcLabel.text = [NSString stringWithFormat:@"%ld\nln", (long)lineCount];
        lcLabel.frame = CGRectMake(sizeSepX + 2, kCellPadV, kSizeColW - 3, cellH - kCellPadV * 2);
    }

    // ── Buttons layout (right side BEFORE size col, at top y=kCellPadV) ──────
    CGFloat btnY = kCellPadV;
    CGFloat x    = sizeSepX - 4;

    if (e.hasVertexFunction) {
        x -= kBtnW;
        UIButton *b = (UIButton *)[cell.contentView viewWithTag:kTagVert];
        if (b) b.frame = CGRectMake(x, btnY, kBtnW, kBtnH);
        x -= kBtnSp;
    }
    if (e.hasFragmentFunction) {
        NSInteger fragTags[] = {kTagFlash, kTagB, kTagG, kTagR};
        for (NSInteger i = 0; i < 4; i++) {
            x -= kBtnW;
            UIButton *b = (UIButton *)[cell.contentView viewWithTag:fragTags[i]];
            if (b) b.frame = CGRectMake(x, btnY, kBtnW, kBtnH);
            x -= kBtnSp;
        }
    }

    CGFloat sepX = x - 3;  // vertical separator before buttons

    UIView *sep = (UIView *)[cell.contentView viewWithTag:kTagSep];
    sep.frame = CGRectMake(sepX, 4, 1, cellH - 8);

    // ── Left column: number (top) → [★ star | VERT/FRAG badge] row ──────────
    static const CGFloat kLeftColW  = 50;  // wider: fits star(20)+gap(2)+badge(26)
    static const CGFloat kStarColW  = 20;  // ★ button width (bigger)
    static const CGFloat kBadgeColW = 26;  // VERT/FRAG/BOTH badge width

    // Row 1: number, centred, bigger font
    UILabel *numLabel = (UILabel *)[cell.contentView viewWithTag:kTagNum];
    if (e.fragIndex > 0 && e.vertIndex > 0) {
        numLabel.text = [NSString stringWithFormat:@"F%ld\nV%ld", (long)e.fragIndex, (long)e.vertIndex];
    } else if (e.fragIndex > 0) {
        numLabel.text = [NSString stringWithFormat:@"F%ld", (long)e.fragIndex];
    } else {
        numLabel.text = [NSString stringWithFormat:@"V%ld", (long)e.vertIndex];
    }
    numLabel.frame = CGRectMake(2, kCellPadV, kLeftColW - 2, 16);

    // Row 2 left: ★ star (bigger)
    UIButton *saveBtn = (UIButton *)[cell.contentView viewWithTag:kTagSave];
    saveBtn.frame = CGRectMake(1, kCellPadV + 17, kStarColW, 20);
    objc_setAssociatedObject(saveBtn, &kEntryKey, e, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    applyStar(saveBtn, e.isSaved);

    // Row 2 right: VERT/FRAG/BOTH badge (beside star)
    UILabel *badge = (UILabel *)[cell.contentView viewWithTag:kTagBadge];
    badge.frame = CGRectMake(1 + kStarColW + 1, kCellPadV + 19, kBadgeColW, 15);
    if (e.hasVertexFunction && e.hasFragmentFunction) {
        badge.text = @"BOTH"; badge.backgroundColor = [UIColor colorWithRed:0.6 green:0.4 blue:1.0 alpha:0.8];
        badge.textColor = [UIColor whiteColor];
    } else if (e.hasVertexFunction) {
        badge.text = @"VERT"; badge.backgroundColor = [UIColor colorWithRed:0.2 green:0.75 blue:1.0 alpha:0.85];
        badge.textColor = [UIColor colorWithWhite:0.05 alpha:1];
    } else {
        badge.text = @"FRAG"; badge.backgroundColor = [UIColor colorWithRed:0.3 green:0.9 blue:0.4 alpha:0.85];
        badge.textColor = [UIColor colorWithWhite:0.05 alpha:1];
    }

    // ── Text area: struct col | VGlobals col ─────────────────────────────────
    CGFloat textX  = 2 + kLeftColW + 2;
    CGFloat totalW = sepX - textX - 3;
    BOOL    hasVG  = e.vglobalsText.length > 0;

    CGFloat leftW  = hasVG ? (totalW - 1) / 2.0 : totalW;
    CGFloat vgX    = hasVG ? textX + leftW + 1   : 0;
    CGFloat rightW = hasVG ? sepX - vgX - 3       : 0;

    UIView *sep2 = (UIView *)[cell.contentView viewWithTag:kTagSep2];
    if (hasVG) {
        sep2.frame  = CGRectMake(textX + leftW, 4, 1, cellH - 8);
        sep2.hidden = NO;
    } else {
        sep2.hidden = YES;
        sep2.frame  = CGRectZero;
    }

    // Struct name + body
    BOOL hasError = e.errorInfo.length > 0;
    UILabel *nameLabel = (UILabel *)[cell.contentView viewWithTag:kTagName];
    NSString *dispName = e.customName.length > 0 ? e.customName
                       : e.displayName.length > 0 ? e.displayName : e.name;
    // Prefix with source-type badge so the user knows before tapping
    NSString *srcBadge = @"";
    if (!hasError) {
        if (fmSourceIsBinary(e.source))          srcBadge = @"📦 ";
        else if (fmSourceIsObfuscated(e.source)) srcBadge = @"🔒 ";
    }
    nameLabel.text = hasError
        ? [NSString stringWithFormat:@"⚠ %@", dispName]
        : [NSString stringWithFormat:@"%@%@", srcBadge, dispName];
    nameLabel.textColor = hasError
        ? [UIColor colorWithRed:1 green:0.45 blue:0.35 alpha:1]
        : [UIColor colorWithWhite:0.90 alpha:1];
    nameLabel.frame = CGRectMake(textX, kCellPadV, leftW, kNameH);

    // Live dot — green ● in top-right of left column when shader was active this frame
    BOOL isLive = (_liveSnapshotHashes != nil &&
                   ([_liveSnapshotHashes containsObject:@(e.sourceHash)]));
    UILabel *liveDotLbl = (UILabel *)[cell.contentView viewWithTag:kTagLiveDot];
    if (liveDotLbl) {
        liveDotLbl.hidden = !isLive;
        liveDotLbl.frame  = CGRectMake(sizeSepX + 2, 2, kSizeColW - 3, 10);
        liveDotLbl.textColor = [UIColor colorWithRed:0.15 green:0.95 blue:0.35 alpha:1];
    }

    UILabel *subLabel = (UILabel *)[cell.contentView viewWithTag:kTagSub];
    if (e.subMembersText.length > 0) {
        NSInteger lc = (NSInteger)[[e.subMembersText componentsSeparatedByString:@"\n"] count];
        subLabel.text   = e.subMembersText;
        subLabel.frame  = CGRectMake(textX, kCellPadV + kNameH, leftW, lc * kMemberLineH);
        subLabel.hidden = NO;
    } else {
        subLabel.hidden = YES;
        subLabel.frame  = CGRectZero;
    }

    // VGlobals name (white) + body
    UILabel *vgHdr  = (UILabel *)[cell.contentView viewWithTag:kTagVGHdr];
    UILabel *vgBody = (UILabel *)[cell.contentView viewWithTag:kTagVG];

    if (hasVG) {
        vgHdr.text      = e.vglobalsName.length > 0 ? e.vglobalsName : @"struct VGlobals_Type";
        vgHdr.textColor = [UIColor whiteColor];
        vgHdr.frame     = CGRectMake(vgX + 4, kCellPadV, rightW, kNameH);
        vgHdr.hidden    = NO;

        NSInteger vgLines = (NSInteger)[[e.vglobalsText componentsSeparatedByString:@"\n"] count];
        vgBody.text   = e.vglobalsText;
        vgBody.frame  = CGRectMake(vgX + 4, kCellPadV + kNameH, rightW, vgLines * kMemberLineH);
        vgBody.hidden = NO;
    } else {
        vgHdr.hidden  = YES;
        vgBody.hidden = YES;
        vgHdr.frame   = CGRectZero;
        vgBody.frame  = CGRectZero;
    }

    // Patch button states + entry association
    for (NSInteger tag = kTagR; tag <= kTagVert; tag++) {
        UIButton *btn = (UIButton *)[cell.contentView viewWithTag:tag];
        if (btn) objc_setAssociatedObject(btn, &kEntryKey, e, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [self updatePatchButtonsInContentView:cell.contentView forEntry:e];

    // Long-press → rename (rimuovi vecchio, aggiungi nuovo con entry aggiornato)
    for (UIGestureRecognizer *gr in [cell.contentView.gestureRecognizers copy]) {
        if ([gr isKindOfClass:[UILongPressGestureRecognizer class]])
            [cell.contentView removeGestureRecognizer:gr];
    }
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(longPressCellRecognized:)];
    lp.minimumPressDuration = 0.6;
    objc_setAssociatedObject(lp, &kEntryKey, e, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [cell.contentView addGestureRecognizer:lp];
}

// ── setupListView ──────────────────────────────────────────────────────────────

- (void)setupListView {
    CGFloat W = self.bounds.size.width;

    // ── Header ──
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, W, kHeaderH)];
    header.backgroundColor = [UIColor colorWithRed:0.07 green:0.07 blue:0.12 alpha:1];
    header.userInteractionEnabled = YES;
    header.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self addSubview:header];

    // drag pill
    UIView *pill = [[UIView alloc] initWithFrame:CGRectMake((W - 24) / 2, 2, 24, 2)];
    pill.backgroundColor = [UIColor colorWithWhite:1 alpha:0.15];
    pill.layer.cornerRadius = 1;
    pill.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    [header addSubview:pill];

    // ── Row 1 (y=6, h=22): "Metal Inspector" LEFT bold + subtitle same line ────
    UILabel *titleRow = [[UILabel alloc] initWithFrame:CGRectMake(8, 6, W - 126, 22)];
    NSMutableAttributedString *titleStr = [[NSMutableAttributedString alloc] init];
    [titleStr appendAttributedString:[[NSAttributedString alloc]
        initWithString:@"Metal Inspector"
            attributes:@{NSFontAttributeName:[UIFont boldSystemFontOfSize:16],
                         NSForegroundColorAttributeName:[UIColor colorWithRed:0.55 green:0.88 blue:1 alpha:1]}]];
    [titleStr appendAttributedString:[[NSAttributedString alloc]
        initWithString:@"  Metal Shader Dumper - Realtime Patcher & Compiler"
            attributes:@{NSFontAttributeName:[UIFont systemFontOfSize:11],
                         NSForegroundColorAttributeName:[UIColor colorWithWhite:0.42 alpha:1]}]];
    titleRow.attributedText = titleStr;
    titleRow.adjustsFontSizeToFitWidth = YES;
    titleRow.minimumScaleFactor = 0.6;
    titleRow.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [header addSubview:titleRow];

    // ── 📋 Log + ⚡ Hooks — both in top-right of title row, same size ────────
    // [📋 Log] then [⚡ OFF], each 52×22, separated by 6pt
    UIButton *titleLogBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    titleLogBtn.frame = CGRectMake(W - 118, 5, 52, 22);
    titleLogBtn.backgroundColor = [UIColor colorWithRed:0.08 green:0.55 blue:1.0 alpha:0.18];
    titleLogBtn.layer.cornerRadius = 5;
    titleLogBtn.layer.borderWidth  = 1;
    titleLogBtn.layer.borderColor  = [UIColor colorWithRed:0.08 green:0.55 blue:1.0 alpha:0.40].CGColor;
    [titleLogBtn setTitle:@"📋 Log" forState:UIControlStateNormal];
    [titleLogBtn setTitleColor:[UIColor colorWithRed:0.5 green:0.85 blue:1.0 alpha:1] forState:UIControlStateNormal];
    titleLogBtn.titleLabel.font = [UIFont boldSystemFontOfSize:10];
    titleLogBtn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [titleLogBtn addTarget:self action:@selector(logBtnTapped) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:titleLogBtn];

    // ── ⚡ Hooks ON/OFF — small pill at TOP-RIGHT of title row ────────────────
    UIButton *hooksPill = [UIButton buttonWithType:UIButtonTypeCustom];
    hooksPill.tag   = 4030;
    hooksPill.frame = CGRectMake(W - 60, 5, 52, 22);
    [hooksPill setTitle:@"⚡ OFF" forState:UIControlStateNormal];
    hooksPill.titleLabel.font    = [UIFont boldSystemFontOfSize:10];
    hooksPill.layer.cornerRadius = 5;
    hooksPill.layer.borderWidth  = 1;
    hooksPill.backgroundColor    = [UIColor colorWithWhite:0.08 alpha:1];
    hooksPill.layer.borderColor  = [UIColor colorWithRed:0.85 green:0.2 blue:0.2 alpha:0.7].CGColor;
    [hooksPill setTitleColor:[UIColor colorWithRed:0.85 green:0.3 blue:0.3 alpha:1]
                   forState:UIControlStateNormal];
    hooksPill.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [hooksPill addTarget:self action:@selector(hookSwitchTapped:)
       forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:hooksPill];

    // ── Pill row (y=30, h=30): [Shaders][Memory][Export] + badge + credit + action buttons ─
    // 3 tab pills, narrower (60pt each) to fit all three left-aligned.
    static const CGFloat kTabPillW   = 60;
    static const CGFloat kTabPillH   = 30;
    static const CGFloat kTabPillGap = 4;
    static const CGFloat kPillRowY   = 30;
    static const CGFloat kBtnH2      = 26;
    CGFloat btnY2 = kPillRowY + (kTabPillH - kBtnH2) / 2.0;

    // Tab pill factory block
    void (^makeTabPill)(NSInteger, NSString*, CGFloat, BOOL) =
        ^(NSInteger tag, NSString *title, CGFloat x, BOOL active) {
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.tag = tag;
        btn.frame = CGRectMake(x, kPillRowY, kTabPillW, kTabPillH);
        [btn setTitle:title forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
        btn.layer.cornerRadius = 6;
        btn.layer.borderWidth = 1;
        if (active) {
            btn.backgroundColor = [UIColor colorWithRed:0.10 green:0.30 blue:0.50 alpha:0.35];
            btn.layer.borderColor = [UIColor colorWithRed:0.5 green:0.9 blue:1.0 alpha:0.5].CGColor;
            [btn setTitleColor:[UIColor colorWithRed:0.5 green:0.9 blue:1.0 alpha:1] forState:UIControlStateNormal];
        } else {
            btn.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1];
            btn.layer.borderColor = [UIColor colorWithWhite:0.22 alpha:1].CGColor;
            [btn setTitleColor:[UIColor colorWithWhite:0.40 alpha:1] forState:UIControlStateNormal];
        }
        btn.autoresizingMask = UIViewAutoresizingFlexibleRightMargin;
        [btn addTarget:self action:@selector(tabTapped:) forControlEvents:UIControlEventTouchUpInside];
        [header addSubview:btn];
    };

    CGFloat t0x = 8;
    CGFloat t1x = t0x + kTabPillW + kTabPillGap;
    CGFloat t2x = t1x + kTabPillW + kTabPillGap;
    makeTabPill(4001, @"Shaders", t0x, YES);
    makeTabPill(4002, @"Memory",  t1x, NO);
    makeTabPill(4003, @"Export",  t2x, NO);

    // ── [🗑 Clear] pill — visible only in Memory tab, right after Export ────
    CGFloat clearPillX = t2x + kTabPillW + kTabPillGap;
    UIButton *clearPill = [UIButton buttonWithType:UIButtonTypeCustom];
    clearPill.tag = 4020;
    clearPill.frame = CGRectMake(clearPillX, kPillRowY, 52, kTabPillH);
    [clearPill setTitle:@"🗑 Clear" forState:UIControlStateNormal];
    clearPill.titleLabel.font = [UIFont boldSystemFontOfSize:10];
    clearPill.layer.cornerRadius = 6;
    clearPill.backgroundColor = [UIColor colorWithRed:0.55 green:0.08 blue:0.08 alpha:0.85];
    clearPill.layer.borderWidth = 1;
    clearPill.layer.borderColor = [UIColor colorWithRed:1.0 green:0.3 blue:0.3 alpha:0.6].CGColor;
    [clearPill setTitleColor:[UIColor colorWithRed:1.0 green:0.55 blue:0.55 alpha:1] forState:UIControlStateNormal];
    clearPill.autoresizingMask = UIViewAutoresizingFlexibleRightMargin;
    clearPill.hidden = YES;
    [clearPill addTarget:self action:@selector(clearMemoryTapped) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:clearPill];

    // ── Action buttons RIGHT: ↺ · 📍 · 📋 Log ────────────────────────────────
    // ↺ (rightmost)
    UIButton *clearBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    clearBtn.frame = CGRectMake(W - 34, btnY2, 30, kBtnH2);
    [clearBtn setTitle:@"↺" forState:UIControlStateNormal];
    [clearBtn setTitleColor:[UIColor colorWithWhite:0.50 alpha:1] forState:UIControlStateNormal];
    clearBtn.titleLabel.font = [UIFont systemFontOfSize:18];
    clearBtn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [clearBtn addTarget:self action:@selector(clearShaders) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:clearBtn];

    // 📍
    UIButton *markBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    markBtn.frame = CGRectMake(W - 68, btnY2, 30, kBtnH2);
    [markBtn setTitle:@"📍" forState:UIControlStateNormal];
    markBtn.titleLabel.font = [UIFont systemFontOfSize:16];
    markBtn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [markBtn addTarget:self action:@selector(markSession:) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:markBtn];

    // Credit label — flexible, between Clear pill and ↺ button
    CGFloat creditRightEdge = W - 68 - 4;
    CGFloat creditLeftEdge  = clearPillX + 52 + kTabPillGap + 4;
    CGFloat creditW = MAX(0, creditRightEdge - creditLeftEdge);
    CGFloat creditY = kPillRowY + (kTabPillH - 13) / 2.0;
    UILabel *credit = [[UILabel alloc] initWithFrame:CGRectMake(creditLeftEdge, creditY, creditW, 13)];
    credit.text = @"Made by Max-Q for Iosgods";
    credit.font = [UIFont systemFontOfSize:10];
    credit.textColor = [UIColor colorWithWhite:0.38 alpha:1];
    credit.adjustsFontSizeToFitWidth = YES;
    credit.minimumScaleFactor = 0.60;
    credit.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleLeftMargin;
    [header addSubview:credit];

    // Active indicator bar — 1/3 width per tab
    CGFloat tabW = W / 3.0;
    UIView *activeBar = [[UIView alloc] initWithFrame:CGRectMake(0, kHeaderH - 2, tabW, 2)];
    activeBar.backgroundColor = [UIColor colorWithRed:0.5 green:0.9 blue:1.0 alpha:0.6];
    activeBar.tag = 4010;
    activeBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [header addSubview:activeBar];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
                                   initWithTarget:self action:@selector(handleHeaderDrag:)];
    [header addGestureRecognizer:pan];

    // Tap header → close menu (fires headerTappedHandler)
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
                                   initWithTarget:self action:@selector(handleHeaderTap:)];
    tap.cancelsTouchesInView = NO;
    tap.delegate = self; // gestureRecognizer:shouldReceiveTouch: ignora i bottoni
    [header addGestureRecognizer:tap];

    // ── Search bar (left half) + Jump-to field (right half) + LIVE + sort button ─
    static const CGFloat kSortBtnW = 28;
    static const CGFloat kLiveBtnW = 34;
    static const CGFloat kDividerW = 1;
    // Split available space in half (minus sort btn + live btn)
    CGFloat availW     = W - kSortBtnW - kLiveBtnW - 3;
    CGFloat halfW      = availW / 2.0;

    UIView *searchBg = [[UIView alloc] initWithFrame:CGRectMake(0, kHeaderH, W, kSearchH)];
    searchBg.tag = 9901;
    searchBg.backgroundColor = [UIColor colorWithRed:0.06 green:0.06 blue:0.10 alpha:1];
    searchBg.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self addSubview:searchBg];

    // Sort button — far right
    UIButton *sortBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    sortBtn.tag = 9902;
    sortBtn.frame = CGRectMake(W - kSortBtnW, 2, kSortBtnW - 2, kSearchH - 4);
    [sortBtn setTitle:@"↕" forState:UIControlStateNormal];
    [sortBtn setTitleColor:[UIColor colorWithWhite:0.38 alpha:1] forState:UIControlStateNormal];
    sortBtn.titleLabel.font = [UIFont systemFontOfSize:13];
    sortBtn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [sortBtn addTarget:self action:@selector(sortBtnTapped:) forControlEvents:UIControlEventTouchUpInside];
    [searchBg addSubview:sortBtn];

    // LIVE filter button — left of sort button
    UIButton *liveBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    liveBtn.tag = 9903;
    liveBtn.frame = CGRectMake(W - kSortBtnW - kLiveBtnW - 1, 2, kLiveBtnW - 1, kSearchH - 4);
    [liveBtn setTitle:@"🟢" forState:UIControlStateNormal];
    liveBtn.titleLabel.font = [UIFont systemFontOfSize:13];
    liveBtn.layer.cornerRadius = 4;
    liveBtn.clipsToBounds = YES;
    liveBtn.backgroundColor = [UIColor colorWithWhite:0.13 alpha:1];
    liveBtn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [liveBtn addTarget:self action:@selector(liveBtnTapped:) forControlEvents:UIControlEventTouchUpInside];
    [searchBg addSubview:liveBtn];

    // ── Left half: smart search field ────────────────────────────────────────
    // self.searchField intentionally stays nil → applyFilter treats manual q as ""
    self.smartField = [[UITextField alloc] initWithFrame:CGRectMake(2, 3, halfW - 4, kSearchH - 6)];
    self.smartField.backgroundColor = [UIColor colorWithRed:0.14 green:0.09 blue:0.02 alpha:0.25];
    self.smartField.textColor = [UIColor colorWithRed:1.0 green:0.85 blue:0.45 alpha:1];
    self.smartField.font = [UIFont systemFontOfSize:10];
    self.smartField.layer.cornerRadius = 5;
    self.smartField.layer.borderWidth = 0;
    self.smartField.clipsToBounds = YES;
    self.smartField.returnKeyType = UIReturnKeySearch;
    self.smartField.autocorrectionType  = UITextAutocorrectionTypeNo;
    self.smartField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.smartField.keyboardAppearance = UIKeyboardAppearanceDark;
    self.smartField.delegate = self;
    self.smartField.attributedPlaceholder = [[NSAttributedString alloc]
        initWithString:@"🧠 weapon · outline…"
            attributes:@{NSForegroundColorAttributeName:[UIColor colorWithRed:0.55 green:0.40 blue:0.10 alpha:0.80],
                         NSFontAttributeName:[UIFont systemFontOfSize:10]}];
    UIView *smartPad = [[UIView alloc] initWithFrame:CGRectMake(0,0,6,16)];
    self.smartField.leftView = smartPad;
    self.smartField.leftViewMode = UITextFieldViewModeAlways;
    // Composite rightView: count label (tag=700) + ✕ clear button
    CGFloat fieldH = kSearchH - 6;
    UIView *rightContainer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 54, fieldH)];

    UILabel *countInBar = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 32, fieldH)];
    countInBar.tag = 700;
    countInBar.font = [UIFont boldSystemFontOfSize:9];
    countInBar.textAlignment = NSTextAlignmentRight;
    countInBar.textColor = [UIColor colorWithWhite:0.55 alpha:1];
    countInBar.adjustsFontSizeToFitWidth = YES;
    countInBar.minimumScaleFactor = 0.7;
    [rightContainer addSubview:countInBar];

    UIButton *xBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    xBtn.frame = CGRectMake(32, 0, 22, fieldH);
    [xBtn setTitle:@"✕" forState:UIControlStateNormal];
    [xBtn setTitleColor:[UIColor colorWithWhite:0.45 alpha:1] forState:UIControlStateNormal];
    xBtn.titleLabel.font = [UIFont systemFontOfSize:11];
    [xBtn addTarget:self action:@selector(clearSearchTapped) forControlEvents:UIControlEventTouchUpInside];
    [rightContainer addSubview:xBtn];

    self.smartField.rightView = rightContainer;
    self.smartField.rightViewMode = UITextFieldViewModeAlways;
    [self.smartField addTarget:self action:@selector(smartSearchChanged:)
               forControlEvents:UIControlEventEditingChanged];
    [searchBg addSubview:self.smartField];

    // Center divider between the two fields
    UIView *midDiv = [[UIView alloc] initWithFrame:CGRectMake(halfW, 4, kDividerW, kSearchH - 8)];
    midDiv.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10];
    [searchBg addSubview:midDiv];

    // ── Right half: Jump-to field ─────────────────────────────────────────────
    self.jumpField = [[UITextField alloc] initWithFrame:CGRectMake(halfW + kDividerW + 2, 3, halfW - 4, kSearchH - 6)];
    self.jumpField.backgroundColor = [UIColor colorWithRed:0.04 green:0.12 blue:0.20 alpha:0.35];
    self.jumpField.textColor = [UIColor colorWithRed:0.55 green:0.90 blue:1.0 alpha:1];
    self.jumpField.font = [UIFont fontWithName:@"Courier" size:11] ?: [UIFont systemFontOfSize:11];
    self.jumpField.layer.cornerRadius = 5;
    self.jumpField.clipsToBounds = YES;
    self.jumpField.returnKeyType = UIReturnKeyGo;
    self.jumpField.keyboardType = UIKeyboardTypeDefault;
    self.jumpField.autocorrectionType  = UITextAutocorrectionTypeNo;
    self.jumpField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.jumpField.keyboardAppearance = UIKeyboardAppearanceDark;
    self.jumpField.delegate = self;
    self.jumpField.attributedPlaceholder = [[NSAttributedString alloc]
        initWithString:@"→ v130 · f200"
            attributes:@{NSForegroundColorAttributeName:[UIColor colorWithRed:0.25 green:0.55 blue:0.70 alpha:0.80],
                         NSFontAttributeName:[UIFont fontWithName:@"Courier" size:10] ?: [UIFont systemFontOfSize:10]}];
    UIView *jumpPad = [[UIView alloc] initWithFrame:CGRectMake(0,0,6,16)];
    self.jumpField.leftView = jumpPad;
    self.jumpField.leftViewMode = UITextFieldViewModeAlways;
    // ✕ clear button — visible while editing
    UIButton *jumpX = [UIButton buttonWithType:UIButtonTypeCustom];
    jumpX.frame = CGRectMake(0, 0, 22, kSearchH - 6);
    [jumpX setTitle:@"✕" forState:UIControlStateNormal];
    [jumpX setTitleColor:[UIColor colorWithWhite:0.45 alpha:1] forState:UIControlStateNormal];
    jumpX.titleLabel.font = [UIFont systemFontOfSize:11];
    [jumpX addTarget:self action:@selector(clearJumpTapped) forControlEvents:UIControlEventTouchUpInside];
    self.jumpField.rightView = jumpX;
    self.jumpField.rightViewMode = UITextFieldViewModeWhileEditing;
    [searchBg addSubview:self.jumpField];

    UIView *divider = [[UIView alloc] initWithFrame:CGRectMake(0, kHeaderH + kTabH + kSearchH, W, 1)];
    divider.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    divider.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self addSubview:divider];

    // ── Table view (full remaining height, no footer) ──
    self.shaderList = [[UITableView alloc]
                       initWithFrame:CGRectMake(0, kListStart, W,
                                                self.bounds.size.height - kListStart - 1)
                               style:UITableViewStylePlain];
    self.shaderList.backgroundColor = [UIColor clearColor];
    self.shaderList.separatorColor  = [UIColor colorWithWhite:1 alpha:0.07];
    self.shaderList.separatorInset  = UIEdgeInsetsZero;
    self.shaderList.delegate        = self;
    self.shaderList.dataSource      = self;
    self.shaderList.showsVerticalScrollIndicator = YES;
    self.shaderList.alwaysBounceVertical         = YES;
    self.shaderList.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.shaderList.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self addSubview:self.shaderList];

    // Thin bottom border (1px) instead of footer bar
    UIView *bottomLine = [[UIView alloc]
                          initWithFrame:CGRectMake(0, self.bounds.size.height - 1, W, 1)];
    bottomLine.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10];
    bottomLine.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    [self addSubview:bottomLine];

    // ── Export tab view (hidden by default, same rect as shaderList) ──────────
    CGFloat exportY = kListStart;
    CGFloat exportH = self.bounds.size.height - exportY - 1;
    _exportView = [[UIView alloc] initWithFrame:CGRectMake(0, exportY, W, exportH)];
    _exportView.backgroundColor = [UIColor clearColor];
    _exportView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _exportView.hidden = YES;

    // Info header label
    UILabel *expInfo = [[UILabel alloc] initWithFrame:CGRectMake(8, 6, W - 16, 30)];
    expInfo.text = @"File .m pronto — includilo nel tuo progetto Theos e compila con make package";
    expInfo.font = [UIFont systemFontOfSize:10];
    expInfo.textColor = [UIColor colorWithWhite:0.50 alpha:1];
    expInfo.numberOfLines = 2;
    expInfo.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [_exportView addSubview:expInfo];

    // Source text view
    static const CGFloat kExpBtnH  = 38;
    static const CGFloat kExpInfoH = 34;
    _exportTextView = [[UITextView alloc] initWithFrame:
        CGRectMake(0, kExpInfoH, W, exportH - kExpInfoH - kExpBtnH - 6)];
    _exportTextView.backgroundColor = [UIColor colorWithRed:0.04 green:0.04 blue:0.07 alpha:1];
    _exportTextView.textColor       = [UIColor colorWithRed:0.6 green:1.0 blue:0.7 alpha:1];
    _exportTextView.font            = [UIFont fontWithName:@"Courier" size:9];
    _exportTextView.editable        = NO;
    _exportTextView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _exportTextView.text = @"// Nessuno shader salvato in Memory.\n// Aggiungi ★ agli shader che vuoi esportare, poi torna qui.";
    [_exportView addSubview:_exportTextView];

    // Export button (bottom)
    UIButton *expBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    expBtn.frame = CGRectMake(8, exportH - kExpBtnH - 2, W - 16, kExpBtnH);
    expBtn.backgroundColor = [UIColor colorWithRed:0.08 green:0.42 blue:0.15 alpha:0.90];
    expBtn.layer.cornerRadius = 8;
    expBtn.layer.borderWidth  = 1;
    expBtn.layer.borderColor  = [UIColor colorWithRed:0.35 green:1.0 blue:0.5 alpha:0.6].CGColor;
    [expBtn setTitle:@"📤  Esporta  exported_patches.m" forState:UIControlStateNormal];
    [expBtn setTitleColor:[UIColor colorWithRed:0.5 green:1.0 blue:0.65 alpha:1] forState:UIControlStateNormal];
    expBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    expBtn.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    [expBtn addTarget:self action:@selector(_exportFileTapped) forControlEvents:UIControlEventTouchUpInside];
    [_exportView addSubview:expBtn];

    [self addSubview:_exportView];
}

- (void)logBtnTapped { if (self.logTappedHandler) self.logTappedHandler(); }

// ── Master hooks switch ────────────────────────────────────────────────────────

- (void)applyHookSwitchState:(BOOL)enabled {
    self.masterSwitchEnabled = enabled;
    UIButton *pill = (UIButton *)[self viewWithTag:4030];
    if (pill) {
        if (enabled) {
            pill.backgroundColor   = [UIColor colorWithRed:0.04 green:0.22 blue:0.08 alpha:1];
            pill.layer.borderColor = [UIColor colorWithRed:0.2 green:0.85 blue:0.35 alpha:0.8].CGColor;
            [pill setTitleColor:[UIColor colorWithRed:0.2 green:0.9 blue:0.4 alpha:1]
                       forState:UIControlStateNormal];
            [pill setTitle:@"⚡ ON"  forState:UIControlStateNormal];
        } else {
            pill.backgroundColor   = [UIColor colorWithWhite:0.08 alpha:1];
            pill.layer.borderColor = [UIColor colorWithRed:0.85 green:0.2 blue:0.2 alpha:0.7].CGColor;
            [pill setTitleColor:[UIColor colorWithRed:0.85 green:0.3 blue:0.3 alpha:1]
                       forState:UIControlStateNormal];
            [pill setTitle:@"⚡ OFF" forState:UIControlStateNormal];
        }
    }
}

- (void)hookSwitchTapped:(UIButton *)sender {
    [self applyHookSwitchState:!self.masterSwitchEnabled];
    if (self.hookSwitchChangedHandler) self.hookSwitchChangedHandler(self.masterSwitchEnabled);
}

// ── setupDetailView ────────────────────────────────────────────────────────────

- (void)setupDetailView {
    CGFloat W = self.bounds.size.width;
    self.detailView = [[UIView alloc] initWithFrame:self.bounds];
    self.detailView.backgroundColor = [UIColor colorWithRed:0.05 green:0.05 blue:0.08 alpha:1];
    self.detailView.hidden = YES;
    self.detailView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    // Draggable header (added first → behind buttons)
    UIView *detailHeader = [[UIView alloc] initWithFrame:CGRectMake(0, 0, W, 42)];
    detailHeader.backgroundColor = [UIColor colorWithRed:0.07 green:0.07 blue:0.12 alpha:1];
    detailHeader.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    UIPanGestureRecognizer *detailPan = [[UIPanGestureRecognizer alloc]
                                         initWithTarget:self action:@selector(handleHeaderDrag:)];
    detailPan.cancelsTouchesInView = NO;
    [detailHeader addGestureRecognizer:detailPan];
    UIView *dpill = [[UIView alloc] initWithFrame:CGRectMake((W - 28) / 2, 5, 28, 3)];
    dpill.backgroundColor = [UIColor colorWithWhite:1 alpha:0.18];
    dpill.layer.cornerRadius = 1.5;
    dpill.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    [detailHeader addSubview:dpill];
    [self.detailView addSubview:detailHeader];

    self.backBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    self.backBtn.frame = CGRectMake(8, 6, 70, 30);
    [self.backBtn setTitle:@"‹ Back" forState:UIControlStateNormal];
    [self.backBtn setTitleColor:[UIColor colorWithRed:0.6 green:0.9 blue:1 alpha:1] forState:UIControlStateNormal];
    self.backBtn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    [self.backBtn addTarget:self action:@selector(closeDetail) forControlEvents:UIControlEventTouchUpInside];
    [self.detailView addSubview:self.backBtn];

    UIButton *dClose = [UIButton buttonWithType:UIButtonTypeCustom];
    dClose.frame = CGRectMake(W - 38, 6, 30, 30);
    [dClose setTitle:@"✕" forState:UIControlStateNormal];
    [dClose setTitleColor:[UIColor colorWithWhite:0.55 alpha:1] forState:UIControlStateNormal];
    dClose.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    dClose.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [dClose addTarget:self action:@selector(closeSelf) forControlEvents:UIControlEventTouchUpInside];
    [self.detailView addSubview:dClose];

    UILabel *nameLabel = [[UILabel alloc] initWithFrame:CGRectMake(80, 6, W - 130, 30)];
    nameLabel.textColor = [UIColor colorWithWhite:0.6 alpha:1];
    nameLabel.font = [UIFont fontWithName:@"Courier" size:10];
    nameLabel.tag  = 801;
    nameLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.detailView addSubview:nameLabel];

    UIView *div = [[UIView alloc] initWithFrame:CGRectMake(0, 42, W, 1)];
    div.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    div.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.detailView addSubview:div];

    self.errorLabel = [[UILabel alloc] initWithFrame:CGRectMake(8, 46, W - 16, 0)];
    self.errorLabel.textColor = [UIColor colorWithRed:1 green:0.35 blue:0.35 alpha:1];
    self.errorLabel.backgroundColor = [UIColor colorWithRed:0.3 green:0 blue:0 alpha:0.3];
    self.errorLabel.font = [UIFont fontWithName:@"Courier" size:10];
    self.errorLabel.numberOfLines = 0;
    self.errorLabel.hidden = YES;
    self.errorLabel.layer.cornerRadius = 6;
    self.errorLabel.clipsToBounds = YES;
    self.errorLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.detailView addSubview:self.errorLabel];

    self.sourceTextView = [[UITextView alloc]
                           initWithFrame:CGRectMake(0, 46, W, self.bounds.size.height - 90)];
    self.sourceTextView.backgroundColor = [UIColor colorWithRed:0.06 green:0.06 blue:0.10 alpha:1];
    self.sourceTextView.textColor = [UIColor colorWithRed:0.85 green:0.85 blue:0.6 alpha:1];
    self.sourceTextView.font = [UIFont fontWithName:@"Courier" size:10];
    self.sourceTextView.editable = NO;
    self.sourceTextView.scrollEnabled = YES;
    self.sourceTextView.tag  = 802;
    self.sourceTextView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.detailView addSubview:self.sourceTextView];

    UIView *div2 = [[UIView alloc] initWithFrame:CGRectMake(0, self.bounds.size.height - 46, W, 1)];
    div2.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    div2.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    [self.detailView addSubview:div2];

    self.srcCopyBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    self.srcCopyBtn.frame = CGRectMake(8, self.bounds.size.height - 42, W - 16, 34);
    self.srcCopyBtn.backgroundColor = [UIColor colorWithRed:0.6 green:0.9 blue:1 alpha:0.12];
    self.srcCopyBtn.layer.cornerRadius = 8;
    self.srcCopyBtn.layer.borderWidth  = 1;
    self.srcCopyBtn.layer.borderColor  = [UIColor colorWithRed:0.6 green:0.9 blue:1 alpha:0.35].CGColor;
    [self.srcCopyBtn setTitle:@"⎘  Copy Source" forState:UIControlStateNormal];
    [self.srcCopyBtn setTitleColor:[UIColor colorWithRed:0.6 green:0.9 blue:1 alpha:1] forState:UIControlStateNormal];
    self.srcCopyBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    self.srcCopyBtn.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    [self.srcCopyBtn addTarget:self action:@selector(copySource)
              forControlEvents:UIControlEventTouchUpInside];
    [self.detailView addSubview:self.srcCopyBtn];

    [self addSubview:self.detailView];
}

// ── Patch persistence (NSUserDefaults — sopravvive al riavvio) ────────────────

static NSString * const kPatchDefaultsKey = @"FMSavedPatches_v3";

// ── Stable persistence key: function name + source char-length ─────────────────
// Source length is invariant between sessions for the same app version.
// Avoids using [source hash] (per-process salted on iOS) or full-source DJB2
// (breaks if Unity changes even one embedded constant between sessions).
static NSString *fmStableKey(NSString *name, NSString *source) {
    // Use content hash (not length) — UE shaders have same name AND same length → dedup
    NSUInteger h = [(source ?: @"") hash];
    return [NSString stringWithFormat:@"%@_%lx", name ?: @"unnamed", (unsigned long)h];
}

- (void)_loadPatchCache {
    NSDictionary *raw = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kPatchDefaultsKey];
    _savedPatchCache = raw ? [raw mutableCopy] : [NSMutableDictionary dictionary];
}

- (void)_persistEntry:(ShaderEntry *)entry {
    if (!entry || entry.isDivider || !entry.name.length || !entry.stableKey.length) return;
    BOOL hasAny = entry.isSaved
               || entry.patchFragColor != FragPatchNone
               || entry.patchFlash
               || entry.patchVertex;
    if (hasAny) {
        _savedPatchCache[entry.stableKey] = @{
            @"s": @(entry.isSaved),
            @"c": @((NSInteger)entry.patchFragColor),
            @"f": @(entry.patchFlash),
            @"v": @(entry.patchVertex),
            @"n": entry.customName ?: @"",
        };
    } else {
        [_savedPatchCache removeObjectForKey:entry.stableKey];
    }
    [[NSUserDefaults standardUserDefaults] setObject:[_savedPatchCache copy]
                                             forKey:kPatchDefaultsKey];
}

// ── UIGestureRecognizerDelegate — ignora tap-to-close se tocca un UIButton ────

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gr shouldReceiveTouch:(UITouch *)touch {
    UIView *v = touch.view;
    while (v) {
        if ([v isKindOfClass:[UIButton class]]) return NO;
        v = v.superview;
    }
    return YES;
}

// ── Long press su cella → dialog rinomina ─────────────────────────────────────

- (void)longPressCellRecognized:(UILongPressGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateBegan) return;
    ShaderEntry *entry = objc_getAssociatedObject(gr, &kEntryKey);
    if (!entry || entry.isDivider) return;

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"✏️ Rinomina shader"
        message:nil
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = entry.customName.length ? entry.customName : (entry.displayName.length ? entry.displayName : entry.name);
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Annulla" style:UIAlertActionStyleCancel handler:nil]];
    __weak ShaderPage *ws = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"💾 Salva" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *newName = [alert.textFields.firstObject.text
                             stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (newName.length > 0) {
            entry.customName = newName;
            entry.isSaved    = YES; // rinominare implica salvataggio
            ShaderPage *sp = ws;
            if (!sp) return;
            [sp _persistEntry:entry];
            dispatch_async(dispatch_get_main_queue(), ^{
                [sp.shaderList reloadData];
            });
        }
    }]];

    UIViewController *vc = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w.isKeyWindow) { vc = w.rootViewController; break; }
        }
        if (vc) break;
    }
    while (vc.presentedViewController) vc = vc.presentedViewController;
    [vc presentViewController:alert animated:YES completion:nil];
}

// ── Header tap → close menu ───────────────────────────────────────────────────

- (void)handleHeaderTap:(UITapGestureRecognizer *)tap {
    if (self.headerTappedHandler) self.headerTappedHandler();
}

// ── Search clear ✕ ────────────────────────────────────────────────────────────

- (void)clearJumpTapped {
    self.jumpField.text = @"";
    [self.jumpField resignFirstResponder];
    self.jumpField.layer.borderWidth = 0;
}

- (void)clearSearchTapped {
    self.smartField.text = @"";
    [self.smartField resignFirstResponder];
    [self smartSearchChanged:self.smartField];
}

// ── Drag ──────────────────────────────────────────────────────────────────────

- (void)handleHeaderDrag:(UIPanGestureRecognizer *)pan {
    UIView *parent = self.superview;
    if (!parent) return;
    CGPoint t = [pan translationInView:parent];
    CGRect f = self.frame;
    f.origin.x += t.x; f.origin.y += t.y;
    CGSize s = [UIScreen mainScreen].bounds.size;
    // Allow partial off-screen movement (min 60 pt visible)
    static const CGFloat kVis = 60;
    f.origin.x = MAX(-(f.size.width - kVis), MIN(s.width  - kVis, f.origin.x));
    f.origin.y = MAX(16,                      MIN(s.height - kVis, f.origin.y));
    self.frame = f;
    [pan setTranslation:CGPointZero inView:parent];
}

// ── Expand ────────────────────────────────────────────────────────────────────

- (void)expandBtnTapped:(UIButton *)sender {
    _expanded = !_expanded;
    UIButton *btn = (UIButton *)[self viewWithTag:9901];
    [btn setTitle:_expanded ? @"⇱" : @"⇲" forState:UIControlStateNormal];

    if (_expanded) {
        _originalFrame = self.frame;
        CGSize screen  = [UIScreen mainScreen].bounds.size;
        CGFloat newW   = self.frame.size.width;                             // width unchanged
        CGFloat newH   = MIN(self.frame.size.height * 1.6, screen.height - 60);
        CGFloat newX   = MAX(8, MIN(self.frame.origin.x, screen.width  - newW - 8));
        CGFloat newY   = MAX(20, MIN(self.frame.origin.y, screen.height - newH - 20));
        [UIView animateWithDuration:0.28 delay:0
             usingSpringWithDamping:0.82 initialSpringVelocity:0.3 options:0
                         animations:^{ self.frame = CGRectMake(newX, newY, newW, newH); }
                         completion:nil];
    } else {
        [UIView animateWithDuration:0.25 delay:0
             usingSpringWithDamping:0.85 initialSpringVelocity:0.2 options:0
                         animations:^{ self.frame = _originalFrame; }
                         completion:nil];
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.32 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self.shaderList reloadData];
    });
}

// ── Tabs ──────────────────────────────────────────────────────────────────────

- (void)tabTapped:(UIButton *)sender {
    NSInteger newTab = (sender.tag == 4001) ? 0 : (sender.tag == 4002) ? 1 : 2;

    // Save scroll position when leaving Shaders tab (tab 0)
    if (_currentTab == 0 && newTab != 0) {
        _savedShaderScrollOffset = self.shaderList.contentOffset;
    }

    _currentTab = newTab;

    // Style all three tab pills
    NSInteger tags[] = {4001, 4002, 4003};
    UIColor *activeColors[] = {
        [UIColor colorWithRed:0.5 green:0.9 blue:1.0 alpha:1],   // Shaders — cyan
        [UIColor colorWithRed:1.0 green:0.85 blue:0.2 alpha:1],  // Memory  — yellow
        [UIColor colorWithRed:0.5 green:1.0 blue:0.6 alpha:1],   // Export  — green
    };
    for (int i = 0; i < 3; i++) {
        UIButton *b = (UIButton *)[self viewWithTag:tags[i]];
        if (!b) continue;
        BOOL on = (i == newTab);
        b.backgroundColor = on
            ? [UIColor colorWithRed:0.10 green:0.30 blue:0.50 alpha:0.35]
            : [UIColor colorWithWhite:0.08 alpha:1];
        b.layer.borderColor = on
            ? activeColors[i].CGColor
            : [UIColor colorWithWhite:0.22 alpha:1].CGColor;
        [b setTitleColor:on ? activeColors[i] : [UIColor colorWithWhite:0.40 alpha:1]
                forState:UIControlStateNormal];
    }

    // Active indicator bar slides to the active 1/3
    UIView *activeBar = [self viewWithTag:4010];
    if (activeBar) {
        CGFloat tW = self.bounds.size.width / 3.0;
        [UIView animateWithDuration:0.15 animations:^{
            activeBar.frame = CGRectMake(tW * newTab, kHeaderH - 2, tW, 2);
        }];
    }

    // Clear pill: visible only in Memory tab
    UIButton *clearPill = (UIButton *)[self viewWithTag:4020];
    clearPill.hidden = (newTab != 1);

    // Export view: show/hide + regenerate source when entering tab
    if (_exportView) {
        _exportView.hidden = (newTab != 2);
        if (newTab == 2) [self _regenerateExportSource];
    }

    // List/search: hidden when Export tab is active
    self.shaderList.hidden = (newTab == 2);
    UIView *searchBg = [self viewWithTag:9901];
    if (searchBg) searchBg.hidden = (newTab == 2);

    if (newTab != 2) {
        [self applyFilter];
        // Restore scroll position when returning to Shaders tab
        if (newTab == 0 && (_savedShaderScrollOffset.y > 0 || _savedShaderScrollOffset.x > 0)) {
            CGPoint saved = _savedShaderScrollOffset;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                CGFloat maxY = MAX(0, self.shaderList.contentSize.height - self.shaderList.bounds.size.height);
                CGPoint target = CGPointMake(0, MIN(saved.y, maxY));
                [self.shaderList setContentOffset:target animated:NO];
            });
        }
    }
}

// ── Session mark ──────────────────────────────────────────────────────────────

- (void)markSession:(UIButton *)sender {
    NSDateFormatter *fmt = [NSDateFormatter new];
    fmt.dateFormat = @"HH:mm:ss";
    NSString *label = [NSString stringWithFormat:@"── Partita avviata %@ ──",
                       [fmt stringFromDate:[NSDate date]]];
    [self insertSessionDivider:label];
    [sender setTitle:@"✓" forState:UIControlStateNormal];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [sender setTitle:@"📍" forState:UIControlStateNormal];
    });
}

- (void)insertSessionDivider:(NSString *)label {
    ShaderEntry *div = [ShaderEntry new];
    div.name      = label ?: @"── Sezione ──";
    div.isDivider = YES;
    NSCharacterSet *ws2 = [NSCharacterSet whitespaceCharacterSet];
    NSString *q  = [(self.searchField.text ?: @"") stringByTrimmingCharactersInSet:ws2];
    NSString *sq = [(self.smartField.text  ?: @"") stringByTrimmingCharactersInSet:ws2];
    [self.shaders addObject:div];
    if (_currentTab == 0 && q.length == 0 && sq.length == 0) [self.filteredShaders addObject:div];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.shaderList reloadData];
        if (self.filteredShaders.count > 0) {
            NSIndexPath *ip = [NSIndexPath indexPathForRow:(NSInteger)self.filteredShaders.count - 1 inSection:0];
            [self.shaderList scrollToRowAtIndexPath:ip atScrollPosition:UITableViewScrollPositionBottom animated:YES];
        }
    });
}

// ── LIVE filter ────────────────────────────────────────────────────────────────

- (void)liveBtnTapped:(UIButton *)sender {
    if (_liveFilterActive) {
        // Turn OFF: clear snapshot, restore full list
        _liveFilterActive    = NO;
        _liveSnapshotHashes  = nil;
        sender.backgroundColor = [UIColor colorWithWhite:0.13 alpha:1];
        [sender setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    } else {
        // Turn ON: take snapshot of hashes active in the CURRENT frame, then filter
        _liveSnapshotHashes  = fmCopyLiveActiveHashes();
        _liveFilterActive    = YES;
        sender.backgroundColor = [UIColor colorWithRed:0.08 green:0.42 blue:0.12 alpha:1];
        [sender setTitleColor:[UIColor colorWithRed:0.3 green:1.0 blue:0.45 alpha:1]
                     forState:UIControlStateNormal];
    }
    [self applyFilter];
}

// ── Sort ──────────────────────────────────────────────────────────────────────

- (void)sortBtnTapped:(UIButton *)sender {
    _sortMode = (_sortMode + 1) % 3;
    NSString *titles[] = {@"↕", @"↑", @"↓"};
    UIColor  *colors[] = {
        [UIColor colorWithWhite:0.38 alpha:1],
        [UIColor colorWithRed:0.35 green:0.9 blue:0.35 alpha:1],
        [UIColor colorWithRed:0.9  green:0.5 blue:0.25 alpha:1],
    };
    [sender setTitle:titles[_sortMode] forState:UIControlStateNormal];
    [sender setTitleColor:colors[_sortMode] forState:UIControlStateNormal];
    [self applyFilter];
}

// ── Actions ────────────────────────────────────────────────────────────────────

- (void)closeSelf {
    [self.searchField resignFirstResponder];
    [self.smartField  resignFirstResponder];
    [UIView animateWithDuration:0.18 animations:^{
        self.alpha = 0;
        self.transform = CGAffineTransformMakeScale(0.94, 0.94);
    } completion:^(BOOL f) {
        self.hidden = YES; self.alpha = 1; self.transform = CGAffineTransformIdentity;
    }];
}

- (void)searchChanged:(UITextField *)field    { [self applyFilter]; }
- (void)smartSearchChanged:(UITextField *)field { [self applyFilter]; }

- (BOOL)textFieldShouldReturn:(UITextField *)tf {
    [tf resignFirstResponder];

    // ── Jump-to field: parse "v130" or "f200" ────────────────────────────────
    if (tf == self.jumpField) {
        [self performJumpToString:tf.text];
        return YES;
    }

    // ── Smart search: scroll to first result ─────────────────────────────────
    NSInteger target = -1;
    for (NSInteger i = 0; i < (NSInteger)self.filteredShaders.count; i++) {
        if (!self.filteredShaders[i].isDivider) { target = i; break; }
    }
    if (target >= 0) {
        NSIndexPath *ip = [NSIndexPath indexPathForRow:target inSection:0];
        [self.shaderList scrollToRowAtIndexPath:ip atScrollPosition:UITableViewScrollPositionTop animated:YES];
        [self.shaderList selectRowAtIndexPath:ip animated:YES scrollPosition:UITableViewScrollPositionTop];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self.shaderList deselectRowAtIndexPath:ip animated:YES];
        });
    }
    return YES;
}

- (void)performJumpToString:(NSString *)raw {
    // Accept: "v130", "V130", "f200", "F200" (with optional leading spaces)
    NSString *s = [[raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] lowercaseString];
    if (s.length < 2) return;

    unichar typeChar = [s characterAtIndex:0];
    BOOL wantVert = (typeChar == 'v');
    BOOL wantFrag = (typeChar == 'f');
    if (!wantVert && !wantFrag) return;

    NSInteger targetNum = [[s substringFromIndex:1] integerValue];
    if (targetNum <= 0) return;

    // Search the FULL shaders list (not filtered — jump ignores current filter)
    NSInteger rowInFiltered = -1;
    for (NSInteger i = 0; i < (NSInteger)self.filteredShaders.count; i++) {
        ShaderEntry *e = self.filteredShaders[i];
        if (e.isDivider) continue;
        BOOL match = (wantVert && e.vertIndex == targetNum) ||
                     (wantFrag && e.fragIndex == targetNum);
        if (match) { rowInFiltered = i; break; }
    }

    if (rowInFiltered < 0) {
        // Not in current filter — temporarily clear filter then jump
        NSString *prevSmart = self.smartField.text;
        self.smartField.text = @"";
        [self applyFilter];
        for (NSInteger i = 0; i < (NSInteger)self.filteredShaders.count; i++) {
            ShaderEntry *e = self.filteredShaders[i];
            if (e.isDivider) continue;
            BOOL match = (wantVert && e.vertIndex == targetNum) ||
                         (wantFrag && e.fragIndex == targetNum);
            if (match) { rowInFiltered = i; break; }
        }
        if (rowInFiltered < 0) {
            // Not found: restore filter
            self.smartField.text = prevSmart;
            [self applyFilter];
            // Flash the jump field red to signal not found
            UIColor *orig = self.jumpField.backgroundColor;
            self.jumpField.backgroundColor = [UIColor colorWithRed:0.5 green:0.05 blue:0.05 alpha:0.7];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                self.jumpField.backgroundColor = orig;
            });
            return;
        }
    }

    NSIndexPath *ip = [NSIndexPath indexPathForRow:rowInFiltered inSection:0];
    [self.shaderList scrollToRowAtIndexPath:ip atScrollPosition:UITableViewScrollPositionMiddle animated:YES];
    [self.shaderList selectRowAtIndexPath:ip animated:YES scrollPosition:UITableViewScrollPositionMiddle];
    // Flash cyan border on jump field to confirm
    self.jumpField.layer.borderWidth = 1.5;
    self.jumpField.layer.borderColor = [UIColor colorWithRed:0.3 green:0.9 blue:1.0 alpha:1].CGColor;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self.shaderList deselectRowAtIndexPath:ip animated:YES];
        self.jumpField.layer.borderWidth = 0;
    });
}

// ── Smart search alias dictionary (IT + EN → technical keywords) ──────────────
static NSDictionary<NSString *, NSArray<NSString *> *> *fmSmartAliases(void) {
    static NSDictionary *d = nil;
    static dispatch_once_t t;
    dispatch_once(&t, ^{
        d = @{
            // ── Players / characters
            @"giocatore":   @[@"player",@"character",@"hero",@"skin",@"human",@"soldier",@"actor",@"avatar",@"body",@"enemy"],
            @"giocatori":   @[@"player",@"character",@"hero",@"skin",@"human",@"soldier",@"actor",@"avatar",@"body",@"enemy"],
            @"player":      @[@"player",@"character",@"hero",@"skin",@"human",@"soldier",@"actor",@"avatar",@"body",@"enemy"],
            @"personaggio":  @[@"player",@"character",@"hero",@"skin",@"human",@"actor",@"avatar",@"body"],
            @"nemico":      @[@"enemy",@"npc",@"bot",@"opponent",@"hostile",@"foe"],
            @"enemy":       @[@"enemy",@"npc",@"bot",@"opponent",@"hostile",@"foe"],
            // ── Weapons / guns
            @"arma":        @[@"weapon",@"gun",@"rifle",@"pistol",@"bullet",@"ammo",@"firearm",@"muzzle",@"barrel",@"scope"],
            @"armi":        @[@"weapon",@"gun",@"rifle",@"pistol",@"bullet",@"ammo",@"firearm",@"muzzle",@"barrel",@"scope"],
            @"weapon":      @[@"weapon",@"gun",@"rifle",@"pistol",@"bullet",@"ammo",@"firearm",@"muzzle",@"barrel"],
            @"gun":         @[@"weapon",@"gun",@"rifle",@"pistol",@"bullet",@"ammo",@"firearm"],
            @"proiettile":  @[@"bullet",@"projectile",@"shot",@"ammo",@"round",@"tracer"],
            @"bullet":      @[@"bullet",@"projectile",@"shot",@"ammo",@"round",@"tracer"],
            // ── Explosions / particles / fire
            @"esplosione":  @[@"explosion",@"explode",@"blast",@"boom",@"particle",@"smoke",@"fire",@"flame",@"vfx"],
            @"explosion":   @[@"explosion",@"explode",@"blast",@"boom",@"particle",@"smoke",@"fire",@"flame"],
            @"fuoco":       @[@"fire",@"flame",@"smoke",@"particle",@"vfx",@"explosion",@"ember"],
            @"fire":        @[@"fire",@"flame",@"smoke",@"particle",@"ember"],
            @"particelle":  @[@"particle",@"vfx",@"effect",@"fx",@"emitter",@"spark"],
            @"particle":    @[@"particle",@"vfx",@"effect",@"fx",@"emitter",@"spark"],
            @"fumo":        @[@"smoke",@"fog",@"mist",@"haze",@"particle"],
            @"smoke":       @[@"smoke",@"fog",@"mist",@"haze",@"particle"],
            // ── Sky / environment
            @"cielo":       @[@"sky",@"cloud",@"skybox",@"atmosphere",@"fog",@"haze"],
            @"sky":         @[@"sky",@"cloud",@"skybox",@"atmosphere",@"fog"],
            @"nuvole":      @[@"cloud",@"sky",@"atmosphere",@"fog"],
            @"cloud":       @[@"cloud",@"sky",@"atmosphere"],
            // ── Terrain / ground
            @"terreno":     @[@"terrain",@"ground",@"dirt",@"grass",@"land",@"floor",@"surface",@"rock"],
            @"terrain":     @[@"terrain",@"ground",@"dirt",@"grass",@"land",@"floor",@"surface"],
            @"pavimento":   @[@"floor",@"ground",@"terrain",@"tile",@"surface"],
            // ── Water
            @"acqua":       @[@"water",@"liquid",@"ocean",@"wave",@"puddle",@"rain",@"wet",@"river"],
            @"water":       @[@"water",@"liquid",@"ocean",@"wave",@"puddle",@"rain"],
            // ── Shadows / depth
            @"ombra":       @[@"shadow",@"depth",@"stencil",@"dark",@"occlude"],
            @"shadow":      @[@"shadow",@"depth",@"stencil",@"occlude"],
            // ── Lighting
            @"luce":        @[@"light",@"lighting",@"specular",@"ambient",@"point",@"directional",@"bright",@"bloom"],
            @"light":       @[@"light",@"lighting",@"specular",@"ambient",@"point",@"directional"],
            // ── Post-processing
            @"postprocess": @[@"post",@"bloom",@"blur",@"dof",@"tonemap",@"vignette",@"color",@"grade"],
            @"post":        @[@"post",@"bloom",@"blur",@"dof",@"tonemap",@"vignette"],
            @"bloom":       @[@"bloom",@"glow",@"light",@"bright"],
            @"blur":        @[@"blur",@"dof",@"depth",@"bokeh"],
            // ── UI / HUD
            @"ui":          @[@"ui",@"hud",@"menu",@"button",@"text",@"overlay",@"icon",@"interface"],
            @"interfaccia": @[@"ui",@"hud",@"menu",@"button",@"text",@"overlay",@"interface"],
            @"hud":         @[@"hud",@"ui",@"overlay",@"icon",@"crosshair",@"minimap"],
            // ── Building / map
            @"edificio":    @[@"building",@"house",@"wall",@"room",@"structure",@"arch"],
            @"building":    @[@"building",@"house",@"wall",@"room",@"structure"],
            @"mappa":       @[@"map",@"level",@"scene",@"world",@"terrain"],
            @"map":         @[@"map",@"level",@"scene",@"world",@"terrain"],
            // ── Vehicles
            @"veicolo":     @[@"vehicle",@"car",@"tank",@"truck",@"jeep",@"wheels"],
            @"vehicle":     @[@"vehicle",@"car",@"tank",@"truck",@"jeep"],
        };
    });
    return d;
}

- (void)applyFilter {
    // Read both search fields (nil-safe)
    NSCharacterSet *ws = [NSCharacterSet whitespaceCharacterSet];
    NSString *q  = [(self.searchField.text ?: @"") stringByTrimmingCharactersInSet:ws];
    NSString *sq = [(self.smartField.text  ?: @"") stringByTrimmingCharactersInSet:ws];

    // Expand smart query through alias dictionary
    NSArray<NSString *> *smartTerms = fmSmartAliases()[[sq lowercaseString]];
    BOOL hasSmart  = sq.length > 0;
    BOOL hasManual = q.length  > 0;

    [self.filteredShaders removeAllObjects];
    NSUInteger matchCount = 0;

    for (ShaderEntry *e in self.shaders) {
        if (e.isDivider) {
            if (_sortMode == 0 && _currentTab == 0 && !hasManual && !hasSmart)
                [self.filteredShaders addObject:e];
            continue;
        }
        if (_currentTab == 1 && !e.isSaved) continue;

        // Neither text filter active — still check LIVE filter
        if (!hasManual && !hasSmart) {
            BOOL passLiveEarly = YES;
            if (_liveFilterActive && _liveSnapshotHashes)
                passLiveEarly = [_liveSnapshotHashes containsObject:@(e.sourceHash)];
            if (passLiveEarly) { [self.filteredShaders addObject:e]; matchCount++; }
            continue;
        }

        NSString *nameLow  = [e.name lowercaseString];
        NSString *dispLow  = [e.displayName lowercaseString];
        NSString *customLow= [e.customName lowercaseString];
        // For binary IR, e.source is garbage — search extracted struct fields instead
        BOOL binSrc = fmSourceIsBinary(e.source);
        NSString *srcLow   = binSrc
            ? [[@[e.subMembersText ?: @"", e.vglobalsText ?: @"", e.vglobalsName ?: @"", e.displayName ?: @""]
                componentsJoinedByString:@"\n"] lowercaseString]
            : [e.source lowercaseString];
        // Also always include subMembers/vglobals for MSL shaders
        NSString *membersLow = [[@[e.subMembersText ?: @"", e.vglobalsText ?: @""] componentsJoinedByString:@"\n"] lowercaseString];

        // Manual match (literal substring, case-insensitive)
        BOOL passManual = YES;
        if (hasManual) {
            NSString *lower = [q lowercaseString];
            passManual = [nameLow    containsString:lower] ||
                         [dispLow   containsString:lower] ||
                         [customLow containsString:lower] ||
                         [srcLow    containsString:lower] ||
                         [membersLow containsString:lower];
        }

        // Smart match (alias expansion — OR across terms)
        BOOL passSmart = YES;
        if (hasSmart) {
            if (smartTerms.count > 0) {
                passSmart = NO;
                for (NSString *term in smartTerms) {
                    if ([nameLow     containsString:term] ||
                        [dispLow    containsString:term] ||
                        [srcLow     containsString:term] ||
                        [membersLow containsString:term]) { passSmart = YES; break; }
                }
            } else {
                // Unknown keyword → fall back to literal match on all fields
                NSString *lower = [sq lowercaseString];
                passSmart = [nameLow     containsString:lower] ||
                            [dispLow    containsString:lower] ||
                            [customLow  containsString:lower] ||
                            [srcLow     containsString:lower] ||
                            [membersLow containsString:lower];
            }
        }

        // LIVE filter: shader must have been used in the current frame snapshot
        BOOL passLive = YES;
        if (_liveFilterActive && _liveSnapshotHashes) {
            passLive = [_liveSnapshotHashes containsObject:@(e.sourceHash)];
        }

        // AND: shader must pass ALL active filters
        if (passManual && passSmart && passLive) {
            [self.filteredShaders addObject:e]; matchCount++;
        }
    }

    // Sort
    if (_sortMode != 0) {
        NSInteger mode = _sortMode;
        [self.filteredShaders sortUsingComparator:^NSComparisonResult(ShaderEntry *a, ShaderEntry *b) {
            NSInteger aL = (NSInteger)[[a.source componentsSeparatedByString:@"\n"] count];
            NSInteger bL = (NSInteger)[[b.source componentsSeparatedByString:@"\n"] count];
            if (mode == 1) return (aL < bL) ? NSOrderedAscending : (aL > bL) ? NSOrderedDescending : NSOrderedSame;
            else           return (aL > bL) ? NSOrderedAscending : (aL < bL) ? NSOrderedDescending : NSOrderedSame;
        }];
    }

    // Compute total non-divider shaders for badge
    NSUInteger totalShaders = 0;
    for (ShaderEntry *e in self.shaders) { if (!e.isDivider) totalShaders++; }

    // Capture for block
    NSUInteger mc = matchCount;
    NSUInteger tc = totalShaders;
    BOOL hs = hasSmart, hm = hasManual;
    NSArray *st = smartTerms;
    NSString *sqCopy = sq;

    dispatch_async(dispatch_get_main_queue(), ^{
        [self.shaderList reloadData];

        // ── Badge: found/total when filter active, otherwise total ✓ ──────────
        UILabel *badge = (UILabel *)[self viewWithTag:700];
        if (badge) {
            BOOL filterOn = hm || hs;
            if (tc == 0) {
                badge.text = @"";
            } else if (filterOn) {
                badge.text = [NSString stringWithFormat:@"%lu/%lu", (unsigned long)mc, (unsigned long)tc];
                badge.textColor = (mc == 0)
                    ? [UIColor colorWithRed:1.0 green:0.35 blue:0.35 alpha:1]
                    : [UIColor colorWithRed:0.3 green:0.9 blue:0.5 alpha:1];
            } else {
                // No filter: delegate to standard badge
                [self updateCountBadge];
            }
        }

        // ── Manual field border feedback ──────────────────────────────────────
        if (hm) {
            self.searchField.layer.borderWidth = 1;
            self.searchField.layer.borderColor = (mc == 0)
                ? [UIColor colorWithRed:1 green:0.35 blue:0.35 alpha:0.7].CGColor
                : [UIColor colorWithRed:0.3 green:0.9 blue:0.5 alpha:0.5].CGColor;
        } else {
            self.searchField.layer.borderWidth = 0;
        }

        // ── Smart field border + tooltip in placeholder area ──────────────────
        if (hs) {
            self.smartField.layer.borderWidth = 1;
            self.smartField.layer.borderColor = (mc == 0)
                ? [UIColor colorWithRed:1 green:0.35 blue:0.35 alpha:0.7].CGColor
                : [UIColor colorWithRed:1.0 green:0.82 blue:0.2 alpha:0.5].CGColor;

            // Show expanded terms as placeholder hint when field has no text
            if (st.count > 0 && sqCopy.length > 0) {
                NSUInteger n = MIN(3, st.count);
                NSString *hint = [[st subarrayWithRange:NSMakeRange(0,n)] componentsJoinedByString:@"|"];
                if (st.count > 3) hint = [hint stringByAppendingString:@"…"];
                NSString *badge = mc == 0 ? @"✗" : [NSString stringWithFormat:@"%lu✓", (unsigned long)mc];
                self.smartField.attributedPlaceholder = [[NSAttributedString alloc]
                    initWithString:[NSString stringWithFormat:@"🧠 %@ %@", hint, badge]
                        attributes:@{NSForegroundColorAttributeName:[UIColor colorWithRed:0.7 green:0.6 blue:0.2 alpha:0.8],
                                     NSFontAttributeName:[UIFont systemFontOfSize:9]}];
            }
        } else {
            self.smartField.layer.borderWidth = 0;
            // Restore default placeholder
            self.smartField.attributedPlaceholder = [[NSAttributedString alloc]
                initWithString:@"🧠  weapon · players…"
                    attributes:@{NSForegroundColorAttributeName:[UIColor colorWithRed:0.55 green:0.40 blue:0.10 alpha:0.80],
                                 NSFontAttributeName:[UIFont systemFontOfSize:10]}];
        }
    });
}

// ── Public API ──────────────────────────────────────────────────────────────────

- (void)addShaderWithName:(NSString *)name source:(NSString *)source error:(NSString *)error libHash:(NSUInteger)libHash {
    ShaderEntry *entry = [ShaderEntry new];
    entry.name       = name ?: @"unnamed_shader";
    entry.source     = source ?: @"";
    entry.stableKey  = fmStableKey(entry.name, entry.source); // deterministic, survives restarts
    entry.errorInfo  = error;
    entry.capturedAt = [NSDate date];
    entry.sourceHash = libHash; // real kLibHashKey from Tweak.mm — matches gLiveActiveHashes
    entry.isDivider  = NO;

    NSString *lower = [source lowercaseString];
    entry.hasVertexFunction   = ([lower rangeOfString:@"vertex "].location   != NSNotFound);
    entry.hasFragmentFunction = ([lower rangeOfString:@"fragment "].location != NSNotFound);

    if (entry.hasFragmentFunction) entry.fragIndex = ++_fragCount;
    if (entry.hasVertexFunction)   entry.vertIndex = ++_vertCount;

    // ── Detect ANGLE shader (WebGL-Metal bridge, e.g. Bullet Echo) ──────────
    // ANGLE shaders carry specific struct names: defaultUniforms + ANGLEUniformBlock.
    // For these we show uniform structs in both columns (more useful for UE inspection).
    BOOL isANGLE = [lower containsString:@"defaultuniforms"] || [lower containsString:@"angleuniformblock"];

    if (isANGLE) {
        // LEFT = defaultUniforms (per-draw uniforms), RIGHT = ANGLEUniformBlock (ANGLE internals)
        entry.displayName    = fmStructName(source, @"defaultuniforms")   ?: @"struct defaultUniforms";
        entry.subMembersText = fmStructBody(source, @"defaultuniforms");
        entry.vglobalsName   = fmStructName(source, @"angleuniformblock") ?: @"struct ANGLEUniformBlock";
        entry.vglobalsText   = fmStructBody(source, @"angleuniformblock");
    } else {
        // Standard UE / Unity mode: LEFT = vertex/fragment output struct, RIGHT = VGlobals
        NSString *primaryHint = entry.hasFragmentFunction ? @"mtl_fragmentout" : @"mtl_vertexout";
        NSString *structName  = fmStructName(source, primaryHint);
        NSString *structBody  = fmStructBody(source, primaryHint);

        if (!structBody) {
            // Fallback A: parse return type from "vertex|fragment <ReturnType> <funcName>("
            NSString *funcKw  = entry.hasFragmentFunction ? @"fragment " : @"vertex ";
            NSRange   funcPos = [lower rangeOfString:funcKw];
            if (funcPos.location != NSNotFound) {
                NSUInteger after = NSMaxRange(funcPos);
                NSCharacterSet *ws2 = [NSCharacterSet whitespaceCharacterSet];
                while (after < source.length && [ws2 characterIsMember:[source characterAtIndex:after]]) after++;
                NSUInteger start = after;
                while (after < source.length) {
                    unichar c = [source characterAtIndex:after];
                    if (c == ' ' || c == '\t' || c == '<' || c == '(' || c == '\n' || c == '\r') break;
                    after++;
                }
                if (after > start) {
                    NSString *retType = [source substringWithRange:NSMakeRange(start, after - start)];
                    NSString *retHint = [retType lowercaseString];
                    BOOL isBuiltin = [retHint hasPrefix:@"void"] || [retHint hasPrefix:@"float"]
                                  || [retHint hasPrefix:@"half"]  || [retHint hasPrefix:@"int"]
                                  || [retHint hasPrefix:@"uint"];
                    if (!isBuiltin && retHint.length > 2) {
                        NSString *n2 = fmStructName(source, retHint);
                        NSString *b2 = fmStructBody(source, retHint);
                        if (b2) { structName = n2; structBody = b2; }
                    }
                }
            }
        }
        if (!structBody) {
            NSArray *altHints = entry.hasFragmentFunction
                ? @[@"_mtl_fragmentout", @"main_out", @"main0_out", @"ps_out", @"fsoutput", @"fragout"]
                : @[@"_mtl_vertexout",   @"main_out", @"main0_out", @"vs_out", @"vsoutput",  @"vertout"];
            for (NSString *alt in altHints) {
                NSString *n2 = fmStructName(source, alt);
                NSString *b2 = fmStructBody(source, alt);
                if (b2) { structName = n2; structBody = b2; break; }
            }
        }
        entry.displayName    = structName ?: (entry.hasFragmentFunction ? @"struct Mtl_FragmentOut" : @"struct Mtl_VertexOut");
        entry.subMembersText = structBody;

        // RIGHT column: VGlobals / uniform-buffer struct
        // Hints: UE HLSLCC "vglobals_type" -> SPIRV-Cross "type_globals"/"_globals" ->
        //        "constant <Type>&" param scan
        NSString *vgName = nil, *vgBody = nil;
        NSArray *vgHints = @[@"vglobals_type", @"type_globals", @"_globals",
                             @"spvdescriptorset0", @"uniforms", @"cbuffer", @"ubuffer", @"pushconstants"];
        for (NSString *h in vgHints) {
            NSString *n2 = fmStructName(source, h);
            NSString *b2 = fmStructBody(source, h);
            if (b2) { vgName = n2; vgBody = b2; break; }
        }
        if (!vgBody) {
            // Scan "constant <Type>&" params
            NSRegularExpression *re = [NSRegularExpression
                regularExpressionWithPattern:@"constant\s+(\w+)\s*&"
                options:NSRegularExpressionCaseInsensitive error:nil];
            for (NSTextCheckingResult *m in [re matchesInString:source options:0
                                             range:NSMakeRange(0, source.length)]) {
                if (m.numberOfRanges < 2) continue;
                NSString *th = [[source substringWithRange:[m rangeAtIndex:1]] lowercaseString];
                if ([th containsString:@"out"] || [th containsString:@"_in"]) continue;
                NSString *n2 = fmStructName(source, th);
                NSString *b2 = fmStructBody(source, th);
                if (b2 && b2.length > 4) { vgName = n2; vgBody = b2; break; }
            }
        }
        entry.vglobalsName = vgName ?: @"struct VGlobals_Type";
        entry.vglobalsText = vgBody;
    }

    // ── Restore saved patch state (persists across game restarts) ──────────────
    NSDictionary *saved = _savedPatchCache[entry.stableKey];
    if (saved) {
        entry.isSaved        = [saved[@"s"] boolValue];
        entry.patchFragColor = (FragPatchColor)[saved[@"c"] integerValue];
        entry.patchFlash     = [saved[@"f"] boolValue];
        entry.patchVertex    = [saved[@"v"] boolValue];
        NSString *cn = saved[@"n"];
        if (cn.length > 0) entry.customName = cn;
        // Re-trigger compilation if any patch is active
        if (entry.patchFragColor != FragPatchNone || entry.patchFlash || entry.patchVertex) {
            ShaderEntry *e = entry;
            void (^handler)(ShaderEntry *) = self.patchChangedHandler;
            if (handler) {
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                    handler(e);
                });
            }
        }
    }

    [self.shaders addObject:entry];

    // Rebuild filteredShaders via applyFilter so the smart filter is respected.
    // (The old passSearch path only checked searchField and ignored smartField,
    //  causing the badge to grow while the visible list stayed stale.)
    dispatch_async(dispatch_get_main_queue(), ^{
        [self applyFilter];
    });
}

- (ShaderEntry *)entryForSourceHash:(NSUInteger)hash {
    for (ShaderEntry *e in self.shaders)
        if (e.sourceHash == hash) return e;
    return nil;
}

- (void)refresh {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.shaderList reloadData]; [self updateCountBadge];
    });
}

- (void)updateCountBadge {
    UILabel *badge = (UILabel *)[self viewWithTag:700];
    NSUInteger errors = 0, total = 0;
    for (ShaderEntry *e in self.shaders) {
        if (e.isDivider) continue; total++;
        if (e.errorInfo.length) errors++;
    }
    if (total == 0) { badge.text = @""; return; }
    if (errors > 0) {
        badge.text = [NSString stringWithFormat:@"%lu ⚠%lu", (unsigned long)total, (unsigned long)errors];
        badge.textColor = [UIColor colorWithRed:1 green:0.5 blue:0.4 alpha:1];
    } else {
        badge.text = [NSString stringWithFormat:@"%lu ✓", (unsigned long)total];
        badge.textColor = [UIColor colorWithRed:0.3 green:0.9 blue:0.4 alpha:1];
    }
}

- (void)clearShaders {
    // 1. Collect entries with active patches BEFORE resetting (need sourceHash for GPU revert)
    NSMutableArray *patched = [NSMutableArray array];
    for (ShaderEntry *e in self.shaders) {
        if (!e.isDivider && (e.patchFragColor != FragPatchNone || e.patchFlash || e.patchVertex))
            [patched addObject:e];
    }

    // 2. Reset all patch flags on every entry
    for (ShaderEntry *e in self.shaders) {
        e.patchFragColor = FragPatchNone;
        e.patchFlash = NO;
        e.patchVertex = NO;
        e.isSaved = NO;
    }

    // 3. Wipe NSUserDefaults persistence (new v2 key)
    [_savedPatchCache removeAllObjects];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kPatchDefaultsKey];

    // 4. Revert GPU effects: call patchChangedHandler for each previously-patched entry
    //    (all flags are now 0 → applyPatchesForEntry removes variant pipelines)
    void (^handler)(ShaderEntry *) = self.patchChangedHandler;
    if (handler) {
        for (ShaderEntry *e in patched) {
            ShaderEntry *captured = e;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                handler(captured);
            });
        }
    }

    // 5. Clear the visual list — keep saved (Memory ★) shaders intact
    NSMutableArray *toKeep = [NSMutableArray array];
    NSInteger newFragMax = 0, newVertMax = 0;
    for (ShaderEntry *e in self.shaders) {
        if (!e.isDivider && e.isSaved) {
            [toKeep addObject:e];
            if (e.hasFragmentFunction) newFragMax = MAX(newFragMax, e.fragIndex);
            if (e.hasVertexFunction)   newVertMax = MAX(newVertMax, e.vertIndex);
        }
    }
    [self.shaders removeAllObjects];
    [self.shaders addObjectsFromArray:toKeep];
    [self.filteredShaders removeAllObjects];
    _fragCount = newFragMax;
    _vertCount = newVertMax;
    self.searchField.text = @"";
    UILabel *resultLbl = (UILabel *)[self viewWithTag:703];
    if (resultLbl) resultLbl.hidden = YES;
    [self applyFilter];   // rebuilds filteredShaders + reloads table
    [self updateCountBadge];
}

// ── resetAllPatchesAndPersistence (public, called by double-tap safety reset) ─
// Clears ALL patch flags, wipes _savedPatchCache + NSUserDefaults, triggers
// patchChangedHandler (with flags=OFF) for each previously-patched entry so GPU
// variants are removed.  Does NOT clear the shader list or ★ save state.

- (void)resetAllPatchesAndPersistence {
    // 1. Collect entries that currently have patches active
    NSMutableArray *patched = [NSMutableArray array];
    for (ShaderEntry *e in self.shaders) {
        if (!e.isDivider && (e.patchFragColor != FragPatchNone || e.patchFlash || e.patchVertex))
            [patched addObject:e];
    }

    // 2. Reset patch flags on every entry (keep isSaved so Memory ★ persists)
    for (ShaderEntry *e in self.shaders) {
        e.patchFragColor    = FragPatchNone;
        e.patchFlash        = NO;
        e.patchVertex       = NO;
        e.patchShadeOverride = NO;
    }

    // 3. Wipe patch persistence entirely
    [_savedPatchCache removeAllObjects];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kPatchDefaultsKey];

    // 4. Trigger patchChangedHandler for each previously-patched entry
    //    (flags are now all OFF → applyPatchesForEntry removes variant pipelines)
    void (^handler)(ShaderEntry *) = self.patchChangedHandler;
    if (handler) {
        for (ShaderEntry *e in patched) {
            ShaderEntry *cap = e;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                handler(cap);
            });
        }
    }

    // 5. Reload UI
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.shaderList reloadData];
        [self updateCountBadge];
    });
}

// ── resetActivePatchesOnly ────────────────────────────────────────────────────
// Usato dal double-tap: resetta i flag dei patch attivi + GPU variants,
// ma NON tocca _savedPatchCache né NSUserDefaults → la Memory rimane intatta.

- (void)resetActivePatchesOnly {
    // 1. Raccogli entry con patch attivi
    NSMutableArray *patched = [NSMutableArray array];
    for (ShaderEntry *e in self.shaders) {
        if (!e.isDivider && (e.patchFragColor != FragPatchNone || e.patchFlash || e.patchVertex))
            [patched addObject:e];
    }

    // 2. Azzera i flag attivi — preserva isSaved e customName ma cancella i patch
    //    CRITICO: deve anche aggiornare _savedPatchCache + NSUserDefaults, altrimenti
    //    al prossimo riavvio addShaderWithName() ricarica i patch e va in crash loop.
    for (ShaderEntry *e in self.shaders) {
        e.patchFragColor     = FragPatchNone;
        e.patchFlash         = NO;
        e.patchVertex        = NO;
        e.patchShadeOverride = NO;
    }
    // Wipe patch flags from _savedPatchCache (keep isSaved + customName for UI)
    for (NSString *key in _savedPatchCache.allKeys) {
        NSDictionary *old = _savedPatchCache[key];
        _savedPatchCache[key] = @{
            @"s": old[@"s"] ?: @NO,
            @"c": @((NSInteger)FragPatchNone),
            @"f": @NO,
            @"v": @NO,
            @"n": old[@"n"] ?: @"",
        };
    }
    [[NSUserDefaults standardUserDefaults] setObject:[_savedPatchCache copy]
                                             forKey:kPatchDefaultsKey];

    // 3. Rimuovi GPU variant pipelines per ogni entry che aveva patch
    void (^handler)(ShaderEntry *) = self.patchChangedHandler;
    if (handler) {
        for (ShaderEntry *e in patched) {
            ShaderEntry *cap = e;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                handler(cap);
            });
        }
    }

    // 4. Ricarica UI
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.shaderList reloadData];
        [self updateCountBadge];
    });
}

// ── Clear Memory (solo gli shader con ★ salvati) ──────────────────────────────
// Resetta patch + UserDefaults + effetti GPU, SENZA cancellare la lista Shaders.

- (void)clearMemoryTapped {
    // Raccogli prima gli entry con patch attivi (prima di azzerarli)
    NSMutableArray *patched = [NSMutableArray array];
    for (ShaderEntry *e in self.shaders) {
        if (!e.isDivider && (e.patchFragColor != FragPatchNone || e.patchFlash || e.patchVertex))
            [patched addObject:e];
    }

    // Azzera tutti i flag su tutti gli entry (saved + patch)
    for (ShaderEntry *e in self.shaders) {
        e.patchFragColor = FragPatchNone;
        e.patchFlash     = NO;
        e.patchVertex    = NO;
        e.isSaved        = NO;
    }

    // Cancella persistenza
    [_savedPatchCache removeAllObjects];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kPatchDefaultsKey];

    // Ripristina GPU: handler con flag a 0 → applyPatchesForEntry rimuove variant pipeline
    void (^handler)(ShaderEntry *) = self.patchChangedHandler;
    if (handler) {
        for (ShaderEntry *e in patched) {
            ShaderEntry *cap = e;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                handler(cap);
            });
        }
    }

    // Aggiorna UI (la lista Shaders rimane intatta, solo Memory si svuota)
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.shaderList reloadData];
        [self updateCountBadge];
    });
}

// ── Export: genera il file .m e lo mostra nel tab ────────────────────────────

- (void)_regenerateExportSource {
    NSMutableArray<ShaderEntry *> *saved = [NSMutableArray array];
    for (ShaderEntry *e in self.shaders) {
        if (!e.isDivider && e.isSaved) [saved addObject:e];
    }

    if (saved.count == 0) {
        _exportTextView.text =
            @"// Nessuno shader salvato in Memory.\n"
             "// Aggiungi ★ agli shader che vuoi esportare, poi torna qui.";
        return;
    }

    NSMutableString *src = [NSMutableString string];

    // ── Header ──────────────────────────────────────────────────────────────
    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"yyyy-MM-dd HH:mm";
    [src appendFormat:
        @"// exported_patches.m\n"
         "// Generato da Metal Inspector — %@\n"
         "// Shaders: %lu\n"
         "//\n"
         "// Come usarlo:\n"
         "//   1. Copia questo file nella cartella del tuo progetto Theos\n"
         "//   2. Nel Makefile aggiungi: <TARGET>_FILES = Tweak.xm exported_patches.m\n"
         "//   3. In Tweak.xm includi: extern void FM_installPatches(id<MTLDevice>);\n"
         "//      e chiamalo dove ottieni il device.\n"
         "//   4. make package\n\n"
         "#import <Metal/Metal.h>\n"
         "#import <objc/runtime.h>\n\n",
        [df stringFromDate:[NSDate date]],
        (unsigned long)saved.count];

    // ── Inject helpers (copiati inline, headless) ────────────────────────────
    [src appendString:
        @"// ── Inject helpers ──────────────────────────────────────────────────\n"
         "static NSString *_fm_injectFragColor(NSString *s,float r,float g,float b){\n"
         "    // trova ultimo return nel fragment body e aggiunge override RGB\n"
         "    NSRange ret=[s rangeOfString:@\"return\" options:NSBackwardsSearch];\n"
         "    if(ret.location==NSNotFound) return s;\n"
         "    NSRange semi=[s rangeOfString:@\";\" options:0 range:NSMakeRange(ret.location,s.length-ret.location)];\n"
         "    if(semi.location==NSNotFound) return s;\n"
         "    NSRange expr=NSMakeRange(ret.location+6, semi.location-(ret.location+6));\n"
         "    NSString *v=[[s substringWithRange:expr] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];\n"
         "    NSString *patch=[NSString stringWithFormat:@\"%@.r=(half)%.4ff;%@.g=(half)%.4ff;%@.b=(half)%.4ff;return %@;\",v,r,v,g,v,b,v];\n"
         "    return [s stringByReplacingCharactersInRange:NSMakeRange(ret.location,semi.location-ret.location+1) withString:patch];\n"
         "}\n"
         "static NSString *_fm_injectVertexDepth(NSString *s){\n"
         "    NSRange ret=[s rangeOfString:@\"return\" options:NSBackwardsSearch];\n"
         "    if(ret.location==NSNotFound) return s;\n"
         "    NSRange semi=[s rangeOfString:@\";\" options:0 range:NSMakeRange(ret.location,s.length-ret.location)];\n"
         "    if(semi.location==NSNotFound) return s;\n"
         "    NSRange expr=NSMakeRange(ret.location+6, semi.location-(ret.location+6));\n"
         "    NSString *v=[[s substringWithRange:expr] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];\n"
         "    NSString *patch=[NSString stringWithFormat:@\"%@.position.z=%@.position.w*0.0001f;return %@;\",v,v,v];\n"
         "    return [s stringByReplacingCharactersInRange:NSMakeRange(ret.location,semi.location-ret.location+1) withString:patch];\n"
         "}\n\n"];

    // ── Patch table: one entry per saved shader ──────────────────────────────
    [src appendString:@"// ── Patch table (name → source length → patch type) ────────────────\n"];
    [src appendString:@"typedef struct { const char *name; NSUInteger len; int patchType; float r,g,b; } FMPatchEntry;\n"];
    [src appendString:@"// patchType: 0=none 1=red 2=green 3=blue 4=flash 5=vertex\n"];
    [src appendString:@"static const FMPatchEntry kFMPatches[] = {\n"];

    for (ShaderEntry *e in saved) {
        NSString *name = (e.customName.length ? e.customName : e.name);
        // Escape quotes in name
        name = [name stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
        int ptype = 0;
        float r=0,g=0,b=0;
        if (e.patchVertex)                          { ptype=5; }
        else if (e.patchFlash)                      { ptype=4; }
        else if (e.patchFragColor==FragPatchRed)    { ptype=1; r=1.0f; }
        else if (e.patchFragColor==FragPatchGreen)  { ptype=2; g=0.9f; b=0.2f; }
        else if (e.patchFragColor==FragPatchBlue)   { ptype=3; r=0.2f; g=0.5f; b=1.0f; }
        [src appendFormat:@"    { \"%@\", %lu, %d, %.4ff, %.4ff, %.4ff },\n",
            name, (unsigned long)e.source.length, ptype, r, g, b];
    }
    [src appendString:@"};\n"];
    [src appendFormat:@"static const NSUInteger kFMPatchCount = %lu;\n\n", (unsigned long)saved.count];

    // ── Hook implementation ──────────────────────────────────────────────────
    [src appendString:
        @"// ── Runtime hook ────────────────────────────────────────────────────\n"
         "typedef id<MTLLibrary>(*_FMLibIMP)(id,SEL,NSString*,MTLCompileOptions*,NSError**);\n"
         "static _FMLibIMP _fm_origNewLib = NULL;\n\n"
         "static id<MTLLibrary> _fm_hookedNewLib(id self,SEL _cmd,NSString *src,MTLCompileOptions *opts,NSError **err){\n"
         "    for(NSUInteger i=0;i<kFMPatchCount;i++){\n"
         "        const FMPatchEntry *p=&kFMPatches[i];\n"
         "        if(src.length!=p->len) continue;\n"
         "        switch(p->patchType){\n"
         "            case 1: case 2: case 3: src=_fm_injectFragColor(src,p->r,p->g,p->b); break;\n"
         "            case 5: src=_fm_injectVertexDepth(src); break;\n"
         "            default: break;\n"
         "        }\n"
         "        break;\n"
         "    }\n"
         "    return _fm_origNewLib(self,_cmd,src,opts,err);\n"
         "}\n\n"
         "void FM_installPatches(id<MTLDevice> device){\n"
         "    if(!device||_fm_origNewLib) return;\n"
         "    Class cls=[device class];\n"
         "    Method m=class_getInstanceMethod(cls,@selector(newLibraryWithSource:options:error:));\n"
         "    if(m){ _fm_origNewLib=(_FMLibIMP)method_getImplementation(m);\n"
         "            method_setImplementation(m,(IMP)_fm_hookedNewLib); }\n"
         "}\n"];

    _exportTextView.text = src;
}

- (void)_exportFileTapped {
    NSString *text = _exportTextView.text;
    if (!text.length || [text hasPrefix:@"// Nessuno"]) return;

    // Share as plain text file via UIActivityViewController
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return;

    // Write to a temp URL in-memory using NSItemProvider pattern
    NSURL *tmpDir = [NSURL fileURLWithPath:NSTemporaryDirectory()];
    NSURL *tmpFile = [tmpDir URLByAppendingPathComponent:@"exported_patches.m"];
    [data writeToURL:tmpFile atomically:YES];

    UIActivityViewController *avc = [[UIActivityViewController alloc]
        initWithActivityItems:@[tmpFile]
        applicationActivities:nil];

    // Find the presenting view controller
    UIViewController *vc = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w.isKeyWindow) { vc = w.rootViewController; break; }
        }
        if (vc) break;
    }
    while (vc.presentedViewController) vc = vc.presentedViewController;

    if ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        avc.popoverPresentationController.sourceView = _exportView;
        avc.popoverPresentationController.sourceRect = CGRectMake(_exportView.bounds.size.width/2, _exportView.bounds.size.height - 50, 1, 1);
    }

    [vc presentViewController:avc animated:YES completion:nil];
}

// ── Detail view ───────────────────────────────────────────────────────────────

// ── Helpers for source classification ────────────────────────────────────────

// Returns YES if >20% of sampled chars are non-ASCII (obfuscated identifiers).
// Checks: first 400 chars (catches header-level obfuscation) PLUS
// a 400-char window starting at 30% of the source (catches shaders where the
// readable struct definition is at the top but the function body is obfuscated).
static BOOL fmSourceIsObfuscated(NSString *src) {
    if (!src.length) return NO;
    NSUInteger total = src.length;
    // Helper lambda: returns non-ASCII ratio * 100 for a window
    NSUInteger (^ratio)(NSUInteger, NSUInteger) = ^(NSUInteger start, NSUInteger len) {
        NSUInteger end = MIN(start + len, total);
        NSUInteger cnt = 0;
        for (NSUInteger i = start; i < end; i++)
            if ([src characterAtIndex:i] > 127) cnt++;
        NSUInteger win = end - start;
        return win ? (cnt * 100 / win) : 0;
    };
    if (ratio(0, 400) > 20) return YES;
    // Middle window (30% offset, handles struct-at-top + obfuscated body)
    if (total > 800 && ratio(total * 3 / 10, 400) > 20) return YES;
    return NO;
}

// Returns YES if source is a placeholder generated for a precompiled .metallib.
static BOOL fmSourceIsBinary(NSString *src) {
    return [src hasPrefix:@"// ⚠️  METALLIB PRECOMPILATA"] ||
           [src hasPrefix:@"// ── METALLIB"]              ||
           [src hasPrefix:@"// METALLIB"]                 ||
           [src hasPrefix:@"// DEFAULT METALLIB"]         ||
           [src hasPrefix:@"// ⚠️  LIBRERIA NON-MSL"];   // lateTagLibrary (pipeline-triggered)
}

- (void)showDetailForShader:(ShaderEntry *)shader {
    UILabel *nameLabel = (UILabel *)[self.detailView viewWithTag:801];
    nameLabel.text = shader.displayName.length > 0 ? shader.displayName : shader.name;
    UITextView *tv = (UITextView *)[self.detailView viewWithTag:802];

    // ── obfuscation / binary banner (tag 820) ────────────────────────────────
    UILabel *obfBanner = (UILabel *)[self.detailView viewWithTag:820];
    if (!obfBanner) {
        obfBanner = [[UILabel alloc] init];
        obfBanner.tag = 820;
        obfBanner.font = [UIFont systemFontOfSize:10];
        obfBanner.textAlignment = NSTextAlignmentCenter;
        obfBanner.numberOfLines = 0;
        obfBanner.layer.cornerRadius = 4;
        obfBanner.clipsToBounds = YES;
        [self.detailView addSubview:obfBanner];
    }

    BOOL isBin  = fmSourceIsBinary(shader.source);
    BOOL isObf  = !isBin && fmSourceIsObfuscated(shader.source);
    CGFloat bannerH = 0;
    CGFloat tvY = 46;

    if (shader.errorInfo.length) {
        self.errorLabel.text = [NSString stringWithFormat:@"  ⚠ %@  ", shader.errorInfo];
        [self.errorLabel sizeToFit];
        CGRect ef = self.errorLabel.frame;
        ef.origin.y = 46; ef.size.width = self.bounds.size.width - 16;
        self.errorLabel.frame = ef;
        self.errorLabel.hidden = NO;
        tvY = ef.origin.y + ef.size.height + 4;
    } else {
        self.errorLabel.hidden = YES;
    }

    if (isBin || isObf) {
        obfBanner.hidden = NO;
        if (isBin) {
            obfBanner.backgroundColor = [UIColor colorWithRed:0.1 green:0.25 blue:0.55 alpha:1];
            obfBanner.textColor = [UIColor colorWithRed:0.7 green:0.85 blue:1 alpha:1];
            obfBanner.text = @"  📦  Metallib precompilata — R/G/B colore + V wallhack disponibili  ";
        } else {
            obfBanner.backgroundColor = [UIColor colorWithRed:0.30 green:0.20 blue:0.0 alpha:1];
            obfBanner.textColor = [UIColor colorWithRed:1 green:0.85 blue:0.3 alpha:1];
            obfBanner.text = @"  🔒  Sorgente obfuscata con identificatori Unicode (R6 Mobile) — patch supportati  ";
        }
        [obfBanner sizeToFit];
        CGRect bf = obfBanner.frame;
        bf.origin = CGPointMake(0, tvY);
        bf.size.width = self.bounds.size.width;
        obfBanner.frame = bf;
        bannerH = bf.size.height + 4;
        tvY += bannerH;
    } else {
        obfBanner.hidden = YES;
    }

    tv.frame = CGRectMake(0, tvY, self.bounds.size.width, self.bounds.size.height - tvY - 46);

    if (isBin) {
        // Binary IR: show extracted struct/uniform info (no readable MSL available)
        NSMutableString *info = [NSMutableString string];
        [info appendString:@"// ── Metallib precompilata (Binary IR) ──\n"];
        [info appendString:@"// Sorgente MSL non disponibile. Dati estratti:\n\n"];
        if (shader.displayName.length > 0) {
            [info appendFormat:@"%@ {\n%@\n}\n\n",
                shader.displayName,
                shader.subMembersText.length > 0 ? shader.subMembersText : @"  // (nessun membro trovato)"];
        }
        if (shader.vglobalsText.length > 0) {
            [info appendFormat:@"%@ {\n%@\n}\n",
                shader.vglobalsName.length > 0 ? shader.vglobalsName : @"struct VGlobals_Type",
                shader.vglobalsText];
        }
        if (info.length <= 100) {
            [info appendString:@"\n// Nessun nome struct/uniforme trovato nel binario."];
        }
        tv.text = info;
    } else if (isObf) {
        // Obfuscated MSL: IS valid MSL, just with unreadable Unicode identifiers.
        // Show the raw source preceded by a short warning banner.
        NSMutableString *info = [NSMutableString string];
        [info appendString:@"// ── Sorgente obfuscata (nomi Unicode non leggibili) ──\n"];
        [info appendString:@"// La struttura MSL è valida; solo i nomi sono illeggibili.\n"];
        [info appendString:@"// I patch R/G/B/V/⚡ funzionano comunque.\n\n"];
        [info appendString:shader.source];
        tv.text = info;
    } else {
        tv.text = shader.source;
    }
    [tv scrollRangeToVisible:NSMakeRange(0, 0)];
    self.detailView.hidden = NO;
}

- (void)closeDetail { self.detailView.hidden = YES; }

- (void)copySource {
    UITextView *tv = (UITextView *)[self.detailView viewWithTag:802];
    [UIPasteboard generalPasteboard].string = tv.text;
    [self.srcCopyBtn setTitle:@"✓  Copied!" forState:UIControlStateNormal];
    [self.srcCopyBtn setTitleColor:[UIColor colorWithRed:0.2 green:0.9 blue:0.4 alpha:1] forState:UIControlStateNormal];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self.srcCopyBtn setTitle:@"⎘  Copy Source" forState:UIControlStateNormal];
        [self.srcCopyBtn setTitleColor:[UIColor colorWithRed:0.6 green:0.9 blue:1 alpha:1] forState:UIControlStateNormal];
    });
}

// ── UITableViewDataSource ──────────────────────────────────────────────────────

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return self.filteredShaders.count == 0 ? 1 : (NSInteger)self.filteredShaders.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {

    if (self.filteredShaders.count == 0) {
        UITableViewCell *c = [[UITableViewCell alloc]
                              initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        c.backgroundColor = [UIColor clearColor];
        c.textLabel.text  = (_currentTab == 1)
            ? @""
            : (self.shaders.count > 0 ? @"" : @"In attesa degli shader…");
        c.textLabel.textColor     = [UIColor colorWithWhite:0.3 alpha:1];
        c.textLabel.font          = [UIFont italicSystemFontOfSize:12];
        c.textLabel.textAlignment = NSTextAlignmentCenter;
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        return c;
    }

    ShaderEntry *e = self.filteredShaders[indexPath.row];

    if (e.isDivider) {
        UITableViewCell *dc = [tableView dequeueReusableCellWithIdentifier:kReuseDivider];
        if (!dc) {
            dc = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:kReuseDivider];
            dc.backgroundColor = [UIColor colorWithRed:0.08 green:0.08 blue:0.13 alpha:1];
            dc.selectionStyle  = UITableViewCellSelectionStyleNone;
            UILabel *dl = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, tableView.bounds.size.width, kDividerH)];
            dl.tag = 900; dl.textAlignment = NSTextAlignmentCenter;
            dl.font = [UIFont boldSystemFontOfSize:10];
            dl.textColor = [UIColor colorWithRed:1.0 green:0.75 blue:0.2 alpha:0.85];
            [dc.contentView addSubview:dl];
        }
        UILabel *dl = (UILabel *)[dc.contentView viewWithTag:900];
        dl.text = e.name;
        dl.frame = CGRectMake(0, 0, tableView.bounds.size.width, kDividerH);
        return dc;
    }

    UITableViewCell *cell = [self makeCellForEntry:e tableView:tableView];
    [self configureCell:cell forEntry:e tableWidth:tableView.bounds.size.width];
    return cell;
}

- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
    if (self.filteredShaders.count == 0) return 44;
    return [self cellHeightForEntry:self.filteredShaders[ip.row]];
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (self.filteredShaders.count == 0) return;
    ShaderEntry *e = self.filteredShaders[ip.row];
    if (e.isDivider) return;
    [self showDetailForShader:e];
}

@end
