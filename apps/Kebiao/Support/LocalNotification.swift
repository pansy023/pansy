import Foundation
import UserNotifications

/// 「测试课表自动同步通知」按钮真正要做的事：发一条**真实的**本地通知。
///
/// 逐字照抄 Android `TimetableAutoRefreshNotifier.showTestNotification(context)`
/// （`上课早枝道-源码-1.11.5/app/src/main/java/kebiaocom/example/sync/TimetableAutoRefreshNotifier.java:49-56`）：
/// 它调 `show(context, success = true, courseCount = 8, detail = "", triggerHour = 13)`
/// （`:54`），于是
/// - 标题 = `"课表已自动更新"`（`:79`）
/// - 正文 = `"[中午 1 点] 已从教务系统覆盖本地课表，共 8 门课程。"`（`:75`+`:81`）
/// - 通知栏常驻、可手动清除（`setAutoCancel(false)` / `setOngoing(false)`，`:86`）
///
/// iOS 侧的对应关系：
/// - 通道 `timetable_auto_sync`（`:24`）→ `UNNotificationRequest` 的 `identifier`；
/// - `NOTIFICATION_ID = 881001`（`:26`）没有 iOS 等价物，用固定 identifier 表达
///   「同一条通知被覆盖」的语义（Android 的 `notify(id, …)` 也是同 id 覆盖）；
/// - Android 用 `PendingIntent` 打开 `MainActivity`（`:68-71`），iOS 点击通知默认
///   就是回到本 App，不需要额外声明。
///
/// ⚠️ 与 Android 的能力差异（`docs/recon/03-reminder-and-refresh.md` A 表）：
/// Android 的 `canNotify()` 是「SDK < 33 或已授予 POST_NOTIFICATIONS」（`:44-47`），
/// iOS 必须 `requestAuthorization` 才能发通知，且**用户拒绝后无法在 App 内绕过**，
/// 只能引导去系统设置。这里把「拒绝」如实回报给调用方，由界面弹原版那句提示
/// （`SettingsScreenKt.java:1475`：`"无法测试：请先在系统设置中允许本应用发送通知"`）。
enum LocalNotificationTester {

    /// 固定 identifier：覆盖式，反复点「测试」只会更新同一条。
    /// 对应 Android 的 `CHANNEL_ID = "timetable_auto_sync"`（`:24`）。
    static let identifier = "timetable_auto_sync"

    /// 测试通知的标题，逐字取自 `TimetableAutoRefreshNotifier.java:79`。
    static let testTitle = "课表已自动更新"
    /// 测试通知的正文，逐字取自 `TimetableAutoRefreshNotifier.java:75`、`:81`。
    static let testBody = "[中午 1 点] 已从教务系统覆盖本地课表，共 8 门课程。"

    /// 发一条测试通知。
    ///
    /// - Returns: 已成功安排通知时为 `true`；通知权限被拒绝 / 未被授予时为 `false`
    ///   （界面据此弹「无法测试」提示）。
    @discardableResult
    static func sendTestAutoSyncNotification() async -> Bool {
        let center = UNUserNotificationCenter.current()

        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            guard granted else { return false }
        case .denied:
            return false
        default:
            break
        }

        let content = UNMutableNotificationContent()
        content.title = testTitle
        content.body = testBody
        content.sound = .default

        // Android 是立刻 `notify(...)`；iOS 不允许「0 秒后」交付，
        // 取 2 秒——短到像立即弹出，又不会因为系统延迟被丢掉。
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

        do {
            try await center.add(request)
            return true
        } catch {
            return false
        }
    }
}
