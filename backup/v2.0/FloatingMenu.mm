#import "FloatingMenu.h"
#import "FMIconData.h"

// Defined in Tweak.xm — master Metal hooks on/off switch
extern void fmSetHooksEnabled(BOOL enabled);
// Deep patch reset — clears all active hash sets + compiled variant libraries
extern void fmClearAllShaderPatches(void);

static const CGFloat kIconSize = 64;
static const NSUInteger kMaxLogLines = 600; // more lines for crash analysis

// ── Persistent log file ───────────────────────────────────────────────────────
// Survives game restarts; cleared only by the Clear button.
// Stored in <container>/Library/FloatingMenuLog.txt (survives across launches).
static NSString *fmLogFilePath(void) {
    static NSString *path = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *lib = NSSearchPathForDirectoriesInDomains(
            NSLibraryDirectory, NSUserDomainMask, YES).firstObject;
        path = [lib stringByAppendingPathComponent:@"FloatingMenuLog.txt"];
    });
    return path;
}

// ── Passthrough window ────────────────────────────────────────────────────────
@interface FMPassthroughWindow : UIWindow
@end
@implementation FMPassthroughWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (!hit || hit == self || hit == self.rootViewController.view) return nil;
    return hit;
}
@end

// ── PassthroughView for root VC view ──────────────────────────────────────────
@interface FMPassthroughView : UIView
@end
@implementation FMPassthroughView
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    for (UIView *sub in self.subviews) {
        if (!sub.hidden && sub.userInteractionEnabled &&
            [sub pointInside:[self convertPoint:point toView:sub] withEvent:event]) {
            return YES;
        }
    }
    return NO;
}
@end

@interface FloatingMenu ()
@property (nonatomic, assign) NSUInteger logSaveGeneration; // incremented on each addLog: for debounce
@end

@implementation FloatingMenu

// ── Load persisted log from previous session ──────────────────────────────────
- (void)_loadPersistedLog {
    NSString *path = fmLogFilePath();
    NSString *saved = [NSString stringWithContentsOfFile:path
                                                encoding:NSUTF8StringEncoding
                                                   error:nil];
    if (!saved.length) return;
    NSArray<NSString *> *lines = [saved componentsSeparatedByString:@"\n"];
    for (NSString *l in lines) {
        if (l.length > 0) [self.logLines addObject:l];
    }
    // Trim to max — keep the NEWEST lines
    while (self.logLines.count > kMaxLogLines)
        [self.logLines removeObjectAtIndex:0];
}

// ── Write current log to file (called debounced from background queue) ────────
- (void)_persistLogNow {
    // Snapshot sotto lock — protegge da addLog: su qualsiasi thread
    NSArray *snapshot;
    @synchronized(self.logLines) {
        snapshot = [self.logLines copy];
    }
    NSString *text = [snapshot componentsJoinedByString:@"\n"];
    NSString *path = fmLogFilePath();
    [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

// ── Schedule a debounced save (2 s after last log entry) ─────────────────────
// Uses a generation counter: each addLog: increments it; the dispatched block only
// writes if the counter hasn't advanced again since it was scheduled.
- (void)_scheduleSave {
    NSUInteger gen = ++self.logSaveGeneration;
    __weak FloatingMenu *wself = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
        FloatingMenu *s = wself;
        if (s && s.logSaveGeneration == gen) [s _persistLogNow];
    });
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _isOpen   = NO;
        _logLines = [NSMutableArray array];
        [self _loadPersistedLog]; // restore log from previous session
        [self setupWindow];
        [self setupIcon];
        [self setupDebugPanel];
        [self setupShaderPage];
        // Show persisted content immediately in text view (panel may be hidden but
        // text must be ready for when the user opens the log panel)
        if (self.logLines.count > 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.logTextView.text = [self.logLines componentsJoinedByString:@"\n"];
                [self.logTextView scrollRangeToVisible:
                    NSMakeRange(self.logTextView.text.length, 0)];
            });
        }
        [self addLog:@"[INFO] ── sessione avviata ──"];
    }
    return self;
}

// ── Window ────────────────────────────────────────────────────────────────────

- (void)setupWindow {
    if (@available(iOS 13.0, *)) {
        UIWindowScene *scene = nil;
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]] &&
                s.activationState == UISceneActivationStateForegroundActive) {
                scene = (UIWindowScene *)s; break;
            }
        }
        if (!scene) {
            for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
                if ([s isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene *)s; break; }
            }
        }
        if (scene) self.menuWindow = [[FMPassthroughWindow alloc] initWithWindowScene:scene];
    }
    if (!self.menuWindow)
        self.menuWindow = [[FMPassthroughWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];

    self.menuWindow.frame = [UIScreen mainScreen].bounds;
    self.menuWindow.windowLevel = UIWindowLevelAlert + 200;
    self.menuWindow.backgroundColor = [UIColor clearColor];
    self.menuWindow.userInteractionEnabled = YES;

    UIViewController *rootVC = [[UIViewController alloc] init];
    FMPassthroughView *rootView = [[FMPassthroughView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    rootView.backgroundColor = [UIColor clearColor];
    rootVC.view = rootView;
    self.menuWindow.rootViewController = rootVC;
    self.menuWindow.hidden = NO;
}

// ── Floating icon ─────────────────────────────────────────────────────────────

- (void)setupIcon {
    CGSize screen = [UIScreen mainScreen].bounds.size;
    self.iconButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.iconButton.frame = CGRectMake(screen.width - kIconSize - 20, 120, kIconSize, kIconSize);
    // Transparent bg — glowing border comes from the icon image itself
    self.iconButton.backgroundColor = [UIColor clearColor];
    self.iconButton.layer.cornerRadius = 14;   // rounded rectangle, matches icon shape
    self.iconButton.layer.shadowColor  = [UIColor colorWithRed:0.45 green:0.25 blue:1.0 alpha:1.0].CGColor;
    self.iconButton.layer.shadowOpacity = 0.90;
    self.iconButton.layer.shadowOffset  = CGSizeMake(0, 0);
    self.iconButton.layer.shadowRadius  = 12;
    self.iconButton.layer.borderWidth   = 0;
    self.iconButton.clipsToBounds       = NO;
    // Load icon from embedded data.
    // NOTE: setImage:forState: NON ridimensiona la imageView al frame del button —
    // usiamo una UIImageView esplicita per garantire che riempia sempre i 128×128pt.
    NSData  *iconData = [[NSData alloc] initWithBase64EncodedString:kFMIconBase64 options:0];
    UIImage *iconImg  = [UIImage imageWithData:iconData scale:1.0]; // scale 1 = logical 128pt
    UIImageView *iconIV = [[UIImageView alloc] initWithFrame:CGRectInset(self.iconButton.bounds, 3, 3)];
    iconIV.image = [iconImg imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    iconIV.contentMode = UIViewContentModeScaleAspectFill;
    iconIV.clipsToBounds = YES;
    iconIV.layer.cornerRadius = 12;
    iconIV.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    iconIV.userInteractionEnabled = NO; // i touch passano al button sotto
    [self.iconButton addSubview:iconIV];
    [self pulseIcon];
    // Double-tap = safety OFF (disables all Metal hooks immediately)
    UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                                action:@selector(iconDoubleTapped)];
    doubleTap.numberOfTapsRequired = 2;
    [self.iconButton addGestureRecognizer:doubleTap];

    // Single-tap = open/close menu (waits for double-tap to fail first)
    UITapGestureRecognizer *singleTap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                                action:@selector(toggleMenu)];
    singleTap.numberOfTapsRequired = 1;
    [singleTap requireGestureRecognizerToFail:doubleTap];
    [self.iconButton addGestureRecognizer:singleTap];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                          action:@selector(handlePan:)];
    [self.iconButton addGestureRecognizer:pan];

    // Long press (0.6s) = EMERGENCY STOP: disable all shaders including unsaved ones.
    // Useful when entering a match and the game is about to crash from an active patch.
    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(iconLongPressed:)];
    longPress.minimumPressDuration = 0.6;
    [self.iconButton addGestureRecognizer:longPress];

    [self.menuWindow.rootViewController.view addSubview:self.iconButton];
}

- (void)pulseIcon {
    self.iconButton.transform = CGAffineTransformMakeScale(0.7, 0.7);
    [UIView animateWithDuration:0.5 delay:0
         usingSpringWithDamping:0.4 initialSpringVelocity:0.8
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{ self.iconButton.transform = CGAffineTransformIdentity; }
                     completion:nil];
}


// ── Debug panel ───────────────────────────────────────────────────────────────

- (void)setupDebugPanel {
    CGSize screen = [UIScreen mainScreen].bounds.size;
    CGFloat W = 300, H = 270;
    self.debugPanel = [[UIView alloc] initWithFrame:CGRectMake((screen.width - W) / 2,
                                                                screen.height - H - 60, W, H)];
    self.debugPanel.backgroundColor = [UIColor colorWithRed:0.04 green:0.04 blue:0.07 alpha:0.97];
    self.debugPanel.layer.cornerRadius = 14;
    self.debugPanel.layer.borderWidth = 1;
    self.debugPanel.layer.borderColor = [UIColor colorWithRed:0.08 green:0.55 blue:1.0 alpha:0.4].CGColor;
    self.debugPanel.layer.shadowColor = [UIColor blackColor].CGColor;
    self.debugPanel.layer.shadowOpacity = 0.7;
    self.debugPanel.layer.shadowOffset = CGSizeMake(0, 4);
    self.debugPanel.layer.shadowRadius = 10;
    self.debugPanel.hidden = YES;

    // ── Draggable header ──────────────────────────────────────────────────────
    CGFloat headerH = 40;
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, W, headerH)];
    header.backgroundColor = [UIColor colorWithRed:0.06 green:0.06 blue:0.10 alpha:1];
    header.userInteractionEnabled = YES;
    UIBezierPath *mask = [UIBezierPath bezierPathWithRoundedRect:header.bounds
                                              byRoundingCorners:UIRectCornerTopLeft | UIRectCornerTopRight
                                                    cornerRadii:CGSizeMake(14, 14)];
    CAShapeLayer *ml = [CAShapeLayer layer];
    ml.path = mask.CGPath;
    header.layer.mask = ml;
    [self.debugPanel addSubview:header];

    // Drag pill
    UIView *pill = [[UIView alloc] initWithFrame:CGRectMake((W - 28) / 2, 6, 28, 3)];
    pill.backgroundColor = [UIColor colorWithWhite:1 alpha:0.18];
    pill.layer.cornerRadius = 1.5;
    [header addSubview:pill];

    // Title
    UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(12, 0, W - 110, headerH)];
    t.text = @"⚙ Debug Log";
    t.textColor = [UIColor colorWithRed:0.08 green:0.55 blue:1.0 alpha:1.0];
    t.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
    [header addSubview:t];

    // Clear button
    UIButton *clearBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    clearBtn.frame = CGRectMake(W - 92, 8, 44, 24);
    [clearBtn setTitle:@"Clear" forState:UIControlStateNormal];
    [clearBtn setTitleColor:[UIColor colorWithWhite:0.45 alpha:1.0] forState:UIControlStateNormal];
    clearBtn.titleLabel.font = [UIFont systemFontOfSize:12];
    [clearBtn addTarget:self action:@selector(clearLogs) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:clearBtn];

    // Close button
    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    closeBtn.frame = CGRectMake(W - 42, 8, 28, 24);
    [closeBtn setTitle:@"✕" forState:UIControlStateNormal];
    [closeBtn setTitleColor:[UIColor colorWithWhite:0.55 alpha:1.0] forState:UIControlStateNormal];
    closeBtn.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    [closeBtn addTarget:self action:@selector(closeDebugPanel) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:closeBtn];

    // Pan → drag the panel
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                          action:@selector(handleDebugPanelDrag:)];
    [header addGestureRecognizer:pan];

    // Tap on header → close (same as ✕ but easier to reach)
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                          action:@selector(closeDebugPanel)];
    tap.cancelsTouchesInView = NO;
    [header addGestureRecognizer:tap];

    // ── Content ───────────────────────────────────────────────────────────────
    UIView *div = [[UIView alloc] initWithFrame:CGRectMake(0, headerH, W, 1)];
    div.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.07];
    [self.debugPanel addSubview:div];

    CGFloat logY = headerH + 4;
    CGFloat copyBtnH = 34;
    CGFloat copyBtnY = H - copyBtnH - 8;
    CGFloat div2Y    = copyBtnY - 5;

    self.logTextView = [[UITextView alloc] initWithFrame:CGRectMake(8, logY, W - 16,
                                                                     div2Y - logY - 4)];
    self.logTextView.backgroundColor = [UIColor clearColor];
    self.logTextView.textColor = [UIColor colorWithRed:0.3 green:1.0 blue:0.45 alpha:1.0];
    self.logTextView.font = [UIFont fontWithName:@"Courier" size:11];
    self.logTextView.editable = NO;
    [self.debugPanel addSubview:self.logTextView];

    UIView *div2 = [[UIView alloc] initWithFrame:CGRectMake(0, div2Y, W, 1)];
    div2.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.07];
    [self.debugPanel addSubview:div2];

    UIButton *copyBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    copyBtn.frame = CGRectMake(8, copyBtnY, W - 16, copyBtnH);
    copyBtn.backgroundColor = [UIColor colorWithRed:0.08 green:0.55 blue:1.0 alpha:0.18];
    copyBtn.layer.cornerRadius = 8;
    copyBtn.layer.borderWidth = 1;
    copyBtn.layer.borderColor = [UIColor colorWithRed:0.08 green:0.55 blue:1.0 alpha:0.5].CGColor;
    [copyBtn setTitle:@"⎘  Copy Log" forState:UIControlStateNormal];
    [copyBtn setTitleColor:[UIColor colorWithRed:0.08 green:0.55 blue:1.0 alpha:1.0] forState:UIControlStateNormal];
    copyBtn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
    copyBtn.tag = 500;
    [copyBtn addTarget:self action:@selector(copyLog) forControlEvents:UIControlEventTouchUpInside];
    [self.debugPanel addSubview:copyBtn];

    [self.menuWindow.rootViewController.view addSubview:self.debugPanel];
}

// ── Shader page (main UI — opened directly by icon tap) ───────────────────────

- (void)setupShaderPage {
    CGSize screen = [UIScreen mainScreen].bounds.size;
    CGFloat W = MIN(screen.width - 20, 510);   // +25% wider (408→510)
    CGFloat H = MIN(screen.height - 100, 460);
    self.shaderPage = [[ShaderPage alloc] initWithFrame:CGRectMake((screen.width - W) / 2,
                                                                    (screen.height - H) / 2, W, H)];
    self.shaderPage.layer.shadowColor   = [UIColor blackColor].CGColor;
    self.shaderPage.layer.shadowOpacity = 0.7;
    self.shaderPage.layer.shadowOffset  = CGSizeMake(0, 6);
    self.shaderPage.layer.shadowRadius  = 14;
    self.shaderPage.hidden = YES;

    // "📋 Log" button at bottom of shader page → opens/closes debug panel
    __weak FloatingMenu *wm = self;
    self.shaderPage.headerTappedHandler = ^{
        FloatingMenu *me = wm;
        if (me) [me toggleMenu];
    };
    self.shaderPage.logTappedHandler = ^{
        FloatingMenu *me = wm;
        if (!me) return;
        if (me.debugPanel.hidden) {
            // Centre on screen, above everything (Metal Inspector stays visible behind)
            CGSize  scr = [UIScreen mainScreen].bounds.size;
            CGSize  sz  = me.debugPanel.frame.size;
            me.debugPanel.frame = CGRectMake((scr.width  - sz.width)  / 2.0,
                                             (scr.height - sz.height) / 2.0,
                                             sz.width, sz.height);
            [me.shaderPage.superview bringSubviewToFront:me.debugPanel];
            [me addLog:@"[INFO] Log aperto"];
            me.debugPanel.hidden = NO;
            me.debugPanel.alpha  = 0;
            [UIView animateWithDuration:0.2 animations:^{ me.debugPanel.alpha = 1; }];
        } else {
            [me closeDebugPanel];
        }
    };

    self.shaderPage.hookSwitchChangedHandler = ^(BOOL enabled) {
        FloatingMenu *me = wm;
        fmSetHooksEnabled(enabled);
        if (me) [me addLog:enabled
            ? @"[HOOKS] Attivati ✓ — i Metal hook sono ora live"
            : @"[HOOKS] Disattivati — patch in memoria azzerate"];
    };

    [self.menuWindow.rootViewController.view addSubview:self.shaderPage];

    BOOL savedHooks = [[NSUserDefaults standardUserDefaults] boolForKey:@"FMHooksEnabled"];
    [self.shaderPage applyHookSwitchState:savedHooks];
    [self addLog:savedHooks ? @"[INFO] Hooks ON — ripristinato dallo stato precedente" : @"[INFO] Hooks OFF — premi ⚡ ON per attivare le patch"];
}

// ── Actions ───────────────────────────────────────────────────────────────────

- (void)closeDebugPanel {
    if (self.debugPanel.hidden) return;
    [UIView animateWithDuration:0.18 animations:^{ self.debugPanel.alpha = 0; }
                     completion:^(BOOL f) {
        self.debugPanel.hidden = YES;
        self.debugPanel.alpha  = 1;
    }];
}

- (void)addLog:(NSString *)message {
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"HH:mm:ss";
    NSString *line = [NSString stringWithFormat:@"[%@] %@", [fmt stringFromDate:[NSDate date]], message];
    @synchronized(self.logLines) {
        [self.logLines addObject:line];
        while (self.logLines.count > kMaxLogLines) [self.logLines removeObjectAtIndex:0];
    }
    // Persist asynchronously (debounced 2 s so rapid log bursts don't thrash disk)
    [self _scheduleSave];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *text;
        @synchronized(self.logLines) { text = [self.logLines componentsJoinedByString:@"\n"]; }
        self.logTextView.text = text;
        [self.logTextView scrollRangeToVisible:NSMakeRange(text.length, 0)];
    });
}

- (void)captureShaderWithName:(NSString *)name source:(NSString *)source error:(NSString *)error libHash:(NSUInteger)libHash {
    [self.shaderPage addShaderWithName:name source:source error:error libHash:libHash];
    [self addLog:[NSString stringWithFormat:@"[SHADER] %@ — %@",
                  name, error.length > 0 ? @"ERROR" : @"OK"]];
}

- (void)clearLogs {
    // Bump generation so any pending debounced save block becomes a no-op
    ++self.logSaveGeneration;
    @synchronized(self.logLines) { [self.logLines removeAllObjects]; }
    self.logTextView.text = @"";
    // Delete the persisted file immediately
    [[NSFileManager defaultManager] removeItemAtPath:fmLogFilePath() error:nil];
    [self addLog:@"[INFO] Log svuotato"];
}

- (void)copyLog {
    [UIPasteboard generalPasteboard].string = [self.logLines componentsJoinedByString:@"\n"];
    UIButton *btn = (UIButton *)[self.debugPanel viewWithTag:500];
    [btn setTitle:@"✓  Copiato!" forState:UIControlStateNormal];
    [btn setTitleColor:[UIColor colorWithRed:0.2 green:0.9 blue:0.4 alpha:1.0] forState:UIControlStateNormal];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [btn setTitle:@"⎘  Copy Log" forState:UIControlStateNormal];
        [btn setTitleColor:[UIColor colorWithRed:0.08 green:0.55 blue:1.0 alpha:1.0] forState:UIControlStateNormal];
    });
}

- (void)toggleMenu {
    if (self.isOpen) {
        [UIView animateWithDuration:0.18 animations:^{
            self.shaderPage.alpha     = 0;
            self.shaderPage.transform = CGAffineTransformMakeScale(0.94, 0.94);
        } completion:^(BOOL f) {
            self.shaderPage.hidden    = YES;
            self.shaderPage.transform = CGAffineTransformIdentity;
            self.shaderPage.alpha     = 1;
        }];
    } else {
        self.shaderPage.hidden    = NO;
        self.shaderPage.alpha     = 0;
        self.shaderPage.transform = CGAffineTransformMakeScale(0.92, 0.92);
        [UIView animateWithDuration:0.24 delay:0
             usingSpringWithDamping:0.72 initialSpringVelocity:0.5 options:0
                         animations:^{
            self.shaderPage.alpha     = 1;
            self.shaderPage.transform = CGAffineTransformIdentity;
        } completion:nil];
        [self addLog:@"[INFO] Shader Inspector aperto"];
    }
    self.isOpen = !self.isOpen;
}

// ── Long press: EMERGENCY STOP (all shaders OFF, hooks OFF) ──────────────────

- (void)iconLongPressed:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;

    // 1. Disable ALL hooks + persist to NSUserDefaults (fmSetHooksEnabled calls synchronize)
    //    so the NEXT launch starts with hooks=NO even after a GPU crash (no POSIX signal).
    fmSetHooksEnabled(NO);
    [self.shaderPage applyHookSwitchState:NO];

    // 2. Deep reset C-level: clears activeColorHashes, flashHashes, colorLibraries,
    //    flashLibraries, pipelinePatches, pipelineDescriptors, hash tables, variant dedup.
    fmClearAllShaderPatches();

    // 3. Reset all active patch flags in the UI (saved shaders remain in Memory tab).
    [self.shaderPage resetActivePatchesOnly];

    // 4. Close any open panel
    [self closeDebugPanel];
    if (self.isOpen) [self toggleMenu];

    [self addLog:@"[KILL] â¡ Long press — EMERGENCY STOP: tutti i patch OFF, hook disattivati"];

    // Vibrate for haptic confirmation (available iOS 10+)
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc]
        initWithStyle:UIImpactFeedbackStyleHeavy];
    [haptic prepare];
    [haptic impactOccurred];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
        [haptic impactOccurred]; // double pulse
    });

    // Flash icon RED for 1s as visual confirmation
    self.iconButton.layer.shadowColor = [UIColor colorWithRed:1.0 green:0.1 blue:0.1 alpha:1.0].CGColor;
    self.iconButton.layer.shadowRadius = 20;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
        self.iconButton.layer.shadowColor = [UIColor colorWithRed:0.45 green:0.25 blue:1.0 alpha:1.0].CGColor;
        self.iconButton.layer.shadowRadius = 12;
    });
}

// ── Double-tap: safety force-OFF ─────────────────────────────────────────────

- (void)iconDoubleTapped {
    // 1. Disable hooks first (pass-through mode)
    fmSetHooksEnabled(NO);
    [self.shaderPage applyHookSwitchState:NO];

    // 2. Deep reset C-level: clears activeColorHashes, flashHashes, colorLibraries,
    //    flashLibraries, pipelinePatches, pipelineDescriptors, hash tables.
    fmClearAllShaderPatches();

    // 3. Reset patch flags attivi senza toccare Memory (savedPatchCache/NSUserDefaults).
    //    I shader salvati nel Memory tab restano intatti per il match successivo.
    [self.shaderPage resetActivePatchesOnly];

    [self addLog:@"[SAFETY] ⚡ Doppio tap — Hooks OFF + tutti i patch azzerati"];
    // Flash icon red for 700ms as visual confirmation
    self.iconButton.layer.shadowColor = [UIColor colorWithRed:1.0 green:0.15 blue:0.15 alpha:1.0].CGColor;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self.iconButton.layer.shadowColor = [UIColor colorWithRed:0.45 green:0.25 blue:1.0 alpha:1.0].CGColor;
    });
}

// ── Pan: icon drag ────────────────────────────────────────────────────────────

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    CGPoint t = [gesture translationInView:self.menuWindow];
    UIButton *btn = self.iconButton;
    CGPoint c = CGPointMake(btn.center.x + t.x, btn.center.y + t.y);
    CGSize s = self.menuWindow.bounds.size;
    // Margine fisso 24pt: l'icona può andare parzialmente fuori schermo (drag libero)
    c.x = MAX(24, MIN(s.width  - 24, c.x));
    c.y = MAX(48, MIN(s.height - 48, c.y));
    btn.center = c;
    [gesture setTranslation:CGPointZero inView:self.menuWindow];
}

// ── Pan: debug panel drag ─────────────────────────────────────────────────────

- (void)handleDebugPanelDrag:(UIPanGestureRecognizer *)gesture {
    UIView *container = self.menuWindow.rootViewController.view;
    CGPoint t = [gesture translationInView:container];
    CGRect f = self.debugPanel.frame;
    f.origin.x += t.x; f.origin.y += t.y;
    CGSize s = [UIScreen mainScreen].bounds.size;
    f.origin.x = MAX(0, MIN(s.width  - f.size.width,  f.origin.x));
    f.origin.y = MAX(16, MIN(s.height - f.size.height - 16, f.origin.y));
    self.debugPanel.frame = f;
    [gesture setTranslation:CGPointZero inView:container];
}

- (void)show { self.menuWindow.hidden = NO; }
- (void)hide { self.menuWindow.hidden = YES; }

@end
