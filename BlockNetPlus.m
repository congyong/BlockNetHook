/**
 * BlockNetPlus.m  ->  BlockNetPlus.dylib
 *
 * 基于 https://github.com/congyong/BlockNetHook (BlockNet.m) 扩展。
 * 原项目：用纯 ObjC runtime hook 拒掉 umeng.com / umengcloud.com 请求，
 *         修复「指尖浏览器」启动时因友盟响应异常导致的闪退。
 *
 * 本插件保留原项目的 HookMethod / NSURLSession / NSURLConnection / NSURLProtocol
 * 架构与默认行为，并扩展为可配置的分层网络拦截：
 *   1. 规则引擎：分档域名表 + 硬编码白名单 + 路径关键词 + 运行时配置
 *   2. ObjC 层：NSURLSession(12 个 task 工厂) / NSURLConnection(5) / NSData(2)
 *               / WKWebView / NSURLProtocol 兜底
 *   3. 修复原项目盲点：把 NSURLProtocol 注入 NSURLSessionConfiguration.protocolClasses
 *      （registerClass: 对自定义 NSURLSession 不生效）
 *   4. C 层兜底：fishhook rebind getaddrinfo，覆盖绕开 NSURLSession 的原生 socket 请求
 *   5. 本机服务：禁用 GCDWebServer 启动（对应包内 GCDWebUploader 的 WiFi 传文件服务）
 *
 * 边界：白名单硬编码且优先于任何拦截规则，支付 / 订阅校验 / 账号登录 / 应用核心
 *       API 一律放行。本插件只做广告与追踪请求拦截，不干预应用内购买逻辑。
 *
 * 原仓库未声明 LICENSE，请自行确认再分发；本文件仅供个人本地研究与隐私加固使用。
 *
 * 编译：见同目录 Makefile / .github/workflows/build.yml（需 macOS + Xcode iOS SDK）
 */

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>
#include <netdb.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#ifndef BNP_USE_FISHHOOK
#define BNP_USE_FISHHOOK 1
#endif
#if BNP_USE_FISHHOOK
#include "fishhook.h"
#endif

#pragma mark - 日志

static BOOL BNPLoggingEnabled(void) {
    static BOOL enabled = YES;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *v = getenv("BNP_LOG");
        if (v && (!strcmp(v, "0") || !strcasecmp(v, "off"))) enabled = NO;
        else {
            NSString *s = [[NSUserDefaults standardUserDefaults] stringForKey:@"BNP_LOG"];
            if ([s isEqualToString:@"0"] || [s.lowercaseString isEqualToString:@"off"]) enabled = NO;
        }
    });
    return enabled;
}

#define BNPLog(fmt, ...) do { \
    if (BNPLoggingEnabled()) NSLog((@"[BlockNet+] " fmt), ##__VA_ARGS__); \
} while (0)

/* 同一 host 只记一条日志，避免 NSURLProtocol 反复查询造成刷屏 */
static void BNPNoteBlockedHost(NSString *host) {
    if (!BNPLoggingEnabled()) return;
    static NSMutableSet *seen = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ seen = [NSMutableSet set]; });
    NSString *h = host.lowercaseString ?: @"(unknown)";
    @synchronized (seen) {
        if ([seen containsObject:h]) return;
        [seen addObject:h];
    }
    BNPLog(@"❌ BLOCKED %@", h);
}

#pragma mark - Hook helper（沿用 BlockNetHook 的 HookMethod，补充 nil 保护）

static BOOL BNPHook(Class cls, SEL sel, IMP newImp, IMP *oldImp) {
    if (!cls || !sel || !newImp) return NO;
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) {
        method = class_getClassMethod(cls, sel);
        if (!method) {
            BNPLog(@"⚠️ method not found: %@ %@", cls, NSStringFromSelector(sel));
            return NO;
        }
        cls = object_getClass(cls);                 // 类方法要操作 metaclass
        method = class_getInstanceMethod(cls, sel);
    }
    if (!method) return NO;
    IMP orig = method_setImplementation(method, newImp);
    if (oldImp) *oldImp = orig;
    return orig != NULL;
}

#pragma mark - 运行时配置

/* 配置优先级：环境变量 > App 的 NSUserDefaults。
   iOS 上环境变量通常不可设，NSUserDefaults 是更可靠的入口。 */
static NSString *BNPConfigValue(NSString *key) {
    const char *raw = getenv(key.UTF8String);
    if (raw && raw[0]) {
        NSString *v = [NSString stringWithUTF8String:raw];
        if (v.length) return v;
    }
    return [[NSUserDefaults standardUserDefaults] stringForKey:key];
}

static NSArray<NSString *> *BNPSplitList(NSString *s) {
    if (!s.length) return @[];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *part in [s componentsSeparatedByString:@","]) {
        NSString *t = [part stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (t.length) [out addObject:t.lowercaseString];
    }
    return out;
}

typedef NS_ENUM(NSInteger, BNPLevel) {
    BNPLevelLoose    = 0,   /* 仅原项目行为：umeng.com / umengcloud.com */
    BNPLevelStandard = 1,   /* 默认：全部广告 + 统计上报域名 */
    BNPLevelStrict   = 2,   /* 追加：推送 / 投屏 / 搜索建议等，可能影响功能 */
};

static BNPLevel BNPActiveLevel(void) {
    static BNPLevel level = BNPLevelStandard;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *v = BNPConfigValue(@"BNP_LEVEL");
        NSString *l = v.lowercaseString;
        if ([l isEqualToString:@"loose"] || [l isEqualToString:@"0"]) level = BNPLevelLoose;
        else if ([l isEqualToString:@"strict"] || [l isEqualToString:@"2"]) level = BNPLevelStrict;
    });
    return level;
}

static BOOL BNPBoolConfig(NSString *key, BOOL defaultValue) {
    static NSMutableDictionary *cache = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    @synchronized (cache) {
        id cached = cache[key];
        if (cached) return [cached boolValue];
        NSString *v = BNPConfigValue(key);
        BOOL result = defaultValue;
        if (v.length) {
            result = !([v isEqualToString:@"0"] || [v.lowercaseString isEqualToString:@"off"] ||
                       [v.lowercaseString isEqualToString:@"no"]);
        }
        cache[key] = @(result);
        return result;
    }
}

#pragma mark - 规则表

/* Loose：完整保留原 BlockNetHook 的行为，用于对照排障 */
static NSArray<NSString *> *BNPLegacyRules(void) {
    return @[@"umeng.com", @"umengcloud.com"];
}

/* Standard：从鲨鱼浏览器 9.3 主二进制静态提取的广告 / 追踪域名 */
static NSArray<NSString *> *BNPCoreRules(void) {
    return @[
        /* 友盟（原项目目标，修复启动闪退） */
        @"umeng.com", @"umengcloud.com", @"umsns.com",
        /* 穿山甲 / Pangle / ABU 聚合上报 */
        @"mon.snssdk.com", @"mon.toutiao.com", @"monsetting.toutiao.com",
        /* 百度广告 Mobads */
        @"mobads.baidu.com", @"mobads-logs.baidu.com", @"cpro.baidustatic.com",
        @"mobads-pre-config.bj.bcebos.com", @"mobads-pre-config.cdn.bcebos.com",
        @"render-server.cdn.bcebos.com",
        /* 广点通 / 优量汇 */
        @"gdt.qq.com", @"gdtimg.com", @"sdk.e.qq.com", @"union.eff.qq.com",
        /* 乐播投屏广告与日志 */
        @"ad.hpplay.cn", @"adeng.hpplay.cn", @"logu.hpplay.cn",
        /* 极光统计 */
        @"stats.jpush.cn",
    ];
}

/* Strict：范围更宽，会连带影响推送、投屏、搜索建议等功能 */
static NSArray<NSString *> *BNPStrictRules(void) {
    return @[
        @"so.toutiao.com", @"cpu-openapi.baidu.com",
        @"hpplay.cn", @"h5.hpplay.com.cn",                 /* 整个投屏域 */
        @"jpush.cn",                                        /* 整个推送域 */
        @"api.sugg.sogou.com", @"wap.sogou.com",
        @"sugs.m.sm.cn", @"yz.m.sm.cn",
        @"developer.umeng.com", @"config.umeng.com",
        @"pangle.io", @"pangolin-sdk-toutiao.com",
    ];
}

/* 白名单：支付 / 订阅 / 登录 / 应用核心 API / 本机回环。
   优先级高于一切拦截规则，且不会被 BNP_EXTRA_HOSTS 覆盖。 */
static NSArray<NSString *> *BNPAllowRules(void) {
    static NSArray *rules = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray *m = [@[
            @"buy.itunes.apple.com", @"sandbox.itunes.apple.com",   /* IAP 收据校验 */
            @"itunes.apple.com", @"apps.apple.com",
            @"api.weixin.qq.com", @"openmobile.qq.com",              /* 微信 / QQ 登录分享 */
            @"live.zhongjiangapp.com", @"api.zhongjiangapp.com",     /* 会员购买与应用 API */
            @"weather.zhongjiangapp.com", @"m.zhongjiangapp.com",
            @"localhost", @"127.0.0.1", @"local",
        ] mutableCopy];
        [m addObjectsFromArray:BNPSplitList(BNPConfigValue(@"BNP_ALLOW_HOSTS"))];
        rules = m.copy;
    });
    return rules;
}

/* 最终拦截规则 = 分档表 + 用户追加的 BNP_EXTRA_HOSTS */
static NSArray<NSString *> *BNPBlockRules(void) {
    static NSArray *rules = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        BNPLevel lv = BNPActiveLevel();
        NSMutableArray *m = [NSMutableArray array];
        if (lv == BNPLevelLoose) [m addObjectsFromArray:BNPLegacyRules()];
        else {
            [m addObjectsFromArray:BNPCoreRules()];
            if (lv == BNPLevelStrict) [m addObjectsFromArray:BNPStrictRules()];
        }
        [m addObjectsFromArray:BNPSplitList(BNPConfigValue(@"BNP_EXTRA_HOSTS"))];
        rules = [[NSOrderedSet orderedSetWithArray:m] array];
    });
    return rules;
}

/* 后缀匹配：rule = "umeng.com" 可命中 errlog.umeng.com */
static BOOL BNPMatchHost(NSString *host, NSArray<NSString *> *rules) {
    NSString *h = host.lowercaseString;
    if (!h.length) return NO;
    h = [h stringByTrimmingCharactersInSet:
         [NSCharacterSet characterSetWithCharactersInString:@".[]"]];
    NSRange colon = [h rangeOfString:@":"];
    if (colon.location != NSNotFound) h = [h substringToIndex:colon.location];
    if (!h.length) return NO;
    for (NSString *raw in rules) {
        /* 规则也做 trim，允许 BNP_EXTRA_HOSTS 写成 ".tracker.io" 这类形式 */
        NSString *r = [raw.lowercaseString stringByTrimmingCharactersInSet:
                       [NSCharacterSet characterSetWithCharactersInString:@".[]"]];
        if (!r.length) continue;
        if ([h isEqualToString:r] || [h hasSuffix:[@"." stringByAppendingString:r]]) return YES;
    }
    return NO;
}

static BOOL BNPPathBlocked(NSURL *url) {
    static BOOL enabled = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *v = BNPConfigValue(@"BNP_BLOCK_PATH_KEYWORDS");
        enabled = ([v isEqualToString:@"1"] || [v.lowercaseString isEqualToString:@"on"]);
    });
    if (!enabled) return NO;
    NSString *p = url.path.lowercaseString ?: @"";
    for (NSString *k in @[@"/adreport", @"/ad_log", @"/logcollect", @"/sdklog",
                          @"/beacon", @"/track", @"/analytics", @"/unionlog"]) {
        if ([p containsString:k]) return YES;
    }
    return NO;
}

static BOOL BNPShouldBlockURL(NSURL *url) {
    if (!url) return NO;
    NSString *h = url.host;
    if (!h.length) return NO;
    if (BNPMatchHost(h, BNPAllowRules())) return NO;      /* 白名单优先 */
    if (BNPMatchHost(h, BNPBlockRules())) { BNPNoteBlockedHost(h); return YES; }
    if (BNPPathBlocked(url)) { BNPNoteBlockedHost(h); return YES; }
    return NO;
}

static BOOL BNPShouldBlockHostC(const char *node) {
    if (!node || !*node) return NO;
    NSString *h = [NSString stringWithUTF8String:node];
    if (!h.length) return NO;
    if (BNPMatchHost(h, BNPAllowRules())) return NO;
    return BNPMatchHost(h, BNPBlockRules());
}

#pragma mark - 被拦截时的返回对象

static NSError *BNPBlockedError(NSURL *url) {
    return [NSError errorWithDomain:NSURLErrorDomain
                              code:NSURLErrorNotConnectedToInternet
                          userInfo:@{
        NSURLErrorFailingURLErrorKey: url ?: [NSURL URLWithString:@"about:blocked"],
        NSLocalizedDescriptionKey: @"Blocked by BlockNetPlus.",
    }];
}

/* NSURLSession 各类 completionHandler 的首参类型不同（NSData / NSURL），
   但都是对象指针，用 id 统一调用即可，nil 对二者都安全。 */
static void BNPCallCompletion(id handler, NSURL *url) {
    if (!handler) return;
    void (^blk)(id, id, NSError *) = handler;
    NSError *e = BNPBlockedError(url);
    dispatch_async(dispatch_get_main_queue(), ^{ blk(nil, nil, e); });
}

#pragma mark - NSURLProtocol 兜底

@interface BNPBlockProtocol : NSURLProtocol
@end
@implementation BNPBlockProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request { return BNPShouldBlockURL(request.URL); }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)startLoading {
    [self.client URLProtocol:self didFailWithError:BNPBlockedError(self.request.URL)];
}
- (void)stopLoading {}
@end

/* registerClass: 只影响 NSURLConnection / sharedSession；
   自定义 configuration 的 session 必须显式注入 protocolClasses。 */
static void BNPInjectProtocol(NSURLSessionConfiguration *cfg) {
    if (!cfg) return;
    NSMutableArray *protocols = [NSMutableArray arrayWithObject:[BNPBlockProtocol class]];
    for (Class c in (cfg.protocolClasses ?: @[])) {
        if (c != [BNPBlockProtocol class]) [protocols addObject:c];
    }
    cfg.protocolClasses = protocols;
}

static IMP orig_defaultSessionConfiguration;
static id hook_defaultSessionConfiguration(id cls, SEL _cmd) {
    NSURLSessionConfiguration *cfg =
        ((id (*)(id, SEL))orig_defaultSessionConfiguration)(cls, _cmd);
    BNPInjectProtocol(cfg);
    return cfg;
}

static IMP orig_ephemeralSessionConfiguration;
static id hook_ephemeralSessionConfiguration(id cls, SEL _cmd) {
    NSURLSessionConfiguration *cfg =
        ((id (*)(id, SEL))orig_ephemeralSessionConfiguration)(cls, _cmd);
    BNPInjectProtocol(cfg);
    return cfg;
}

#pragma mark - NSURLSession hooks

/* 无 completionHandler 的 task 工厂：创建后立即 cancel */
static IMP orig_dataTaskWithRequest;
static id hook_dataTaskWithRequest(NSURLSession *self, SEL _cmd, NSURLRequest *req) {
    id t = ((id (*)(id, SEL, NSURLRequest *))orig_dataTaskWithRequest)(self, _cmd, req);
    if (BNPShouldBlockURL(req.URL)) [t cancel];
    return t;
}

static IMP orig_dataTaskWithURL;
static id hook_dataTaskWithURL(NSURLSession *self, SEL _cmd, NSURL *url) {
    id t = ((id (*)(id, SEL, NSURL *))orig_dataTaskWithURL)(self, _cmd, url);
    if (BNPShouldBlockURL(url)) [t cancel];
    return t;
}

static IMP orig_downloadTaskWithRequest;
static id hook_downloadTaskWithRequest(NSURLSession *self, SEL _cmd, NSURLRequest *req) {
    id t = ((id (*)(id, SEL, NSURLRequest *))orig_downloadTaskWithRequest)(self, _cmd, req);
    if (BNPShouldBlockURL(req.URL)) [t cancel];
    return t;
}

static IMP orig_downloadTaskWithURL;
static id hook_downloadTaskWithURL(NSURLSession *self, SEL _cmd, NSURL *url) {
    id t = ((id (*)(id, SEL, NSURL *))orig_downloadTaskWithURL)(self, _cmd, url);
    if (BNPShouldBlockURL(url)) [t cancel];
    return t;
}

static IMP orig_uploadTaskWithRequestFromData;
static id hook_uploadTaskWithRequestFromData(NSURLSession *self, SEL _cmd,
                                             NSURLRequest *req, NSData *body) {
    id t = ((id (*)(id, SEL, NSURLRequest *, NSData *))
            orig_uploadTaskWithRequestFromData)(self, _cmd, req, body);
    if (BNPShouldBlockURL(req.URL)) [t cancel];
    return t;
}

static IMP orig_uploadTaskWithRequestFromFile;
static id hook_uploadTaskWithRequestFromFile(NSURLSession *self, SEL _cmd,
                                             NSURLRequest *req, NSURL *fileURL) {
    id t = ((id (*)(id, SEL, NSURLRequest *, NSURL *))
            orig_uploadTaskWithRequestFromFile)(self, _cmd, req, fileURL);
    if (BNPShouldBlockURL(req.URL)) [t cancel];
    return t;
}

/* 带 completionHandler 的 task 工厂：不发起真实请求，异步回错误 */
static IMP orig_dataTaskWithRequestCompletion;
static id hook_dataTaskWithRequestCompletion(NSURLSession *self, SEL _cmd,
                                             NSURLRequest *req, id handler) {
    if (BNPShouldBlockURL(req.URL)) {
        id t = ((id (*)(id, SEL, NSURLRequest *, id))
                orig_dataTaskWithRequestCompletion)(self, _cmd, req, nil);
        [t cancel];
        BNPCallCompletion(handler, req.URL);
        return t;
    }
    return ((id (*)(id, SEL, NSURLRequest *, id))
            orig_dataTaskWithRequestCompletion)(self, _cmd, req, handler);
}

static IMP orig_dataTaskWithURLCompletion;
static id hook_dataTaskWithURLCompletion(NSURLSession *self, SEL _cmd,
                                         NSURL *url, id handler) {
    if (BNPShouldBlockURL(url)) {
        id t = ((id (*)(id, SEL, NSURL *, id))
                orig_dataTaskWithURLCompletion)(self, _cmd, url, nil);
        [t cancel];
        BNPCallCompletion(handler, url);
        return t;
    }
    return ((id (*)(id, SEL, NSURL *, id))
            orig_dataTaskWithURLCompletion)(self, _cmd, url, handler);
}

static IMP orig_downloadTaskWithRequestCompletion;
static id hook_downloadTaskWithRequestCompletion(NSURLSession *self, SEL _cmd,
                                                 NSURLRequest *req, id handler) {
    if (BNPShouldBlockURL(req.URL)) {
        id t = ((id (*)(id, SEL, NSURLRequest *, id))
                orig_downloadTaskWithRequestCompletion)(self, _cmd, req, nil);
        [t cancel];
        BNPCallCompletion(handler, req.URL);
        return t;
    }
    return ((id (*)(id, SEL, NSURLRequest *, id))
            orig_downloadTaskWithRequestCompletion)(self, _cmd, req, handler);
}

static IMP orig_downloadTaskWithURLCompletion;
static id hook_downloadTaskWithURLCompletion(NSURLSession *self, SEL _cmd,
                                             NSURL *url, id handler) {
    if (BNPShouldBlockURL(url)) {
        id t = ((id (*)(id, SEL, NSURL *, id))
                orig_downloadTaskWithURLCompletion)(self, _cmd, url, nil);
        [t cancel];
        BNPCallCompletion(handler, url);
        return t;
    }
    return ((id (*)(id, SEL, NSURL *, id))
            orig_downloadTaskWithURLCompletion)(self, _cmd, url, handler);
}

static IMP orig_uploadTaskWithRequestFromDataCompletion;
static id hook_uploadTaskWithRequestFromDataCompletion(NSURLSession *self, SEL _cmd,
                                                       NSURLRequest *req, NSData *body,
                                                       id handler) {
    if (BNPShouldBlockURL(req.URL)) {
        id t = ((id (*)(id, SEL, NSURLRequest *, NSData *, id))
                orig_uploadTaskWithRequestFromDataCompletion)(self, _cmd, req, body, nil);
        [t cancel];
        BNPCallCompletion(handler, req.URL);
        return t;
    }
    return ((id (*)(id, SEL, NSURLRequest *, NSData *, id))
            orig_uploadTaskWithRequestFromDataCompletion)(self, _cmd, req, body, handler);
}

static IMP orig_uploadTaskWithRequestFromFileCompletion;
static id hook_uploadTaskWithRequestFromFileCompletion(NSURLSession *self, SEL _cmd,
                                                       NSURLRequest *req, NSURL *fileURL,
                                                       id handler) {
    if (BNPShouldBlockURL(req.URL)) {
        id t = ((id (*)(id, SEL, NSURLRequest *, NSURL *, id))
                orig_uploadTaskWithRequestFromFileCompletion)(self, _cmd, req, fileURL, nil);
        [t cancel];
        BNPCallCompletion(handler, req.URL);
        return t;
    }
    return ((id (*)(id, SEL, NSURLRequest *, NSURL *, id))
            orig_uploadTaskWithRequestFromFileCompletion)(self, _cmd, req, fileURL, handler);
}

#pragma mark - NSURLConnection / NSData hooks

static IMP orig_sendAsync;
static void hook_sendAsync(id cls, SEL _cmd, NSURLRequest *req,
                           NSOperationQueue *queue, id handler) {
    if (BNPShouldBlockURL(req.URL)) {
        void (^blk)(id, id, NSError *) = handler;
        NSError *e = BNPBlockedError(req.URL);
        [(queue ?: [NSOperationQueue mainQueue]) addOperationWithBlock:^{
            if (blk) blk(nil, nil, e);
        }];
        return;
    }
    ((void (*)(id, SEL, NSURLRequest *, NSOperationQueue *, id))
     orig_sendAsync)(cls, _cmd, req, queue, handler);
}

static IMP orig_sendSync;
static NSData *hook_sendSync(id cls, SEL _cmd, NSURLRequest *req,
                             NSURLResponse *__autoreleasing *resp,
                             NSError *__autoreleasing *err) {
    if (BNPShouldBlockURL(req.URL)) {
        if (err) *err = BNPBlockedError(req.URL);
        return nil;
    }
    return ((NSData *(*)(id, SEL, NSURLRequest *, void *, void *))
            orig_sendSync)(cls, _cmd, req, (void *)resp, (void *)err);
}

static IMP orig_connectionWithRequest;
static id hook_connectionWithRequest(id cls, SEL _cmd, NSURLRequest *req, id delegate) {
    if (BNPShouldBlockURL(req.URL)) return nil;
    return ((id (*)(id, SEL, NSURLRequest *, id))
            orig_connectionWithRequest)(cls, _cmd, req, delegate);
}

static IMP orig_initWithRequest;
static id hook_initWithRequest(NSURLConnection *self, SEL _cmd,
                               NSURLRequest *req, id delegate) {
    if (BNPShouldBlockURL(req.URL)) return nil;
    return ((id (*)(id, SEL, NSURLRequest *, id))
            orig_initWithRequest)(self, _cmd, req, delegate);
}

static IMP orig_initWithRequestStartImmediately;
static id hook_initWithRequestStartImmediately(NSURLConnection *self, SEL _cmd,
                                               NSURLRequest *req, id delegate,
                                               BOOL startImmediately) {
    if (BNPShouldBlockURL(req.URL)) return nil;
    return ((id (*)(id, SEL, NSURLRequest *, id, BOOL))
            orig_initWithRequestStartImmediately)(self, _cmd, req, delegate, startImmediately);
}

static IMP orig_dataWithContentsOfURL;
static NSData *hook_dataWithContentsOfURL(id cls, SEL _cmd, NSURL *url) {
    if (BNPShouldBlockURL(url)) return nil;
    return ((NSData *(*)(id, SEL, NSURL *))orig_dataWithContentsOfURL)(cls, _cmd, url);
}

static IMP orig_dataWithContentsOfURLOptions;
static NSData *hook_dataWithContentsOfURLOptions(id cls, SEL _cmd, NSURL *url,
                                                 NSUInteger options, void *err) {
    if (BNPShouldBlockURL(url)) return nil;
    return ((NSData *(*)(id, SEL, NSURL *, NSUInteger, void *))
            orig_dataWithContentsOfURLOptions)(cls, _cmd, url, options, err);
}

#pragma mark - WKWebView（仅 Strict 档启用）

static IMP orig_wkLoadRequest;
static id hook_wkLoadRequest(id self, SEL _cmd, NSURLRequest *req) {
    if (BNPActiveLevel() == BNPLevelStrict && BNPShouldBlockURL(req.URL)) return nil;
    return ((id (*)(id, SEL, NSURLRequest *))orig_wkLoadRequest)(self, _cmd, req);
}

#pragma mark - 禁用 GCDWebServer 本机 HTTP 服务（GCDWebUploader 的底座）

static IMP orig_gcdStart;
static BOOL hook_gcdStart(id self, SEL _cmd) {
    BNPNoteBlockedHost(@"(local-http-server)");
    return NO;
}

static IMP orig_gcdStartWithOptions;
static BOOL hook_gcdStartWithOptions(id self, SEL _cmd, id options, void *err) {
    BNPNoteBlockedHost(@"(local-http-server)");
    return NO;
}

static IMP orig_gcdStartWithPort;
static BOOL hook_gcdStartWithPort(id self, SEL _cmd, NSUInteger port, id bonjourName) {
    BNPNoteBlockedHost(@"(local-http-server)");
    return NO;
}

#pragma mark - C 层兜底：fishhook rebind getaddrinfo

#if BNP_USE_FISHHOOK
static int (*orig_getaddrinfo)(const char *, const char *,
                               const struct addrinfo *, struct addrinfo **);

static int hook_getaddrinfo(const char *node, const char *service,
                            const struct addrinfo *hints, struct addrinfo **res) {
    if (node && *node && BNPShouldBlockHostC(node)) {
        BNPNoteBlockedHost([NSString stringWithUTF8String:node] ?: @"(unknown)");
        return EAI_NONAME;
    }
    if (!orig_getaddrinfo) return EAI_FAIL;   /* rebind 异常时的保护，不应发生 */
    return orig_getaddrinfo(node, service, hints, res);
}

static void BNPInstallFishhook(void) {
    struct rebinding r = { "getaddrinfo", (void *)hook_getaddrinfo,
                           (void **)&orig_getaddrinfo };
    rebind_symbols(&r, 1);
    BNPLog(@"🔧 getaddrinfo rebind %@", orig_getaddrinfo ? @"OK" : @"FAILED");
}
#endif

#pragma mark - Constructor

__attribute__((constructor))
static void BlockNetPlusInit(void) {
    BNPLevel lv = BNPActiveLevel();
    BNPLog(@"✅ loading (level=%ld, block rules=%lu, allow rules=%lu)",
           (long)lv,
           (unsigned long)BNPBlockRules().count,
           (unsigned long)BNPAllowRules().count);

    NSUInteger installed = 0;

    /* 1. NSURLProtocol：全局注册 + 注入默认 configuration */
    [NSURLProtocol registerClass:[BNPBlockProtocol class]];
    Class Cfg = [NSURLSessionConfiguration class];
    if (BNPHook(Cfg, @selector(defaultSessionConfiguration),
                (IMP)hook_defaultSessionConfiguration,
                &orig_defaultSessionConfiguration)) installed++;
    if (BNPHook(Cfg, @selector(ephemeralSessionConfiguration),
                (IMP)hook_ephemeralSessionConfiguration,
                &orig_ephemeralSessionConfiguration)) installed++;

    /* 2. NSURLSession */
    Class S = [NSURLSession class];
    struct { SEL sel; IMP imp; IMP *orig; } sessionHooks[] = {
        { @selector(dataTaskWithRequest:),                        (IMP)hook_dataTaskWithRequest,                        &orig_dataTaskWithRequest },
        { @selector(dataTaskWithURL:),                            (IMP)hook_dataTaskWithURL,                            &orig_dataTaskWithURL },
        { @selector(downloadTaskWithRequest:),                   (IMP)hook_downloadTaskWithRequest,                   &orig_downloadTaskWithRequest },
        { @selector(downloadTaskWithURL:),                       (IMP)hook_downloadTaskWithURL,                       &orig_downloadTaskWithURL },
        { @selector(uploadTaskWithRequest:fromData:),             (IMP)hook_uploadTaskWithRequestFromData,             &orig_uploadTaskWithRequestFromData },
        { @selector(uploadTaskWithRequest:fromFile:),             (IMP)hook_uploadTaskWithRequestFromFile,             &orig_uploadTaskWithRequestFromFile },
        { @selector(dataTaskWithRequest:completionHandler:),     (IMP)hook_dataTaskWithRequestCompletion,             &orig_dataTaskWithRequestCompletion },
        { @selector(dataTaskWithURL:completionHandler:),         (IMP)hook_dataTaskWithURLCompletion,                 &orig_dataTaskWithURLCompletion },
        { @selector(downloadTaskWithRequest:completionHandler:), (IMP)hook_downloadTaskWithRequestCompletion,         &orig_downloadTaskWithRequestCompletion },
        { @selector(downloadTaskWithURL:completionHandler:),     (IMP)hook_downloadTaskWithURLCompletion,             &orig_downloadTaskWithURLCompletion },
        { @selector(uploadTaskWithRequest:fromData:completionHandler:), (IMP)hook_uploadTaskWithRequestFromDataCompletion, &orig_uploadTaskWithRequestFromDataCompletion },
        { @selector(uploadTaskWithRequest:fromFile:completionHandler:), (IMP)hook_uploadTaskWithRequestFromFileCompletion, &orig_uploadTaskWithRequestFromFileCompletion },
    };
    for (size_t i = 0; i < sizeof(sessionHooks)/sizeof(sessionHooks[0]); i++) {
        if (BNPHook(S, sessionHooks[i].sel, sessionHooks[i].imp, sessionHooks[i].orig)) installed++;
    }

    /* 3. NSURLConnection / NSData */
    Class Conn = [NSURLConnection class];
    if (BNPHook(Conn, @selector(sendAsynchronousRequest:queue:completionHandler:),
                (IMP)hook_sendAsync, &orig_sendAsync)) installed++;
    if (BNPHook(Conn, @selector(sendSynchronousRequest:returningResponse:error:),
                (IMP)hook_sendSync, &orig_sendSync)) installed++;
    if (BNPHook(Conn, @selector(connectionWithRequest:delegate:),
                (IMP)hook_connectionWithRequest, &orig_connectionWithRequest)) installed++;
    if (BNPHook(Conn, @selector(initWithRequest:delegate:),
                (IMP)hook_initWithRequest, &orig_initWithRequest)) installed++;
    if (BNPHook(Conn, @selector(initWithRequest:delegate:startImmediately:),
                (IMP)hook_initWithRequestStartImmediately,
                &orig_initWithRequestStartImmediately)) installed++;

    Class Data = [NSData class];
    if (BNPHook(Data, @selector(dataWithContentsOfURL:),
                (IMP)hook_dataWithContentsOfURL, &orig_dataWithContentsOfURL)) installed++;
    if (BNPHook(Data, @selector(dataWithContentsOfURL:options:error:),
                (IMP)hook_dataWithContentsOfURLOptions,
                &orig_dataWithContentsOfURLOptions)) installed++;

    /* 4. WKWebView（Strict） */
    Class WK = NSClassFromString(@"WKWebView");
    /* WKWebView 头文件未引入，用 NSSelectorFromString 避免 undeclared-selector 警告 */
    if (WK && BNPHook(WK, NSSelectorFromString(@"loadRequest:"),
                      (IMP)hook_wkLoadRequest, &orig_wkLoadRequest)) installed++;

    /* 5. 本机 HTTP 服务：默认禁用，可用 BNP_DISABLE_LOCAL_SERVER=0 关闭此行为 */
    if (BNPBoolConfig(@"BNP_DISABLE_LOCAL_SERVER", YES)) {
        Class G = NSClassFromString(@"GCDWebServer");
        if (G) {
            if (BNPHook(G, NSSelectorFromString(@"start"),
                        (IMP)hook_gcdStart, &orig_gcdStart)) installed++;
            if (BNPHook(G, NSSelectorFromString(@"startWithOptions:error:"),
                        (IMP)hook_gcdStartWithOptions, &orig_gcdStartWithOptions)) installed++;
            if (BNPHook(G, NSSelectorFromString(@"startWithPort:bonjourName:"),
                        (IMP)hook_gcdStartWithPort, &orig_gcdStartWithPort)) installed++;
        } else {
            BNPLog(@"ℹ️ GCDWebServer class not found, local-server hooks skipped");
        }
    }

    /* 6. C 层 DNS 兜底 */
#if BNP_USE_FISHHOOK
    BNPInstallFishhook();
#endif

    BNPLog(@"✅ %lu hooks installed; ready (search [BlockNet+] in device log)",
           (unsigned long)installed);
}
