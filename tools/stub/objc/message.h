#ifndef OBJC_MESSAGE_STUB_H
#define OBJC_MESSAGE_STUB_H
#include <stddef.h>
/* 与 clang builtin 保持一致，避免 incompatible redeclaration */
extern id objc_msgSend(id self, SEL op, ...);
#endif
