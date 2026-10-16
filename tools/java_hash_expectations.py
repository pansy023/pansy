#!/usr/bin/env python3
"""为 Swift 单测生成 Java `String.hashCode()` 的期望值。

用途：`KebiaoCore/Tests/KebiaoCoreTests/JavaHashTests.swift` 与
`MorandiPaletteTests.swift` 里的期望常量都由本脚本产出，避免手算错。

用法（Windows，使用本机自带的 Python）：
    python 上课早枝道-iOS/tools/java_hash_expectations.py

注意：不要把这个脚本的内容通过 PowerShell 命令行内联执行——pwsh 控制台按 GBK
解码 UTF-8，中文字面量会被破坏（已踩过一次）。必须以 UTF-8 文件方式运行。
"""

from __future__ import annotations

# 与原版 Compose 源码逐字一致的 12 色莫兰迪调色板
# （apk_work/kb/src2/TimetableGridV2.kt:80-93）
MORANDI_PALETTE = [
    0xFFA8A8C0,
    0xFFACA7C5,
    0xFFA795A5,
    0xFF454350,
    0xFF797C67,
    0xFFC9AA7C,
    0xFFDAACB6,
    0xFFD1DBDA,
    0xFFBEBAAE,
    0xFF8D89A2,
    0xFFB7C0B2,
    0xFFC8B4A8,
]

# 覆盖：ASCII、空串、常见课程名、非 BMP（emoji，验证 UTF-16 代理对）
SAMPLES = [
    "",
    "a",
    "ab",
    "abc",
    "Hello",
    "高等数学",
    "大学英语",
    "线性代数",
    "数据结构",
    "体育",
    "计算机组成原理",
    "马克思主义基本原理",
    "操作系统",
    "编译原理",
    # 非 BMP：Java 里是一个代理对（两个 char），用来钉住「必须遍历 utf16 而不是
    # Swift 的 Character」这条实现约束。
    "\U0001F600",
]


def java_string_hash_code(value: str) -> int:
    """Java `String.hashCode()`：UTF-16 code unit、32 位有符号回绕。"""
    h = 0
    encoded = value.encode("utf-16-le")
    for i in range(0, len(encoded), 2):
        unit = encoded[i] | (encoded[i + 1] << 8)
        h = (31 * h + unit) & 0xFFFFFFFF
    if h >= 0x80000000:
        h -= 0x100000000
    return h


def main() -> None:
    # 本机 Windows 控制台默认 GBK，直接打印 emoji / 中文会 UnicodeEncodeError。
    # 强制 UTF-8 输出，保证脚本在任何终端都能跑完。
    import sys

    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")

    print(f"{'字符串':<24}{'hashCode':>14}{'bucket':>14}{'idx':>5}   argb")
    print("-" * 72)
    for sample in SAMPLES:
        raw = java_string_hash_code(sample)
        bucket = raw & 0x7FFFFFFF
        index = bucket % len(MORANDI_PALETTE)
        argb = MORANDI_PALETTE[index]
        shown = sample if sample else '""'
        print(f"{shown:<24}{raw:>14}{bucket:>14}{index:>5}   0x{argb:08X}")

    print()
    print("可直接粘进 Swift 断言的 (输入, hash, bucket, index, argb) 元组：")
    for sample in SAMPLES:
        raw = java_string_hash_code(sample)
        bucket = raw & 0x7FFFFFFF
        index = bucket % len(MORANDI_PALETTE)
        argb = MORANDI_PALETTE[index]
        escaped = sample.encode("unicode_escape").decode("ascii")
        print(
            f'        ("{escaped}", {raw}, {bucket}, {index}, 0x{argb:08X}),'
        )


if __name__ == "__main__":
    main()
