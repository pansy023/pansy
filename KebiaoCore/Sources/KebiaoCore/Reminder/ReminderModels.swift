import Foundation

/// 课前提醒的纯数据模型：调度窗口、待发通知、提醒设置值域、计划结果。
///
/// 设计原则（本文件不碰 `UserNotifications`，可在无 iOS SDK 的环境里直接单测）：
/// - 把一个「待发提醒」建模成 `ReminderPendingNotification`，字段与 iOS
///   `UNNotificationRequest` 一一对应（`identifier` / 触发时刻 / 内容）；
/// - 所有与 Android 有关的字面量都写成 `static let` 并注明出处，方便对照。

// MARK: - 调度窗口

/// 提醒的滚动调度窗口。
///
/// ## 为什么不能照抄 Android 的 15 天
/// Android 的 `CourseReminderScheduler.rescheduleAll` 用内联字面量 `while (i2 < 15)`
/// 为**未来 15 天**的每一节课各排一个 `AlarmManager` 精确闹钟
/// （`上课早枝道-源码-1.11.5/app/src/main/java/kebiaocom/example/reminder/CourseReminderScheduler.java:62`），
/// Android 对已排 alarm 数量没有硬上限。
///
/// iOS 的待发本地通知**有硬上限 64 条**（Apple 文档；
/// 见 `docs/recon/03-reminder-and-refresh.md` §1.4 与能力对照表 A11）。
/// 15 天窗口在「每周 20 节课」这种正常课表下就会算出 40+ 条，
/// 一旦课再密一些就必然超限——而超限时 iOS 的行为是**静默丢弃**，
/// 不会有任何报错，也就是「提醒莫名其妙不响」。
///
/// 因此这里做两件事，并把差异明确写下来：
/// 1. `dayWindow` 默认仍是 **15**（与 Android 完全一致，用于筛选候选）；
/// 2. `maximumScheduledCount` 默认 **64**（iOS 硬上限），
///    在候选里只保留**最早的 64 条**，其余靠「每次前台/自动刷新时重算」滚动补上。
///
/// ⚠️ 这不是等价实现：Android 一次排 15 天且全量生效；
/// iOS 只能保证「最近的一批」进系统队列，更远的提醒依赖 App 被重新唤醒后重排。
/// 这个取舍见 `docs/recon/notes-reminder-implementation.md`。
public struct ReminderWindow: Equatable, Sendable {

    /// 向前看多少天（含今天）。Android 对应字面量 `15`
    /// （`CourseReminderScheduler.java:62`）。
    public var dayWindow: Int

    /// 最多向系统登记多少条待发通知。iOS 硬上限 64（A11）。
    public var maximumScheduledCount: Int

    public init(dayWindow: Int = 15, maximumScheduledCount: Int = 64) {
        self.dayWindow = dayWindow
        self.maximumScheduledCount = maximumScheduledCount
    }

    /// 与 Android 相同的窗口天数 + iOS 允许的通知条数。
    public static let `default` = ReminderWindow()

    /// iOS 文档给出的待发本地通知上限。
    public static let iOSPendingNotificationLimit = 64
}

// MARK: - 提醒模式 / 设置值域

/// `AppSettings.classReminderMode` 的取值域。
///
/// 证据：`上课早枝道-源码-1.11.5/app/src/main/java/kebiaocom/example/ui/SettingsScreenKt.java:2960`
/// 的切换逻辑 `areEqual(当前值, "strong") ? "weak" : "strong"`，
/// 以及 `:2938` 的展示文案 `areEqual(值, "strong") ? "强提醒（闹钟）" : "弱提醒（通知）"`。
///
/// ⚠️ 原版**没有**校验：`classReminderMode` 是自由字符串，
/// `CourseReminderReceiver.java:486` 只判断 `areEqual(mode, "strong")`，
/// 其余一切取值都走弱提醒分支。所以这里把「解析不出来的值」归到 `.weak`，
/// 与 `CourseReminderReceiver.java:483-485`（`null → "weak"`）一致，
/// **不**把未知值当错误。
public enum ReminderMode: String, Sendable, CaseIterable {
    /// 普通通知。Android 渠道 `class_reminder_weak`。
    case weak = "weak"
    /// 全屏闹钟样式强提醒。Android 渠道 `class_reminder_strong` + 独立 Activity。
    case strong = "strong"

    /// 把 `AppSettings.classReminderMode` 解析成枚举；未知值按 `weak` 处理。
    public init(rawMode: String) {
        self = ReminderMode(rawValue: rawMode) ?? .weak
    }

    /// 设置页展示文案（`SettingsScreenKt.java:2938` 逐字）。
    public var displayName: String {
        switch self {
        case .weak: return "弱提醒（通知）"
        case .strong: return "强提醒（闹钟）"
        }
    }
}

/// 与提醒/自动刷新相关的设置快照：只有 Android 真正参与判断的字段。
///
/// 证据（`上课早枝道-源码-1.11.5/app/src/main/java/kebiaocom/example/data/AppSettings.java:14-19`）：
/// 提醒路径只读 `classReminderEnabled` / `classReminderMode` / `classReminderMinutes`；
/// 自动刷新路径只读 `autoSyncTimetableFromJwxt`。
public struct ReminderSettings: Equatable, Sendable {

    /// `classReminderEnabled`，默认 `false`。
    public var isEnabled: Bool
    /// `classReminderMode`，默认 `"weak"`。
    public var mode: ReminderMode
    /// `classReminderMinutes`，默认 `10`。
    public var leadMinutes: Int
    /// `autoSyncTimetableFromJwxt`，默认 `false`。
    public var isAutoSyncEnabled: Bool

    public init(
        isEnabled: Bool = false,
        mode: ReminderMode = .weak,
        leadMinutes: Int = 10,
        isAutoSyncEnabled: Bool = false
    ) {
        self.isEnabled = isEnabled
        self.mode = mode
        self.leadMinutes = leadMinutes
        self.isAutoSyncEnabled = isAutoSyncEnabled
    }

    /// 与 `AppSettings()` 出厂值一致（见 `AppSettings.swift` 的同名字段默认值）。
    public static let `default` = ReminderSettings()

    /// 从端口已有的 `AppSettings` 构造。
    ///
    /// 这里只做字段搬运，不做任何规则改写：
    /// `classReminderMinutes` 的「至少 1 分钟」钳制发生在算触发时刻时
    /// （`CourseReminderScheduler.java:88`），**不在**这里改值——
    /// 否则设置页回显的分钟数会与原版不一致。
    public init(settings: AppSettings) {
        self.isEnabled = settings.classReminderEnabled
        self.mode = ReminderMode(rawMode: settings.classReminderMode)
        self.leadMinutes = settings.classReminderMinutes
        self.isAutoSyncEnabled = settings.autoSyncTimetableFromJwxt
    }
}

// MARK: - 待发通知

/// 一条待发提醒：与 iOS `UNNotificationRequest` 一一对应。
///
/// 之所以不直接用 `UNNotificationRequest`：`UNNotificationRequest` 无法在
/// 非苹果平台构造，纯逻辑就永远测不了。调度侧（`ReminderScheduling.swift`）
/// 负责把它翻译成 `UNNotificationRequest`。
public struct ReminderPendingNotification: Equatable, Sendable {

    /// 通知唯一标识。
    ///
    /// Android 用 `requestCode = abs((courseId + "_" + 触发毫秒).hashCode())`
    /// （`CourseReminderScheduler.java:90-91`）标识一个 alarm；
    /// iOS 没有 requestCode，用字符串 identifier，且**相同 identifier 的
    /// `add` 会替换旧请求**（A12），语义与 Android 的 `FLAG_CANCEL_CURRENT` 等价。
    ///
    /// ⚠️ 原版把「触发毫秒」编进了 id，所以改提前量后算出来是新 id；
    /// iOS 侧本实现改成「课程 + 触发时刻（分钟精度）」，
    /// 好让同一节课的提醒可被稳定替换、不会天天堆积重复条目。
    public var identifier: String

    /// 触发时刻（绝对时间）。
    public var triggerDate: Date

    /// 通知内容。
    public var content: ReminderContent

    public init(identifier: String, triggerDate: Date, content: ReminderContent) {
        self.identifier = identifier
        self.triggerDate = triggerDate
        self.content = content
    }
}

/// 已排程的提醒计划：这次重算到底要登记哪些通知。
public struct ReminderPlan: Equatable, Sendable {

    /// 窗口内命中的**全部**候选（已按触发时刻升序、已按 identifier 去重）。
    public var occurrences: [ReminderPendingNotification]

    /// 实际提交给系统的条目（`occurrences` 的前 `maximumScheduledCount` 条）。
    public var scheduled: [ReminderPendingNotification]

    /// 因 iOS 64 条上限被挤掉的条目数。
    public var droppedCount: Int { occurrences.count - scheduled.count }

    /// 计划里是否出现了「被上限截断」的情况（用于刷新状态里提示用户）。
    public var didHitPendingLimit: Bool { droppedCount > 0 }

    public init(occurrences: [ReminderPendingNotification], maximumScheduledCount: Int) {
        self.occurrences = occurrences
        let limit = max(maximumScheduledCount, 0)
        self.scheduled = Array(occurrences.prefix(limit))
    }

    /// 空计划（提醒关闭、或没有可排的课）。
    public static let empty = ReminderPlan(occurrences: [], maximumScheduledCount: 0)
}
