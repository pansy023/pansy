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

    func testSplitCourseSegmentsByCellMarkerThenCutsAtTdClose() {
        // 真实标记：`left=100,top=50')">`（`QiangzhiJwxtParser.java:342`）。
        let marker = "left=100,top=50')\">"
        XCTAssertEqual(
            QiangzhiJwxtParser.splitCourseSegments(marker + "AAA</td>" + marker + "BBB</td>"),
            ["AAA", "BBB"]
        )
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
        XCTAssertEqual(QianzhiJwxtParser.extractPeriodRange("1-16(周)[03-04节]")?.0, 3)
        XCTAssertEqual(QianzhiJwxtParser.extractPeriodRange("1-16(周)[03-04节]")?.1, 4)
        // 括号写法 `[3-4节]` 同样命中。
        XCTAssertEqual(QianzhiJwxtParser.extractPeriodRange("[3-4节]")?.0, 3)
        // 不合法（end < start）返回 nil，交回兜底。
        XCTAssertNil(QianzhiJwxtParser.extractPeriodRange("[4-3节]"))
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

    // MARK: - 同步层文案（`sync/JwxtTimetableSync.java:85`）

    func testLoginFailureMessageMatchesAndroid() {
        XCTAssertEqual(
            JwxtSyncError.loginFailed.errorDescription,
            "登录教务系统失败，请检查账号密码"
        )
    }
}
