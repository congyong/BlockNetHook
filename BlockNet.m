#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <netdb.h>

// fishhook type
struct rebinding {
    const char *name;
    void *replacement;
    void **replaced;
};

extern int rebind_symbols(struct rebinding rebindings[], size_t rebindings_nel);

// 原始函数指针
static int (*orig_getaddrinfo)(
    const char *nodename,
    const char *servname,
    const struct addrinfo *hints,
    struct addrinfo **res);

// hook getaddrinfo
static int hook_getaddrinfo(
    const char *nodename,
    const char *servname,
    const struct addrinfo *hints,
    struct addrinfo **res)
{
    if (nodename) {
        NSString *host = [NSString stringWithUTF8String:nodename];
        if ([host containsString:@"umeng.com"] ||
            [host containsString:@"umengcloud.com"])
        {
            NSLog(@"[BlockNet] Blocked DNS: %@", host);
            return EAI_FAIL;  // 让解析失败
        }
    }
    return orig_getaddrinfo(nodename, servname, hints, res);
}

// 测试界面弹窗（确认 tweak 加载）
static void showAlert(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            UIWindow *w = UIApplication.sharedApplication.windows.firstObject;
            if (!w) return;
            UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:@"BlockNet"
                                                message:@"LiveContainer Tweak Loaded"
                                         preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                      style:UIAlertActionStyleDefault
                                                    handler:nil]];
            [w.rootViewController presentViewController:alert animated:YES completion:nil];
        });
    });
}

// entry
__attribute__((constructor))
static void entry(void) {

    // UI 提示
    showAlert();

    // 安装 hook
    struct rebinding r;
    r.name = "getaddrinfo";
    r.replacement = hook_getaddrinfo;
    r.replaced = (void **)&orig_getaddrinfo;
    rebind_symbols(&r, 1);
}
