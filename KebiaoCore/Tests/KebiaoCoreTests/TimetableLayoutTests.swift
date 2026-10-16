import XCTest
@testable import KebiaoCore

/// 课表网格几何与文本算法测试。
///
/// 期望值来源：`apk_work/kb/src2/TimetableGridV2.kt`
/// - `:80-103` 常量、`:111-112` 左侧列宽、`:726-731` 字号
/// - `:733-741` 楼名/教室、`:743-752` 星期、`:754-763` 日期文本
/// - `:774-793` 相邻课程合并、`:796-805` 时间区间
/// - `:550-566` 卡片纵向几何、`:191-207` 展开目标矩形
final class TimetableLayoutTests: XCTestCase {

    private func course(
        id: Int = 0,
        name: String = "高等数学",
        teacher: String = "张老师",
        location: String = "教学楼A 101",
        dayOfWeek: Int = 1,
        startPeriod: Int = 1,
        endPeriod: Int = 2
    ) -> Course {
        Course(
            id: id,
            name: name,
            teacher: teacher,
            location: location,
            dayOfWeek: dayOfWeek,
            startPeriod: startPeriod,
            endPeriod: endPeriod,
            color: 0,
            weekRange: ""
        )
    }

    // MARK: - 常量

    func testLayoutConstantsMatchComposeSource() {
        XCTAssertEqual(TimetableLayout.leftColumnWide, 50)
        XCTAssertEqual(TimetableLayout.leftColumnNarrow, 42)
        XCTAssertEqual(TimetableLayout.headerHeight, 46)
        XCTAssertEqual(TimetableLayout.blockGap, 10)
        XCTAssertEqual(TimetableLayout.cardGap, 5)
        XCTAssertEqual(TimetableLayout.minCardHeight, 12)
        XCTAssertEqual(TimetableLayout.panelRadius, 16)
        XCTAssertEqual(TimetableLayout.panelPadding, 4)
        XCTAssertEqual(TimetableLayout.expandMargin, 14)
        XCTAssertEqual(TimetableLayout.expandMinWidth, 190)
        XCTAssertEqual(TimetableLayout.expandMinHeight, 196)
        XCTAssertEqual(TimetableLayout.expandWidthFactor, 1.8, accuracy: 1e-9)
        XCTAssertEqual(TimetableLayout.expandHeightFactor, 1.85, accuracy: 1e-9)
    }

    func testLeftColumnNarrowsOnlyWithSevenColumns() {
        XCTAssertEqual(TimetableLayout.leftColumnWidth(dayCount: 5), 50)
        XCTAssertEqual(TimetableLayout.leftColumnWidth(dayCount: 6), 50)
        XCTAssertEqual(TimetableLayout.leftColumnWidth(dayCount: 7), 42)
    }

    // MARK: - 星期映射

    func testDayIndexOfMapsSingleCharacterLabels() {
        for (index, label) in ["一", "二", "三", "四", "五", "六", "日"].enumerated() {
            XCTAssertEqual(TimetableLayout.dayIndexOf(label), index + 1, "标签 \(label)")
        }
    }

    func testDayIndexOfRejectsAnythingElse() {
        // 原版是对整个字符串精确匹配，所以 "周一" 也返回 0。
        XCTAssertEqual(TimetableLayout.dayIndexOf("周一"), 0)
        XCTAssertEqual(TimetableLayout.dayIndexOf(""), 0)
        XCTAssertEqual(TimetableLayout.dayIndexOf("8"), 0)
    }

    // MARK: - 楼名 / 教室

    func testBuildingAndRoomSplitOnFirstSpace() {
        let sut = course(location: "教学楼A 101")
        XCTAssertEqual(sut.building, "教学楼A")
        XCTAssertEqual(sut.room, "101")
    }

    func testBuildingWithoutSpaceIsWholeStringAndRoomIsEmpty() {
        let sut = course(location: "操场")
        XCTAssertEqual(sut.building, "操场")
        XCTAssertEqual(sut.room, "")
    }

    func testRoomTrimsTrailingSpaces() {
        let sut = course(location: "实验楼B  305  ")
        XCTAssertEqual(sut.building, "实验楼B")
        XCTAssertEqual(sut.room, "305")
    }

    // MARK: - 字号

    func testFitTextSizeKeepsConfiguredSizeWhenCardIsTallEnough() {
        // 69dp 高的格子：(69-8)/5 = 12.2 → 12，cap = 10 → 12 >= 10 → 用配置值 10。
        XCTAssertEqual(TimetableLayout.fitTextSize(configured: 10, heightDp: 69), 10)
    }

    func testFitTextSizeFallsBackOnVeryShortCards() {
        // (20-8)/5 = 2.4 → 2，cap = 10 → 2 < 10 → max(2, 7) = 7。
        XCTAssertEqual(TimetableLayout.fitTextSize(configured: 10, heightDp: 20), 7)
    }

    func testFitTextSizeNeverGoesBelowSeven() {
        XCTAssertEqual(TimetableLayout.fitTextSize(configured: 7, heightDp: 0), 7)
        XCTAssertEqual(TimetableLayout.fitTextSize(configured: 3, heightDp: 40), 7)
    }

    func testFitTextSizeRaisesConfiguredBelowSevenToSeven() {
        // cap = configured.coerceAtLeast(7)，且 configured 小于 7 时 fit 会 >= cap。
        XCTAssertEqual(TimetableLayout.fitTextSize(configured: 4, heightDp: 100), 7)
    }

    // MARK: - 相邻课程合并

    func testMergeAdjacentJoinsContiguousSameCourse() {
        let merged = TimetableLayout.mergeAdjacent([
            course(id: 1, startPeriod: 1, endPeriod: 2),
            course(id: 2, startPeriod: 3, endPeriod: 4)
        ])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].startPeriod, 1)
        XCTAssertEqual(merged[0].endPeriod, 4)
        // 合并链上第一张卡片的 id 被保留。
        XCTAssertEqual(merged[0].id, 1)
    }

    func testMergeAdjacentDoesNotJoinGap() {
        let merged = TimetableLayout.mergeAdjacent([
            course(id: 1, startPeriod: 1, endPeriod: 2),
            course(id: 2, startPeriod: 4, endPeriod: 5)
        ])
        XCTAssertEqual(merged.count, 2)
    }

    func testMergeAdjacentDoesNotJoinDifferentName() {
        let merged = TimetableLayout.mergeAdjacent([
            course(id: 1, name: "高等数学", startPeriod: 1, endPeriod: 2),
            course(id: 2, name: "大学英语", startPeriod: 3, endPeriod: 4)
        ])
        XCTAssertEqual(merged.count, 2)
    }

    func testMergeAdjacentDoesNotJoinDifferentLocationOrTeacher() {
        let byLocation = TimetableLayout.mergeAdjacent([
            course(id: 1, location: "教学楼A 101", startPeriod: 1, endPeriod: 2),
            course(id: 2, location: "教学楼B 202", startPeriod: 3, endPeriod: 4)
        ])
        XCTAssertEqual(byLocation.count, 2)

        let byTeacher = TimetableLayout.mergeAdjacent([
            course(id: 1, teacher: "张老师", startPeriod: 1, endPeriod: 2),
            course(id: 2, teacher: "李老师", startPeriod: 3, endPeriod: 4)
        ])
        XCTAssertEqual(byTeacher.count, 2)
    }

    func testMergeAdjacentSortsByStartPeriodAndKeepsStableOrder() {
        // 输入乱序；同一 name/location/teacher 的三段 3-4、1-2、5-6 应合成 1-6。
        let merged = TimetableLayout.mergeAdjacent([
            course(id: 30, startPeriod: 5, endPeriod: 6),
            course(id: 10, startPeriod: 1, endPeriod: 2),
            course(id: 20, startPeriod: 3, endPeriod: 4)
        ])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].id, 10)
        XCTAssertEqual(merged[0].endPeriod, 6)
    }

    func testMergeAdjacentEmptyAndSingle() {
        XCTAssertTrue(TimetableLayout.mergeAdjacent([]).isEmpty)
        XCTAssertEqual(TimetableLayout.mergeAdjacent([course(id: 9)]).count, 1)
    }

    // MARK: - 时间区间

    func testBuildTimeRangeUsesFirstAndLastSlot() {
        let slots = ["08:00-08:45", "08:55-09:40", "10:00-10:45", "10:55-11:40"]
        let sut = course(startPeriod: 1, endPeriod: 4)
        XCTAssertEqual(TimetableLayout.buildTimeRange(sut, timeSlots: slots), "08:00-11:40")
    }

    func testBuildTimeRangeTrimsAroundDelimiter() {
        let slots = [" 08:00 - 08:45 ", "08:55-09:40"]
        let sut = course(startPeriod: 1, endPeriod: 2)
        XCTAssertEqual(TimetableLayout.buildTimeRange(sut, timeSlots: slots), "08:00-09:40")
    }

    func testBuildTimeRangeFallsBackToTheOtherEndWhenOneIsMissing() {
        // endPeriod 越界 → last 为空 → 返回 first。
        let slots = ["08:00-08:45"]
        let sut = course(startPeriod: 1, endPeriod: 5)
        XCTAssertEqual(TimetableLayout.buildTimeRange(sut, timeSlots: slots), "08:00")
    }

    func testBuildTimeRangeReturnsEmptyWhenNoSlotMatches() {
        // startPeriod = 0 → 下标 -1 越界；endPeriod 也越界 → 两边都空。
        let sut = course(startPeriod: 0, endPeriod: 0)
        XCTAssertEqual(TimetableLayout.buildTimeRange(sut, timeSlots: ["08:00-08:45"]), "")
    }

    func testBuildTimeRangeKeepsWholeSlotWhenDelimiterIsAbsent() {
        // Kotlin 的 substringBefore/After 在找不到分隔符时返回**原串**，
        // 所以 "08:00" 这种没有 "-" 的槽位会两边都取到 "08:00"。
        let sut = course(startPeriod: 1, endPeriod: 1)
        XCTAssertEqual(TimetableLayout.buildTimeRange(sut, timeSlots: ["08:00"]), "08:00-08:00")
    }

    // MARK: - 日期文本

    func testPrettyDatePadsMonthAndDay() {
        XCTAssertEqual(TimetableLayout.prettyDate("5/2"), "05-02")
        XCTAssertEqual(TimetableLayout.prettyDate("12/31"), "12-31")
        XCTAssertEqual(TimetableLayout.prettyDate(" 7 / 4 "), "07-04")
    }

    func testPrettyDatePassesThroughUnexpectedInput() {
        XCTAssertEqual(TimetableLayout.prettyDate("2026-10-15"), "2026-10-15")
        XCTAssertEqual(TimetableLayout.prettyDate("5/2/3"), "5/2/3")
        XCTAssertEqual(TimetableLayout.prettyDate("五/二"), "五/二")
    }

    // MARK: - 时间段面板与卡片纵向几何

    func testCardGeometryFirstCardInBlockStartsAtZero() {
        let sut = course(startPeriod: 1, endPeriod: 2)
        let geometry = TimetableLayout.cardVerticalGeometry(
            card: sut,
            blockStartPeriod: 1,
            blockEndPeriod: 4,
            cellHeight: 69,
            previousBottom: 0
        )
        XCTAssertEqual(geometry.top, 0, accuracy: 1e-9)
        // 2 节 * 69 - CardGap(5) = 133
        XCTAssertEqual(geometry.height, 133, accuracy: 1e-9)
    }

    func testCardGeometrySecondCardIsPushedBelowTheFirst() {
        // 同一格两门课：第二张的自然位置与第一张重叠，应被推到 prevBottom + CardGap。
        let first = course(startPeriod: 1, endPeriod: 2)
        let second = course(id: 1, name: "大学英语", startPeriod: 2, endPeriod: 3)

        let firstGeometry = TimetableLayout.cardVerticalGeometry(
            card: first, blockStartPeriod: 1, blockEndPeriod: 4,
            cellHeight: 69, previousBottom: 0
        )
        let previousBottom = firstGeometry.top + firstGeometry.height
        XCTAssertEqual(previousBottom, 133, accuracy: 1e-9)

        let secondGeometry = TimetableLayout.cardVerticalGeometry(
            card: second, blockStartPeriod: 1, blockEndPeriod: 4,
            cellHeight: 69, previousBottom: previousBottom
        )
        // naturalTop = 69 * (2-1) = 69 < 133 → top = 133 + 5 = 138
        XCTAssertEqual(secondGeometry.top, 138, accuracy: 1e-9)
        // naturalBottom = 69 * (3-1+1) - 5 = 202；h = 202 - 138 = 64
        XCTAssertEqual(secondGeometry.height, 64, accuracy: 1e-9)
    }

    func testCardGeometryRespectsMinCardHeight() {
        // 极矮的格子：h 会被撑到 MinCardHeight。
        let sut = course(startPeriod: 1, endPeriod: 1)
        let geometry = TimetableLayout.cardVerticalGeometry(
            card: sut, blockStartPeriod: 1, blockEndPeriod: 4,
            cellHeight: 6, previousBottom: 0
        )
        // naturalBottom = 6 - 5 = 1；top = 0；h = 1 → 被撑到 12
        XCTAssertEqual(geometry.height, 12, accuracy: 1e-9)
    }

    func testCardGeometryHonoursBlockStartPeriod() {
        // 第二个面板从第 5 节开始：第 5 节在该面板内是第 0 行。
        let sut = course(startPeriod: 5, endPeriod: 6)
        let geometry = TimetableLayout.cardVerticalGeometry(
            card: sut, blockStartPeriod: 5, blockEndPeriod: 8,
            cellHeight: 69, previousBottom: 0
        )
        XCTAssertEqual(geometry.top, 0, accuracy: 1e-9)
        XCTAssertEqual(geometry.height, 133, accuracy: 1e-9)
    }

    func testCardGeometryClampsCrossPanelCourseIntoEachPanel() {
        // 原版 `:557-558` 的两个 coerceIn：跨面板的课程（4-5 节）在两个面板里都被画，
        // 但各自被裁到本面板范围内。
        let sut = course(startPeriod: 4, endPeriod: 5)

        // 上午面板 1..4：start = 4，end = 5 → 4，所以是面板内最后一行、单行高。
        let morning = TimetableLayout.cardVerticalGeometry(
            card: sut, blockStartPeriod: 1, blockEndPeriod: 4,
            cellHeight: 69, previousBottom: 0
        )
        XCTAssertEqual(morning.top, 69 * 3, accuracy: 1e-9)
        XCTAssertEqual(morning.height, 69 - 5, accuracy: 1e-9)

        // 下午面板 5..8：start = 4 → 5，end = 5，所以是面板内第 0 行、单行高。
        let afternoon = TimetableLayout.cardVerticalGeometry(
            card: sut, blockStartPeriod: 5, blockEndPeriod: 8,
            cellHeight: 69, previousBottom: 0
        )
        XCTAssertEqual(afternoon.top, 0, accuracy: 1e-9)
        XCTAssertEqual(afternoon.height, 69 - 5, accuracy: 1e-9)
    }

    func testCardGeometryClampsEndNotBeforeStart() {
        // `end` 的下界是已经 clamp 过的 `start`（不是 blockStartPeriod）：
        // 卡片 6-7 落进上午面板 1..4 时 start = end = 4，高度不得为负。
        let sut = course(startPeriod: 6, endPeriod: 7)
        let geometry = TimetableLayout.cardVerticalGeometry(
            card: sut, blockStartPeriod: 1, blockEndPeriod: 4,
            cellHeight: 69, previousBottom: 0
        )
        XCTAssertEqual(geometry.top, 69 * 3, accuracy: 1e-9)
        XCTAssertEqual(geometry.height, 69 - 5, accuracy: 1e-9)
        XCTAssertGreaterThan(geometry.height, 0)
    }

    func testCoursesInBlockFiltersDayAndPanelThenMerges() {
        let courses = [
            course(id: 1, dayOfWeek: 1, startPeriod: 1, endPeriod: 2),
            course(id: 2, dayOfWeek: 1, startPeriod: 3, endPeriod: 4),
            course(id: 3, dayOfWeek: 2, startPeriod: 1, endPeriod: 2),   // 别的天
            course(id: 4, dayOfWeek: 1, startPeriod: 5, endPeriod: 6)    // 别的面板
        ]

        let morningMonday = TimetableLayout.coursesInBlock(
            courses, dayOfWeek: 1, blockStartPeriod: 1, blockEndPeriod: 4
        )
        // 1-2 与 3-4 同课且连续 → 合并成一张 1-4。
        XCTAssertEqual(morningMonday.count, 1)
        XCTAssertEqual(morningMonday[0].id, 1)
        XCTAssertEqual(morningMonday[0].endPeriod, 4)

        let afternoonMonday = TimetableLayout.coursesInBlock(
            courses, dayOfWeek: 1, blockStartPeriod: 5, blockEndPeriod: 8
        )
        XCTAssertEqual(afternoonMonday.count, 1)
        XCTAssertEqual(afternoonMonday[0].id, 4)

        // 面板里没有任何课时返回空数组（而不是崩溃）。
        XCTAssertTrue(
            TimetableLayout.coursesInBlock(
                courses, dayOfWeek: 5, blockStartPeriod: 9, blockEndPeriod: 12
            ).isEmpty
        )
    }

    func testCoursesInBlockIncludesCourseStraddlingThePanelBoundary() {
        // 过滤条件是 `endPeriod >= blockStart && startPeriod <= blockEnd`，
        // 所以 4-5 节这种横跨边界的课在两个面板里都会出现。
        let courses = [course(id: 7, dayOfWeek: 3, startPeriod: 4, endPeriod: 5)]
        XCTAssertEqual(
            TimetableLayout.coursesInBlock(courses, dayOfWeek: 3, blockStartPeriod: 1, blockEndPeriod: 4).count,
            1
        )
        XCTAssertEqual(
            TimetableLayout.coursesInBlock(courses, dayOfWeek: 3, blockStartPeriod: 5, blockEndPeriod: 8).count,
            1
        )
    }

    // MARK: - 展开目标矩形

    func testExpandTargetGrowsAroundCentre() {
        let origin = LayoutRect(left: 100, top: 200, width: 100, height: 100)
        let target = TimetableLayout.expandTarget(origin: origin, boxWidth: 400, boxHeight: 800)
        // 宽 = 100 * 1.8 = 180，但最小宽度 190 → 190
        XCTAssertEqual(target.width, 190, accuracy: 1e-9)
        // 高 = 100 * 1.85 = 185，但最小高度 196 → 196
        XCTAssertEqual(target.height, 196, accuracy: 1e-9)
        // 绕原点中心 (150, 250) 展开
        XCTAssertEqual(target.centerX, origin.centerX, accuracy: 1e-9)
        XCTAssertEqual(target.centerY, origin.centerY, accuracy: 1e-9)
    }

    func testExpandTargetIsClampedInsideTheBox() {
        // 贴着左上角的卡片：绕中心展开后会越界，应被夹回 margin 处。
        let origin = LayoutRect(left: 0, top: 0, width: 80, height: 80)
        let target = TimetableLayout.expandTarget(origin: origin, boxWidth: 300, boxHeight: 600)
        XCTAssertGreaterThanOrEqual(target.left, TimetableLayout.expandMargin - 1e-9)
        XCTAssertGreaterThanOrEqual(target.top, TimetableLayout.expandMargin - 1e-9)
        XCTAssertLessThanOrEqual(target.right, 300 - TimetableLayout.expandMargin + 1e-9)
        XCTAssertLessThanOrEqual(target.bottom, 600 - TimetableLayout.expandMargin + 1e-9)
    }

    func testExpandTargetNeverExceedsAvailableSpace() {
        // 很小的网格：最小宽高本身超过可用空间时，应退化为可用空间。
        let origin = LayoutRect(left: 10, top: 10, width: 60, height: 60)
        let target = TimetableLayout.expandTarget(origin: origin, boxWidth: 100, boxHeight: 100)
        XCTAssertLessThanOrEqual(target.width, 100 - TimetableLayout.expandMargin * 2 + 1e-9)
        XCTAssertLessThanOrEqual(target.height, 100 - TimetableLayout.expandMargin * 2 + 1e-9)
    }

    func testExpandTargetOfBottomRightCardIsNudgedInward() {
        let origin = LayoutRect(left: 700, top: 1500, width: 100, height: 100)
        let target = TimetableLayout.expandTarget(origin: origin, boxWidth: 800, boxHeight: 1600)
        XCTAssertLessThanOrEqual(target.right, 800 - TimetableLayout.expandMargin + 1e-9)
        XCTAssertLessThanOrEqual(target.bottom, 1600 - TimetableLayout.expandMargin + 1e-9)
    }
}
