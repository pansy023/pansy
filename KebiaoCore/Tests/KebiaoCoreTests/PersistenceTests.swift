import XCTest
@testable import KebiaoCore

/// 内存版凭证仓库：给存储层测试用，不碰任何钥匙串。
///
/// 为什么要它：本机（以及任何 CI）可能没有系统钥匙串，而
/// `UserDefaultsTimetableRepository` 的默认依赖是 `KeychainCredentialStore`。
/// 注入这一份就能把「密码不进 UserDefaults」这条策略完整测出来，
/// 同时断言「密码确实交到了 CredentialStore 手里」。
private final class InMemoryCredentialStore: CredentialStore {

    /// 当前保存的密码。`nil` = 没存过。
    private(set) var password: String?

    /// 被调用了几次，便于断言 `clearTimetableData()` 真的删了密码。
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

/// 该抛错就抛错的内存版凭证仓库：模拟钥匙串不可用（非 Apple 平台分支、
/// 或 `errSecInteractionNotAllowed`）。
private final class ThrowingCredentialStore: CredentialStore {

    struct Boom: Error {}

    func loadPassword() throws -> String? { throw Boom() }
    func savePassword(_ password: String) throws { throw Boom() }
    func deletePassword() throws { throw Boom() }
}

/// 持久化层测试：键名契约、JSON 往返、重启后仍在、密码不进 UserDefaults。
///
/// 覆盖对象是 `UserDefaultsTimetableRepository`（`TimetableRepository` 的 iOS 主实现）。
/// 全部测试用 `UserDefaults(suiteName:)` 建独立 suite，**不碰** `.standard`，
/// 以免污染开发机上的真实偏好；`tearDown` 里整域删除。
///
/// 键名的权威来源：`docs/recon/storage.md`（Android 端 `LocalStorage.java` 的逐项清单）
/// 与 `Sources/KebiaoCore/Storage/UserDefaultsTimetableRepository.swift` 的
/// `TimetableStorageKeys`。这里直接引用 `TimetableStorageKeys`
/// （靠 `@testable import` 拿到 internal 成员），而不是在测试里再抄一遍字面量 ——
/// 抄一遍只能证明「测试和实现写的一样」，引用才能证明「实现用的是这个键」。
@MainActor
final class PersistenceTests: XCTestCase {

    // MARK: - 夹具

    /// 本次测试独占的 suite 名。`UserDefaults(suiteName:)` 传的是
    /// 「domain 名」而不是文件名，用 UUID 保证并发跑测试也互不干扰。
    private var suiteName: String = ""

    /// 当前用例的临时偏好域。**绝不**是 `.standard`。
    private var userDefaults: UserDefaults!

    private var credentialStore: InMemoryCredentialStore!

    override func setUp() {
        super.setUp()
        suiteName = "PersistenceTests-" + UUID().uuidString
        // `UserDefaults(suiteName:)` 在合法 suite 名上不会返回 nil，这里仍防一手，
        // 但**不**回落到 `.standard`：宁可让用例崩掉，也不能去改开发机的真实偏好。
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("无法创建临时 UserDefaults suite：\(suiteName)")
        }
        userDefaults = defaults
        credentialStore = InMemoryCredentialStore()
    }

    override func tearDown() {
        // 整域删除，避免临时 suite 的 plist 留在磁盘上。
        if !suiteName.isEmpty {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        suiteName = ""
        userDefaults = nil
        credentialStore = nil
        super.tearDown()
    }

    /// 新建一个 repository 实例（= 模拟 App 重启）。
    ///
    /// ⚠️ 关键点：**复用同一个 suite**，只换实例。若实现把数据攒在内存里没写盘，
    /// 新实例就读不到。
    private func makeRepository() -> UserDefaultsTimetableRepository {
        UserDefaultsTimetableRepository(
            userDefaults: userDefaults,
            credentialStore: credentialStore
        )
    }

    private func makeStore(_ repository: UserDefaultsTimetableRepository) -> TimetableStore {
        TimetableStore(repository: repository)
    }

    /// 覆盖全部 4 个子系统的样本课程。
    private var sampleCourses: [Course] {
        [
            Course(
                id: 1,
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
                id: 2,
                name: "大学英语",
                teacher: "李老师",
                location: "外语楼 203",
                dayOfWeek: 3,
                startPeriod: 5,
                endPeriod: 6,
                color: 0,
                weekRange: "1-16(单)",
                startWeek: 1,
                endWeek: 16,
                isOdd: 1
            )
        ]
    }

    private var sampleSettings: AppSettings {
        AppSettings(
            backgroundImageUri: "file:///tmp/bg.png",
            periodsPerDay: 10,
            periodDurationMinutes: 50,
            breakDurationMinutes: 5,
            firstPeriodStartTime: "07:50",
            firstWeekStartDate: "2026-03-02",
            semesterWeeks: 18,
            showSaturday: true,
            showSunday: true,
            showNonCurrentWeekCourses: true,
            showWeekSlider: true,
            reverseMainText: true,
            autoCheckUpdate: false,
            autoSyncTimetableFromJwxt: true,
            selectedTimetableProfileId: "default",
            classReminderEnabled: true,
            classReminderMode: "strong",
            classReminderMinutes: 15,
            nonCurrentWeekCourseAlphaPercent: 30,
            courseCardAlphaPercent: 80,
            courseFrostedIntensityPercent: 60,
            courseCellHeightDp: 80,
            courseTextSizeSp: 12,
            showCourseTime: false,
            showCourseLocation: false,
            showCourseTeacher: true
        )
    }

    /// 一套非默认作息的方案：**节次故意乱序**，用来验证读取时会按 index 重排
    /// （`LocalStorage.java:236-242`）。
    private var shortProfile: TimetableProfile {
        TimetableProfile(
            id: "short-day",
            name: "半日制",
            periodsPerDay: 2,
            periodTimes: [
                PeriodTime(index: 2, start: "09:00", end: "09:40"),
                PeriodTime(index: 1, start: "08:00", end: "08:40")
            ]
        )
    }

    // MARK: - 1. 存取往返

    func testCoursesRoundTrip() throws {
        let repository = makeRepository()
        try repository.saveCourses(sampleCourses)
        XCTAssertEqual(try repository.loadCourses(), sampleCourses)
    }

    func testSettingsRoundTrip() throws {
        let repository = makeRepository()
        let settings = sampleSettings
        try repository.saveSettings(settings)
        // `id` 不参与 JSON（原版 `LocalStorage.java:64` 无 id），
        // 实现统一取出厂默认 1；样本里保持默认值，等式才成立。
        XCTAssertEqual(try repository.loadSettings(), settings)
    }

    func testProfilesRoundTrip() throws {
        let repository = makeRepository()
        try repository.saveProfiles([shortProfile, .defaultProfile])
        let loaded = try repository.loadProfiles()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].id, "short-day")
        XCTAssertEqual(loaded[0].name, "半日制")
        XCTAssertEqual(loaded[0].periodsPerDay, 2)
        // 乱序写进去，读出来按 index 升序。
        XCTAssertEqual(loaded[0].periodTimes, [
            PeriodTime(index: 1, start: "08:00", end: "08:40"),
            PeriodTime(index: 2, start: "09:00", end: "09:40")
        ])
        XCTAssertEqual(loaded[1], .defaultProfile)
    }

    func testUIFlagsRoundTrip() throws {
        let repository = makeRepository()
        let flags = UIFlags(isDarkTheme: true, isOptimizeMode: true)
        try repository.saveUIFlags(flags)
        XCTAssertEqual(try repository.loadUIFlags(), flags)
    }

    func testCredentialsRoundTrip() throws {
        let repository = makeRepository()
        let credentials = UserCredentials(
            id: 1,
            username: "2021001",
            password: "s3cret",
            jwxtUrl: "https://jwgl.example.com"
        )
        try repository.saveCredentials(credentials)

        let loaded = try repository.loadCredentials()
        XCTAssertEqual(loaded.username, "2021001")
        XCTAssertEqual(loaded.jwxtUrl, "https://jwgl.example.com")
        XCTAssertEqual(loaded.password, "s3cret")
        // 密码经手了注入的 CredentialStore，而不是偏好。
        XCTAssertEqual(credentialStore.password, "s3cret")
    }

    // MARK: - 2. 模拟重启：换一个实例再读

    func testCoursesSurviveRestart() throws {
        try makeRepository().saveCourses(sampleCourses)

        // 新实例、同一个 suite。
        let reopened = makeRepository()
        XCTAssertEqual(try reopened.loadCourses(), sampleCourses)
        XCTAssertEqual(try reopened.loadCourses().count, 2)
    }

    func testSettingsSurviveRestart() throws {
        let settings = sampleSettings
        try makeRepository().saveSettings(settings)

        XCTAssertEqual(try makeRepository().loadSettings(), settings)
    }

    func testProfilesSurviveRestart() throws {
        try makeRepository().saveProfiles([shortProfile])

        let loaded = try makeRepository().loadProfiles()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].id, "short-day")
        XCTAssertEqual(loaded[0].periodTimes.count, 2)
    }

    func testUIFlagsSurviveRestart() throws {
        try makeRepository().saveUIFlags(UIFlags(isDarkTheme: true, isOptimizeMode: false))

        let loaded = try makeRepository().loadUIFlags()
        XCTAssertTrue(loaded.isDarkTheme)
        XCTAssertFalse(loaded.isOptimizeMode)
    }

    func testCredentialsSurviveRestart() throws {
        try makeRepository().saveCredentials(
            UserCredentials(id: 1, username: "u", password: "s3cret"))

        let loaded = try makeRepository().loadCredentials()
        XCTAssertEqual(loaded.username, "u")
        XCTAssertEqual(loaded.password, "s3cret")
    }

    /// 落盘必须是**立刻**的：`saveCourses` 返回后，真实 UserDefaults 里就有值，
    /// 不依赖任何 flush / 析构 / 延迟写。
    func testSaveWritesImmediately() throws {
        XCTAssertNil(userDefaults.object(forKey: TimetableStorageKeys.coursesJson))

        try makeRepository().saveCourses(sampleCourses)

        XCTAssertNotNil(userDefaults.object(forKey: TimetableStorageKeys.coursesJson))
    }

    // MARK: - 3. 键名契约与 JSON 形状

    func testStoredKeysMatchAndroidContract() throws {
        let repository = makeRepository()
        try repository.saveCourses(sampleCourses)
        try repository.saveSettings(sampleSettings)
        try repository.saveProfiles([shortProfile])
        try repository.saveUIFlags(UIFlags(isDarkTheme: true, isOptimizeMode: true))
        try repository.saveCredentials(
            UserCredentials(id: 1, username: "2021001", password: "s3cret", jwxtUrl: "https://jwgl.example.com"))

        let present = Set(userDefaults.dictionaryRepresentation().keys)

        // 两个 JSON 容器：单个键里放整张表（storage.md §2.3 / §3.1）。
        XCTAssertTrue(present.contains("courses_json"), "缺 courses_json")
        XCTAssertTrue(present.contains("timetable_profiles_json"), "缺 timetable_profiles_json")

        // 凭证：username / jwxtUrl 在偏好里（storage.md §2.1）；
        // `password` 键必须**不存在**（m03200 第七节）。
        XCTAssertTrue(present.contains("username"))
        XCTAssertTrue(present.contains("jwxtUrl"))
        XCTAssertFalse(
            present.contains("password"),
            "明文 password 键绝不能出现在 UserDefaults 里（规格 m03200 第七节）"
        )

        // AppSettings 的 26 个键（storage.md §2.2），键名逐个对得上。
        for key in TimetableStorageKeys.settings {
            XCTAssertTrue(present.contains(key), "缺设置键 \(key)")
        }

        // UI 开关（ThemeMode.java:28 / OptimizeMode.java:28）。
        XCTAssertTrue(present.contains("ui_dark_mode"))
        XCTAssertTrue(present.contains("ui_optimize_mode"))
    }

    func testJSONContainersAreJSONStrings() throws {
        let repository = makeRepository()
        try repository.saveCourses(sampleCourses)
        try repository.saveProfiles([shortProfile])

        // 存的是「JSON 数组字符串」，不是数组/字典对象，也不是 Data。
        let coursesText = try XCTUnwrap(
            userDefaults.string(forKey: TimetableStorageKeys.coursesJson))
        XCTAssertTrue(coursesText.hasPrefix("["))
        let coursesArray = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(coursesText.utf8)) as? [[String: Any]])
        XCTAssertEqual(coursesArray.count, 2)
        XCTAssertEqual(coursesArray[0]["name"] as? String, "高等数学")

        let profilesText = try XCTUnwrap(
            userDefaults.string(forKey: TimetableStorageKeys.profilesJson))
        XCTAssertTrue(profilesText.hasPrefix("["))
        let profilesArray = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(profilesText.utf8)) as? [[String: Any]])
        XCTAssertEqual(profilesArray.count, 1)
        XCTAssertEqual(profilesArray[0]["id"] as? String, "short-day")
    }

    func testMissingKeysYieldFactoryDefaults() throws {
        // 一个全新的 suite：什么都没存过。
        let repository = makeRepository()

        XCTAssertEqual(try repository.loadCourses(), [])
        // ⚠️ 不能整体比较 `.default`：`autoCheckUpdate` 缺键时要取 **false**
        // （`LocalStorage.java:83` 的读取字面量，storage.md §9 U3），而
        // `AppSettings.default.autoCheckUpdate` 是 true（Kotlin data class 构造默认）。
        var factorySettings = AppSettings.default
        factorySettings.autoCheckUpdate = false
        XCTAssertEqual(try repository.loadSettings(), factorySettings)
        XCTAssertEqual(try repository.loadProfiles(), [.defaultProfile])
        XCTAssertEqual(try repository.loadUIFlags(), .default)
        XCTAssertEqual(try repository.loadCredentials().username, "")
        XCTAssertEqual(
            try repository.loadCredentials().jwxtUrl, UserCredentials.defaultJwxtUrl)
        XCTAssertEqual(try repository.loadCredentials().password, "")
    }

    // MARK: - 4. 坏 JSON → decodingFailed

    func testCorruptCoursesJSONThrowsDecodingFailed() throws {
        userDefaults.set("{ 这不是 JSON 数组", forKey: TimetableStorageKeys.coursesJson)

        XCTAssertThrowsError(try makeRepository().loadCourses()) { error in
            guard case let TimetableRepositoryError.decodingFailed(key, reason) = error else {
                return XCTFail("期望 decodingFailed，实际是 \(error)")
            }
            XCTAssertEqual(key, "courses_json")
            XCTAssertFalse(reason.isEmpty)
        }
    }

    func testTypeMismatchCoursesJSONThrowsDecodingFailed() throws {
        // 合法 JSON，但顶层是对象而不是数组。
        userDefaults.set("{\"courses\": []}", forKey: TimetableStorageKeys.coursesJson)

        XCTAssertThrowsError(try makeRepository().loadCourses()) { error in
            guard case let TimetableRepositoryError.decodingFailed(key, _) = error else {
                return XCTFail("期望 decodingFailed，实际是 \(error)")
            }
            XCTAssertEqual(key, "courses_json")
        }
    }

    func testCorruptProfilesJSONThrowsDecodingFailed() throws {
        userDefaults.set("[]] 坏了", forKey: TimetableStorageKeys.profilesJson)

        XCTAssertThrowsError(try makeRepository().loadProfiles()) { error in
            guard case let TimetableRepositoryError.decodingFailed(key, _) = error else {
                return XCTFail("期望 decodingFailed，实际是 \(error)")
            }
            XCTAssertEqual(key, "timetable_profiles_json")
        }
    }

    /// 界面上不该因为坏数据就崩：`TimetableStore` 兜底成出厂值 + 记一条 `lastError`。
    func testStoreFallsBackOnCorruptData() {
        userDefaults.set("{ 坏", forKey: TimetableStorageKeys.coursesJson)

        let store = makeStore(makeRepository())

        XCTAssertEqual(store.courses, [])
        XCTAssertNotNil(store.lastError)
        XCTAssertTrue(store.lastError?.contains("课程") ?? false)
    }

    // MARK: - 5. 清空只清课表键

    func testClearRemovesTimetableKeysButKeepsOthers() throws {
        let repository = makeRepository()
        try repository.saveCourses(sampleCourses)
        try repository.saveSettings(sampleSettings)
        try repository.saveProfiles([shortProfile])
        try repository.saveUIFlags(UIFlags(isDarkTheme: true, isOptimizeMode: true))
        try repository.saveCredentials(
            UserCredentials(id: 1, username: "2021001", password: "s3cret"))

        // 探针：不属于课表数据的键（对应 Android 的 `log_prefs` / App 自己的偏好）。
        userDefaults.set("unrelated-value", forKey: "unrelated")
        XCTAssertEqual(credentialStore.password, "s3cret")

        try repository.clearTimetableData()

        let present = Set(userDefaults.dictionaryRepresentation().keys)
        for key in TimetableStorageKeys.clearedKeys {
            XCTAssertFalse(present.contains(key), "清空后不应残留 \(key)")
        }
        // 无关键必须还在 —— 这正是「不能整域 clear()」的理由。
        XCTAssertEqual(userDefaults.string(forKey: "unrelated"), "unrelated-value")
        // 密码走钥匙串删除，不留孤儿。
        XCTAssertNil(credentialStore.password)
        XCTAssertEqual(credentialStore.deleteCount, 1)
        // 清空后读出来是出厂值，不抛错。
        XCTAssertEqual(try repository.loadCourses(), [])
        // ⚠️ 不能整体比较 `.default`：`autoCheckUpdate` 缺键时要取 **false**
        // （`LocalStorage.java:83` 的读取字面量，storage.md §9 U3），而
        // `AppSettings.default.autoCheckUpdate` 是 true（Kotlin data class 构造默认）。
        var factorySettings = AppSettings.default
        factorySettings.autoCheckUpdate = false
        XCTAssertEqual(try repository.loadSettings(), factorySettings)
        XCTAssertEqual(try repository.loadProfiles(), [.defaultProfile])
    }

    // MARK: - 6. 密码绝不进 UserDefaults

    func testPasswordNeverAppearsInUserDefaults() throws {
        let secret = "s3cret"
        try makeRepository().saveCredentials(
            UserCredentials(id: 1, username: "u", password: secret))

        // 偏好里的每一个值都翻一遍：不允许任何字符串含密码。
        let dictionary = userDefaults.dictionaryRepresentation()
        for (key, value) in dictionary {
            if let text = value as? String {
                XCTAssertFalse(
                    text.contains(secret),
                    "键 \(key) 的值里出现了明文密码（规格 m03200 第七节禁止）"
                )
            }
        }

        // 强断言：password 键压根不存在。
        XCTAssertNil(userDefaults.object(forKey: "password"))
        XCTAssertNil(userDefaults.string(forKey: "password"))
        XCTAssertNil(userDefaults.string(forKey: TimetableStorageKeys.password))

        // 密码确实被交到了 CredentialStore（默认实现 = 钥匙串）。
        XCTAssertEqual(credentialStore.password, secret)
        XCTAssertEqual(credentialStore.saveCount, 1)
        // 重建实例后从 CredentialStore 取回。
        XCTAssertEqual(try makeRepository().loadCredentials().password, secret)
    }

    /// 空密码 = 清除密码，不能把空串也塞进钥匙串。
    func testEmptyPasswordDeletesCredential() throws {
        let repository = makeRepository()
        try repository.saveCredentials(UserCredentials(id: 1, username: "u", password: "s3cret"))
        XCTAssertEqual(credentialStore.password, "s3cret")

        try repository.saveCredentials(UserCredentials(id: 1, username: "u", password: ""))

        XCTAssertNil(credentialStore.password)
        XCTAssertEqual(try repository.loadCredentials().password, "")
        XCTAssertEqual(try repository.loadCredentials().username, "u")
    }

    // MARK: - 7. 端到端：TimetableStore + 真实 UserDefaults

    func testStoreInsertCourseSurvivesRestart() throws {
        let course = sampleCourses[0]

        // 第一次进 App：插入一门课。
        let firstRepository = makeRepository()
        let firstStore = makeStore(firstRepository)
        let inserted = firstStore.insertCourse(course)
        XCTAssertEqual(inserted.id, 1)
        XCTAssertEqual(firstStore.courses.count, 1)

        // 「重启」：同一个 suite，全新的 repository + store。
        let secondRepository = makeRepository()
        let secondStore = makeStore(secondRepository)

        XCTAssertEqual(secondStore.courses.count, 1)
        XCTAssertEqual(secondStore.courses[0].name, "高等数学")
        XCTAssertEqual(secondStore.courses[0].location, "教学楼A 101")
        XCTAssertEqual(secondStore.courses[0], inserted)
    }

    func testStoreSettingsAndFlagsSurviveRestart() throws {
        let firstStore = makeStore(makeRepository())
        firstStore.mutateSettings { $0.semesterWeeks = 18 }
        firstStore.updateUIFlags(UIFlags(isDarkTheme: true, isOptimizeMode: true))

        let secondStore = makeStore(makeRepository())

        XCTAssertEqual(secondStore.settings.semesterWeeks, 18)
        XCTAssertTrue(secondStore.uiFlags.isDarkTheme)
        XCTAssertTrue(secondStore.uiFlags.isOptimizeMode)
    }

    // MARK: - 边界：钥匙串不可用时向上抛

    /// 凭证写入失败必须抛 `writeFailed`（而不是静默吞掉），
    /// 这样 `TimetableStore.saveCredentials` 能把它记进 `lastError`。
    func testCredentialStoreFailurePropagatesAsWriteFailed() {
        let repository = UserDefaultsTimetableRepository(
            userDefaults: userDefaults,
            credentialStore: ThrowingCredentialStore()
        )

        XCTAssertThrowsError(
            try repository.saveCredentials(UserCredentials(id: 1, username: "u", password: "s3cret"))
        ) { error in
            guard case TimetableRepositoryError.writeFailed = error else {
                return XCTFail("期望 writeFailed，实际是 \(error)")
            }
        }
    }

    func testCredentialStoreFailureOnLoadFallsBackInStore() {
        let repository = UserDefaultsTimetableRepository(
            userDefaults: userDefaults,
            credentialStore: ThrowingCredentialStore()
        )

        let store = makeStore(repository)

        // 读凭证失败 → 出厂默认 + lastError，界面照常起得来。
        XCTAssertEqual(store.credentials.username, "")
        XCTAssertEqual(store.credentials.password, "")
        XCTAssertNotNil(store.lastError)
    }

    /// 钥匙串删不掉时 `clearTimetableData()` 抛错，但偏好里的课表键仍然被清掉了
    /// （先删偏好、后删密码：宁可留一条孤儿密码，也不能让「清空课表」假成功）。
    func testClearThrowsWhenPasswordCannotBeDeleted() {
        let repository = UserDefaultsTimetableRepository(
            userDefaults: userDefaults,
            credentialStore: ThrowingCredentialStore()
        )
        userDefaults.set("unrelated-value", forKey: "unrelated")

        XCTAssertThrowsError(try repository.clearTimetableData())

        XCTAssertNil(userDefaults.object(forKey: TimetableStorageKeys.coursesJson))
        XCTAssertEqual(userDefaults.string(forKey: "unrelated"), "unrelated-value")
    }
}
