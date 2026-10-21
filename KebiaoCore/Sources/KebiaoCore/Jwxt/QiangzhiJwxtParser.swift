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

    /// 可选**分段诊断计数器**（本轮为定位「英语 / 体育 / 高等数学 在哪一环丢」而加）。
    ///
    /// 由同步层（`JwxtTimetableSync`）构造后赋值，与 `log` 同一个套路。
    /// 为 `nil` 时所有埋点都是 `diagnostics?.xxx()` 的空操作，**不改变任何解析结果**。
    public var diagnostics: JwxtParseDiagnostics?

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
        // ① 原始响应（成功分支）：状态码、HTML 长度、原文里的 tr / td 出现次数、
        //    以及三个结构特征串。**没拿到响应**时（传输异常）只记一条「成功=否」。
        let response: JwxtSession.Response
        do {
            response = try await session.send(
                url,
                options: JwxtSession.RequestOptions(
                    method: "GET",
                    headers: [
                        "Referer": referer,
                        "User-Agent": JwxtSession.userAgent,
                    ]
                )
            )
        } catch {
            diagnostics?.recordResponseFailure()
            throw error
        }

        let finalURL = response.finalURL?.absoluteString ?? url
        let body = response.body

        diagnostics?.recordResponse(
            status: response.statusCode,
            body: body,
            hasTimetableId: body.contains("id=\"timetable\"") || body.contains("id='timetable'"),
            hasTable1: body.contains("Table1"),
            hasKbcontent: body.contains("kbcontent")
        )

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
        // ⑤ 过滤与保存：把两层去重前后的计数分开记 —— 「被过滤 / 去重吃掉多少」才可归因。
        diagnostics?.recordParsedCourses(parsed)
        let merged = QiangzhiJwxtParser.mergeDuplicateCourses(parsed)
        diagnostics?.recordAfterMerge(merged)
        let collapsed = QiangzhiJwxtParser.collapseAdjacentCourses(merged)
        diagnostics?.recordFinal(collapsed)
        // ⑤「实际保存」= 交给 UI 落盘的门数：与本方法返回的数组一一对应
        //    （`TimetableStore.replaceAllCourses` 是原样全量覆盖，不改数量）。
        diagnostics?.recordSaved(collapsed.count)
        return collapsed
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
        diagnostics?.recordTableAttempt()
        let rows = document.select("tr", from: table)
        guard !rows.isEmpty else { return [] }

        // ② 表格结构：解析树里的 tr / td 总数与「td 嵌套」迹象。
        //    ⚠ 原文 <td 计数**只数这张表的切片**（见 recordTableTreeShape），
        //    不能拿全文档的 <td 数去比 —— 那会把页面上其它表格也算进来。
        recordTableTreeShape(table, in: document)

        var out: [Course] = []
        var periodRow = 0
        for row in rows {
            // `:183-188`：取 th 文本，**去掉所有 ASCII 空格**。
            // 选择器必须限定在**本行**内（jsoup 的 `row.selectFirst("th")` 只看该元素子树）。
            let header = (document.selectFirst("th", from: row)?.text() ?? "")
                .replacingOccurrences(of: " ", with: "")
            // `:191` 的 `element.select("> td")` —— 直接子 td（见文件头「有意差异 1」）。
            let cells = row.children.filter { $0.tag == "td" }
            let isPeriodRow = header.contains("第") && header.contains("大节")
            // ② 每行直接子 td 数量直方图 + 被跳过行的原因（只统计，不参与任何判定）。
            diagnostics?.recordRow(
                header: header,
                directTdCount: cells.count,
                isPeriodRow: isPeriodRow
            )
            guard isPeriodRow else { continue }
            periodRow += 1

            for (offset, cell) in cells.enumerated() {
                let dayOfWeek = offset + 1
                guard dayOfWeek >= 1, dayOfWeek < 8 else { continue }
                // ③ 单元格级目标课追踪：先看**整格文本**里有没有出现目标课关键词。
                // 用整格文本而不是原始 innerHTML，是因为课名可能被标签切开（`英</font>语`）。
                diagnostics?.recordCellText(cell.text())
                let rawHTML = cell.innerHTML(in: document)
                let content = extractDoCellContent(cell, in: document)
                let produced: [Course]
                if QiangzhiJwxtParser.isBlank(content) {
                    produced = []
                } else {
                    produced = parseKbContent(content, periodRow: periodRow, dayOfWeek: dayOfWeek)
                }
                // ②b 棋盘：这一格到底是「原始就空」还是「有课程痕迹却 0 门」。
                // 只看「某时间段没显示课程」是分不清这两者的，必须逐格记。
                diagnostics?.recordCellOutcome(
                    periodRow: periodRow,
                    dayOfWeek: dayOfWeek,
                    courseCount: produced.count,
                    looksLikeCourse: QiangzhiJwxtParser.cellLooksLikeCourse(rawHTML)
                )
                // ②c 0 门但格子非空时，记下这一格的**标记形态**（标签数 / class 列表 / 有无文本）。
                // 这是「那几格到底用什么结构写的」的唯一线索，且不含任何课程原文。
                if produced.isEmpty, !rawHTML.isEmpty {
                    diagnostics?.recordEmptyCellMarkup(
                        QiangzhiJwxtParser.markupSignature(rawHTML)
                    )
                }
                out.append(contentsOf: produced)
            }
        }
        return out
    }

    /// 统计 `table` 子树在**解析树**里的 tr / td 数、含 `td` 后代的 `td` 个数（嵌套迹象），
    /// 以及**这张表**原文切片里的 `<td` 个数（用来判断「解析前后结构是否一致」）。
    ///
    /// ⚠ 这一版修掉了一个**会误报**的缺陷：原先拿「全文档」的 `<td` 计数去比单张表的树内
    /// `td` 数，必然出现「树内 43 ≠ 原文 283」这种假告警（真机截图里就报了「存在漏闭合/嵌套错位迹象」，
    /// 但那只是因为页面上还有别的表格）。现在只数**本表切片**；若本表没有显式 `</table>`，
    /// 切片不可靠，就记 `-1`（= 无法比对），不猜。
    ///
    /// 只读遍历，返回与解析结果无关。
    private func recordTableTreeShape(_ table: JwxtHTMLNode, in document: JwxtHTMLDocument) {
        guard let diagnostics = diagnostics else { return }
        var trCount = 0
        var tdCount = 0
        var nestedTdCount = 0
        for node in table.descendantElements() {
            if node.tag == "tr" { trCount += 1 }
            if node.tag == "td" {
                tdCount += 1
                // `descendantElements()` 把自身排在最前，`dropFirst()` 之后才是真后代。
                if node.descendantElements().dropFirst().contains(where: { $0.tag == "td" }) {
                    nestedTdCount += 1
                }
            }
        }

        let source = document.source
        var rawTdInTable = -1
        if table.startOffset < table.endOffset, table.endOffset <= source.count {
            let lower = source.index(source.startIndex, offsetBy: table.startOffset)
            let upper = source.index(source.startIndex, offsetBy: table.endOffset)
            let slice = String(source[lower..<upper])
            if slice.contains("</table") || slice.contains("</TABLE") {
                rawTdInTable = JwxtParseDiagnostics.occurrences(of: "<td", in: slice)
            }
        }
        diagnostics.recordTableTree(
            tr: trCount,
            td: tdCount,
            nestedTd: nestedTdCount,
            rawTdInTable: rawTdInTable
        )
    }

    /// 单元格内容提取（`QiangzhiJwxtParser.java:229-292`，recon doc §4.3）。
    ///
    /// 1. `td.select("div.kbcontent")`，只留 `innerHTML` **忽略大小写含 `<font`** 的；
    /// 2. 优先取 `innerHTML` 含 `title='教师'` / `title="教师"` / `title=教师` 的那个，否则取第一个；
    /// 3. `trim` 后非空且 ≠ 字面量 `&nbsp;` → 返回；
    /// 4. 否则同样的「含 `<font`」逻辑走 `div.kbcontent1`；都不满足返回 `""`（`:270-291`）。
    public func extractDoCellContent(_ td: JwxtHTMLNode, in document: JwxtHTMLDocument) -> String {
        // ③ 先记这一格**总共有几个候选 div**（两种 class 都算）。
        // 原版逻辑每个单元格只会取**一个**候选（含 `title=教师` 的那个，否则第一个），
        // 所以「候选数 ≥ 2」的格子意味着可能有课被这一取法吃掉了 —— 只计数，不改选择。
        diagnostics?.recordCellCandidates(
            kbcontent: document.select("div.kbcontent", from: td).count,
            kbcontent1: document.select("div.kbcontent1", from: td).count
        )
        let candidates = document.select("div.kbcontent", from: td).map { $0.innerHTML(in: document) }
            .filter { $0.range(of: "<font", options: .caseInsensitive) != nil }

        var chosen: String?
        var chosenByTeacherTitle = false
        for html in candidates
        where html.contains("title='教师'") || html.contains("title=\"教师\"") || html.contains("title=教师") {
            chosen = html
            chosenByTeacherTitle = true
            break
        }
        if chosen == nil { chosen = candidates.first }

        let trimmed = QiangzhiJwxtParser.kotlinTrim(chosen ?? "")
        if !QiangzhiJwxtParser.isBlank(trimmed), trimmed != "&nbsp;" {
            // ③ 单元格：候选数 / 选中了哪一个 / 是否走了 kbcontent1 兜底。
            diagnostics?.recordCellChosen(
                candidates: candidates.count,
                byTeacherTitle: chosenByTeacherTitle,
                usedKbcontent1Fallback: false
            )
            return trimmed
        }

        for node in document.select("div.kbcontent1", from: td) {
            let html = node.innerHTML(in: document)
            guard html.range(of: "<font", options: .caseInsensitive) != nil else { continue }
            let fallback = QiangzhiJwxtParser.kotlinTrim(html)
            if QiangzhiJwxtParser.isBlank(fallback) || fallback == "&nbsp;" {
                diagnostics?.recordCellSkipped(candidates: candidates.count)
                return ""
            }
            diagnostics?.recordCellChosen(
                candidates: candidates.count,
                byTeacherTitle: chosenByTeacherTitle,
                usedKbcontent1Fallback: true
            )
            return fallback
        }
        diagnostics?.recordCellSkipped(candidates: candidates.count)
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
        let segments = QiangzhiJwxtParser.splitCourseSegments(html)
        // ④ 课程文本：本单元格切出多少段。
        diagnostics?.recordSegments(segments.count)
        for segment in segments {
            // ④ 先记「本段里有没有目标课关键词」——必须在课名抽取**之前**记，
            //    否则「段里有课但课名没抽出来」这种情况会被后续的空计数掩盖掉。
            diagnostics?.recordSegmentText(segment)
            guard let name = extractCourseName(segment) else {
                // ④ 取不到课名 ⇒ 整段被跳过（原因由 extractCourseName 内部三分记账）。
                diagnostics?.recordSegmentNameMissing()
                continue
            }
            diagnostics?.recordSegmentName(name, dayOfWeek: dayOfWeek)
            let teacher = extractTeacher(segment)
            let location = extractLocationMerged(segment)
            let weekRange = extractWeekRange(segment)
            let meta = QiangzhiJwxtParser.parseWeekMeta(weekRange: weekRange, html: segment)
            let periodRange = QiangzhiJwxtParser.extractPeriodRange(segment)
            // ④ 节次：优先区间命中，否则回落到「大节号 × 2」兜底。
            diagnostics?.recordSegmentPeriod(primaryRangeHit: periodRange != nil)

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

        var seenNonBlankFont = false
        for font in document.select("font") {
            let text = QiangzhiJwxtParser.kotlinTrim(QiangzhiJwxtParser.nbspToSpace(font.text()))
            guard !QiangzhiJwxtParser.isBlank(text) else { continue }
            seenNonBlankFont = true
            let title = QiangzhiJwxtParser.kotlinTrim(font.attr("title"))
            if !title.isEmpty, titleBlacklist.contains(title) { continue }
            let name = QiangzhiJwxtParser.kotlinTrim(font.attr("name"))
            if !name.isEmpty, nameBlacklist.contains(name) { continue }
            if text.hasPrefix("通知单编号") || text.hasPrefix("班级：") || text == "备注：" { continue }
            return text
        }
        // ④ 走到这里说明整段没有可用的课名：把原因三分记下来（无 font / font 全空 / 全被黑名单）。
        diagnostics?.recordNameFailure(
            fontCount: document.select("font").count,
            allBlank: !seenNonBlankFont
        )
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
            // ④ 周次命中正则（真解析成功，不是兜底值）+ 记下命中处**形态**。
            diagnostics?.recordWeekRangeMatched()
            diagnostics?.recordWeekShape(
                QiangzhiJwxtParser.weekContextShape(text: text, matched: group)
            )
            return group
        }
        // ④ 周次未命中 ⇒ 返回兜底 `1-20`；这一条专门用来区分「真周次」与「兜底值」。
        diagnostics?.recordWeekRangeFallback()
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

    // MARK: - 诊断：周次命中处形态

    /// 一个单元格的原始 innerHTML 是否**看起来含课程**。
    ///
    /// 只做「是否有痕迹」的判断，不解析任何字段：命中 `(周)` / `周)` / `节]` / `<font` 任一即算有。
    /// 用途是把「原始就是空格子」与「有课程痕迹但解析出 0 门」分开 —— 这两种情况
    /// 在界面上同样表现为「该时间段没课」，但根因完全不同，修法也相反。
    static func cellLooksLikeCourse(_ rawHTML: String) -> Bool {
        guard !rawHTML.isEmpty else { return false }
        if rawHTML.range(of: "<font", options: .caseInsensitive) != nil { return true }
        return rawHTML.contains("(周)") || rawHTML.contains("周)")
            || rawHTML.contains("节]") || rawHTML.contains("(单)") || rawHTML.contains("(双)")
    }

    /// 截取「周次命中处」前后一小段，把字符替换成类别，得到**不含任何原文**的结构签名。
    ///
    /// 例：`1-16(周)` 命中 `1-16`、上下文是 `周次(节次)1-16(周)[01-02节]`（已删空格）→
    /// 前 6 个字符 `)1-16` 后 8 个字符 `(周)[01-` → 签名形如 `C D - D ( C ) [ D -`。
    /// 数字→`D`、ASCII 字母→`L`、中日韩字符→`C`、其它标点原样保留（连续同类合并成一个）。
    ///
    /// 为什么要它：「周次=4 / 6 / 15」这种单值要看是源数据本来就写 `4(周)`，
    /// 还是我们只吃到了 `1-4(周)` 的尾部 —— 只看结果数字区分不了，看形态就能区分。
    static func weekContextShape(text: String, matched: String) -> String {
        guard let range = text.range(of: matched) else {
            return shapeSignature(matched)
        }
        let beforeStart = text.index(range.lowerBound, offsetBy: -6, limitedBy: text.startIndex) ?? text.startIndex
        let afterEnd = text.index(range.upperBound, offsetBy: 8, limitedBy: text.endIndex) ?? text.endIndex
        return shapeSignature(String(text[beforeStart..<afterEnd]))
    }

    /// 把字符串压成类别签名（见 `weekContextShape`）。
    static func shapeSignature(_ value: String) -> String {
        var out = ""
        for character in value {
            let symbol: String
            if character.isNumber {
                symbol = "D"
            } else if character.isASCII, character.isLetter {
                symbol = "L"
            } else if let scalar = character.unicodeScalars.first, scalar.value >= 0x2E80 {
                symbol = "C"
            } else {
                symbol = String(character)
            }
            if out.hasSuffix(symbol) { continue }
            out += symbol
        }
        return out
    }

    /// 一个「0 门但非空」单元格的**标记形态**签名（不含任何课程原文）。
    ///
    /// 形如 `div2/span0/font0/td0/txt有/cls:kbcontent,kbcontent2`：
    /// 标签数说明它用什么元素承载内容，`cls` 说明用的哪个 class，
    /// `txt` 说明去掉标签后还有没有文字 —— 三者合起来就能判断
    /// 「这几格是原始空白」还是「用了我们没识别的结构」。
    static func markupSignature(_ rawHTML: String) -> String {
        func countTag(_ tag: String) -> Int { occurrences(of: "<" + tag, in: rawHTML) }
        let classes = classNames(in: rawHTML)
        let text = JwxtHTMLText.strippingTags(rawHTML).trimmingCharacters(in: .whitespacesAndNewlines)
        return "div\(countTag("div"))/span\(countTag("span"))/font\(countTag("font"))"
            + "/td\(countTag("td"))/txt\(text.isEmpty ? "无" : "有")"
            + (classes.isEmpty ? "" : "/cls:\(classes.joined(separator: ","))")
    }

    /// 取出 HTML 里所有 `class` 属性值（去重后排序，忽略大小写取得原值）。
    static func classNames(in rawHTML: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"class\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#,
            options: [.caseInsensitive]
        ) else { return [] }
        let range = NSRange(rawHTML.startIndex..<rawHTML.endIndex, in: rawHTML)
        var names: Set<String> = []
        for match in regex.matches(in: rawHTML, options: [], range: range) {
            for group in 1...3 {
                guard let r = Range(match.range(at: group), in: rawHTML) else { continue }
                let value = String(rawHTML[r]).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { names.insert(value) }
            }
        }
        return names.sorted()
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

// MARK: - 分段诊断计数器

/// 课表同步链路的**分段诊断计数器**（本轮只加计数，**不改**任何解析 / 过滤 / 去重规则）。
///
/// 背景：安卓端能同步到的「英语 / 体育 / 高等数学」在 iOS 端缺失。已证实 iOS 自写的
/// `JwxtHTML` 扫描器与安卓的 jsoup 有真实差异（jsoup 有 HTML5 隐式闭合，本实现只有
/// 显式 `</tag>` 才闭合），但**本机没有真实课表 HTML 样本**，无法证明这就是三门课
/// 缺失的直接原因。所以本轮只把「课在哪一环丢」用真机数据钉出来，再决定要不要动扫描器。
///
/// 记录分五段（与需求逐条对应）：
/// ① 原始响应 ② 表格结构 ③ 课程单元格 ④ 课程文本 ⑤ 过滤与保存，
/// 外加对「英语 / 体育 / 高等数学」的**逐段**追踪。
///
/// ## 安全性（硬要求）
///
/// 只记**计数、阶段名与失败原因**：不记账号 / 密码 / Cookie 值 / 会话令牌，
/// 也不把整张课表的教师、班级等个人信息写进日志。唯一允许出现的原文是
/// **目标课关键词**（`targetKeywords`）—— 那是本轮要追踪的对象。
///
/// ## 线程安全
///
/// 埋点可能来自会话 / 解析的任意线程（`@unchecked Sendable` + `NSLock` 保护）。
public final class JwxtParseDiagnostics: @unchecked Sendable {

    /// 目标课程关键词。
    ///
    /// **包含式**匹配（如「大学英语(一)」含「英语」即命中）、**大小写不敏感**。
    /// 刻意不用裸「数学」「英语课」这类宽词，避免把无关课程误判成目标课。
    public static let targetKeywords: [String] = ["英语", "体育", "高等数学"]

    private let lock = NSLock()

    // MARK: ① 原始响应
    private var responseStatus: Int?
    private var responseFailed = false
    private var htmlLength = 0
    private var rawTrCount = 0
    private var rawTdOpenCount = 0
    private var rawTdCloseCount = 0
    private var hasTimetableId = false
    private var hasTable1 = false
    private var hasKbcontent = false

    // MARK: ② 表格结构
    private var tableAttempts = 0
    private var treeTrCount = 0
    private var treeTdCount = 0
    private var treeNestedTdCount = 0
    /// **本表切片**里的 `<td` 数（`-1` = 没取到可靠切片）。用来判断解析前后结构是否一致 ——
    /// 不能用全文档计数（会误报，见 `recordTableTreeShape` 的注释）。
    private var rawTdInTable = -1
    private var rowTdHistogram: [Int: Int] = [:]
    private var periodRowTdHistogram: [Int: Int] = [:]
    private var periodRows = 0
    private var skippedRows: [String: Int] = [:]

    // MARK: ③ 单元格
    private var cellCandidateTotal = 0
    private var cellChosenCount = 0
    private var cellChosenByTeacherTitle = 0
    private var cellChosenFirst = 0
    private var cellKbcontent1Fallback = 0
    private var cellSkippedEmpty = 0
    /// 每格候选 div 总数（`div.kbcontent` + `div.kbcontent1`）的直方图。
    private var candidateHistogram: [Int: Int] = [:]
    /// 候选数 ≥ 2 的格子数 —— 原版每格只取一个候选，这些格子可能被吃掉了课。
    private var multiCandidateCells = 0

    // MARK: ④ 课程文本
    private var segmentTotal = 0
    private var segmentNameExtracted = 0
    private var segmentNameMissing = 0
    private var weekRangeMatched = 0
    private var weekRangeFallback = 0
    /// 周次**命中处的上下文形态**直方图（数字→`D`、字母→`L`、中日韩字符→`C`、其余原样、连续同类折叠）。
    ///
    /// 用途：真机上「周次=4 / 6 / 15」这种**单值**明显不像正常教学周区间（`1-16`），
    /// 但只有知道命中处原文长什么样（`D-D` 还是 `D`）才能判断是源数据本来如此、
    /// 还是我们只吃到了区间尾部。形态串里没有任何课名 / 教师姓名 / 班级信息。
    private var weekShapes: [String: Int] = [:]
    private var periodRangePrimary = 0
    private var periodRangeFallback = 0
    private var dayHistogram: [Int: Int] = [:]

    // MARK: ②b 单元格棋盘（大节行 × 星期列）
    /// 每格的**token**（`●` / `◐` / `·` / `!`），只用于汇总时的棋盘渲染。
    private var cellGrid: [Int: [Int: String]] = [:]
    /// 「原始 innerHTML 看起来含课程，却解析出 0 门」的格子数 —— 这是真正的解析缺陷。
    private var cellLostCount = 0
    /// 「原始 innerHTML 没有任何课程痕迹」的格子数 —— 源数据本来就空。
    private var cellTrulyEmptyCount = 0
    /// 「0 门但格子非空」的**标记形态**直方图（见 `markupSignature`）。
    private var emptyCellMarkups: [String: Int] = [:]

    // MARK: ④ 课名抽取失败的原因（三分；原先在汇总里写死一句话，等于没测）
    private var nameFailNoFont = 0
    private var nameFailAllBlank = 0
    private var nameFailBlacklisted = 0

    // MARK: ⑤ 过滤与保存
    private var initialCourseCount = 0
    private var afterMergeCount = 0
    private var afterCollapseCount = 0
    private var savedCourseCount = 0

    // MARK: 目标课追踪
    private var targetMentionedInRawHTML: Set<String> = []
    /// 目标关键词出现在**单元格整格文本**里的次数（③）。
    private var targetLocatedInCell: [String: Int] = [:]
    /// 目标关键词出现在**课程段**里的次数（④，课名抽取之前）。
    ///
    /// 与 `targetNameExtracted` 对比就能把「段里明明有这门课，但课名没抽出来」
    /// 与「段里根本没有」区分开 —— 前者是解析缺陷，后者是源数据就没有。
    private var targetInSegment: [String: Int] = [:]
    private var targetNameExtracted: [String: Int] = [:]
    private var targetInParsed: [String: Int] = [:]
    private var targetInFinal: [String: Int] = [:]

    public init() {}

    // MARK: - 埋点（只加计数；返回值与解析结果无关）

    /// ① 拿到了响应。
    func recordResponse(
        status: Int,
        body: String,
        hasTimetableId: Bool,
        hasTable1: Bool,
        hasKbcontent: Bool
    ) {
        lock.lock()
        defer { lock.unlock() }
        responseStatus = status
        htmlLength = body.count
        rawTrCount = JwxtParseDiagnostics.occurrences(of: "<tr", in: body)
        rawTdOpenCount = JwxtParseDiagnostics.occurrences(of: "<td", in: body)
        rawTdCloseCount = JwxtParseDiagnostics.occurrences(of: "</td", in: body)
        self.hasTimetableId = hasTimetableId
        self.hasTable1 = hasTable1
        self.hasKbcontent = hasKbcontent
        for keyword in JwxtParseDiagnostics.targetKeywords
        where JwxtParseDiagnostics.contains(body, keyword) {
            targetMentionedInRawHTML.insert(keyword)
        }
    }

    /// ① 请求根本没拿到响应（传输层异常）。`reason` 不记 —— 避免把可能含 URL 的原文带出来。
    func recordResponseFailure() {
        lock.lock()
        defer { lock.unlock() }
        responseFailed = true
    }

    func recordTableAttempt() {
        lock.lock()
        defer { lock.unlock() }
        tableAttempts += 1
    }

    func recordTableTree(tr: Int, td: Int, nestedTd: Int, rawTdInTable: Int) {
        lock.lock()
        defer { lock.unlock() }
        treeTrCount += tr
        treeTdCount += td
        treeNestedTdCount += nestedTd
        if rawTdInTable >= 0 { self.rawTdInTable = rawTdInTable }
    }

    /// ② 一行：直接子 `td` 数量入直方图；非节次行按原因计入「被跳过」。
    func recordRow(header: String, directTdCount: Int, isPeriodRow: Bool) {
        lock.lock()
        defer { lock.unlock() }
        rowTdHistogram[directTdCount, default: 0] += 1
        guard isPeriodRow else {
            let reason = header.isEmpty ? "th 文本为空" : "th 文本不含「第」「大节」"
            skippedRows[reason, default: 0] += 1
            return
        }
        periodRows += 1
        periodRowTdHistogram[directTdCount, default: 0] += 1
    }

    /// ③ 一个单元格的**整格文本**里是否出现目标课关键词（定位到「课程单元格」这一环）。
    func recordCellText(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        for keyword in JwxtParseDiagnostics.targetKeywords
        where JwxtParseDiagnostics.contains(text, keyword) {
            targetLocatedInCell[keyword, default: 0] += 1
        }
    }

    /// ③ 记录本格候选 div 总数（`div.kbcontent` 与 `div.kbcontent1` 分别计数后求和）。
    func recordCellCandidates(kbcontent: Int, kbcontent1: Int) {
        lock.lock()
        defer { lock.unlock() }
        let total = kbcontent + kbcontent1
        candidateHistogram[total, default: 0] += 1
        if total > 1 { multiCandidateCells += 1 }
    }

    /// ③ 记录一次性选中内容（候选数、选中哪个、是否 kbcontent1 兜底）。
    func recordCellChosen(candidates: Int, byTeacherTitle: Bool, usedKbcontent1Fallback: Bool) {
        lock.lock()
        defer { lock.unlock() }
        cellCandidateTotal += candidates
        cellChosenCount += 1
        if byTeacherTitle { cellChosenByTeacherTitle += 1 } else { cellChosenFirst += 1 }
        if usedKbcontent1Fallback { cellKbcontent1Fallback += 1 }
    }

    /// ③ 单元格内容为空被跳过（`kbcontent` / `kbcontent1` 都没拿到可用内容）。
    func recordCellSkipped(candidates: Int) {
        lock.lock()
        defer { lock.unlock() }
        cellCandidateTotal += candidates
        cellSkippedEmpty += 1
    }

    /// ④ 本次 `parseKbContent` 从单元格里切出多少段。
    func recordSegments(_ count: Int) {
        lock.lock()
        defer { lock.unlock() }
        segmentTotal += count
    }

    /// ④ 一段成功取到课名（同时按日入直方图，并记目标课命中）。
    func recordSegmentName(_ name: String, dayOfWeek: Int) {
        lock.lock()
        defer { lock.unlock() }
        segmentNameExtracted += 1
        dayHistogram[dayOfWeek, default: 0] += 1
        for keyword in JwxtParseDiagnostics.targetKeywords
        where JwxtParseDiagnostics.contains(name, keyword) {
            targetNameExtracted[keyword, default: 0] += 1
        }
    }

    /// ④ 本段里出现了哪些目标关键词（课名抽取**之前**的计数）。
    ///
    /// 必须与 `recordSegmentName` 分开记：只有这样才能区分「段里根本没有这门课」
    /// 与「段里有、但课名没抽出来」—— 后者才是我们要修的解析缺陷。
    func recordSegmentText(_ segment: String) {
        lock.lock()
        defer { lock.unlock() }
        for keyword in JwxtParseDiagnostics.targetKeywords
        where JwxtParseDiagnostics.contains(segment, keyword) {
            targetInSegment[keyword, default: 0] += 1
        }
    }

    /// ④ 一段取不到课名 ⇒ 整段被跳过。
    func recordSegmentNameMissing() {
        lock.lock()
        defer { lock.unlock() }
        segmentNameMissing += 1
    }

    /// ④ 课名抽取失败时，把「为什么」三分记账（原先汇总里那句原因是写死的，等于没测）。
    ///
    /// - Parameters:
    ///   - fontCount: 该段 `font` 元素总数。
    ///   - allBlank: 这些 font 的文本是否全部为空白。
    func recordNameFailure(fontCount: Int, allBlank: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if fontCount == 0 {
            nameFailNoFont += 1
        } else if allBlank {
            nameFailAllBlank += 1
        } else {
            nameFailBlacklisted += 1
        }
    }

    /// ④ 记录一次周次命中处的**形态**（不含任何课名 / 姓名 / 班级）。
    func recordWeekShape(_ shape: String) {
        lock.lock()
        defer { lock.unlock() }
        weekShapes[shape, default: 0] += 1
    }

    /// ②b 记一格：大节行 × 星期列 → 产出课程数。
    ///
    /// - Parameters:
    ///   - periodRow: 大节序号（1 起）。
    ///   - dayOfWeek: 星期（1 = 周一 … 7 = 周日）。
    ///   - courseCount: 该格最终解析出的课程数。
    ///   - looksLikeCourse: 该格原始 innerHTML 是否含课程痕迹（见 `cellLooksLikeCourse`）。
    func recordCellOutcome(periodRow: Int, dayOfWeek: Int, courseCount: Int, looksLikeCourse: Bool) {
        lock.lock()
        defer { lock.unlock() }
        cellGrid[periodRow, default: [:]][dayOfWeek] = JwxtParseDiagnostics.cellToken(
            courseCount: courseCount,
            looksLikeCourse: looksLikeCourse
        )
        if courseCount == 0 {
            if looksLikeCourse { cellLostCount += 1 } else { cellTrulyEmptyCount += 1 }
        }
    }

    /// ②c 记一次「0 门但格子非空」的标记形态（不含任何课程原文）。
    func recordEmptyCellMarkup(_ signature: String) {
        lock.lock()
        defer { lock.unlock() }
        emptyCellMarkups[signature, default: 0] += 1
    }

    /// 一格的显示符号：`●` 1 门、`◐` 2 门以上、`!` 有课程痕迹却 0 门、`·` 原始就空。
    static func cellToken(courseCount: Int, looksLikeCourse: Bool) -> String {
        if courseCount == 0 { return looksLikeCourse ? "!" : "·" }
        return courseCount == 1 ? "●" : "◐"
    }

    /// ④ 周次**命中正则**（真值）。
    func recordWeekRangeMatched() {
        lock.lock()
        defer { lock.unlock() }
        weekRangeMatched += 1
    }

    /// ④ 周次**未命中正则** ⇒ 返回兜底 `1-20`。
    func recordWeekRangeFallback() {
        lock.lock()
        defer { lock.unlock() }
        weekRangeFallback += 1
    }

    /// ④ 节次：`[xx-yy节]` 区间命中（primary）或回落「大节号 × 2」兜底。
    func recordSegmentPeriod(primaryRangeHit: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if primaryRangeHit { periodRangePrimary += 1 } else { periodRangeFallback += 1 }
    }

    /// ⑤ 去重前的课程数 + 目标课命中数。
    func recordParsedCourses(_ courses: [Course]) {
        lock.lock()
        defer { lock.unlock() }
        initialCourseCount = courses.count
        recordTargets(courses, into: &targetInParsed)
    }

    /// ⑤ `mergeDuplicateCourses` 之后的课程数。
    func recordAfterMerge(_ courses: [Course]) {
        lock.lock()
        defer { lock.unlock() }
        afterMergeCount = courses.count
    }

    /// ⑤ `collapseAdjacentCourses` 之后的课程数 + 目标课命中数。
    func recordFinal(_ courses: [Course]) {
        lock.lock()
        defer { lock.unlock() }
        afterCollapseCount = courses.count
        recordTargets(courses, into: &targetInFinal)
    }

    /// ⑤ 交给 UI 落盘（`replaceAllCourses`）的课程数。
    func recordSaved(_ count: Int) {
        lock.lock()
        defer { lock.unlock() }
        savedCourseCount = count
    }

    // MARK: - 汇总

    /// 汇总成一段紧凑多行文本（真机上直接看这一段）。
    ///
    /// 什么都没记到（例如登录就没过、根本没走到抓课表）时返回 `""`，
    /// 调用方据此决定不追加，避免往错误文案里塞一段空表头。
    public func summary() -> String {
        lock.lock()
        defer { lock.unlock() }
        guard responseStatus != nil || responseFailed || tableAttempts > 0 else { return "" }

        var lines: [String] = ["【课表解析诊断】"]

        // ① 原始响应
        if responseFailed {
            lines.append("① 原始响应 成功=否（请求没拿到响应，原因见上方错误文案）")
        } else if let status = responseStatus {
            lines.append(
                "① 原始响应 成功=\(JwxtParseDiagnostics.yesNo((200..<300).contains(status)))"
                + " status=\(status) len=\(htmlLength)"
                + " 原文 tr=\(rawTrCount) td=\(rawTdOpenCount)开/\(rawTdCloseCount)闭"
                + " 特征(timetable=\(JwxtParseDiagnostics.yesNo(hasTimetableId))"
                + " Table1=\(JwxtParseDiagnostics.yesNo(hasTable1))"
                + " kbcontent=\(JwxtParseDiagnostics.yesNo(hasKbcontent)))"
            )
        }

        // ② 表格结构
        let rawInTableText = rawTdInTable >= 0 ? String(rawTdInTable) : "未取到"
        var second = "② 表格 尝试=\(tableAttempts) 节次行=\(periodRows)"
            + " 行-td 直方图=\(JwxtParseDiagnostics.formatIntMap(rowTdHistogram))"
            + " 节次行-td 直方图=\(JwxtParseDiagnostics.formatIntMap(periodRowTdHistogram))"
            + " 跳过行=\(JwxtParseDiagnostics.formatStringMap(skippedRows))"
            + " 树内 tr=\(treeTrCount) td=\(treeTdCount) 嵌套 td=\(treeNestedTdCount)"
            + " 本表原文 td=\(rawInTableText)"
        if rawTdInTable >= 0, treeTdCount != rawTdInTable {
            // 解析前后结构不一致的直接证据：**本表**原文里的 <td 数与解析树里的 td 节点数对不上。
            second += " ⚠ 树内 td(\(treeTdCount)) ≠ 本表原文 <td(\(rawTdInTable))：这张表有漏闭合/嵌套错位迹象"
        }
        lines.append(second)

        // ②b 单元格棋盘：直接回答「某时间段没课」是原始就空、还是有课却没解析出来。
        if !cellGrid.isEmpty {
            var grid = "②b 单元格棋盘(●=1门 ◐=2门以上 ·=原始就空 !=有课程痕迹却0门)"
            grid += " 有痕迹却0门=\(cellLostCount) 原始就空=\(cellTrulyEmptyCount)"
            let maxDay = cellGrid.values.flatMap { $0.keys }.max() ?? 5
            for row in cellGrid.keys.sorted() {
                var line = "\n  大节\(row)(第\(row * 2 - 1)-\(row * 2)节):"
                for day in 1...maxDay {
                    line += " " + (cellGrid[row]?[day] ?? "·")
                }
                grid += line
            }
            if !emptyCellMarkups.isEmpty {
                // 只报「0 门但格子非空」的标记形态：它就是那几格到底长什么样的唯一线索。
                grid += "\n  ②c 0门非空格形态=\(JwxtParseDiagnostics.formatStringMap(emptyCellMarkups))"
            }
            lines.append(grid)
        }

        // ③ 单元格
        lines.append(
            "③ 单元格 候选累计=\(cellCandidateTotal) 选中=\(cellChosenCount)"
            + "(按 title=教师 命中 \(cellChosenByTeacherTitle) / 取首个 \(cellChosenFirst))"
            + " kbcontent1 兜底=\(cellKbcontent1Fallback) 空内容跳过=\(cellSkippedEmpty)"
        )
        lines.append(
            "③b 每格候选 div 数直方图=\(JwxtParseDiagnostics.formatIntMap(candidateHistogram))"
            + " 多候选格=\(multiCandidateCells)(原版每格只取一个候选)"
        )

        // ④ 课程文本
        lines.append(
            "④ 文本 段=\(segmentTotal) 课名成功=\(segmentNameExtracted) 课名失败=\(segmentNameMissing)"
            + "(无 font:\(nameFailNoFont) font 全空:\(nameFailAllBlank) 文本全被黑名单:\(nameFailBlacklisted))"
            + " 周次命中=\(weekRangeMatched)/兜底 \(weekRangeFallback)"
            + " 节次区间=\(periodRangePrimary)/兜底 \(periodRangeFallback)"
            + " 日分布=\(JwxtParseDiagnostics.formatIntMap(dayHistogram))"
        )
        lines.append(
            "④b 周次形态(数字→D/汉字→C，连续同类已折叠)=\(JwxtParseDiagnostics.formatStringMap(weekShapes))"
        )

        // ⑤ 过滤与保存
        lines.append(
            "⑤ 过滤与保存 初始=\(initialCourseCount) 去重后=\(afterMergeCount)"
            + " 连排合并后=\(afterCollapseCount) 返回(=本地全量覆盖)=\(savedCourseCount)"
        )

        // 目标课逐段追踪
        lines.append("目标课追踪（包含式、大小写不敏感）：")
        for keyword in JwxtParseDiagnostics.targetKeywords {
            let raw = JwxtParseDiagnostics.yesNo(targetMentionedInRawHTML.contains(keyword))
            let cell = targetLocatedInCell[keyword] ?? 0
            let segment = targetInSegment[keyword] ?? 0
            let name = targetNameExtracted[keyword] ?? 0
            let parsed = targetInParsed[keyword] ?? 0
            let final = targetInFinal[keyword] ?? 0
            // 「段 > 课名」就是**课名抽取**吃掉的次数；「单元格 > 段」说明那门课所在的分段
            // 根本没进 parseKbContent（例如同格多课只取了一个候选 div）。
            var line = "  \(keyword) 原文=\(raw) 单元格=\(cell) 段=\(segment) 课名=\(name)"
                + " 解析=\(parsed) 最终=\(final)"
            if segment > name {
                line += "（课名抽取丢掉 \(segment - name) 次）"
            } else if cell > segment {
                line += "（同格多课只取其一，丢掉 \(cell - segment) 次）"
            }
            if parsed > final {
                line += "（被去重/合排吃掉 \(parsed - final) 条）"
            }
            lines.append(line)
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - 工具（全部无副作用）

    private func recordTargets(_ courses: [Course], into store: inout [String: Int]) {
        for keyword in JwxtParseDiagnostics.targetKeywords {
            store[keyword, default: 0] += courses.filter {
                JwxtParseDiagnostics.contains($0.name, keyword)
            }.count
        }
    }

    static func yesNo(_ value: Bool) -> String { value ? "有" : "无" }

    /// 单双周取值（`0/1/2`）的可读文本，供展示层诊断复用。
    static func parityText(_ value: Int) -> String {
        switch value {
        case 1: return "单"
        case 2: return "双"
        default: return "无"
        }
    }

    /// 包含式、大小写不敏感匹配。
    static func contains(_ haystack: String, _ keyword: String) -> Bool {
        guard !haystack.isEmpty, !keyword.isEmpty else { return false }
        return haystack.range(of: keyword, options: .caseInsensitive) != nil
    }

    /// `needle` 在 `haystack` 里出现多少次（大小写不敏感、不重叠）。
    static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty, !haystack.isEmpty else { return 0 }
        var count = 0
        var searchStart = haystack.startIndex
        while searchStart < haystack.endIndex,
              let found = haystack.range(
                  of: needle,
                  options: .caseInsensitive,
                  range: searchStart..<haystack.endIndex
              ) {
            count += 1
            searchStart = found.upperBound
        }
        return count
    }

    private static func formatIntMap(_ map: [Int: Int]) -> String {
        guard !map.isEmpty else { return "{}" }
        return "{" + map.keys.sorted().map { "\($0):\(map[$0] ?? 0)" }.joined(separator: ",") + "}"
    }

    private static func formatStringMap(_ map: [String: Int]) -> String {
        guard !map.isEmpty else { return "{}" }
        return "{" + map.keys.sorted().map { "\($0):\(map[$0] ?? 0)" }.joined(separator: ",") + "}"
    }
}
