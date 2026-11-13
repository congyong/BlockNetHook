# BlockNetPlus — 本地编译（需要 macOS + Xcode / iPhoneOS SDK）
# Windows / Linux 没有 iOS SDK，无法编译，请改用 .github/workflows/build.yml

NAME  := BlockNetPlus
SRC   := BlockNetPlus.m fishhook.c
SDK   := $(shell xcrun --sdk iphoneos --show-sdk-path)
MIN   := 13.0
CC    := clang
# 置 0 可去掉 fishhook C 层 hook（ObjC 层拦截仍完整）：make FISHHOOK=0
FISHHOOK ?= 1
WARN  := -Wall -Wno-unknown-warning-option -Wno-unused-function \
         -Wno-deprecated-declarations -Wno-cast-function-type-strict -Wno-cast-function-type
FLAGS := -dynamiclib -isysroot "$(SDK)" -fobjc-arc -framework Foundation \
         -DBNP_USE_FISHHOOK=$(FISHHOOK) $(WARN)

.PHONY: all deps arm64 arm64e fat verify clean

all: fat verify

deps:
	@test -f fishhook.c || curl -fsSL -o fishhook.c https://raw.githubusercontent.com/facebook/fishhook/main/fishhook.c
	@test -f fishhook.h || curl -fsSL -o fishhook.h https://raw.githubusercontent.com/facebook/fishhook/main/fishhook.h

arm64: deps
	$(CC) $(SRC) $(FLAGS) -arch arm64  -miphoneos-version-min=$(MIN) -o $(NAME)_arm64.dylib

arm64e: deps
	$(CC) $(SRC) $(FLAGS) -arch arm64e -miphoneos-version-min=$(MIN) -o $(NAME)_arm64e.dylib

fat: arm64 arm64e
	lipo -create $(NAME)_arm64.dylib $(NAME)_arm64e.dylib -output $(NAME).dylib

verify: fat
	@echo "=== lipo ==="; lipo -info $(NAME).dylib
	@echo "=== file ==="; file $(NAME).dylib
	@echo "=== exported constructor ==="; nm -m $(NAME).dylib | grep -E 'BlockNetPlusInit|hook_getaddrinfo' || true

clean:
	rm -f $(NAME)_arm64.dylib $(NAME)_arm64e.dylib $(NAME).dylib fishhook.c fishhook.h
