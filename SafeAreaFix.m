/**
 * SafeAreaFix.m  ->  SafeAreaFix.dylib   (v2 加固版)
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
 * ── v2 加固：修掉 v1 会导致「点击设置闪退」的四个缺陷 ─────────────────────
 *   缺陷 1【致命·递归崩溃】
 *     v1 在 viewDidLayoutSubviews 回调里调用 [view layoutIfNeeded]。
 *     UIKit 明确禁止在 layout pass 中调 layoutIfNeeded —— 会无限递归，
 *     表现为「进设置页闪退」。v2 彻底不再 hook viewDidLayoutSubviews。
 *
 *   缺陷 2【致命·递归重入】
 *     v1 先执行 edgesForExtendedLayout = stripped（setter 内部会触发
 *     setNeedsLayout，可能同步重入 layout 回调），再打 associated object 标记。
 *     重入时标记还没设 → 再次进入 → 再次 setter → 无限递归。
 *     v2 把标记提到 setter 之前。
 *
 *   缺陷 3【ABI 错误·行为未定义】
 *     v1 的 viewWillAppear: 钩子把 BOOL animated 声明成 id。
 *     arm64 calling convention 下这是 UB —— 寄存器里的 BOOL 会被当指针解释。
 *     v2 改成正确的 BOOL。
 *
 *   缺陷 4【风险·主动触发 view 加载】
 *     v1 到处直接访问 vc.view，会在 view 尚未加载时触发 loadView，
 *     在 viewDidLoad 上下文中极易重入。v2 一律先用 isViewLoaded 判断，
 *     且只在 VC 真正上屏（view.window != nil）时才动手。
 *
 *   另外：v2 给所有 hook 套了 @try/@catch，任何 NSException 都不会外泄成崩溃；
 *   延后重试有次数上限，不会无限排程。
 *
 * ── 修法（只做「系统本该替它做」的补正，不改业务逻辑）──────────────────────
 *   1. 只在 VC 已经上屏且设备确有安全区时，把 edgesForExtendedLayout 的
 *      Top/Bottom 位剥离 → UIKit 把 VC.view 收缩进安全区。App 内部元素是
 *      相对 view 布局的，view 尺寸变了但相对坐标不变，所以顶栏自动下移到
 *      刘海下方、底栏自动上移到 Home Indicator 上方 —— 一次设置，全页生效。
 *
 *   2. WKWebView 初始化后（延后一轮 runloop）强制
 *      contentInsetAdjustmentBehavior = .always，让网页内容避开底部横条。
 *      WKWebView 默认 .automatic，而 .automatic 在 WKWebView 内不会真正加 inset。
 *
 * ── 安全阀 ────────────────────────────────────────────────────────────────
 *   · 只有 window.safeAreaInsets 非零的设备才动作。
 *     iPhone SE / 8 这类无刘海机型如果也设 edgesForExtendedLayout = None，
 *     view 会从 status bar 下方开始，App 写死的顶部坐标反而被遮挡。
 *   · UIViewController / UINavigationController / UITabBarController /
 *     UISplitViewController / UIPageViewController 自身跳过。
 *   · 不依赖 CydiaSubstrate / ElleKit：hook 用 objc runtime 的
 *     method_setImplementation 实现，LiveContainer 外置 dylib 即可生效。
 *   · 不链接 WebKit.framework：WKWebView 走 NSClassFromString + objc_msgSend。
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

/* 所有 hook 主体都套上：任何 NSException 都不允许外泄成崩溃 */
#define SAFProtected(body) do { \
    @try { body } \
    @catch (NSException *e) { SAFLog(@"⚠️ 捕获异常 %@: %@", e.name, e.reason); } \
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

static IMP g_origViewDidLoad     = NULL;
static IMP g_origViewWillAppear  = NULL;
static IMP g_origWKInitWithFrame = NULL;
static IMP g_origWKInitWithCoder = NULL;

static NSUInteger g_appliedCount = 0;
static NSUInteger g_retryCount   = 0;      /* 延后重试次数（全局上限） */
static BOOL       g_inApply       = NO;    /* 重入保护 */

/* 已经处理过的 VC，用 associated object 打标，避免重复设置 */
static const void *kSAFMarkKey = &kSAFMarkKey;
/* 延后重试次数的 per-VC 标记 */
static const void *kSAFRetryKey = &kSAFRetryKey;

#pragma mark - 核心：把 VC.view 收缩进安全区

/* 设备是否真实存在安全区（刘海 / Home Indicator）。没有就绝不能动。
 *
 * ★ v2.3 关键修正：LiveContainer 这类「容器式」运行环境里，guest app 的
 * window 可能没有设置 safeAreaInsets（实测为全 0）。若只信 window.safeAreaInsets，
 * 插件就会判定「这台设备没有刘海」而全程不动作 —— 表现正是「没生效」。
 *
 * 所以加一条兜底：按主屏幕逻辑高度判断。
 *   iPhone SE / 8     = 667pt  → 无刘海
 *   iPhone 8 Plus     = 736pt  → 无刘海
 *   iPhone X 及以上   = 812pt 起 → 有刘海
 * 800pt 是可靠的判据分界。
 */
/* ★ 判断一个类是不是「系统 / 第三方库」的类。
 * class_getImageName 返回该类所在的镜像路径：
 *   · UIKit / Foundation 等系统框架 → "/System/Library/Frameworks/UIKit.framework/UIKit"
 *   · App 主二进制里的类        → NULL（或指向 App 可执行文件）
 *   · 第三方 dylib 里的类       → 指向那个 dylib 的路径
 * 用它来避免误伤系统弹窗（UIAlertController / UIActionSheet 等）。
 */
static BOOL SAFIsSystemOrThirdParty(Class cls) {
    const char *img = class_getImageName(cls);
    if (!img) return NO;                       /* 主 bundle 的类 → App 自己的 */
    if (strstr(img, "/System/Library/")) return YES;   /* 系统框架 → 跳过 */
    return NO;
}

/* 系统呈现类额外排除（即使不是 UIKit 框架的类） */
static BOOL SAFIsSystemPresentation(UIViewController *vc) {
    static NSArray *extra = nil;
    if (!extra) extra = @[[UIAlertController class], [UIPopoverPresentationController class]];
    for (Class c in extra) if ([vc isKindOfClass:c]) return YES;
    if ([vc isKindOfClass:[UIActivityViewController class]]) return YES;
    return NO;
}

static BOOL SAFDeviceHasSafeArea(UIViewController *vc) {
    UIWindow *win = vc.view.window;
    if (!win) {
        /* view 未上屏时退回 keyWindow —— 它的 safeAreaInsets 反映的是屏幕安全区 */
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w.isKeyWindow) { win = w; break; }
        }
    }
    if (win) {
        UIEdgeInsets ins = win.safeAreaInsets;
        if (ins.top > 0.0 || ins.bottom > 0.0 || ins.left > 0.0 || ins.right > 0.0) return YES;
    }

    /* 兜底：按屏幕高度判断 */
    CGFloat h = [UIScreen mainScreen].bounds.size.height;
    return (h >= 800.0);
}

/* 诊断信息：一眼看出为什么没生效 */
static void SAFLogDiagnostics(UIViewController *vc) {
    UIWindow *win = vc.view.window;
    UIEdgeInsets ins = win ? win.safeAreaInsets : UIEdgeInsetsZero;
    CGSize scr = [UIScreen mainScreen].bounds.size;
    SAFLog(@"ℹ️ 诊断: %@ window=%@ safeArea(top=%.0f bottom=%.0f l=%.0f r=%.0f) screen=%.0fx%.0f "
           @"hasSafeArea=%d",
           NSStringFromClass([vc class]),
           win ? @"有" : @"nil",
           ins.top, ins.bottom, ins.left, ins.right,
           scr.width, scr.height,
           SAFDeviceHasSafeArea(vc));
}

/* 真正执行收缩；已处理过则跳过 */
static void SAFDoApply(id obj);

/* WKWebView hook 的延迟补装（定义在文件后段） */
static void SAFEnsureWebViewHook(void);

/* SAFScheduleRetry 会回调它，而它的定义在后面 —— 必须先声明。
   C99 起隐式函数声明是编译错误（-Wimplicit-function-declaration）。 */
static void SAFApplyToViewController(id obj);

static void SAFScheduleRetry(UIViewController *vc) {
    if (g_retryCount >= 8) return;   /* 全局上限，别无限排程 */

    NSNumber *n = objc_getAssociatedObject(vc, kSAFRetryKey);
    if (n && n.integerValue >= 4) return;   /* per-VC 上限 */

    g_retryCount++;
    objc_setAssociatedObject(vc, kSAFRetryKey, @(n ? n.integerValue + 1 : 1),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    dispatch_async(dispatch_get_main_queue(), ^{
        if (objc_getAssociatedObject(vc, kSAFMarkKey) != nil) return;
        SAFApplyToViewController(vc);
    });
}

static void SAFApplyToViewController(id obj) {
    if (![obj isKindOfClass:[UIViewController class]]) return;
    if (g_inApply) return;                 /* 重入保护 */
    UIViewController *vc = (UIViewController *)obj;

    /* 每次 VC 出现都补装 WKWebView hook（WebKit 可能晚于构造函数加载） */
    SAFEnsureWebViewHook();

    NSString *mode = SAFConfigValue(@"SAF_MODE", @"auto");
    if ([mode isEqualToString:@"off"]) return;

    /* ★ 系统 / 第三方库的 VC 一律不碰 —— v2 就是在这里破坏了系统弹窗 */
    if (SAFIsSystemPresentation(vc)) return;
    if (SAFIsSystemOrThirdParty([vc class])) {
        SAFLog(@"⏭️ 跳过系统/三方 VC: %@", NSStringFromClass([vc class]));
        return;
    }

    /* 容器自身交给 UIKit 处理 */
    if ([vc isKindOfClass:[UINavigationController class]] ||
        [vc isKindOfClass:[UITabBarController class]] ||
        [vc isKindOfClass:[UISplitViewController class]] ||
        [vc isKindOfClass:[UIPageViewController class]]) {
        return;
    }

    /* 已处理过 */
    if (objc_getAssociatedObject(vc, kSAFMarkKey) != nil) return;

    /* ★ 绝不主动触发 view 加载 —— isViewLoaded 只读，不会 loadView */
    if (!vc.isViewLoaded) {
        SAFScheduleRetry(vc);
        return;
    }

    /* ★ 必须在 view 已经上屏时才动手：此时 UIKit 才真的知道安全区，
       且改 edgesForExtendedLayout 不会和正在进行的布局打架 */
    if (!vc.view.window) {
        SAFScheduleRetry(vc);
        return;
    }

    if ([mode isEqualToString:@"auto"]) {
        if (!SAFDeviceHasSafeArea(vc)) {
            SAFLogDiagnostics(vc);
            return;   /* 无刘海设备一律不动 */
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
    if (!vc.isViewLoaded || !vc.view) return;

    UIRectEdge edges = vc.edgesForExtendedLayout;
    if (edges == UIRectEdgeNone) return;   /* 已经是收缩状态 */

    /* 只剥离 Top / Bottom，保留 Left / Right：
       竖屏时左右本来就没内容；横屏时刘海在左右侧，
       剥离左右会让侧边内容也缩进去，所以这里保留，由 UIKit 按方向处理。 */
    UIRectEdge stripped = edges & ~(UIRectEdgeTop | UIRectEdgeBottom);
    if (stripped == edges) return;

    g_inApply = YES;

    /* ★★★ 标记必须打在 setter 之前 ★★★
       setter 内部会触发 setNeedsLayout，可能同步重入 layout 回调；
       若标记还没设，重入时会再次进入这里 → 无限递归 → 崩溃。 */
    objc_setAssociatedObject(vc, kSAFMarkKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    g_appliedCount++;

    UIEdgeInsets ins = vc.view.window.safeAreaInsets;
    SAFLog(@"✅ %@ edges %ld→%ld (safeArea top=%.0f bottom=%.0f) [applied=%lu]",
           NSStringFromClass([vc class]),
           (long)edges, (long)stripped,
           ins.top, ins.bottom,
           (unsigned long)g_appliedCount);

    vc.edgesForExtendedLayout = stripped;

    /* ★ 只 setNeedsLayout，绝不 layoutIfNeeded ——
       在 layout 回调里调 layoutIfNeeded 会造成无限递归。 */
    [vc.view setNeedsLayout];

    g_inApply = NO;
}

#pragma mark - UIViewController hooks

/* ★ 不再 hook viewDidLayoutSubviews —— layout pass 中改布局 = 无限递归 = 闪退 */

static void SAF_hook_viewDidLoad(id self, SEL _cmd) {
    if (g_origViewDidLoad) ((void (*)(id, SEL))g_origViewDidLoad)(self, _cmd);
    SAFProtected({
        /* viewDidLoad 时 view 刚加载完但通常还没上屏 → 这里只排队，
           等 viewWillAppear: / 下一轮 runloop 再真正动手 */
        SAFApplyToViewController(self);
    });
}

static void SAF_hook_viewWillAppear(id self, SEL _cmd, BOOL animated) {
    if (g_origViewWillAppear) ((void (*)(id, SEL, BOOL))g_origViewWillAppear)(self, _cmd, animated);
    SAFProtected({
        SAFApplyToViewController(self);
    });
}

#pragma mark - WKWebView hooks（网页内容避开 Home Indicator）
/* 不链接 WebKit.framework：用 objc_msgSend 动态调用 */

/* ★ v2 修正：WKWebView 类是「App 首次创建 WKWebView 时」才被 dyld 加载的。
   如果 dylib 构造函数跑得比那更早，NSClassFromString 返回 nil，
   init hook 就永远装不上（表现为网页内容不避让 Home Indicator）。
   所以在每次 VC 出现时补装一次。 */
static BOOL g_webViewHooked = NO;

/* ★ 前向声明：下面 SAFEnsureWebViewHook 会用到这两个 hook 函数，
   而它们的定义在更后面。C99 起隐式函数声明是错误，必须显式声明。 */
static id SAF_hook_WKInitWithFrame(id self, SEL _cmd, CGRect frame);
static id SAF_hook_WKInitWithCoder(id self, SEL _cmd, NSCoder *coder);

static void SAFEnsureWebViewHook(void) {
    if (g_webViewHooked) return;
    Class WK = NSClassFromString(@"WKWebView");
    if (!WK) return;   /* WebKit 还没加载，下次再试 */
    g_webViewHooked = YES;
    NSUInteger n = 0;
    if (SAFHook(WK, @selector(initWithFrame:), (IMP)SAF_hook_WKInitWithFrame, &g_origWKInitWithFrame)) n++;
    if (SAFHook(WK, @selector(initWithCoder:), (IMP)SAF_hook_WKInitWithCoder, &g_origWKInitWithCoder)) n++;
    SAFLog(@"ℹ️ WKWebView hooks 已补装 (%lu)", (unsigned long)n);
}

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
    if (wkClass && [ret isKindOfClass:wkClass]) {
        /* 延后一轮 runloop：不要在 WKWebView 初始化过程中动它的 scrollView */
        id wv = ret;
        dispatch_async(dispatch_get_main_queue(), ^{
            SAFProtected({ SAFConfigureWebView(wv); });
        });
    }
    return ret;
}

static id SAF_hook_WKInitWithCoder(id self, SEL _cmd, NSCoder *coder) {
    id ret = nil;
    if (g_origWKInitWithCoder) {
        ret = ((id (*)(id, SEL, NSCoder *))g_origWKInitWithCoder)(self, _cmd, coder);
    }
    Class wkClass = NSClassFromString(@"WKWebView");
    if (wkClass && [ret isKindOfClass:wkClass]) {
        id wv = ret;
        dispatch_async(dispatch_get_main_queue(), ^{
            SAFProtected({ SAFConfigureWebView(wv); });
        });
    }
    return ret;
}

#pragma mark - 构造函数

__attribute__((constructor))
static void SafeAreaFixInit(void) {
    NSUInteger installed = 0;

    Class VC = [UIViewController class];
    if (SAFHook(VC, @selector(viewDidLoad), (IMP)SAF_hook_viewDidLoad, &g_origViewDidLoad)) installed++;
    if (SAFHook(VC, @selector(viewWillAppear:), (IMP)SAF_hook_viewWillAppear, &g_origViewWillAppear)) installed++;

    /* WKWebView 用 NSClassFromString 取，避免强制链接 WebKit.framework。
       这里先试一次；若 WebKit 还没被 dyld 加载，SAFEnsureWebViewHook
       会在后续每次 VC 出现时补装。 */
    SAFEnsureWebViewHook();

    SAFLog(@"✅ loading (%lu hooks installed) — 指尖浏览器安全区适配已启用 (v2 加固版)",
           (unsigned long)installed);
}
