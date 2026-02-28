/**
 * BlockUmeng.dylib
 * 屏蔽 umeng.com / umengcloud.com 的所有网络请求
 *
 * 无需 CydiaSubstrate / ElleKit，使用 ObjC runtime + fishhook 实现 hook
 */

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include "fishhook.h"

// ─── 轻量 MSHookMessageEx 替代（纯 ObjC runtime）─────────────────────────────
// 用法与 MSHookMessageEx 完全一致
static void HookMethod(Class cls, SEL sel, IMP newImp, IMP *oldImp) {
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) {
        method = class_getClassMethod(cls, sel);
        if (!method) {
            NSLog(@"[BlockUmeng] ⚠️ Method not found: %@ %@", cls, NSStringFromSelector(sel));
            return;
        }
        cls = object_getClass(cls); // 类方法需要操作 metaclass
        method = class_getInstanceMethod(cls, sel);
    }
    if (oldImp) *oldImp = method_getImplementation(method);
    method_setImplementation(method, newImp);
}

// ─── 目标域名 ─────────────────────────────────────────────────────────────────
static BOOL shouldBlockHost(NSString *host) {
    if (!host) return NO;
    host = host.lowercaseString;
    static NSArray *suffixes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        suffixes = @[@"umeng.com", @"umengcloud.com"];
    });
    for (NSString *s in suffixes) {
        if ([host isEqualToString:s] || [host hasSuffix:[@"." stringByAppendingString:s]]) {
            NSLog(@"[BlockUmeng] ❌ BLOCKED: %@", host);
            return YES;
        }
    }
    return NO;
}

static BOOL shouldBlockURL(NSURL *url) { return shouldBlockHost(url.host); }

static NSError *blockedError(NSURL *url) {
    return [NSError errorWithDomain:NSURLErrorDomain
                              code:NSURLErrorNotConnectedToInternet
                          userInfo:@{
        NSURLErrorFailingURLErrorKey: url ?: [NSURL URLWithString:@"about:blocked"],
        NSLocalizedDescriptionKey: @"Blocked by BlockUmeng.",
    }];
}

// ─── NSURLSession hooks ───────────────────────────────────────────────────────
static IMP orig_dataTaskWithRequest_completion;
static NSURLSessionDataTask *hook_dataTaskWithRequest_completion(
    NSURLSession *self, SEL _cmd, NSURLRequest *req,
    void (^handler)(NSData *, NSURLResponse *, NSError *))
{
    if (shouldBlockURL(req.URL)) {
        NSURLSessionDataTask *t = ((id(*)(id,SEL,NSURLRequest*,id))
            orig_dataTaskWithRequest_completion)(self,_cmd,req,nil);
        [t cancel];
        if (handler) dispatch_async(dispatch_get_main_queue(), ^{ handler(nil,nil,blockedError(req.URL)); });
        return t;
    }
    return ((id(*)(id,SEL,NSURLRequest*,id))orig_dataTaskWithRequest_completion)(self,_cmd,req,handler);
}

static IMP orig_dataTaskWithURL_completion;
static NSURLSessionDataTask *hook_dataTaskWithURL_completion(
    NSURLSession *self, SEL _cmd, NSURL *url,
    void (^handler)(NSData *, NSURLResponse *, NSError *))
{
    if (shouldBlockURL(url)) {
        NSURLSessionDataTask *t = ((id(*)(id,SEL,NSURL*,id))
            orig_dataTaskWithURL_completion)(self,_cmd,url,nil);
        [t cancel];
        if (handler) dispatch_async(dispatch_get_main_queue(), ^{ handler(nil,nil,blockedError(url)); });
        return t;
    }
    return ((id(*)(id,SEL,NSURL*,id))orig_dataTaskWithURL_completion)(self,_cmd,url,handler);
}

static IMP orig_dataTaskWithRequest;
static NSURLSessionDataTask *hook_dataTaskWithRequest(
    NSURLSession *self, SEL _cmd, NSURLRequest *req)
{
    if (shouldBlockURL(req.URL)) {
        NSURLSessionDataTask *t = ((id(*)(id,SEL,NSURLRequest*))orig_dataTaskWithRequest)(self,_cmd,req);
        [t cancel]; return t;
    }
    return ((id(*)(id,SEL,NSURLRequest*))orig_dataTaskWithRequest)(self,_cmd,req);
}

static IMP orig_uploadTask;
static NSURLSessionUploadTask *hook_uploadTask(
    NSURLSession *self, SEL _cmd, NSURLRequest *req, NSData *data,
    void (^handler)(NSData *, NSURLResponse *, NSError *))
{
    if (shouldBlockURL(req.URL)) {
        NSURLSessionUploadTask *t = ((id(*)(id,SEL,NSURLRequest*,NSData*,id))
            orig_uploadTask)(self,_cmd,req,data,nil);
        [t cancel];
        if (handler) dispatch_async(dispatch_get_main_queue(), ^{ handler(nil,nil,blockedError(req.URL)); });
        return t;
    }
    return ((id(*)(id,SEL,NSURLRequest*,NSData*,id))orig_uploadTask)(self,_cmd,req,data,handler);
}

// ─── NSURLConnection hooks ────────────────────────────────────────────────────
static IMP orig_sendAsync;
static void hook_sendAsync(
    Class cls, SEL _cmd, NSURLRequest *req, NSOperationQueue *q,
    void (^handler)(NSURLResponse *, NSData *, NSError *))
{
    if (shouldBlockURL(req.URL)) {
        [(q ?: NSOperationQueue.mainQueue) addOperationWithBlock:^{
            handler(nil, nil, blockedError(req.URL));
        }]; return;
    }
    ((void(*)(id,SEL,NSURLRequest*,NSOperationQueue*,id))orig_sendAsync)(cls,_cmd,req,q,handler);
}

static IMP orig_initWithRequest;
static id hook_initWithRequest(NSURLConnection *self, SEL _cmd, NSURLRequest *req, id delegate) {
    if (shouldBlockURL(req.URL)) return nil;
    return ((id(*)(id,SEL,NSURLRequest*,id))orig_initWithRequest)(self,_cmd,req,delegate);
}

// ─── NSURLProtocol 兜底 ───────────────────────────────────────────────────────
@interface BlockUmengProtocol : NSURLProtocol
@end
@implementation BlockUmengProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)r { return shouldBlockURL(r.URL); }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)r { return r; }
- (void)startLoading { [self.client URLProtocol:self didFailWithError:blockedError(self.request.URL)]; }
- (void)stopLoading {}
@end

// ─── Constructor ──────────────────────────────────────────────────────────────
__attribute__((constructor))
static void BlockUmengInit(void) {
    NSLog(@"[BlockUmeng] ✅ Loading...");

    // NSURLProtocol 兜底
    [NSURLProtocol registerClass:[BlockUmengProtocol class]];

    // NSURLSession
    Class S = [NSURLSession class];
    HookMethod(S, @selector(dataTaskWithRequest:completionHandler:), (IMP)hook_dataTaskWithRequest_completion, &orig_dataTaskWithRequest_completion);
    HookMethod(S, @selector(dataTaskWithURL:completionHandler:),     (IMP)hook_dataTaskWithURL_completion,     &orig_dataTaskWithURL_completion);
    HookMethod(S, @selector(dataTaskWithRequest:),                   (IMP)hook_dataTaskWithRequest,            &orig_dataTaskWithRequest);
    HookMethod(S, @selector(uploadTaskWithRequest:fromData:completionHandler:), (IMP)hook_uploadTask, &orig_uploadTask);

    // NSURLConnection (类方法)
    Class CM = object_getClass([NSURLConnection class]);
    HookMethod(CM, @selector(sendAsynchronousRequest:queue:completionHandler:), (IMP)hook_sendAsync, &orig_sendAsync);

    // NSURLConnection (实例方法)
    HookMethod([NSURLConnection class], @selector(initWithRequest:delegate:), (IMP)hook_initWithRequest, &orig_initWithRequest);

    NSLog(@"[BlockUmeng] ✅ All hooks installed");
}
