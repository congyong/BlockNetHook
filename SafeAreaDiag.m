/**
 * SafeAreaDiag.m  ->  SafeAreaDiag.dylib
 *
 * 安全区适配的「诊断版」—— **只读、零副作用**。
 *
 * ── 为什么需要它 ────────────────────────────────────────────────────────────
 * v1/v2 的修法是改 UIViewController.edgesForExtendedLayout。实测结果：
 *   · 系统弹窗（UIAlertController / UIActionSheet）被破坏 —— 说明 hook 确实生效
 *   · 但 App 自己的页面毫无变化 —— 说明 App 的目标根本不是 VC.view
 *
 * 静态分析该 App（com.app.scanapppro，Pro 1.9）主二进制得到关键类名：
 *   AddressBarView        顶部地址栏
 *   BottomToolBarView     底部工具栏
 *   BasisWKWebView        App 的 WKWebView 子类
 *   BSJTabBarController   根 tab 控制器
 *   ActionSheetView / BDTCustomAlertView   App 自绘弹窗
 *   AlertViewController / BaseController / ADVViewController ...
 *
 * 即：顶栏/底栏是**独立的自定义 UIView**，不是 VC.view 的边界布局。
 * 改 VC 的 edgesForExtendedLayout 不会让它们挪位，却会破坏系统弹窗。
 *
 * 与其继续猜，不如让设备自己说话。本插件：
 *   1. 遍历所有 UIWindow，打印 frame / safeAreaInsets / 是否 key
 *   2. 打印完整 UIViewController 树（类名 + edgesForExtendedLayout + view.frame）
 *   3. 打印 UIView 树（类名 + frame + 是否超出安全区 + 是否有约束）
 *   4. 把「被刘海/Home Indicator 遮挡」的 view 单独汇总成清单
 *   5. 结果同时 NSLog 和写入 App 的 Documents/safadiag-*.txt
 *
 * **绝不修改任何 view / VC / window 的属性** —— 只读。
 *
 * ── 使用 ────────────────────────────────────────────────────────────────────
 * LiveContainer → Tweaks → Import Tweak → 选 SafeAreaDiag-arm64.dylib
 * 启动 App → 走到出问题的那一页 → 等 1 秒
 * 日志看 NSLog（搜 [DIAG]），完整报告取 Documents/safadiag-*.txt
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#pragma mark - 输出

static NSMutableString *g_buf = nil;
static NSUInteger g_snapshot = 0;
static NSString *g_dir = nil;

static void DOut(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (!g_buf) g_buf = [NSMutableString string];
    [g_buf appendString:s];
    [g_buf appendString:@"\n"];
    NSLog(@"[DIAG] %@", [s stringByReplacingOccurrencesOfString:@"\n" withString:@" | "]);
}

static void DFlush(const char *tag) {
    if (!g_buf.length) return;
    NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *doc = dirs.firstObject;
    if (!doc) { g_buf = nil; return; }
    NSString *name = [NSString stringWithFormat:@"safadiag-%@-%lu.txt", tag, (unsigned long)g_snapshot];
    NSString *path = [doc stringByAppendingPathComponent:name];
    NSError *err = nil;
    NSString *header = [NSString stringWithFormat:
        @"===== SafeAreaDiag snapshot #%lu  %@ =====\n", (unsigned long)g_snapshot,
         [[NSDate date] descriptionWithLocale:[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]]];
    [[header stringByAppendingString:g_buf] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&err];
    if (err) NSLog(@"[DIAG] write failed: %@", err.localizedDescription);
    else NSLog(@"[DIAG] report written: %@", path);
    g_buf = [NSMutableString string];
    g_snapshot++;
}

#pragma mark - 越界判定

/* view 相对 window 是否被刘海 / Home Indicator 遮挡 */
static NSString *OverlapFlags(UIView *v, UIWindow *win) {
    if (!win) return @"";
    CGRect f = [v convertRect:v.bounds toView:win];
    CGRect wf = win.bounds;
    UIEdgeInsets ins = win.safeAreaInsets;
    NSMutableArray *m = [NSMutableArray array];

    if (CGRectIsEmpty(f) || CGRectIsEmpty(wf)) return @"";

    /* 上方被挡：view 顶部在安全区上沿之上，且有部分落在窗口内 */
    if (f.origin.y < ins.top - 0.5 && CGRectGetMaxY(f) > ins.top)
        [m addObject:@"TOP"];
    /* 下方被挡 */
    if (CGRectGetMaxY(f) > CGRectGetHeight(wf) - ins.bottom + 0.5 && f.origin.y < CGRectGetHeight(wf) - ins.bottom)
        [m addObject:@"BOT"];
    /* 左右 */
    if (f.origin.x < ins.left - 0.5 && CGRectGetMaxX(f) > ins.left) [m addObject:@"LEFT"];
    if (CGRectGetMaxX(f) > CGRectGetWidth(wf) - ins.right + 0.5 && f.origin.x < CGRectGetWidth(wf) - ins.right)
        [m addObject:@"RIGHT"];

    return m.count ? [m componentsJoinedByString:@"|"] : @"";
}

static BOOL IsSystemClass(NSString *cn) {
    if ([cn hasPrefix:@"_"]) return YES;
    static NSArray *sys = nil;
    if (!sys) sys = @[@"UIAlertController", @"UIActionSheet", @"UIAlertView",
                      @"UIPopoverPresentationController", @"UIContextMenu",
                      @"_UI", @"UITextEffects", @"UIInputSet", @"UIKeyboard",
                      @"UIRemoteKeyboard", @"UIPresentation", @"UIMenu",
                      @"UIEditMenu", @"UIEditingMenu"];
    for (NSString *s in sys) if ([cn hasPrefix:s]) return YES;
    return NO;
}

#pragma mark - 遍历

static void DumpViewTree(UIView *v, NSInteger depth, UIWindow *win, NSMutableArray *overlapList) {
    if (!v || depth > 4) return;

    NSString *cn = NSStringFromClass([v class]);
    CGRect f = [v convertRect:v.bounds toView:win];
    NSString *flags = OverlapFlags(v, win);

    BOOL interesting = flags.length > 0
        || [cn containsString:@"AddressBar"]
        || [cn containsString:@"ToolBar"]
        || [cn containsString:@"BasisWK"]
        || [cn containsString:@"TabBar"]
        || [cn containsString:@"NavigationBar"]
        || [cn containsString:@"StatusBar"]
        || [cn containsString:@"Bar"];

    if (interesting) {
        NSString *pad = [@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0];
        BOOL auto = v.translatesAutoresizingMaskIntoConstraints;
        DOut(@"%@V %@ frame=(%.0f,%.0f,%.0f,%.0f) safe=(%.0f,%.0f,%.0f,%.0f) hidden=%d alpha=%.2f autoTF=%d %@",
             pad, cn, f.origin.x, f.origin.y, f.size.width, f.size.height,
             win ? win.safeAreaInsets.top : 0, win ? win.safeAreaInsets.left : 0,
             win ? win.safeAreaInsets.bottom : 0, win ? win.safeAreaInsets.right : 0,
             v.hidden, v.alpha, auto, flags.length ? [@"⚠️ " stringByAppendingString:flags] : @"");
        if (flags.length) {
            [overlapList addObject:[NSString stringWithFormat:@"%@%@ frame=(%.0f,%.0f,%.0f,%.0f) %@",
                [@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0],
                cn, f.origin.x, f.origin.y, f.size.width, f.size.height, flags]];
        }
    }

    NSArray *subs = v.subviews;
    NSInteger n = MIN((NSInteger)subs.count, 40);
    for (NSInteger i = 0; i < n; i++) {
        DumpViewTree(subs[i], depth + 1, win, overlapList);
    }
}

static void DumpVCTree(UIViewController *vc, NSInteger depth) {
    if (!vc || depth > 6) return;
    NSString *pad = [@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0];
    UIView *v = vc.isViewLoaded ? vc.view : nil;
    DOut(@"%@C %@ edges=%ld viewLoaded=%d frame=%@",
         pad, NSStringFromClass([vc class]), (long)vc.edgesForExtendedLayout,
         vc.isViewLoaded,
         v ? [NSString stringWithFormat:@"(%.0f,%.0f,%.0f,%.0f)",
              v.frame.origin.x, v.frame.origin.y, v.frame.size.width, v.frame.size.height] : @"nil");

    for (UIViewController *c in vc.childViewControllers) DumpVCTree(c, depth + 1);
    if (vc.presentedViewController) {
        DOut(@"%@  ↳ presented:", pad);
        DumpVCTree(vc.presentedViewController, depth + 1);
    }
}

#pragma mark - 快照

static void TakeSnapshot(const char *tag) {
    @try {
        g_buf = [NSMutableString string];

        UIScreen *scr = [UIScreen mainScreen];
        DOut(@"screen=%.0fx%.0f scale=%.1f orientation=%ld",
             scr.bounds.size.width, scr.bounds.size.height, scr.scale,
             (long)[scr valueForKey:@"orientation"]);

        NSArray *wins = [UIApplication sharedApplication].windows;
        DOut(@"windows=%lu", (unsigned long)wins.count);

        NSMutableArray *overlapList = [NSMutableArray array];

        for (UIWindow *w in wins) {
            NSString *cn = NSStringFromClass([w class]);
            CGRect wf = w.frame;
            UIEdgeInsets ins = w.safeAreaInsets;
            DOut(@"WIN %@ frame=(%.0f,%.0f,%.0f,%.0f) safe=(t=%.0f,l=%.0f,b=%.0f,r=%.0f) key=%d hidden=%d alpha=%.2f level=%f sys=%d",
                 cn, wf.origin.x, wf.origin.y, wf.size.width, wf.size.height,
                 ins.top, ins.left, ins.bottom, ins.right,
                 w.isKeyWindow, w.hidden, w.alpha, w.windowLevel,
                 IsSystemClass(cn));

            if (w.rootViewController) {
                DOut(@"  VC tree:");
                DumpVCTree(w.rootViewController, 2);
            }
            if (w.subviews.count) {
                DOut(@"  VIEW tree:");
                for (UIView *sv in w.subviews) DumpViewTree(sv, 2, w, overlapList);
            }
        }

        DOut(@"");
        DOut(@"===== 被刘海/Home Indicator 遮挡的 view 清单 (%lu) =====", (unsigned long)overlapList.count);
        for (NSString *s in overlapList) DOut(@"  ⚠️ %@", s);

        DFlush(tag);
    } @catch (NSException *e) {
        NSLog(@"[DIAG] snapshot failed: %@ %@", e.name, e.reason);
    }
}

static void TakeSnapshotLater(const char *tag, NSTimeInterval delay) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try { TakeSnapshot(tag); } @catch (NSException *e) {}
    });
}

#pragma mark - Hook（全部只读）

static IMP g_origMakeKeyAndVisible = NULL;
static IMP g_origViewDidAppear      = NULL;
static IMP g_origDidBecomeVisible   = NULL;

static void hook_makeKeyAndVisible(id self, SEL _cmd) {
    if (g_origMakeKeyAndVisible) ((void (*)(id, SEL))g_origMakeKeyAndVisible)(self, _cmd);
    TakeSnapshotLater("launch", 1.2);
    TakeSnapshotLater("launch", 3.0);
}

static void hook_viewDidAppear(id self, SEL _cmd) {
    if (g_origViewDidAppear) ((void (*)(id, SEL))g_origViewDidAppear)(self, _cmd);
    const char *cls = class_getName(object_getClass(self));
    NSString *tag = [NSString stringWithFormat:@"%s", cls];
    TakeSnapshotLater([tag UTF8String], 0.8);
}

static void hook_didBecomeVisible(id self, SEL _cmd) {
    if (g_origDidBecomeVisible) ((void (*)(id, SEL))g_origDidBecomeVisible)(self, _cmd);
    TakeSnapshotLater("winvisible", 0.8);
}

static BOOL SAFDiagHook(Class cls, SEL sel, IMP newImp, IMP *oldImp) {
    if (!cls || !sel) return NO;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    IMP orig = method_setImplementation(m, newImp);
    if (oldImp) *oldImp = orig;
    return orig != NULL;
}

__attribute__((constructor))
static void SafeAreaDiagInit(void) {
    NSUInteger n = 0;
    if (SAFDiagHook([UIWindow class], @selector(makeKeyAndVisible),
                     (IMP)hook_makeKeyAndVisible, &g_origMakeKeyAndVisible)) n++;
    if (SAFDiagHook([UIViewController class], @selector(viewDidAppear:),
                     (IMP)hook_viewDidAppear, &g_origViewDidAppear)) n++;
    if (SAFDiagHook([UIWindow class], @selector(didBecomeVisible),
                     (IMP)hook_didBecomeVisible, &g_origDidBecomeVisible)) n++;

    NSLog(@"[DIAG] ✅ SafeAreaDiag loaded (%lu hooks) — 只读诊断，不修改任何东西", (unsigned long)n);
    TakeSnapshotLater("init", 1.5);
}
