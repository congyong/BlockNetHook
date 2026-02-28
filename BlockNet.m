#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static BOOL shouldBlock(NSURL *url) {
    if (!url) return NO;

    NSString *host = url.host.lowercaseString;
    if (!host) return NO;

    if ([host hasSuffix:@"umeng.com"] ||
        [host hasSuffix:@"umengcloud.com"]) {

        NSLog(@"[BlockNet] 🚫 Blocked: %@", url.absoluteString);
        return YES;
    }

    return NO;
}

@implementation NSURLSession (BlockNet)

+ (void)load {

    NSLog(@"[BlockNet] ✅ HOOK LOADED");

    Class cls = [self class];

    // hook dataTaskWithRequest
    method_exchangeImplementations(
        class_getInstanceMethod(cls, @selector(dataTaskWithRequest:completionHandler:)),
        class_getInstanceMethod(cls, @selector(bn_dataTaskWithRequest:completionHandler:))
    );

    // hook dataTaskWithURL
    method_exchangeImplementations(
        class_getInstanceMethod(cls, @selector(dataTaskWithURL:completionHandler:)),
        class_getInstanceMethod(cls, @selector(bn_dataTaskWithURL:completionHandler:))
    );
}

- (NSURLSessionDataTask *)
bn_dataTaskWithRequest:(NSURLRequest *)request
     completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {

    NSLog(@"[BlockNet] Request: %@", request.URL);

    if (shouldBlock(request.URL)) {
        if (completionHandler) {
            NSError *error = [NSError errorWithDomain:NSURLErrorDomain
                                                 code:NSURLErrorCancelled
                                             userInfo:nil];
            completionHandler(nil, nil, error);
        }
        return nil;
    }

    return [self bn_dataTaskWithRequest:request completionHandler:completionHandler];
}

- (NSURLSessionDataTask *)
bn_dataTaskWithURL:(NSURL *)url
 completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {

    NSLog(@"[BlockNet] URL: %@", url);

    if (shouldBlock(url)) {
        if (completionHandler) {
            NSError *error = [NSError errorWithDomain:NSURLErrorDomain
                                                 code:NSURLErrorCancelled
                                             userInfo:nil];
            completionHandler(nil, nil, error);
        }
        return nil;
    }

    return [self bn_dataTaskWithURL:url completionHandler:completionHandler];
}

@end
