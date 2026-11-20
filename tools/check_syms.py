#!/usr/bin/env python3
"""
check_syms.py —— 本地链接前检查：列出 .o 里的未定义符号并按框架归类。

用途：CI 的 Link check 步骤能抓到「忘记链接某个 framework」，但要等两分钟。
这个脚本在 Windows 本地就能做同样的事 —— 它不真的链接，只看符号表。

用法：
    python tools/check_syms.py build/check/SafeAreaDiag.o

退出码：
    0 = 所有未定义符号都能归到已知框架
    1 = 有符号无法归类（很可能漏链接了某个 framework）
"""
import struct
import sys

# 未定义符号前缀 → 提供它的框架
FRAMEWORK_RULES = [
    # libobjc / Objective-C runtime
    ("_objc_", "libobjc"),
    ("_class_", "libobjc"),
    ("_method_", "libobjc"),
    ("_sel_", "libobjc"),
    ("_protocol_", "libobjc"),
    ("_ivar_", "libobjc"),
    ("_property_", "libobjc"),
    ("_object_", "libobjc"),
    ("_imp_", "libobjc"),
    # ObjC 类符号：_OBJC_CLASS_$_UIxxx → UIKit，_OBJC_CLASS_$_NSxxx → Foundation
    ("_OBJC_CLASS_$_UI", "UIKit"),
    ("_OBJC_CLASS_$_NS", "Foundation"),
    ("_OBJC_CLASS_$_CF", "CoreFoundation"),
    ("_OBJC_CLASS_$_MK", "MapKit"),
    ("_OBJC_CLASS_$_AV", "AVFoundation"),
    # 常量 / block / unwind / ubsan —— 都由 libSystem 与 BlocksRuntime 提供
    ("__NSConcrete", "libSystem"),
    ("___CFConstant", "CoreFoundation"),
    ("___kCFBoolean", "CoreFoundation"),
    ("__Unwind_", "libSystem"),
    ("___objc_personality", "libSystem"),
    ("___ubsan_handle", "libSystem"),
    ("___stack_chk", "libSystem"),
    # CoreGraphics
    ("_CG", "CoreGraphics"),
    ("_CGRect", "CoreGraphics"),
    ("_CGSize", "CoreGraphics"),
    ("_CGPoint", "CoreGraphics"),
    ("_CGAffine", "CoreGraphics"),
    ("_CGFloat", "CoreGraphics"),
    # CoreFoundation
    ("_CF", "CoreFoundation"),
    # Foundation
    ("_NS", "Foundation"),
    ("_CFArray", "CoreFoundation"),
    # UIKit
    ("_UI", "UIKit"),
    # libSystem / dispatch
    ("_dispatch_", "libSystem"),
    ("_os_", "libSystem"),
    ("_pthread_", "libSystem"),
    ("_memcpy", "libSystem"),
    ("_memset", "libSystem"),
    ("_strlen", "libSystem"),
    ("_strcmp", "libSystem"),
    ("_strcasecmp", "libSystem"),
    ("_strstr", "libSystem"),
    ("_strchr", "libSystem"),
    ("_malloc", "libSystem"),
    ("_free", "libSystem"),
    ("_getenv", "libSystem"),
    ("_abort", "libSystem"),
    ("_exit", "libSystem"),
    ("_objc_", "libobjc"),
    ("___stack_chk", "libSystem"),
    ("_dyld_", "libSystem"),
    ("_BZ2_", "libcompression"),
    ("_kCT", "CoreTelephony"),
    ("_CT", "CoreTelephony"),
    ("_SSL", "libsqlite3"),
    ("_sqlite", "libsqlite3"),
    ("_iconv", "libiconv"),
    ("_res_", "libresolv"),
    ("_mkstemp", "libSystem"),
    ("_fopen", "libSystem"),
    ("_fclose", "libSystem"),
    ("_fwrite", "libSystem"),
    ("_fread", "libSystem"),
    ("_fputs", "libSystem"),
    ("_printf", "libSystem"),
    ("_snprintf", "libSystem"),
    ("_vsnprintf", "libSystem"),
    ("_getpid", "libSystem"),
    ("_sysctl", "libSystem"),
]

# 需要 -framework 的框架 → 提示该加哪个链接参数
FRAMEWORK_FLAG = {
    "CoreGraphics": "-framework CoreGraphics",
    "UIKit": "-framework UIKit",
    "Foundation": "-framework Foundation",
    "CoreFoundation": "-framework CoreFoundation",
    "libobjc": "-lobjc",
}


def parse_undefined(path):
    b = open(path, "rb").read()
    magic = struct.unpack("<I", b[:4])[0]
    if magic == 0xcafebabe:
        n = struct.unpack(">I", b[4:8])[0]
        for i in range(n):
            ct, cs, off, size, al = struct.unpack(">5I", b[8 + i * 20:28 + i * 20])
            if ct == 0x0100000c:
                return parse_undefined_slice(b[off:off + size])
        raise SystemExit("no arm64 slice")
    return parse_undefined_slice(b)


def parse_undefined_slice(seg):
    ncmds = struct.unpack("<I", seg[16:20])[0]
    o = 32
    symtab = None
    for _ in range(ncmds):
        cmd, csz = struct.unpack("<II", seg[o:o + 8])
        if cmd == 0x2:  # LC_SYMTAB
            symoff, nsyms, stroff, strsize = struct.unpack("<4I", seg[o + 8:o + 24])
            symtab = (symoff, nsyms, stroff, strsize)
        o += csz
    if not symtab:
        return []
    symoff, nsyms, stroff, strsize = symtab
    syms = []
    for i in range(nsyms):
        off = symoff + i * 16  # nlist_64
        strx, ntype, nsect, ndesc, nvalue = struct.unpack("<IBBHQ", seg[off:off + 16])
        if (ntype & 0x0E) != 0x00:      # N_UNDF
            continue
        if not (ntype & 0x01):            # N_EXT
            continue
        end = seg.find(b"\x00", stroff + strx)
        name = seg[stroff + strx:end].decode("utf-8", "ignore")
        if name:
            syms.append(name)
    return sorted(set(syms))


def classify(sym):
    for prefix, fw in FRAMEWORK_RULES:
        if sym.startswith(prefix):
            return fw
    return None


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    total_unknown = 0
    for path in sys.argv[1:]:
        print(f"── {path}")
        syms = parse_undefined(path)
        if not syms:
            print("   （无未定义符号）")
            continue
        buckets = {}
        unknown = []
        for s in syms:
            fw = classify(s)
            if fw:
                buckets.setdefault(fw, []).append(s)
            else:
                unknown.append(s)
        for fw in sorted(buckets):
            names = buckets[fw]
            flag = FRAMEWORK_FLAG.get(fw, "")
            print(f"   {fw:16} {len(names):3} 个  {flag}")
            for n in names[:8]:
                print(f"        {n}")
            if len(names) > 8:
                print(f"        … 还有 {len(names) - 8} 个")
        if unknown:
            total_unknown += len(unknown)
            print(f"   ★ 无法归类 {len(unknown)} 个（很可能漏链接了 framework）:")
            for n in unknown:
                print(f"        {n}")
        else:
            print("   ✓ 全部可归类")
    return 1 if total_unknown else 0


if __name__ == "__main__":
    sys.exit(main())
