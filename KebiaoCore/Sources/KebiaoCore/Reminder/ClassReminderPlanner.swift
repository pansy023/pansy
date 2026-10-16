import Foundation

/// 课前提醒的**纯计算**部分：把「课程 + 作息时间 + 设置」算成一份待发通知计划。
///
/// 本文件不碰 `UserNotifications`、不碰 `Date()`、不碰系统时区，
/// 所有对外部世界的依赖（现在时刻、日历）都由参数注入，因此可以完全确定性地单测。
///
/// ## 逐字移植的算法与出处
/// 顺序严格照抄 `上课早枝道-源码-1.11.5/app/src/main/java/kebiaocom/example/reminder/CourseReminderScheduler.java`：
/// 1. 15 天循环（`:58-69`）→ 星期映射（`:184-202`）→ 教学周（`:204-242`）
///    → 课程筛选（`:71-76`）→ 时刻推导（`:80-89`）→ 过去时间过滤（`:89`）；
/// 2. 「已排过的 alarm id 列表 + 全量取消重建」策略（`:41-52`）；
/// 3. 提前量下限 `coerceAtLeast(classReminderMinutes, 1)`（`:88`）。
public enum ClassReminderPlanner {

    // MARK: - 提前量

    /// 提前量的**下限**：1 分钟。
    ///
    /// 证据：`CourseReminderScheduler.java:88`
    /// `calendar3.add(Calendar.MINUTE, -RangesKt.coerceAtLeast(settings.getClassReminderMinutes(), 1))`。
    ///
    /// ⚠️ 注意是 `coerceAtLeast`——用户把提醒分钟数设成 0 或负数时，
    /// 原版按 **1 分钟**处理，而不是「提前 0 分钟（准点）」或「往后推」。
    /// 这个钳制只发生在算触发时刻处，不改设置本身的值，所以设置页仍显示用户输入。
    public static let minimumLeadMinutes = 1

    /// 生效的提前分钟数。
    public static func effectiveLeadMinutes(_ configured: Int) -> Int {
        max(configured, minimumLeadMinutes)
    }

    // MARK: - 单课触发时刻

    /// 把 `"HH:mm"` 解析成「当日零点起的分钟数」。
    ///
    /// 逐行对应 `CourseReminderScheduler.java:171-182` 的 `parseMinute`：
    /// ```
    /// split = trim(hhmm).split(":")
    /// 若 split.size != 2 → null
    /// hour = split[0].toIntOrNull() ?: return null
    /// minute = split[1].toIntOrNull() ?: return null
    /// return hour * 60 + minute
    /// ```
    /// Kotlin 的 `toIntOrNull` **不接受**空白与正负号以外的杂质，
    /// 也不接受 `"+8"`/`" 8"`；Swift 的 `Int(_:)` 同样只接受可选的 `+`/`-` 加十进制数字。
    ///
    /// 注意 `trim` 只作用在整串上（`:173` 的 `StringsKt.trim(hhmm)`），
    /// 分开的两段**没有**各自 trim。
    public static func parseMinuteOfDay(_ hhmm: String) -> Int? {
        let parts = hhmm.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: ":")
        guard parts.count == 2 else { return nil }
        guard let hour = Int(parts[0]) else { return nil }
        guard let minute = Int(parts[1]) else { return nil }
        return hour * 60 + minute
    }

    /// 计算某一天某节课的提醒触发时刻。
    ///
    /// 逐行对应 `CourseReminderScheduler.java:80-89`：
    /// ```
    /// slot = effectiveTimeSlots[course.startPeriod - 1]        // 越界 → null，跳过
    /// minutes = parseMinute(slot.substringBefore("-"))          // 失败 → null，跳过
    /// trigger = dayAtMidnight
    /// trigger.set(HOUR_OF_DAY, minutes / 60)
    /// trigger.set(MINUTE, minutes % 60)
    /// trigger.add(MINUTE, -coerceAtLeast(classReminderMinutes, 1))
    /// ```
    ///
    /// - Parameters:
    ///   - dayAtMidnight: 目标日期的**零点**（与原版 `Calendar` 里 `sec`/`ms` 清零后的值对应）。
    ///   - startPeriodStartText: 该课起始节次对应时间槽的 `"HH:mm"` 部分。
    ///   - leadMinutes: `classReminderMinutes` 原值（内部会做 `max(_, 1)`）。
    ///   - calendar: 用于拆分/组装时分的日历（时区从此来）。
    /// - Returns: 触发时刻；`HH:mm` 解析失败时返回 `nil`（原版会跳过这门课）。
    public static func reminderDate(
        dayAtMidnight: Date,
        startPeriodStartText: String,
        leadMinutes: Int,
        calendar: Calendar
    ) -> Date? {
        guard let minutes = parseMinuteOfDay(startPeriodStartText) else { return nil }

        var components = calendar.dateComponents([.year, .month, .day], from: dayAtMidnight)
        components.hour = minutes / 60
        components.minute = minutes % 60
        components.second = 0
        components.nanosecond = 0
        guard let slotStart = calendar.date(from: components) else { return nil }

        return calendar.date(
            byAdding: .minute,
            value: -effectiveLeadMinutes(leadMinutes),
            to: slotStart
        )
    }

    // MARK: - 星期 / 教学周

    /// 把 `Calendar` 的 `weekday` 映射成「周一 = 1 … 周日 = 7」。
    ///
    /// 逐行对应 `CourseReminderScheduler.java:184-202` 的 `toMondayBasedDay`，
    /// 其输入是 Java 的 `Calendar.DAY_OF_WEEK`（`SUNDAY = 1 … SATURDAY = 7`）——
    /// 与 Foundation `Calendar.component(.weekday, ...)` 的取值域**完全一致**，
    /// 所以映射式可以直接用：
    /// `DAY_OF_WEEK 2(周一) → 1`、`3 → 2`、…、`7 → 6`、`1(周日) → 7`。
    ///
    /// 用 `(weekday + 5) % 7 + 1` 一次算完：
    /// `1 → 7`、`2 → 1`、`3 → 2`、`4 → 3`、`5 → 4`、`6 → 5`、`7 → 6`，与 switch 分支逐个吻合。
    public static func mondayBasedDay(weekday: Int) -> Int {
        ((weekday + 5) % 7) + 1
    }

    /// 课表自动刷新路径之外的「教学周」计算。
    ///
    /// ⚠️ **不要**用 `WeekLogic.teachingWeek` 替代本函数：两者对同一份数据的结论可能不同。
    /// - `WeekLogic.teachingWeek`（`TimetableScreenKt.java:301-317`）会把结果
    ///   `coerceIn(1, max(semesterWeeks, 1))`，即**有上界钳制**；
    /// - 本函数（`CourseReminderScheduler.java:204-242`）**没有上界钳制**，
    ///   且用 `"yyyy-M-d"` 三段整数解析（不是 `SimpleDateFormat("yyyy-MM-dd")`）。
    ///
    /// 逐行对应：
    /// ```
    /// 去空白后为空 → 1
    /// split("-") 段数 != 3 或任一段 toIntOrNull 失败 → 1
    /// start = 该年/月-1/日的零点
    /// days = (targetMillis - startMillis) / 86_400_000      // 向零截断
    /// days < 0 → 1
    /// return 1 + (days / 7)                                  // 向零截断
    /// ```
    /// - Parameters:
    ///   - firstWeekStartDate: `AppSettings.firstWeekStartDate`，形如 `"2025-9-1"`。
    ///   - target: 要判断的那一天（原版传入的是「当天 + i 天」的 `Calendar`）。
    ///   - calendar: 用于切分日期与取零点的日历。
    public static func teachingWeek(
        firstWeekStartDate: String?,
        target: Date,
        calendar: Calendar
    ) -> Int {
        let raw = (firstWeekStartDate ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return 1 }

        let parts = raw.components(separatedBy: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2])
        else { return 1 }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 0
        components.minute = 0
        components.second = 0
        guard let semesterStart = calendar.date(from: components) else { return 1 }

        // 原版用毫秒差再整除；Swift 用秒差再整除，两者等价（同一 86400 系数）。
        // Java 的 long 除法向零截断，Swift 的 Int(Double) 同样向零截断。
        let elapsedSeconds = target.timeIntervalSince(semesterStart)
        let days = Int(elapsedSeconds / 86_400)
        guard days >= 0 else { return 1 }
        return 1 + (days / 7)
    }

    /// 课程在第 `week` 周是否上课。
    ///
    /// 逐行对应 `CourseReminderScheduler.java:244-258` 的 `occursInWeek`：
    /// ```
    /// if (week > course.endWeek || course.startWeek > week) return false
    /// isOdd == 1 → week % 2 != 1 → false        // 单周
    /// isOdd == 2 && week % 2 != 0 → false       // 双周
    /// return true
    /// ```
    ///
    /// ⚠️ **与 `WeekLogic.courseOccursInWeek` 不是同一套规则**，不能互换：
    /// - 本函数（提醒调度器）**只看** `startWeek`/`endWeek`/`isOdd`，
    ///   **完全不解析** `course.weekRange` 字符串；
    /// - `WeekLogic.courseOccursInWeek`（课表网格）会解析 `weekRange`
    ///   （含 `"1-16(单)"` 之类的教务导入串）。
    ///
    /// 因此「界面显示这周有课、提醒却没响」（或反之）在原版里**是可能发生的**。
    /// 这是原版行为，这里逐字保留，并在
    /// `docs/recon/notes-reminder-implementation.md` 里记为「已确认的原版分歧」。
    public static func courseOccursInWeek(_ course: Course, week: Int) -> Bool {
        if week > course.endWeek || course.startWeek > week { return false }
        switch course.isOdd {
        case 1:
            if week % 2 != 1 { return false }
        case 2:
            if week % 2 != 0 { return false }
        default:
            break
        }
        return true
    }

    // MARK: - 滚动窗口筛选

    /// 某一日（零点）的候选提醒。
    ///
    /// 逐行对应 `CourseReminderScheduler.java:70-113` 的单日循环体：
    /// ```
    /// dayCourses = courses.filter { it.dayOfWeek == mondayBasedDay && occursInWeek(it, teachingWeek) }
    /// for course in dayCourses:
    ///     slot = effectiveTimeSlots.getOrNull(course.startPeriod - 1)   // 越界跳过
    ///     trigger = ...（见 reminderDate）
    ///     if trigger > now: 收集（id = "courseId_triggerMillis"）
    /// ```
    ///
    /// - Parameters:
    ///   - dayAtMidnight: 当日零点。
    ///   - now: 当前时刻；只有**严格晚于 now** 的触发时刻才会被排。
    ///     ⚠️ 原版比较的是 `calendar3.getTimeInMillis() > calendar.getTimeInMillis()`
    ///     （`:89`），是**严格大于**，正好等于 now 的不排。
    ///   - courses: 全部课程（未过滤）。
    ///   - effectiveTimeSlots: 形如 `["08:10-08:55", …]` 的时间槽；索引 = `startPeriod - 1`。
    public static func occurrences(
        onDay dayAtMidnight: Date,
        now: Date,
        courses: [Course],
        effectiveTimeSlots: [String],
        settings: ReminderSettings,
        firstWeekStartDate: String?,
        calendar: Calendar
    ) -> [ReminderPendingNotification] {
        guard settings.isEnabled else { return [] }
        guard !effectiveTimeSlots.isEmpty else { return [] }

        let weekday = calendar.component(.weekday, from: dayAtMidnight)
        let targetDay = mondayBasedDay(weekday: weekday)
        let week = teachingWeek(
            firstWeekStartDate: firstWeekStartDate,
            target: dayAtMidnight,
            calendar: calendar
        )

        var result: [ReminderPendingNotification] = []
        for course in courses {
            guard course.dayOfWeek == targetDay else { continue }
            guard courseOccursInWeek(course, week: week) else { continue }

            let index = course.startPeriod - 1
            guard index >= 0, index < effectiveTimeSlots.count else { continue }

            // 原版 `substringBefore("-")`：无 "-" 时返回整串。
            let slot = effectiveTimeSlots[index]
            let startText = slot.components(separatedBy: "-").first ?? slot

            guard let trigger = reminderDate(
                dayAtMidnight: dayAtMidnight,
                startPeriodStartText: startText,
                leadMinutes: settings.leadMinutes,
                calendar: calendar
            ) else { continue }

            guard trigger > now else { continue }

            let content = ReminderContentBuilder.content(
                mode: settings.mode,
                courseName: course.name,
                location: course.location,
                teacher: course.teacher
            )

            // 原版 alarm id 串是 `courseId + "_" + 触发毫秒`；
            // iOS 无法按数字 requestCode 去重，这里用同一段信息构造字符串 identifier，
            // 语义保持一致：同一门课的不同触发时刻 → 不同 identifier → 各自独立存在。
            let epochMinute = Int(trigger.timeIntervalSince1970 / 60)
            result.append(
                ReminderPendingNotification(
                    identifier: "\(course.id)_\(epochMinute)",
                    triggerDate: trigger,
                    content: content
                )
            )
        }
        return result
    }

    // MARK: - 整窗计划

    /// 生成整份待发通知计划（纯函数，不触系统）。
    ///
    /// 逐行对应 `rescheduleAll` 的骨架（`CourseReminderScheduler.java:41-120`）：
    /// ```
    /// cancelAll(context, alarmManager)                 // 全量取消（iOS 侧在调度器里做）
    /// if (!settings.classReminderEnabled) return       // 开关关闭 → 什么都不排
    /// slots = getEffectiveTimeSlots(settings, profiles)
    /// if (slots.isEmpty()) return                      // 没有作息时间 → 什么都不排
    /// for (i = 0; i < 15; i++) { day = now + i 天; 收集当日候选 }
    /// 保存 alarm id 列表
    /// ```
    ///
    /// ⚠️ 与原版的两处**有意差异**，都必须记在案：
    /// 1. **窗口上限**：原版 15 天全排；这里先取全部 15 天候选，再按
    ///    `window.maximumScheduledCount`（默认 64，iOS 硬上限）截取**最早的若干条**。
    ///    被截掉的条目数可从 `ReminderPlan.droppedCount` the 读到；
    /// 2. **去重**：同一 identifier 的候选只保留**第一条**。
    ///    原版靠 `PendingIntent` + `FLAG_CANCEL_CURRENT` 天然覆盖
    ///    （`CourseReminderScheduler.java:100`），iOS 靠 identifier 覆盖（A12），
    ///    所以去重是等价语义，不是行为改变。
    public static func plan(
        courses: [Course],
        settings: ReminderSettings,
        effectiveTimeSlots: [String],
        firstWeekStartDate: String?,
        now: Date,
        window: ReminderWindow = .default,
        calendar: Calendar
    ) -> ReminderPlan {
        // 开关关闭 → 原版在 cancelAll 之后直接返回，一条都不排。
        guard settings.isEnabled else { return .empty }
        // 没有可用的作息时间 → 原版 `return emptyList()` 触发早退（`:55-57`）。
        guard !effectiveTimeSlots.isEmpty else { return .empty }

        let today = calendar.startOfDay(for: now)
        let dayCount = max(window.dayWindow, 0)
        guard dayCount > 0 else { return .empty }

        var candidates: [ReminderPendingNotification] = []
        for offset in 0..<dayCount {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            candidates.append(
                contentsOf: occurrences(
                    onDay: day,
                    now: now,
                    courses: courses,
                    effectiveTimeSlots: effectiveTimeSlots,
                    settings: settings,
                    firstWeekStartDate: firstWeekStartDate,
                    calendar: calendar
                )
            )
        }

        // 原版依次排入 15 天的循环顺序，这里按触发时刻排序后再截断，
        // 保证「留下的 64 条 = 最近要响的 64 条」，而不是碰巧排在前面的那 64 条。
        let sorted = candidates.sorted { lhs, rhs in
            if lhs.triggerDate != rhs.triggerDate { return lhs.triggerDate < rhs.triggerDate }
            if lhs.identifier != rhs.identifier { return lhs.identifier < rhs.identifier }
            return lhs.content.title < rhs.content.title
        }

        var seen = Set<String>()
        var deduplicated: [ReminderPendingNotification] = []
        deduplicated.reserveCapacity(sorted.count)
        for item in sorted where seen.insert(item.identifier).inserted {
            deduplicated.append(item)
        }

        return ReminderPlan(
            occurrences: deduplicated,
            maximumScheduledCount: window.maximumScheduledCount
        )
    }
}
