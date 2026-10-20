import XCTest
@testable import KebiaoCore

/// `QiangzhiJwxtParser` / `JwxtTimetableSync` 的单元测试。
///
/// 期望值来源：`docs/recon/02-jwxt-login-and-parser.md` §4（抓取与两种解析风格）、
/// §4.5（课程块切分）、§4.7（字段抽取）、§5.1（周次表）、§5.2（节次）、§7.2（两层去重）
/// 以及 Android 源码 `QiangzhiJwxtParser.java` 的真实常量（配色 palette `:63`、
/// 单元格标记 `:342`、异常文案 `sync/JwxtTimetableSync.java:85`）。
///
/// 注意：DO 风格样例 HTML 是**按原版选择器与黑名单手工构造**的最小可用样本，
/// 不是抓下来的真实页面；它只用来证明 Swift 版的选择器/抽取器与 Android 同规则。
final class JwxtTimetableParserTests: XCTestCase {

    private let parser = QiangzhiJwxtParser(baseURL: UserCredentials.defaultJwxtUrl)

    // MARK: - 风格 A：parseDoStyle（recon §4.3、§9）

    /// `table#timetable` + `th` 含「第」「大节」+ 直接子 `td` 的第 0 列 = 周一。
    /// 说明：`周次(节次)` 这个 `font` 被**刻意放到最前**。`extractWeekRange` 的归一化是
    /// 「标签→空格 → `&nbsp;`→空格 → **删掉所有空格**」，所以「教室 `A310`」紧挨
    /// 「`1-16(周)`」时会被粘成 `A3101-16(周)`，正则从左往右第一个命中就变成 `3101-16`。
    /// 这里把周次前置只是为了让本样例的周次唯一可解析；抽取逻辑本身与原版逐字一致。
    private let doStyleHTML = """
    <table id="timetable">
    <tr><th>节次</th><th>星期一</th><th>星期二</th></tr>
    <tr>
    <th>第一大节</th>
    <td><div class="kbcontent"><font title="周次(节次)">1-16(周)[01-02节]</font><br><font title="课程" name="ktmc">高等数学</font><br><font title="教师">张明</font><br><font title="教学楼" name="jxlmc">6号教学楼</font><br><font title="教室">A310</font></div></td>
    <td></td>
    </tr>
    </table>
    """

    func testParseDoStyleBuildsCourseWithAllFields() {
        let courses = parser.parseDoStyle(doStyleHTML)
        XCTAssertEqual(courses.count, 1)
        guard let course = courses.first else { return }
        // 课名「高等数学」→ 首个 UTF-16 码元 0x9AD8 = 39640，39640 % 10 = 0 → palette[0]。
        XCTAssertEqual(
            course,
            Course(
                id: 0,
                name: "高等数学",
                teacher: "张明",
                location: "6号教学楼 A310",   // 楼名 + 一个空格 + 教室
                dayOfWeek: 1,                  // 第 0 个 td = 周一
                startPeriod: 1,                // 来自 `[01-02节]`
                endPeriod: 2,
                color: -11751600,              // palette[0]
                weekRange: "1-16",
                startWeek: 1,
                endWeek: 16,
                isOdd: 0
            )
        )
    }

    /// 空白单元格（无 `div.kbcontent`，或内容为 `&nbsp;`）不产生课程。
    func testParseDoStyleSkipsBlankCells() {
        let html = """
        <table id="timetable">
        <tr><th>第一大节</th><td><div class="kbcontent">&nbsp;</div></td></tr>
        </table>
        """
        XCTAssertTrue(parser.parseDoStyle(html).isEmpty)
    }

    // MARK: - 课程块切分（recon §4.5）

    func testSplitCourseSegmentsByFiveOrMoreDashes() {
        XCTAssertEqual(
            QiangzhiJwxtParser.splitCourseSegments("A-----B---------C"),
            ["A", "B", "C"]
        )
    }

    func testSplitCourseSegmentsTreatsWholeTextAsOneCourseWithoutMarker() {
        XCTAssertEqual(QiangzhiJwxtParser.splitCourseSegments(" 只有一门课 "), ["只有一门课"])
    }

    /// `splitCourseSegments`（`QiangzhiJwxtParser.java:952-1009`）的**真实**行为：
    /// `:954` 用 `-{5,}` 切分，`:967` 判空用的是 `!segments.isEmpty()`；而 Kotlin 的
    /// `Regex.split` 在**无命中**时返回单元素列表 `[str]`，`trim` + `isBlank` 过滤后仍非空
    /// → 直接返回整段原文。因此 `:985` 起「按 `left=100,top=50')\">` 切分」的分支对非空输入
    /// **不可达**（原版死代码），单元格里带标记也不会被拆开。
    func testSplitCourseSegmentsWithoutDashesReturnsWholeTextEvenWithCellMarker() {
        // 真实标记：`left=100,top=50')">`（`QiangzhiJwxtParser.java:342`）。
        let marker = "left=100,top=50')\">"
        let html = marker + "AAA</td>" + marker + "BBB</td>"
        XCTAssertEqual(QiangzhiJwxtParser.splitCourseSegments(html), [html])
    }

    // MARK: - 周次（recon §5.1）

    func testExtractWeekRangeTable() {
        // 正则要求周次数字后面**紧跟** `(周)` / `(单)` / `(双)`（`QiangzhiJwxtParser.java:1227`）。
        let cases: [(input: String, expected: String)] = [
            ("1-16(周)", "1-16"),
            ("1,3,5(周)", "1,3,5"),
            ("1-16(单)", "1-16"),
            ("1-16(双)", "1-16"),
            ("1,3,5(单)", "1,3,5"),
            ("周次1 - 16 (周)", "1-16"),   // 删「周次」+ 删所有空格
            ("1~16(周)", "16"),            // 正则未锚定：从「16」起命中，只剩 16
            ("", "1-20"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(parser.extractWeekRange(input), expected, "输入=\(input)")
        }
    }

    func testParseWeekMetaTable() {
        let cases: [(range: String, html: String, start: Int, end: Int, odd: Int)] = [
            ("1-16", "", 1, 16, 0),
            ("1,3,5", "", 1, 5, 0),          // 非连续周次被压成 min…max
            ("1-16", "(单)", 1, 16, 1),
            ("1-16", "(双)", 1, 16, 2),
            ("1,3,5", "单周", 1, 5, 1),
            ("", "", 1, 20, 0),              // 兜底
        ]
        for c in cases {
            let meta = QiangzhiJwxtParser.parseWeekMeta(weekRange: c.range, html: c.html)
            XCTAssertEqual(meta.startWeek, c.start, "range=\(c.range) html=\(c.html)")
            XCTAssertEqual(meta.endWeek, c.end, "range=\(c.range) html=\(c.html)")
            XCTAssertEqual(meta.isOdd, c.odd, "range=\(c.range) html=\(c.html)")
        }
    }

    // MARK: - 节次（recon §5.2）

    func testExtractPeriodRangePrefersXYJie() {
        XCTAssertEqual(QiangzhiJwxtParser.extractPeriodRange("1-16(周)[03-04节]")?.0, 3)
        XCTAssertEqual(QiangzhiJwxtParser.extractPeriodRange("1-16(周)[03-04节]")?.1, 4)
        // 括号写法 `[3-4节]` 同样命中。
        XCTAssertEqual(QiangzhiJwxtParser.extractPeriodRange("[3-4节]")?.0, 3)
        // 不合法（end < start）返回 nil，交回兜底。
        XCTAssertNil(QiangzhiJwxtParser.extractPeriodRange("[4-3节]"))
    }

    // MARK: - 配色（recon §4.7、§5）

    func testGetStableColorUsesFirstUTF16CodeUnit() {
        // palette 逐字取自 `QiangzhiJwxtParser.java:63`。
        XCTAssertEqual(QiangzhiJwxtParser.palette.count, 10)
        XCTAssertEqual(QiangzhiJwxtParser.getStableColor("高等数学"), -11751600) // 39640 % 10 = 0
        XCTAssertEqual(QiangzhiJwxtParser.getStableColor("a"), -10453621)        // 97 % 10 = 7
        XCTAssertEqual(QiangzhiJwxtParser.getStableColor(""), -11751600)        // 空串 → palette[0]
    }

    // MARK: - 两层去重（recon §7.2）

    func testMergeDuplicateCoursesKeepsFirstAndFillsBlankFields() {
        let first = Course(
            id: 0, name: "英语", teacher: "", location: "A101",
            dayOfWeek: 2, startPeriod: 1, endPeriod: 2, color: 0,
            weekRange: "1-16", startWeek: 1, endWeek: 16, isOdd: 0
        )
        var second = first
        second.teacher = "李华"      // 同键（判重不含 teacher/location/color）
        second.color = 999

        let merged = QiangzhiJwxtParser.mergeDuplicateCourses([first, second])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].teacher, "李华")     // 首次出现的空白项被补齐
        XCTAssertEqual(merged[0].location, "A101")
        XCTAssertEqual(merged[0].color, 0)            // color 不参与补齐，保留首个
    }

    func testCollapseAdjacentCoursesMergesConsecutivePeriods() {
        let a = Course(
            id: 0, name: "体育", teacher: "王强", location: "操场",
            dayOfWeek: 3, startPeriod: 1, endPeriod: 2, color: 5,
            weekRange: "1-16", startWeek: 1, endWeek: 16, isOdd: 0
        )
        var b = a
        b.startPeriod = 3
        b.endPeriod = 4

        let collapsed = QiangzhiJwxtParser.collapseAdjacentCourses([a, b])
        XCTAssertEqual(collapsed.count, 1)
        XCTAssertEqual(collapsed[0].startPeriod, 1)   // 保留前者起始
        XCTAssertEqual(collapsed[0].endPeriod, 4)     // 取后者结束
    }

    func testCollapseAdjacentCoursesKeepsNonAdjacentSeparate() {
        let a = Course(
            id: 0, name: "体育", teacher: "王强", location: "操场",
            dayOfWeek: 3, startPeriod: 1, endPeriod: 2, color: 5,
            weekRange: "1-16", startWeek: 1, endWeek: 16, isOdd: 0
        )
        var b = a
        b.startPeriod = 7                            // 不连续（2 与 7 之间断开）
        b.endPeriod = 8

        XCTAssertEqual(QiangzhiJwxtParser.collapseAdjacentCourses([a, b]).count, 2)
    }

    // MARK: - 抓课表失败必须显式报错（不再静默返回空表；文件头「有意差异 4」）

    /// 登录页最小样本：含 `Logon.do?method=logon` 与 `userAccount`，且**不含**任何课表特征串。
    /// 形状照抄实测副本（`<title>登录</title>`，HTTP 200、无 302、无 `Location`）。
    private let loginPageHTML = """
    <html><head><title>登录</title></head>
    <body><form action="/Logon.do?method=logon" method="post">
    <input name="userAccount"><input name="userPassword"><input name="encoded">
    </form></body></html>
    """

    func testIsLoginPageDetectsLoginPageBody() {
        // 服务端未认证时直接回 200 + 登录页：最终 URL 与 Location 都不含 Login。
        XCTAssertTrue(QiangzhiJwxtParser.isLoginPage(
            body: loginPageHTML,
            finalURL: "https://jwgl.xihang.com.cn/jsxsd/xskb/xskb_list.do",
            location: nil
        ))
    }

    func testIsLoginPageReturnsFalseForTimetableBody() {
        XCTAssertFalse(QiangzhiJwxtParser.isLoginPage(
            body: doStyleHTML,
            finalURL: "https://jwgl.xihang.com.cn/jsxsd/xskb/xskb_list.do",
            location: nil
        ))
    }

    /// `table#timetable` 没命中时，宽松兜底必须还能拿到课程（严格超集，不改变原结果）。
    func testParseDoStyleRelaxedFallsBackWhenTableIDIsMissing() {
        let html = doStyleHTML.replacingOccurrences(of: "<table id=\"timetable\">", with: "<table>")
        XCTAssertTrue(parser.parseDoStyle(html).isEmpty)
        XCTAssertEqual(parser.parseDoStyleRelaxed(html).count, 1)
    }

    /// 抓课表那一跳拿到登录页时，必须抛 `sessionExpired` —— 这正是真机上
    /// 「未获取到课表数据；已保留本地原有课程。」那句误导性提示的根因。
    func testFetchTimetableThrowsSessionExpiredInsteadOfReturningEmpty() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [JwxtStubURLProtocol.self]
        let body = Data(loginPageHTML.utf8)
        JwxtStubURLProtocol.setResponder { _ in (200, body) }
        defer { JwxtStubURLProtocol.setResponder(nil) }

        let stubbed = QiangzhiJwxtParser(
            baseURL: UserCredentials.defaultJwxtUrl,
            configuration: configuration
        )
        do {
            let courses = try await stubbed.fetchTimetable()
            XCTFail("应抛 sessionExpired，而不是静默返回空表；实际得到 \(courses.count) 门课")
        } catch let error as JwxtFetchError {
            guard case .sessionExpired = error else {
                XCTFail("应为 sessionExpired，实际 \(error)")
                return
            }
            XCTAssertTrue(
                error.errorDescription?.contains("会话已失效") == true,
                "诊断文案应说明会话失效，实际：\(error.errorDescription ?? "nil")"
            )
        } catch {
            XCTFail("应为 JwxtFetchError，实际 \(error)")
        }
    }

    // MARK: - 同步层文案（`sync/JwxtTimetableSync.java:85`）

    func testLoginFailureMessageMatchesAndroid() {
        // Android 原文「登录教务系统失败，请检查账号密码」逐字作为前缀保留，
        // iOS 侧在后面括号里追加具体诊断（仅此处不同）。
        XCTAssertEqual(
            JwxtSyncError.loginFailed(detail: "服务端判定账号或密码错误").errorDescription,
            "登录教务系统失败，请检查账号密码（诊断：服务端判定账号或密码错误）"
        )
        XCTAssertEqual(
            JwxtSyncError.loginFailed(detail: "网络/传输异常：x")
                .errorDescription?.hasPrefix("登录教务系统失败，请检查账号密码"),
            true
        )
    }

    // MARK: - 分段诊断（本轮只加计数，不改解析 / 过滤 / 去重规则）

    /// 仿真 DO 风格样本：**按 `docs/recon/02-jwxt-login-and-parser.md` §4.3 的结构手工仿真**，
    /// 刻意放进「英语 / 体育 / 高等数学」三门目标课 + 1 个空白单元格。
    ///
    /// ⚠️ 本机**没有真实课表响应样本**（仓库里只有登录页样本），所以这份 HTML **不能**用来
    /// 断言「真机上三门课到底丢在哪一环」—— 那必须等真机同步后看诊断汇总。这条用例只证明：
    /// 1. 诊断埋点**没有改变**解析结果（同样的输入，课程数与字段照旧）；
    /// 2. 五段计数与三门目标课的逐段追踪，在该结构下**确实按预期记录**。
    private let diagnosticsFixtureHTML = """
    <table id="timetable">
    <tr><th>节次</th><th>星期一</th><th>星期二</th><th>星期三</th></tr>
    <tr>
    <th>第一大节</th>
    <td><div class="kbcontent"><font title="周次(节次)">1-16(周)[01-02节]</font><br><font title="课程" name="ktmc">大学英语(一)</font><br><font title="教师">张明</font><br><font title="教学楼" name="jxlmc">6号教学楼</font><br><font title="教室">A310</font></div></td>
    <td><div class="kbcontent"><font title="周次(节次)">1-16(周)[01-02节]</font><br><font title="课程" name="ktmc">体育</font><br><font title="教师">李华</font><br><font title="教室">操场</font></div></td>
    <td><div class="kbcontent"><font title="周次(节次)">1-16(周)[01-02节]</font><br><font title="课程" name="ktmc">高等数学</font><br><font title="教师">王强</font><br><font title="教室">B101</font></div></td>
    <td></td>
    </tr>
    </table>
    """

    func testFetchTimetableEmitsStageDiagnosticsAndTracksTargetCourses() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [JwxtStubURLProtocol.self]
        JwxtStubURLProtocol.setResponder { _ in (200, Data(diagnosticsFixtureHTML.utf8)) }
        defer { JwxtStubURLProtocol.setResponder(nil) }

        let stubbed = QiangzhiJwxtParser(
            baseURL: UserCredentials.defaultJwxtUrl,
            configuration: configuration
        )
        let diagnostics = JwxtParseDiagnostics()
        stubbed.diagnostics = diagnostics

        let courses = try await stubbed.fetchTimetable()
        let report = diagnostics.summary()

        // 诊断不改解析结果：三门目标课各一门，空白单元格不产生课程。
        XCTAssertEqual(courses.count, 3)
        XCTAssertEqual(Set(courses.map(\.name)), ["大学英语(一)", "体育", "高等数学"])

        // 五段都在汇总里出现。
        for stage in ["① 原始响应", "② 表格", "③ 单元格", "④ 文本", "⑤ 过滤与保存"] {
            XCTAssertTrue(report.contains(stage), "诊断汇总缺少阶段：\(stage)\n\(report)")
        }
        // ① 原文里的 tr / td 出现次数与本样本一致（2 行、4 个 td、4 个闭合）。
        XCTAssertTrue(report.contains("原文 tr=2"), report)
        XCTAssertTrue(report.contains("td=4开/4闭"), report)
        // ② 解析树与原文一致 ⇒ 不应出现「结构不一致」告警。
        XCTAssertTrue(report.contains("树内 tr=2 td=4 嵌套 td=0"), report)
        XCTAssertFalse(report.contains("解析树 td"), "结构正常时不应出现不一致告警：\(report)")
        // ③ 4 个单元格：3 个选中内容、1 个空内容被跳过。
        XCTAssertTrue(report.contains("选中=3"), report)
        XCTAssertTrue(report.contains("空内容跳过=1"), report)
        // ④ 3 段全部取到课名，周次 / 节次都命中而非兜底。
        XCTAssertTrue(report.contains("段=3 课名成功=3 课名失败=0"), report)
        XCTAssertTrue(report.contains("周次命中=3/兜底 0"), report)
        XCTAssertTrue(report.contains("节次区间=3/兜底 0"), report)
        // ⑤ 三门课没被去重 / 连排合并吃掉，返回数 = 落盘数。
        XCTAssertTrue(
            report.contains("初始=3 去重后=3 连排合并后=3 返回(=本地全量覆盖)=3"),
            report
        )

        // 三门目标课逐段追踪：原文有 / 定位到单元格 / 取到课名 / 解析出 / 最终保留。
        XCTAssertTrue(report.contains("英语 原文=有 单元格=1 课名=1 解析=1 最终=1"), report)
        XCTAssertTrue(report.contains("体育 原文=有 单元格=1 课名=1 解析=1 最终=1"), report)
        XCTAssertTrue(report.contains("高等数学 原文=有 单元格=1 课名=1 解析=1 最终=1"), report)

        // 安全红线：汇总里只有计数、阶段名与目标课关键词，不含凭证 / Cookie / 令牌字样。
        for banned in ["password", "useraccount", "encoded", "jsessionid", "bzb_jsxsd"] {
            XCTAssertFalse(
                report.lowercased().contains(banned),
                "诊断汇总出现了不该有的敏感字样：\(banned)\n\(report)"
            )
        }
    }
}

/// 极简 `URLProtocol` 桩：让 `JwxtSession` 的请求拿到固定响应。
///
/// 用途单一 —— 锁定「抓课表拿到登录页时必须抛错、不能静默返回空表」。
/// 本包 `swift-tools-version: 5.9`（Swift 5 语言模式），静态可变状态用 `NSLock` 保护即可。
final class JwxtStubURLProtocol: URLProtocol {

    /// `(statusCode, body)`；未设置时按 404 处理。
    private static var responder: ((URLRequest) -> (Int, Data))?
    private static let lock = NSLock()

    static func setResponder(_ value: ((URLRequest) -> (Int, Data))?) {
        lock.lock()
        defer { lock.unlock() }
        responder = value
    }

    private static func currentResponder() -> ((URLRequest) -> (Int, Data))? {
        lock.lock()
        defer { lock.unlock() }
        return responder
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let responder = JwxtStubURLProtocol.currentResponder(),
              let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, data) = responder(request)
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html; charset=utf-8"]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
