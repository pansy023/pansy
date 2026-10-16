import Foundation

/// 通知文案：标题 / 正文 / 标识符 / 用户信息。
///
/// 全部字面量逐字照抄 Android，出处写在每个成员上。
/// 这是「换个平台重写」时最容易走样的一块，所以**一个字符都不改**。

/// 一条通知的内容 + 标识符。
public struct ReminderContent: Equatable, Sendable {

    /// 通知标题。
    public var title: String
    /// 通知正文（可能含换行，见 `strong` 模式）。
    public var body: String
    /// 通知标识符（iOS 用它做「同 id 覆盖」）。
    public var identifier: String
    /// 随通知携带的附加信息，App 点击后可据此深链。
    public var userInfo: [String: String]

    public init(title: String, body: String, identifier: String, userInfo: [String: String] = [:]) {
        self.title = title
        self.body = body
        self.identifier = identifier
        self.userInfo = userInfo
    }
}

/// 提醒内容的构造规则。
///
/// 证据：
/// - 弱提醒：`上课早枝道-源码-1.11.5/app/src/main/java/kebiaocom/example/reminder/CourseReminderReceiver.java:499-514`
/// - 强提醒页文案：`.../reminder/CourseStrongAlarmActivity.java:150-161`
/// - 自动同步：`.../sync/TimetableAutoRefreshNotifier.java:1310-1340`（见 03-recon §9.1）
public enum ReminderContentBuilder {

    /// 弱提醒正文里 `location` 与 `teacher` 的连接符。
    ///
    /// 逐字取自 `CourseReminderReceiver.java:507` 的
    /// `CollectionsKt.joinToString$default(arrayList, " · ", ...)`：
    /// 空格 + U+00B7（MIDDLE DOT）+ 空格。
    public static let detailSeparator = " · "

    /// 地点与教师都为空时的正文兜底。
    /// 证据：`CourseReminderReceiver.java:509-511`（`if (isBlank(...)) "马上上课啦"`）。
    public static let emptyDetailFallback = "马上上课啦"

    /// 弱提醒标题前缀。
    /// 证据：`CourseReminderReceiver.java:508` 的 `"课前提醒：" + courseName`
    /// （中文全角冒号 U+FF1A）。
    public static let weakTitlePrefix = "课前提醒："

    /// 强提醒固定标题。
    /// 证据：`CourseStrongAlarmActivity.java:657` 的 `TextKt.m2157Text4IGK_g("强提醒", ...)`。
    public static let strongTitle = "强提醒"

    // MARK: - 地点 + 教师

    /// `location` 与 `teacher` 各自去空白后，用 `" · "` 连接，两个都空则回退 `"马上上课啦"`。
    ///
    /// 逐行对应 `CourseReminderReceiver.java:500-511`：
    /// ```
    /// listOf = [location, teacher]
    /// 过滤掉 isBlank 的项（Kotlin isBlank = 全为空白字符即算空）
    /// join(" · ")
    /// 结果仍为 blank → "马上上课啦"
    /// ```
    /// Kotlin 的 `isBlank()` 判定的是 **Unicode 空白**，这里用
    /// `trimmingCharacters(in: .whitespacesAndNewlines)` 近似（与原版一致的常见情形：
    /// 空串、空格、换行、制表符）。
    public static func detailLine(location: String, teacher: String) -> String {
        let parts = [location, teacher]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let joined = parts.joined(separator: detailSeparator)
        return joined.isEmpty ? emptyDetailFallback : joined
    }

    // MARK: - 弱提醒

    /// 弱提醒的通知标识符。
    ///
    /// Android 用的是**通知 id** `("weak_" + courseName).hashCode()`
    /// （`CourseReminderReceiver.java:531`，注意是按课程名而不是 courseId）。
    /// iOS 没有数字 id，但「同一门课的通知互相覆盖、不堆叠」是原版行为，
    /// 所以这里用 `"weak_\(courseName)"` 复刻同样的去重语义
    /// （03-recon §4.1 的 iOS 对应建议）。
    public static func weakIdentifier(courseName: String) -> String {
        "weak_" + courseName
    }

    /// 弱提醒内容。
    ///
    /// - Parameters:
    ///   - courseName: `Course.name`。
    ///   - location: `Course.location`。
    ///   - teacher: `Course.teacher`。
    public static func weak(
        courseName: String,
        location: String,
        teacher: String
    ) -> ReminderContent {
        ReminderContent(
            title: weakTitlePrefix + courseName,
            body: detailLine(location: location, teacher: teacher),
            identifier: weakIdentifier(courseName: courseName),
            // Android 点击只拉起 MainActivity、不带任何参数
            // （`CourseReminderReceiver.java:499`）。iOS 侧多带一个课程名，
            // 只是为了让 App 能选择滚到那门课；**不改变**原版的任何行为。
            userInfo: ["courseName": courseName]
        )
    }

    // MARK: - 强提醒

    /// 强提醒的通知标识符。与弱提醒分开，避免两种模式互相覆盖。
    ///
    /// Android 的强提醒**不是通知**，而是 `CourseStrongAlarmActivity`
    /// （`CourseReminderReceiver.java:486-492`）；iOS 后台不能拉起界面（A6/A15），
    /// 只能用通知承载，故这里给一个独立前缀。
    public static func strongIdentifier(courseName: String) -> String {
        "strong_" + courseName
    }

    /// 强提醒内容：把 `CourseStrongAlarmActivity` 的三行文本搬进通知。
    ///
    /// 逐行对应 `CourseStrongAlarmActivity.java:657-666`：
    /// - 固定标题 `强提醒`；
    /// - `"课程：" + courseName`（必定显示）；
    /// - `"地点：" + location` / `"教师：" + teacher` **仅在非空白时**追加。
    ///
    /// 原版是一屏界面、三行文字；iOS 通知只有一个 body，
    /// 因此用换行把三行拼起来，**文本内容与判定条件完全一致**。
    public static func strong(
        courseName: String,
        location: String,
        teacher: String
    ) -> ReminderContent {
        var lines = ["课程：" + courseName]
        let trimmedLocation = location.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedLocation.isEmpty {
            lines.append("地点：" + location)
        }
        let trimmedTeacher = teacher.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTeacher.isEmpty {
            lines.append("教师：" + teacher)
        }
        return ReminderContent(
            title: strongTitle,
            body: lines.joined(separator: "\n"),
            identifier: strongIdentifier(courseName: courseName),
            userInfo: ["courseName": courseName]
        )
    }

    // MARK: - 按模式分派

    /// 按 `mode` 生成内容；`strong` 走强提醒文案，其余走弱提醒。
    public static func content(
        mode: ReminderMode,
        courseName: String,
        location: String,
        teacher: String
    ) -> ReminderContent {
        switch mode {
        case .weak:
            return weak(courseName: courseName, location: location, teacher: teacher)
        case .strong:
            return strong(courseName: courseName, location: location, teacher: teacher)
        }
    }
}

// MARK: - 自动同步通知

/// 课表自动同步的结果通知。
///
/// 证据（逐字）：
/// - 渠道/标识符：`上课早枝道-源码-1.11.5/app/src/main/java/kebiaocom/example/sync/TimetableAutoRefreshNotifier.java:1276`
///   `CHANNEL_ID = "timetable_auto_sync"`、`:1278` `NOTIFICATION_ID = 881001`；
/// - 标题/正文：`:1331-1336`；
/// - 时间前缀：`:1324-1330`。
///
/// 原版用固定通知 id `881001`，所以多次同步只会**覆盖**同一条通知；
/// iOS 侧用固定 identifier 复刻这一点（03-recon §9.1）。
public enum AutoSyncNotificationBuilder {

    /// 固定标识符。沿用 Android 的渠道 id 字面量（`:1276`）。
    public static let identifier = "timetable_auto_sync"

    /// 固定通知 id。原版常量 `NOTIFICATION_ID`（`:1278`）。
    /// iOS 无数字 id，保留它只为「跨平台日志/调试时能对上号」。
    public static let notificationID = 881001

    /// 标题（成功）。证据：`TimetableAutoRefreshNotifier.java:1331`。
    public static let successTitle = "课表已自动更新"

    /// 标题（失败/未完成）。证据：`TimetableAutoRefreshNotifier.java:1331` 的另一分支。
    public static let failureTitle = "课表自动同步未完成"

    /// 触发小时对应的时间前缀。
    ///
    /// 逐字对应 `TimetableAutoRefreshNotifier.java:1324-1330`：
    /// `1 → "凌晨 1 点"`、`13 → "中午 1 点"`、其余 → `"定时"`。
    public static func timePrefix(triggerHour: Int) -> String {
        switch triggerHour {
        case 1: return "凌晨 1 点"
        case 13: return "中午 1 点"
        default: return "定时"
        }
    }

    /// 成功正文。
    ///
    /// 逐字对应 `TimetableAutoRefreshNotifier.java:1333`：
    /// `"[" + 前缀 + "] 已从教务系统覆盖本地课表，共 " + courseCount + " 门课程。"`
    public static func successBody(courseCount: Int, triggerHour: Int) -> String {
        "[\(timePrefix(triggerHour: triggerHour))] 已从教务系统覆盖本地课表，共 \(courseCount) 门课程。"
    }

    /// 失败正文。
    ///
    /// 逐字对应 `TimetableAutoRefreshNotifier.java:1335`：
    /// `"[" + 前缀 + "] " + detail`。
    public static func failureBody(detail: String, triggerHour: Int) -> String {
        "[\(timePrefix(triggerHour: triggerHour))] " + detail
    }

    /// 组装完整内容。
    public static func content(
        success: Bool,
        courseCount: Int,
        detail: String,
        triggerHour: Int
    ) -> ReminderContent {
        ReminderContent(
            title: success ? successTitle : failureTitle,
            body: success
                ? successBody(courseCount: courseCount, triggerHour: triggerHour)
                : failureBody(detail: detail, triggerHour: triggerHour),
            identifier: identifier,
            userInfo: ["triggerHour": String(triggerHour)]
        )
    }
}
