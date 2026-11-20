# BlockNetPlus

基于 [congyong/BlockNetHook](https://github.com/congyong/BlockNetHook) 扩展的可配置网络拦截 dylib，
并附带一套 **刘海屏 / 灵动岛 / Home Indicator 安全区适配**（`SafeAreaFix.m`）。

原仓库用纯 ObjC runtime hook 拒掉 `umeng.com` / `umengcloud.com` 请求，
解决「指尖浏览器」（鲨鱼浏览器，开发者 Finger Joint）启动时因友盟响应异常导致的闪退。

本插件**完整保留原项目的 HookMethod 架构与默认行为**，并扩展成一套分层拦截框架，
同时补上指尖浏览器Pro 1.9 完全缺失的安全区适配。

## 两个产物

| 文件 | 内容 | 适用场景 |
| --- | --- | --- |
| `BlockNetPlus.dylib` | 广告拦截 **+** 安全区适配 | 想两者都要 |
| `SafeAreaFix.dylib` | **仅**安全区适配 | 只想修刘海屏布局，完全不碰网络层 |

两个都是 fat dylib（arm64 + arm64e），可以只装一个，也可以同时加载。

## 做了什么

| 层 | 覆盖 |
| --- | --- |
| 规则引擎 | 三档域名表（loose / standard / strict）、硬编码白名单、可选路径关键词、运行时配置追加规则 |
| ObjC 网络层 | `NSURLSession` 12 个 task 工厂、`NSURLConnection` 5 个、`NSData` 2 个、`NSURLProtocol` 兜底、`WKWebView`（Strict） |
| 配置修复 | 把 `BNPBlockProtocol` 注入 `NSURLSessionConfiguration.protocolClasses` —— `registerClass:` 对自定义 session 不生效，这是原项目的盲点 |
| C 层兜底 | fishhook rebind `getaddrinfo`，覆盖绕开 NSURLSession 直接用 socket / CFNetwork 的广告 SDK |
| 本机服务 | hook `GCDWebServer` 的 `start` / `startWithOptions:error:` / `startWithPort:bonjourName:` 返回 `NO`，禁用 GCDWebUploader 的 WiFi 传文件服务 |
| 安全区适配 | `UIViewController.viewDidLoad` / `viewWillAppear:` / `viewDidLayoutSubviews` 收缩 `edgesForExtendedLayout`；`WKWebView` 强制 `contentInsetAdjustmentBehavior = .always` |

默认档 `standard` 拦截友盟、穿山甲/ABU、百度 Mobads、广点通、乐播广告、极光统计共 6 类 20 条后缀规则；`strict` 追加 13 条后共 33 条。
规则来源是对 `meiyu_browser_9.3.ipa` 主二进制的静态提取，详见 `规则清单.md`。

**边界**：白名单硬编码且优先于一切拦截规则，支付、订阅校验、账号登录和应用核心 API 一律放行；
`BNP_EXTRA_HOSTS` 也无法越过白名单。插件不干预应用内购买逻辑。

## 目录

```
BlockNetPlus/
├── BlockNetPlus.m                  插件源码（网络拦截部分）
├── SafeAreaFix.m                   插件源码（安全区适配部分）
├── Makefile                        macOS 本地编译
├── .github/workflows/build.yml     GitHub Actions 自动编译 + 发布 Release
├── .gitignore                      排除编译产物与运行时下载的 fishhook
├── 规则清单.md                     分档规则、白名单、配置开关、扩展点
└── README.md                       本文件
```

`fishhook.c` / `fishhook.h` 由 Makefile 与 CI 在编译时从 `facebook/fishhook` 自动下载，不入库。

## 安全区适配（`SafeAreaFix.m`）

### 问题

指尖浏览器Pro 1.9 建于 2018 年（iOS 11.1 SDK），对其主二进制逐项实测：

| API | 引用次数 |
| --- | --- |
| `safeAreaInsets` | **0** |
| `safeAreaLayoutGuide` | **0** |
| `viewSafeAreaInsetsDidChange` | **0** |
| `topLayoutGuide` / `bottomLayoutGuide` | **0** |
| `contentInsetAdjustmentBehavior` | **0** |
| `edgesForExtendedLayout` | 2（只用了 iOS 7 的老 API） |
| `UIScreen` / `bounds` | 4 / 84（布局全部基于屏幕物理尺寸） |

配套证据：`Info.plist` 的 `UILaunchImages` 只覆盖到 iPhone X（375×812pt），
390×844 / 393×852 / 414×896 / 430×932 / 440×956 全部缺失。

结论：这个 App 出生在安全区概念普及之前，布局一律按 `UIScreen.main.bounds` 硬算，
从不读安全区。iOS 13+ 把这类旧 App 铺满全屏后 —— 顶栏压进刘海/灵动岛、
底栏压进 Home Indicator，**上下两端的按钮点不到**。

### 修法

只做「系统本该替它做」的补正，不改业务逻辑：

1. **收缩 `edgesForExtendedLayout`**
   hook `UIViewController.viewDidLoad` / `viewWillAppear:` / `viewDidLayoutSubviews`，
   在原实现之后把 `edgesForExtendedLayout` 的 Top/Bottom 位剥离。
   UIKit 随即把 `VC.view` 收缩进安全区；因为 App 内部元素是**相对 view** 布局的
   （view 尺寸变了但相对坐标不变），顶栏自动下移到刘海下方、底栏自动上移到
   Home Indicator 上方 —— 一次设置，全页生效。

2. **`WKWebView` 的 inset**
   WKWebView 默认 `contentInsetAdjustmentBehavior = .automatic`，而 `.automatic`
   在 WKWebView 内不会真正加 inset，网页内容会被 Home Indicator 盖住（WebKit 的经典坑）。
   hook `WKWebView` 的 `initWithFrame:` / `initWithCoder:`，强制设为 `.always`。

### 安全阀

- **只在 `window.safeAreaInsets` 非零的设备上动作。**
  iPhone SE / 8 这类无刘海机型如果也设 `edgesForExtendedLayout = None`，
  view 会从 status bar 下方开始，App 写死的顶部坐标反而被遮挡 —— 必须避免。
- `UINavigationController` / `UITabBarController` / `UISplitViewController` /
  `UIPageViewController` 自身跳过，它们内部已由 UIKit 处理。
- view 尚未上屏（`view.window == nil`）时推迟到下一轮 runloop 重试。
- **不链接 `WebKit.framework`**：`WKWebView` 走 `NSClassFromString` + `objc_msgSend`，
  不为一个可选功能引入额外框架依赖。
- **不依赖 CydiaSubstrate / ElleKit**：hook 用 objc runtime 的 `method_setImplementation`
  实现，与 `BlockNetPlus.m` 同一套思路，LiveContainer 外置 dylib 即可生效，无需越狱。

### 配置

| Key | 默认 | 说明 |
| --- | --- | --- |
| `SAF_LOG` | `1` | 设 `0` 静默 |
| `SAF_MODE` | `auto` | `auto`（仅刘海设备生效）/ `off`（完全关闭）/ `force`（无视设备检查） |
| `SAF_NAV` | `auto` | `auto` / `nav`（一律收缩含导航栏容器的 VC）/ `bare`（一律只处理裸 VC） |
| `SAF_WEBVIEW` | `1` | 设 `0` 关闭 WKWebView inset 修正 |

### 验证

设备日志搜索 `[SafeAreaFix]`：

```
[SafeAreaFix] ✅ loading (5 hooks installed) — 指尖浏览器安全区适配已启用
[SafeAreaFix] ✅ ZJBrowserNavigationController edges 15→0 (safeArea top=59 bottom=34) [applied=1]
[SafeAreaFix] ℹ️ WKWebView contentInsetAdjustmentBehavior → always
```

`edges 15→0` 表示 `UIRectEdgeAll` 被收成 `UIRectEdgeNone`，`safeArea top=59` 是刘海机型的典型值。
如果看到 `edges 15→3`（只剥离 Top/Bottom、保留左右）也是正常的 —— 左右位在竖屏下无意义，
由 UIKit 按当前方向自行处理。

若某个页面仍然偏紧，用 `SAF_NAV=bare` 或 `SAF_NAV=nav` 调整适用范围后重试。

## 编译

**Windows / Linux 无法编译** —— 需要 macOS + Xcode 的 iPhoneOS SDK（`xcrun`、`clang -arch arm64e`、`lipo`）。
仓库只维护源码与构建配置，产物 dylib 由 CI 在 Release 中发布。

**方式 A：GitHub Actions（推荐，零本地环境）**

本插件托管在 [congyong/BlockNetHook](https://github.com/congyong/BlockNetHook) 的
**`blocknetplus` 分支**；原项目的 `main`（`BlockNet.m` 及其 CI）保持不变，两套构建互不干扰。

1. 向 `blocknetplus` 分支 push 即自动触发 `Build BlockNetPlus dylib`。
2. 也可在 Actions 里用 `workflow_dispatch` 手动触发。
3. 产物在自动创建的 Release 里：`BlockNetPlus.dylib`（一体版）与 `SafeAreaFix.dylib`（独立安全区版），
   都是 arm64 + arm64e fat。

**方式 B：macOS 本地**

```bash
cd BlockNetPlus
make            # 自动下载 fishhook，编译 arm64/arm64e，合并并验证
make clean      # 清理产物
```

编译参数沿用原仓库：`clang -dynamiclib ... -isysroot $(xcrun --sdk iphoneos --show-sdk-path)
-arch arm64[e] -miphoneos-version-min=13.0 -framework Foundation -fobjc-arc`。
若不想依赖 fishhook，可在编译时加 `-DBNP_USE_FISHHOOK=0`，ObjC 层拦截仍然完整。

## 注入与验证

LiveContainer 的流程：

1. LiveContainer → **Tweaks** → `+` → **Import Tweak** → 选 `BlockNetPlus.dylib`
   （只想修安全区就选 `SafeAreaFix.dylib`）。**必须走这个入口**。
2. 放到全局 Tweak 目录，或只放进鲨鱼浏览器的应用目录（Tweaks → New Folder）。
3. 在 App 设置里设置 **Tweak Folder**，重新启动生效。

⚠️ **别用文件 App 直接往 `Documents/Tweaks/` 里拷文件。** 那样文件不会被登记，
LiveContainer 启动前也就不会给它重签，`dlopen` 会报
`code signature invalid ... (errno=1)`。已经拷进去了的话：Tweaks 标签页里长按该文件
→ **Sign** 手动签一次（老版本是右上角签名按钮），再启动 App。

### 为什么 ad-hoc 签名还不够

本仓库的 CI 已经做了 ad-hoc 签名（`codesign --force --sign -`，每个切片都验过），
那只满足"至少 ad-hoc"这一层。容器里的进程还要求被 `dlopen` 的镜像与主程序属于
**同一签名身份**，ad-hoc 没有证书/team，所以内核照样以 `errno=1` 拒绝。
LiveContainer 的做法就是启动前用自己的证书把 tweak 重签一遍（TweakInfo.plist 记账），
这也是官方文档说 "Tweaks must be signed before they can be loaded" 的含义 ——
这里说的签名是**它签**，不是作者签。判定设备上的文件有没有被重签：看日志里的
`codeBlobOffset` / `codeBlobSize`，和 release 里原始文件一致就说明没重签。

排错顺序：Sign 之后仍失败 → 看 LiveContainer 的签名证书/描述文件是否过期（免费证书 7 天），
重新侧载后再试 → 确认目标 App 是 private（shared App 的 Tweak Folder 只读）
→ 确认 TweakLoader 没在 App 设置里被禁用。

若要注入到已砸壳的 IPA，需要在注入后自行完成重签名；本仓库不提供签名、侧载与分发流程。

**签名**：Release 里的 dylib 已由 CI 做 ad-hoc 签名（`codesign --force --sign -`，
每个切片都校验过）。iOS 15+ / arm64e 上未签名的 dylib 会被 AMFI 直接拒绝加载，
而 LiveContainer / TrollStore 只会静默失败、不报原因——所以这一步不能省。
本机自证：`codesign -dv BlockNetPlus.dylib` 打印 `Signature=adhoc`；
`codesign --verify --verbose=2 BlockNetPlus.dylib` 无输出即通过。
自己本地编译时 `make` 已含 `sign` 目标；**对产物做过 strip / 注入 / 改数据后必须重新签名**，
否则页哈希失效，加载同样失败。

**验证**：设备日志搜索 `[BlockNet+]`，应看到：

```
[BlockNet+] ✅ loading (level=1, block rules=20, allow rules=13)
[BlockNet+] 🔧 getaddrinfo rebind OK
[BlockNet+] ✅ 25 hooks installed; ready
[BlockNet+] ❌ BLOCKED errlog.umeng.com
```

`25` 是全部类都存在时的 hook 数（2 + 12 + 5 + 2 + 1 + 3）；
若 App 未加载 `WKWebView` / `GCDWebServer` 类，数字会相应减少，属正常。

同一 host 只打印一条 BLOCKED，避免 NSURLProtocol 反复查询刷屏。
若 App 抓包仍看到广告请求，先确认 dylib 是否被加载（有没有 `✅ loading`）。

## 配置

配置读取优先级：环境变量 > App 的 `NSUserDefaults`；iOS 上后者更可靠。

| Key | 默认 | 说明 |
| --- | --- | --- |
| `BNP_LEVEL` | `standard` | `loose`（仅友盟，对照排障）/ `standard` / `strict`（含推送、投屏、搜索建议） |
| `BNP_EXTRA_HOSTS` | 空 | 逗号分隔追加拦截域名，支持后缀。**扩大拦截首选这个** |
| `BNP_ALLOW_HOSTS` | 空 | 逗号分隔追加放行域名 |
| `BNP_BLOCK_PATH_KEYWORDS` | `0` | 设 `1` 后拦截含 `/adreport`、`/beacon`、`/track` 等路径的请求 |
| `BNP_DISABLE_LOCAL_SERVER` | `1` | 设 `0` 保留 WiFi 传文件服务 |
| `BNP_LOG` | `1` | 设 `0` 静默 |

例：`BNP_EXTRA_HOSTS=ad.example.com,.tracker.io BNP_LEVEL=strict`（规则支持前导点，匹配时会自动 trim）。

## 继续扩大拦截

按侵入性从低到高：

1. 改配置：`BNP_LEVEL=strict`、`BNP_EXTRA_HOSTS`、`BNP_BLOCK_PATH_KEYWORDS=1`。
2. 改规则表：编辑 `BlockNetPlus.m` 的 `BNPCoreRules()` / `BNPStrictRules()`。
3. 加 hook 点：constructor 里的 `sessionHooks[]` 数组与 `BNPHook(...)` 调用就是扩展位，
   可继续覆盖 `NSURLSessionStreamTask`、`CFReadStream` 等。
4. C 层：`getaddrinfo` 已能拦住绝大多数原生请求；若 SDK 直连硬编码 IP，
   DNS 层无效，需要 hook `connect` / SSL 握手层，或改在路由器 / DNS 侧阻断
   （分析 IPA 时整理过一份域名清单，已按「可阻断 / 勿封」分类，可直接转成 DNS 阻断规则）。

## 已知限制与排障

- **Strict 会禁用推送和投屏**：`jpush.cn`、`hpplay.cn` 整域被拦是刻意设计，按需用 `BNP_ALLOW_HOSTS` 放行。
- **返回 `NSURLErrorNotConnectedToInternet`** 是沿用原项目行为，对「友盟响应异常导致闪退」最安全；
  个别 SDK 若反复重试，可把 `BNPBlockedError()` 的 code 换成 `NSURLErrorCancelled`。
- **arm64e** slice 只适用于 A12+ 设备；fat dylib 已同时包含 arm64。
- **找不到 GCDWebServer 类** 时会打印 `ℹ️ ... skipped` 并继续，不影响其他 hook。
- **拦截不生效**：先切 `BNP_LEVEL=loose` 确认 dylib 已加载，再逐档放宽；
  若只有某个 SDK 漏网，多半是它绕开 NSURLSession 走了 C 层，检查 `getaddrinfo rebind OK` 是否出现。
- **原仓库未声明 LICENSE**，分发前请自行确认授权；本插件仅供个人本地研究与隐私加固。

## 与前面分析的关系

- 广告 SDK（穿山甲 / 百度 / 广点通 / 友盟）和 GCDWebUploader 都是**官方原包自带**，
  静态链接在 66 MB 主二进制里，删 `.bundle` 资源不等于移除代码。
- 这个插件走的是「运行时禁用」路径：不改动 IPA 内容，不破坏签名，随时可撤销，
  也是三条路径里唯一不需要重新打包就能同时覆盖多个广告源的方案。
- 若目标是拿到干净可信的包，仍建议直接安装 App Store 官方版本，而不是给砸壳重签包打补丁。
