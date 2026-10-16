#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""swift_api_check.py —— 在没有 Swift 编译器的机器上做一次「跨文件 API 引用」交叉检查。

它 **不是编译器**，也 **不检查类型**。它只回答一个问题：

    代码里写的 `Type.member` / `变量.member`，指向的这个 member 在本工程的
    Swift 源码里到底有没有声明？

用途：本机（Windows）没有 swift/swiftc/xcodebuild，写出来的 Swift 一次都没编译过。
人工评审容易漏掉「凭想象编出来的 API」（例如 store.weekNumberText 其实叫别的名字、
TimetableLayout.cardFrame 根本不存在）。这个脚本专门抓这类问题。

原理（刻意保守，宁少报不误报）：
  1. 先把字符串字面量与注释剥掉（复用 swift_sanity_check.py 的同款状态机）；
  2. 「本工程的类型」= 在扫描目录里出现 struct/class/enum/actor/protocol/typealias 声明的名字，
     因此 Color/Font/View 这类系统类型天然不会被检查（它们不在这里声明）；
  3. 收集所有声明出来的成员名（func / var / let / case / init / typealias）；
  4. 找两类引用：
       - 静态引用：`本工程类型.member`
       - 实例引用：先找出 `let x: 本工程类型` 或 `= 本工程类型(` 绑定的变量 x，
         再找 `x.member`
     引用的 member 若在声明集合里找不到，且不在允许白名单里，就报一行 ERR；
  5. 白名单只有语言级成员（init/self/some/any/none/Type 等）和无意义的数字成员。
  6. 另外查两类「真编译器必报」的结构性错误：
       - 同一 target 内顶层类型重名（invalid redeclaration）；
       - 协议一致性不完整（写了 `: P`，却漏实现 P 的某个 func/var/init
         ⇒ "does not conform to protocol 'P'"）。成员可以写在 extension 里，
         协议也可以用 extension 提供默认实现，这两种情况都会被正确算进去。

用法：
    python 上课早枝道-iOS/tools/swift_api_check.py 上课早枝道-iOS/KebiaoCore 上课早枝道-iOS/apps

退出码：0 = 没有发现未声明的核心成员引用；1 = 有；2 = 参数/路径错误。
"""

import os
import re
import sys

WHITELIST = {
    "init", "self", "Self", "some", "any", "none", "Type", "Protocol",
    "zero", "max", "min", "allCases", "description", "debugDescription",
    "hashValue", "hash", "count", "isEmpty", "first", "last", "map",
    "filter", "reduce", "sorted", "contains", "id", "rawValue",
}

TYPE_DECL_RE = re.compile(
    r"\b(?:struct|class|enum|actor|protocol)\s+([A-Za-z_][A-Za-z0-9_]*)")
TYPEALIAS_RE = re.compile(r"\btypealias\s+([A-Za-z_][A-Za-z0-9_]*)")
# 成员名可能被反引号包住（Swift 里用关键字当标识符：`default`、`repeat`、`class`）
MEMBER_DECL_RE = re.compile(
    r"\b(?:func|var|let|case|init)\s+`?([A-Za-z_][A-Za-z0-9_]*)`?")
CASE_LIST_RE = re.compile(r"^\s*case\s+(.+)$", re.M)
STATIC_REF_RE = re.compile(r"\b([A-Z][A-Za-z0-9_]*)\s*\.\s*([A-Za-z_][A-Za-z0-9_]*)")
# 任何 `名字: 类型` 形式：let x: T / var x: T / func f(x: T) / `_ body: String`
# 只收「类型名首字母大写」的写法，避免把字典字面量、外部参数标签误当成类型。
BINDING_RE = re.compile(r"\b([a-z_][A-Za-z0-9_]*)\s*:\s*([A-Z][A-Za-z0-9_]*)")
# let x = Type(   /  private var x: Type =  ...  /  @StateObject var x = Type(
INIT_VAR_RE = re.compile(
    r"\b(?:let|var)\s+([a-z_][A-Za-z0-9_]*)[^=\n]*=\s*([A-Z][A-Za-z0-9_]*)\s*\(")


def strip_literals_and_comments(src: str) -> str:
    """把字符串/字符字面量与注释换成等长空格，保留换行与列位置。

    处理：// 行注释、/* 块注释（支持嵌套）、"普通串"、\"转义\"、
    \"\"\"多行串\"\"\"、#\"原始串\"#（含 #\"\"\"…\"\"\"#）。
    """
    out = []
    i, n = 0, len(src)
    mode = "code"  # code | line | block | str | raw
    block_depth = 0
    raw_hashes = 0
    triple = False
    while i < n:
        ch = src[i]
        nxt = src[i + 1] if i + 1 < n else ""
        if mode == "code":
            if ch == "/" and nxt == "/":
                mode = "line"
                out.append("  ")
                i += 2
                continue
            if ch == "/" and nxt == "*":
                mode = "block"
                block_depth = 1
                out.append("  ")
                i += 2
                continue
            if ch == "#" and nxt == '"':
                j = i + 1
                k = 0
                while j < n and src[j] == "#":
                    k += 1
                    j += 1
                # 只把 #" 视为原始串开头（#if 等指令以 # 后跟字母）
                if j < n and src[j] == '"':
                    mode = "raw"
                    raw_hashes = k
                    out.append(" " * (k + 1))
                    i = j + 1
                    continue
            if ch == '"':
                if src.startswith('"""', i):
                    triple = True
                    mode = "str"
                    out.append("   ")
                    i += 3
                    continue
                triple = False
                mode = "str"
                out.append(" ")
                i += 1
                continue
            out.append(ch)
            i += 1
        elif mode == "line":
            if ch == "\n":
                mode = "code"
                out.append("\n")
            else:
                out.append(" ")
            i += 1
        elif mode == "block":
            if ch == "/" and nxt == "*":
                block_depth += 1
                out.append("  ")
                i += 2
                continue
            if ch == "*" and nxt == "/":
                block_depth -= 1
                out.append("  ")
                i += 2
                if block_depth == 0:
                    mode = "code"
                continue
            out.append("\n" if ch == "\n" else " ")
            i += 1
        elif mode == "str":
            if triple:
                if src.startswith('"""', i):
                    mode = "code"
                    out.append("   ")
                    i += 3
                    continue
                out.append("\n" if ch == "\n" else " ")
                i += 1
            else:
                if ch == "\\" and nxt:
                    out.append("  ")
                    i += 2
                    continue
                if ch == '"':
                    mode = "code"
                    out.append(" ")
                    i += 1
                    continue
                if ch == "\n":  # 单行串不该跨行；容错当作结束
                    mode = "code"
                    out.append("\n")
                    i += 1
                    continue
                out.append(" ")
                i += 1
        elif mode == "raw":
            closing = '"' + "#" * raw_hashes
            if src.startswith(closing, i):
                mode = "code"
                out.append(" " * len(closing))
                i += len(closing)
                continue
            out.append("\n" if ch == "\n" else " ")
            i += 1
    return "".join(out)


PROTOCOL_HEADER_RE = re.compile(
    r"\bprotocol\s+([A-Za-z_][A-Za-z0-9_]*)(?:\s*:\s*([^{]*?))?\s*\{")
TYPE_HEADER_RE = re.compile(
    r"\b(?:struct|class|actor|enum)\s+([A-Za-z_][A-Za-z0-9_]*)"
    r"(?:\s*:\s*([^{]*?))?\s*\{")
EXTENSION_HEADER_RE = re.compile(
    r"\bextension\s+([A-Za-z_][A-Za-z0-9_]*)(?:\s*:\s*([^{]*?))?\s*\{")


def match_brace(src, open_index):
    """open_index 指向 '{'，返回配对 '}' 的下标；找不到返回 len(src)。"""
    depth = 0
    i = open_index
    while i < len(src):
        ch = src[i]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return len(src)


def parse_conformance_list(text):
    """把 'A, B<T>, C' 拆成名字列表（丢掉泛型实参与 `where` 子句）。"""
    if not text:
        return []
    names = []
    for part in text.split(" where ")[0].split(","):
        m = re.match(r"\s*([A-Za-z_][A-Za-z0-9_]*)", part)
        if m:
            names.append(m.group(1))
    return names


def protocol_requirements(body):
    """从一个声明体里提取「成员名」集合：func / var / let / init。

    只取名字，不看签名 —— 本脚本的定位是抓「要求整个漏掉」，
    签名层面的错误（类型、参数、throws、属性必须是 get set）它抓不到。
    """
    reqs = set()
    for m in re.finditer(r"\bfunc\s+`?([A-Za-z_][A-Za-z0-9_]*)`?\s*[<(]", body):
        reqs.add(m.group(1))
    for m in re.finditer(r"\b(?:var|let)\s+`?([A-Za-z_][A-Za-z0-9_]*)`?\s*:", body):
        reqs.add(m.group(1))
    if re.search(r"\binit\s*[?(]", body):
        reqs.add("init")
    return reqs


def collect_swift_files(roots):
    files = []
    for root in roots:
        if os.path.isfile(root) and root.endswith(".swift"):
            files.append(root)
            continue
        if not os.path.isdir(root):
            print("[swift_api_check] 路径不存在：%s" % root, file=sys.stderr)
            sys.exit(2)
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames if d not in (".build", ".git")]
            for fn in sorted(filenames):
                if fn.endswith(".swift"):
                    files.append(os.path.join(dirpath, fn))
    return sorted(files)


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    roots = argv[1:]
    files = collect_swift_files(roots)
    if not files:
        print("[swift_api_check] 没有找到 .swift 文件", file=sys.stderr)
        return 2

    stripped = {}
    for path in files:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            stripped[path] = strip_literals_and_comments(fh.read())

    declared_types, members = set(), set()
    for path, src in stripped.items():
        declared_types.update(TYPE_DECL_RE.findall(src))
        declared_types.update(TYPEALIAS_RE.findall(src))
        members.update(MEMBER_DECL_RE.findall(src))
        for item in CASE_LIST_RE.findall(src):        # `case a, b(c)` 逐个登记
            for part in item.split(","):
                m = re.match(r"\s*([A-Za-z_][A-Za-z0-9_]*)", part)
                if m:
                    members.add(m.group(1))

    if not declared_types:
        print("[swift_api_check] 没有解析出任何本工程类型声明", file=sys.stderr)
        return 2

    problems = []
    checked = 0
    for path, src in stripped.items():
        lines = src.split("\n")

        def loc(pos):
            return src.count("\n", 0, pos) + 1

        # 1) 静态引用：本工程类型.member
        for m in STATIC_REF_RE.finditer(src):
            type_name, member = m.group(1), m.group(2)
            if type_name not in declared_types:
                continue
            checked += 1
            # `A.B` 里的 B 也可能是在 A **内部**声明的嵌套类型（enum/struct/class），
            # 这类名字不会被 MEMBER_DECL_RE 收进 members，必须用 declared_types 兜住，
            # 否则 `JwxtSession.RequestOptions`、`JwxtLoginClient.Marker` 会被误报。
            if member in WHITELIST or member in members or member in declared_types:
                continue
            problems.append((path, loc(m.start()), "%s.%s" % (type_name, member)))

        # 2) 实例引用：先把变量绑定到本工程类型。
        #    同一个名字在一个文件里可能有**多处**绑定（存储属性 + 局部变量 + 形参），
        #    例如 `JwxtHTMLDocument.body: JwxtHTMLNode` 与 `parseAttributes` 里的
        #    `let body = String(...)` / `_ body: String` 同名。按名字全局猜类型必然误报，
        #    所以只在「该名字在本文件里只绑定到唯一一个类型」时才检查它的成员引用。
        #    （vars 的成员登记与静态引用那一步共用同一张 members 表。）
        bindings = {}
        for m in BINDING_RE.finditer(src):
            bindings.setdefault(m.group(1), set()).add(m.group(2))
        for m in INIT_VAR_RE.finditer(src):
            bindings.setdefault(m.group(1), set()).add(m.group(2))

        for var, type_names in bindings.items():
            if len(type_names) != 1:
                continue
            type_name = next(iter(type_names))
            if type_name not in declared_types:
                continue
            for m in re.finditer(r"\b%s\s*\.\s*([A-Za-z_][A-Za-z0-9_]*)" % re.escape(var), src):
                member = m.group(1)
                checked += 1
                if member in WHITELIST or member in members:
                    continue
                problems.append((path, loc(m.start()),
                                 "%s.%s（%s 的实例）" % (var, member, type_name)))

    # 3) 同一 target 内顶层类型重名 = 真编译器必报的 "invalid redeclaration"。
    #    只统计**顶格**声明，避免把嵌套类型误判；并按 target 分组，
    #    因为 Sources 与 Tests 是两个 target，各声明一次同名类型是合法的。
    top_type_re = re.compile(
        r"^(?:public\s+|internal\s+|private\s+|fileprivate\s+|final\s+|open\s+)*"
        r"(?:struct|class|enum|actor|protocol)\s+([A-Za-z_][A-Za-z0-9_]*)")

    def target_of(path):
        p = path.replace("\\", "/")
        for marker, prefix in (("/Sources/", ""), ("/Tests/", "test:")):
            if marker in p:
                return prefix + p.split(marker, 1)[1].split("/")[0]
        return os.path.dirname(p)

    def conditional_lines(src):
        """返回位于 #if / #elseif / #else 分支里的行号集合（1 基）。

        条件编译分支里的同名类型是**合法**的（本工程就有
        `#if canImport(Security) ... #else ... #endif` 双实现），重名检测必须跳过。
        """
        result, depth = set(), 0
        for lineno, line in enumerate(src.split("\n"), 1):
            s = line.strip()
            if s.startswith("#if"):
                depth += 1
                result.add(lineno)
            elif s.startswith("#endif"):
                result.add(lineno)
                depth = max(0, depth - 1)
            elif s.startswith("#else") or s.startswith("#elseif"):
                result.add(lineno)
            elif depth > 0:
                result.add(lineno)
        return result

    decl_sites = {}
    for path, src in stripped.items():
        cond = conditional_lines(src)
        for lineno, line in enumerate(src.split("\n"), 1):
            if lineno in cond:
                continue
            m = top_type_re.match(line)
            if m:
                decl_sites.setdefault((target_of(path), m.group(1)), []).append((path, lineno))

    duplicates = []
    for (target, name), sites in sorted(decl_sites.items()):
        if len(sites) > 1:
            where = "、".join("%s:%d" % (p, l) for p, l in sites)
            duplicates.append((sites[0][0], sites[0][1],
                               "target %s 里重复声明了类型 %s（%s）" % (target, name, where)))

    # 4) 协议一致性完整性：写了 `: P` 却漏实现 P 的某个要求，
    #    真编译器必报 "type 'X' does not conform to protocol 'P'"。
    #    实现可能分散在 extension 里，所以成员集合要跨文件按类型名汇总；
    #    协议本身用 extension 提供的默认实现也算已满足。
    pro_reqs, pro_defaults = {}, {}
    for src in stripped.values():
        for m in PROTOCOL_HEADER_RE.finditer(src):
            close = match_brace(src, m.end() - 1)
            pro_reqs.setdefault(m.group(1), set()).update(
                protocol_requirements(src[m.end():close]))
        for m in EXTENSION_HEADER_RE.finditer(src):
            name = m.group(1)
            if name in pro_reqs:
                close = match_brace(src, m.end() - 1)
                pro_defaults.setdefault(name, set()).update(
                    protocol_requirements(src[m.end():close]))

    type_members, conformance_sites = {}, []
    for path, src in stripped.items():
        for m in TYPE_HEADER_RE.finditer(src):
            close = match_brace(src, m.end() - 1)
            type_members.setdefault(m.group(1), set()).update(
                protocol_requirements(src[m.end():close]))
            conformance_sites.append((path, src.count("\n", 0, m.start()) + 1,
                                      m.group(1), parse_conformance_list(m.group(2))))
        for m in EXTENSION_HEADER_RE.finditer(src):
            name = m.group(1)
            if name in pro_reqs:
                continue
            close = match_brace(src, m.end() - 1)
            type_members.setdefault(name, set()).update(
                protocol_requirements(src[m.end():close]))
            conformance_sites.append((path, src.count("\n", 0, m.start()) + 1,
                                      name, parse_conformance_list(m.group(2))))

    conformance_problems, conformance_checked = [], 0
    for path, line, type_name, protos in conformance_sites:
        have = type_members.get(type_name, set()) | WHITELIST
        for proto in protos:
            if proto not in pro_reqs:
                continue
            conformance_checked += 1
            missing = pro_reqs[proto] - have - pro_defaults.get(proto, set())
            if missing:
                conformance_problems.append((path, line,
                    "%s 声明遵守 %s，但实现里找不到这些要求：%s"
                    % (type_name, proto, "、".join(sorted(missing)))))

    problems.sort(key=lambda p: (p[0], p[1]))
    for path, line, what in problems:
        print("[ERR] %s:%d  %s —— 在本工程里找不到声明" % (path, line, what))
    for path, line, what in duplicates:
        print("[ERR] %s:%d  %s" % (path, line, what))
    for path, line, what in conformance_problems:
        print("[ERR] %s:%d  %s" % (path, line, what))

    print("")
    print("检查文件 %d 个；核对核心成员引用 %d 处；未声明 %d 处；顶层类型重名 %d 处；"
          "核对协议一致性 %d 处、缺要求 %d 处"
          % (len(files), checked, len(problems), len(duplicates),
             conformance_checked, len(conformance_problems)))
    print("提醒：这不是编译器。它只查「成员/要求是否存在」和「类型是否重名」，")
    print("      不查类型、不查参数、不查签名、不查任何其它编译错误。")
    return 1 if (problems or duplicates or conformance_problems) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
