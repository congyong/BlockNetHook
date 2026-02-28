#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static BOOL shouldBlock(NSURLRequest *request) {

    if (!request.URL) return NO;

    NSString *host = request.URL.host;
    if (!host) return NO;

    if ([host containsString:@"umeng.com"]) {
        NSLog(@"[BlockNet] 🚫 Blocked: %@", request.URL.absoluteString);
        return YES;
    }

    return NO;
}

@implementation NSURLSession (BlockNet)

+ (void)load {

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{

        Class cls = [self class];

        SEL originalSel = @selector(dataTaskWithRequest:completionHandler:);
        SEL swizzledSel = @selector(bn_dataTaskWithRequest:completionHandler:);

        Method originalMethod = class_getInstanceMethod(cls, originalSel);
        Method swizzledMethod = class_getInstanceMethod(cls, swizzledSel);

        method_exchangeImplementations(originalMethod, swizzledMethod);

        NSLog(@"[BlockNet] ✅ NSURLSession hook installed");
    });
}

- (NSURLSessionDataTask *)
bn_dataTaskWithRequest:(NSURLRequest *)request
     completionHandler:(void (^)(NSData *data,
                                 NSURLResponse *response,
                                 NSError *error))completionHandler {

    if (shouldBlock(request)) {

        if (completionHandler) {

            NSError *error = [NSError errorWithDomain:NSURLErrorDomain
                                                 code:NSURLErrorCancelled
                                             userInfo:nil];

            dispatch_async(dispatch_get_main_queue(), ^{
                completionHandler(nil, nil, error);
            });
        }

        return nil; // 不发请求
    }

    return [self bn_dataTaskWithRequest:request
                      completionHandler:completionHandler];
}

@end