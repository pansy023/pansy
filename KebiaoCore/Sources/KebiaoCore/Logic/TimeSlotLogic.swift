import Foundation

/// 作息时间槽（形如 `"08:10-08:55"`）的生成与挑选。
///
/// 这是 `TimetableWeekGrid` 的第一入参来源：网格左侧的「节次 + 起止时间」、
/// 卡片上的时间文本、提醒调度器算上课时刻，全都读同一份时间槽。
///
/// 证据（原版把同一段逻辑抄了三份，三份行为一致）：
/// - `上课早枝道-源码-1.11.5/app/src/main/java/kebiaocom/example/ui/TimetableScreenKt.java:198-256`
///   （`generateTimeSlots` + `getEffectiveTimeSlots`）——**本文件按这一份实现**
/// - `.../reminder/CourseReminderScheduler.java:260-284`
/// - `.../widget/WidgetTimetableHelperKt.java:211-240`
///
/// 卡片上的时间文本用 `TimetableLayout.buildTimeRange(_:timeSlots:)`，不在这里重复实现。
public enum TimeSlotLogic {

    /// 时间槽的分隔符。原版是字符串拼接 `start + "-" + end`
    /// （`TimetableScreenKt.java:253`），读取端用 `substringBefore/After("-")`
    /// （`TimetableGridV2.kt:525,528`）。
    public static let separator = "-"

    /// 按「第一节开始时间 + 每节时长 + 课间休息」推算 `periodsPerDay` 个时间槽。
    ///
    /// 逐行对应 `TimetableScreenKt.java:198-225`：
    /// ```
    /// split(":") → hour（解析失败取 8）、minute（解析失败取 0）
    /// for i in 0..<periodsPerDay:
    ///     start = "%02d:%02d".format(hour, minute)
    ///     minute += periodDurationMinutes
    ///     if minute >= 60 { hour += minute / 60; minute %= 60 }
    ///     end = "%02d:%02d".format(hour, minute)
    ///     slots.add(start + "-" + end)
    ///     if i < periodsPerDay - 1 {
    ///         minute += breakDurationMinutes
    ///         if minute >= 60 { hour += minute / 60; minute %= 60 }
    ///     }
    /// ```
    ///
    /// ⚠️ 原版这里**不**对 `hour` 取模 24：节次足够多时会生成 `"25:30-26:15"` 这种串。
    /// 为了与原版逐字一致，这里同样不取模。
    ///
    /// - Parameters:
    ///   - firstPeriodStartTime: 形如 `"08:00"`；解析不出「时」时取默认 8。
    ///   - periodDurationMinutes: 每节时长（默认 45）。
    ///   - breakDurationMinutes: 课间（默认 10）。
    ///   - periodsPerDay: 生成几节。
    public static func generateTimeSlots(
        firstPeriodStartTime: String,
        periodDurationMinutes: Int,
        breakDurationMinutes: Int,
        periodsPerDay: Int
    ) -> [String] {
        let parts = firstPeriodStartTime.components(separatedBy: ":")
        var hour = Int(parts.first ?? "") ?? 8
        var minute = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0

        let count = max(periodsPerDay, 0)
        guard count > 0 else { return [] }

        var slots: [String] = []
        slots.reserveCapacity(count)

        for index in 0..<count {
            let start = String(format: "%02d:%02d", hour, minute)

            minute += periodDurationMinutes
            if minute >= 60 {
                hour += minute / 60
                minute %= 60
            }
            let end = String(format: "%02d:%02d", hour, minute)
            slots.append(start + separator + end)

            if index < count - 1 {
                minute += breakDurationMinutes
                if minute >= 60 {
                    hour += minute / 60
                    minute %= 60
                }
            }
        }
        return slots
    }

    /// 挑出生效的时间槽。
    ///
    /// 逐行对应 `TimetableScreenKt.java:227-256`：
    /// 1. 在 `profiles` 里找 `id == settings.selectedTimetableProfileId` 的那一套；
    /// 2. 找不到、或该方案的 `periodTimes` 为空 → 用 `settings` 里的
    ///    「第一节时间 / 每节时长 / 课间 / 每天节数」现算（`generateTimeSlots`）；
    /// 3. 否则把 `periodTimes` **按 `index` 升序**排序后拼成 `"start-end"`。
    ///
    /// ⚠️ 第 3 步只排序，**不**补齐也**不**截断到 `periodsPerDay`：方案里有几节就是几节。
    public static func effectiveTimeSlots(
        settings: AppSettings,
        profiles: [TimetableProfile]
    ) -> [String] {
        let profile = profiles.first { $0.id == settings.selectedTimetableProfileId }

        guard let profile, !profile.periodTimes.isEmpty else {
            return generateTimeSlots(
                firstPeriodStartTime: settings.firstPeriodStartTime,
                periodDurationMinutes: settings.periodDurationMinutes,
                breakDurationMinutes: settings.breakDurationMinutes,
                periodsPerDay: settings.periodsPerDay
            )
        }

        return profile.periodTimes
            .sorted { $0.index < $1.index }
            .map { $0.start + separator + $0.end }
    }
}
