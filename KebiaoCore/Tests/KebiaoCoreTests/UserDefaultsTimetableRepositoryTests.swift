import XCTest

@testable import KebiaoCore

// MARK: - 测试替身：内存里的「密码保管处」

/// `CredentialStore` 的内存实现。
///
/// 存在的理由：钥匙串在非 Apple 平台不存在，而本工程的存储层逻辑必须在
/// Windows / CI 上也能被测。仓库的默认实现是 `KeychainCredentialStore`，
/// 只有生产路径才用它（`UserDefaultsTimetableRepository.init(userDefaults:credentialStore:)`）。
///
/// 与 `PersistenceTests.swift` 里的同名替身刻意取了不同名字：那个是 `private`（文件级），
/// 两个文件各自持有一份互不干扰的实现，改坏一个不会牵连另一个。
private final class RecordingCredentialVault: CredentialStore {

    /// 注入的失败，用来验证「钥匙串坏了要向上抛成 `writeFailed`」。
    struct InjectedFailure: Error, LocalizedError {
        var errorDescription: String? { "注入的钥匙串失败" }
    }

    /// 当前「钥匙串」里的密码。`nil` = 没存过。
    var stored: String?

    private(set) var loadCallCount = 0
    private(set) var saveCallCount = 0
    private(set) var deleteCallCount = 0

    /// 非 nil 时所有方法都抛它 —— 模拟 `errSecMissingEntitlement` 之类的真实失败。
    var failure: Error?

    func loadPassword() throws -> String? {
        loadCallCount += 1
        if let failure { throw failure }
        return stored
    }

    func savePassword(_ password: String) throws {
        saveCallCount += 1
        if let failure { throw failure }
        stored = password
    }

    func deletePassword() throws {
        deleteCallCount += 1
        if let failure { throw failure }
        stored = nil
    }
}

// MARK: - 契约测试

/// `UserDefaultsTimetableRepository` 的键名 / 默认值 / JSON 形状契约测试。
///
/// 本文件的期望值**不取自 Swift 模型**，而是逐字抄自
/// `docs/recon/storage.md` §2–§5 与 `LocalStorage.java` 的行号。
/// 这一点很重要：如果实现改成「拿 `AppSettings()` 当缺键兜底」，
/// 期望值跟着实现一起漂移的测试是抓不到的；本文件抓得到。
///
/// 所有测试都在一个**独立的** `UserDefaults` suite 上跑（`setUpWithError` 里
/// 用随机名创建，`tearDownWithError` 里 `removePersistentDomain`），
/// 因此绝不会碰到 App 的真实偏好，也不会碰 macOS 钥匙串
/// （密码一律走注入的 `RecordingCredentialVault`）。
///
/// ## 与同目录另两个套件的关系（重要，务必先读）
///
/// 同一份实现在 `Tests/KebiaoCoreTests/` 下有**三个**套件：`PersistenceTests.swift`、
/// `StorageRoundTripTests.swift` 与本文件，覆盖面大量重叠（并发写入的产物，
/// 不是本文件作者的选择；保留哪一份应由仓库主人决定）。
///
/// 更严重的是，三者对「`autoCheckUpdate` 缺键默认值」的期望**互相矛盾**：
/// - `PersistenceTests.swift:361` 断言 `loadSettings() == .default`，而
///   `AppSettings.default.autoCheckUpdate == true`；
/// - 本文件与 `StorageRoundTripTests.swift:874` 断言 false
///   （依据 `LocalStorage.java:83` 的读取字面量与 storage.md §9 U3 的明确指示）。
///
/// 这两组断言不可能同时成立：当前实现（`Storage/` 版）满足前者、让后两者变红。
/// 定案依据应当是 storage.md §9 U3（取 false），随后删掉重复的套件。
final class UserDefaultsTimetableRepositoryTests: XCTestCase {

    // MARK: - 夹具

    private var suiteName = ""
    private var defaults: UserDefaults!
    private var vault: RecordingCredentialVault!
    private var repository: UserDefaultsTimetableRepository!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // 随机 suite 名：并发跑的测试之间也不会互相看见对方的数据。
        suiteName = "KebiaoCoreTests.UserDefaultsTimetableRepository." + UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName), "无法创建独立的 UserDefaults suite")
        vault = RecordingCredentialVault()
        repository = UserDefaultsTimetableRepository(userDefaults: defaults, credentialStore: vault)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        repository = nil
        vault = nil
        defaults = nil
        try super.tearDownWithError()
    }

    /// 换一个仓库实例、但共用同一套偏好与同一个「钥匙串」——
    /// 等价于「App 重启后重新读盘」，用来验证数据真的落盘了而不只是留在实例内存里。
    private func makeRepositoryAfterRestart() -> UserDefaultsTimetableRepository {
        UserDefaultsTimetableRepository(userDefaults: defaults, credentialStore: vault)
    }

    // MARK: - 探针

    private func assertDecodingFailed(
        key: String,
        _ body: () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard let repositoryError = error as? TimetableRepositoryError else {
                return XCTFail("期望 TimetableRepositoryError，实际是 \(error)", file: file, line: line)
            }
            guard case let .decodingFailed(failedKey, reason) = repositoryError else {
                return XCTFail("期望 decodingFailed，实际是 \(repositoryError)", file: file, line: line)
            }
            XCTAssertEqual(failedKey, key, "报出的键名必须是 storage.md 里的字面量", file: file, line: line)
            XCTAssertFalse(reason.isEmpty, "reason 不能为空，否则排障时看不到原因", file: file, line: line)
        }
    }

    private func assertWriteFailed(
        key: String,
        _ body: () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard let repositoryError = error as? TimetableRepositoryError else {
                return XCTFail("期望 TimetableRepositoryError，实际是 \(error)", file: file, line: line)
            }
            guard case let .writeFailed(failedKey, reason) = repositoryError else {
                return XCTFail("期望 writeFailed，实际是 \(repositoryError)", file: file, line: line)
            }
            XCTAssertEqual(failedKey, key, file: file, line: line)
            XCTAssertFalse(reason.isEmpty, file: file, line: line)
        }
    }

    /// 一份「每个字段都不是默认值」的课程，用来验证 12 个字段一个都没丢。
    /// `isOdd` 取 2（偶数周）而不是 0/1，`color` 取负数，两者都是易错点：
    /// `isOdd` 是 Int 不是 Bool（storage.md §3.3 第 12 项），
    /// `color` 是带符号 ARGB（默认 -11751600 = 0xFF4C8DF0）。
    private func makeCourse(
        id: Int = 7,
        name: String = "高等数学",
        isOdd: Int = 2
    ) -> Course {
        Course(
            id: id,
            name: name,
            teacher: "张老师",
            location: "教三 301",
            dayOfWeek: 3,
            startPeriod: 2,
            endPeriod: 4,
            color: -16_777_216,
            weekRange: "1-16",
            startWeek: 1,
            endWeek: 16,
            isOdd: isOdd
        )
    }

    /// 一份「每个字段都不是默认值」的设置，用来验证 26 个键一个都没丢。
    /// `id` 故意设成 42：它**不持久化**（storage.md §2.2 第 1 项 / §7.5），
    /// 读回来必须是模型默认值，不能是 42。
    private func makeNonDefaultSettings() -> AppSettings {
        AppSettings(
            id: 42,
            backgroundImageUri: "file:///var/mobile/bg.png",
            periodsPerDay: 8,
            periodDurationMinutes: 50,
            breakDurationMinutes: 15,
            firstPeriodStartTime: "07:40",
            firstWeekStartDate: "2025-02-24",
            semesterWeeks: 18,
            showSaturday: true,
            showSunday: true,
            showNonCurrentWeekCourses: true,
            showWeekSlider: true,
            reverseMainText: true,
            autoCheckUpdate: false,
            autoSyncTimetableFromJwxt: true,
            selectedTimetableProfileId: "profile_b",
            classReminderEnabled: true,
            classReminderMode: "strong",
            classReminderMinutes: 20,
            nonCurrentWeekCourseAlphaPercent: 60,
            courseCardAlphaPercent: 90,
            courseFrostedIntensityPercent: 80,
            courseCellHeightDp: 72,
            courseTextSizeSp: 12,
            showCourseTime: false,
            showCourseLocation: false,
            showCourseTeacher: false
        )
    }

    // MARK: - 1. 空库 → 文档化的默认值

    func testEmptyStoreYieldsEmptyCourses() throws {
        // storage.md §2.3：`courses_json` 缺键 → 空列表（LocalStorage.java:118-124）。
        XCTAssertEqual(try repository.loadCourses(), [])
    }

    func testEmptyStoreYieldsDocumentedSettingsDefaults() throws {
        // 逐字段对照 storage.md §2.2（写 LocalStorage.java:62-65，读 :67-90）。
        // `autoCheckUpdate` 单独放在下面的测试里（它是唯一有已知冲突的一项），
        // `id` 不列在这里（§9 U2 说反序列化后的取值无法确定，只验证「不落盘」）。
        let settings = try repository.loadSettings()

        XCTAssertNil(settings.backgroundImageUri, "缺键应为 nil（§2.2 第 2 项 / :68）")
        XCTAssertEqual(settings.periodsPerDay, 12, "§2.2 第 3 项 / :69")
        XCTAssertEqual(settings.periodDurationMinutes, 45, "§2.2 第 4 项 / :70")
        XCTAssertEqual(settings.breakDurationMinutes, 10, "§2.2 第 5 项 / :71")
        XCTAssertEqual(settings.firstPeriodStartTime, "08:00", "§2.2 第 6 项 / :72-73")
        XCTAssertNil(settings.firstWeekStartDate, "缺键应为 nil（§2.2 第 7 项 / :74）")
        XCTAssertEqual(settings.semesterWeeks, 20, "§2.2 第 8 项 / :75")
        XCTAssertFalse(settings.showSaturday, "§2.2 第 9 项 / :77")
        XCTAssertFalse(settings.showSunday, "§2.2 第 10 项 / :79")
        XCTAssertFalse(settings.showNonCurrentWeekCourses, "§2.2 第 11 项 / :80")
        XCTAssertFalse(settings.showWeekSlider, "§2.2 第 12 项 / :81")
        XCTAssertFalse(settings.reverseMainText, "§2.2 第 13 项 / :82（1.11.5 功能已停用）")
        XCTAssertFalse(settings.autoSyncTimetableFromJwxt, "§2.2 第 15 项 / :84")
        XCTAssertEqual(settings.selectedTimetableProfileId, "default", "§2.2 第 16 项 / :85-86")
        XCTAssertFalse(settings.classReminderEnabled, "§2.2 第 17 项 / :87")
        XCTAssertEqual(settings.classReminderMode, "weak", "§2.2 第 18 项 / :88-89")
        XCTAssertEqual(settings.classReminderMinutes, 10, "§2.2 第 19 项 / :89")
        XCTAssertEqual(settings.nonCurrentWeekCourseAlphaPercent, 45, "§2.2 第 20 项 / :89")
        XCTAssertEqual(settings.courseCardAlphaPercent, 100, "§2.2 第 21 项 / :89")
        XCTAssertEqual(settings.courseFrostedIntensityPercent, 100, "§2.2 第 22 项 / :89")
        XCTAssertEqual(settings.courseCellHeightDp, 69, "§2.2 第 23 项 / :89")
        XCTAssertEqual(settings.courseTextSizeSp, 10, "§2.2 第 24 项 / :89")
        XCTAssertTrue(settings.showCourseTime, "§2.2 第 25 项 / :89")
        XCTAssertTrue(settings.showCourseLocation, "§2.2 第 26 项 / :89")
        XCTAssertTrue(settings.showCourseTeacher, "§2.2 第 27 项 / :89")
    }

    /// ⚠️ 已知与当前实现的冲突，本断言在 macOS 上会**失败**。
    ///
    /// 期望值来自反编译出来的读取字面量：
    /// `getBoolean("autoCheckUpdate", false)`（`LocalStorage.java:83`，storage.md §2.2 第 14 项），
    /// 且 storage.md §9 U3 明确要求「iOS 首次启动未写入时应取 false」。
    ///
    /// 本用例最初是**故意红着**写的：当时 `Storage/UserDefaultsTimetableRepository.swift`
    /// 用 `fallback: defaults.autoCheckUpdate` 兜底，而 `AppSettings.default` 是
    /// `AppSettings()`，其 Kotlin 侧构造默认 `autoCheckUpdate = true`（`AppSettings.kt:34`），
    /// 于是缺键时实际取到 **true**，与 Android 的读取字面量相反。
    ///
    /// 该缺陷已修：实现改成 `fallback: false`。`AppSettings.default.autoCheckUpdate`
    /// 仍保持 true —— 那是**构造默认值**，与「盘上没有这个键时的读取值」不是一回事。
    /// 现在本用例是绿的回归守卫：谁把兜底改回 `defaults.autoCheckUpdate`，它立刻变红。
    func testAutoCheckUpdateFallsBackToDocumentedReadLiteral() throws {
        let settings = try repository.loadSettings()
        XCTAssertFalse(
            settings.autoCheckUpdate,
            "storage.md §2.2 第 14 项 / §9 U3 要求缺键时取 false（LocalStorage.java:83）"
        )
    }

    func testEmptyStoreYieldsDocumentedDefaultProfile() throws {
        // storage.md §5.1/§5.3：`timetable_profiles_json` 缺键 → `defaultTimetableProfiles()`，
        // 该默认档案每次读取现算、从不写回（LocalStorage.java:263-279）。
        let profiles = try repository.loadProfiles()
        XCTAssertEqual(profiles.count, 1, "缺键只应产生 1 个默认档案")

        let profile = try XCTUnwrap(profiles.first)
        XCTAssertEqual(profile.id, "default", "§5.3 id")
        XCTAssertEqual(profile.name, "默认", "§5.3 name")
        XCTAssertEqual(profile.periodsPerDay, 10, "§5.3 periodsPerDay = 10")

        // 10 个节次的起止时间必须逐字一致（§5.3 逐字代码 :422-434）。
        let expectedSlots = [
            "08:10-08:55", "09:05-09:50", "10:20-11:05", "11:15-12:00", "14:10-14:55",
            "15:05-15:50", "16:20-17:05", "17:15-18:00", "19:30-20:15", "20:25-21:10",
        ]
        XCTAssertEqual(profile.periodTimes.count, 10, "默认档案应有 10 个节次")
        XCTAssertEqual(profile.periodTimes.map(\.slot), expectedSlots, "§5.3 的 10 组起止时间")
        XCTAssertEqual(profile.periodTimes.map(\.index), Array(1...10), "index 从 1 递增到 10")
    }

    func testEmptyStoreYieldsNonPersistedDefaultProfileInDefaults() throws {
        // 默认档案是「现算」的，不该被写回偏好（storage.md §5.3）。
        _ = try repository.loadProfiles()
        XCTAssertNil(
            defaults.object(forKey: "timetable_profiles_json"),
            "读默认档案不应产生落盘副作用（§5.3）"
        )
    }

    func testEmptyStoreYieldsDefaultUIFlags() throws {
        // storage.md §2.5：`ui_dark_mode` / `ui_optimize_mode` 缺键都是 false
        // （ThemeMode.java:28、OptimizeMode.java:28）。
        XCTAssertEqual(try repository.loadUIFlags(), .default)
        XCTAssertFalse(try repository.loadUIFlags().isDarkTheme)
        XCTAssertFalse(try repository.loadUIFlags().isOptimizeMode)
    }

    func testEmptyStoreYieldsEmptyCredentialsWithDefaultJwxtUrl() throws {
        // storage.md §2.1 / §4.1：username "" `LocalStorage.java:46`、
        // jwxtUrl 取常量 `UserCredentials.java:13`、密码没存过就是 ""、id 硬编码 1（:59）。
        let credentials = try repository.loadCredentials()
        XCTAssertEqual(credentials.username, "")
        XCTAssertEqual(credentials.password, "")
        XCTAssertEqual(credentials.jwxtUrl, "https://jwgl.xihang.com.cn")
        XCTAssertEqual(credentials.id, 1, "id 不持久化，读取处硬编码 1（LocalStorage.java:59）")
        XCTAssertNil(vault.stored, "空库里不该凭空造出密码")
    }

    func testEmptyStoreYieldsDefaultSettingsForProfileSelection() throws {
        // §5.4：`selectedTimetableProfileId` 是独立 String 键，默认 "default"，
        // 与档案 id 只是「恰好同名」，存储层不做存在性校验。
        let settings = try repository.loadSettings()
        XCTAssertEqual(settings.selectedTimetableProfileId, "default")
        XCTAssertNil(
            defaults.object(forKey: "selectedTimetableProfileId"),
            "读取不应把默认值写回偏好"
        )
    }

    // MARK: - 2. 往返：存进去、重启、读回来

    func testCoursesRoundTripAcrossRestart() throws {
        let courses = [makeCourse(), makeCourse(id: 9, name: "大学物理", isOdd: 1)]
        try repository.saveCourses(courses)

        let reloaded = try makeRepositoryAfterRestart().loadCourses()
        XCTAssertEqual(reloaded, courses, "12 个字段必须原样回来（storage.md §3.3）")
        XCTAssertEqual(reloaded.first?.isOdd, 2, "isOdd 是 Int，2 表示偶数周（§3.3 第 12 项）")
        XCTAssertEqual(reloaded.first?.color, -16_777_216, "color 是带符号 ARGB Int（§3.3 第 8 项）")
    }

    func testSettingsRoundTripAcrossRestart() throws {
        let settings = makeNonDefaultSettings()
        try repository.saveSettings(settings)

        var expected = settings
        // `id` 不持久化（§2.2 第 1 项 / §7.5），读回来只能是模型默认值 1。
        expected.id = 1

        let reloaded = try makeRepositoryAfterRestart().loadSettings()
        XCTAssertEqual(reloaded, expected, "26 个持久化字段必须原样回来（§2.2）")
        XCTAssertNotEqual(reloaded.id, settings.id, "id = 42 不该被持久化")
    }

    func testProfilesRoundTripAcrossRestart() throws {
        let profiles = [
            TimetableProfile(
                id: "profile_b",
                name: "下学期",
                periodsPerDay: 2,
                periodTimes: [
                    PeriodTime(index: 2, start: "09:00", end: "09:45"),
                    PeriodTime(index: 1, start: "08:00", end: "08:45"),
                ]
            ),
            TimetableProfile(id: "profile_c", name: "周末班", periodsPerDay: 0, periodTimes: []),
        ]
        try repository.saveProfiles(profiles)

        let reloaded = try makeRepositoryAfterRestart().loadProfiles()
        XCTAssertEqual(reloaded.count, 2)

        // JSON 里的顺序不被信任：读侧按 `PeriodTime.index` 升序重排（§5.2 末 / :416）。
        XCTAssertEqual(
            reloaded.first?.periodTimes.map(\.index),
            [1, 2],
            "读侧必须按 index 升序排序（LocalStorage.java:236-242）"
        )
        XCTAssertEqual(reloaded.first?.periodTimes.first?.start, "08:00")
        XCTAssertEqual(reloaded.first?.id, "profile_b")
        XCTAssertEqual(reloaded.first?.name, "下学期")
        XCTAssertEqual(reloaded.last?.id, "profile_c")
        XCTAssertEqual(reloaded.last?.periodTimes.count, 0, "空 periodTimes 原样往返")
    }

    func testUIFlagsRoundTripAcrossRestart() throws {
        try repository.saveUIFlags(UIFlags(isDarkTheme: true, isOptimizeMode: true))
        XCTAssertEqual(
            try makeRepositoryAfterRestart().loadUIFlags(),
            UIFlags(isDarkTheme: true, isOptimizeMode: true)
        )
        XCTAssertEqual(defaults.bool(forKey: "ui_dark_mode"), true)
        XCTAssertEqual(defaults.bool(forKey: "ui_optimize_mode"), true)
    }

    func testCredentialsRoundTripAcrossRestart() throws {
        try repository.saveCredentials(
            UserCredentials(id: 99, username: "2021001", password: "pw-123456", jwxtUrl: "https://jw.example.edu.cn")
        )

        let reloaded = try makeRepositoryAfterRestart().loadCredentials()
        XCTAssertEqual(reloaded.username, "2021001")
        XCTAssertEqual(reloaded.password, "pw-123456", "密码经注入的 CredentialStore 往返")
        XCTAssertEqual(reloaded.jwxtUrl, "https://jw.example.edu.cn")
        XCTAssertEqual(reloaded.id, 1, "id 不持久化，读取处硬编码 1（LocalStorage.java:59）")

        // 落盘位置：用户名 / 教务地址在偏好里，密码只在「钥匙串」里。
        XCTAssertEqual(defaults.string(forKey: "username"), "2021001")
        XCTAssertEqual(defaults.string(forKey: "jwxtUrl"), "https://jw.example.edu.cn")
        XCTAssertEqual(vault.stored, "pw-123456")
    }

    // MARK: - 3. 键名契约与 JSON 形状

    func testAllDocumentedKeysAreWrittenWithVerbatimNames() throws {
        var settings = makeNonDefaultSettings()
        // 两个可空字段都给值，这样 26 个设置键会全部落盘（nil 会被 removeObject 掉）。
        settings.backgroundImageUri = "file:///bg.png"
        settings.firstWeekStartDate = "2025-02-24"

        try repository.saveSettings(settings)
        try repository.saveCourses([makeCourse()])
        try repository.saveProfiles([.defaultProfile])
        try repository.saveCredentials(UserCredentials(username: "u", password: "p"))
        try repository.saveUIFlags(UIFlags(isDarkTheme: true, isOptimizeMode: true))

        // §2.2 的 26 个设置键：键名 = Kotlin 属性名，一个字都不能改。
        let settingsKeys = [
            "backgroundImageUri", "periodsPerDay", "periodDurationMinutes", "breakDurationMinutes",
            "firstPeriodStartTime", "firstWeekStartDate", "semesterWeeks", "showSaturday", "showSunday",
            "showNonCurrentWeekCourses", "showWeekSlider", "reverseMainText", "autoCheckUpdate",
            "autoSyncTimetableFromJwxt", "selectedTimetableProfileId", "classReminderEnabled",
            "classReminderMode", "classReminderMinutes", "nonCurrentWeekCourseAlphaPercent",
            "courseCardAlphaPercent", "courseFrostedIntensityPercent", "courseCellHeightDp",
            "courseTextSizeSp", "showCourseTime", "showCourseLocation", "showCourseTeacher",
        ]
        for key in settingsKeys {
            XCTAssertNotNil(defaults.object(forKey: key), "缺键：\(key)（storage.md §2.2）")
        }

        // §2.1 / §2.3 / §2.5 的其余键。
        XCTAssertEqual(defaults.string(forKey: "username"), "u")
        XCTAssertEqual(
            defaults.string(forKey: "jwxtUrl"),
            "https://jwgl.xihang.com.cn",
            "§2.1 jwxtUrl 默认常量（UserCredentials.java:13）"
        )
        XCTAssertNotNil(defaults.string(forKey: "courses_json"))
        XCTAssertNotNil(defaults.string(forKey: "timetable_profiles_json"))
        XCTAssertNotNil(defaults.object(forKey: "ui_dark_mode"))
        XCTAssertNotNil(defaults.object(forKey: "ui_optimize_mode"))
    }

    func testKeyNamesThatAndroidDoesNotUseAreNeverWritten() throws {
        try repository.saveSettings(makeNonDefaultSettings())
        try repository.saveCourses([makeCourse()])
        try repository.saveProfiles([.defaultProfile])
        try repository.saveCredentials(UserCredentials(username: "u", password: "p"))
        try repository.saveUIFlags(UIFlags(isDarkTheme: true, isOptimizeMode: true))

        // 最容易被「顺手清理」出来的错误键名（驼峰版 / 单词版），都必须不存在。
        let wrongKeys = [
            "coursesJson", "profilesJson", "timetableProfilesJson", "courses", "profiles",
            "userName", "username ", "jwcUrl", "uiDarkMode", "darkMode", "optimizeMode",
            "reminderAlarmIds", "showWeekendCourses", "courseAlphaPercent",
        ]
        for key in wrongKeys {
            XCTAssertNil(defaults.object(forKey: key), "不该出现这个键名：\(key)")
        }

        // `id` 两边都不落盘：§2.2 第 1 项（AppSettings.id）、§4.1（UserCredentials.id）。
        XCTAssertNil(defaults.object(forKey: "id"), "id 不持久化（storage.md §7.5）")
    }

    func testShowWeekendLegacyKeyIsOnlyReadNeverWritten() throws {
        // §2.2 末尾 / LocalStorage.java:77、:79：
        // `getBoolean("showSaturday", getBoolean("showWeekend", false))`。
        defaults.set(true, forKey: "showWeekend")

        let settings = try repository.loadSettings()
        XCTAssertTrue(settings.showSaturday, "缺 showSaturday 时回退读 showWeekend")
        XCTAssertTrue(settings.showSunday, "缺 showSunday 时回退读 showWeekend")

        // 1.11.5 只读不写，所以 saveSettings 不得写出这个遗留键。
        try repository.saveSettings(settings)
        XCTAssertNil(defaults.object(forKey: "showWeekend"), "遗留键只读，不得写出（§2.2 末尾）")
        XCTAssertTrue(defaults.bool(forKey: "showSaturday"))
    }

    func testCoursesJSONIsAFlatArrayOfTwelveNamedFields() throws {
        try repository.saveCourses([makeCourse(id: 0, name: "线代", isOdd: 0)])

        let text = try XCTUnwrap(defaults.string(forKey: "courses_json"))
        let parsed = try JSONSerialization.jsonObject(with: Data(text.utf8))
        let array = try XCTUnwrap(parsed as? [[String: Any]], "顶层必须是 JSON 数组（§3.1）")
        XCTAssertEqual(array.count, 1)

        let element = try XCTUnwrap(array.first)
        let expectedKeys: Set<String> = [
            "id", "name", "teacher", "location", "dayOfWeek", "startPeriod", "endPeriod",
            "color", "weekRange", "startWeek", "endWeek", "isOdd",
        ]
        XCTAssertEqual(Set(element.keys), expectedKeys, "12 个字段名逐字对齐 §3.3")
        XCTAssertEqual(element["name"] as? String, "线代")
        XCTAssertEqual(element["weekRange"] as? String, "1-16")

        // `isOdd` 是数字不是布尔（§3.3 第 12 项 / §9 第 3 条）：
        // 序列化出来的原文里必须看到 `"isOdd":0` 这种形态。
        XCTAssertTrue(
            text.contains("\"isOdd\":0"),
            "isOdd 必须序列化成数字（storage.md §9 第 3 条），实际 JSON：\(text)"
        )

        // 三个默认值也要能在 JSON 里看到原样（§3.2 示例里的兜底值）。
        XCTAssertEqual(element["color"] as? Int, -16_777_216)
        XCTAssertEqual(element["startWeek"] as? Int, 1)
        XCTAssertEqual(element["endWeek"] as? Int, 16)
    }

    func testProfilesJSONShapeMatchesStorageDotMd() throws {
        try repository.saveProfiles([
            TimetableProfile(
                id: "profile_a",
                name: "课表1",
                periodsPerDay: 1,
                periodTimes: [PeriodTime(index: 1, start: "08:00", end: "08:45")]
            )
        ])

        let text = try XCTUnwrap(defaults.string(forKey: "timetable_profiles_json"))
        let parsed = try JSONSerialization.jsonObject(with: Data(text.utf8))
        let array = try XCTUnwrap(parsed as? [[String: Any]])
        let profile = try XCTUnwrap(array.first)

        XCTAssertEqual(
            Set(profile.keys),
            ["id", "name", "periodsPerDay", "periodTimes"],
            "档案字段名逐字对齐 §5.1/§5.2"
        )
        XCTAssertEqual(profile["id"] as? String, "profile_a")
        XCTAssertEqual(profile["name"] as? String, "课表1")
        XCTAssertEqual(profile["periodsPerDay"] as? Int, 1)

        let times = try XCTUnwrap(profile["periodTimes"] as? [[String: Any]])
        let time = try XCTUnwrap(times.first)
        XCTAssertEqual(
            Set(time.keys),
            ["index", "start", "end"],
            "节次字段名逐字对齐 §5.2（计算属性 id 不参与编码）"
        )
        XCTAssertEqual(time["index"] as? Int, 1)
        XCTAssertEqual(time["start"] as? String, "08:00")
        XCTAssertEqual(time["end"] as? String, "08:45")
    }

    func testExplicitEmptyCollectionsAreStoredAsEmptyJSONArrays() throws {
        // 「空串 = 不存在」是读取侧的约定；显式保存空集合时写的仍然是 `[]`
        // （原版 `putString("courses_json", "[]")`，storage.md §2.3 / §9 第 2 条）。
        try repository.saveCourses([])
        try repository.saveProfiles([])

        XCTAssertEqual(defaults.string(forKey: "courses_json"), "[]")
        XCTAssertEqual(defaults.string(forKey: "timetable_profiles_json"), "[]")

        // 读回来：课程是空列表，档案则回落到默认档案（§5.1：解出空数组也返回默认档案）。
        XCTAssertEqual(try repository.loadCourses(), [])
        XCTAssertEqual(try repository.loadProfiles(), [.defaultProfile])
    }

    func testBlankJSONContainersAreTreatedAsMissing() throws {
        // storage.md §9 第 2 条：三个 JSON 容器键的「不存在」与「空串」语义相同
        // （原版用 Kotlin `isBlank()`，LocalStorage.java:122）。
        defaults.set("", forKey: "courses_json")
        defaults.set("", forKey: "timetable_profiles_json")

        XCTAssertEqual(try repository.loadCourses(), [])
        XCTAssertEqual(try repository.loadProfiles(), [.defaultProfile])
    }

    func testParsedEmptyProfileArrayFallsBackToDefaultProfile() throws {
        // §5.1 :359：默认档案的条件是「空串 / 空数组」二者之一，不只是缺键。
        defaults.set("[]", forKey: "timetable_profiles_json")
        XCTAssertEqual(try repository.loadProfiles(), [.defaultProfile])
    }

    // MARK: - 4. 缺键逐项回落（部分写入的库）

    func testPartiallyWrittenStoreKeepsDefaultsForUntouchedKeys() throws {
        // 只写 3 个键，模拟「用户改过学期周数、其它键还是初始状态」。
        defaults.set(8, forKey: "periodsPerDay")
        defaults.set("09:30", forKey: "firstPeriodStartTime")
        defaults.set("profile_z", forKey: "selectedTimetableProfileId")

        let settings = try repository.loadSettings()
        XCTAssertEqual(settings.periodsPerDay, 8, "写过的键要用写入值")
        XCTAssertEqual(settings.firstPeriodStartTime, "09:30")
        XCTAssertEqual(settings.selectedTimetableProfileId, "profile_z")
        XCTAssertEqual(settings.periodDurationMinutes, 45, "没写过的键回落 §2.2 默认值")
        XCTAssertEqual(settings.semesterWeeks, 20, "没写过的键回落 §2.2 默认值")
        XCTAssertTrue(settings.showCourseTime, "没写过的键回落 §2.2 默认值")
        XCTAssertTrue(settings.showCourseTeacher, "没写过的键回落 §2.2 默认值")
        XCTAssertNil(settings.backgroundImageUri, "没写过的可空键回落 nil")
        XCTAssertNil(settings.firstWeekStartDate, "没写过的可空键回落 nil")
    }

    func testMissingKeysOnAFreshSuiteAreAllDefaults() throws {
        // 空 suite 里一个键都没有：每个 load 都必须给出文档化默认值且**不抛**
        // （协议文件要求：缺键不得抛错）。
        XCTAssertNoThrow(try repository.loadCourses())
        XCTAssertNoThrow(try repository.loadSettings())
        XCTAssertNoThrow(try repository.loadProfiles())
        XCTAssertNoThrow(try repository.loadCredentials())
        XCTAssertNoThrow(try repository.loadUIFlags())
    }

    // MARK: - 5. 坏数据 → decodingFailed（绝不 fatalError、绝不静默吞掉）

    func testCorruptCoursesJSONThrowsDecodingFailed() {
        defaults.set("{ this is not json", forKey: "courses_json")
        assertDecodingFailed(key: "courses_json") {
            _ = try self.repository.loadCourses()
        }
    }

    func testCoursesJSONWithWrongTopLevelTypeThrowsDecodingFailed() {
        // 顶层是对象而不是数组：原版 org.json 会走到 catch 分支返回 emptyList
        // （storage.md §3.4），iOS 侧按协议要求报 decodingFailed。
        defaults.set("{}", forKey: "courses_json")
        assertDecodingFailed(key: "courses_json") {
            _ = try self.repository.loadCourses()
        }
    }

    func testCoursesJSONWithWrongFieldTypeThrowsDecodingFailed() {
        // `dayOfWeek` 给字符串而非数字 → 类型不符。协议文件把「键存在但内容损坏」
        // 归为 decodingFailed，正是为了不让这种数据静默变成 dayOfWeek = 1。
        defaults.set(
            "[{\"id\":0,\"name\":\"\",\"teacher\":\"\",\"location\":\"\",\"dayOfWeek\":\"三\",\"startPeriod\":1,\"endPeriod\":1,\"color\":-11751600,\"weekRange\":\"1-20\",\"startWeek\":1,\"endWeek\":20,\"isOdd\":0}]",
            forKey: "courses_json"
        )
        assertDecodingFailed(key: "courses_json") {
            _ = try self.repository.loadCourses()
        }
    }

    func testCorruptProfilesJSONThrowsDecodingFailed() {
        defaults.set("{ broken", forKey: "timetable_profiles_json")
        assertDecodingFailed(key: "timetable_profiles_json") {
            _ = try self.repository.loadProfiles()
        }
    }

    func testProfilesJSONWithWrongFieldTypeThrowsDecodingFailed() {
        defaults.set("[{\"id\":\"a\",\"name\":\"甲\",\"periodsPerDay\":\"十\"}]", forKey: "timetable_profiles_json")
        assertDecodingFailed(key: "timetable_profiles_json") {
            _ = try self.repository.loadProfiles()
        }
    }

    // MARK: - 6. 密码绝不进 UserDefaults

    func testPasswordNeverAppearsInUserDefaults() throws {
        let secret = "S3cr3t-JWXT-口令-42"
        try repository.saveCredentials(UserCredentials(username: "2021001", password: secret))

        // 需求指定的检查方式：整个偏好字典里既不能有 password 键，
        // 也不能有任何值等于密码本体。
        let snapshot = defaults.dictionaryRepresentation()
        XCTAssertNil(snapshot["password"], "密码键不得写入偏好")
        assertNoValueEquals(secret, in: snapshot)

        // 明文也可以藏在 JSON 容器里 —— 一并扫一遍原始字符串。
        for (key, value) in snapshot {
            if let text = value as? String {
                XCTAssertFalse(text.contains(secret), "偏好键 \(key) 的值里出现了密码明文")
            }
        }

        // 反面确认：密码确实被保存了，只是保存在注入的凭证仓库（生产环境 = 钥匙串）。
        XCTAssertEqual(vault.stored, secret)
        XCTAssertEqual(vault.saveCallCount, 1)
    }

    func testEmptyPasswordDeletesTheStoredSecret() throws {
        try repository.saveCredentials(UserCredentials(username: "u", password: "先有密码"))
        XCTAssertEqual(vault.stored, "先有密码")

        // 空密码等价于「清除」：钥匙串条目被删掉，不留下孤儿密码。
        try repository.saveCredentials(UserCredentials(username: "u", password: ""))
        XCTAssertNil(vault.stored, "空密码必须删除凭证，而不是写入空串")
        XCTAssertEqual(vault.deleteCallCount, 1)
        XCTAssertEqual(try repository.loadCredentials().password, "")
    }

    func testLegacyPlaintextPasswordIsMigratedIntoTheSecretStore() throws {
        // Android 时代把明文密码写在 `password` 键里（storage.md §4.2，证据链 :315-343）。
        // iOS 首次读到这种遗留数据时必须「搬进钥匙串 + 删掉明文」，
        // 且顺序必须是先写成功再删（否则钥匙串写失败会连密码一起丢掉）。
        defaults.set("legacy-plaintext-pw", forKey: "password")
        XCTAssertNil(vault.stored)

        let credentials = try repository.loadCredentials()
        XCTAssertEqual(credentials.password, "legacy-plaintext-pw", "迁移后应当仍能读到密码")
        XCTAssertEqual(vault.stored, "legacy-plaintext-pw", "密码必须已经搬进凭证仓库")
        XCTAssertNil(defaults.object(forKey: "password"), "迁移完成后明文键必须被删除")
        assertNoValueEquals("legacy-plaintext-pw", in: defaults.dictionaryRepresentation())
    }

    func testSecretStoreFailureSurfacesAsWriteFailed() {
        vault.failure = RecordingCredentialVault.InjectedFailure()

        assertWriteFailed(key: "password") {
            try self.repository.saveCredentials(UserCredentials(username: "u", password: "pw"))
        }
        // 账号信息是普通偏好，仍然写得进去 —— 失败只针对密码那一项。
        XCTAssertEqual(defaults.string(forKey: "username"), "u")
        XCTAssertNil(defaults.object(forKey: "password"), "失败时更不能退回明文写入偏好")
    }

    func testSecretStoreFailureOnReadIsNotSilentlySwallowed() throws {
        // 只管「写」失败是不够的：读失败也必须是可观察的错误，
        // 否则 App 会以为用户从没设过密码（静默吞掉）。
        //
        // 这里刻意**不**限定错误的具体类型：`saveCredentials` 会把底层错误收进
        // `writeFailed(key:reason:)`，而读路径是把钥匙串错误原样上抛
        //（`Storage/UserDefaultsTimetableRepository.swift:665` 的
        // `try credentialStore.loadPassword()`），两者都不算「吞掉」。
        // 用 `TimetableStore` 兜底时的表现（回落默认值 + 记 `lastError`）另有其测试。
        vault.failure = RecordingCredentialVault.InjectedFailure()
        XCTAssertThrowsError(try repository.loadCredentials(), "钥匙串读失败不得被静默吞成空密码")
    }

    // MARK: - 7. clearTimetableData 只清课表数据

    func testClearRemovesTimetableKeysButKeepsUnrelatedOnes() throws {
        // 先把「全部 37 个受管键」都写上有值的数据。
        try repository.saveCourses([makeCourse()])
        try repository.saveProfiles([.defaultProfile])
        try repository.saveSettings(makeNonDefaultSettings())
        try repository.saveCredentials(UserCredentials(username: "u", password: "pw"))
        try repository.saveUIFlags(UIFlags(isDarkTheme: true, isOptimizeMode: true))
        defaults.set("[\"7_1000\"]", forKey: "reminder_alarm_ids")
        defaults.set(true, forKey: "disclaimer_dont_show")
        defaults.set(true, forKey: "usage_guide_dont_show")

        // 两个「不属于课表数据」的键：`log_prefs` 的 `log_enabled`
        //（在 Android 上是**另一个文件**，storage.md §1.2 / §9 第 4 条）
        // 和一个实现完全不认识的键。
        defaults.set(false, forKey: "log_enabled")
        defaults.set("keep-me", forKey: "unrelated")

        try repository.clearTimetableData()

        // 受管的 37 个键全清（storage.md §2.2 末尾 / LocalStorage.java:164-166）。
        let clearedKeys = [
            "username", "password", "jwxtUrl", "courses_json", "timetable_profiles_json",
            "reminder_alarm_ids", "disclaimer_dont_show", "usage_guide_dont_show",
            "ui_dark_mode", "ui_optimize_mode", "backgroundImageUri", "periodsPerDay",
            "periodDurationMinutes", "breakDurationMinutes", "firstPeriodStartTime",
            "firstWeekStartDate", "semesterWeeks", "showSaturday", "showSunday",
            "showNonCurrentWeekCourses", "showWeekSlider", "reverseMainText", "autoCheckUpdate",
            "autoSyncTimetableFromJwxt", "selectedTimetableProfileId", "classReminderEnabled",
            "classReminderMode", "classReminderMinutes", "nonCurrentWeekCourseAlphaPercent",
            "courseCardAlphaPercent", "courseFrostedIntensityPercent", "courseCellHeightDp",
            "courseTextSizeSp", "showCourseTime", "showCourseLocation", "showCourseTeacher",
        ]
        for key in clearedKeys {
            XCTAssertNil(defaults.object(forKey: key), "清空后不该残留：\(key)")
        }

        // `log_prefs` 的 `log_enabled` 与陌生键必须活着（§9 第 4 条）。
        XCTAssertEqual(defaults.object(forKey: "log_enabled") as? Bool, false, "log_enabled 不归清空管")
        XCTAssertEqual(defaults.string(forKey: "unrelated"), "keep-me", "陌生键不该被清空误伤")

        // 密码也一并从凭证仓库删除，不留孤儿。
        XCTAssertNil(vault.stored)
        XCTAssertEqual(vault.deleteCallCount, 1)
    }

    func testClearRestoresDocumentedDefaults() throws {
        defaults.set("{ broken", forKey: "courses_json")
        defaults.set("{ broken", forKey: "timetable_profiles_json")

        // 即使库里是坏数据，清空也必须成功（它不解析内容）。
        XCTAssertNoThrow(try repository.clearTimetableData())

        XCTAssertEqual(try repository.loadCourses(), [])
        XCTAssertEqual(try repository.loadProfiles(), [.defaultProfile])
        XCTAssertEqual(try repository.loadSettings().periodsPerDay, 12)
        XCTAssertEqual(try repository.loadUIFlags(), .default)
        XCTAssertEqual(try repository.loadCredentials().username, "")
        XCTAssertEqual(try repository.loadCredentials().jwxtUrl, "https://jwgl.xihang.com.cn")
    }

    // MARK: - 8. 与 TimetableStore 的接缝（真实偏好 + 真实仓库）

    @MainActor
    func testStoreRoundTripThroughRealRepository() throws {
        // 端到端一层：`TimetableStore` → 仓库 → 独立 suite → 换实例再读。
        // 这里只断言「数据真的过了 UserDefaults 这道关」，
        // 比 `TimetableStoreTests` 用 `InMemoryTimetableRepository` 的用例更接近生产路径。
        // `TimetableStore` 是 `@MainActor`（TimetableStore.swift:23），所以本方法也要标注。
        let store = TimetableStore(repository: repository)
        _ = store.insertCourse(makeCourse(id: 5, name: "数据结构"))

        let reopened = TimetableStore(repository: makeRepositoryAfterRestart())
        XCTAssertEqual(reopened.courses.count, 1)
        XCTAssertEqual(reopened.courses.first?.name, "数据结构")
        XCTAssertNotNil(defaults.string(forKey: "courses_json"), "课程必须真的落盘了")
    }

    // MARK: - 内部工具

    /// 断言偏好字典里没有任何值等于给定密文（既查字符串，也查字符串化后的其它类型）。
    private func assertNoValueEquals(
        _ secret: String,
        in snapshot: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for (key, value) in snapshot {
            if let text = value as? String {
                XCTAssertNotEqual(text, secret, "偏好键 \(key) 的值就是密码本体", file: file, line: line)
            } else if let array = value as? [Any] {
                for element in array where (element as? String) == secret {
                    XCTFail("偏好键 \(key) 的数组里藏着密码", file: file, line: line)
                }
            } else if let nested = value as? [String: Any] {
                for (nestedKey, nestedValue) in nested where (nestedValue as? String) == secret {
                    XCTFail("偏好键 \(key).\(nestedKey) 里藏着密码", file: file, line: line)
                }
            }
        }
    }
}
