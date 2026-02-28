#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static void showAlert(NSString *message) {

    dispatch_async(dispatch_get_main_queue(), ^{

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{

            UIWindow *keyWindow = UIApplication.sharedApplication.windows.firstObject;
            if (!keyWindow) return;

            UIViewController *rootVC = keyWindow.rootViewController;
            if (!rootVC) return;

            UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:@"BlockNet"
                                                message:message
                                         preferredStyle:UIAlertControllerStyleAlert];

            UIAlertAction *ok =
            [UIAlertAction actionWithTitle:@"OK"
                                     style:UIAlertActionStyleDefault
                                   handler:nil];

            [alert addAction:ok];

            [rootVC presentViewController:alert animated:YES completion:nil];
        });
    });
}

@implementation NSURLSession (BlockNet)

+ (void)load {

    showAlert(@"✅ BlockNet dylib loaded");
}

@end
