#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>

static void showAlert(void) {

    dispatch_async(dispatch_get_main_queue(), ^{

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{

            UIWindow *window = nil;

            if (@available(iOS 13.0, *)) {
                for (UIWindowScene *scene in UIApplication.sharedApplication.connectedScenes) {
                    if (scene.activationState == UISceneActivationStateForegroundActive) {
                        window = scene.windows.firstObject;
                        break;
                    }
                }
            } else {
                window = UIApplication.sharedApplication.keyWindow;
            }

            if (!window) return;

            UIViewController *rootVC = window.rootViewController;
            if (!rootVC) return;

            // 1️⃣ 弹窗
            UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:@"BlockNet"
                                                message:@"✅ DYLIB INJECTED SUCCESS"
                                         preferredStyle:UIAlertControllerStyleAlert];

            UIAlertAction *ok =
            [UIAlertAction actionWithTitle:@"OK"
                                     style:UIAlertActionStyleDefault
                                   handler:nil];

            [alert addAction:ok];
            [rootVC presentViewController:alert animated:YES completion:nil];

            // 2️⃣ 修改界面背景色（非常明显）
            window.backgroundColor = [UIColor redColor];

            // 3️⃣ 震动
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);

            // 4️⃣ 写入文件
            NSString *docPath =
            NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                NSUserDomainMask,
                                                YES).firstObject;

            NSString *logPath =
            [docPath stringByAppendingPathComponent:@"inject_success.txt"];

            [@"DYLIB LOADED"
             writeToFile:logPath
             atomically:YES
             encoding:NSUTF8StringEncoding
             error:nil];
        });
    });
}

__attribute__((constructor))
static void entry(void) {
    showAlert();
}
