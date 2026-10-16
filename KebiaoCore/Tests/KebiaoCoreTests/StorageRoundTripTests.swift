import XCTest
import KebiaoCore

// MARK: - 测试替身

/// 内存版凭证仓库：真实实现 `KeychainCredentialStore` 要访问系统钥匙串，
/// 在无人值守的测试机上既慢又可能直接失败；本文件一律注入这一份。
///
/// 与同目录 `PersistenceTests.swift` 里的替身互不干扰：顶层 `private` 是**文件私有**。
private final class StorageRoundTripCredentialStore: CredentialStore {

    /// 当前密码；`nil` 表示钥匙串里没有存过。
    private(set) var password: String?

    private(set) var saveCount = 0
    private(set) var deleteCount = 0

    func loadPassword() throws -> String? { password }

    func savePassword(_ password: String) throws {
        self.password = password
        saveCount += 1
    }

    func deletePassword() throws {
        password = nil
        deleteCount += 1
    }
}

/// 存储层往返测试：键名、默认值、JSON 形状、清空语义，全部以
/// `docs/recon/storage.md`（Android 1.11.5 `LocalStorage.java` 的逐项证据）为准。
///
/// 与同目录 `PersistenceTests.swift` 的分工，且**刻意**如此：
/// - 那份用 `@testable import` 引用 `TimetableStorageKeys`，证明「实现用的是那个常量」；
/// - 本份只用**公开 API + 重抄的 Android 字面量键名**（`import KebiaoCore`，不带 `@testable`），
///   证明「实现真正落盘的键名就是 Android 的那串字符串」——常量本身抄错了只有本份会红。
///
/// 全部用例都是密闭的：`UserDefaults(suiteName: UUID())` 独立 suite + 内存版
/// `CredentialStore`，不碰 `.standard`、不碰真钥匙串、无网络、无 sleep、
/// 无 `fatalError`、无跨用例共享状态。
final class StorageRoundTripTests: XCTestCase {

    // MARK: - 夹具

    private var suiteName: String = ""
    private var userDefaults: UserDefaults!
    private var credentialStore: StorageRoundTripCredentialStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let name = "StorageRoundTripTests-" + UUID().uuidString
        suiteName = name
        // `UserDefaults(suiteName:)` 是可失败构造器；失败就抛出，
        // **不**回落到 `.standard`（否则会写脏开发机的真实偏好）。
        userDefaults = try XCTUnwrap(
            UserDefaults(suiteName: name),
            "无法创建临时 UserDefaults suite：\(name)"
        )
        credentialStore = StorageRoundTripCredentialStore()
    }

    override func tearDownWithError() throws {
        if !suiteName.isEmpty {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        suiteName = ""
        userDefaults = nil
        credentialStore = nil
        try super.tearDownWithError()
    }

    /// 新建一个仓储实例。再次调用同一个 helper = 模拟 App 重启（同一个 suite，全新对象）。
    private func makeRepository() -> UserDefaultsTimetableRepository {
        UserDefaultsTimetableRepository(
            userDefaults: userDefaults,
            credentialStore: credentialStore
        )
    }

    // MARK: - Android 字面量键名

    /// 26 个设置键——原版 `LocalStorage.java` 的字面量与 `AppSettings` 字段名逐字相同
    /// （storage.md §2.2 第 2–27 行）。
    private static let settingsKeys: [String] = [
        "backgroundImageUri",
        "periodsPerDay",
        "periodDurationMinutes",
        "breakDurationMinutes",
        "firstPeriodStartTime",
        "firstWeekStartDate",
        "semesterWeeks",
        "showSaturday",
        "showSunday",
        "showNonCurrentWeekCourses",
        "showWeekSlider",
        "reverseMainText",
        "autoCheckUpdate",
        "autoSyncTimetableFromJwxt",
        "selectedTimetableProfileId",
        "classReminderEnabled",
        "classReminderMode",
        "classReminderMinutes",
        "nonCurrentWeekCourseAlphaPercent",
        "courseCardAlphaPercent",
        "courseFrostedIntensityPercent",
        "courseCellHeightDp",
        "courseTextSizeSp",
        "showCourseTime",
        "showCourseLocation",
        "showCourseTeacher"
    ]

    /// `clearTimetableData()` 宣称要清掉的全部键（storage.md §2.1/§2.3/§2.4/§2.5）。
    ///
    /// 刻意在测试里**重抄一遍字面量**，而不是引用 `TimetableStorageKeys`：
    /// 引用只能证明「实现用的是自己的常量」，重抄才能证明「常量真的等于 Android 那串字面量」。
    private static let managedKeys: [String] = {
        var keys: [String] = ["username", "password", "jwxtUrl"]
        keys.append("courses_json")
        keys.append("timetable_profiles_json")
        keys.append(contentsOf: StorageRoundTripTests.settingsKeys)
        keys.append("disclaimer_dont_show")
        keys.append("usage_guide_dont_show")
        keys.append("ui_dark_mode")
        keys.append("ui_optimize_mode")
        keys.append("reminder_alarm_ids")
        return keys
    }()

    /// 出厂内置作息方案：按 storage.md §5.3 / `LocalStorage.java:263-278` 逐对时间重抄。
    private static var documentedDefaultProfile: TimetableProfile {
        TimetableProfile(
            id: "default",
            name: "默认",
            periodsPerDay: 10,
            periodTimes: [
                PeriodTime(index: 1, start: "08:10", end: "08:55"),
                PeriodTime(index: 2, start: "09:05", end: "09:50"),
                PeriodTime(index: 3, start: "10:20", end: "11:05"),
                PeriodTime(index: 4, start: "11:15", end: "12:00"),
                PeriodTime(index: 5, start: "14:10", end: "14:55"),
                PeriodTime(index: 6, start: "15:05", end: "15:50"),
                PeriodTime(index: 7, start: "16:20", end: "17:05"),
                PeriodTime(index: 8, start: "17:15", end: "18:00"),
                PeriodTime(index: 9, start: "19:30", end: "20:15"),
                PeriodTime(index: 10, start: "20:25", end: "21:10")
            ]
        )
    }

    // MARK: - 样本数据

    private var sampleCourses: [Course] {
        [
            Course(
                id: 7,
                name: "高等数学",
                teacher: "张老师",
                location: "教学楼A 101",
                dayOfWeek: 1,
                startPeriod: 1,
                endPeriod: 2,
                color: -11751600,
                weekRange: "1-16",
                startWeek: 1,
                endWeek: 16,
                isOdd: 0
            ),
            Course(
                id: 8,
                name: "大学物理",
                teacher: "李老师",
                location: "实验楼B 203",
                dayOfWeek: 7,
                startPeriod: 9,
                endPeriod: 10,
                color: -26624,
                weekRange: "1-16(双)",
                startWeek: 2,
                endWeek: 16,
                isOdd: 2
            ),
            Course(
                id: 0,
                name: "",
                teacher: "",
                location: "",
                dayOfWeek: 1,
                startPeriod: 1,
                endPeriod: 1,
                color: 0,
                weekRange: "",
                startWeek: 1,
                endWeek: 20,
                isOdd: 0
            )
        ]
    }

    /// 一个「26 个持久化字段都不是出厂值」的设置对象，用来验证逐字段往返。
    ///
    /// 刻意从 `AppSettings()` 改字段，而不是走 27 个位置参数：字段名比参数顺序更难写错。
    private var sampleSettings: AppSettings {
        var settings = AppSettings()
        settings.id = 99
        settings.backgroundImageUri = "file:///tmp/bg.png"
        settings.periodsPerDay = 11
        settings.periodDurationMinutes = 50
        settings.breakDurationMinutes = 5
        settings.firstPeriodStartTime = "07:50"
        settings.firstWeekStartDate = "2026-03-02"
        settings.semesterWeeks = 18
        settings.showSaturday = true
        settings.showSunday = true
        settings.showNonCurrentWeekCourses = true
        settings.showWeekSlider = true
        settings.reverseMainText = true
        settings.autoCheckUpdate = false
        settings.autoSyncTimetableFromJwxt = true
        settings.selectedTimetableProfileId = "short-day"
        settings.classReminderEnabled = true
        settings.classReminderMode = "strong"
        settings.classReminderMinutes = 15
        settings.nonCurrentWeekCourseAlphaPercent = 30
        settings.courseCardAlphaPercent = 80
        settings.courseFrostedIntensityPercent = 60
        settings.courseCellHeightDp = 80
        settings.courseTextSizeSp = 12
        settings.showCourseTime = false
        settings.showCourseLocation = false
        settings.showCourseTeacher = false
        return settings
    }

    private var sampleProfiles: [TimetableProfile] {
        [
            TimetableProfile(
                id: "short-day",
                name: "半日制",
                periodsPerDay: 2,
                // 刻意乱序：读取侧必须按 index 升序重排（storage.md §5.2）。
                periodTimes: [
                    PeriodTime(index: 2, start: "09:00", end: "09:40"),
                    PeriodTime(index: 1, start: "08:00", end: "08:40")
                ]
            ),
            TimetableProfile(
                id: "evening",
                name: "晚课",
                periodsPerDay: 1,
                periodTimes: [
                    PeriodTime(index: 1, start: "19:00", end: "19:45")
                ]
            )
        ]
    }

    // MARK: - 1. 空库 → 文档化默认值

    func testEmptyStoreLoadsAllDocumentedDefaultsWithoutThrowing() throws {
        let repository = makeRepository()

        XCTAssertNoThrow(try repository.loadCourses())
        XCTAssertNoThrow(try repository.loadSettings())
        XCTAssertNoThrow(try repository.loadProfiles())
        XCTAssertNoThrow(try repository.loadCredentials())
        XCTAssertNoThrow(try repository.loadUIFlags())

        // storage.md §2.3：`courses_json` 缺键 → 空列表（课程没有「空数组回落」分支）。
        XCTAssertEqual(try repository.loadCourses(), [])

        // storage.md §2.5：两个 UI 开关缺键 → false。
        XCTAssertEqual(
            try repository.loadUIFlags(),
            UIFlags(isDarkTheme: false, isOptimizeMode: false)
        )

        // storage.md §2.1 / §4.1：凭证缺键 → 空用户名、空密码、默认教务地址。
        let credentials = try repository.loadCredentials()
        XCTAssertEqual(credentials.username, "")
        XCTAssertEqual(credentials.password, "")
        XCTAssertEqual(credentials.jwxtUrl, "https://jwgl.xihang.com.cn")
        XCTAssertEqual(credentials.jwxtUrl, UserCredentials.defaultJwxtUrl)
        // 原版 `getUserCredentials()` 把 id 硬编码成 1（storage.md §4.1 / §7.5）。
        XCTAssertEqual(credentials.id, 1)
    }

    func testEmptyStoreSettingsMatchDocumentedDefaults() throws {
        let settings = try makeRepository().loadSettings()

        // storage.md §2.2 第 2–27 行的出厂值，逐字段核对。
        // `autoCheckUpdate` 不在这里断言：原版读取字面量是 false、而 `AppSettings()`
        // 的构造默认是 true，两者冲突（storage.md §9 U3）；那份争议单独放在
        // `testAuditFinding_emptyStoreAutoCheckUpdateFollowsAndroidReadDefault` 里。
        XCTAssertNil(settings.backgroundImageUri)
        XCTAssertEqual(settings.periodsPerDay, 12)
        XCTAssertEqual(settings.periodDurationMinutes, 45)
        XCTAssertEqual(settings.breakDurationMinutes, 10)
        XCTAssertEqual(settings.firstPeriodStartTime, "08:00")
        XCTAssertNil(settings.firstWeekStartDate)
        XCTAssertEqual(settings.semesterWeeks, 20)
        XCTAssertFalse(settings.showSaturday)
        XCTAssertFalse(settings.showSunday)
        XCTAssertFalse(settings.showNonCurrentWeekCourses)
        XCTAssertFalse(settings.showWeekSlider)
        XCTAssertFalse(settings.reverseMainText)
        XCTAssertFalse(settings.autoSyncTimetableFromJwxt)
        XCTAssertEqual(settings.selectedTimetableProfileId, "default")
        XCTAssertFalse(settings.classReminderEnabled)
        XCTAssertEqual(settings.classReminderMode, "weak")
        XCTAssertEqual(settings.classReminderMinutes, 10)
        XCTAssertEqual(settings.nonCurrentWeekCourseAlphaPercent, 45)
        XCTAssertEqual(settings.courseCardAlphaPercent, 100)
        XCTAssertEqual(settings.courseFrostedIntensityPercent, 100)
        XCTAssertEqual(settings.courseCellHeightDp, 69)
        XCTAssertEqual(settings.courseTextSizeSp, 10)
        XCTAssertTrue(settings.showCourseTime)
        XCTAssertTrue(settings.showCourseLocation)
        XCTAssertTrue(settings.showCourseTeacher)

        // `AppSettings.id` 不落盘；反编译里读取侧取值无法确证是 0 还是 1
        // （storage.md §9 U2），所以这里只断言「等于 AppSettings 的出厂值」。
        XCTAssertEqual(settings.id, AppSettings().id)
    }

    func testEmptyStoreReturnsDocumentedDefaultProfile() throws {
        let profiles = try makeRepository().loadProfiles()

        // storage.md §5.1：`timetable_profiles_json` 缺键 → 出厂内置默认档案。
        XCTAssertEqual(profiles.count, 1)
        let profile = try XCTUnwrap(profiles.first)
        XCTAssertEqual(profile.id, "default")
        XCTAssertEqual(profile.name, "默认")
        XCTAssertEqual(profile.periodsPerDay, 10)
        XCTAssertEqual(profile.periodTimes.count, 10)
        XCTAssertEqual(profile, StorageRoundTripTests.documentedDefaultProfile)
        // 同一份默认档案也内置在模型层；测试里重抄的副本与它必须逐字一致。
        XCTAssertEqual(TimetableProfile.defaultProfile, StorageRoundTripTests.documentedDefaultProfile)
        XCTAssertEqual(TimetableProfile.defaultId, "default")
    }

    // MARK: - 2. 完整往返

    func testCoursesRoundTripPreservesEveryField() throws {
        let courses = sampleCourses
        try makeRepository().saveCourses(courses)

        let loaded = try makeRepository().loadCourses()

        XCTAssertEqual(loaded.count, courses.count)
        XCTAssertEqual(loaded, courses)

        // 12 个字段逐个核对（storage.md §3.3 的读取列），别只靠 Equatable。
        let first = try XCTUnwrap(loaded.first)
        XCTAssertEqual(first.id, 7)
        XCTAssertEqual(first.name, "高等数学")
        XCTAssertEqual(first.teacher, "张老师")
        XCTAssertEqual(first.location, "教学楼A 101")
        XCTAssertEqual(first.dayOfWeek, 1)
        XCTAssertEqual(first.startPeriod, 1)
        XCTAssertEqual(first.endPeriod, 2)
        XCTAssertEqual(first.color, -11751600)
        XCTAssertEqual(first.weekRange, "1-16")
        XCTAssertEqual(first.startWeek, 1)
        XCTAssertEqual(first.endWeek, 16)
        XCTAssertEqual(first.isOdd, 0)

        // 边界值：双周用 isOdd = 2 表示（不是布尔），负色值、空周次串。
        let second = try XCTUnwrap(loaded.dropFirst().first)
        XCTAssertEqual(second.isOdd, 2)
        XCTAssertEqual(second.color, -26624)
        XCTAssertEqual(second.weekRange, "1-16(双)")
        XCTAssertEqual(second.dayOfWeek, 7)
    }

    func testSettingsRoundTripPreservesEveryPersistedField() throws {
        let settings = sampleSettings
        try makeRepository().saveSettings(settings)

        let loaded = try makeRepository().loadSettings()

        // `id` 不落盘（storage.md §2.2 第 1 行），读回时被换回出厂值。
        var expected = settings
        expected.id = AppSettings().id
        XCTAssertEqual(loaded, expected)
        XCTAssertNil(
            userDefaults.object(forKey: "id"),
            "AppSettings.id 不得写进偏好（storage.md §2.2 第 1 行）"
        )

        // 抽几个与出厂值不同的字段，确认读回的是落盘值而不是默认值。
        XCTAssertEqual(loaded.backgroundImageUri, "file:///tmp/bg.png")
        XCTAssertEqual(loaded.periodsPerDay, 11)
        XCTAssertEqual(loaded.periodDurationMinutes, 50)
        XCTAssertEqual(loaded.breakDurationMinutes, 5)
        XCTAssertEqual(loaded.firstPeriodStartTime, "07:50")
        XCTAssertEqual(loaded.firstWeekStartDate, "2026-03-02")
        XCTAssertEqual(loaded.semesterWeeks, 18)
        XCTAssertEqual(loaded.classReminderMode, "strong")
        XCTAssertEqual(loaded.classReminderMinutes, 15)
        XCTAssertEqual(loaded.courseCellHeightDp, 80)
        XCTAssertEqual(loaded.courseTextSizeSp, 12)
        XCTAssertEqual(loaded.selectedTimetableProfileId, "short-day")
        XCTAssertTrue(loaded.showSaturday)
        XCTAssertTrue(loaded.showSunday)
        XCTAssertTrue(loaded.showWeekSlider)
        XCTAssertTrue(loaded.autoSyncTimetableFromJwxt)
        XCTAssertFalse(loaded.autoCheckUpdate)
        XCTAssertFalse(loaded.showCourseTime)
        XCTAssertFalse(loaded.showCourseTeacher)
    }

    func testProfilesRoundTripPreservesEveryField() throws {
        let profiles = sampleProfiles
        try makeRepository().saveProfiles(profiles)

        let loaded = try makeRepository().loadProfiles()

        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].id, "short-day")
        XCTAssertEqual(loaded[0].name, "半日制")
        XCTAssertEqual(loaded[0].periodsPerDay, 2)
        // 写入时是乱序的，读取时必须按 index 升序重排（storage.md §5.2）。
        XCTAssertEqual(
            loaded[0].periodTimes,
            [
                PeriodTime(index: 1, start: "08:00", end: "08:40"),
                PeriodTime(index: 2, start: "09:00", end: "09:40")
            ]
        )
        XCTAssertEqual(loaded[1].id, "evening")
        XCTAssertEqual(loaded[1].name, "晚课")
        XCTAssertEqual(loaded[1].periodsPerDay, 1)
        XCTAssertEqual(
            loaded[1].periodTimes,
            [PeriodTime(index: 1, start: "19:00", end: "19:45")]
        )
    }

    func testUIFlagsRoundTrip() throws {
        try makeRepository().saveUIFlags(UIFlags(isDarkTheme: true, isOptimizeMode: true))
        XCTAssertEqual(
            try makeRepository().loadUIFlags(),
            UIFlags(isDarkTheme: true, isOptimizeMode: true)
        )

        try makeRepository().saveUIFlags(UIFlags(isDarkTheme: false, isOptimizeMode: true))
        XCTAssertEqual(
            try makeRepository().loadUIFlags(),
            UIFlags(isDarkTheme: false, isOptimizeMode: true)
        )
    }

    func testCredentialsRoundTripWritesOnlyUsernameAndUrlToPreferences() throws {
        let credentials = UserCredentials(
            id: 1,
            username: "2021001",
            password: "S3cret-P@ss",
            jwxtUrl: "https://jwgl.example.com"
        )
        try makeRepository().saveCredentials(credentials)

        let loaded = try makeRepository().loadCredentials()
        XCTAssertEqual(loaded.id, 1)
        XCTAssertEqual(loaded.username, "2021001")
        XCTAssertEqual(loaded.jwxtUrl, "https://jwgl.example.com")
        XCTAssertEqual(loaded.password, "S3cret-P@ss")

        // 非敏感字段进偏好（storage.md §2.1）。
        XCTAssertEqual(userDefaults.string(forKey: "username"), "2021001")
        XCTAssertEqual(userDefaults.string(forKey: "jwxtUrl"), "https://jwgl.example.com")
        // 密码走注入的凭证仓库。
        XCTAssertEqual(credentialStore.password, "S3cret-P@ss")
    }

    func testEmptyPasswordDeletesCredentialInsteadOfStoringBlank() throws {
        let repository = makeRepository()
        try repository.saveCredentials(
            UserCredentials(id: 1, username: "u", password: "S3cret-P@ss")
        )
        XCTAssertEqual(credentialStore.password, "S3cret-P@ss")

        try repository.saveCredentials(UserCredentials(id: 1, username: "u", password: ""))

        XCTAssertNil(credentialStore.password, "空密码必须删掉钥匙串条目，而不是写入空串")
        XCTAssertNil(userDefaults.object(forKey: "password"))
        XCTAssertEqual(try repository.loadCredentials().password, "")
    }

    // MARK: - 3. 缺键 / 空串 → 默认值，不崩

    func testEmptyStringJSONContainersBehaveLikeMissingKeys() throws {
        // storage.md §2.3：这两个键的出厂值是空串，空串与缺键语义相同。
        userDefaults.set("", forKey: "courses_json")
        userDefaults.set("", forKey: "timetable_profiles_json")

        let repository = makeRepository()
        XCTAssertEqual(try repository.loadCourses(), [])
        XCTAssertEqual(try repository.loadProfiles(), [StorageRoundTripTests.documentedDefaultProfile])
    }

    func testEmptyProfilesArrayFallsBackToDefaultProfile() throws {
        // storage.md §5.1：解析出空数组也返回默认档案（原版 `LocalStorage.java:252-256`）。
        userDefaults.set("[]", forKey: "timetable_profiles_json")

        XCTAssertEqual(try makeRepository().loadProfiles(), [StorageRoundTripTests.documentedDefaultProfile])
    }

    func testEmptyCoursesArrayStaysEmpty() throws {
        // 课程没有「空数组回落」分支，空数组就是空数组（storage.md §3.4）。
        userDefaults.set("[]", forKey: "courses_json")

        XCTAssertEqual(try makeRepository().loadCourses(), [])
    }

    // MARK: - 4. 坏内容 → TimetableRepositoryError.decodingFailed

    func testCorruptCoursesJSONThrowsDecodingFailed() throws {
        userDefaults.set("{ 这不是 JSON", forKey: "courses_json")

        XCTAssertThrowsError(try makeRepository().loadCourses()) { error in
            guard case let TimetableRepositoryError.decodingFailed(key, reason) = error else {
                return XCTFail("期望 decodingFailed，实际是 \(error)")
            }
            XCTAssertEqual(key, "courses_json")
            XCTAssertFalse(reason.isEmpty, "reason 应带上底层解码错误描述")
        }
    }

    func testNonArrayCoursesJSONThrowsDecodingFailed() throws {
        // 顶层是对象而不是数组：原版按 JSONArray 解析，iOS 侧同样算坏内容。
        userDefaults.set("{\"courses\": []}", forKey: "courses_json")

        XCTAssertThrowsError(try makeRepository().loadCourses()) { error in
            guard case let TimetableRepositoryError.decodingFailed(key, _) = error else {
                return XCTFail("期望 decodingFailed，实际是 \(error)")
            }
            XCTAssertEqual(key, "courses_json")
        }
    }

    func testCorruptProfilesJSONThrowsDecodingFailed() throws {
        userDefaults.set("[{]", forKey: "timetable_profiles_json")

        XCTAssertThrowsError(try makeRepository().loadProfiles()) { error in
            guard case let TimetableRepositoryError.decodingFailed(key, reason) = error else {
                return XCTFail("期望 decodingFailed，实际是 \(error)")
            }
            XCTAssertEqual(key, "timetable_profiles_json")
            XCTAssertFalse(reason.isEmpty)
        }
    }

    func testNonArrayProfilesJSONThrowsDecodingFailed() throws {
        userDefaults.set("{}", forKey: "timetable_profiles_json")

        XCTAssertThrowsError(try makeRepository().loadProfiles()) { error in
            guard case let TimetableRepositoryError.decodingFailed(key, _) = error else {
                return XCTFail("期望 decodingFailed，实际是 \(error)")
            }
            XCTAssertEqual(key, "timetable_profiles_json")
        }
    }

    func testNonNumericSettingsIntegerThrowsDecodingFailed() throws {
        // 键存在、但既不是数字也不是可解析成整数的字符串 → decodingFailed
        // （UserDefaultsTimetableRepository.swift:623-634 的 intValue）。
        userDefaults.set("not-an-integer", forKey: "periodsPerDay")

        XCTAssertThrowsError(try makeRepository().loadSettings()) { error in
            guard case let TimetableRepositoryError.decodingFailed(key, _) = error else {
                return XCTFail("期望 decodingFailed，实际是 \(error)")
            }
            XCTAssertEqual(key, "periodsPerDay")
        }
    }

    // MARK: - 5. 密码绝不进 UserDefaults

    func testPasswordNeverAppearsInUserDefaultsSuite() throws {
        let secret = "S3cret-P@ss"
        try makeRepository().saveCredentials(
            UserCredentials(
                id: 1,
                username: "2021001",
                password: secret,
                jwxtUrl: "https://jwgl.example.com"
            )
        )

        // 1) 把整个 suite 的每个值翻一遍，不允许任何字符串值带上密码。
        for (key, value) in userDefaults.dictionaryRepresentation() {
            if let text = value as? String {
                XCTAssertFalse(
                    text.contains(secret),
                    "偏好键 \(key) 的值里出现了明文密码（安全要求 m03200 第七节）"
                )
            }
        }

        // 2) `password` 键必须「不存在或为空」——两种合规形态都接受。
        if let storedPassword = userDefaults.object(forKey: "password") {
            XCTAssertEqual(
                storedPassword as? String,
                "",
                "`password` 键存在时只能是空串，不得含明文"
            )
        }

        // 3) 密码确实落到了注入的凭证仓库里。
        XCTAssertEqual(credentialStore.password, secret)
        XCTAssertEqual(credentialStore.saveCount, 1)
        XCTAssertEqual(try makeRepository().loadCredentials().password, secret)
    }

    func testLegacyPlaintextPasswordIsMigratedAndDeleted() throws {
        // 模拟「从 Android 迁过来」的偏好：明文 `password` 键还在，钥匙串里没有。
        userDefaults.set("u", forKey: "username")
        userDefaults.set("plain-text-pass", forKey: "password")
        XCTAssertNil(credentialStore.password)

        let loaded = try makeRepository().loadCredentials()

        XCTAssertEqual(loaded.password, "plain-text-pass")
        // 迁移后明文键必须立刻消失（UserDefaultsTimetableRepository.swift:208-209）。
        XCTAssertNil(userDefaults.object(forKey: "password"))
        XCTAssertEqual(credentialStore.password, "plain-text-pass")
        // 下一次读取走钥匙串。
        XCTAssertEqual(try makeRepository().loadCredentials().password, "plain-text-pass")
    }

    // MARK: - 6. 旧键回退

    func testLegacyShowWeekendKeyFeedsSaturdayAndSundayFallbacks() throws {
        // storage.md §2.2 旧键表 / `LocalStorage.java:77`、`:79`：
        // `showSaturday`、`showSunday` 缺键时回退到旧键 `showWeekend`。
        userDefaults.set(true, forKey: "showWeekend")

        let settings = try makeRepository().loadSettings()
        XCTAssertTrue(settings.showSaturday)
        XCTAssertTrue(settings.showSunday)

        // 新键存在时优先于旧键。
        userDefaults.set(false, forKey: "showSaturday")
        let overridden = try makeRepository().loadSettings()
        XCTAssertFalse(overridden.showSaturday)
        XCTAssertTrue(overridden.showSunday, "showSunday 仍回退到 showWeekend")
    }

    // MARK: - 7. clearTimetableData()

    func testClearRemovesEveryManagedKeyAndRestoresDefaults() throws {
        let repository = makeRepository()
        try repository.saveCourses(sampleCourses)
        try repository.saveSettings(sampleSettings)
        try repository.saveProfiles(sampleProfiles)
        try repository.saveUIFlags(UIFlags(isDarkTheme: true, isOptimizeMode: true))
        try repository.saveCredentials(
            UserCredentials(
                id: 1,
                username: "2021001",
                password: "S3cret-P@ss",
                jwxtUrl: "https://jwgl.example.com"
            )
        )

        // 实现从不写这三个键，但前两个仍在 `clearTimetableData()` 的清单里
        // （storage.md §2.4/§2.5），这里手动写入以便验证「宣称要清」。
        userDefaults.set(true, forKey: "disclaimer_dont_show")
        userDefaults.set(true, forKey: "usage_guide_dont_show")
        userDefaults.set("[\"1_1000\"]", forKey: "reminder_alarm_ids")

        try repository.clearTimetableData()

        // 1) 宣称要清的键，一个不剩。
        for key in StorageRoundTripTests.managedKeys {
            XCTAssertNil(userDefaults.object(forKey: key), "清空后仍残留键 \(key)")
        }

        // 2) 之后的 load 回到出厂值，且不抛错。
        XCTAssertEqual(try repository.loadCourses(), [])
        XCTAssertEqual(try repository.loadProfiles(), [StorageRoundTripTests.documentedDefaultProfile])
        XCTAssertEqual(
            try repository.loadUIFlags(),
            UIFlags(isDarkTheme: false, isOptimizeMode: false)
        )
        let credentials = try repository.loadCredentials()
        XCTAssertEqual(credentials.username, "")
        XCTAssertEqual(credentials.jwxtUrl, UserCredentials.defaultJwxtUrl)
        XCTAssertEqual(credentials.password, "")

        // 3) 设置回到出厂值（autoCheckUpdate 的争议见审计用例）。
        let settings = try repository.loadSettings()
        XCTAssertEqual(settings.periodsPerDay, 12)
        XCTAssertEqual(settings.periodDurationMinutes, 45)
        XCTAssertEqual(settings.selectedTimetableProfileId, "default")
        XCTAssertNil(settings.backgroundImageUri)
        XCTAssertNil(settings.firstWeekStartDate)
        XCTAssertFalse(settings.showSaturday)
        XCTAssertFalse(settings.showSunday)
        // ⚠️ 三个「显示」开关的工厂默认值是 **true**
        // （`LocalStorage.java:89` 的 `getBoolean("showCourseTime", true)` / `"showCourseLocation"` /
        // `"showCourseTeacher"`），不是 false。
        XCTAssertTrue(settings.showCourseTeacher)

        // 4) 密码走凭证仓库删除，不留孤儿。
        XCTAssertNil(credentialStore.password)
        XCTAssertGreaterThanOrEqual(credentialStore.deleteCount, 1)
    }

    func testClearKeepsKeysThatAreNotTimetableData() throws {
        let repository = makeRepository()
        try repository.saveCourses(sampleCourses)

        // 探针：不属于课表数据的键。storage.md §1.3：原版 `clearAll()` 只清
        // `timetable_prefs`，`log_prefs` 里的 `log_enabled` 必须活下来；
        // iOS 用同一个 suite 承载 App 自己的偏好，更不能整域 `clear()`。
        userDefaults.set(true, forKey: "log_enabled")
        userDefaults.set("keep-me", forKey: "storage_round_trip_probe")

        try repository.clearTimetableData()

        XCTAssertTrue(userDefaults.bool(forKey: "log_enabled"))
        XCTAssertNotNil(userDefaults.object(forKey: "log_enabled"))
        XCTAssertEqual(userDefaults.string(forKey: "storage_round_trip_probe"), "keep-me")
        XCTAssertNil(userDefaults.object(forKey: "courses_json"))
    }

    // MARK: - 8. 落盘键名与 JSON 形状

    func testSaveWritesAndroidLiteralKeys() throws {
        let repository = makeRepository()
        try repository.saveCourses(sampleCourses)
        try repository.saveSettings(sampleSettings)
        try repository.saveProfiles(sampleProfiles)
        try repository.saveUIFlags(UIFlags(isDarkTheme: true, isOptimizeMode: false))
        try repository.saveCredentials(
            UserCredentials(
                id: 1,
                username: "u",
                password: "p",
                jwxtUrl: "https://jwgl.example.com"
            )
        )

        // `saveSettings` 不写的键：密码（走钥匙串，只由 `saveCredentials` 处理）、
        // `reminder_alarm_ids`（iOS 用 `UNUserNotificationCenter.pendingNotificationRequests`
        // 自省待处理请求，**有意不落盘**，见 `docs/recon/03-reminder-and-refresh.md:1215`），
        // 以及两个「不再提示」开关——它们有专用访问器
        // （`load/setDisclaimerDismissedPermanently`、`load/setUsageGuideDismissedPermanently`），
        // 但刻意不属于 `AppSettings`（storage.md §2.5），所以 `saveSettings` 不该碰它们。
        let neverWrittenByRepository: Set<String> = [
            "password",
            "reminder_alarm_ids",
            "disclaimer_dont_show",
            "usage_guide_dont_show"
        ]

        for key in StorageRoundTripTests.managedKeys where !neverWrittenByRepository.contains(key) {
            XCTAssertNotNil(userDefaults.object(forKey: key), "保存后缺少 Android 字面量键 \(key)")
        }
        for key in neverWrittenByRepository {
            XCTAssertNil(
                userDefaults.object(forKey: key),
                "\(key) 不应由仓储写入偏好（见 UserDefaultsTimetableRepository.swift 键清单）"
            )
        }
    }

    func testCoursesJSONIsArrayOfAndroidShapedObjects() throws {
        try makeRepository().saveCourses(sampleCourses)

        let text = try XCTUnwrap(
            userDefaults.string(forKey: "courses_json"),
            "courses_json 必须存成字符串"
        )
        XCTAssertTrue(text.hasPrefix("["), "顶层必须是 JSON 数组，不是对象包装（storage.md §3.1）")

        let json = try JSONSerialization.jsonObject(with: Data(text.utf8))
        let array = try XCTUnwrap(json as? [Any], "顶层解析结果必须是数组")
        XCTAssertEqual(array.count, sampleCourses.count)

        // storage.md §3.2：原版 JSON 对象的 12 个键，逐字一致。
        let expectedKeys: Set<String> = [
            "id", "name", "teacher", "location", "dayOfWeek", "startPeriod",
            "endPeriod", "color", "weekRange", "startWeek", "endWeek", "isOdd"
        ]

        for (index, element) in array.enumerated() {
            let object = try XCTUnwrap(element as? [String: Any], "元素 \(index) 必须是 JSON 对象")
            XCTAssertEqual(
                Set(object.keys),
                expectedKeys,
                "元素 \(index) 的键名必须与 Android 逐字一致（storage.md §3.2）"
            )
            XCTAssertNotNil(object["name"] as? String)
            XCTAssertNotNil(object["teacher"] as? String)
            XCTAssertNotNil(object["location"] as? String)
            XCTAssertNotNil(object["weekRange"] as? String)
            XCTAssertNotNil(object["id"] as? Int)
            XCTAssertNotNil(object["dayOfWeek"] as? Int)
            XCTAssertNotNil(object["startPeriod"] as? Int)
            XCTAssertNotNil(object["endPeriod"] as? Int)
            XCTAssertNotNil(object["color"] as? Int)
            XCTAssertNotNil(object["startWeek"] as? Int)
            XCTAssertNotNil(object["endWeek"] as? Int)
            XCTAssertNotNil(object["isOdd"] as? Int)
        }

        // 值也核对一条：双周是整数 2，不是布尔（storage.md §3.3 注）。
        let second = try XCTUnwrap(array[1] as? [String: Any])
        XCTAssertEqual(second["isOdd"] as? Int, 2)
        XCTAssertEqual(second["color"] as? Int, -26624)
        XCTAssertEqual(second["weekRange"] as? String, "1-16(双)")
        XCTAssertEqual(second["name"] as? String, "大学物理")
    }

    func testProfilesJSONIsArrayOfAndroidShapedObjects() throws {
        try makeRepository().saveProfiles(sampleProfiles)

        let text = try XCTUnwrap(userDefaults.string(forKey: "timetable_profiles_json"))
        let json = try JSONSerialization.jsonObject(with: Data(text.utf8))
        let array = try XCTUnwrap(json as? [Any], "顶层解析结果必须是数组")
        XCTAssertEqual(array.count, 2)

        // storage.md §5.2：档案对象的 4 个键。
        let first = try XCTUnwrap(array[0] as? [String: Any])
        XCTAssertEqual(Set(first.keys), ["id", "name", "periodsPerDay", "periodTimes"])
        XCTAssertEqual(first["id"] as? String, "short-day")
        XCTAssertEqual(first["name"] as? String, "半日制")
        XCTAssertEqual(first["periodsPerDay"] as? Int, 2)

        // 每个时段对象的 3 个键。
        let times = try XCTUnwrap(first["periodTimes"] as? [Any])
        XCTAssertEqual(times.count, 2)
        let expectedTimeKeys: Set<String> = ["index", "start", "end"]
        for element in times {
            let time = try XCTUnwrap(element as? [String: Any])
            XCTAssertEqual(Set(time.keys), expectedTimeKeys)
            XCTAssertNotNil(time["index"] as? Int)
            XCTAssertNotNil(time["start"] as? String)
            XCTAssertNotNil(time["end"] as? String)
        }

        // 写入侧保持数组原样顺序（重排只发生在读取时），所以第 0 条仍是 index 2。
        let firstTime = try XCTUnwrap(times[0] as? [String: Any])
        XCTAssertEqual(firstTime["index"] as? Int, 2)
        XCTAssertEqual(firstTime["start"] as? String, "09:00")
        XCTAssertEqual(firstTime["end"] as? String, "09:40")
    }

    // MARK: - 9. 审计用例（按证据文档断言，非按实现断言）

    /// ⚠️ **审计发现**：本用例对当前实现**预期失败**。
    ///
    /// 证据：`docs/recon/storage.md:117`（§2.2 第 14 行）与 `storage.md:720`（§9 U3）——
    /// 原版读取处是 `getBoolean("autoCheckUpdate", false)`（`LocalStorage.java:83`），
    /// 文档结论是「iOS 侧『首次启动未写入时』应取 **false**（以反编译的读取字面量为准），
    /// 否则行为与 Android 不一致」。
    ///
    /// 实现：`UserDefaultsTimetableRepository.swift:339-340` 用的是
    /// `fallback: defaults.autoCheckUpdate`，而 `:303` 的 `defaults` 是
    /// `AppSettings.default`，它在 `Models/AppSettings.swift:112` 定义为
    /// `AppSettings()`，其 `autoCheckUpdate` 构造默认是 **true**
    /// （`Models/AppSettings.swift:67` 的 `autoCheckUpdate: Bool = true`）。
    /// 更矛盾的是 `UserDefaultsTimetableRepository.swift:336-338` 的注释自称
    /// 「取 false —— 即 `AppSettings()` 的出厂值」，可 `AppSettings()` 的出厂值并不是 false。
    ///
    /// 本用例按证据文档断言，因此应当失败；修实现（不是改断言）之后它会转绿。
    func testAuditFinding_emptyStoreAutoCheckUpdateFollowsAndroidReadDefault() throws {
        let settings = try makeRepository().loadSettings()

        let message = "storage.md:117 / :720（§9 U3）：原版读取默认是 false，"
            + "iOS 首次启动未写入时应取 false；实测取到了 true"
            + "（UserDefaultsTimetableRepository.swift:339-340 回落到 "
            + "AppSettings.default.autoCheckUpdate，而 AppSettings.swift:67 把它默认成 true）。"
            + "同文件 :336-338 的注释却自称取 false。"

        XCTAssertFalse(settings.autoCheckUpdate, message)
    }
}
