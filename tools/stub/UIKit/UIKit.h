// 最小 UIKit stub —— 仅用于本地语法/类型检查
#ifndef UIKIT_STUB_H
#define UIKIT_STUB_H
#import <Foundation/Foundation.h>

@class UIView, UIWindow, UIViewController, UIScreen, UIDevice, UIApplication,
       UINavigationController, UITabBarController, UISplitViewController, UIPageViewController;

extern const UIEdgeInsets UIEdgeInsetsZero;

@interface UIResponder : NSObject
@end

@interface UIScreen : NSObject
+ (UIScreen *)mainScreen;
@property (readonly) CGRect bounds;
@property (readonly) CGFloat scale;
@end

@interface UIDevice : NSObject
+ (UIDevice *)currentDevice;
@property (readonly) UIDeviceOrientation orientation;
@end

@interface UIView : UIResponder
@property (nonatomic) CGRect frame;
@property (nonatomic) CGRect bounds;
@property (nonatomic) CGPoint center;
@property (nonatomic, getter=isHidden) BOOL hidden;
@property (nonatomic) CGFloat alpha;
@property (nonatomic) BOOL clipsToBounds;
@property (nonatomic) BOOL translatesAutoresizingMaskIntoConstraints;
@property (nonatomic, readonly) NSArray *subviews;
@property (nonatomic, readonly) UIView *superview;
@property (nonatomic, readonly) UIWindow *window;
- (instancetype)initWithFrame:(CGRect)frame;
- (CGRect)convertRect:(CGRect)rect toView:(UIView *)view;
- (void)setNeedsLayout;
@end

@interface UIWindow : UIView
@property (nonatomic) UIEdgeInsets safeAreaInsets;
@property (nonatomic, getter=isKeyWindow) BOOL keyWindow;
@property (nonatomic) UIWindowLevel windowLevel;
@property (nonatomic, strong) UIViewController *rootViewController;
- (void)makeKeyAndVisible;
- (void)didBecomeVisible;
@end

@interface UIViewController : UIResponder
@property (nonatomic, strong) UIView *view;
@property (nonatomic, readonly) BOOL isViewLoaded;
@property (nonatomic) UIRectEdge edgesForExtendedLayout;
@property (nonatomic, readonly) NSArray *childViewControllers;
@property (nonatomic, readonly) UIViewController *presentedViewController;
@property (nonatomic, readonly) UINavigationController *navigationController;
@property (nonatomic, readonly) UITabBarController *tabBarController;
- (void)viewDidLoad;
- (void)viewWillAppear:(BOOL)animated;
- (void)viewDidAppear:(BOOL)animated;
@end

@interface UIAlertController : UIViewController
@end
@interface UIPopoverPresentationController : NSObject
@end
@interface UIActivityViewController : UIViewController
@end
@interface UINavigationController : UIViewController
@end
@interface UISplitViewController : UIViewController
@end
@interface UIPageViewController : UIViewController
@end
@interface UITabBarController : UIViewController
@end

@interface UIApplication : NSObject
+ (UIApplication *)sharedApplication;
@property (readonly) NSArray *windows;
@end
#endif
