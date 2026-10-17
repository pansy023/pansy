import XCTest
@testable import KebiaoCore

/// 上课提醒的**纯计算**测试（用户要求的「测试八：提醒功能」中可在本机确定性验证的部分）。
///
/// 期望值来源：`上课早枝道-源码-1.11.5/app/src/main/java/kebiaocom/example/reminder/
/// CourseReminderScheduler.java`（行号写在 `ClassReminderPlanner` 的每个成员上），
/// 以及 `TimetableAutoRefreshAlarms.java`（自动刷新钟点）。
///
/// ⚠️ 本文件**只能**证明「算得对」，证明不了「通知真的会弹」：
/// `UNUserNotificationCenter` 的授权与投递必须在真实设备上验证，
/// 见 `docs/audit/functional-audit.md` 的「需要真机验证」清单。
final class ClassReminderPlannerTests: XCTestCase {

    /// 固定时区，避免结果随运行机器变化。
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_CN")
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0, minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = 0
        return calendar.date(from: components)!
    }

    private func course(
        id: Int = 1,
        name: String = "高等数学",
        location: String = "教学楼A 101",
        dayOfWeek: Int = 1,
        startPeriod: Int = 1,
        startWeek: Int = 1,
        endWeek: Int = 20,
        isOdd: Int = 0
    ) -> Course {
        Course(
            id: id,
            name: name,
            teacher: "张老师",
            location: location,
            dayOfWeek: dayOfWeek,
            startPeriod: startPeriod,
            endPeriod: startPeriod + 1,
            color: 0,
            weekRange: "",
            startWeek: startWeek,
            endWeek: endWeek,
            isOdd: isOdd
        )
    }

    /// `["08:10-08:55", "09:00-09:45", …]`；索引 = `startPeriod - 1`。
    private let slots = ["08:10-08:55", "09:00-09:45", "10:00-10:45", "11:00-11:45"]

    // MARK: - 提前量钳制

    /// `CourseReminderScheduler.java:88` 的 `coerceAtLeast(classReminderMinutes, 1)`：
    /// 0 / 负数一律按 1 分钟处理，而不是「准点」或「往后推」。
    func testEffectiveLeadMinutesClampsToAtLeastOne() {
        XCTAssertEqual(ClassReminderPlanner.effectiveLeadMinutes(0), 1)
        XCTAssertEqual(ClassReminderPlanner.effectiveLeadMinutes(-30), 1)
        XCTAssertEqual(ClassReminderPlanner.effectiveLeadMinutes(1), 1)
        XCTAssertEqual(ClassReminderPlanner.effectiveLeadMinutes(10), 10)
        XCTAssertEqual(ClassReminderPlanner.minimumLeadMinutes, 1)
    }

    // MARK: - HH:mm 解析

    /// `CourseReminderScheduler.java:171-182` 的 `parseMinute`。
    func testParseMinuteOfDay() {
        XCTAssertEqual(ClassReminderPlanner.parseMinuteOfDay("08:10"), 8 * 60 + 10)
        XCTAssertEqual(ClassReminderPlanner.parseMinuteOfDay("00:00"), 0)
        XCTAssertEqual(ClassReminderPlanner.parseMinuteOfDay("23:59"), 23 * 60 + 59)
        // 只有**整串**会 trim（`:173`），"8:5" 这种非补零写法照样能解析。
        XCTAssertEqual(ClassReminderPlanner.parseMinuteOfDay(" 08:10 "), 8 * 60 + 10)
        XCTAssertEqual(ClassReminderPlanner.parseMinuteOfDay("8:5"), 8 * 60 + 5)

        // 失败即 nil（原版跳过这门课）。
        XCTAssertNil(ClassReminderPlanner.parseMinuteOfDay("08"))
        XCTAssertNil(ClassReminderPlanner.parseMinuteOfDay("08:"))
        XCTAssertNil(ClassReminderPlanner.parseMinuteOfDay("08:10:00"))
        XCTAssertNil(ClassReminderPlanner.parseMinuteOfDay("abc"))
        XCTAssertNil(ClassReminderPlanner.parseMinuteOfDay(""))
        // `split` 出来的两段**没有**各自 trim（与 Kotlin 一致）。
        XCTAssertNil(ClassReminderPlanner.parseMinuteOfDay("08: 10"))
    }

    // MARK: - 单课触发时刻

    func testReminderDateSubtractsLeadMinutes() {
        let day = date(2025, 9, 1)

        XCTAssertEqual(
            ClassReminderPlanner.reminderDate(
                dayAtMidnight: day, startPeriodStartText: "08:10", leadMinutes: 10, calendar: calendar
            ),
            date(2025, 9, 1, hour: 8, minute: 0)
        )
        // 提前量 0 → 按 1 分钟算。
        XCTAssertEqual(
            ClassReminderPlanner.reminderDate(
                dayAtMidnight: day, startPeriodStartText: "08:10", leadMinutes: 0, calendar: calendar
            ),
            date(2025, 9, 1, hour: 8, minute: 9)
        )
        // 解析失败 → nil，由调用方跳过。
        XCTAssertNil(
            ClassReminderPlanner.reminderDate(
                dayAtMidnight: day, startPeriodStartText: "not-a-time", leadMinutes: 10, calendar: calendar
            )
        )
    }

    /// 跨零点的提前量：00:05 提前 10 分钟 = **前一天** 23:55。
    func testReminderDateCanCrossMidnight() {
        XCTAssertEqual(
            ClassReminderPlanner.reminderDate(
                dayAtMidnight: date(2025, 9, 1),
                startPeriodStartText: "00:05",
                leadMinutes: 10,
                calendar: calendar
            ),
            date(2025, 8, 31, hour: 23, minute: 55)
        )
    }

    // MARK: - 星期映射

    /// `CourseReminderScheduler.java:184-202` 的 `toMondayBasedDay`。
    /// 输入是 `Calendar.weekday`（周日 = 1 … 周六 = 7），输出「周一 = 1 … 周日 = 7」。
    func testMondayBasedDay() {
        XCTAssertEqual(ClassReminderPlanner.mondayBasedDay(weekday: 2), 1, "周一")
        XCTAssertEqual(ClassReminderPlanner.mondayBasedDay(weekday: 3), 2, "周二")
        XCTAssertEqual(ClassReminderPlanner.mondayBasedDay(weekday: 4), 3, "周三")
        XCTAssertEqual(ClassReminderPlanner.mondayBasedDay(weekday: 5), 4, "周四")
        XCTAssertEqual(ClassReminderPlanner.mondayBasedDay(weekday: 6), 5, "周五")
        XCTAssertEqual(ClassReminderPlanner.mondayBasedDay(weekday: 7), 6, "周六")
        XCTAssertEqual(ClassReminderPlanner.mondayBasedDay(weekday: 1), 7, "周日")
    }

    // MARK: - 教学周（提醒路径版本）

    /// `CourseReminderScheduler.java:204-242`：`"yyyy-M-d"` 三段整数解析，
    /// 失败/为空一律退化成第 1 周。
    func testReminderTeachingWeekParsesDashedDate() {
        XCTAssertEqual(
            ClassReminderPlanner.teachingWeek(firstWeekStartDate: nil, target: date(2025, 9, 1), calendar: calendar),
            1
        )
        XCTAssertEqual(
            ClassReminderPlanner.teachingWeek(firstWeekStartDate: "   ", target: date(2025, 9, 1), calendar: calendar),
            1
        )
        // 刻意**不是** `yyyy-MM-dd` 解析：斜杠分隔解析不出来，退化成第 1 周。
        XCTAssertEqual(
            ClassReminderPlanner.teachingWeek(firstWeekStartDate: "2025/9/1", target: date(2025, 9, 1), calendar: calendar),
            1
        )

        XCTAssertEqual(
            ClassReminderPlanner.teachingWeek(firstWeekStartDate: "2025-9-1", target: date(2025, 9, 1), calendar: calendar),
            1
        )
        XCTAssertEqual(
            ClassReminderPlanner.teachingWeek(firstWeekStartDate: "2025-9-1", target: date(2025, 9, 7), calendar: calendar),
            1,
            "第 7 天仍属第 1 周"
        )
        XCTAssertEqual(
            ClassReminderPlanner.teachingWeek(firstWeekStartDate: "2025-9-1", target: date(2025, 9, 8), calendar: calendar),
            2
        )
        XCTAssertEqual(
            ClassReminderPlanner.teachingWeek(firstWeekStartDate: "2025-9-1", target: date(2025, 9, 15), calendar: calendar),
            3
        )
        // 开学日之前 → 夹到第 1 周。
        XCTAssertEqual(
            ClassReminderPlanner.teachingWeek(firstWeekStartDate: "2025-9-1", target: date(2025, 8, 20), calendar: calendar),
            1
        )
    }

    /// ⚠️ 本函数**没有上界钳制**，与 `WeekLogic.teachingWeek` 不同 ——
    /// 这是原版的既存分歧（`CourseReminderScheduler.java:204-242` vs
    /// `TimetableScreenKt.java:301-317`），测试把差异固定下来，避免将来「顺手统一」。
    func testReminderTeachingWeekHasNoUpperClamp() {
        XCTAssertEqual(
            ClassReminderPlanner.teachingWeek(firstWeekStartDate: "2025-9-1", target: date(2026, 1, 1), calendar: calendar),
            18,
            "2025-09-01 → 2026-01-01 相隔 122 天 = 17 周余 3 天 → 第 18 周"
        )
    }

    // MARK: - 单双周筛选

    /// `CourseReminderScheduler.java:244-258` 的 `occursInWeek`。
    /// 注意：提醒路径**不看** `weekRange` 字符串。
    func testCourseOccursInWeek() {
        let allWeeks = course(startWeek: 2, endWeek: 5, isOdd: 0)
        XCTAssertFalse(ClassReminderPlanner.courseOccursInWeek(allWeeks, week: 1))
        XCTAssertTrue(ClassReminderPlanner.courseOccursInWeek(allWeeks, week: 2))
        XCTAssertTrue(ClassReminderPlanner.courseOccursInWeek(allWeeks, week: 5))
        XCTAssertFalse(ClassReminderPlanner.courseOccursInWeek(allWeeks, week: 6))

        let odd = course(startWeek: 1, endWeek: 10, isOdd: 1)
        XCTAssertTrue(ClassReminderPlanner.courseOccursInWeek(odd, week: 1))
        XCTAssertFalse(ClassReminderPlanner.courseOccursInWeek(odd, week: 2))
        XCTAssertTrue(ClassReminderPlanner.courseOccursInWeek(odd, week: 3))

        let even = course(startWeek: 1, endWeek: 10, isOdd: 2)
        XCTAssertFalse(ClassReminderPlanner.courseOccursInWeek(even, week: 1))
        XCTAssertTrue(ClassReminderPlanner.courseOccursInWeek(even, week: 2))
        XCTAssertFalse(ClassReminderPlanner.courseOccursInWeek(even, week: 3))

        // `weekRange` 不参与提醒路径的判断：留空的 weekRange 照样命中。
        let blankRange = course(startWeek: 1, endWeek: 20, isOdd: 0)
        XCTAssertEqual(blankRange.weekRange, "")
        XCTAssertTrue(ClassReminderPlanner.courseOccursInWeek(blankRange, week: 12))
    }

    // MARK: - 单日候选

    func testOccurrencesFiltersByDayWeekPeriodAndNow() {
        let monday = date(2025, 9, 1)
        // 先自证前提：2025-09-01 必须是周一，否则下面所有期望值都失去意义。
        XCTAssertEqual(calendar.component(.weekday, from: monday), 2, "2025-09-01 应当是周一")
        XCTAssertEqual(ClassReminderPlanner.mondayBasedDay(weekday: 2), 1)

        let settings = ReminderSettings(isEnabled: true, mode: .weak, leadMinutes: 10)
        let mondayCourse = course(dayOfWeek: 1, startPeriod: 1)

        // ① 现在 07:00 < 触发 08:00 → 排一条。
        let planned = ClassReminderPlanner.occurrences(
            onDay: monday,
            now: date(2025, 9, 1, hour: 7),
            courses: [mondayCourse],
            effectiveTimeSlots: slots,
            settings: settings,
            firstWeekStartDate: "2025-9-1",
            calendar: calendar
        )
        XCTAssertEqual(planned.count, 1)
        XCTAssertEqual(planned.first?.triggerDate, date(2025, 9, 1, hour: 8, minute: 0))
        XCTAssertEqual(planned.first?.identifier, "1_\(Int(date(2025, 9, 1, hour: 8).timeIntervalSince1970 / 60))")
        XCTAssertEqual(planned.first?.content.title, "课前提醒：高等数学")

        // ② 触发时刻已过 → 不排（原版是 `trigger > now` 严格大于，`:89`）。
        XCTAssertTrue(
            ClassReminderPlanner.occurrences(
                onDay: monday,
                now: date(2025, 9, 1, hour: 8, minute: 5),
                courses: [mondayCourse],
                effectiveTimeSlots: slots,
                settings: settings,
                firstWeekStartDate: "2025-9-1",
                calendar: calendar
            ).isEmpty
        )
        // ③ 正好等于触发时刻也不排 —— 锁住「严格大于」这条边界。
        XCTAssertTrue(
            ClassReminderPlanner.occurrences(
                onDay: monday,
                now: date(2025, 9, 1, hour: 8, minute: 0),
                courses: [mondayCourse],
                effectiveTimeSlots: slots,
                settings: settings,
                firstWeekStartDate: "2025-9-1",
                calendar: calendar
            ).isEmpty,
            "触发时刻等于 now 时不该排（原版是严格大于）"
        )

        // ④ 课程不在这一天 → 不排。
        XCTAssertTrue(
            ClassReminderPlanner.occurrences(
                onDay: monday,
                now: date(2025, 9, 1, hour: 7),
                courses: [course(dayOfWeek: 2, startPeriod: 1)],
                effectiveTimeSlots: slots,
                settings: settings,
                firstWeekStartDate: "2025-9-1",
                calendar: calendar
            ).isEmpty
        )

        // ⑤ 节次越界（slots 只有 4 项，startPeriod = 5）→ 跳过，不是崩溃。
        XCTAssertTrue(
            ClassReminderPlanner.occurrences(
                onDay: monday,
                now: date(2025, 9, 1, hour: 7),
                courses: [course(dayOfWeek: 1, startPeriod: 5)],
                effectiveTimeSlots: slots,
                settings: settings,
                firstWeekStartDate: "2025-9-1",
                calendar: calendar
            ).isEmpty
        )

        // ⑥ 该课本周不上（单周课遇到第 2 周）→ 不排。
        XCTAssertTrue(
            ClassReminderPlanner.occurrences(
                onDay: date(2025, 9, 8),
                now: date(2025, 9, 8, hour: 7),
                courses: [course(dayOfWeek: 1, startPeriod: 1, isOdd: 1)],
                effectiveTimeSlots: slots,
                settings: settings,
                firstWeekStartDate: "2025-9-1",
                calendar: calendar
            ).isEmpty
        )

        // ⑦ 总开关关闭 → 一条都不排。
        XCTAssertTrue(
            ClassReminderPlanner.occurrences(
                onDay: monday,
                now: date(2025, 9, 1, hour: 7),
                courses: [mondayCourse],
                effectiveTimeSlots: slots,
                settings: ReminderSettings(isEnabled: false),
                firstWeekStartDate: "2025-9-1",
                calendar: calendar
            ).isEmpty
        )
    }

    // MARK: - 整窗计划

    func testPlanIsEmptyWhenDisabledOrWithoutSlots() {
        let now = date(2025, 9, 1, hour: 7)

        XCTAssertEqual(
            ClassReminderPlanner.plan(
                courses: [course()],
                settings: ReminderSettings(isEnabled: false),
                effectiveTimeSlots: slots,
                firstWeekStartDate: "2025-9-1",
                now: now,
                calendar: calendar
            ),
            .empty,
            "提醒总开关关闭时应当完全不排（原版在 cancelAll 之后直接 return）"
        )
        XCTAssertEqual(
            ClassReminderPlanner.plan(
                courses: [course()],
                settings: ReminderSettings(isEnabled: true),
                effectiveTimeSlots: [],
                firstWeekStartDate: "2025-9-1",
                now: now,
                calendar: calendar
            ),
            .empty,
            "没有作息时间槽时应当完全不排"
        )
    }

    /// 15 天窗口 + iOS 64 条上限：只保留**最早的若干条**，其余靠下次重排滚动补上。
    func testPlanSortsAndTruncatesToLimit() {
        let now = date(2025, 9, 1, hour: 7)
        let courses = [
            course(id: 1, name: "高等数学", startPeriod: 1),
            course(id: 2, name: "线性代数", startPeriod: 2),
        ]
        let window = ReminderWindow(dayWindow: 15, maximumScheduledCount: 3)

        let plan = ClassReminderPlanner.plan(
            courses: courses,
            settings: ReminderSettings(isEnabled: true, mode: .weak, leadMinutes: 10),
            effectiveTimeSlots: slots,
            firstWeekStartDate: "2025-9-1",
            now: now,
            window: window,
            calendar: calendar
        )

        // 15 天窗口覆盖 3 个周一（9/1、9/8、9/15），每个周一 2 门课 → 6 条候选。
        XCTAssertEqual(plan.occurrences.count, 6)
        XCTAssertEqual(plan.scheduled.count, 3)
        XCTAssertEqual(plan.droppedCount, 3)
        XCTAssertTrue(plan.didHitPendingLimit)

        // 候选必须是按触发时刻升序的。
        for index in 1..<plan.occurrences.count {
            XCTAssertLessThanOrEqual(
                plan.occurrences[index - 1].triggerDate,
                plan.occurrences[index].triggerDate,
                "候选没有按触发时刻排序"
            )
        }
        XCTAssertEqual(plan.scheduled.first?.triggerDate, date(2025, 9, 1, hour: 8, minute: 0))
        XCTAssertEqual(plan.occurrences.last?.triggerDate, date(2025, 9, 15, hour: 8, minute: 50))

        // 计划结果本身不可变，且 `scheduled` 恒为 `occurrences` 的前缀。
        XCTAssertEqual(Array(plan.occurrences.prefix(3)), plan.scheduled)
    }

    /// 同一 identifier 的候选只保留第一条（对应原版 `FLAG_CANCEL_CURRENT` 的覆盖语义）。
    func testPlanDeduplicatesSameIdentifier() {
        let now = date(2025, 9, 1, hour: 7)
        // 两门课 id 相同、同一天、同一起始节次 → 触发时刻与 identifier 都相同。
        let courses = [
            course(id: 7, name: "高等数学", startPeriod: 1),
            course(id: 7, name: "大学物理", startPeriod: 1),
        ]

        let plan = ClassReminderPlanner.plan(
            courses: courses,
            settings: ReminderSettings(isEnabled: true, mode: .weak, leadMinutes: 10),
            effectiveTimeSlots: slots,
            firstWeekStartDate: "2025-9-1",
            now: now,
            window: ReminderWindow(dayWindow: 1, maximumScheduledCount: 64),
            calendar: calendar
        )

        XCTAssertEqual(plan.occurrences.count, 1, "同一 identifier 的候选应当去重")
        XCTAssertEqual(plan.occurrences.first?.identifier, "7_\(Int(date(2025, 9, 1, hour: 8).timeIntervalSince1970 / 60))")
        XCTAssertEqual(plan.droppedCount, 0)
        XCTAssertFalse(plan.didHitPendingLimit)
    }

    /// 窗口边界：`dayWindow: 1` 只看今天，`dayWindow: 0` 什么都不排。
    func testPlanDayWindowBounds() {
        let now = date(2025, 9, 1, hour: 7)
        let settings = ReminderSettings(isEnabled: true, mode: .weak, leadMinutes: 10)
        let courses = [course(id: 1, startPeriod: 1)]

        let todayOnly = ClassReminderPlanner.plan(
            courses: courses,
            settings: settings,
            effectiveTimeSlots: slots,
            firstWeekStartDate: "2025-9-1",
            now: now,
            window: ReminderWindow(dayWindow: 1, maximumScheduledCount: 64),
            calendar: calendar
        )
        XCTAssertEqual(todayOnly.occurrences.count, 1)

        XCTAssertEqual(
            ClassReminderPlanner.plan(
                courses: courses,
                settings: settings,
                effectiveTimeSlots: slots,
                firstWeekStartDate: "2025-9-1",
                now: now,
                window: ReminderWindow(dayWindow: 0, maximumScheduledCount: 64),
                calendar: calendar
            ),
            .empty
        )
    }

    // MARK: - ReminderPlan / ReminderWindow 值域

    func testReminderPlanPrefixClampsNegativeLimit() {
        let now = date(2025, 9, 1, hour: 7)
        let plan = ClassReminderPlanner.plan(
            courses: [course(id: 1, startPeriod: 1), course(id: 2, startPeriod: 2)],
            settings: ReminderSettings(isEnabled: true, mode: .weak, leadMinutes: 10),
            effectiveTimeSlots: slots,
            firstWeekStartDate: "2025-9-1",
            now: now,
            window: ReminderWindow(dayWindow: 1, maximumScheduledCount: -5),
            calendar: calendar
        )
        // 负数上限按 0 处理，不会崩、也不会反向截取。
        XCTAssertEqual(plan.scheduled, [])
        XCTAssertEqual(plan.droppedCount, plan.occurrences.count)
    }

    func testReminderWindowDefaultsMatchAndroidWindowAndiOSLimit() {
        XCTAssertEqual(ReminderWindow.default.dayWindow, 15, "与 Android 的 15 天窗口一致")
        XCTAssertEqual(ReminderWindow.default.maximumScheduledCount, 64, "iOS 待发通知硬上限")
        XCTAssertEqual(ReminderWindow.iOSPendingNotificationLimit, 64)
    }

    /// `classReminderMode` 是自由字符串：解析不出来的值归到 `.weak`
    /// （`CourseReminderReceiver.java:483-485`）。
    func testReminderModeParsing() {
        XCTAssertEqual(ReminderMode(rawMode: "strong"), .strong)
        XCTAssertEqual(ReminderMode(rawMode: "weak"), .weak)
        XCTAssertEqual(ReminderMode(rawMode: ""), .weak)
        XCTAssertEqual(ReminderMode(rawMode: "STRONG"), .weak, "原版是大小写敏感的比较，不认识的取值走弱提醒")
        XCTAssertEqual(ReminderMode.weak.displayName, "弱提醒（通知）")
        XCTAssertEqual(ReminderMode.strong.displayName, "强提醒（闹钟）")
    }
}

/// 课表自动刷新的**时刻计算**测试。
///
/// ⚠️ 只覆盖「下一个 01:00 / 13:00 是什么时候」这类纯数学；
/// iOS 上 `BGAppRefreshTask` **不保证**到点执行，这一条无法用单测证明，
/// 见功能审计文档的「需要真机验证」清单。
final class RefreshSchedulingTests: XCTestCase {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_CN")
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int, minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = 0
        return calendar.date(from: components)!
    }

    func testConstantsMatchAndroid() {
        XCTAssertEqual(RefreshScheduling.morningHour, 1)
        XCTAssertEqual(RefreshScheduling.afternoonHour, 13)
        XCTAssertEqual(RefreshScheduling.minute, 0)
        XCTAssertEqual(RefreshScheduling.requestCodeMorning, 774401)
        XCTAssertEqual(RefreshScheduling.requestCodeAfternoon, 774413)
        XCTAssertEqual(RefreshScheduling.acceptedHours, [1, 13])
        XCTAssertTrue(RefreshScheduling.isAcceptedHour(1))
        XCTAssertTrue(RefreshScheduling.isAcceptedHour(13))
        XCTAssertFalse(RefreshScheduling.isAcceptedHour(0))
        XCTAssertFalse(RefreshScheduling.isAcceptedHour(12))
        XCTAssertEqual(RefreshScheduling.requestCode(triggerHour: 1), 774401)
        XCTAssertEqual(RefreshScheduling.requestCode(triggerHour: 13), 774413)
        XCTAssertNil(RefreshScheduling.requestCode(triggerHour: 2))
    }

    /// `TimetableAutoRefreshAlarms.java:38`：
    /// 秒/毫秒清零 → 设时分 → **`<= now` 就 +1 天**（注意是 `<=`）。
    func testNextFireDateAdvancesOneDayWhenNotStrictlyLater() {
        XCTAssertEqual(
            RefreshScheduling.nextFireDate(triggerHour: 13, now: date(2025, 9, 1, hour: 12), calendar: calendar),
            date(2025, 9, 1, hour: 13)
        )
        // 正好等于现在 → 顺延到明天（`<=`，不是 `<`）。
        XCTAssertEqual(
            RefreshScheduling.nextFireDate(triggerHour: 13, now: date(2025, 9, 1, hour: 13), calendar: calendar),
            date(2025, 9, 2, hour: 13)
        )
        XCTAssertEqual(
            RefreshScheduling.nextFireDate(triggerHour: 13, now: date(2025, 9, 1, hour: 13, minute: 30), calendar: calendar),
            date(2025, 9, 2, hour: 13)
        )
        XCTAssertEqual(
            RefreshScheduling.nextFireDate(triggerHour: 1, now: date(2025, 9, 1, hour: 12), calendar: calendar),
            date(2025, 9, 2, hour: 1),
            "1 点已经过了 → 明天 1 点"
        )
        // 跨月/跨年。
        XCTAssertEqual(
            RefreshScheduling.nextFireDate(triggerHour: 1, now: date(2025, 12, 31, hour: 23), calendar: calendar),
            date(2026, 1, 1, hour: 1)
        )
    }

    /// 两槽取更早：12:00 时更早的是当天 13:00。
    func testNextFireDatePicksEarlierSlot() {
        XCTAssertEqual(
            RefreshScheduling.nextFireDate(now: date(2025, 9, 1, hour: 12), calendar: calendar),
            date(2025, 9, 1, hour: 13)
        )
        // 14:00 时，1 点与 13 点都已过 → 明天 1 点更早。
        XCTAssertEqual(
            RefreshScheduling.nextFireDate(now: date(2025, 9, 1, hour: 14), calendar: calendar),
            date(2025, 9, 2, hour: 1)
        )
    }

    func testReschedulePlanFollowsAutoSyncSwitch() {
        let now = date(2025, 9, 1, hour: 12)

        XCTAssertEqual(
            RefreshScheduling.reschedulePlan(isAutoSyncEnabled: false, now: now, calendar: calendar),
            .cancelled,
            "开关关闭 → 什么都不排（原版 cancelAll）"
        )

        let plan = RefreshScheduling.reschedulePlan(isAutoSyncEnabled: true, now: now, calendar: calendar)
        XCTAssertTrue(plan.shouldSchedule)
        XCTAssertEqual(plan.triggerHours, [1, 13])
        XCTAssertEqual(plan.nextFireDates.count, 2)
        XCTAssertEqual(plan.earliestBeginDate, date(2025, 9, 1, hour: 13), "两个槽里更早的那个")
    }

    func testRescheduleOneRejectsUnknownHourAndDisabledSwitch() {
        let now = date(2025, 9, 1, hour: 12)

        XCTAssertEqual(
            RefreshScheduling.rescheduleOne(triggerHour: 9, isAutoSyncEnabled: true, now: now, calendar: calendar),
            .cancelled,
            "非 1 / 13 点的钟点，原版接收器直接 return"
        )
        XCTAssertEqual(
            RefreshScheduling.rescheduleOne(triggerHour: 13, isAutoSyncEnabled: false, now: now, calendar: calendar),
            .cancelled,
            "开关关闭时静默不排（也不 cancelAll）"
        )

        let one = RefreshScheduling.rescheduleOne(
            triggerHour: 13,
            isAutoSyncEnabled: true,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(one.triggerHours, [13])
        XCTAssertEqual(one.nextFireDates, [date(2025, 9, 1, hour: 13)])
    }
}
