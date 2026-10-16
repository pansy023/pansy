import Foundation

/// 课表自动刷新的**时刻计算**与重排骨架（纯逻辑，不触系统）。
///
/// ## 原版机制回顾（证据）
/// `上课早枝道-源码-1.11.5/app/src/main/java/kebiaocom/example/sync/TimetableAutoRefreshAlarms.java`：
/// - 每天两个固定钟点：**01:00**（`REQ_01 = 774401`）与 **13:00**（`REQ_13 = 774413`）；
/// - 用的是 `AlarmManager.setAlarmClock(new AlarmClockInfo(t, pi), pi)`（`:54-80`），
///   **不是** `PeriodicWorkRequest`——所以每次响完由接收器再排下一次；
/// - `nextMillisLocal(hour, minute)`：秒/毫秒清零、设上时分，
///   `<= now` 就 `+1 天`（本地时间）；
/// - `rescheduleFromStorage`：只有 `autoSyncTimetableFromJwxt == true` 才排，
///   否则 `cancelAll`。
///
/// ## iOS 侧的现实
/// iOS **没有**「每天 13:00 精确叫醒 App」的能力：
/// - `UNCalendarNotificationTrigger` 只能**发通知**，不能唤醒进程执行同步；
/// - `BGAppRefreshTask`（能力表 A14）由系统按使用习惯调度，
///   **不保证时刻**，App 被用户强杀后也不会运行。
///
/// 所以本文件做两件事，并把非等价性写清楚：
/// 1. 逐字保留「下一个 01:00 / 13:00」的**时刻计算**（它决定状态提示与
///    BGTask 的 `earliestBeginDate` 参考值），可确定性地单测；
/// 2. 提供 `RefreshReschedulePlan` 描述「该不该排、排哪两个钟点」，
///    供 App 层登记 `BGAppRefreshTaskRequest` 使用。
///
/// ⚠️ 明确**不声称**「到点一定会后台刷新」。
public enum RefreshScheduling {

    // MARK: - 常量（逐字照抄）

    /// 广播 action 字符串。证据：`TimetableAutoRefreshAlarms.java:23`。
    public static let action = "kebiaocom.example.action.AUTO_REFRESH_TIMETABLE"

    /// 触发小时在 extras / `WorkManager` input data 里的键名。
    /// 证据：`TimetableAutoRefreshAlarms.java:24` 与
    /// `TimetableAutoRefreshWorker.java:78`（`KEY_TRIGGER_HOUR`）。
    public static let extraHourKey = "trigger_hour"

    /// 凌晨钟点：1 点。证据：`TimetableAutoRefreshAlarms.java:23-24` 的 `REQ_01`/`hour=1`。
    public static let morningHour = 1

    /// 中午钟点：13 点。证据：`:25` 的 `REQ_13`/`hour=13`。
    public static let afternoonHour = 13

    /// 分钟恒为 0。证据：`nextMillisLocal(hour, 0)`（`:38`）。
    public static let minute = 0

    /// 凌晨槽的 `PendingIntent` requestCode。证据：`TimetableAutoRefreshAlarms.java:23`。
    /// iOS 无 requestCode；保留该数字只是为了日志/调试能跟 Android 对上号。
    public static let requestCodeMorning = 774401

    /// 中午槽的 requestCode。证据：`TimetableAutoRefreshAlarms.java:25`。
    public static let requestCodeAfternoon = 774413

    /// 接收器只接受这两个钟点。证据：`TimetableAutoRefreshAlarmReceiver.java:34-40`
    /// （`if (hour != 1 && hour != 13) return;`）。
    public static let acceptedHours: [Int] = [morningHour, afternoonHour]

    /// 该钟点是否被原版接收器接受。
    public static func isAcceptedHour(_ hour: Int) -> Bool {
        acceptedHours.contains(hour)
    }

    /// 该钟点对应的 Android requestCode（仅用于对照）。
    public static func requestCode(triggerHour: Int) -> Int? {
        switch triggerHour {
        case morningHour: return requestCodeMorning
        case afternoonHour: return requestCodeAfternoon
        default: return nil
        }
    }

    // MARK: - 下一个触发时刻

    /// 计算某钟点的「下一次」触发时刻。
    ///
    /// 逐行对应 `TimetableAutoRefreshAlarms.java:38` 与 `:54-80` 的
    /// `nextMillisLocal(int hour, int minute)`：
    /// ```
    /// calendar = 现在
    /// calendar.set(SECOND, 0); calendar.set(MILLISECOND, 0)   // 秒/毫秒清零
    /// calendar.set(HOUR_OF_DAY, hour); calendar.set(MINUTE, minute)
    /// if (calendar.getTimeInMillis() <= now) calendar.add(DAY_OF_YEAR, 1)
    /// return calendar.getTimeInMillis()
    /// ```
    /// ⚠️ 是 `<=`（`:38` 的 `if (millis <= System.currentTimeMillis())`），
    /// 即**正好等于现在**也要顺延一天。
    ///
    /// - Parameters:
    ///   - hour: 目标小时（`hourOfDay`）。
    ///   - minute: 目标分钟。
    ///   - now: 当前时刻。
    ///   - calendar: 提供时区与日期运算的日历。
    public static func nextFireDate(
        hour: Int,
        minute: Int,
        now: Date,
        calendar: Calendar
    ) -> Date {
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = minute
        components.second = 0
        components.nanosecond = 0

        guard let candidate = calendar.date(from: components) else {
            // `date(from:)` 只在组件不自洽时才失败；这里的组件都由 `now` 派生，不会发生。
            return now
        }
        if candidate <= now {
            return calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
        }
        return candidate
    }

    /// 某个钟点的下一次触发（`minute` 固定为 0，与原版一致）。
    public static func nextFireDate(triggerHour: Int, now: Date, calendar: Calendar) -> Date {
        nextFireDate(hour: triggerHour, minute: minute, now: now, calendar: calendar)
    }

    /// 两个槽位「下一次触发」中**更早**的那个。
    ///
    /// 这是 iOS 侧唯一可用的近似：`BGAppRefreshTask` 只接受一个
    /// `earliestBeginDate`，无法像 Android 那样同时挂两个 `setAlarmClock`。
    /// 到点后由下一次前台/回调重排。**不是**「两个钟点都会准时跑」。
    public static func nextFireDate(now: Date, calendar: Calendar) -> Date {
        let morning = nextFireDate(triggerHour: morningHour, now: now, calendar: calendar)
        let afternoon = nextFireDate(triggerHour: afternoonHour, now: now, calendar: calendar)
        return min(morning, afternoon)
    }

    // MARK: - 重排计划

    /// 「该不该排、排什么」的纯描述，供 App 层落到具体系统 API。
    public struct ReschedulePlan: Equatable, Sendable {

        /// 是否需要登记刷新任务（= 开关打开）。
        public var shouldSchedule: Bool
        /// 需要登记的两个钟点（开关关闭时为空）。
        public var triggerHours: [Int]
        /// 每个钟点对应的下一次触发时刻（与 `triggerHours` 同序）。
        public var nextFireDates: [Date]

        /// 开关关闭时：什么都不排（原版是 `cancelAll()`，iOS 侧是注销请求）。
        public static let cancelled = ReschedulePlan(
            shouldSchedule: false,
            triggerHours: [],
            nextFireDates: []
        )

        public init(shouldSchedule: Bool, triggerHours: [Int], nextFireDates: [Date]) {
            self.shouldSchedule = shouldSchedule
            self.triggerHours = triggerHours
            self.nextFireDates = nextFireDates
        }

        /// 最早的触发时刻（`BGAppRefreshTaskRequest.earliestBeginDate` 的参考值）。
        public var earliestBeginDate: Date? {
            nextFireDates.min()
        }
    }

    /// 由「自动同步开关」决定重排计划。
    ///
    /// 逐行对应 `rescheduleFromStorage`（`TimetableAutoRefreshAlarms.java:21-38`）：
    /// ```
    /// if (settings.getAutoSyncTimetableFromJwxt()) { scheduleSlot(13, REQ_13); scheduleSlot(1, REQ_01); }
    /// else cancelAll()
    /// ```
    /// ⚠️ 原版**先排 13 点再排 1 点**（`:33-34`），顺序只是调用顺序、不影响结果；
    /// 这里为便于阅读按时间先后返回 `[1, 13]`，触发时刻各自独立计算，语义一致。
    public static func reschedulePlan(
        isAutoSyncEnabled: Bool,
        now: Date,
        calendar: Calendar
    ) -> ReschedulePlan {
        guard isAutoSyncEnabled else { return .cancelled }
        let hours = acceptedHours
        let dates = hours.map { nextFireDate(triggerHour: $0, now: now, calendar: calendar) }
        return ReschedulePlan(shouldSchedule: true, triggerHours: hours, nextFireDates: dates)
    }

    /// 到点后重排**单个**槽位。
    ///
    /// 逐行对应 `TimetableAutoRefreshAlarmReceiver.onReceive` 的
    /// 「处理本次 → `rescheduleOne(ctx, hour)`」流程（`:42-58`）：
    /// ```
    /// if (hour != 1 && hour != 13) return;          // 非法钟点：直接返回，不排
    /// if (!settings.getAutoSyncTimetableFromJwxt()) return;   // 开关关闭：静默不排也不取消
    /// scheduleSlot(hour, ...)  // 用同一 hour 算下一次
    /// ```
    /// ⚠️ 与原版一致：开关关掉时这里**什么都不做**（既不排、也不 cancelAll）。
    public static func rescheduleOne(
        triggerHour: Int,
        isAutoSyncEnabled: Bool,
        now: Date,
        calendar: Calendar
    ) -> ReschedulePlan {
        guard isAcceptedHour(triggerHour) else { return .cancelled }
        guard isAutoSyncEnabled else { return .cancelled }
        let next = nextFireDate(triggerHour: triggerHour, now: now, calendar: calendar)
        return ReschedulePlan(
            shouldSchedule: true,
            triggerHours: [triggerHour],
            nextFireDates: [next]
        )
    }
}
