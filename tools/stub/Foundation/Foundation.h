// 最小 Foundation stub —— 仅用于本地语法/类型检查，不用于生产编译
#ifndef FOUNDATION_STUB_H
#define FOUNDATION_STUB_H
#include <stdint.h>
#include <stddef.h>
#include <stdarg.h>

/* zig 的 aarch64-ios 目标没有 Darwin libc 头文件，这里自己声明需要的 */
extern unsigned long strlen(const char *s);
extern char *strstr(const char *h, const char *n);
extern int strcmp(const char *a, const char *b);
extern int strcasecmp(const char *a, const char *b);
extern char *getenv(const char *name);
#include <objc/runtime.h>

typedef signed char BOOL;
#define YES ((BOOL)1)
#define NO  ((BOOL)0)
#define nil ((id)0)
#define Nil ((Class)0)
typedef long NSInteger;
typedef unsigned long NSUInteger;
typedef double NSTimeInterval;
typedef double CGFloat;

typedef struct { CGFloat x, y; } CGPoint;
typedef struct { CGFloat width, height; } CGSize;
typedef struct { CGPoint origin; CGSize size; } CGRect;
typedef struct { CGFloat top, left, bottom, right; } UIEdgeInsets;
typedef NSUInteger UIRectEdge;
enum { UIRectEdgeNone = 0, UIRectEdgeTop = 1, UIRectEdgeLeft = 2, UIRectEdgeBottom = 4, UIRectEdgeRight = 8 };
typedef CGFloat UIWindowLevel;
typedef NSInteger UIDeviceOrientation;
enum { UIDeviceOrientationUnknown = 0, UIDeviceOrientationPortrait = 1, UIDeviceOrientationLandscapeLeft = 3, UIDeviceOrientationLandscapeRight = 4 };

static inline CGRect CGRectMake(CGFloat x, CGFloat y, CGFloat w, CGFloat h){ CGRect r; r.origin.x=x;r.origin.y=y;r.size.width=w;r.size.height=h; return r; }
static inline CGSize CGSizeMake(CGFloat w, CGFloat h){ CGSize s; s.width=w;s.height=h; return s; }
/* ★ 必须是 extern 声明，不能写成 static inline ——
   真实 SDK 里这些是 CoreGraphics 的导出符号，链接期需要 -framework CoreGraphics。
   如果 stub 里定义成 inline，本地符号检查就看不到它们，
   也就发现不了「忘记链接 CoreGraphics」这类错误（踩过的坑）。 */
extern CGFloat CGRectGetMinX(CGRect r);
extern CGFloat CGRectGetMinY(CGRect r);
extern CGFloat CGRectGetMaxX(CGRect r);
extern CGFloat CGRectGetMaxY(CGRect r);
extern CGFloat CGRectGetWidth(CGRect r);
extern CGFloat CGRectGetHeight(CGRect r);
extern BOOL CGRectIsEmpty(CGRect r);
extern BOOL CGRectIntersectsRect(CGRect a, CGRect b);
static inline CGRect CGRectZeroMake(void){ return CGRectMake(0,0,0,0); }

@class NSString, NSArray, NSMutableString, NSNumber, NSValue, NSDictionary, NSError, NSLocale;

/* 快速枚举协议（for-in 需要） */
typedef struct {
    unsigned long state;
    __unsafe_unretained id *itemsPtr;
    unsigned long *mutationsPtr;
    unsigned long extra[5];
} NSFastEnumerationState;
@protocol NSFastEnumeration
- (NSUInteger)countByEnumeratingWithState:(NSFastEnumerationState *)state objects:(id *)buffer count:(NSUInteger)len;
@end

@interface NSObject
+ (instancetype)alloc;
+ (Class)class;
+ (BOOL)isSubclassOfClass:(Class)cls;
- (Class)class;
- (id)valueForKey:(NSString *)key;
- (instancetype)init;
- (BOOL)isKindOfClass:(Class)cls;
- (BOOL)respondsToSelector:(SEL)sel;
- (id)performSelector:(SEL)sel;
- (id)performSelector:(SEL)sel withObject:(id)obj;
- (NSString *)description;
@end

@interface NSString : NSObject
+ (instancetype)string;
+ (instancetype)stringWithFormat:(NSString *)fmt, ...;
+ (instancetype)stringWithUTF8String:(const char *)s;
- (instancetype)initWithFormat:(NSString *)fmt arguments:(va_list)ap;
- (BOOL)writeToFile:(NSString *)path atomically:(BOOL)atomically encoding:(NSUInteger)enc error:(NSError **)err;
@property (readonly) NSUInteger length;
- (NSString *)lowercaseString;
- (BOOL)isEqualToString:(NSString *)s;
- (NSString *)stringByAppendingString:(NSString *)s;
- (NSString *)stringByAppendingPathComponent:(NSString *)s;
- (NSString *)stringByPaddingToLength:(NSUInteger)len withString:(NSString *)pad startingAtIndex:(NSUInteger)idx;
- (NSString *)stringByReplacingOccurrencesOfString:(NSString *)a withString:(NSString *)b;
- (NSString *)descriptionWithLocale:(NSLocale *)l;
- (BOOL)hasPrefix:(NSString *)p;
- (const char *)UTF8String;
- (BOOL)containsString:(NSString *)s;
@end

@interface NSMutableString : NSString
+ (instancetype)string;
- (void)appendString:(NSString *)s;
@end

@interface NSArray : NSObject <NSFastEnumeration>
+ (instancetype)arrayWithObjects:(const id *)objects count:(NSUInteger)count;
@property (readonly) NSUInteger count;
- (id)firstObject;
- (id)objectAtIndexedSubscript:(NSUInteger)i;
- (NSString *)componentsJoinedByString:(NSString *)sep;
@end

@interface NSMutableArray : NSArray
+ (instancetype)array;
- (void)addObject:(id)obj;
@end

@interface NSNumber : NSObject
- (long)longValue;
- (NSInteger)integerValue;
+ (NSNumber *)numberWithInteger:(NSInteger)v;
+ (NSNumber *)numberWithBool:(BOOL)v;
@end

@interface NSException : NSObject
@property (readonly) NSString *name;
@property (readonly) NSString *reason;
@end

@interface NSError : NSObject
@property (readonly) NSString *localizedDescription;
@end

@interface NSLocale : NSObject
+ (NSLocale *)localeWithLocaleIdentifier:(NSString *)id;
@end

@interface NSUserDefaults : NSObject
+ (NSUserDefaults *)standardUserDefaults;
- (NSString *)stringForKey:(NSString *)key;
@end

@interface NSDate : NSObject
+ (NSDate *)date;
- (NSString *)descriptionWithLocale:(NSLocale *)l;
- (BOOL)hasPrefix:(NSString *)p;
- (const char *)UTF8String;
- (BOOL)containsString:(NSString *)s;
@end

extern void NSLog(NSString *fmt, ...);
enum { NSUTF8StringEncoding = 4 };
#ifndef MIN
#define MIN(a,b) ((a) < (b) ? (a) : (b))
#endif
#ifndef MAX
#define MAX(a,b) ((a) > (b) ? (a) : (b))
#endif
extern NSString *NSStringFromClass(Class cls);
extern NSString *NSStringFromSelector(SEL sel);
extern Class NSClassFromString(NSString *name);
extern SEL NSSelectorFromString(NSString *name);
@interface NSCoder : NSObject
@end
extern NSArray *NSSearchPathForDirectoriesInDomains(NSUInteger directory, NSUInteger domainMask, BOOL expandTilde);
enum { NSDocumentDirectory = 9, NSUserDomainMask = 1 };
#endif
