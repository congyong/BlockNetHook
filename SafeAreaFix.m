/**
 * SafeAreaFix.m  ->  SafeAreaFix.dylib
 *
 * 为「指尖浏览器 / 指尖浏览器Pro 1.9」（bundle: com.app.scanapppro）补上
 * 刘海屏 / 灵动岛 / Home Indicator / 圆角屏的安全区适配。
 *
 * ── 为什么必须做（对该 App 主二进制的实测数据）────────────────────────────
 *   safeAreaInsets                  → 0 次引用
 *   safeAreaLayoutGuide             → 0 次引用
 *   viewSafeAreaInsetsDidChange     → 0 次引用
 *   topLayoutGuide / bottomLayoutGuide → 0 次引用
 *   contentInsetAdjustmentBehavior  → 0 次引用
 *   edgesForExtendedLayout          → 2 次引用（只用了 iOS 7 的老 API）
 *   UIScreen / bounds               → 4 / 84 次（布局全部基于屏幕物理尺寸）
 *
 * 结论：该 App 建于 2018 年（iOS 11.1 SDK），出生在安全区概念普及之前，
 *       布局一律按 UIScreen.main.bounds 硬算，从不读安全区。
 *       iOS 13+ 会把「未声明支持新屏幕」的旧 App 铺满全屏，于是
 *         · 顶栏按钮压进刘海 / 灵动岛
 *         · 底栏按钮压进 Home Indicator
 *       → 上下两端按钮点不到。
 *
 *   配套证据：Info.plist 的 UILaunchImages 只覆盖到 iPhone X（375×812pt），
 *   390×844 / 393×852 / 414×896 / 430×932 / 440×956 全部缺失。
 *
 * ── 修法（只做「系统本该替它做」的补正，不改业务逻辑）──────────────────────
 *   1. UIViewController.viewDidLoad / viewWillAppear: / viewDidLayoutSubviews
 *      → 在原实现之后把 edgesForExtendedLayout 收成「不含 Top/Bottom」，
 *        UIKit 随即把 VC.view 收缩进安全区。因为 App 内部元素是相对 view
 *        布局的（view 尺寸变了但相对坐标不变），顶栏自动下移到刘海下方、
 *        底栏自动上移到 Home Indicator 上方 —— 一次设置，全页生效。
 *
 *   2. WKWebView 初始化后强制 contentInsetAdjustmentBehavior = .always
 *        WKWebView 默认是 .automatic，而 .automatic 在 WKWebView 内不会真正
 *        加 inset，网页内容会被 Home Indicator 盖住。这是 WebKit 的经典坑。
 *
 * ── 安全阀（重要）─────────────────────────────────────────────────────────
 *   · 只有当设备真实存在安全区（window.safeAreaInsets 非零）时才动作。
 *     iPhone SE / 8 这类无刘海机型上如果也设 edgesForExtendedLayout = None，
 *     view 会从 status bar 下方开始，App 写死的顶部坐标反而会被遮挡 —— 必须避免。
 *   · UIViewController / UINavigationController / UITabBarController 自身跳过，
 *     它们内部已由 UIKit 处理。
 *   · 不依赖 CydiaSubstrate / ElleKit：hook 用 objc runtime 的
 *     method_setImplementation 实现，与同仓库 BlockNetPlus.m 同一套思路，
 *     因此 LiveContainer 外置 dylib 即可生效，无需越狱。
 *   · 不链接 WebKit.framework：WKWebView 走 NSClassFromString + objc_msgSend，
 *     避免为一个可选功能引入额外框架依赖。
 *
 * ── 可调开关（App 内 NSUserDefaults）──────────────────────────────────────
 *   SAF_LOG        "0" 关闭日志（默认开）
 *   SAF_MODE       "auto"（默认）| "off" 完全关闭 | "force" 无视安全区检查
 *   SAF_NAV        "auto"（默认）| "nav" 一律收缩含导航栏容器 | "bare" 一律只处理裸 VC
 *   SAF_WEBVIEW    "0" 关闭 WKWebView inset 修正
 *
 * 编译：见同目录 Makefile / .github/workflows/build.yml（需 macOS + Xcode iOS SDK）
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>

#pragma mark - 日志

static BOOL SAFLoggingEnabled(void) {
    static BOOL enabled = YES;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *v = getenv("SAF_LOG");
        if (v && (!strcmp(v, "0") || !strcasecmp(v, "off"))) enabled = NO;
        else {
            NSString *s = [[NSUserDefaults standardUserDefaults] stringForKey:@"SAF_LOG"];
            if ([s isEqualToString:@"0"] || [s.lowercaseString isEqualToString:@"off"]) enabled = NO;
        }
    });
    return enabled;
}

#define SAFLog(fmt, ...) do { \
    if (SAFLoggingEnabled()) NSLog((@"[SafeAreaFix] " fmt), ##__VA_ARGS__); \
} while (0)

static NSString *SAFConfigValue(NSString *key, NSString *fallback) {
    NSString *v = [[NSUserDefaults standardUserDefaults] stringForKey:key];
    if (v.length == 0) v = fallback;
    return v.lowercaseString ?: fallback;
}

#pragma mark - Hook helper（与 BlockNetPlus.m 的 BNPHook 同一套思路）

static BOOL SAFHook(Class cls, SEL sel, IMP newImp, IMP *oldImp) {
    if (!cls || !sel || !newImp) return NO;
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) {
        SAFLog(@"⚠️ method not found: %@ %@", cls, NSStringFromSelector(sel));
        return NO;
    }
    IMP orig = method_setImplementation(method, newImp);
    if (oldImp) *oldImp = orig;
    return orig != NULL;
}

#pragma mark - 状态

static IMP g_origViewDidLoad           = NULL;
static IMP g_origViewWillAppear        = NULL;
static IMP g_origViewDidLayoutSubviews = NULL;
static IMP g_origWKInitWithFrame       = NULL;
static IMP g_origWKInitWithCoder       = NULL;

static NSUInteger g_appliedCount = 0;

/* 已经处理过的 VC，用 associated object 打标，避免重复设置 */
static const void *kSAFMarkKey = &kSAFMarkKey;

#pragma mark - 核心：把 VC.view 收缩进安全区

/* 拿到设备真实安全区。返回 NO 表示这台设备没有安全区（老机型），不要动。 */
static BOOL SAFDeviceHasSafeArea(UIViewController *vc) {
    UIWindow *win = vc.view.window;
    if (!win) {
        /* view 还没上屏：退回到 keyWindow，safeAreaInsets 反映的是屏幕安全区 */
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w.isKeyWindow) { win = w; break; }
        }
    }
    if (!win) return NO;

    UIEdgeInsets ins = win.safeAreaInsets;
    return (ins.top > 0.0 || ins.bottom > 0.0 || ins.left > 0.0 || ins.right > 0.0);
}

/* 真正执行收缩；已处理过则跳过 */
static void SAFDoApply(id obj);

static void SAFApplyToViewController(id obj) {
    if (![obj isKindOfClass:[UIViewController class]]) return;
    UIViewController *vc = (UIViewController *)obj;

    NSString *mode = SAFConfigValue(@"SAF_MODE", @"auto");
    if ([mode isEqualToString:@"off"]) return;

    /* 容器自身交给 UIKit 处理 */
    if ([vc isKindOfClass:[UINavigationController class]] ||
        [vc isKindOfClass:[UITabBarController class]] ||
        [vc isKindOfClass:[UISplitViewController class]] ||
        [vc isKindOfClass:[UIPageViewController class]]) {
        return;
    }

    /* 已处理过 */
    if (objc_getAssociatedObject(vc, kSAFMarkKey) != nil) return;

    if ([mode isEqualToString:@"auto"]) {
        if (!SAFDeviceHasSafeArea(vc)) {
            /* view 尚未上屏时 window 为 nil —— 下一轮 runloop 再试一次 */
            if (!vc.view.window) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (objc_getAssociatedObject(vc, kSAFMarkKey) == nil) {
                        SAFApplyToViewController(vc);
                    }
                });
            }
            return;
        }
    }

    NSString *navPolicy = SAFConfigValue(@"SAF_NAV", @"auto");
    BOOL bare = [navPolicy isEqualToString:@"bare"];
    BOOL all  = [navPolicy isEqualToString:@"nav"];
    if (bare && (vc.navigationController || vc.tabBarController)) return;
    if (all && !(vc.navigationController || vc.tabBarController)) return;

    SAFDoApply(vc);
}

static void SAFDoApply(id obj) {
    UIViewController *vc = (UIViewController *)obj;
    if (!vc.view) return;

    UIRectEdge edges = vc.edgesForExtendedLayout;
    if (edges == UIRectEdgeNone) return;   /* 已经是收缩状态 */

    /* 只剥离 Top / Bottom，保留 Left / Right：
       竖屏时左右本来就没内容；横屏时刘海在左右侧，
       剥离左右会让侧边内容也缩进去，所以这里保留，由 UIKit 按方向处理。 */
    UIRectEdge stripped = edges & ~(UIRectEdgeTop | UIRectEdgeBottom);
    if (stripped == edges) return;

    vc.edgesForExtendedLayout = stripped;
    objc_setAssociatedObject(vc, kSAFMarkKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    g_appliedCount++;

    UIEdgeInsets ins = vc.view.window.safeAreaInsets;
    SAFLog(@"✅ %@ edges %ld→%ld (safeArea top=%.0f bottom=%.0f) [applied=%lu]",
           NSStringFromClass([vc class]),
           (long)edges, (long)stripped,
           ins.top, ins.bottom,
           (unsigned long)g_appliedCount);

    /* 立刻重排一次，让顶/底栏马上落位 */
    [vc.view setNeedsLayout];
    [vc.view layoutIfNeeded];
}

#pragma mark - UIViewController hooks

static void SAF_hook_viewDidLoad(id self, SEL _cmd) {
    if (g_origViewDidLoad) ((void (*)(id, SEL))g_origViewDidLoad)(self, _cmd);
    SAFApplyToViewController(self);
}

static void SAF_hook_viewWillAppear(id self, SEL _cmd, id animated) {
    if (g_origViewWillAppear) ((void (*)(id, SEL, id))g_origViewWillAppear)(self, _cmd, animated);
    SAFApplyToViewController(self);
}

static void SAF_hook_viewDidLayoutSubviews(id self, SEL _cmd) {
    if (g_origViewDidLayoutSubviews) ((void (*)(id, SEL))g_origViewDidLayoutSubviews)(self, _cmd);
    SAFApplyToViewController(self);
}

#pragma mark - WKWebView hooks（网页内容避开 Home Indicator）
/* 不链接 WebKit.framework：用 objc_msgSend 动态调用 */

static void SAFConfigureWebView(id webView) {
    if (!webView) return;
    NSString *flag = SAFConfigValue(@"SAF_WEBVIEW", @"1");
    if ([flag isEqualToString:@"0"]) return;

    Class scrollViewClass = NSClassFromString(@"UIScrollView");
    SEL scrollViewSel = NSSelectorFromString(@"scrollView");
    if (!scrollViewClass || !scrollViewSel) return;
    if (![webView respondsToSelector:scrollViewSel]) return;

    /* 可变参数版 msgSend，避免强转成固定参数原型 */
    id (*msgSend)(id, SEL, ...) = (id (*)(id, SEL, ...))objc_msgSend;

    id scrollView = msgSend(webView, scrollViewSel);
    if (!scrollView) return;

    SEL behaviorSel = NSSelectorFromString(@"setContentInsetAdjustmentBehavior:");
    if (![scrollView respondsToSelector:behaviorSel]) return;

    msgSend(scrollView, behaviorSel, (NSInteger)2);   /* UIScrollViewContentInsetAdjustmentAlways */

    SAFLog(@"ℹ️ WKWebView contentInsetAdjustmentBehavior → always");
}

static id SAF_hook_WKInitWithFrame(id self, SEL _cmd, CGRect frame) {
    id ret = nil;
    if (g_origWKInitWithFrame) {
        ret = ((id (*)(id, SEL, CGRect))g_origWKInitWithFrame)(self, _cmd, frame);
    }
    Class wkClass = NSClassFromString(@"WKWebView");
    if (wkClass && [ret isKindOfClass:wkClass]) SAFConfigureWebView(ret);
    return ret;
}

static id SAF_hook_WKInitWithCoder(id self, SEL _cmd, NSCoder *coder) {
    id ret = nil;
    if (g_origWKInitWithCoder) {
        ret = ((id (*)(id, SEL, NSCoder *))g_origWKInitWithCoder)(self, _cmd, coder);
    }
    Class wkClass = NSClassFromString(@"WKWebView");
    if (wkClass && [ret isKindOfClass:wkClass]) SAFConfigureWebView(ret);
    return ret;
}

#pragma mark - 构造函数

__attribute__((constructor))
static void SafeAreaFixInit(void) {
    NSUInteger installed = 0;

    Class VC = [UIViewController class];
    if (SAFHook(VC, @selector(viewDidLoad), (IMP)SAF_hook_viewDidLoad, &g_origViewDidLoad)) installed++;
    if (SAFHook(VC, @selector(viewWillAppear:), (IMP)SAF_hook_viewWillAppear, &g_origViewWillAppear)) installed++;
    if (SAFHook(VC, @selector(viewDidLayoutSubviews), (IMP)SAF_hook_viewDidLayoutSubviews, &g_origViewDidLayoutSubviews)) installed++;

    /* WKWebView 用 NSClassFromString 取，避免强制链接 WebKit.framework */
    Class WK = NSClassFromString(@"WKWebView");
    if (WK) {
        if (SAFHook(WK, @selector(initWithFrame:), (IMP)SAF_hook_WKInitWithFrame, &g_origWKInitWithFrame)) installed++;
        if (SAFHook(WK, @selector(initWithCoder:), (IMP)SAF_hook_WKInitWithCoder, &g_origWKInitWithCoder)) installed++;
    }

    SAFLog(@"✅ loading (%lu hooks installed) — 指尖浏览器安全区适配已启用",
           (unsigned long)installed);
}
