import XCTest
@testable import KebiaoCore

/// 周次与日期算法测试。
///
/// 期望值来源：
/// - `TimetableScreenKt.java:301-325`（当前教学周、`第N周`、`isOddWeek`）
/// - `:258-279`（一周日期标签）
/// - `:366-442`（`courseOccursInWeek`）
final class WeekLogicTests: XCTestCase {

    /// 固定时区，避免测试结果随运行机器的本地时区变化。
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_CN")
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        return calendar.date(from: components)!
    }

    private func course(
        name: String = "高等数学",
        startWeek: Int = 1,
        endWeek: Int = 20,
        isOdd: Int = 0,
        weekRange: String = ""
    ) -> Course {
        Course(
            name: name,
            teacher: "张老师",
            location: "教学楼A 101",
            dayOfWeek: 1,
            startPeriod: 1,
            endPeriod: 2,
            color: 0,
            weekRange: weekRange,
            startWeek: startWeek,
            endWeek: endWeek,
            isOdd: isOdd
        )
    }

    // MARK: - isOddWeek

    func testIsOddWeekMatchesJavaModulo() {
        XCTAssertTrue(WeekLogic.isOddWeek(1))
        XCTAssertFalse(WeekLogic.isOddWeek(2))
        XCTAssertTrue(WeekLogic.isOddWeek(3))
        XCTAssertFalse(WeekLogic.isOddWeek(4))
        XCTAssertTrue(WeekLogic.isOddWeek(21))
    }

    // MARK: - courseOccursInWeek：不依赖 weekRange 文本的分支

    func testNonPositiveWeekNeverOccurs() {
        let sut = course()
        XCTAssertFalse(WeekLogic.courseOccursInWeek(sut, week: 0))
        XCTAssertFalse(WeekLogic.courseOccursInWeek(sut, week: -3))
    }

    func testWeekOutsideStartEndRangeNeverOccurs() {
        let sut = course(startWeek: 5, endWeek: 8)
        XCTAssertFalse(WeekLogic.courseOccursInWeek(sut, week: 4))
        XCTAssertFalse(WeekLogic.courseOccursInWeek(sut, week: 9))
        XCTAssertTrue(WeekLogic.courseOccursInWeek(sut, week: 5))
        XCTAssertTrue(WeekLogic.courseOccursInWeek(sut, week: 8))
    }

    func testOddParitySkipsEvenWeeks() {
        let sut = course(isOdd: 1)
        XCTAssertTrue(WeekLogic.courseOccursInWeek(sut, week: 1))
        XCTAssertFalse(WeekLogic.courseOccursInWeek(sut, week: 2))
        XCTAssertTrue(WeekLogic.courseOccursInWeek(sut, week: 3))
    }

    func testEvenParitySkipsOddWeeks() {
        let sut = course(isOdd: 2)
        XCTAssertFalse(WeekLogic.courseOccursInWeek(sut, week: 1))
        XCTAssertTrue(WeekLogic.courseOccursInWeek(sut, week: 2))
        XCTAssertFalse(WeekLogic.courseOccursInWeek(sut, week: 3))
    }

    func testUnknownParityValueIsTreatedAsEvery() {
        // 原版是 `if (isOdd == 1) … else if (isOdd == 2) …`，其它值不做单双周过滤。
        let sut = course(isOdd: 7)
        XCTAssertTrue(WeekLogic.courseOccursInWeek(sut, week: 1))
        XCTAssertTrue(WeekLogic.courseOccursInWeek(sut, week: 2))
    }

    // MARK: - courseOccursInWeek：weekRange 文本分支

    func testBlankWeekRangeOccursEveryWeekInStartEndRange() {
        let sut = course(weekRange: "   ")
        XCTAssertTrue(WeekLogic.courseOccursInWeek(sut, week: 1))
        XCTAssertTrue(WeekLogic.courseOccursInWeek(sut, week: 2))
    }

    func testWeekRangeWithoutAsciiDigitsOccursEveryWeek() {
        // 原版：清洗后若不含 `\d` 就 return true（如 "每周"）。
        let sut = course(weekRange: "每周")
        XCTAssertTrue(WeekLogic.courseOccursInWeek(sut, week: 1))
        XCTAssertTrue(WeekLogic.courseOccursInWeek(sut, week: 2))
    }

    func testWeekRangeSingleBlockKeepsEveryWeekSemantics() {
        // 已由 smali 逐指令确证：`TimetableScreenKt.smali:9676-9703` 的收尾判定是
        //   if (contains("单")) return isOddWeek(week)
        //   if (contains("双")) return !isOddWeek(week)
        //   return true
        // 所以「1-16」这种不带单/双字样的区间是**每周都上课**。
        // jadx 把这段收尾删空了（`:431-437` 只剩 `if (!contains$default) { }`），
        // 照它字面实现会反向成「只在单周」——本断言就是那条回归防线。
        let sut = course(weekRange: "1-16")
        XCTAssertTrue(WeekLogic.courseOccursInWeek(sut, week: 1))
        XCTAssertTrue(WeekLogic.courseOccursInWeek(sut, week: 2))
        XCTAssertTrue(WeekLogic.courseOccursInWeek(sut, week: 16))
        XCTAssertFalse(WeekLogic.courseOccursInWeek(sut, week: 17))
    }

    func testWeekRangeBareNumberListUsesEveryWeekSemantics() {
        // "1,3,5" 走单数字段 → 与区间段共用同一段收尾判定（smali `:9663-9676`）。
        // jadx 版会把命中的周次判成 `return false`（源码 `:441`），即整门课消失。
        let sut = course(weekRange: "1,3,5")
        XCTAssertTrue(WeekLogic.courseOccursInWeek(sut, week: 1))
        XCTAssertFalse(WeekLogic.courseOccursInWeek(sut, week: 2))
        XCTAssertTrue(WeekLogic.courseOccursInWeek(sut, week: 3))
        XCTAssertFalse(WeekLogic.courseOccursInWeek(sut, week: 4))
        XCTAssertTrue(WeekLogic.courseOccursInWeek(sut, week: 5))
        XCTAssertFalse(WeekLogic.courseOccursInWeek(sut, week: 6))
    }

    func testWeekRangeOddSuffixOnlyAllowsOddWeeks() {
        // "1-16周(单)" → contains("单") 为真 → 收尾判定返回 isOddWeek(week)。
        let sut = course(weekRange: "1-16周(单)")
        XCTAssertTrue(WeekLogic.courseOccursInWeek(sut, week: 1))
        XCTAssertFalse(WeekLogic.courseOccursInWeek(sut, week: 2))
        XCTAssertTrue(WeekLogic.courseOccursInWeek(sut, week: 3))
        XCTAssertFalse(WeekLogic.courseOccursInWeek(sut, week: 16))
    }

    func testWeekRangeEvenSuffixOnlyAllowsEvenWeeks() {
        // "1-16周(双)" → contains("双") 为真 → 收尾判定返回 !isOddWeek(week)。
        let sut = course(weekRange: "1-16周(双)")
        XCTAssertFalse(WeekLogic.courseOccursInWeek(sut, week: 1))
        XCTAssertTrue(WeekLogic.courseOccursInWeek(sut, week: 2))
        XCTAssertFalse(WeekLogic.courseOccursInWeek(sut, week: 3))
        XCTAssertTrue(WeekLogic.courseOccursInWeek(sut, week: 16))
    }

    func testWeekRangeWithNoDigitsAtAllReturnsTrue() {
        // "单周" 不含数字 → 第 6 步就 return true，单/双字样根本不参与判定。
        let sut = course(weekRange: "单周")
        XCTAssertTrue(WeekLogic.courseOccursInWeek(sut, week: 1))
        XCTAssertTrue(WeekLogic.courseOccursInWeek(sut, week: 2))
    }

    func testWeekRangeRangeMatchingNothingReturnsFalse() {
        // 遍历完所有段仍未命中 → `return false`（源码 `:441`）。
        let sut = course(weekRange: "1-4")
        XCTAssertTrue(WeekLogic.courseOccursInWeek(sut, week: 2))
        XCTAssertFalse(WeekLogic.courseOccursInWeek(sut, week: 5))
    }

    func testWeekRangeWithChinesePunctuationIsNormalised() {
        // 清洗规则：全角逗号/顿号/分号统一成半角逗号。
        let sut = course(weekRange: "1-4，7-8")
        XCTAssertTrue(WeekLogic.courseOccursInWeek(sut, week: 2))
        XCTAssertTrue(WeekLogic.courseOccursInWeek(sut, week: 7))
        XCTAssertFalse(WeekLogic.courseOccursInWeek(sut, week: 5))
    }

    func testWeekRangeSuffixesAreStripped() {
        // "第1-16周" 去掉 "第"/"周" 后与 "1-16" 等价。
        let sut = course(weekRange: "第1-16周")
        XCTAssertTrue(WeekLogic.courseOccursInWeek(sut, week: 3))
        XCTAssertFalse(WeekLogic.courseOccursInWeek(sut, week: 17))
    }

    func testWeekRangeSingleNumbers() {
        // 单数字段（如 "3"）命中的分支：jadx 渲染为空 body，此处按区间分支同款处理。
        let sut = course(weekRange: "3")
        XCTAssertTrue(WeekLogic.courseOccursInWeek(sut, week: 3))
        XCTAssertFalse(WeekLogic.courseOccursInWeek(sut, week: 4))
    }

    func testEmptyWeekRangePartsFallBackToEveryWeek() {
        // 清洗后只剩分隔符 → parts 为空 → return true。
        let sut = course(weekRange: " , , ")
        XCTAssertTrue(WeekLogic.courseOccursInWeek(sut, week: 2))
    }

    // MARK: - 当前教学周

    func testTeachingWeekWithoutStartDateIsOne() {
        XCTAssertEqual(WeekLogic.teachingWeek(firstWeekStartDate: nil, semesterWeeks: 20, now: date(2026, 10, 15), calendar: calendar), 1)
        XCTAssertEqual(WeekLogic.teachingWeek(firstWeekStartDate: "  ", semesterWeeks: 20, now: date(2026, 10, 15), calendar: calendar), 1)
    }

    func testTeachingWeekRejectsMalformedStartDate() {
        // `SimpleDateFormat.setLenient(false)`：非法日期解析失败 → 1。
        XCTAssertEqual(WeekLogic.teachingWeek(firstWeekStartDate: "2026/09/01", semesterWeeks: 20, now: date(2026, 10, 15), calendar: calendar), 1)
        XCTAssertEqual(WeekLogic.teachingWeek(firstWeekStartDate: "2026-13-01", semesterWeeks: 20, now: date(2026, 10, 15), calendar: calendar), 1)
    }

    func testTeachingWeekCountsSevenDayBlocks() {
        let start = "2026-09-01"
        // 开学当天与第 6 天都还是第 1 周。
        XCTAssertEqual(WeekLogic.teachingWeek(firstWeekStartDate: start, semesterWeeks: 20, now: date(2026, 9, 1), calendar: calendar), 1)
        XCTAssertEqual(WeekLogic.teachingWeek(firstWeekStartDate: start, semesterWeeks: 20, now: date(2026, 9, 7), calendar: calendar), 1)
        // 第 7 天进入第 2 周。
        XCTAssertEqual(WeekLogic.teachingWeek(firstWeekStartDate: start, semesterWeeks: 20, now: date(2026, 9, 8), calendar: calendar), 2)
        XCTAssertEqual(WeekLogic.teachingWeek(firstWeekStartDate: start, semesterWeeks: 20, now: date(2026, 10, 15), calendar: calendar), 7)
    }

    func testTeachingWeekIsClampedToSemesterWeeks() {
        XCTAssertEqual(WeekLogic.teachingWeek(firstWeekStartDate: "2026-09-01", semesterWeeks: 4, now: date(2026, 12, 1), calendar: calendar), 4)
    }

    func testTeachingWeekClampsNonPositiveSemesterWeeksToOne() {
        // 原版 `coerceIn(1, max(semesterWeeks, 1))`。
        XCTAssertEqual(WeekLogic.teachingWeek(firstWeekStartDate: "2026-09-08", semesterWeeks: 0, now: date(2026, 10, 15), calendar: calendar), 1)
    }

    func testTeachingWeekBeforeSemesterStartIsOne() {
        // 开学日之前 days < 0 → 1。
        XCTAssertEqual(WeekLogic.teachingWeek(firstWeekStartDate: "2026-09-01", semesterWeeks: 20, now: date(2026, 8, 1), calendar: calendar), 1)
    }

    // MARK: - 显示文本

    func testWeekNumberDisplayClampsToOne() {
        XCTAssertEqual(WeekLogic.weekNumberDisplay(7), "第7周")
        XCTAssertEqual(WeekLogic.weekNumberDisplay(0), "第1周")
        XCTAssertEqual(WeekLogic.weekNumberDisplay(-5), "第1周")
    }

    // MARK: - 一周日期

    func testWeekDatesMondayFirstWithoutWeekend() {
        let dates = WeekLogic.weekDates(
            weekOffset: 0,
            showSaturday: false,
            showSunday: false,
            now: date(2026, 10, 15),
            calendar: calendar
        )
        XCTAssertEqual(dates.count, 5)
        XCTAssertEqual(dates.map(\.label), ["一", "二", "三", "四", "五"])
        XCTAssertEqual(dates.map(\.date), ["10/12", "10/13", "10/14", "10/15", "10/16"])
    }

    func testWeekDatesWithWeekend() {
        let dates = WeekLogic.weekDates(
            weekOffset: 0,
            showSaturday: true,
            showSunday: true,
            now: date(2026, 10, 15),
            calendar: calendar
        )
        XCTAssertEqual(dates.count, 7)
        XCTAssertEqual(dates.map(\.label), ["一", "二", "三", "四", "五", "六", "日"])
        XCTAssertEqual(dates.last?.date, "10/18")
    }

    func testWeekDatesOffsetMovesOneWeekForward() {
        let dates = WeekLogic.weekDates(
            weekOffset: 1,
            showSaturday: false,
            showSunday: false,
            now: date(2026, 10, 15),
            calendar: calendar
        )
        XCTAssertEqual(dates.first?.date, "10/19")
    }

    func testWeekDatesOffsetMovesOneWeekBackward() {
        let dates = WeekLogic.weekDates(
            weekOffset: -1,
            showSaturday: false,
            showSunday: false,
            now: date(2026, 10, 15),
            calendar: calendar
        )
        XCTAssertEqual(dates.first?.date, "10/5")
    }

    func testWeekDatesOnSundayStillReportsTheWeekJustEnded() {
        // 固定「周一是本周第一天」，周日的「本周周一」应是 6 天前。
        // 这条断言钉住 `Calendar.app` 的 `firstWeekday = 2`，也是
        // `docs/recon/algorithms.md` 里标注的不确定项的守门测试。
        let dates = WeekLogic.weekDates(
            weekOffset: 0,
            showSaturday: true,
            showSunday: true,
            now: date(2026, 10, 18),
            calendar: calendar
        )
        XCTAssertEqual(dates.first?.date, "10/12")
        XCTAssertEqual(dates.last?.date, "10/18")
    }
}
