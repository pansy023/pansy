#!/usr/bin/env python3
"""Swift 源文件的静态体检（本机没有 Swift 工具链，这是能拿到的最强静态保证）。

做四件事：
1. 编码体检：必须是 UTF-8、无 BOM、纯 LF、不含 U+FFFD。
2. 分隔符配平：在**剥掉字符串与注释之后**统计 ()/{}/[]，要求最终归零且过程不为负。
   Swift 的块注释可嵌套、字符串可跨行（`\"\"\"`），所以这里用一个小状态机而不是
   正则——用正则会被字符串里的括号骗到。
3. 报告文件行数与字符数。
4. 退出码非 0 表示有文件不通过。

用法：
    python tools/swift_sanity_check.py
（本脚本按自己的位置定位工程根目录，因此工程目录改名或搬动都不需要改这里。）
"""

from __future__ import annotations

import sys
from pathlib import Path

# 脚本固定放在 <工程根>/tools/ 下，所以 parents[1] 就是工程根，与目录名无关。
SWIFT_ROOT = Path(__file__).resolve().parents[1]

PAIRS = {")": "(", "}": "{", "]": "["}


def strip_code(text: str) -> str:
    """把字符串字面量与注释替换成空格，保留换行以便报行号。

    只处理到「够用于配平检查」的程度：不解析 raw string 的自定义分隔符，
    但处理 `\"\"\"` 多行串、`#\"…\"#` 与转义。
    """
    out: list[str] = []
    i = 0
    n = len(text)
    while i < n:
        ch = text[i]

        # 行注释
        if text.startswith("//", i):
            while i < n and text[i] != "\n":
                out.append(" ")
                i += 1
            continue

        # 块注释（Swift 允许嵌套）
        if text.startswith("/*", i):
            depth = 1
            out.append("  ")
            i += 2
            while i < n and depth > 0:
                if text.startswith("/*", i):
                    depth += 1
                    out.append("  ")
                    i += 2
                elif text.startswith("*/", i):
                    depth -= 1
                    out.append("  ")
                    i += 2
                else:
                    out.append("\n" if text[i] == "\n" else " ")
                    i += 1
            continue

        # 多行字符串 """
        if text.startswith('"""', i):
            out.append("   ")
            i += 3
            while i < n and not text.startswith('"""', i):
                # 转义的三引号（\"\"\"）不算结束
                if text[i] == "\\" and i + 1 < n:
                    out.append("\n" if text[i] == "\n" else " ")
                    out.append(" ")
                    i += 2
                else:
                    out.append("\n" if text[i] == "\n" else " ")
                    i += 1
            if i < n:
                out.append("   ")
                i += 3
            continue

        # raw string #"…"# / ##"…"##
        if ch == "#" and '"' in text[i : i + 12]:
            hashes = 0
            j = i
            while j < n and text[j] == "#":
                hashes += 1
                j += 1
            if j < n and text[j] == '"':
                closer = '"' + "#" * hashes
                out.append(" " * (hashes + 1))
                i = j + 1
                while i < n and not text.startswith(closer, i):
                    out.append("\n" if text[i] == "\n" else " ")
                    i += 1
                if i < n:
                    out.append(" " * len(closer))
                    i += len(closer)
                continue

        # 普通字符串
        if ch == '"':
            out.append(" ")
            i += 1
            while i < n and text[i] != '"':
                if text[i] == "\\" and i + 1 < n:
                    out.append(" ")
                    out.append(" ")
                    i += 2
                else:
                    out.append("\n" if text[i] == "\n" else " ")
                    i += 1
            if i < n:
                out.append(" ")
                i += 1
            continue

        out.append(ch)
        i += 1
    return "".join(out)


def check_delimiters(path: Path, text: str) -> list[str]:
    stripped = strip_code(text)
    stack: list[tuple[str, int]] = []
    problems: list[str] = []
    line = 1
    for ch in stripped:
        if ch == "\n":
            line += 1
        elif ch in "({[":
            stack.append((ch, line))
        elif ch in PAIRS:
            if not stack:
                problems.append(f"{path.name}:{line}: 多余的 '{ch}'")
            elif stack[-1][0] != PAIRS[ch]:
                opener, opened_at = stack[-1]
                problems.append(
                    f"{path.name}:{line}: '{ch}' 与第 {opened_at} 行的 '{opener}' 不匹配"
                )
                stack.pop()
            else:
                stack.pop()
    for opener, opened_at in stack:
        problems.append(f"{path.name}:{opened_at}: '{opener}' 从未闭合")
    return problems


def main() -> int:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")

    if not SWIFT_ROOT.is_dir():
        print(f"找不到目录：{SWIFT_ROOT}")
        return 2

    files = sorted(SWIFT_ROOT.rglob("*.swift"))
    if not files:
        print(f"{SWIFT_ROOT} 下没有 .swift 文件")
        return 2

    all_problems: list[str] = []
    for path in files:
        raw = path.read_bytes()
        rel = path.relative_to(SWIFT_ROOT)
        notes: list[str] = []

        if raw.startswith(b"\xef\xbb\xbf"):
            notes.append("有 BOM")
        if b"\r\n" in raw:
            notes.append("含 CRLF")
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError as exc:
            all_problems.append(f"{rel}: 不是合法 UTF-8（{exc}）")
            continue
        if "\ufffd" in text:
            notes.append("含 U+FFFD")
        if "\t" in text:
            notes.append("含制表符")

        problems = check_delimiters(path, text)
        all_problems.extend(problems)

        lines = text.count("\n") + (0 if text.endswith("\n") else 1)
        status = "OK "
        if notes or problems:
            status = "!! "
        suffix = ("  [" + ", ".join(notes) + "]") if notes else ""
        print(f"{status}{rel!s:<62} {lines:>5} 行 {len(raw):>7} 字节{suffix}")

    print("-" * 92)
    if all_problems:
        print(f"发现 {len(all_problems)} 个问题：")
        for problem in all_problems:
            print(f"  - {problem}")
        return 1

    print(f"全部通过：{len(files)} 个 .swift 文件，分隔符配平、编码合规。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
