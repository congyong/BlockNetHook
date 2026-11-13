# BlockNetPlus

基于 [congyong/BlockNetHook](https://github.com/congyong/BlockNetHook) 扩展的可配置网络拦截 dylib。
原仓库用纯 ObjC runtime hook 拒掉 `umeng.com` / `umengcloud.com` 请求，
解决「指尖浏览器」（鲨鱼浏览器，开发者 Finger Joint）启动时因友盟响应异常导致的闪退。

本插件**完整保留原项目的 HookMethod 架构与默认行为**，并扩展成一套分层拦截框架。

## 做了什么

| 层 | 覆盖 |
| --- | --- |
| 规则引擎 | 三档域名表（loose / standard / strict）、硬编码白名单、可选路径关键词、运行时配置追加规则 |
| ObjC 网络层 | `NSURLSession` 12 个 task 工厂、`NSURLConnection` 5 个、`NSData` 2 个、`NSURLProtocol` 兜底、`WKWebView`（Strict） |
| 配置修复 | 把 `BNPBlockProtocol` 注入 `NSURLSessionConfiguration.protocolClasses` —— `registerClass:` 对自定义 session 不生效，这是原项目的盲点 |
| C 层兜底 | fishhook rebind `getaddrinfo`，覆盖绕开 NSURLSession 直接用 socket / CFNetwork 的广告 SDK |
| 本机服务 | hook `GCDWebServer` 的 `start` / `startWithOptions:error:` / `startWithPort:bonjourName:` 返回 `NO`，禁用 GCDWebUploader 的 WiFi 传文件服务 |

默认档 `standard` 拦截友盟、穿山甲/ABU、百度 Mobads、广点通、乐播广告、极光统计共 6 类 20 条后缀规则；`strict` 追加 13 条后共 33 条。
规则来源是对 `meiyu_browser_9.3.ipa` 主二进制的静态提取，详见 `规则清单.md`。

**边界**：白名单硬编码且优先于一切拦截规则，支付、订阅校验、账号登录和应用核心 API 一律放行；
`BNP_EXTRA_HOSTS` 也无法越过白名单。插件不干预应用内购买逻辑。

## 目录

```
BlockNetPlus/
├── BlockNetPlus.m                  插件源码（唯一需要编译的 ObjC 文件）
├── Makefile                        macOS 本地编译
├── .github/workflows/build.yml     GitHub Actions 自动编译 + 发布 Release
├── .gitignore                      排除编译产物与运行时下载的 fishhook
├── 规则清单.md                     分档规则、白名单、配置开关、扩展点
└── README.md                       本文件
```

`fishhook.c` / `fishhook.h` 由 Makefile 与 CI 在编译时从 `facebook/fishhook` 自动下载，不入库。

## 编译

**Windows / Linux 无法编译** —— 需要 macOS + Xcode 的 iPhoneOS SDK（`xcrun`、`clang -arch arm64e`、`lipo`）。
仓库只维护源码与构建配置，产物 dylib 由 CI 在 Release 中发布。

**方式 A：GitHub Actions（推荐，零本地环境）**

本插件托管在 [congyong/BlockNetHook](https://github.com/congyong/BlockNetHook) 的
**`blocknetplus` 分支**；原项目的 `main`（`BlockNet.m` 及其 CI）保持不变，两套构建互不干扰。

1. 向 `blocknetplus` 分支 push 即自动触发 `Build BlockNetPlus dylib`。
2. 也可在 Actions 里用 `workflow_dispatch` 手动触发。
3. 产物在自动创建的 Release 里：`BlockNetPlus.dylib`（arm64 + arm64e fat）。

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

沿用原仓库的方式（LiveContainer，无需重签）：

1. LiveContainer → **Tweaks** → `+` → **Import Tweak** → 选 `BlockNetPlus.dylib`。
2. 放到全局 Tweak 目录，或只放进鲨鱼浏览器的应用目录。
3. 在 App 设置里设置 **Tweak Folder**，重新启动生效。

若要注入到已砸壳的 IPA，需要在注入后自行完成重签名；本仓库不提供签名、侧载与分发流程。

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
