#ifndef OBJC_RUNTIME_STUB_H
#define OBJC_RUNTIME_STUB_H
#include <stddef.h>
typedef struct objc_class *Class;
typedef struct objc_object *id;
typedef struct objc_selector *SEL;
typedef struct objc_method *Method;
typedef signed char BOOL2;
typedef void (*IMP)(void);
typedef unsigned long objc_AssociationPolicy;
#define OBJC_ASSOCIATION_RETAIN_NONATOMIC 1
extern const char *class_getName(Class cls);
extern const char *class_getImageName(Class cls);
extern Class object_getClass(id obj);
extern Method class_getInstanceMethod(Class cls, SEL name);
extern IMP method_setImplementation(Method m, IMP imp);
extern void object_setAssociatedObject(id object, const void *key, id value, objc_AssociationPolicy policy);
extern id object_getAssociatedObject(id object, const void *key);
extern void objc_setAssociatedObject(id object, const void *key, id value, objc_AssociationPolicy policy);
extern id objc_getAssociatedObject(id object, const void *key);
extern SEL sel_registerName(const char *str);
extern id objc_getClass(const char *name);
#endif
