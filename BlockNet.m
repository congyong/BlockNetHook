/**
 * BlockUmeng.dylib
 * 屏蔽 umeng.com / umengcloud.com 的所有网络请求
 * 
 * Hook 层次：
 *  1. NSURLSession (现代网络层)
 *  2. NSURLConnection (旧版网络层)
 *  3. CFNetwork / CFHTTPMessage (底层 CoreFoundation)
 *
 * 编译要求：Theos + ElleKit/CydiaSubstrate
 */

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

// ─── 需要 Substrate / ElleKit ───────────────────────────────────────────────
#if __has_include(<substrate.h>)
  #import <substrate.h>
#elif __has_include(<CydiaSubstrate/CydiaSubstrate.h>)
  #import <CydiaSubstrate/CydiaSubstrate.h>
#else
  // ElleKit 兼容头（LiveContainer 内置 ElleKit）
  extern void MSHookMessageEx(Class _class, SEL sel, IMP imp, IMP *result);
  #define MSHookMessageEx(cls,sel,imp,old) MSHookMessageEx(cls,sel,imp,old)
#endif

// ─── 目标域名列表 ────────────────────────────────────────────────────────────
static NSArray<NSString *> *blockedSuffixes(void) {
    static NSArray *list;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        list = @[
            @"umeng.com",
            @"umengcloud.com",
        ];
    });
    return list;
}

static BOOL shouldBlockHost(NSString *host) {
    if (!host) return NO;
    host = host.lowercaseString;
    for (NSString *suffix in blockedSuffixes()) {
        // 精确匹配或子域名匹配 (*.umeng.com)
        if ([host isEqualToString:suffix] || [host hasSuffix:[@"." stringByAppendingString:suffix]]) {
            NSLog(@"[BlockUmeng] ❌ BLOCKED host: %@", host);
            return YES;
        }
    }
    return NO;
}

static BOOL shouldBlockURL(NSURL *url) {
    return shouldBlockHost(url.host);
}

static NSError *blockedError(NSURL *url) {
    return [NSError errorWithDomain:NSURLErrorDomain
                              code:NSURLErrorNotConnectedToInternet
                          userInfo:@{
        NSURLErrorFailingURLErrorKey: url ?: [NSURL URLWithString:@"about:blocked"],
        NSLocalizedDescriptionKey: @"Request blocked by BlockUmeng tweak.",
    }];
}

// ─── NSURLSession Hook ───────────────────────────────────────────────────────

// dataTaskWithRequest:completionHandler:
static IMP orig_dataTaskWithRequest_completionHandler;
static NSURLSessionDataTask *hook_dataTaskWithRequest_completionHandler(
    NSURLSession *self, SEL _cmd, NSURLRequest *request, void (^completionHandler)(NSData *, NSURLResponse *, NSError *))
{
    if (shouldBlockURL(request.URL)) {
        if (completionHandler) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completionHandler(nil, nil, blockedError(request.URL));
            });
        }
        // 返回一个已取消的空 task
        NSURLSessionDataTask *task = ((NSURLSessionDataTask *(*)(id,SEL,NSURLRequest*,void(^)(NSData*,NSURLResponse*,NSError*)))
            orig_dataTaskWithRequest_completionHandler)(self, _cmd, request, nil);
        [task cancel];
        return task;
    }
    return ((NSURLSessionDataTask *(*)(id,SEL,NSURLRequest*,void(^)(NSData*,NSURLResponse*,NSError*)))
        orig_dataTaskWithRequest_completionHandler)(self, _cmd, request, completionHandler);
}

// dataTaskWithURL:completionHandler:
static IMP orig_dataTaskWithURL_completionHandler;
static NSURLSessionDataTask *hook_dataTaskWithURL_completionHandler(
    NSURLSession *self, SEL _cmd, NSURL *url, void (^completionHandler)(NSData *, NSURLResponse *, NSError *))
{
    if (shouldBlockURL(url)) {
        if (completionHandler) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completionHandler(nil, nil, blockedError(url));
            });
        }
        NSURLSessionDataTask *task = ((NSURLSessionDataTask *(*)(id,SEL,NSURL*,void(^)(NSData*,NSURLResponse*,NSError*)))
            orig_dataTaskWithURL_completionHandler)(self, _cmd, url, nil);
        [task cancel];
        return task;
    }
    return ((NSURLSessionDataTask *(*)(id,SEL,NSURL*,void(^)(NSData*,NSURLResponse*,NSError*)))
        orig_dataTaskWithURL_completionHandler)(self, _cmd, url, completionHandler);
}

// dataTaskWithRequest: (无 completion handler，delegate 模式)
static IMP orig_dataTaskWithRequest;
static NSURLSessionDataTask *hook_dataTaskWithRequest(
    NSURLSession *self, SEL _cmd, NSURLRequest *request)
{
    if (shouldBlockURL(request.URL)) {
        NSURLSessionDataTask *task = ((NSURLSessionDataTask *(*)(id,SEL,NSURLRequest*))
            orig_dataTaskWithRequest)(self, _cmd, request);
        [task cancel];
        return task;
    }
    return ((NSURLSessionDataTask *(*)(id,SEL,NSURLRequest*))orig_dataTaskWithRequest)(self, _cmd, request);
}

// uploadTaskWithRequest:fromData:completionHandler:
static IMP orig_uploadTaskWithRequest;
static NSURLSessionUploadTask *hook_uploadTaskWithRequest(
    NSURLSession *self, SEL _cmd, NSURLRequest *request, NSData *data,
    void (^completionHandler)(NSData *, NSURLResponse *, NSError *))
{
    if (shouldBlockURL(request.URL)) {
        if (completionHandler) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completionHandler(nil, nil, blockedError(request.URL));
            });
        }
        NSURLSessionUploadTask *task = ((NSURLSessionUploadTask *(*)(id,SEL,NSURLRequest*,NSData*,void(^)(NSData*,NSURLResponse*,NSError*)))
            orig_uploadTaskWithRequest)(self, _cmd, request, data, nil);
        [task cancel];
        return task;
    }
    return ((NSURLSessionUploadTask *(*)(id,SEL,NSURLRequest*,NSData*,void(^)(NSData*,NSURLResponse*,NSError*)))
        orig_uploadTaskWithRequest)(self, _cmd, request, data, completionHandler);
}

// ─── NSURLConnection Hook ────────────────────────────────────────────────────

// +sendAsynchronousRequest:queue:completionHandler:
static IMP orig_sendAsync;
static void hook_sendAsync(
    Class self, SEL _cmd, NSURLRequest *request, NSOperationQueue *queue,
    void (^completionHandler)(NSURLResponse *, NSData *, NSError *))
{
    if (shouldBlockURL(request.URL)) {
        NSOperationQueue *q = queue ?: [NSOperationQueue mainQueue];
        [q addOperationWithBlock:^{
            completionHandler(nil, nil, blockedError(request.URL));
        }];
        return;
    }
    ((void(*)(id,SEL,NSURLRequest*,NSOperationQueue*,void(^)(NSURLResponse*,NSData*,NSError*)))
        orig_sendAsync)(self, _cmd, request, queue, completionHandler);
}

// -initWithRequest:delegate: (同步/delegate 模式)
static IMP orig_initWithRequest;
static id hook_initWithRequest(NSURLConnection *self, SEL _cmd, NSURLRequest *request, id delegate) {
    if (shouldBlockURL(request.URL)) {
        NSLog(@"[BlockUmeng] ❌ NSURLConnection blocked: %@", request.URL);
        return nil; // 直接返回 nil 使连接失败
    }
    return ((id(*)(id,SEL,NSURLRequest*,id))orig_initWithRequest)(self, _cmd, request, delegate);
}

// ─── NSURLProtocol 兜底 (拦截所有漏网请求) ──────────────────────────────────

@interface BlockUmengProtocol : NSURLProtocol
@end

@implementation BlockUmengProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    return shouldBlockURL(request.URL);
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    NSError *error = blockedError(self.request.URL);
    [self.client URLProtocol:self didFailWithError:error];
}

- (void)stopLoading {}

@end

// ─── 初始化 ──────────────────────────────────────────────────────────────────

__attribute__((constructor))
static void BlockUmengInit(void) {
    NSLog(@"[BlockUmeng] ✅ Loaded — blocking umeng.com & umengcloud.com");

    // 注册 NSURLProtocol 兜底
    [NSURLProtocol registerClass:[BlockUmengProtocol class]];

    // Hook NSURLSession
    Class sessionClass = [NSURLSession class];

    MSHookMessageEx(sessionClass,
        @selector(dataTaskWithRequest:completionHandler:),
        (IMP)hook_dataTaskWithRequest_completionHandler,
        &orig_dataTaskWithRequest_completionHandler);

    MSHookMessageEx(sessionClass,
        @selector(dataTaskWithURL:completionHandler:),
        (IMP)hook_dataTaskWithURL_completionHandler,
        &orig_dataTaskWithURL_completionHandler);

    MSHookMessageEx(sessionClass,
        @selector(dataTaskWithRequest:),
        (IMP)hook_dataTaskWithRequest,
        &orig_dataTaskWithRequest);

    MSHookMessageEx(sessionClass,
        @selector(uploadTaskWithRequest:fromData:completionHandler:),
        (IMP)hook_uploadTaskWithRequest,
        &orig_uploadTaskWithRequest);

    // Hook NSURLConnection (类方法)
    Class connMeta = object_getClass([NSURLConnection class]);
    MSHookMessageEx(connMeta,
        @selector(sendAsynchronousRequest:queue:completionHandler:),
        (IMP)hook_sendAsync,
        &orig_sendAsync);

    // Hook NSURLConnection (实例方法)
    MSHookMessageEx([NSURLConnection class],
        @selector(initWithRequest:delegate:),
        (IMP)hook_initWithRequest,
        &orig_initWithRequest);

    NSLog(@"[BlockUmeng] ✅ All hooks installed");
}
