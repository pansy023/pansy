import Foundation

/// 存储层接口：把「课表数据从哪来、到哪去」与「界面怎么用」彻底分开。
///
/// 这样做的理由：
/// - `KebiaoCore` 要能在没有 App target、没有 UIKit 的环境里跑测试（`swift test`）；
/// - Android 端把持久化全部塞在一个 `LocalStorage` 类里（SharedPreferences + JSON），
///   iOS 端沿用同样的键名才能读取旧数据，但**不**应该让界面代码直接碰 UserDefaults；
/// - 密码在 iOS 上必须进 Keychain（m03200 第七节），这条策略只在实现里体现，
///   调用方拿到的永远是一个完整的 `UserCredentials`。
///
/// 实现约束（给实现者）：
/// - `loadXxx()` 在「键不存在」时必须返回出厂默认值，**不要**抛错；
///   只有「键存在但内容损坏」才允许抛 `TimetableRepositoryError.decodingFailed`。
/// - 所有键名必须与 Android 端 `LocalStorage.java` 的字面量逐字一致，
///   证据见 `docs/recon/storage.md`。
public protocol TimetableRepository: AnyObject {
    // MARK: 课表

    func loadCourses() throws -> [Course]
    func saveCourses(_ courses: [Course]) throws

    // MARK: 设置

    func loadSettings() throws -> AppSettings
    func saveSettings(_ settings: AppSettings) throws

    // MARK: 作息方案

    func loadProfiles() throws -> [TimetableProfile]
    func saveProfiles(_ profiles: [TimetableProfile]) throws

    // MARK: 教务凭证

    /// `password` 必须来自 Keychain；`username` / `jwxtUrl` 来自 UserDefaults。
    func loadCredentials() throws -> UserCredentials
    func saveCredentials(_ credentials: UserCredentials) throws

    // MARK: 界面开关

    func loadUIFlags() throws -> UIFlags
    func saveUIFlags(_ flags: UIFlags) throws

    // MARK: 弹窗「不再提示」

    /// 免责声明是否永久不再提示（`disclaimer_dont_show`，键默认 `false`）。
    ///
    /// 原版读写入口是 `LocalStorage.isDisclaimerDismissedPermanently()`(`:282`) /
    /// `setDisclaimerDismissedPermanently(boolean)`(`:286`)，见 storage.md §2.5 :175、§7.3 :585。
    /// 这两个开关刻意**不**并进 `AppSettings`：Android 端它们不属于 `AppSettings` 的
    /// 26 个持久化字段，合并会让两端的 JSON 契约都对不上。
    func loadDisclaimerDismissedPermanently() throws -> Bool
    func setDisclaimerDismissedPermanently(_ dontShow: Bool) throws

    /// 使用引导是否永久不再提示（`usage_guide_dont_show`，键默认 `false`）。
    /// 读 `LocalStorage.java:290`、写 `:294`；参数名不可考（storage.md §9 U4），行为已确证。
    func loadUsageGuideDismissedPermanently() throws -> Bool
    func setUsageGuideDismissedPermanently(_ dontShow: Bool) throws

    // MARK: 清空

    /// 对应 Android 端 `LocalStorage.clearAll()`：清空课表相关的全部键
    /// （课程、设置、作息方案、提醒记录），**不动**日志（`log_prefs`）。
    func clearTimetableData() throws
}

/// 与 `kebiaocom.example.ui.theme.ThemeMode` / `OptimizeMode` 对应的两个开关。
///
/// 证据：`上课早枝道-源码-1.11.5/app/src/main/java/kebiaocom/example/ui/theme/ThemeMode.java:28`
/// 与 `.../OptimizeMode.java:28` —— 两者都在 `timetable_prefs` 里，键分别是
/// `ui_dark_mode` 与 `ui_optimize_mode`，**默认都是 false**。
///
/// 原版用两个全局单例 + Compose `MutableState` 实现；iOS 端把状态收进 `TimetableStore`，
/// 语义不变但不再有全局可变状态。
public struct UIFlags: Equatable, Sendable {
    /// 深色模式。键 `ui_dark_mode`。
    public var isDarkTheme: Bool
    /// 优化模式：卡片改为黑白高对比、取消莫兰迪配色。键 `ui_optimize_mode`。
    public var isOptimizeMode: Bool

    public init(isDarkTheme: Bool = false, isOptimizeMode: Bool = false) {
        self.isDarkTheme = isDarkTheme
        self.isOptimizeMode = isOptimizeMode
    }

    /// 与原版两个 `getBoolean(key, false)` 的默认值一致。
    public static let `default` = UIFlags()
}

/// 存储层错误。刻意只有三种，避免让调用方去分辨底层异常。
public enum TimetableRepositoryError: Error, LocalizedError, Equatable {
    /// 键存在但无法解析（原版遇到这种情况会静默回落到默认值，iOS 端选择显式报错，
    /// 但由 `TimetableStore` 兜底成默认值 + 记一条 `lastError`，不会让 App 起不来）。
    case decodingFailed(key: String, reason: String)
    /// 写盘失败。
    case writeFailed(key: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case let .decodingFailed(key, reason):
            return "读取 \(key) 失败：\(reason)"
        case let .writeFailed(key, reason):
            return "写入 \(key) 失败：\(reason)"
        }
    }
}

/// 内存实现：给单元测试和 SwiftUI 预览用，不碰任何持久化。
public final class InMemoryTimetableRepository: TimetableRepository {
    public var courses: [Course]
    public var settings: AppSettings
    public var profiles: [TimetableProfile]
    public var credentials: UserCredentials
    public var uiFlags: UIFlags
    public var disclaimerDismissedPermanently: Bool
    public var usageGuideDismissedPermanently: Bool

    /// 记录每个方法被调用的次数，便于断言「界面改动确实落盘了」。
    public private(set) var saveCounts: [String: Int] = [:]

    public init(
        courses: [Course] = [],
        settings: AppSettings = .default,
        profiles: [TimetableProfile] = [.defaultProfile],
        credentials: UserCredentials = UserCredentials(username: "", password: ""),
        uiFlags: UIFlags = .default,
        disclaimerDismissedPermanently: Bool = false,
        usageGuideDismissedPermanently: Bool = false
    ) {
        self.courses = courses
        self.settings = settings
        self.profiles = profiles
        self.credentials = credentials
        self.uiFlags = uiFlags
        self.disclaimerDismissedPermanently = disclaimerDismissedPermanently
        self.usageGuideDismissedPermanently = usageGuideDismissedPermanently
    }

    public func loadCourses() throws -> [Course] { courses }
    public func saveCourses(_ courses: [Course]) throws {
        self.courses = courses
        saveCounts["courses", default: 0] += 1
    }

    public func loadSettings() throws -> AppSettings { settings }
    public func saveSettings(_ settings: AppSettings) throws {
        self.settings = settings
        saveCounts["settings", default: 0] += 1
    }

    public func loadProfiles() throws -> [TimetableProfile] { profiles }
    public func saveProfiles(_ profiles: [TimetableProfile]) throws {
        self.profiles = profiles
        saveCounts["profiles", default: 0] += 1
    }

    public func loadCredentials() throws -> UserCredentials { credentials }
    public func saveCredentials(_ credentials: UserCredentials) throws {
        self.credentials = credentials
        saveCounts["credentials", default: 0] += 1
    }

    public func loadUIFlags() throws -> UIFlags { uiFlags }
    public func saveUIFlags(_ flags: UIFlags) throws {
        self.uiFlags = flags
        saveCounts["uiFlags", default: 0] += 1
    }

    public func loadDisclaimerDismissedPermanently() -> Bool { disclaimerDismissedPermanently }
    public func setDisclaimerDismissedPermanently(_ dontShow: Bool) {
        self.disclaimerDismissedPermanently = dontShow
        saveCounts["disclaimerDontShow", default: 0] += 1
    }

    public func loadUsageGuideDismissedPermanently() -> Bool { usageGuideDismissedPermanently }
    public func setUsageGuideDismissedPermanently(_ dontShow: Bool) {
        self.usageGuideDismissedPermanently = dontShow
        saveCounts["usageGuideDontShow", default: 0] += 1
    }

    public func clearTimetableData() throws {
        courses = []
        settings = .default
        profiles = [.defaultProfile]
        credentials = UserCredentials(username: "", password: "")
        disclaimerDismissedPermanently = false
        usageGuideDismissedPermanently = false
        saveCounts["clear", default: 0] += 1
    }
}
