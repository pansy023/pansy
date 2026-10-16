import XCTest
@testable import KebiaoCore

/// 作息时间槽测试。
///
/// 期望值来源：
/// - `上课早枝道-源码-1.11.5/app/src/main/java/kebiaocom/example/ui/TimetableScreenKt.java:198-225`
///   （`generateTimeSlots`）
/// - 同文件 `:227-256`（`getEffectiveTimeSlots`）
/// - `.../data/LocalStorage.java:263-278`（出厂内置的 10 节时间）
final class TimeSlotLogicTests: XCTestCase {

    // MARK: - generateTimeSlots

    func testGenerateTimeSlotsUsesDurationAndBreak() {
        let slots = TimeSlotLogic.generateTimeSlots(
            firstPeriodStartTime: "08:00",
            periodDurationMinutes: 45,
            breakDurationMinutes: 10,
            periodsPerDay: 3
        )
        XCTAssertEqual(slots, ["08:00-08:45", "08:55-09:40", "09:50-10:35"])
    }

    func testGenerateTimeSlotsCarriesHourAcrossPeriods() {
        let slots = TimeSlotLogic.generateTimeSlots(
            firstPeriodStartTime: "08:00",
            periodDurationMinutes: 45,
            breakDurationMinutes: 10,
            periodsPerDay: 12
        )
        XCTAssertEqual(slots.count, 12)
        XCTAssertEqual(slots.first, "08:00-08:45")
        XCTAssertEqual(slots.last, "18:05-18:50")
    }

    func testGenerateTimeSlotsHandlesMinuteRolloverAtExactlySixty() {
        // 08:50 + 10 分钟 = 09:00，进位后分钟必须归零（原版 `if (m >= 60)`）。
        let slots = TimeSlotLogic.generateTimeSlots(
            firstPeriodStartTime: "08:50",
            periodDurationMinutes: 10,
            breakDurationMinutes: 0,
            periodsPerDay: 2
        )
        XCTAssertEqual(slots, ["08:50-09:00", "09:00-09:10"])
    }

    func testGenerateTimeSlotsDoesNotWrapPastMidnight() {
        // 原版对 hour 不取模 24（`TimetableScreenKt.java:211-214`、`:219-222`），
        // 这里逐字保留，避免「修好」之后与原版行为不一致。
        //
        // 逐行推演（`:206-223`）：
        //   i=0  起 23:50 → 50+45=95 ≥60 → hour=24, minute=35 → 存 "23:50-24:35"
        //        课间：35+10=45，不触发进位
        //   i=1  起 24:45 → 45+45=90 ≥60 → hour=25, minute=30 → 存 "24:45-25:30"
        // 所以第二段的起点是「上一段结束后再加 10 分钟课间」，不是上一段的终点。
        let slots = TimeSlotLogic.generateTimeSlots(
            firstPeriodStartTime: "23:50",
            periodDurationMinutes: 45,
            breakDurationMinutes: 10,
            periodsPerDay: 2
        )
        XCTAssertEqual(slots, ["23:50-24:35", "24:45-25:30"])
    }

    func testGenerateTimeSlotsFallsBackToEightOClockWhenStartTimeIsUnparseable() {
        for raw in ["", "abc", "8"] {
            XCTAssertEqual(
                TimeSlotLogic.generateTimeSlots(
                    firstPeriodStartTime: raw,
                    periodDurationMinutes: 45,
                    breakDurationMinutes: 10,
                    periodsPerDay: 1
                ),
                ["08:00-08:45"],
                "起始时间「\(raw)」应回落到 08:00"
            )
        }
    }

    func testGenerateTimeSlotsReturnsEmptyForNonPositivePeriodCount() {
        for count in [0, -3] {
            XCTAssertEqual(
                TimeSlotLogic.generateTimeSlots(
                    firstPeriodStartTime: "08:00",
                    periodDurationMinutes: 45,
                    breakDurationMinutes: 10,
                    periodsPerDay: count
                ),
                [],
                "每天 \(count) 节时不应生成任何时间槽"
            )
        }
    }

    // MARK: - effectiveTimeSlots

    func testEffectiveTimeSlotsUsesSelectedProfileSortedByIndex() {
        let profile = TimetableProfile(
            id: "summer",
            name: "夏令",
            periodsPerDay: 3,
            periodTimes: [
                PeriodTime(index: 3, start: "14:00", end: "14:45"),
                PeriodTime(index: 1, start: "08:00", end: "08:45"),
                PeriodTime(index: 2, start: "09:00", end: "09:45")
            ]
        )
        var settings = AppSettings.default
        settings.selectedTimetableProfileId = "summer"

        XCTAssertEqual(
            TimeSlotLogic.effectiveTimeSlots(settings: settings, profiles: [.defaultProfile, profile]),
            ["08:00-08:45", "09:00-09:45", "14:00-14:45"]
        )
    }

    func testEffectiveTimeSlotsFallsBackWhenProfileIsMissing() {
        var settings = AppSettings.default
        settings.selectedTimetableProfileId = "nope"
        settings.firstPeriodStartTime = "09:00"
        settings.periodDurationMinutes = 40
        settings.breakDurationMinutes = 5
        settings.periodsPerDay = 2

        XCTAssertEqual(
            TimeSlotLogic.effectiveTimeSlots(settings: settings, profiles: [.defaultProfile]),
            ["09:00-09:40", "09:45-10:25"]
        )
    }

    func testEffectiveTimeSlotsFallsBackWhenProfileHasNoPeriodTimes() {
        let empty = TimetableProfile(id: "empty", name: "空", periodsPerDay: 2, periodTimes: [])
        var settings = AppSettings.default
        settings.selectedTimetableProfileId = "empty"
        settings.firstPeriodStartTime = "09:00"
        settings.periodDurationMinutes = 40
        settings.breakDurationMinutes = 5
        settings.periodsPerDay = 2

        XCTAssertEqual(
            TimeSlotLogic.effectiveTimeSlots(settings: settings, profiles: [empty]),
            ["09:00-09:40", "09:45-10:25"]
        )
    }

    func testEffectiveTimeSlotsDoesNotTruncateToPeriodsPerDay() {
        // 方案里有几节就是几节：不补齐、也不截断到 `settings.periodsPerDay`。
        let profile = TimetableProfile(
            id: "long",
            name: "长",
            periodsPerDay: 2,
            periodTimes: [
                PeriodTime(index: 1, start: "08:00", end: "08:45"),
                PeriodTime(index: 2, start: "09:00", end: "09:45"),
                PeriodTime(index: 3, start: "10:00", end: "10:45")
            ]
        )
        var settings = AppSettings.default
        settings.selectedTimetableProfileId = "long"
        settings.periodsPerDay = 2

        XCTAssertEqual(
            TimeSlotLogic.effectiveTimeSlots(settings: settings, profiles: [profile]).count,
            3
        )
    }

    // MARK: - 与出厂内置方案的整合

    func testDefaultSettingsAndDefaultProfileYieldTenSlots() {
        let slots = TimeSlotLogic.effectiveTimeSlots(settings: .default, profiles: [.defaultProfile])

        XCTAssertEqual(
            slots,
            [
                "08:10-08:55", "09:05-09:50", "10:20-11:05", "11:15-12:00", "14:10-14:55",
                "15:05-15:50", "16:20-17:05", "17:15-18:00", "19:30-20:15", "20:25-21:10"
            ]
        )
        XCTAssertEqual(slots.first, "08:10-08:55")
        XCTAssertEqual(slots.last, "20:25-21:10")
    }

    func testDefaultProfileIsNotUniformlyGenerated() {
        // 出厂内置的 10 节（`LocalStorage.java:265`）里有两处**等长推算算不出来**的间隔：
        // - 第 2 节后有 30 分钟大课间（09:50 → 10:20），比 settings 里的课间 10 分钟多 20；
        // - 第 4 节后是午休（12:00 → 14:10）。
        // 所以只有前 2 节能和「等长节次」对上，从第 3 节起必分叉。
        // 这条测试把该事实钉死：生效时间必须读方案本身，不能只按 settings 推算。
        let generated = TimeSlotLogic.generateTimeSlots(
            firstPeriodStartTime: "08:10",
            periodDurationMinutes: 45,
            breakDurationMinutes: 10,
            periodsPerDay: 10
        )
        let profileSlots = TimeSlotLogic.effectiveTimeSlots(settings: .default, profiles: [.defaultProfile])

        XCTAssertEqual(Array(generated.prefix(2)), Array(profileSlots.prefix(2)))
        XCTAssertEqual(profileSlots[2], "10:20-11:05")
        XCTAssertNotEqual(generated[2], profileSlots[2])
        XCTAssertEqual(profileSlots[4], "14:10-14:55")
        XCTAssertNotEqual(generated[4], profileSlots[4])
    }
}
