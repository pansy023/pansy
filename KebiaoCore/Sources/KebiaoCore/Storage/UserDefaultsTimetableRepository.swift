import Foundation

// MARK: - 存储键名

/// iOS 侧使用的全部存储键名，**逐字**抄自 Android 端
/// `LocalStorage.java`。
///
/// 为什么要单独列成一个 `enum` 而不是散在实现里：这些字符串是**数据兼容性契约**
/// （m03200 第七节），一旦写错一个字符，用户从 Android 迁过来的课表就读不出来。
/// 集中放一处便于和 `docs/recon/storage.md` 的表格逐行对照。
///
/// 证据列（全部相对 `上课早枝道-源码-1.11.5/app/src/main/java/kebiaocom/example/data/`）：
/// - `LocalStorage.java`：`timetable_prefs` 里除两个 UI 开关外的所有键；
/// - `.../ui/theme/ThemeMode.java:28`、`:51`：`ui_dark_mode`；
/// - `.../ui/theme/OptimizeMode.java:28`、`:62`：`ui_optimize_mode`。
///
/// ⚠️ 本类型刻意**不公开**：键名是存储实现的细节，调用方只该用 `TimetableRepository`。
enum TimetableStorageKeys {

    // MARK: 教务凭证（storage.md §2.1 / LocalStorage.java:41、:46、:50、:54）

    /// `LocalStorage.java:41` / `:46`。
    static let username = "username"
    /// `LocalStorage.java:41` / `:50`。
    static let password = "password"
    /// `LocalStorage.java:41` / `:54`（默认 `https://jwgl.xihang.com.cn`）。
    static let jwxtUrl = "jwxtUrl"

    // MARK: JSON 容器（storage.md §2.3 / §2.4）

    /// 单个键里放一个 JSON **数组**，写 `LocalStorage.java:111`、读 `:118-124`。
    static let coursesJson = "courses_json"
    /// 写 `LocalStorage.java:187`、读 `:193-197`。
    static let profilesJson = "timetable_profiles_json"
    /// 只用于 `clearTimetableData()`：原版 `CourseReminderScheduler.java:140` 写、`:145-149` 读。
    /// iOS 端的提醒走 `UNUserNotificationCenter`，不写这个键；清空时仍要删掉它，
    /// 免得用户从 Android 带过来的旧键留在本机。
    static let reminderAlarmIds = "reminder_alarm_ids"

    // MARK: 「不再提示」弹窗（storage.md §2.5）

    /// `LocalStorage.java:282` 读、`:286` 写。
    static let disclaimerDontShow = "disclaimer_dont_show"
    /// `LocalStorage.java:290` 读、`:294` 写。
    static let usageGuideDontShow = "usage_guide_dont_show"

    // MARK: UI 开关（storage.md §2.5）

    /// `ThemeMode.java:28` 读、`:51` 写；**默认 false**。
    static let uiDarkMode = "ui_dark_mode"
    /// `OptimizeMode.java:28` 读、`:62` 写；**默认 false**。
    static let uiOptimizeMode = "ui_optimize_mode"

    // MARK: AppSettings 的 26 个持久化字段（storage.md §2.2）

    static let backgroundImageUri = "backgroundImageUri"
    static let periodsPerDay = "periodsPerDay"
    static let periodDurationMinutes = "periodDurationMinutes"
    static let breakDurationMinutes = "breakDurationMinutes"
    static let firstPeriodStartTime = "firstPeriodStartTime"
    static let firstWeekStartDate = "firstWeekStartDate"
    static let semesterWeeks = "semesterWeeks"
    static let showSaturday = "showSaturday"
    static let showSunday = "showSunday"
    static let showNonCurrentWeekCourses = "showNonCurrentWeekCourses"
    static let showWeekSlider = "showWeekSlider"
    static let reverseMainText = "reverseMainText"
    static let autoCheckUpdate = "autoCheckUpdate"
    static let autoSyncTimetableFromJwxt = "autoSyncTimetableFromJwxt"
    static let selectedTimetableProfileId = "selectedTimetableProfileId"
    static let classReminderEnabled = "classReminderEnabled"
    static let classReminderMode = "classReminderMode"
    static let classReminderMinutes = "classReminderMinutes"
    static let nonCurrentWeekCourseAlphaPercent = "nonCurrentWeekCourseAlphaPercent"
    static let courseCardAlphaPercent = "courseCardAlphaPercent"
    static let courseFrostedIntensityPercent = "courseFrostedIntensityPercent"
    static let courseCellHeightDp = "courseCellHeightDp"
    static let courseTextSizeSp = "courseTextSizeSp"
    static let showCourseTime = "showCourseTime"
    static let showCourseLocation = "showCourseLocation"
    static let showCourseTeacher = "showCourseTeacher"

    /// 26 个设置键的完整清单，按上表顺序（= `LocalStorage.java:64` 的写入顺序）。
    ///
    /// `AppSettings.id` **不在**其中：原版 `saveSettings` 全链没有 `id`
    /// （`LocalStorage.java:64` 只写这 26 个，`:89` 用默认值掩码构造对象），
    /// 所以 iOS 端同样既不写也不读它。
    static let settings: [String] = [
        backgroundImageUri,
        periodsPerDay,
        periodDurationMinutes,
        breakDurationMinutes,
        firstPeriodStartTime,
        firstWeekStartDate,
        semesterWeeks,
        showSaturday,
        showSunday,
        showNonCurrentWeekCourses,
        showWeekSlider,
        reverseMainText,
        autoCheckUpdate,
        autoSyncTimetableFromJwxt,
        selectedTimetableProfileId,
        classReminderEnabled,
        classReminderMode,
        classReminderMinutes,
        nonCurrentWeekCourseAlphaPercent,
        courseCardAlphaPercent,
        courseFrostedIntensityPercent,
        courseCellHeightDp,
        courseTextSizeSp,
        showCourseTime,
        showCourseLocation,
        showCourseTeacher
    ]

    /// 顶层 JSON 容器的全部键（清空时要整键删掉）。
    static let jsonContainers: [String] = [coursesJson, profilesJson]

    /// `clearTimetableData()` 要删掉的**全部**键：
    /// 本文件会 **写** 的 35 个键（3 个凭证 + 26 个设置 + 2 个 JSON 容器 + 2 个弹窗开关 + 2 个 UI 开关）
    /// 外加只读的 `reminder_alarm_ids`（见其说明）。
    ///
    /// 刻意**不包含**原版的只读遗留键 `showWeekend`（`LocalStorage.java:77`、`:79`：
    /// 1.11.5 只读不写）：它不属于本实现管辖的数据，写测试探针也无从判断归属。
    static let clearedKeys: [String] = {
        var keys: [String] = [username, password, jwxtUrl]
        keys.append(contentsOf: jsonContainers)
        keys.append(contentsOf: settings)
        keys.append(disclaimerDontShow)
        keys.append(usageGuideDontShow)
        keys.append(uiDarkMode)
        keys.append(uiOptimizeMode)
        keys.append(reminderAlarmIds)
        return keys
    }()

    /// 清空时**只**删除 `timetable_prefs` 里的这些键；`log_prefs` 的 `log_enabled`
    /// 以及任何本实现不认识的键都必须原样留着
    /// （原版 `clearAll()` 只清 `timetable_prefs`，`LocalStorage.java:164-166`）。
    ///
    /// ⚠️ 与 Android 的已知差异：原版 `prefs.edit().clear()` 会把 `timetable_prefs`
    /// 连**未知键**一起清掉；iOS 用一个 `UserDefaults` suite 同时承载业务键、
    /// App 自己的其它偏好（例如未来的 `log_enabled`），整域清空会误伤，
    /// 所以这里改成「只删本实现管得着的键」。
}

// MARK: - 解码错误描述

/// 把 `JSONDecoder` 的错误压成一行人话，喂给
/// `TimetableRepositoryError.decodingFailed(key:reason:)`。
///
/// 为什么两个 JSON 容器（课程 / 作息方案）共用一个描述器：它们的失败原因
/// 无非「截断」「类型不符」「缺字段」，报出的原话本身没有别的信息量，
/// 统一格式反而便于 `TimetableStore.lastError` 与测试断言。
enum StorageDecodingReport {

    /// 把底层解码错误压成一行人话，便于塞进 `lastError` 与测试断言。
    static func describe(_ error: Error) -> String {
        if let decodingError = error as? DecodingError {
            switch decodingError {
            case let .dataCorrupted(context):
                return "数据损坏（\(path(context.codingPath))）：\(context.debugDescription)"
            case let .keyNotFound(key, context):
                return "缺少键 \(key.stringValue)（\(path(context.codingPath))）"
            case let .typeMismatch(type, context):
                return "类型不符，期望 \(type)（\(path(context.codingPath))）"
            case let .valueNotFound(type, context):
                return "值为空，期望 \(type)（\(path(context.codingPath))）"
            @unknown default:
                return "未知的解码错误"
            }
        }
        return error.localizedDescription
    }

    private static func path(_ codingPath: [CodingKey]) -> String {
        if codingPath.isEmpty { return "根" }
        return codingPath.map { $0.stringValue }.joined(separator: ".")
    }
}

// MARK: - UserDefaults 实现

/// 用 `UserDefaults` 落盘课表数据的 `TimetableRepository`。
///
/// 这是 iOS 端的主存储实现（App 里用 `.standard`，测试里注入独立 suite）。
///
/// ## 与 Android 端的关系
///
/// - 键名、JSON 形状、默认值全部照抄 `LocalStorage.java`，
///   清单见 `docs/recon/storage.md`；每个键的证据写在 `TimetableStorageKeys` 的注释里。
/// - **课程**是「单个键 `courses_json` 里放一个 JSON 数组」（`LocalStorage.java:94-111`），
///   不是一门课一个键；作息方案同理（`timetable_profiles_json`，`:170-187`）。
/// - `AppSettings` 的 26 个字段（`id` 除外）各自是一个独立键
///   （`LocalStorage.java:64` / `:67-90`），不是一个大 JSON。
/// - `clearTimetableData()` 抄的是 `clearAll()`，但只删本实现管得着的键
///   （见 `TimetableStorageKeys.clearedKeys` 的说明），绝不碰 `log_prefs`。
///
/// ## 安全要求（规格 m03200 第七节，硬性）
///
/// Android 端把教务密码**明文**写进 `timetable_prefs`（`LocalStorage.java:41`，
/// 证据见 `docs/recon/storage.md` §4.2）。iOS 端**禁止**沿用：
/// - `password` **绝不进 `UserDefaults`**，只交给注入的 `CredentialStore`
///   （`KeychainCredentialStore`，`kSecClassGenericPassword`）；
/// - `username` / `jwxtUrl` 不敏感，仍按 Android 的键名进 `UserDefaults`；
/// - `loadCredentials()` 若发现 Android 时代留下的明文 `password` 键，
///   会把它迁移进钥匙串并**立即删掉**该键，不让明文继续留在偏好里。
///
/// ## 落盘时机
///
/// 每个 `saveXxx` 都立即写 `UserDefaults`（`UserDefaults` 自身是同步内存 + 异步落磁盘，
/// 进程重启不丢），不做任何攒批/延迟写入 —— 「App 重启后数据还在」是本实现的验收点。
public final class UserDefaultsTimetableRepository: TimetableRepository {

    // MARK: 编码器

    /// `.sortedKeys` 让输出键序与原版 `org.json.JSONObject.toString()` 一样稳定，
    /// 便于人工比对两份数据（`docs/recon/storage.md` §9 U5 提醒「不能假定键序稳定」，
    /// 这里只是让它**可预测**，不依赖它）。
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder = JSONDecoder()

    // MARK: 依赖

    /// 可注入：App 用 `.standard`，测试用 `UserDefaults(suiteName:)` 独立 suite。
    private let userDefaults: UserDefaults

    /// 密码的去处。默认钥匙串；测试用内存实现。
    private let credentialStore: CredentialStore

    /// 上一次 `loadCredentials()` 里密码侧的失败原因。见
    /// `TimetableRepository.credentialLoadWarning` 的说明：它只报告「密码读不到」，
    /// 不改变「账号字段照常返回」这件事。每次读取都会重置。
    public private(set) var credentialLoadWarning: String?

    // MARK: 初始化

    public init(
        userDefaults: UserDefaults = .standard,
        credentialStore: CredentialStore = KeychainCredentialStore()
    ) {
        self.userDefaults = userDefaults
        self.credentialStore = credentialStore
    }

    // MARK: - 课表（courses_json）

    /// 读全部课程。
    ///
    /// 逐条对应 `LocalStorage.java:118-124`：键不存在或空串 → 空列表。
    /// - Throws: `decodingFailed`，键存在但不是「JSON 数组」或数组内有元素无法解析成课程时。
    public func loadCourses() throws -> [Course] {
        let key = TimetableStorageKeys.coursesJson
        guard let text = userDefaults.string(forKey: key), !text.isEmpty else { return [] }
        guard let data = text.data(using: .utf8) else {
            throw TimetableRepositoryError.decodingFailed(
                key: key,
                reason: "存进去的字符串不是合法的 UTF-8"
            )
        }
        do {
            return try Self.decoder.decode([Course].self, from: data)
        } catch {
            throw TimetableRepositoryError.decodingFailed(
                key: key,
                reason: StorageDecodingReport.describe(error)
            )
        }
    }

    /// 写全部课程（整表覆盖，与 `LocalStorage.java:111` 的 `putString` 一致）。
    public func saveCourses(_ courses: [Course]) throws {
        let key = TimetableStorageKeys.coursesJson
        do {
            let data = try Self.encoder.encode(courses)
            guard let text = String(data: data, encoding: .utf8) else {
                throw TimetableRepositoryError.writeFailed(key: key, reason: "编码结果不是合法 UTF-8")
            }
            // 立刻落盘，不攒批。
            userDefaults.set(text, forKey: key)
        } catch let error as TimetableRepositoryError {
            throw error
        } catch {
            throw TimetableRepositoryError.writeFailed(
                key: key,
                reason: StorageDecodingReport.describe(error)
            )
        }
    }

    // MARK: - 设置（26 个独立键）

    /// 读设置：26 个键逐一 `object(forKey:)`，缺键/类型不符回落默认值。
    ///
    /// 逐条对应 `LocalStorage.java:67-90`。默认值取 `AppSettings()` 的出厂值
    /// （与 `:69-89` 的 `opt*` 第二参一致）。
    ///
    /// - Throws: 只在某个键存在但既不是数字也不是可解析的字符串时抛
    ///   `decodingFailed(key: 该字段名)`。
    public func loadSettings() throws -> AppSettings {
        let defaults = AppSettings.default
        var settings = AppSettings()

        // `id` 不持久化：原版读取时用默认值掩码构造（`LocalStorage.java:89` 首参 0），
        // 值不确定（`docs/recon/storage.md` §9 U2），这里统一取出厂默认 1。
        settings.id = defaults.id

        settings.backgroundImageUri = optionalString(TimetableStorageKeys.backgroundImageUri)
        settings.periodsPerDay = try intValue(
            TimetableStorageKeys.periodsPerDay, fallback: defaults.periodsPerDay)
        settings.periodDurationMinutes = try intValue(
            TimetableStorageKeys.periodDurationMinutes, fallback: defaults.periodDurationMinutes)
        settings.breakDurationMinutes = try intValue(
            TimetableStorageKeys.breakDurationMinutes, fallback: defaults.breakDurationMinutes)
        settings.firstPeriodStartTime = stringValue(
            TimetableStorageKeys.firstPeriodStartTime, fallback: defaults.firstPeriodStartTime)
        settings.firstWeekStartDate = optionalString(TimetableStorageKeys.firstWeekStartDate)
        settings.semesterWeeks = try intValue(
            TimetableStorageKeys.semesterWeeks, fallback: defaults.semesterWeeks)

        // `showSaturday` / `showSunday` 有旧键回退：`LocalStorage.java:77`、`:79`
        // `getBoolean("showSaturday", getBoolean("showWeekend", false))`。
        let legacyWeekend = boolValue("showWeekend", fallback: defaults.showSaturday)
        settings.showSaturday = boolValue(TimetableStorageKeys.showSaturday, fallback: legacyWeekend)
        settings.showSunday = boolValue(TimetableStorageKeys.showSunday, fallback: legacyWeekend)

        settings.showNonCurrentWeekCourses = boolValue(
            TimetableStorageKeys.showNonCurrentWeekCourses, fallback: defaults.showNonCurrentWeekCourses)
        settings.showWeekSlider = boolValue(
            TimetableStorageKeys.showWeekSlider, fallback: defaults.showWeekSlider)
        settings.reverseMainText = boolValue(
            TimetableStorageKeys.reverseMainText, fallback: defaults.reverseMainText)

        // ⚠️ `autoCheckUpdate`：原版**读取侧**默认是 false
        // （`LocalStorage.java:83` 的 `getBoolean("autoCheckUpdate", false)`），
        // 而 Kotlin data class 默认是 true（`AppSettings.kt:34`），两者矛盾（storage.md §9 U3）。
        // 「盘上没有这个键」时要复现的是 Android 的**读取结果**，所以这里硬取 false；
        // `AppSettings.default.autoCheckUpdate` 保持 true —— 那是构造默认值，
        // 只表示「内存里新建一个对象」，不代表键缺失时的取值。两者不是一回事。
        // 对应审计用例：StorageRoundTripTests.testAuditFinding_emptyStoreAutoCheckUpdateFollowsAndroidReadDefault
        settings.autoCheckUpdate = boolValue(
            TimetableStorageKeys.autoCheckUpdate, fallback: false)

        settings.autoSyncTimetableFromJwxt = boolValue(
            TimetableStorageKeys.autoSyncTimetableFromJwxt,
            fallback: defaults.autoSyncTimetableFromJwxt)
        settings.selectedTimetableProfileId = stringValue(
            TimetableStorageKeys.selectedTimetableProfileId,
            fallback: defaults.selectedTimetableProfileId)
        settings.classReminderEnabled = boolValue(
            TimetableStorageKeys.classReminderEnabled, fallback: defaults.classReminderEnabled)
        settings.classReminderMode = stringValue(
            TimetableStorageKeys.classReminderMode, fallback: defaults.classReminderMode)
        settings.classReminderMinutes = try intValue(
            TimetableStorageKeys.classReminderMinutes, fallback: defaults.classReminderMinutes)
        settings.nonCurrentWeekCourseAlphaPercent = try intValue(
            TimetableStorageKeys.nonCurrentWeekCourseAlphaPercent,
            fallback: defaults.nonCurrentWeekCourseAlphaPercent)
        settings.courseCardAlphaPercent = try intValue(
            TimetableStorageKeys.courseCardAlphaPercent, fallback: defaults.courseCardAlphaPercent)
        settings.courseFrostedIntensityPercent = try intValue(
            TimetableStorageKeys.courseFrostedIntensityPercent,
            fallback: defaults.courseFrostedIntensityPercent)
        settings.courseCellHeightDp = try intValue(
            TimetableStorageKeys.courseCellHeightDp, fallback: defaults.courseCellHeightDp)
        settings.courseTextSizeSp = try intValue(
            TimetableStorageKeys.courseTextSizeSp, fallback: defaults.courseTextSizeSp)
        settings.showCourseTime = boolValue(
            TimetableStorageKeys.showCourseTime, fallback: defaults.showCourseTime)
        settings.showCourseLocation = boolValue(
            TimetableStorageKeys.showCourseLocation, fallback: defaults.showCourseLocation)
        settings.showCourseTeacher = boolValue(
            TimetableStorageKeys.showCourseTeacher, fallback: defaults.showCourseTeacher)

        return settings
    }

    /// 写设置：26 个独立键，与 `LocalStorage.java:64` 逐键对应。
    ///
    /// 与原版的一处**有意差异**：原版 `putBoolean/putInt/putString` 会把 `null`
    /// 直接剔除（`putString` 传 null 等价于 remove），所以未设置的
    /// `backgroundImageUri` / `firstWeekStartDate` 在 XML 里是**没有这个键**。
    /// iOS 端沿用同一语义：值为 nil 就 `removeObject(forKey:)`。
    public func saveSettings(_ settings: AppSettings) throws {
        // 可空字段：nil 时删键（等价于原版的 put null）。
        writeOptionalString(TimetableStorageKeys.backgroundImageUri, settings.backgroundImageUri)
        writeOptionalString(TimetableStorageKeys.firstWeekStartDate, settings.firstWeekStartDate)

        userDefaults.set(settings.periodsPerDay, forKey: TimetableStorageKeys.periodsPerDay)
        userDefaults.set(
            settings.periodDurationMinutes, forKey: TimetableStorageKeys.periodDurationMinutes)
        userDefaults.set(
            settings.breakDurationMinutes, forKey: TimetableStorageKeys.breakDurationMinutes)
        userDefaults.set(
            settings.firstPeriodStartTime, forKey: TimetableStorageKeys.firstPeriodStartTime)
        userDefaults.set(settings.semesterWeeks, forKey: TimetableStorageKeys.semesterWeeks)
        userDefaults.set(settings.showSaturday, forKey: TimetableStorageKeys.showSaturday)
        userDefaults.set(settings.showSunday, forKey: TimetableStorageKeys.showSunday)
        userDefaults.set(
            settings.showNonCurrentWeekCourses,
            forKey: TimetableStorageKeys.showNonCurrentWeekCourses)
        userDefaults.set(settings.showWeekSlider, forKey: TimetableStorageKeys.showWeekSlider)
        // `reverseMainText` 原版仍写（`LocalStorage.java:64`），虽然 1.11.5 里它恒为 false。
        userDefaults.set(settings.reverseMainText, forKey: TimetableStorageKeys.reverseMainText)
        userDefaults.set(settings.autoCheckUpdate, forKey: TimetableStorageKeys.autoCheckUpdate)
        userDefaults.set(
            settings.autoSyncTimetableFromJwxt,
            forKey: TimetableStorageKeys.autoSyncTimetableFromJwxt)
        userDefaults.set(
            settings.selectedTimetableProfileId,
            forKey: TimetableStorageKeys.selectedTimetableProfileId)
        userDefaults.set(
            settings.classReminderEnabled, forKey: TimetableStorageKeys.classReminderEnabled)
        userDefaults.set(settings.classReminderMode, forKey: TimetableStorageKeys.classReminderMode)
        userDefaults.set(
            settings.classReminderMinutes, forKey: TimetableStorageKeys.classReminderMinutes)
        userDefaults.set(
            settings.nonCurrentWeekCourseAlphaPercent,
            forKey: TimetableStorageKeys.nonCurrentWeekCourseAlphaPercent)
        userDefaults.set(
            settings.courseCardAlphaPercent, forKey: TimetableStorageKeys.courseCardAlphaPercent)
        userDefaults.set(
            settings.courseFrostedIntensityPercent,
            forKey: TimetableStorageKeys.courseFrostedIntensityPercent)
        userDefaults.set(
            settings.courseCellHeightDp, forKey: TimetableStorageKeys.courseCellHeightDp)
        userDefaults.set(settings.courseTextSizeSp, forKey: TimetableStorageKeys.courseTextSizeSp)
        userDefaults.set(settings.showCourseTime, forKey: TimetableStorageKeys.showCourseTime)
        userDefaults.set(
            settings.showCourseLocation, forKey: TimetableStorageKeys.showCourseLocation)
        userDefaults.set(settings.showCourseTeacher, forKey: TimetableStorageKeys.showCourseTeacher)
    }

    // MARK: - 作息方案（timetable_profiles_json）

    /// 读全部作息方案。
    ///
    /// 对应 `LocalStorage.java:193-197` / `:252-256`：键不存在、空串、
    /// 或解析出一个空数组 → 返回出厂内置的 `defaultProfile`。
    public func loadProfiles() throws -> [TimetableProfile] {
        let key = TimetableStorageKeys.profilesJson
        guard let text = userDefaults.string(forKey: key), !text.isEmpty else {
            return [.defaultProfile]
        }
        guard let data = text.data(using: .utf8) else {
            throw TimetableRepositoryError.decodingFailed(
                key: key,
                reason: "存进去的字符串不是合法的 UTF-8"
            )
        }
        let decoded: [TimetableProfile]
        do {
            decoded = try Self.decoder.decode([TimetableProfile].self, from: data)
        } catch {
            throw TimetableRepositoryError.decodingFailed(
                key: key,
                reason: StorageDecodingReport.describe(error)
            )
        }
        // 原版 `:252-256`：解析出空数组也回落到默认档案。
        if decoded.isEmpty { return [.defaultProfile] }
        // 原版 `:236-242` 读取时按节次 index 升序重排（`ComparisonsKt.compareValues`），
        // JSON 里的顺序不被信任 —— 这里照做。
        return decoded.map { profile in
            var sorted = profile
            sorted.periodTimes.sort { $0.index < $1.index }
            return sorted
        }
    }

    /// 写全部作息方案。对应 `LocalStorage.java:187`。
    public func saveProfiles(_ profiles: [TimetableProfile]) throws {
        let key = TimetableStorageKeys.profilesJson
        do {
            let data = try Self.encoder.encode(profiles)
            guard let text = String(data: data, encoding: .utf8) else {
                throw TimetableRepositoryError.writeFailed(key: key, reason: "编码结果不是合法 UTF-8")
            }
            userDefaults.set(text, forKey: key)
        } catch let error as TimetableRepositoryError {
            throw error
        } catch {
            throw TimetableRepositoryError.writeFailed(
                key: key,
                reason: StorageDecodingReport.describe(error)
            )
        }
    }

    // MARK: - 教务凭证（用户名/URL 进 UserDefaults，密码进钥匙串）

    /// 读凭证。
    ///
    /// - `username` / `jwxtUrl`：`LocalStorage.java:46-57`，缺键回落
    ///   `""` / `UserCredentials.defaultJwxtUrl`；
    /// - `password`：来自 `credentialStore`，**不读** `UserDefaults` 的 `password` 键；
    ///   仅当钥匙串里没有、而偏好里存在 Android 时代遗留的明文时才回退读取，
    ///   并立刻迁移进钥匙串 + 删掉明文键。
    /// - `id`：原版不持久化（`LocalStorage.java:59` 硬编码 1），这里取 `UserCredentials` 的默认 1。
    ///
    /// - Important: **密码读失败不再牵连账号。** 早先这里让
    ///   `loadPasswordWithLegacyMigration()` 的错误直接上抛，整个函数抛掉之后
    ///   `TimetableStore` 回落成全空的 `UserCredentials`，**已经落盘的 `username` /
    ///   `jwxtUrl` 一起被丢掉**（界面表现：保存过账号，重启后用户名输入框是空的，
    ///   CI 上 `SettingsControlsUITests.testAccountFieldsExistAndSaveIsPersisted` 就撞在这里）。
    ///   现在只把密码置空、把原因记进 `credentialLoadWarning`，账号字段照常返回；
    ///   调用方（`TimetableStore`）再把它并进 `lastError`，不会把错误吞掉。
    public func loadCredentials() throws -> UserCredentials {
        var credentials = UserCredentials(username: "", password: "")

        credentials.username = stringValue(TimetableStorageKeys.username, fallback: "")
        credentials.jwxtUrl = stringValue(
            TimetableStorageKeys.jwxtUrl, fallback: UserCredentials.defaultJwxtUrl)
        // `id` 不持久化：原版读取处硬编码 1（`LocalStorage.java:59`），
        // 这里取 `UserCredentials` 的默认值，同样是 1。
        credentials.id = UserCredentials(username: "", password: "").id

        do {
            credentials.password = try loadPasswordWithLegacyMigration()
            credentialLoadWarning = nil
        } catch {
            credentials.password = ""
            credentialLoadWarning = StorageDecodingReport.describe(error)
        }
        return credentials
    }

    /// 写凭证。
    ///
    /// - `username` / `jwxtUrl` → `UserDefaults`（`LocalStorage.java:41`）；
    /// - `password` → `credentialStore`（Keychain），**绝不**写 `UserDefaults`；
    /// - 空密码等价于「清除密码」：钥匙串条目会被删除，
    ///   这样 `TimetableStore.clearTimetableData()` 之后不会留下一份孤儿密码。
    ///
    /// - Throws: `writeFailed(key: "password")` —— 钥匙串写失败（例如
    ///   非 Apple 平台的 `KeychainCredentialStoreError.platformUnavailable`、
    ///   iOS 的 `errSecMissingEntitlement`）。刻意把底层错误**收进** `reason`
    ///   而不是原样上抛：`TimetableRepository` 的调用方（`TimetableStore`）
    ///   只认识 `TimetableRepositoryError`，不该逼它去 import `Security` 的错误类型。
    ///   ⚠️ 注意顺序：偏好里的 `username` / `jwxtUrl` 已经写进去了才轮到密码，
    ///   所以这里失败会留下「账号更新了、密码没更新」的中间态 —— 与原版
    ///   `commit()` 一次性写入的行为不同，但密码写不进去时至少不会丢账号。
    public func saveCredentials(_ credentials: UserCredentials) throws {
        userDefaults.set(credentials.username, forKey: TimetableStorageKeys.username)
        userDefaults.set(credentials.jwxtUrl, forKey: TimetableStorageKeys.jwxtUrl)

        // 老数据可能还留着明文 password 键，顺手清掉（无论有没有密码都清）。
        userDefaults.removeObject(forKey: TimetableStorageKeys.password)

        do {
            if credentials.password.isEmpty {
                try credentialStore.deletePassword()
            } else {
                try credentialStore.savePassword(credentials.password)
            }
        } catch {
            throw TimetableRepositoryError.writeFailed(
                key: TimetableStorageKeys.password,
                reason: StorageDecodingReport.describe(error)
            )
        }
    }

    // MARK: - 界面开关（两个独立 Boolean 键）

    /// 读深色/优化模式。
    ///
    /// 对应 `ThemeMode.java:28` / `OptimizeMode.java:28`：两者都缺键时取 **false**。
    /// （widget 侧缺 `ui_dark_mode` 时会回退系统深色 —— `DshWidgetRenderer.java:530-537`，
    /// 那是 widget 自己的判断，不属于存储层，这里不做。）
    public func loadUIFlags() throws -> UIFlags {
        UIFlags(
            isDarkTheme: boolValue(TimetableStorageKeys.uiDarkMode, fallback: false),
            isOptimizeMode: boolValue(TimetableStorageKeys.uiOptimizeMode, fallback: false)
        )
    }

    /// 写深色/优化模式。对应 `ThemeMode.java:51` / `OptimizeMode.java:62`。
    public func saveUIFlags(_ flags: UIFlags) throws {
        userDefaults.set(flags.isDarkTheme, forKey: TimetableStorageKeys.uiDarkMode)
        userDefaults.set(flags.isOptimizeMode, forKey: TimetableStorageKeys.uiOptimizeMode)
    }

    // MARK: - 清空

    /// 清空课表相关的键（对应 `LocalStorage.clearAll()`，`LocalStorage.java:164-166`）。
    ///
    /// 删哪些键见 `TimetableStorageKeys.clearedKeys` 的说明；密码走钥匙串删除。
    ///
    /// ⚠️ **不改动** `UserDefaults` 里的其它键（`log_prefs` 的 `log_enabled`、
    /// App 自己的偏好、测试探针等）。原版是整域 `clear()`，iOS 端刻意收窄成
    /// 「删本实现认识的课表键」——理由见 `clearedKeys`。
    public func clearTimetableData() throws {
        for key in TimetableStorageKeys.clearedKeys {
            userDefaults.removeObject(forKey: key)
        }
        try credentialStore.deletePassword()
    }

    // MARK: - 私有：读取辅助

    /// 键不存在时返回 `nil`；存在且是字符串就返回它；其它类型返回 `nil`
    /// （原版 `optString` 对非字符串也只是回落到默认值，这里等价于「当没设过」）。
    private func optionalString(_ key: String) -> String? {
        guard let value = userDefaults.object(forKey: key) else { return nil }
        if let text = value as? String {
            return text
        }
        return nil
    }

    private func stringValue(_ key: String, fallback: String) -> String {
        optionalString(key) ?? fallback
    }

    /// 读 Boolean。原版 `getBoolean(key, default)` 的等价物：
    /// 键不存在 → `fallback`；值是 `NSNumber` → 取 `boolValue`；
    /// 值是字符串 `"true"` / `"false"`（不分大小写）→ 也认（`UserDefaults` 偶尔会把
    /// 手动 `-key value` 的启动参数存成字符串）。
    private func boolValue(_ key: String, fallback: Bool) -> Bool {
        guard let value = userDefaults.object(forKey: key) else { return fallback }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let text = value as? String {
            let lowered = text.lowercased()
            if lowered == "true" || lowered == "1" { return true }
            if lowered == "false" || lowered == "0" { return false }
        }
        return fallback
    }

    /// 读 Int。值缺失或类型不符 → `fallback`。
    ///
    /// 与 `boolValue` 不同，这里**允许抛出**：键存在却是字符串（例如手改过的偏好、
    /// 或将来协议改动留下的脏数据）属于「键存在但内容坏了」，按协议的
    /// 「只有键存在但内容损坏才允许抛 `decodingFailed`」处理，
    /// 让 `TimetableStore` 能把它记进 `lastError`，而不是静默当成出厂值。
    private func intValue(_ key: String, fallback: Int) throws -> Int {
        guard let value = userDefaults.object(forKey: key) else { return fallback }
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let text = value as? String, let parsed = Int(text) {
            return parsed
        }
        throw TimetableRepositoryError.decodingFailed(
            key: key,
            reason: "期望整数，实际是 \(type(of: value))"
        )
    }

    /// 写可空字符串：nil 就删键（等价于原版 `putString(key, null)` 的剔除语义）。
    private func writeOptionalString(_ key: String, _ value: String?) {
        if let value = value {
            userDefaults.set(value, forKey: key)
        } else {
            userDefaults.removeObject(forKey: key)
        }
    }

    // MARK: - 弹窗「不再提示」开关

    /// 免责声明是否永久不再提示（`disclaimer_dont_show`，键默认 `false`）。
    ///
    /// 证据：storage.md §2.5 :175 与 §7.3 :585；读侧 `LocalStorage.java:282`、
    /// 写侧 `:286`（`apply()`）。
    public func loadDisclaimerDismissedPermanently() -> Bool {
        boolValue(TimetableStorageKeys.disclaimerDontShow, fallback: false)
    }

    /// 对应原版 `setDisclaimerDismissedPermanently(boolean dontShow)`（`LocalStorage.java:286`）。
    /// 这里**写 false 而不是删键**：原版是 `putBoolean(key, false)`；两种写法在读取上等价
    /// （都走 fallback），但保留键更贴近原版行为。
    public func setDisclaimerDismissedPermanently(_ dontShow: Bool) {
        userDefaults.set(dontShow, forKey: TimetableStorageKeys.disclaimerDontShow)
    }

    /// 使用引导是否永久不再提示（`usage_guide_dont_show`，键默认 `false`）。
    /// 读 `LocalStorage.java:290`、写 `:294`；参数名不可考（storage.md §9 U4），行为已确证。
    public func loadUsageGuideDismissedPermanently() -> Bool {
        boolValue(TimetableStorageKeys.usageGuideDontShow, fallback: false)
    }

    /// 对应原版 `setUsageGuideDismissedPermanently(boolean)`（`LocalStorage.java:294`）。
    public func setUsageGuideDismissedPermanently(_ dontShow: Bool) {
        userDefaults.set(dontShow, forKey: TimetableStorageKeys.usageGuideDontShow)
    }

    // MARK: - 私有：密码与迁移

    /// 取密码，必要时把 Android 遗留的明文迁移进钥匙串。
    ///
    /// 顺序：
    /// 1. 钥匙串里有非空密码 → 直接用，并**无条件清掉**偏好里的 `password` 明文残留；
    /// 2. 钥匙串里没有（`nil` 或空串）→ 看偏好里的 `password` 键
    ///    （Android 端 `LocalStorage.java:41` 的明文残留）；
    ///    - 有明文：先删明文键，再 `savePassword` 进钥匙串；
    ///    - 没有：删掉可能存在的空串键，返回空串。
    ///
    /// 「无论走哪条分支，明文键都必须消失」——`m03200` 第七节要求密码绝不明文落盘，
    /// 所以这里**不是**只在迁移时才删：只要钥匙串里已经有一份密码，偏好里的明文就是
    /// 多余的副本，留着只会让旧密码永久躺在偏好里（`StorageRoundTripTests` 与
    /// `UserDefaultsTimetableRepositoryTests` 的迁移用例都覆盖这条路径）。
    ///
    /// 钥匙串自身报错（`errSecInteractionNotAllowed` 等）时向上抛，由 `TimetableStore`
    /// 兜底成默认值 + `lastError`；此时**不**删明文——删了就真把用户唯一的密码丢了。
    private func loadPasswordWithLegacyMigration() throws -> String {
        let stored = try credentialStore.loadPassword()
        let legacyKey = TimetableStorageKeys.password

        if let stored = stored, !stored.isEmpty {
            userDefaults.removeObject(forKey: legacyKey)
            return stored
        }

        guard let legacy = optionalString(legacyKey), !legacy.isEmpty else {
            userDefaults.removeObject(forKey: legacyKey)
            return ""
        }

        // 迁移：先删明文，再写钥匙串（顺序上宁可丢一次密码，也不留明文）。
        userDefaults.removeObject(forKey: legacyKey)
        try credentialStore.savePassword(legacy)
        return legacy
    }
}
