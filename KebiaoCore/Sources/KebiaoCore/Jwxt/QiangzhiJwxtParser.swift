import Foundation

/// 强智教务（Qiangzhi JWXT）**课表抓取 + 解析**。
///
/// 逐块移植 Android 1.11.5 `kebiaocom/example/data/QiangzhiJwxtParser.java` 的
/// `fetchTimetable` / `parseDoStyle` / `parseWakeUpStyle` / `parseKbContent` /
/// 字段抽取器 / 周次节次 / `mergeDuplicateCourses` / `collapseAdjacentCourses`。
///
/// 权威规格：`docs/recon/02-jwxt-login-and-parser.md`（§4 抓取、§4.3/§4.4 两种风格、
/// §4.6 课程块、§4.7 字段抽取、§5 周次节次、§7.2 两层去重、§9 Course 构造顺序）。
/// 注释里的 `:NNN` 行号沿用该文档的行号体系（以方法名为准）。
///
/// ## 与原版刻意不同的地方（都不是自由发挥，逐条在此登记）
///
/// 1. **`> td` 的选择器实现**：`JwxtHTML` 的选择器引擎把首段的 `.child` 组合符
///    （`:325-326` 的 `parseSingle` → `matchesAncestors` 在 `partIndex == 0` 时不再向上看）
///    退化成后代选择，而原版是 jsoup 语义的**直接子元素**（`:191`）。
///    这里改用 `row.children.filter { $0.tag == "td" }` 精确表达 `> td`，结果与原版一致。
/// 2. **Kotlin `trim` / `isBlank` 等价物**：Kotlin 的 `Char.isWhitespace()`（JVM 委托
///    `Character.isWhitespace`）**不把 U+00A0（NBSP）当空白**，而 Swift 的
///    `CharacterSet.whitespaces` 与 `Character.isWhitespace` 都把 NBSP 当空白。
///    直接用会在「末尾带 NBSP 的课名」这类输入上与 Android 分叉，因此本文件用
///    `kotlinTrim` / `isBlank` 两个显式排除 NBSP 的实现。
/// 3. **风格 B 的两处 jadx 反编译错乱**（recon doc §11 第 7 条明确「不要照抄」）：
///    见 `parseWakeUpStyle` 内的 `有意差异` 注释。
/// 4. **抓课表失败时抛 `JwxtFetchError`，不再静默返回空表**（`fetchTimetable`）：
///    Android 原版在两种情况下**返回空数组** —— 会话失效（`:104-111`）与两种风格都没命中
///    （`:112-125`）。调用方无法区分「这学期真的没课」与「抓取失败」，真机上表现为
///    设置页弹一句「未获取到课表数据；已保留本地原有课程。」，排查时毫无线索。
///    实测（2026-10）已证明 iOS 上原版判据是**死代码**：未认证时服务端对
///    `GET /jsxsd/xskb/xskb_list.do` 直接返回 **200 + 登录页**（`<title>登录</title>`，
///    无 302、无 `Location`），但判据是「最终 URL 或 `Location` 含 `Login`」→ 永不命中
///    → 会话失效被静默吞掉。因此 iOS 侧改为**显式抛错并附带证据串**
///    （status / title / len / 特征串），让失败原因可读、可修。
///    另新增 `parseDoStyleRelaxed` 兜底：`table#timetable` 没命中时再遍历所有 `table`，
///    属严格超集（只在原版结果为空时才启用），用于页面结构漂移时的自愈。
public final class QiangzhiJwxtParser: @unchecked Sendable {

    /// 与原版 `TAG` 一致的日志标签（`:61`）。
    public static let tag = "QiangzhiJwxtParser"

    /// 抓课表的固定路径：`GET {secureBaseUrl}/jsxsd/xskb/xskb_list.do`，
    /// **零查询参数**（`fetchTimetable$2.java:79`；recon doc §4.1）。
    public static let timetablePath = "/jsxsd/xskb/xskb_list.do"

    /// 导入配色的 10 个 ARGB 值，逐字取自 `QiangzhiJwxtParser.java:63`。
    public static let palette: [Int] = [
        -11751600, -14575885, -26624, -6543440, -16728876,
        -43230, -8825528, -10453621, -12627531, -1499549,
    ]

    /// 与会话层共用（Cookie / Referer / 编码都在它里面）。
    public let session: JwxtSession

    /// 可选日志出口。原版走 `LogManager`；iOS 端不新增日志基础设施，默认丢弃。
    private let log: (@Sendable (String) -> Void)?

    public init(session: JwxtSession, log: (@Sendable (String) -> Void)? = nil) {
        self.session = session
        self.log = log
    }

    /// 便捷构造：直接给教务根地址（等价原版 `QiangzhiJwxtParser(baseUrl, logManager)`）。
    public convenience init(
        baseURL: String,
        log: (@Sendable (String) -> Void)? = nil,
        configuration: URLSessionConfiguration? = nil
    ) {
        self.init(session: JwxtSession(baseURL: baseURL, configuration: configuration), log: log)
    }

    // MARK: - 抓取（recon doc §4.1、§4.2）

    /// 拉取并解析课表。
    ///
    /// 完整行为（逐条对齐 `QiangzhiJwxtParser$fetchTimetable$2.java`，最后一处为有意差异）：
    /// 1. `GET {secureBaseUrl}/jsxsd/xskb/xskb_list.do`，Referer =
    ///    `timetableReferer ?? {base}/jsxsd/framework/xsMainV.htmlx`，带登录后累积的 Cookie；
    /// 2. **会话失效判定改为基于正文**（见文件头「有意差异 4」）→ 抛
    ///    `JwxtFetchError.sessionExpired`；
    /// 3. 先 `parseDoStyle`，空则 `parseDoStyleRelaxed`（新增兜底），再空则 `parseWakeUpStyle`；
    ///    仍空 **抛** `JwxtFetchError.pageStructureUnsupported`（不静默返回空表）；
    /// 4. `mergeDuplicateCourses` → `collapseAdjacentCourses` → 返回后者（`:127-128`）。
    public func fetchTimetable() async throws -> [Course] {
        let url = session.secureBaseURL + QiangzhiJwxtParser.timetablePath
        let referer = session.timetableReferer
            ?? (session.secureBaseURL + JwxtLoginClient.mainFramePath)
        let response = try await session.send(
            url,
            options: JwxtSession.RequestOptions(
                method: "GET",
                headers: [
                    "Referer": referer,
                    "User-Agent": JwxtSession.userAgent,
                ]
            )
        )

        let finalURL = response.finalURL?.absoluteString ?? url
        let body = response.body

        // 会话失效：**按正文判定**，只信最终 URL / Location 会漏（文件头「有意差异 4」）。
        if QiangzhiJwxtParser.isLoginPage(
            body: body,
            finalURL: finalURL,
            location: response.locationHeader
        ) {
            log?("Session已过期，需要重新登录（服务端直接返回登录页，未重定向）")
            throw JwxtFetchError.sessionExpired(diagnostic: QiangzhiJwxtParser.diagnose(response))
        }

        var parsed = parseDoStyle(body)
        if parsed.isEmpty { parsed = parseDoStyleRelaxed(body) }
        if parsed.isEmpty { parsed = parseWakeUpStyle(body) }
        guard !parsed.isEmpty else {
            log?("未命中可用课表解析规则")
            throw JwxtFetchError.pageStructureUnsupported(
                diagnostic: QiangzhiJwxtParser.diagnose(response)
            )
        }
        return QiangzhiJwxtParser.collapseAdjacentCourses(
            QiangzhiJwxtParser.mergeDuplicateCourses(parsed)
        )
    }

    // MARK: - 抓取失败判定与诊断（文件头「有意差异 4」）

    /// 判定「抓课表那一跳拿到的是登录页」。
    ///
    /// 实测（2026-10）：未认证时 `GET /jsxsd/xskb/xskb_list.do` 返回 **HTTP 200 + 登录页**，
    /// 无 302、无 `Location`；`/jsxsd/framework/xsMainV.htmlx` 同样。因此原版
    /// 「302 且 `Location` 含 `Login`」的判据在 iOS 上**永不命中**，必须补上基于正文的判据。
    static func isLoginPage(body: String, finalURL: String, location: String?) -> Bool {
        if finalURL.contains("Login") { return true }
        if let location, location.contains("Login") { return true }
        // 真正课表页的特征（任一命中即认为不是登录页）。
        let hasTimetableMarkers = body.contains("id=\"timetable\"")
            || body.contains("id='timetable'")
            || body.contains("Table1")
            || body.contains("kbcontent")
        guard !hasTimetableMarkers else { return false }
        // 登录页特征：登录表单动作或账号输入框名。
        return body.contains("Logon.do?method=logon") || body.contains("userAccount")
    }

    /// 一次失败抓取的证据串（拼进错误文案与日志，避免再次出现「无 clue」的失败）。
    static func diagnose(_ response: JwxtSession.Response) -> String {
        let title = JwxtHTML.title(response.body)
        let hasTimetableId = response.body.contains("id=\"timetable\"")
            || response.body.contains("id='timetable'")
        let hasTable1 = response.body.contains("Table1")
        let hasKbcontent = response.body.contains("kbcontent")
        return "status=\(response.statusCode)"
            + " title=\(title.isEmpty ? "(无)" : title)"
            + " len=\(response.body.count)"
            + " hasTimetableId=\(hasTimetableId)"
            + " hasTable1=\(hasTable1)"
            + " hasKbcontent=\(hasKbcontent)"
    }

    // MARK: - 风格 A：parseDoStyle（recon doc §4.3）

    /// DO 风格（旧版强智）：选择器 `table#timetable`。
    ///
    /// 逐字对应 `QiangzhiJwxtParser.java:169-227`：
    /// - 行：`table#timetable` 下所有 `tr`，**只有** `<th>` 文本去空格后同时含「第」与「大节」
    ///   才计为一个大节行；大节序号先自增再用，因此**从 1 开始**（`:190`）；
    /// - 列：该行的直接子 `td`，序号 `i3 = i2 + 1`，只有 `1 <= i3 < 8` 才处理
    ///   → **列 1…7 = 周一…周日**（列 0 是节次标签列，被跳过，`:200`）；
    /// - 单元格：`extractDoCellContent` 非空才解析（`:202-206`）。
    public func parseDoStyle(_ html: String) -> [Course] {
        let document = JwxtHTMLDocument.parse(html)
        guard let table = document.selectFirst("table#timetable") else { return [] }
        return parseDoStyleTable(table, in: document)
    }

    /// **宽松兜底**（文件头「有意差异 4」）：`table#timetable` 没命中时，遍历文档里**所有**
    /// `table`，返回第一个能解析出课程的结果。
    ///
    /// 这是 `parseDoStyle` 的**严格超集** —— 只在原版选择器返回空时才被调用，
    /// 因此不可能改变任何原本能解析成功的结果；唯一作用是页面结构漂移
    /// （如 `id="timetable"` 改名、或课表被包进另一张表）时仍能拿到课程。
    public func parseDoStyleRelaxed(_ html: String) -> [Course] {
        let document = JwxtHTMLDocument.parse(html)
        for table in document.select("table") {
            let courses = parseDoStyleTable(table, in: document)
            if !courses.isEmpty { return courses }
        }
        return []
    }

    /// 单张表格的 DO 风格解析主体（`QiangzhiJwxtParser.java:169-227`）。
    ///
    /// 从 `parseDoStyle` 里原样拆出，供严格选择器与宽松兜底共用，避免两份实现漂移。
    private func parseDoStyleTable(_ table: JwxtHTMLNode, in document: JwxtHTMLDocument) -> [Course] {
        let rows = document.select("tr", from: table)
        guard !rows.isEmpty else { return [] }

        var out: [Course] = []
        var periodRow = 0
        for row in rows {
            // `:183-188`：取 th 文本，**去掉所有 ASCII 空格**。
            // 选择器必须限定在**本行**内（jsoup 的 `row.selectFirst("th")` 只看该元素子树）。
            let header = (document.selectFirst("th", from: row)?.text() ?? "")
                .replacingOccurrences(of: " ", with: "")
            guard header.contains("第"), header.contains("大节") else { continue }
            periodRow += 1

            // `:191` 的 `element.select("> td")` —— 直接子 td（见文件头「有意差异 1」）。
            let cells = row.children.filter { $0.tag == "td" }
            for (offset, cell) in cells.enumerated() {
                let dayOfWeek = offset + 1
                guard dayOfWeek >= 1, dayOfWeek < 8 else { continue }
                let content = extractDoCellContent(cell, in: document)
                guard !QiangzhiJwxtParser.isBlank(content) else { continue }
                out.append(contentsOf: parseKbContent(content, periodRow: periodRow, dayOfWeek: dayOfWeek))
            }
        }
        return out
    }

    /// 单元格内容提取（`QiangzhiJwxtParser.java:229-292`，recon doc §4.3）。
    ///
    /// 1. `td.select("div.kbcontent")`，只留 `innerHTML` **忽略大小写含 `<font`** 的；
    /// 2. 优先取 `innerHTML` 含 `title='教师'` / `title="教师"` / `title=教师` 的那个，否则取第一个；
    /// 3. `trim` 后非空且 ≠ 字面量 `&nbsp;` → 返回；
    /// 4. 否则同样的「含 `<font`」逻辑走 `div.kbcontent1`；都不满足返回 `""`（`:270-291`）。
    public func extractDoCellContent(_ td: JwxtHTMLNode, in document: JwxtHTMLDocument) -> String {
        let candidates = document.select("div.kbcontent", from: td).map { $0.innerHTML(in: document) }
            .filter { $0.range(of: "<font", options: .caseInsensitive) != nil }

        var chosen: String?
        for html in candidates
        where html.contains("title='教师'") || html.contains("title=\"教师\"") || html.contains("title=教师") {
            chosen = html
            break
        }
        if chosen == nil { chosen = candidates.first }

        let trimmed = QiangzhiJwxtParser.kotlinTrim(chosen ?? "")
        if !QiangzhiJwxtParser.isBlank(trimmed), trimmed != "&nbsp;" {
            return trimmed
        }

        for node in document.select("div.kbcontent1", from: td) {
            let html = node.innerHTML(in: document)
            guard html.range(of: "<font", options: .caseInsensitive) != nil else { continue }
            let fallback = QiangzhiJwxtParser.kotlinTrim(html)
            if QiangzhiJwxtParser.isBlank(fallback) || fallback == "&nbsp;" { return "" }
            return fallback
        }
        return ""
    }

    // MARK: - 风格 B：parseWakeUpStyle（recon doc §4.4，兜底）

    /// WakeUp 风格（纯字符串切片兜底）。逐字对应 `QiangzhiJwxtParser.java:311-616`。
    ///
    /// - 定位 `"Table1"` → 其后第一个 `>` → 其后第一个 `</table>`，取中间内容（`:324-336`）；
    /// - 逐个 `<tr>`…`</tr>` 切片，只处理含标记 `left=100,top=50')\">` 的行（`:342-348`）；
    /// - 大节号 = `">第"` 之后到 `"节"` 之间的整数（`:349-355`）；
    /// - 单元格：标记后 19 个字符起、到首个 `</td>` 止（`:361-367`），再按 `<br>` 分段；
    /// - 星期由 `^(周)[一二三四五六日]` 取（`:379-431`），取不到或不在 1…7 时用 1（`:433`）；
    /// - 节数：`节/周` 前一位数字 / 逗号个数 + 1 / 兜底 1（`:443-452`）；
    /// - 周次：`extractWakeUpStartWeek` / `extractWakeUpEndWeek`（`:768-793`）。
    ///
    /// **有意差异（jadx 反编译错乱，recon doc §11 第 7 条要求不要照抄）**：
    /// - `:438-439` 的 `if (contains("单周")) { contains("双周") ? 2 : 0 } else { 1 }`
    ///   与 `:651-654`（`if (contains("单周")) 1 else (contains("双周") ? 2 : 0)`）自相矛盾；
    ///   本实现采用与 `:651-654`、以及与风格 A `parseWeekMeta` 一致的自洽语义：
    ///   **`单周` → 1，`双周` → 2，都没有 → 0**。
    /// - `:443` / `:597` 的 `if (!contains("节/周"))` 守卫被取反，本实现按自洽语义取
    ///   **`contains("节/周")` 为真分支**。
    public func parseWakeUpStyle(_ html: String) -> [Course] {
        guard let table1 = html.range(of: "Table1") else { return [] }
        guard let open = html.range(of: ">", range: table1.upperBound..<html.endIndex) else { return [] }
        guard let close = html.range(of: "</table>", range: open.upperBound..<html.endIndex) else { return [] }
        let table = String(html[open.upperBound..<close.lowerBound])

        var out: [Course] = []
        var cursor = table.startIndex
        while true {
            guard let trOpen = table.range(of: "<tr>", range: cursor..<table.endIndex),
                  let trClose = table.range(of: "</tr>", range: trOpen.upperBound..<table.endIndex)
            else { return out }
            let row = String(table[trOpen.lowerBound..<trClose.lowerBound])
            cursor = trClose.upperBound

            guard row.contains(QiangzhiJwxtParser.cellMarker) else { continue }
            guard let di = row.range(of: ">第"),
                  let jie = row.range(of: "节", range: di.upperBound..<row.endIndex)
            else { continue }
            guard let periodRow = Int(row[di.upperBound..<jie.lowerBound]) else { continue }

            let day = QiangzhiJwxtParser.wakeUpDay(in: row, marker: QiangzhiJwxtParser.cellMarker)
            out.append(contentsOf: QiangzhiJwxtParser.wakeUpCells(
                in: row, periodRow: periodRow, day: day
            ))
        }
    }

    /// 单元格标记常量（`:321`、`:985`；长度 19）。
    static let cellMarker = "left=100,top=50')\">"

    /// 逐个单元格块解析（`QiangzhiJwxtParser.java:360-508` 的内层循环）。
    private static func wakeUpCells(in row: String, periodRow: Int, day: Int) -> [Course] {
        var out: [Course] = []
        var cursor = row.startIndex
        while true {
            guard let marker = row.range(of: cellMarker, range: cursor..<row.endIndex) else { break }
            guard let tdEnd = row.range(of: "</td>", range: marker.upperBound..<row.endIndex) else { break }
            let block = String(row[marker.upperBound..<tdEnd.lowerBound])
            cursor = tdEnd.upperBound

            let lines = block.components(separatedBy: "<br>")
            guard lines.count >= 2 else { continue }

            let detail = lines[1]
            let periodCount = wakeUpPeriodCount(detail)
            let startWeek = extractWakeUpStartWeek(detail) ?? 1
            let endWeek = extractWakeUpEndWeek(detail) ?? 20
            let isOdd = wakeUpParity(detail)
            let weekRange = "\(startWeek)-\(endWeek)"
            let name = kotlinTrim(lines[0])
            let endPeriod = periodRow + periodCount - 1

            if lines.count == 3 {
                // `:456-460`：`split.size() < 4` 分支 —— teacher = lines[2]，location = lines[3]。
                // 注意原版此处直接取 `lines[3]`，size == 2 时会抛异常并被外层 catch 吞成空表；
                // 本实现把 size == 2 显式归为「跳过该块」，不复制那个崩溃路径（已在测试中固定）。
                guard lines.count >= 4 || lines.indices.contains(3) else { continue }
                out.append(Course(
                    id: 0,
                    name: name,
                    teacher: kotlinTrim(lines[2]),
                    location: kotlinTrim(lines[3]),
                    dayOfWeek: day,
                    startPeriod: periodRow,
                    endPeriod: endPeriod,
                    color: getStableColor(name),
                    weekRange: weekRange,
                    startWeek: startWeek,
                    endWeek: endWeek,
                    isOdd: isOdd
                ))
            } else if lines.count > 3 {
                // `:461-481`：`split.size() >= 3` 分支 —— 从 lines[2] 里拆「教师/地点(教室)」。
                let raw = lines[2]
                let pieces = raw.components(separatedBy: "/")
                var second = pieces.count > 1 ? pieces[1] : ""
                if second.contains("(") {
                    let teacher = kotlinTrim(second.components(separatedBy: "(").first ?? "")
                    let location = kotlinTrim(second.components(separatedBy: "(").dropFirst().joined(separator: "("))
                    out.append(Course(
                        id: 0,
                        name: name,
                        teacher: teacher,
                        location: location,
                        dayOfWeek: day,
                        startPeriod: periodRow,
                        endPeriod: endPeriod,
                        color: getStableColor(name),
                        weekRange: weekRange,
                        startWeek: startWeek,
                        endWeek: endWeek,
                        isOdd: isOdd
                    ))
                } else {
                    if isBlank(second) { second = pieces.first ?? "" }
                    out.append(Course(
                        id: 0,
                        name: name,
                        teacher: kotlinTrim(second),
                        location: "",
                        dayOfWeek: day,
                        startPeriod: periodRow,
                        endPeriod: endPeriod,
                        color: getStableColor(name),
                        weekRange: weekRange,
                        startWeek: startWeek,
                        endWeek: endWeek,
                        isOdd: isOdd
                    ))
                }
            }

            // `:483-488`：同一单元格里若还有标记，走 parseWakeUpLater 拆连排课。
            if row.range(of: cellMarker, range: tdEnd.upperBound..<row.endIndex) != nil {
                out.append(contentsOf: parseWakeUpLater(row, startIndex: periodRow, day: day))
            }
        }
        return out
    }

    /// 星期解析：`^(周)[一二三四五六日]`（`:379-433`）。
    private static func wakeUpDay(in row: String, marker: String) -> Int {
        guard let markerRange = row.range(of: marker),
              let tdEnd = row.range(of: "</td>", range: markerRange.upperBound..<row.endIndex)
        else { return 1 }
        let block = String(row[markerRange.upperBound..<tdEnd.lowerBound])
        let lines = block.components(separatedBy: "<br>")
        guard lines.count >= 2 else { return 1 }
        return dayNumber(fromWeekText: lines[1]) ?? 1
    }

    /// `^(周)[一二三四五六日]` → 1…7；取不到或不在 1…7 返回 `nil`。
    static func dayNumber(fromWeekText text: String) -> Int? {
        guard let first = text.first, first == "周" else { return nil }
        let rest = text.dropFirst()
        guard let second = rest.first else { return nil }
        switch second {
        case "一": return 1
        case "二": return 2
        case "三": return 3
        case "四": return 4
        case "五": return 5
        case "六": return 6
        case "日": return 7
        default: return nil
        }
    }

    /// 节数（`:443-452`）：`节/周` 前一位数字 → 逗号个数 + 1 → 兜底 1，且 `coerceAtLeast(1)`。
    private static func wakeUpPeriodCount(_ detail: String) -> Int {
        if detail.contains("节/周") {
            guard let range = detail.range(of: "节/周"), range.lowerBound > detail.startIndex else { return 1 }
            let previous = detail.index(before: range.lowerBound)
            if let value = Int(String(detail[previous])) { return max(value, 1) }
            return 1
        }
        if detail.contains(",") {
            return max(detail.filter { $0 == "," }.count + 1, 1)
        }
        return 1
    }

    /// 单双周（见 `parseWakeUpStyle` 的「有意差异」）：`单周` → 1，`双周` → 2，否则 0。
    static func wakeUpParity(_ text: String) -> Int {
        if text.contains("单周") { return 1 }
        if text.contains("双周") { return 2 }
        return 0
    }

    /// `parseWakeUpLater`（`QiangzhiJwxtParser.java:628-752`）。
    ///
    /// 把「本单元格里第二个及以后」的块拆成独立课程：按 `"left=100,top=50"`（**不带**尾部
    /// `')\">`）切分后从下标 1 起逐段处理，`> ` 之后到 `<br><` 之前取文本，再按 `<br>` 分组。
    /// 注意原版这个方法的 `单双周` 写法（`:651-654`）是自洽的那一份，因此这里与
    /// `wakeUpParity` 一致。
    private static func parseWakeUpLater(_ later: String, startIndex: Int, day: Int) -> [Course] {
        let pieces = later.components(separatedBy: "left=100,top=50")
        guard pieces.count > 1 else { return [] }
        var out: [Course] = []
        for index in 1..<pieces.count {
            let piece = pieces[index]
            let text: String
            if let close = piece.range(of: "<br><") {
                let afterTag = piece.range(of: ">")
                let start = afterTag?.upperBound ?? piece.startIndex
                text = String(piece[start..<close.lowerBound])
            } else {
                guard let afterTag = piece.range(of: ">") else { continue }
                text = String(piece[afterTag.upperBound...])
            }

            let lines = text.components(separatedBy: "<br>")
            guard lines.count >= 2 else { continue }
            let detail = lines[1]
            let periodCount = QiangzhiJwxtParser.wakeUpPeriodCount(detail)
            let startWeek = QiangzhiJwxtParser.extractWakeUpStartWeek(detail) ?? 1
            let endWeek = QiangzhiJwxtParser.extractWakeUpEndWeek(detail) ?? 20
            let isOdd = QiangzhiJwxtParser.wakeUpParity(detail)
            let weekRange = "\(startWeek)-\(endWeek)"
            let name = QiangzhiJwxtParser.kotlinTrim(lines[0])

            if lines.count == 3 {
                guard lines.indices.contains(3) else { continue }
                out.append(Course(
                    id: 0, name: name,
                    teacher: QiangzhiJwxtParser.kotlinTrim(lines[2]),
                    location: QiangzhiJwxtParser.kotlinTrim(lines[3]),
                    dayOfWeek: day, startPeriod: startIndex,
                    endPeriod: startIndex + periodCount - 1,
                    color: QiangzhiJwxtParser.getStableColor(name),
                    weekRange: weekRange, startWeek: startWeek, endWeek: endWeek, isOdd: isOdd
                ))
            } else if lines.count > 3 {
                let raw = lines[2]
                let piecesOfSlash = raw.components(separatedBy: "/")
                var second = piecesOfSlash.count > 1 ? piecesOfSlash[1] : ""
                if second.contains("(") {
                    let teacher = QiangzhiJwxtParser.kotlinTrim(second.components(separatedBy: "(").first ?? "")
                    let location = QiangzhiJwxtParser.kotlinTrim(second.components(separatedBy: "(").dropFirst().joined(separator: "("))
                    out.append(Course(
                        id: 0, name: name, teacher: teacher, location: location,
                        dayOfWeek: day, startPeriod: startIndex,
                        endPeriod: startIndex + periodCount - 1,
                        color: QiangzhiJwxtParser.getStableColor(name),
                        weekRange: weekRange, startWeek: startWeek, endWeek: endWeek, isOdd: isOdd
                    ))
                } else {
                    if QiangzhiJwxtParser.isBlank(second) { second = piecesOfSlash.first ?? "" }
                    out.append(Course(
                        id: 0, name: name,
                        teacher: QiangzhiJwxtParser.kotlinTrim(second),
                        location: "",
                        dayOfWeek: day, startPeriod: startIndex,
                        endPeriod: startIndex + periodCount - 1,
                        color: QiangzhiJwxtParser.getStableColor(name),
                        weekRange: weekRange, startWeek: startWeek, endWeek: endWeek, isOdd: isOdd
                    ))
                }
            }
        }
        return out
    }

    /// `extractWakeUpStartWeek`（`:768-779`）：`"{第"` 之后到 `"-"` 之间的整数，否则 `nil`。
    static func extractWakeUpStartWeek(_ detail: String) -> Int? {
        guard let start = detail.range(of: "{第") else { return nil }
        guard let dash = detail.range(of: "-", range: start.upperBound..<detail.endIndex) else { return nil }
        return Int(detail[start.upperBound..<dash.lowerBound])
    }

    /// `extractWakeUpEndWeek`（`:781-792`）：第一个 `"-"` 之后到 `"周"` 之间的整数，否则 `nil`。
    static func extractWakeUpEndWeek(_ detail: String) -> Int? {
        guard let dash = detail.range(of: "-") else { return nil }
        guard let zhou = detail.range(of: "周", range: dash.upperBound..<detail.endIndex),
              zhou.lowerBound > dash.upperBound
        else { return nil }
        return Int(detail[dash.upperBound..<zhou.lowerBound])
    }

    // MARK: - 课程块 → Course（recon doc §4.6）

    /// `parseKbContent`（`QiangzhiJwxtParser.java:874-950`）。
    ///
    /// 每段：`extractCourseName` 取不到就**跳过整段**（`:890`）；节次优先
    /// `extractPeriodRange`，其次 `extractStartPeriod` / `extractEndPeriod`，
    /// 兜底用大节号 `periodRow * 2 - 1` / `periodRow * 2`（`:898-909`）。
    public func parseKbContent(_ html: String, periodRow: Int, dayOfWeek: Int) -> [Course] {
        var out: [Course] = []
        for segment in QiangzhiJwxtParser.splitCourseSegments(html) {
            guard let name = extractCourseName(segment) else { continue }
            let teacher = extractTeacher(segment)
            let location = extractLocationMerged(segment)
            let weekRange = extractWeekRange(segment)
            let meta = QiangzhiJwxtParser.parseWeekMeta(weekRange: weekRange, html: segment)
            let periodRange = QiangzhiJwxtParser.extractPeriodRange(segment)

            let startPeriod: Int
            if let periodRange {
                startPeriod = periodRange.0
            } else if let start = QiangzhiJwxtParser.extractStartPeriod(segment) {
                startPeriod = start
            } else {
                startPeriod = periodRow * 2 - 1
            }
            let endPeriod: Int
            if let periodRange {
                endPeriod = periodRange.1
            } else if let end = QiangzhiJwxtParser.extractEndPeriod(segment) {
                endPeriod = end
            } else {
                endPeriod = periodRow * 2
            }

            out.append(Course(
                id: 0,
                name: name,
                teacher: teacher,
                location: location,
                dayOfWeek: dayOfWeek,
                startPeriod: startPeriod,
                endPeriod: endPeriod,
                color: QiangzhiJwxtParser.getStableColor(name),
                weekRange: weekRange,
                startWeek: meta.startWeek,
                endWeek: meta.endWeek,
                isOdd: meta.isOdd
            ))
        }
        return out
    }

    /// `splitCourseSegments`（`QiangzhiJwxtParser.java:952-1009`，recon doc §4.5）。
    ///
    /// 1. 用 **连续 5 个以上 `-`**（正则 `-{5,}`）切分，`trim` 后丢空；
    /// 2. 切不出内容时：若**不含** `left=100,top=50` → 整段文本当一门课；
    /// 3. 否则按 `left=100,top=50')\">` 切分，每段截到第一个 `</td>`，`trim` 后丢空。
    ///
    /// ⚠️ 与原版一致的事实：Kotlin 的 `Regex.split` 在**无命中**时返回单元素列表 `[str]`，
    /// 因此第 1 步对任何非空输入都非空 → 第 2、3 步在 `:967` 的 `!segments.isEmpty()` 判定下
    /// **不可达**（原版即如此，此处照搬不「修正」）。单元格内多门课的分隔靠第 1 步的 `-{5,}`。
    public static func splitCourseSegments(_ html: String) -> [String] {
        let byDashes = split(html, byRegularExpression: "-{5,}")
            .map { kotlinTrim($0) }
            .filter { !isBlank($0) }
        if !byDashes.isEmpty { return byDashes }

        if !html.contains("left=100,top=50") {
            return [kotlinTrim(html)].filter { !isBlank($0) }
        }

        return html.components(separatedBy: cellMarker).map { piece in
            let cut = piece.components(separatedBy: "</td>").first ?? piece
            return kotlinTrim(cut)
        }.filter { !isBlank($0) }
    }

    // MARK: - 字段抽取器（recon doc §4.7）

    /// `extractCourseName`（`:1011-1056`）。取不到返回 `nil`（调用方据此跳过整段）。
    ///
    /// 遍历 `font`，跳过：`title` trim 后在黑名单、`name` trim 后在黑名单、
    /// 文本以 `通知单编号` / `班级：` 开头、文本等于 `备注：`；
    /// 命中则返回 `trim(NBSP→空格)` 后的 `text()`。
    public func extractCourseName(_ html: String) -> String? {
        let document = JwxtHTMLDocument.parseBodyFragment(html)
        let titleBlacklist: Set<String> = [
            "教师", "教室", "教学楼", "周次(节次)", "周次", "通知单编号", "班级", "备注",
        ]
        let nameBlacklist: Set<String> = ["wkxx", "tzdbh", "jxlmc", "xsks", "bzstr", "ktmcstr"]

        for font in document.select("font") {
            let text = QiangzhiJwxtParser.kotlinTrim(QiangzhiJwxtParser.nbspToSpace(font.text()))
            guard !QiangzhiJwxtParser.isBlank(text) else { continue }
            let title = QiangzhiJwxtParser.kotlinTrim(font.attr("title"))
            if !title.isEmpty, titleBlacklist.contains(title) { continue }
            let name = QiangzhiJwxtParser.kotlinTrim(font.attr("name"))
            if !name.isEmpty, nameBlacklist.contains(name) { continue }
            if text.hasPrefix("通知单编号") || text.hasPrefix("班级：") || text == "备注：" { continue }
            return text
        }
        return nil
    }

    /// `extractTeacher`（`:1065-1098`）。
    public func extractTeacher(_ html: String) -> String {
        var value = ""
        let document = JwxtHTMLDocument.parseBodyFragment(html)
        if let node = document.selectFirst("font[title='教师'], font[title=\"教师\"]") {
            let text = QiangzhiJwxtParser.kotlinTrim(node.text())
            if !QiangzhiJwxtParser.isBlank(text) { value = text }
        }
        if QiangzhiJwxtParser.isBlank(value) {
            value = extractByTitleAttr(html, keyword: "教师")
        }
        if QiangzhiJwxtParser.isBlank(value),
           let matched = QiangzhiJwxtParser.firstGroup(
               #"title=['\"]教师['\"][^>]*>([^<]+)</font>"#, in: html
           ) {
            value = QiangzhiJwxtParser.kotlinTrim(matched)
        }
        return value
    }

    /// `extractRoomRaw`（`:1120-1153`）：教室。最后去掉字面量 `</a>`，再用 `<[^>]+>` 清标签。
    public func extractRoomRaw(_ html: String) -> String {
        var value = ""
        let document = JwxtHTMLDocument.parseBodyFragment(html)
        if let node = document.selectFirst("font[title='教室'], font[title=\"教室\"]") {
            let text = QiangzhiJwxtParser.kotlinTrim(node.text())
            if !QiangzhiJwxtParser.isBlank(text) { value = text }
        }
        if QiangzhiJwxtParser.isBlank(value) {
            value = extractByTitleAttr(html, keyword: "教室")
        }
        if QiangzhiJwxtParser.isBlank(value),
           let matched = QiangzhiJwxtParser.firstGroup(
               #"title=['\"]教室['\"][^>]*>([^<]+)</font>"#, in: html
           ) {
            value = QiangzhiJwxtParser.kotlinTrim(matched)
        }
        let withoutAnchor = value.replacingOccurrences(of: "</a>", with: "")
        return QiangzhiJwxtParser.kotlinTrim(JwxtHTMLText.strippingTags(withoutAnchor))
    }

    /// `extractBuildingRaw`（`:1155-1167`）：教学楼。`font[name=jxlmc]` 或 `title=教学楼`。
    public func extractBuildingRaw(_ html: String) -> String {
        let document = JwxtHTMLDocument.parseBodyFragment(html)
        guard let node = document.selectFirst(
            "font[name=jxlmc], font[title='教学楼'], font[title=\"教学楼\"]"
        ) else { return "" }
        return QiangzhiJwxtParser.kotlinTrim(QiangzhiJwxtParser.nbspToSpace(node.text()))
    }

    /// `extractLocationMerged`（`:1100-1111`）：楼名与教室用**一个空格**拼接；只有一个时用那个。
    public func extractLocationMerged(_ html: String) -> String {
        let room = extractRoomRaw(html)
        let building = extractBuildingRaw(html)
        if !QiangzhiJwxtParser.isBlank(building), !QiangzhiJwxtParser.isBlank(room) {
            return QiangzhiJwxtParser.kotlinTrim(
                QiangzhiJwxtParser.kotlinTrim(building) + " " + QiangzhiJwxtParser.kotlinTrim(room)
            )
        }
        return QiangzhiJwxtParser.isBlank(room) ? building : room
    }

    /// `extractByTitleAttr`（`:1169-1224`）：先精确匹配 `title`，再 `contains` 匹配；都取 `text()`。
    public func extractByTitleAttr(_ html: String, keyword: String) -> String {
        let document = JwxtHTMLDocument.parseBodyFragment(html)
        for node in document.select("[title]") {
            guard QiangzhiJwxtParser.kotlinTrim(node.attr("title")) == keyword else { continue }
            let text = QiangzhiJwxtParser.kotlinTrim(node.text())
            if !QiangzhiJwxtParser.isBlank(text) { return text }
            break
        }
        for node in document.select("[title]") where node.attr("title").contains(keyword) {
            return QiangzhiJwxtParser.kotlinTrim(node.text())
        }
        return ""
    }

    // MARK: - 周次（recon doc §4.7 extractWeekRange / parseWeekMeta、§5.1）

    /// `extractWeekRange`（`:1226-1236`）。归一化顺序**必须一致**：
    /// `<br>`→空格 → 其余标签→空格 → `&nbsp;`→空格 → 删所有空格 → 删字面量 `周次`；
    /// 再用 `(\d+(?:-\d+)?(?:,\d+(?:-\d+)?)*)\((?:周|单|双)\)` 取 group(1)；失败兜底 `"1-20"`。
    public func extractWeekRange(_ html: String) -> String {
        var text = JwxtHTMLText.replacingLineBreaks(html, with: " ")
        text = QiangzhiJwxtParser.replacingTags(in: text, with: " ")
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: " ", with: "")
        text = text.replacingOccurrences(of: "周次", with: "")
        if let group = QiangzhiJwxtParser.firstGroup(
            #"(\d+(?:-\d+)?(?:,\d+(?:-\d+)?)*)\((?:周|单|双)\)"#, in: text
        ), !QiangzhiJwxtParser.isBlank(group) {
            return group
        }
        return "1-20"
    }

    /// `parseWeekMeta`（`:1315-1335`）。
    ///
    /// - 数字从 `weekRange`（原始串）里用 `\d+` 全部抽出：`startWeek = min ?? 1`、`endWeek = max ?? 20`；
    /// - 单双周在 `(weekRange + html)` **去空格后**判断：`单周|\(单\)` → 1，`双周|\(双\)` → 2，否则 0。
    public static func parseWeekMeta(weekRange: String, html: String) -> (startWeek: Int, endWeek: Int, isOdd: Int) {
        let numbers = allGroups(#"\d+"#, in: weekRange).compactMap { Int($0) }
        let startWeek = numbers.min() ?? 1
        let endWeek = numbers.max() ?? 20
        let joined = (weekRange + html).replacingOccurrences(of: " ", with: "")
        var isOdd = 0
        if joined.range(of: #"单周|\(单\)"#, options: .regularExpression) != nil {
            isOdd = 1
        } else if joined.range(of: #"双周|\(双\)"#, options: .regularExpression) != nil {
            isOdd = 2
        }
        return (startWeek, endWeek, isOdd)
    }

    // MARK: - 节次（recon doc §5.2）

    /// `extractPeriodRange`（`:1355-1371`）：`(\d+)\s*-\s*(\d+)\s*节`，要求 `start > 0 && end >= start`。
    public static func extractPeriodRange(_ html: String) -> (Int, Int)? {
        guard let groups = firstGroupPair(#"(\d+)\s*-\s*(\d+)\s*节"#, in: html),
              let start = Int(groups.0), let end = Int(groups.1),
              start > 0, end >= start
        else { return nil }
        return (start, end)
    }

    /// `extractStartPeriod`（`:1337-1344`）：`\[(\d+)-\d+节\]`。
    public static func extractStartPeriod(_ html: String) -> Int? {
        firstGroup(#"\[(\d+)-\d+节\]"#, in: html).flatMap { Int($0) }
    }

    /// `extractEndPeriod`（`:1346-1353`）：`\[\d+-(\d+)节\]`。
    public static func extractEndPeriod(_ html: String) -> Int? {
        firstGroup(#"\[\d+-(\d+)节\]"#, in: html).flatMap { Int($0) }
    }

    // MARK: - 颜色（recon doc §5、§4.7）

    /// `getStableColor`（`:1373-1379`）：按课名**首个 UTF-16 码元**取 palette 下标。
    ///
    /// 用 `name.utf16.first` 而不是 `unicodeScalars.first`：Java 的 `(int) char` 是 UTF-16
    /// 码元，两者只在 BMP 之外（emoji 等）不同，这里按 Java 语义取。
    public static func getStableColor(_ name: String) -> Int {
        if isBlank(name) { return palette[0] }
        let code = Int(name.utf16.first ?? 0)
        return palette[abs(code) % palette.count]
    }

    // MARK: - 两层去重（recon doc §7.2）

    /// `mergeDuplicateCourses`（`:795-811`）：按
    /// `name|dayOfWeek|startPeriod|endPeriod|weekRange|startWeek|endWeek|isOdd` 判重，
    /// 保留**首次出现**，同键时用新值补齐 `teacher` / `location` 的空白项。
    public static func mergeDuplicateCourses(_ courses: [Course]) -> [Course] {
        var store: [String: Course] = [:]
        var order: [String] = []
        for course in courses {
            let key = [
                course.name,
                String(course.dayOfWeek),
                String(course.startPeriod),
                String(course.endPeriod),
                course.weekRange,
                String(course.startWeek),
                String(course.endWeek),
                String(course.isOdd),
            ].joined(separator: "|")
            if var existing = store[key] {
                if isBlank(existing.teacher) { existing.teacher = course.teacher }
                if isBlank(existing.location) { existing.location = course.location }
                store[key] = existing
            } else {
                store[key] = course
                order.append(key)
            }
        }
        return order.compactMap { store[$0] }
    }

    /// `collapseAdjacentCourses`（`:814-872`）：相邻同课合并（连排合并）。
    ///
    /// 先按 `(dayOfWeek, startPeriod, name, location, teacher)` 排序，再一次遍历合并
    /// `前.endPeriod + 1 == 后.startPeriod` 且 9 个字段全等的一对，合并后
    /// **保留前者 `startPeriod`、取后者 `endPeriod`**（`:863-864`）。
    public static func collapseAdjacentCourses(_ courses: [Course]) -> [Course] {
        guard !courses.isEmpty else { return [] }
        let sorted = courses.sorted { lhs, rhs in
            if lhs.dayOfWeek != rhs.dayOfWeek { return lhs.dayOfWeek < rhs.dayOfWeek }
            if lhs.startPeriod != rhs.startPeriod { return lhs.startPeriod < rhs.startPeriod }
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            if lhs.location != rhs.location { return lhs.location < rhs.location }
            return lhs.teacher < rhs.teacher
        }
        var out: [Course] = []
        var current = sorted[0]
        for index in 1..<sorted.count {
            let next = sorted[index]
            let mergeable = current.name == next.name
                && current.location == next.location
                && current.teacher == next.teacher
                && current.dayOfWeek == next.dayOfWeek
                && current.endPeriod + 1 == next.startPeriod
                && current.weekRange == next.weekRange
                && current.startWeek == next.startWeek
                && current.endWeek == next.endWeek
                && current.isOdd == next.isOdd
            if mergeable {
                current.endPeriod = next.endPeriod
            } else {
                out.append(current)
                current = next
            }
        }
        out.append(current)
        return out
    }

    // MARK: - 文本工具

    /// 等价 Kotlin `CharSequence.trim()`（JVM `Character.isWhitespace`，**不含 NBSP**）。
    static func kotlinTrim(_ value: String) -> String {
        func isSpace(_ ch: Character) -> Bool { ch != "\u{00A0}" && ch.isWhitespace }
        var start = value.startIndex
        var end = value.endIndex
        while start < end, isSpace(value[start]) { start = value.index(after: start) }
        while end > start {
            let previous = value.index(before: end)
            guard isSpace(value[previous]) else { break }
            end = previous
        }
        return String(value[start..<end])
    }

    /// 等价 Kotlin `CharSequence.isBlank()`（同上，NBSP 不算空白；空串算 blank）。
    static func isBlank(_ value: String) -> Bool {
        value.allSatisfy { $0 != "\u{00A0}" && $0.isWhitespace }
    }

    /// 等价 Kotlin `replace("\u00A0", " ")`（`:1031`、`:1162` 的字面量就是 U+00A0）。
    static func nbspToSpace(_ value: String) -> String {
        value.replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    /// 等价 `new Regex("<[^>]+>").replace(str, " ")`（注意替换成**空格**，`:1227`）。
    static func replacingTags(in value: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "<[^>]+>") else { return value }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.stringByReplacingMatches(in: value, options: [], range: range, withTemplate: template)
    }

    /// 等价 Kotlin `Regex(pattern).findAll(str)` 的全部 group(0)。
    static func allGroups(_ pattern: String, in value: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.matches(in: value, options: [], range: range).compactMap { match in
            guard let r = Range(match.range(at: 0), in: value) else { return nil }
            return String(value[r])
        }
    }

    /// 取第一个匹配的 group(1)；无匹配或该组未参与匹配时返回 `nil`。
    ///
    /// ⚠️ **不能**委托给 `firstGroupPair`：后者要求 `numberOfRanges > 2`（即必须存在两个
    /// 捕获组），因此单捕获组的正则（`extractWeekRange`、`extractStartPeriod`、
    /// `extractEndPeriod`、`extractTeacher` / `extractRoomRaw` 的兜底）会永远拿不到值。
    static func firstGroup(_ pattern: String, in value: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, options: [], range: range),
              match.numberOfRanges > 1,
              let first = Range(match.range(at: 1), in: value)
        else { return nil }
        return String(value[first])
    }

    /// 取第一个匹配的 group(1) 与 group(2)。
    static func firstGroupPair(_ pattern: String, in value: String) -> (String, String)? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, options: [], range: range),
              match.numberOfRanges > 2,
              let first = Range(match.range(at: 1), in: value),
              let second = Range(match.range(at: 2), in: value)
        else { return nil }
        return (String(value[first]), String(value[second]))
    }

    /// 等价 Kotlin `Regex(pattern).split(str)`：按每个匹配切分（空段保留，由调用方 trim 过滤）。
    static func split(_ value: String, byRegularExpression pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern), !value.isEmpty else { return [value] }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        let matches = regex.matches(in: value, options: [], range: range)
        guard !matches.isEmpty else { return [value] }
        var out: [String] = []
        var cursor = value.startIndex
        for match in matches {
            guard let r = Range(match.range, in: value) else { continue }
            out.append(String(value[cursor..<r.lowerBound]))
            cursor = r.upperBound
        }
        out.append(String(value[cursor...]))
        return out
    }
}

/// 抓课表阶段的失败原因（文件头「有意差异 4」）。
///
/// Android 原版在这里**返回空表**（`QiangzhiJwxtParser$fetchTimetable$2.java:104-125`），
/// 使「本学期无课」与「抓取失败」不可区分 —— 真机上就表现为那句毫无线索的
/// 「未获取到课表数据；已保留本地原有课程。」。iOS 侧改为显式抛错并携带证据串
/// （`diagnostic`），让失败原因可读、可修。
public enum JwxtFetchError: Error, LocalizedError, Equatable, Sendable {
    /// 抓课表那一跳拿到的是登录页 ⇒ 会话已失效（服务端 200 + 登录页，不是 302）。
    case sessionExpired(diagnostic: String)
    /// 拿到的是非登录页，但 DO 风格、宽松兜底与 WakeUp 风格都没解析出课程 ⇒ 页面结构与解析器不匹配。
    case pageStructureUnsupported(diagnostic: String)

    public var errorDescription: String? {
        switch self {
        case let .sessionExpired(diagnostic):
            return "教务系统会话已失效，需要重新登录（诊断：\(diagnostic)）"
        case let .pageStructureUnsupported(diagnostic):
            return "课表页结构无法识别（诊断：\(diagnostic)）"
        }
    }
}
