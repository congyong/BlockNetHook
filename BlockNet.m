#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>

// Substrate function pointer
static void (*orig_CFNetworkCopyProxiesForURL)(void);

// ============ 弹窗确认加载 ============
static void showAlert(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            
            UIWindow *window = UIApplication.sharedApplication.windows.firstObject;
            if (!window) return;
            
            UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:@"BlockNet"
                                                message:@"✅ LiveContainer Tweak Loaded"
                                         preferredStyle:UIAlertControllerStyleAlert];
            
            [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                      style:UIAlertActionStyleDefault
                                                    handler:nil]];
            
            [window.rootViewController presentViewController:alert
                                                    animated:YES
                                                  completion:nil];
        });
    });
}

// ============ Hook 示例 ============
static void *(*orig_CFURLCreateWithString)(CFAllocatorRef allocator,
                                           CFStringRef URLString,
                                           CFURLRef baseURL);

static void *hook_CFURLCreateWithString(CFAllocatorRef allocator,
                                        CFStringRef URLString,
                                        CFURLRef baseURL)
{
    NSString *url = (__bridge NSString *)URLString;
    
    if ([url containsString:@"umeng.com"] ||
        [url containsString:@"umengcloud.com"])
    {
        NSLog(@"[BlockNet] Blocked: %@", url);
        return NULL;
    }
    
    return orig_CFURLCreateWithString(allocator, URLString, baseURL);
}

// ============ Substrate 安装函数 ============
static void installHook(void) {
    
    void *handle = dlopen(NULL, RTLD_NOW);
    if (!handle) return;
    
    void *symbol = dlsym(handle, "CFURLCreateWithString");
    if (!symbol) return;
    
    void *substrate = dlopen("/usr/lib/libsubstrate.dylib", RTLD_NOW);
    if (!substrate) {
        substrate = dlopen("/usr/lib/libellekit.dylib", RTLD_NOW);
    }
    
    if (!substrate) {
        NSLog(@"[BlockNet] No substrate/ellekit found");
        return;
    }
    
    void (*MSHookFunction)(void *, void *, void **);
    MSHookFunction = dlsym(substrate, "MSHookFunction");
    
    if (!MSHookFunction) {
        NSLog(@"[BlockNet] MSHookFunction not found");
        return;
    }
    
    MSHookFunction(symbol,
                   (void *)hook_CFURLCreateWithString,
                   (void **)&orig_CFURLCreateWithString);
    
    NSLog(@"[BlockNet] Hook installed");
}

// ============ 入口 ============
__attribute__((constructor))
static void entry(void) {
    showAlert();
    installHook();
}
