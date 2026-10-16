#!/usr/bin/env python3
"""存储键契约核对：把 Swift 实现里的键字面量与 docs/recon/storage.md 里出现的键名做集合差分。

为什么需要它：iOS 端最硬的一条要求是「键名 / 默认值 / 存储规则不许改」。测试文件里
手写的键名断言只能证明「测试作者记得的键」，证明不了「没有漏键」。这个脚本从两侧
各自机械提取一遍，漏掉的键会直接显形。

用法：
    python tools/storage_key_diff.py
退出码：0 = Swift 的每个键都能在 storage.md 里找到（且没有多出来的键）；
        1 = 有差异（下面会列出）。
"""
from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
MD = ROOT / "docs" / "recon" / "storage.md"
SWIFT = (
    ROOT
    / "KebiaoCore"
    / "Sources"
    / "KebiaoCore"
    / "Storage"
    / "UserDefaultsTimetableRepository.swift"
)

# Swift 侧： static let name = "literal"   （只看键名字面量，不看值）
SWIFT_KEY_RE = re.compile(r'static let (\w+)\s*=\s*"([^"]*)"')
# markdown 表格单元里的 `identifier`
MD_CELL_RE = re.compile(r"^`([A-Za-z_][A-Za-z0-9_]*)`$")
# 键名的形状：camelCase 或 snake_case，全小写开头
KEY_SHAPE_RE = re.compile(r"^[a-z][A-Za-z0-9_]*$")


def swift_keys(text: str) -> dict[str, str]:
    return {name: literal for name, literal in SWIFT_KEY_RE.findall(text)}


def md_keys(text: str) -> set[str]:
    found: set[str] = set()
    for line in text.splitlines():
        if not line.lstrip().startswith("|"):
            continue
        for cell in line.strip().strip("|").split("|"):
            m = MD_CELL_RE.match(cell.strip())
            if m and KEY_SHAPE_RE.match(m.group(1)):
                found.add(m.group(1))
    return found


def main() -> int:
    for path in (MD, SWIFT):
        if not path.exists():
            print(f"[ERR] 找不到 {path}")
            return 2

    swift = swift_keys(SWIFT.read_text(encoding="utf-8"))
    documented = md_keys(MD.read_text(encoding="utf-8"))

    literals = set(swift.values())
    missing = sorted(name for name, literal in swift.items() if literal not in documented)
    extra = sorted(k for k in documented if k not in literals and k not in swift)

    print(f"Swift 实现：{len(swift)} 个键（{SWIFT.name}）")
    print(f"storage.md：{len(documented)} 个键名")
    print()

    if missing:
        print(f"[!] Swift 用到的键在 storage.md 里找不到（{len(missing)} 个）：")
        for name in missing:
            print(f"    {name} = \"{swift[name]}\"")
    else:
        print("[OK] Swift 的每个键字面量都能在 storage.md 中找到")

    if extra:
        print()
        print(f"[i] storage.md 里出现、Swift 未实现的键（{len(extra)} 个，需逐个判断是否属于本层）：")
        for name in extra:
            print(f"    {name}")

    print()
    print("提醒：本脚本只比『键名集合』，不比类型、默认值、读写时机 —— 那些要看 PersistenceTests 与 storage.md 的逐键表。")
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
