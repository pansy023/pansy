import Foundation

// MARK: - 为什么手写 HTML 扫描器（而不是引入 SwiftSoup）
//
// 原版 Android 端全部 HTML 解析都走 **jsoup**（`docs/recon/02-jwxt-login-and-parser.md` §1：
// 「全程只用 jsoup（`org.jsoup.Jsoup.connect`）。没有 OkHttp，没有 HttpURLConnection。」）。
// iOS 端若要 1:1 复刻 jsoup 的 CSS 选择器语义，正确做法是引入 SwiftSoup（同源的 jsoup 移植）。
//
// **但本仓库的硬约束是「不得新增 SwiftPM 依赖」（`KebiaoCore/Package.swift` 保持原样，
// 且 `swift test` 必须能离线运行）**，所以这里实现一个**范围受限、可测**的替代品：
//
// - 只用 `Foundation`（`NSRegularExpression` / `String` / `Character`），无第三方依赖；
// - 只覆盖 `JwxtTimetableParser` 实际用到的那几个 jsoup 能力，见下；
// - 支持的选择器语法**仅限**：`tag`、`#id`、`.class`、`[attr]`、`[attr=v]`、`[attr='v']`、
//   `[attr="v"]`、后代组合（空格）、直接子代（`>`）。**不支持** `:nth-child`、`+`、`~`、`*`、
//   `:not(...)`、伪元素等。
//
// 后续若允许加依赖，应整体替换为 SwiftSoup，替换点见
// `docs/recon/notes-jwxt-implementation.md`「依赖替代品的长期替代方案」一节。
//
// jsoup 行为对齐的关键点（都影响解析结果，不是风格问题）：
// 1. `Element.text()` 用 `StringUtil.normaliseWhitespace`：把 **ASCII 空白**（`\t\n\u000C\r `）
//    折叠成单个空格并 trim，**但 U+00A0（`&nbsp;`）不是 ASCII 空白，会被保留**。
//    这正是 `extractCourseName` 之后还要显式 `replace(" ", " ")` 的原因（`QiangzhiJwxtParser.java:1031`
//    的第一个字面量就是 U+00A0，不是普通空格）。
// 2. 标签名与属性名在 HTML 解析时统一小写；属性**值**与 class/id 区分大小写。
// 3. 属性缺失时 `Element.attr("x")` 返回**空字符串**（不是 nil）。
// 4. `Element.html()` 返回元素**内部**的 HTML（不含自身标签）。
//
// ⚠️ 行号引用约定（本目录所有文件一致）：注释里 `QiangzhiJwxtParser.java:NNN` 形式的行号
// 一律沿用 `docs/recon/02-jwxt-login-and-parser.md` 定义的行号体系（该文档是本阶段唯一权威）。
// 本机 `上课早枝道-源码-1.11.5/app/src/main/java/kebiaocom/example/data/QiangzhiJwxtParser.java`
// 只有 1333 行（文档头部记为 1380 行），实测存在约 150 行的整体偏移；符号名与代码内容完全一致。
// 引用时以「方法名」为准去 grep，不要用行号直接定位。

/// 一个极简的 HTML 节点。
///
/// - `tag` 为 `nil` 表示文本节点，文本在 `text`；
/// - `children` 按文档顺序保存；
/// - `parent` 是弱引用，避免 DOM 树成环。
public final class JwxtHTMLNode {
    /// 标签名（已小写）；文本节点为 nil。
    public let tag: String?
    /// 属性名（已小写）→ 属性值（已解码实体）。
    public private(set) var attributes: [String: String]
    /// 该元素在原始 HTML 中的起始偏移（`<` 的位置）。
    public let startOffset: Int
    /// 该元素在原始 HTML 中的结束偏移（`>` 之后一位）。
    public private(set) var endOffset: Int
    /// 文本节点内容（仅文本节点有值）。
    ///
    /// ⚠️ 刻意不叫 `text`：Swift 不允许同一类型里同时存在属性 `text` 与方法 `text()`，
    /// 同名会直接编译报错 `invalid redeclaration of 'text()'`（本条已由 CI 实证）。
    public let rawText: String?
    public private(set) var children: [JwxtHTMLNode] = []
    public weak var parent: JwxtHTMLNode?

    init(
        tag: String?,
        attributes: [String: String] = [:],
        text: String? = nil,
        startOffset: Int = 0,
        endOffset: Int = 0
    ) {
        self.tag = tag
        self.attributes = attributes
        self.rawText = text
        self.startOffset = startOffset
        self.endOffset = endOffset
    }

    /// 是否是元素节点（非文本）。
    public var isElement: Bool { tag != nil }

    /// 对应 jsoup `Element.attr(key)`：缺失时返回 `""`，不返回 nil。
    public func attr(_ key: String) -> String {
        attributes[key.lowercased()] ?? ""
    }

    /// 对应 jsoup `Element.text()`：按文档顺序拼接后代文本，再做 ASCII 空白归一化。
    public func text() -> String {
        guard tag != nil else { return JwxtHTMLNode.normaliseASCIIWhitespace(rawText ?? "") }
        var pieces: [String] = []
        collectText(into: &pieces)
        return JwxtHTMLNode.normaliseASCIIWhitespace(pieces.joined())
    }

    /// 对应 jsoup `Element.html()`：返回元素**内部**的 HTML 源码。
    ///
    /// 这是用原始偏移切片实现的，因此能逐字保住大小写、引号风格与实体原样
    /// ——原版大量逻辑靠 `contains("<font")`、`contains("title='教师'")` 这类
    /// **对原始 HTML 的大小写敏感/不敏感字符串判断**（`QiangzhiJwxtParser.java:239`、
    /// `:254`），所以必须拿到原始切片而不是重新序列化。
    public func innerHTML(in document: JwxtHTMLDocument) -> String {
        let source = document.source
        guard isElement, startOffset <= endOffset else { return "" }
        let openEnd = JwxtHTMLScanner.indexOfTagEnd(in: source, from: startOffset)
        guard openEnd > startOffset else { return "" }
        let innerStart = source.index(source.startIndex, offsetBy: openEnd)
        let innerEnd = source.index(source.startIndex, offsetBy: min(endOffset, source.count))
        guard innerStart < innerEnd else { return "" }
        var slice = String(source[innerStart..<innerEnd])
        // 去掉自身结束标签（`</tag>`），jsoup 的 html() 不含自身结束标签。
        if let t = tag {
            let closing = "</\(t)"
            if let range = slice.range(of: closing, options: [.backwards, .caseInsensitive]) {
                let tail = slice[range.lowerBound...]
                if tail.hasSuffix(">") { slice = String(slice[slice.startIndex..<range.lowerBound]) }
            }
        }
        return slice
    }

    private func collectText(into pieces: inout [String]) {
        if let rawText {
            pieces.append(rawText)
        }
        for child in children {
            if child.tag == nil {
                pieces.append(child.rawText ?? "")
            } else if JwxtHTMLScanner.isLineBreakTag(child.tag ?? "") {
                pieces.append(" ")
            } else {
                child.collectText(into: &pieces)
            }
        }
    }

    /// `StringUtil.normaliseWhitespace` 的等价实现。
    public static func normaliseASCIIWhitespace(_ input: String) -> String {
        var out = ""
        out.reserveCapacity(input.count)
        var pendingSpace = false
        for ch in input {
            if isASCIIWhitespace(ch) {
                pendingSpace = !out.isEmpty
            } else {
                if pendingSpace { out.append(" ") }
                pendingSpace = false
                out.append(ch)
            }
        }
        return out
    }

    /// jsoup `StringUtil.isWhitespace` 用到的正是这几个 ASCII 字符。
    public static func isASCIIWhitespace(_ ch: Character) -> Bool {
        switch ch {
        case " ", "\t", "\n", "\u{000C}", "\r":
            return true
        default:
            return false
        }
    }
}

// MARK: - 选择器

/// 解析后的单个选择器片段。
///
/// ⚠️ 不声明 `Equatable`：`attributes` 是**元组数组**
/// （`[(name: String, op: String?, value: String)]`），Swift 无法为含元组的类型合成 `==`，
/// 声明了会直接编译报错 `does not conform to protocol 'Equatable'`（已由 CI 实证）。
/// 选择器目前只在解析/匹配内部使用，没有比较需求。
public struct JwxtHTMLSelectorPart {
    /// 与**上一个**片段的关系：`.child` 表示 `>`，`.descendant` 表示空格。第一个片段恒为 `.descendant`。
    public enum Combinator: Equatable {
        case descendant
        case child
    }

    public var combinator: Combinator = .descendant
    public var tag: String?
    public var id: String?
    public var classes: [String] = []
    /// 属性断言：`(名, 比较符, 值)`。比较符为 `"="` 或 `nil`（只要求存在该属性）。
    public var attributes: [(name: String, op: String?, value: String)] = []
}

/// 一条选择器（逗号分隔的其中一支）的片段序列。
///
/// 同 `JwxtHTMLSelectorPart`：不声明 `Equatable`（元组成员无法合成 `==`）。
public struct JwxtHTMLSelector {
    /// 从**左到右**（祖先 → 后代）保存。
    public var parts: [JwxtHTMLSelectorPart]
}

// MARK: - 文档

/// 解析后的 HTML 文档。
///
/// 与 jsoup 一样，即使输入是一个片段（如 `parseBodyFragment` 的入参），
/// 也会先补出 `html` / `head` / `body` 骨架，因此 `body` 子树里能按文档顺序找到所有元素。
public final class JwxtHTMLDocument {
    /// 原始 HTML 源码（`innerHTML` 靠它做切片）。
    public let source: String
    /// 根节点（`html`）。
    public let root: JwxtHTMLNode
    /// `body` 元素。
    public let body: JwxtHTMLNode
    /// 所有元素，按文档顺序。
    public let allElements: [JwxtHTMLNode]

    /// `fileprivate` 而不是 `private`：构造只允许同文件里的 `JwxtHTMLScanner` 调用，
    /// 而 Swift 的 `private` 只覆盖「本类型 + 同文件扩展」，跨类型访问必须放宽到 `fileprivate`
    /// （CI 实证报 `initializer is inaccessible due to 'private' protection level`）。
    fileprivate init(source: String, root: JwxtHTMLNode, body: JwxtHTMLNode, allElements: [JwxtHTMLNode]) {
        self.source = source
        self.root = root
        self.body = body
        self.allElements = allElements
    }

    /// 对应 `Jsoup.parse(html)`。
    public static func parse(_ html: String) -> JwxtHTMLDocument {
        JwxtHTMLScanner.parseDocument(html)
    }

    /// 对应 `Jsoup.parseBodyFragment(fragment)` 后取 `body` 子树。
    ///
    /// 原版字段抽取器全部走这条路径（`QiangzhiJwxtParser.java:1016`、`:1070`、`:1125`、
    /// `:1159`、`:1175`），所以这里也保留 `body` 语义以便 `select` 的基准一致。
    public static func parseBodyFragment(_ fragment: String) -> JwxtHTMLDocument {
        JwxtHTMLScanner.parseDocument(fragment)
    }

    /// 对应 `Element.select(cssQuery)`，返回文档顺序的元素列表。
    public func select(_ query: String, from scope: JwxtHTMLNode? = nil) -> [JwxtHTMLNode] {
        let selectors = JwxtHTMLSelectorParser.parse(query)
        guard !selectors.isEmpty else { return [] }
        let candidates = (scope?.descendantElements() ?? allElements)
        var result: [JwxtHTMLNode] = []
        for node in candidates {
            for selector in selectors where JwxtHTMLSelectorMatcher.matches(node: node, selector: selector) {
                result.append(node)
                break
            }
        }
        return result
    }

    /// 对应 `Element.selectFirst(cssQuery)`。
    public func selectFirst(_ query: String, from scope: JwxtHTMLNode? = nil) -> JwxtHTMLNode? {
        select(query, from: scope).first
    }
}

public extension JwxtHTMLNode {
    /// 按文档顺序返回自身子树里的所有元素（含自身）。
    func descendantElements() -> [JwxtHTMLNode] {
        var out: [JwxtHTMLNode] = []
        appendDescendantElements(into: &out)
        return out
    }

    private func appendDescendantElements(into out: inout [JwxtHTMLNode]) {
        if isElement { out.append(self) }
        for child in children { child.appendDescendantElements(into: &out) }
    }
}

// MARK: - 选择器解析

enum JwxtHTMLSelectorParser {
    /// 解析 `a, b > c` 这类选择器串。
    static func parse(_ query: String) -> [JwxtHTMLSelector] {
        splitTopLevel(query, separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .compactMap { parseSingle($0) }
    }

    /// 逗号切分（属性选择器里的逗号本实现用不到，但保留括号感知以免未来踩坑）。
    private static func splitTopLevel(_ input: String, separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        for ch in input {
            if ch == "[" || ch == "(" { depth += 1 }
            if ch == "]" || ch == ")" { depth = max(0, depth - 1) }
            if ch == separator && depth == 0 {
                parts.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        parts.append(current)
        return parts
    }

    private static func parseSingle(_ selector: String) -> JwxtHTMLSelector? {
        var parts: [JwxtHTMLSelectorPart] = []
        var pendingCombinator: JwxtHTMLSelectorPart.Combinator = .descendant
        var token = ""
        var index = selector.startIndex

        func flushToken() {
            guard !token.isEmpty else { return }
            if let part = parsePart(token, combinator: pendingCombinator) {
                parts.append(part)
            }
            token = ""
            pendingCombinator = .descendant
        }

        while index < selector.endIndex {
            let ch = selector[index]
            if ch == ">" {
                flushToken()
                pendingCombinator = .child
                index = selector.index(after: index)
                continue
            }
            if ch == " " || ch == "\t" || ch == "\n" || ch == "\r" {
                flushToken()
                if pendingCombinator == .descendant { pendingCombinator = .descendant }
                index = selector.index(after: index)
                continue
            }
            token.append(ch)
            index = selector.index(after: index)
        }
        flushToken()
        guard !parts.isEmpty else { return nil }
        return JwxtHTMLSelector(parts: parts)
    }

    private static func parsePart(
        _ raw: String,
        combinator: JwxtHTMLSelectorPart.Combinator
    ) -> JwxtHTMLSelectorPart? {
        var text = raw
        // `:scope > td` 等价于 `> td`；`select("> td")` 是 jsoup 允许的写法（`QiangzhiJwxtParser.java:191`）。
        if text.hasPrefix(":scope") { text.removeFirst(":scope".count) }
        if text.isEmpty { return nil }

        var part = JwxtHTMLSelectorPart()
        part.combinator = combinator
        var index = text.startIndex

        // ① 标签名（可选）
        if let ch = text.first, ch != "." , ch != "#", ch != "[" {
            var tag = ""
            while index < text.endIndex {
                let c = text[index]
                if c == "." || c == "#" || c == "[" { break }
                tag.append(c)
                index = text.index(after: index)
            }
            if !tag.isEmpty { part.tag = tag.lowercased() }
        }

        // ② `#id` / `.class` / `[attr…]`
        while index < text.endIndex {
            let ch = text[index]
            if ch == "." || ch == "#" {
                index = text.index(after: index)
                var name = ""
                while index < text.endIndex {
                    let c = text[index]
                    if c == "." || c == "#" || c == "[" { break }
                    name.append(c)
                    index = text.index(after: index)
                }
                if ch == "#" { part.id = name } else { part.classes.append(name) }
                continue
            }
            if ch == "[" {
                guard let close = text[index...].firstIndex(of: "]") else { return nil }
                let inner = String(text[text.index(after: index)..<close])
                if let attr = parseAttributeSelector(inner) { part.attributes.append(attr) }
                index = text.index(after: close)
                continue
            }
            return nil
        }
        return part
    }

    private static let attributeSelectorRegex = try? NSRegularExpression(
        pattern: #"^\s*([A-Za-z_:][-A-Za-z0-9_:.]*)\s*(?:([~^$*|]?=)\s*(?:"([^"]*)"|'([^']*)'|([^\s\]]+)))?\s*$"#
    )

    static func parseAttributeSelector(_ inner: String) -> (name: String, op: String?, value: String)? {
        guard let regex = attributeSelectorRegex else { return nil }
        let range = NSRange(inner.startIndex..<inner.endIndex, in: inner)
        guard let match = regex.firstMatch(in: inner, options: [], range: range) else { return nil }

        func group(_ i: Int) -> String? {
            guard let r = Range(match.range(at: i), in: inner) else { return nil }
            return String(inner[r])
        }
        guard let rawName = group(1) else { return nil }
        let name = rawName.lowercased()
        let op = group(2)
        let value = group(3) ?? group(4) ?? group(5) ?? ""
        return (name, op, value)
    }
}

// MARK: - 选择器匹配

enum JwxtHTMLSelectorMatcher {
    /// 判断节点是否匹配整条选择器（含祖先链）。
    static func matches(node: JwxtHTMLNode, selector: JwxtHTMLSelector) -> Bool {
        guard let last = selector.parts.last else { return false }
        guard matchesPart(node: node, part: last) else { return false }
        return matchesAncestors(node: node, parts: selector.parts, partIndex: selector.parts.count - 1)
    }

    /// 自右向左匹配祖先片段。
    private static func matchesAncestors(
        node: JwxtHTMLNode,
        parts: [JwxtHTMLSelectorPart],
        partIndex: Int
    ) -> Bool {
        if partIndex == 0 { return true }
        let currentPart = parts[partIndex]
        let previousPart = parts[partIndex - 1]

        if currentPart.combinator == .child {
            guard let parent = node.parent, parent.isElement else { return false }
            guard matchesPart(node: parent, part: previousPart) else { return false }
            return matchesAncestors(node: parent, parts: parts, partIndex: partIndex - 1)
        }

        // 后代：从最近的祖先向外逐个尝试；只要有一条链成立即成功。
        var ancestor = node.parent
        while let candidate = ancestor, candidate.isElement {
            if matchesPart(node: candidate, part: previousPart),
               matchesAncestors(node: candidate, parts: parts, partIndex: partIndex - 1) {
                return true
            }
            ancestor = candidate.parent
        }
        return false
    }

    static func matchesPart(node: JwxtHTMLNode, part: JwxtHTMLSelectorPart) -> Bool {
        guard let tag = node.tag else { return false }
        if let want = part.tag, !want.isEmpty, tag != want { return false }
        if let id = part.id {
            guard node.attr("id") == id else { return false }
        }
        for className in part.classes {
            let classes = node.attr("class").split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
            guard classes.contains(where: { $0 == Substring(className) }) else { return false }
        }
        for attribute in part.attributes {
            let actual = node.attributes[attribute.name]
            switch attribute.op {
            case nil:
                guard actual != nil else { return false }
            case "=":
                guard (actual ?? "") == attribute.value else { return false }
            case "~=":
                guard let actual else { return false }
                let words = actual.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
                guard words.contains(where: { $0 == Substring(attribute.value) }) else { return false }
            case "^=":
                guard (actual ?? "").hasPrefix(attribute.value) else { return false }
            case "$=":
                guard (actual ?? "").hasSuffix(attribute.value) else { return false }
            case "*=":
                guard (actual ?? "").contains(attribute.value) else { return false }
            default:
                guard (actual ?? "") == attribute.value else { return false }
            }
        }
        return true
    }
}

// MARK: - 扫描器

/// 手写 HTML 扫描器：把源码切成 `JwxtHTMLNode` 树，并记录每个元素在源码中的偏移。
enum JwxtHTMLScanner {

    /// HTML 规范里的空元素（不需要闭合标签）。
    static let voidTags: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "param", "source", "track", "wbr"
    ]

    /// 内容是纯文本的元素（内部不做标签解析）。
    static let rawTextTags: Set<String> = ["script", "style"]

    /// jsoup 把 `<br>` 在 `text()` 里当作换行（本实现折叠为空格，与 `normaliseWhitespace` 一致）。
    static func isLineBreakTag(_ tag: String) -> Bool { tag == "br" }

    static func parseDocument(_ html: String) -> JwxtHTMLDocument {
        let source = html
        let htmlNode = JwxtHTMLNode(tag: "html")
        let headNode = JwxtHTMLNode(tag: "head")
        let bodyNode = JwxtHTMLNode(tag: "body")
        htmlNode.append(child: headNode)
        htmlNode.append(child: bodyNode)

        var stack: [JwxtHTMLNode] = [bodyNode]
        var allElements: [JwxtHTMLNode] = [htmlNode, headNode, bodyNode]

        var i = source.startIndex
        var offset = 0
        let count = source.count

        while i < source.endIndex {
            let ch = source[i]

            // 注释 / CDATA / 文档类型：整段跳过。
            if ch == "<", source[i...].hasPrefix("<!--") {
                let end = source.range(of: "-->", range: i..<source.endIndex)?.upperBound ?? source.endIndex
                offset += source.distance(from: i, to: end)
                i = end
                continue
            }
            if ch == "<", source[i...].hasPrefix("<![CDATA[") {
                if let close = source.range(of: "]]>", range: i..<source.endIndex)?.upperBound {
                    let innerStart = source.index(i, offsetBy: 9)
                    let innerEnd = source.index(close, offsetBy: -3)
                    if innerStart < innerEnd {
                        appendText(String(source[innerStart..<innerEnd]), offset: offset, to: stack.last)
                    }
                    offset += source.distance(from: i, to: close)
                    i = close
                    continue
                }
            }
            if ch == "<", source[i...].hasPrefix("<!") {
                let end = source.range(of: ">", range: i..<source.endIndex)?.upperBound ?? source.endIndex
                offset += source.distance(from: i, to: end)
                i = end
                continue
            }

            if ch == "<" {
                if source[i...].hasPrefix("</") {
                    // 结束标签
                    let nameStart = source.index(i, offsetBy: 2)
                    let nameEnd = readTagName(source, from: nameStart)
                    let name = String(source[nameStart..<nameEnd]).lowercased()
                    let end = indexOfTagEnd(source, from: i)
                    let newOffset = offset + source.distance(from: i, to: end)
                    if let closeIndex = stack.lastIndex(where: {
                        $0.tag == name && $0.tag != "html" && $0.tag != "head" && $0.tag != "body"
                    }) {
                        // 关闭到（含）该元素：弹出它及其未闭合的子元素。
                        let closed = stack[closeIndex]
                        closed.setEndOffset(offset + source.distance(from: i, to: end))
                        if closeIndex > 0 {
                            stack.removeSubrange(closeIndex...)
                        }
                    }
                    offset = newOffset
                    i = end
                    continue
                }

                // 开始标签（也可能是文本里的裸 `<`）
                let nameStart = source.index(i, offsetBy: 1)
                let nameEnd = readTagName(source, from: nameStart)
                let name = String(source[nameStart..<nameEnd]).lowercased()
                guard !name.isEmpty, name.first.map({ $0.isLetter }) == true else {
                    // 不是标签，当普通文本处理（jsoup 也会这么做）。
                    appendText("<", offset: offset, to: stack.last)
                    offset += 1
                    i = source.index(after: i)
                    continue
                }

                let tagEnd = indexOfTagEnd(source, from: i)
                // `tagEnd` 是 `String.Index`，而节点的 `endOffset` 是 Int 偏移量，
                // 必须经 `distance(from:to:)` 换算（原先直接把 Index 传给了 Int 形参，编译报错）。
                let tagLength = source.distance(from: i, to: tagEnd)
                let attributes = parseAttributes(source, tagNameEnd: nameEnd, tagEnd: tagEnd)
                let node = JwxtHTMLNode(
                    tag: name,
                    attributes: attributes,
                    startOffset: offset,
                    endOffset: offset + tagLength
                )
                stack.last?.append(child: node)
                allElements.append(node)

                let selfClosing = isSelfClosing(source, tagEnd: tagEnd)
                offset += tagLength
                i = tagEnd

                if selfClosing || voidTags.contains(name) {
                    node.setEndOffset(offset)
                    continue
                }

                if rawTextTags.contains(name) {
                    // 原样吃到 </name>，避免把 JS/CSS 里的 `<` 当标签。
                    let closing = "</\(name)"
                    if let range = source.range(of: closing, options: [.caseInsensitive], range: i..<source.endIndex) {
                        let textEnd = range.lowerBound
                        if i < textEnd {
                            let raw = String(source[i..<textEnd])
                            node.append(child: JwxtHTMLNode(tag: nil, text: raw, startOffset: offset, endOffset: offset + source.distance(from: i, to: textEnd)))
                            offset += source.distance(from: i, to: textEnd)
                        }
                        i = range.upperBound
                        continue
                    }
                    stack.append(node)
                    continue
                }

                stack.append(node)
                continue
            }

            // 文本
            let nextLt = source[i...].firstIndex(of: "<") ?? source.endIndex
            let raw = String(source[i..<nextLt])
            appendText(JwxtHTMLScanner.decodeEntities(raw), offset: offset, to: stack.last)
            offset += source.distance(from: i, to: nextLt)
            i = nextLt
        }

        return JwxtHTMLDocument(source: source, root: htmlNode, body: bodyNode, allElements: allElements)
    }

    /// 找到从 `from`（必须指向 `<`）开始的标签的 `>` 之后一位；找不到则返回源码末尾。
    static func indexOfTagEnd(in source: String, from: Int) -> Int {
        let start = source.index(source.startIndex, offsetBy: min(max(0, from), source.count))
        // 下面调用的重载返回 `String.Index`，而本函数声明返回 Int 偏移量，必须换算回去
        // （原先直接 `return` 该重载的结果，编译报「无法把 String.Index 转成 Int」）。
        let end = indexOfTagEnd(source, from: start)
        return source.distance(from: source.startIndex, to: end)
    }

    private static func indexOfTagEnd(_ source: String, from start: String.Index) -> String.Index {
        var i = start
        var quote: Character?
        while i < source.endIndex {
            let c = source[i]
            if let q = quote {
                if c == q { quote = nil }
            } else if c == "'" || c == "\"" {
                quote = c
            } else if c == ">" {
                return source.index(after: i)
            }
            i = source.index(after: i)
        }
        return source.endIndex
    }

    private static func isSelfClosing(_ source: String, tagEnd: String.Index) -> Bool {
        // tagEnd 指向 `>` 之后一位；检查它前面是否是 `/>`。
        let end = source.index(before: tagEnd)
        var i = end
        while i > source.startIndex {
            i = source.index(before: i)
            let c = source[i]
            if c == " " || c == "\t" || c == "\n" || c == "\r" { continue }
            return c == "/"
        }
        return false
    }

    /// 读取标签名区域（到空白、`/`、`>` 或行尾为止）。
    private static func readTagName(_ source: String, from start: String.Index) -> String.Index {
        var i = start
        while i < source.endIndex {
            let c = source[i]
            if c == " " || c == "\t" || c == "\n" || c == "\r" || c == "/" || c == ">" { break }
            i = source.index(after: i)
        }
        return i
    }

    private static func parseAttributes(
        _ source: String,
        tagNameEnd: String.Index,
        tagEnd: String.Index
    ) -> [String: String] {
        var attributes: [String: String] = [:]
        // 去掉 `<name` 之后、`>` 之前的部分，并剥掉可能的结尾 `/`。
        var bodyEnd = source.index(before: tagEnd)
        if bodyEnd > tagNameEnd, source[source.index(before: bodyEnd)] == "/" {
            bodyEnd = source.index(before: bodyEnd)
        }
        guard tagNameEnd < bodyEnd else { return attributes }
        let body = String(source[tagNameEnd..<bodyEnd])

        var i = body.startIndex
        while i < body.endIndex {
            // 跳过分隔空白
            while i < body.endIndex, JwxtHTMLNode.isASCIIWhitespace(body[i]) || body[i] == "/" {
                i = body.index(after: i)
            }
            guard i < body.endIndex else { break }

            var name = ""
            while i < body.endIndex, body[i] != "=",
                  !JwxtHTMLNode.isASCIIWhitespace(body[i]), body[i] != "/" {
                name.append(body[i])
                i = body.index(after: i)
            }
            // 跳到 `=`
            while i < body.endIndex, JwxtHTMLNode.isASCIIWhitespace(body[i]) {
                i = body.index(after: i)
            }
            var value = ""
            if i < body.endIndex, body[i] == "=" {
                i = body.index(after: i)
                while i < body.endIndex, JwxtHTMLNode.isASCIIWhitespace(body[i]) {
                    i = body.index(after: i)
                }
                if i < body.endIndex, body[i] == "\"" || body[i] == "'" {
                    let quote = body[i]
                    i = body.index(after: i)
                    var raw = ""
                    while i < body.endIndex, body[i] != quote {
                        raw.append(body[i])
                        i = body.index(after: i)
                    }
                    if i < body.endIndex { i = body.index(after: i) }
                    value = decodeEntities(raw)
                } else {
                    var raw = ""
                    while i < body.endIndex, !JwxtHTMLNode.isASCIIWhitespace(body[i]), body[i] != ">" {
                        raw.append(body[i])
                        i = body.index(after: i)
                    }
                    value = decodeEntities(raw)
                }
            }
            if !name.isEmpty {
                attributes[name.lowercased()] = value
            }
        }
        return attributes
    }

    private static func appendText(_ raw: String, offset: Int, to parent: JwxtHTMLNode?) {
        guard let parent, !raw.isEmpty else { return }
        let node = JwxtHTMLNode(tag: nil, text: raw, startOffset: offset, endOffset: offset + raw.count)
        parent.append(child: node)
    }

    // MARK: 实体解码

    static let namedEntities: [String: String] = [
        "nbsp": "\u{00A0}",
        "amp": "&",
        "lt": "<",
        "gt": ">",
        "quot": "\"",
        "apos": "'",
        "copy": "\u{00A9}",
        "reg": "\u{00AE}",
        "hellip": "\u{2026}",
        "mdash": "\u{2014}",
        "ndash": "\u{2013}",
        "ldquo": "\u{201C}",
        "rdquo": "\u{201D}",
        "lsquo": "\u{2018}",
        "rsquo": "\u{2019}",
        "middot": "\u{00B7}",
        "times": "\u{00D7}",
        "divide": "\u{00F7}",
        "deg": "\u{00B0}",
        "laquo": "\u{00AB}",
        "raquo": "\u{00BB}",
        "yen": "\u{00A5}",
        "sect": "\u{00A7}",
        "para": "\u{00B6}",
        "bull": "\u{2022}",
        "dagger": "\u{2020}",
        "prime": "\u{2032}",
        "Prime": "\u{2033}",
        "minus": "\u{2212}",
        "ne": "\u{2260}",
        "le": "\u{2264}",
        "ge": "\u{2265}",
        "sp": " ",
        "ensp": "\u{2002}",
        "emsp": "\u{2003}",
        "thinsp": "\u{2009}",
        "zwnj": "\u{200C}",
        "zwj": "\u{200D}",
        "lrm": "\u{200E}",
        "rlm": "\u{200F}"
    ]

    private static let entityRegex = try? NSRegularExpression(
        pattern: #"&(#[0-9]+|#[xX][0-9A-Fa-f]+|[A-Za-z][A-Za-z0-9]*);"#
    )

    /// 解码 HTML 实体。
    ///
    /// 注意 `&nbsp;` 解码为 U+00A0 —— 与原版后续 `replace("\u{00A0}", " ")` 的写法吻合
    /// （`QiangzhiJwxtParser.java:1031`、`:1162`）。
    static func decodeEntities(_ input: String) -> String {
        guard input.contains("&"), let regex = entityRegex else { return input }
        let ns = input as NSString
        let matches = regex.matches(in: input, options: [], range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return input }

        var out = ""
        var cursor = 0
        for match in matches {
            if match.range.location > cursor {
                out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            }
            let whole = ns.substring(with: match.range)
            let body = String(whole.dropFirst().dropLast())
            if let decoded = decodeEntityBody(body) {
                out += decoded
            } else {
                out += whole
            }
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            out += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
        }
        return out
    }

    private static func decodeEntityBody(_ body: String) -> String? {
        if body.hasPrefix("#") {
            let hex = body.hasPrefix("#x") || body.hasPrefix("#X")
            let digits = String(body.dropFirst(hex ? 2 : 1))
            guard let value = UInt32(digits, radix: hex ? 16 : 10), let scalar = Unicode.Scalar(value) else {
                return nil
            }
            return String(Character(scalar))
        }
        if let named = namedEntities[body] { return named }
        // 常见的大写写法回退（HTML 实体名本身区分大小写，这里只兜底极少见的全大写输入）。
        if let named = namedEntities[body.lowercased()], body.lowercased() != "prime" { return named }
        return nil
    }
}

// MARK: - 文本清理（与原版正则逐字对应）

/// 原版里反复出现的几个字符串清理正则，集中在这里以免各处漂移。
public enum JwxtHTMLText {

    private static let tagRegex = try? NSRegularExpression(pattern: "<[^>]+>")
    private static let brRegex = try? NSRegularExpression(pattern: "<br\\s*/?>", options: [.caseInsensitive])

    /// 对应 Kotlin `new Regex("<[^>]+>").replace(str, "")`（`QiangzhiJwxtParser.java:884`、`:1152`）。
    public static func strippingTags(_ input: String) -> String {
        replaceAll(tagRegex, in: input, with: "")
    }

    /// 对应 `new Regex("<br\\s*/?>", IGNORE_CASE).replace(str, replacement)`（`:884`、`:1227`）。
    public static func replacingLineBreaks(_ input: String, with replacement: String) -> String {
        replaceAll(brRegex, in: input, with: replacement)
    }

    static func replaceAll(_ regex: NSRegularExpression?, in input: String, with replacement: String) -> String {
        guard let regex, !input.isEmpty else { return input }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        return regex.stringByReplacingMatches(in: input, options: [], range: range, withTemplate: replacement)
    }
}

// MARK: - DOM 辅助

extension JwxtHTMLNode {
    func append(child: JwxtHTMLNode) {
        child.parent = self
        children.append(child)
    }

    func setEndOffset(_ value: Int) {
        endOffset = value
    }
}

// MARK: - 门面

/// `JwxtLoginClient` 直接调用的两个入口，对应原版的两次 jsoup 调用：
/// - `Jsoup.parse(body).text()`（`QiangzhiJwxtParser$login$2.java:210-217`）
/// - `Jsoup.parse(body).select("title").text()`（`:232`）
///
/// ⚠️ 这两个函数原先**没有实现** —— `JwxtLoginClient.swift:254`、`:368` 引用了并不存在的
/// 类型 `JwxtHTML`，CI 编译报 `cannot find 'JwxtHTML' in scope`。这里严格按上面两处原版调用
/// 的语义补齐，不新增任何原版没有的行为。
public enum JwxtHTML {

    /// 对应 `Jsoup.parse(html).text()`：整篇文档归一化后的文本。
    ///
    /// 取 `root`（`html`）的 `text()`，与 jsoup `Document.text()` 的定义一致
    /// （`<head>` 下的文本同样计入）。原版用它做成功/失败串判定（`:227-229`）。
    public static func plainText(_ html: String) -> String {
        JwxtHTMLDocument.parse(html).root.text()
    }

    /// 对应 `Jsoup.parse(html).select("title").text()`：取第一个 `<title>` 的元素文本。
    ///
    /// 没有 `<title>` 时返回空串，对齐原版 `str5` 的初值 `""`（`:233-234`）。
    public static func title(_ html: String) -> String {
        JwxtHTMLDocument.parse(html).selectFirst("title")?.text() ?? ""
    }
}
