import XCTest
@testable import KebiaoCore

/// 可注入失败的存储实现：不失败时全部转发给内存实现，便于断言「到底有没有落盘」。
private final class FailingRepository: TimetableRepository {

    /// 需要抛出错误的操作名（方法名）。
    var failing: Set<String> = []

    /// 真正落地的地方。
    let memory = InMemoryTimetableRepository()

    var saveCounts: [String: Int] { memory.saveCounts }

    private func checkLoad(_ name: String, key: String) throws {
        if failing.contains(name) {
            throw TimetableRepositoryError.decodingFailed(key: key, reason: "注入的读取失败")
        }
    }

    private func checkSave(_ name: String, key: String) throws {
        if failing.contains(name) {
            throw TimetableRepositoryError.writeFailed(key: key, reason: "注入的写入失败")
        }
    }

    func loadCourses() throws -> [Course] {
        try checkLoad("loadCourses", key: "courses")
        return try memory.loadCourses()
    }

    func saveCourses(_ courses: [Course]) throws {
        try checkSave("saveCourses", key: "courses")
        try memory.saveCourses(courses)
    }

    func loadSettings() throws -> AppSettings {
        try checkLoad("loadSettings", key: "settings")
        return try memory.loadSettings()
    }

    func saveSettings(_ settings: AppSettings) throws {
        try checkSave("saveSettings", key: "settings")
        try memory.saveSettings(settings)
    }

    func loadProfiles() throws -> [TimetableProfile] {
        try checkLoad("loadProfiles", key: "profiles")
        return try memory.loadProfiles()
    }

    func saveProfiles(_ profiles: [TimetableProfile]) throws {
        try checkSave("saveProfiles", key: "profiles")
        try memory.saveProfiles(profiles)
    }

    func loadCredentials() throws -> UserCredentials {
        try checkLoad("loadCredentials", key: "credentials")
        return try memory.loadCredentials()
    }

    func saveCredentials(_ credentials: UserCredentials) throws {
        try checkSave("saveCredentials", key: "credentials")
        try memory.saveCredentials(credentials)
    }

    func loadUIFlags() throws -> UIFlags {
        try checkLoad("loadUIFlags", key: "uiFlags")
        return try memory.loadUIFlags()
    }

    func saveUIFlags(_ flags: UIFlags) throws {
        try checkSave("saveUIFlags", key: "uiFlags")
        try memory.saveUIFlags(flags)
    }

    func loadDisclaimerDismissedPermanently() throws -> Bool {
        try checkLoad("loadDisclaimerDismissedPermanently", key: "disclaimer_dont_show")
        return memory.loadDisclaimerDismissedPermanently()
    }

    func setDisclaimerDismissedPermanently(_ dontShow: Bool) throws {
        try checkSave("setDisclaimerDismissedPermanently", key: "disclaimer_dont_show")
        memory.setDisclaimerDismissedPermanently(dontShow)
    }

    func loadUsageGuideDismissedPermanently() throws -> Bool {
        try checkLoad("loadUsageGuideDismissedPermanently", key: "usage_guide_dont_show")
        return memory.loadUsageGuideDismissedPermanently()
    }

    func setUsageGuideDismissedPermanently(_ dontShow: Bool) throws {
        try checkSave("setUsageGuideDismissedPermanently", key: "usage_guide_dont_show")
        memory.setUsageGuideDismissedPermanently(dontShow)
    }

    func clearTimetableData() throws {
        try checkSave("clearTimetableData", key: "timetable")
        try memory.clearTimetableData()
    }
}

/// 存储/状态层测试：状态迁移、落盘时机、以及与原版 `TimetableViewModel` 的逐字对齐点。
///
/// 时间与存储都注入，测试不依赖真实时钟、真实 UserDefaults。
/// 对齐依据：`上课早枝道-源码-1.11.5/app/src/main/java/kebiaocom/example/ui/TimetableViewModel.java`
/// 与 `TimetableViewModel$insertCourse$1.java`。
@MainActor
final class TimetableStoreTests: XCTestCase {

    // MARK: - 夹具

    /// 固定时区，避免测试结果随运行机器的本地时区变化。
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_CN")
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        return calendar.date(from: components)!
    }

    /// 2026-03-04 是周三，那一周的周一是 2026-03-02。
    private func makeStore(
        repository: TimetableRepository = InMemoryTimetableRepository(),
        now: Date? = nil
    ) -> TimetableStore {
        let now = now ?? date(2026, 3, 4)
        return TimetableStore(repository: repository, now: { now }, calendar: calendar)
    }

    private func course(
        name: String = "高等数学",
        dayOfWeek: Int = 1,
        startPeriod: Int = 1,
        endPeriod: Int = 2,
        startWeek: Int = 1,
        endWeek: Int = 20,
        isOdd: Int = 0,
        weekRange: String = ""
    ) -> Course {
        Course(
            name: name,
            teacher: "张老师",
            location: "教学楼A 101",
            dayOfWeek: dayOfWeek,
            startPeriod: startPeriod,
            endPeriod: endPeriod,
            color: 0,
            weekRange: weekRange,
            startWeek: startWeek,
            endWeek: endWeek,
            isOdd: isOdd
        )
    }

    private func profile(id: String, periods: Int) -> TimetableProfile {
        TimetableProfile(
            id: id,
            name: id,
            periodsPerDay: periods,
            periodTimes: (1...periods).map {
                PeriodTime(index: $0, start: "08:00", end: "08:45")
            }
        )
    }

    // MARK: - 初始化与回落

    func testInitFallsBackToFactoryDefaultsWhenRepositoryIsEmpty() {
        let store = makeStore()

        XCTAssertTrue(store.courses.isEmpty)
        XCTAssertEqual(store.settings, .default)
        XCTAssertEqual(store.profiles, [.defaultProfile])
        XCTAssertEqual(store.credentials.username, "")
        XCTAssertEqual(store.uiFlags, .default)
        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.weekOffset, 0)
    }

    func testInitRecordsLoadFailuresAndKeepsDefaults() {
        let repository = FailingRepository()
        repository.failing = ["loadCourses", "loadSettings"]
        let store = makeStore(repository: repository)

        XCTAssertTrue(store.courses.isEmpty)
        XCTAssertEqual(store.settings, .default)

        let lastError = store.lastError ?? ""
        XCTAssertTrue(lastError.contains("课程"), "lastError = \(lastError)")
        XCTAssertTrue(lastError.contains("设置"), "lastError = \(lastError)")
        XCTAssertTrue(lastError.contains("；"), "多个问题应以全角分号连接：\(lastError)")
    }

    func testInitFallsBackWhenRepositoryReturnsNoProfiles() {
        let store = makeStore(repository: InMemoryTimetableRepository(profiles: []))
        XCTAssertEqual(store.profiles, [.defaultProfile])
        XCTAssertEqual(store.activeProfile.id, TimetableProfile.defaultId)
    }

    func testClearLastError() {
        let repository = FailingRepository()
        repository.failing = ["loadCourses"]
        let store = makeStore(repository: repository)

        XCTAssertNotNil(store.lastError)
        store.clearLastError()
        XCTAssertNil(store.lastError)
    }

    // MARK: - 课程写操作

    func testInsertCourseAssignsIdFromCountPlusOne() {
        let store = makeStore()

        let first = store.insertCourse(course(name: "第一门"))
        let second = store.insertCourse(course(name: "第二门"))

        XCTAssertEqual(first.id, 1)
        XCTAssertEqual(second.id, 2)
        XCTAssertEqual(store.courses.map(\.id), [1, 2])
    }

    func testInsertCourseKeepsOriginalCountPlusOneQuirk() {
        // 逐字保留原版怪癖：`copy(id = size + 1)`（`TimetableViewModel$insertCourse$1.java:63`）。
        // 删掉一门之后再新增会撞 id —— 这里把该行为钉住，免得以后「顺手修好」导致
        // 与 Android 端的 id 语义分叉。
        let store = makeStore()
        let first = store.insertCourse(course(name: "第一门"))
        store.insertCourse(course(name: "第二门"))

        store.deleteCourse(first)
        let third = store.insertCourse(course(name: "第三门"))

        XCTAssertEqual(third.id, 2)
        XCTAssertEqual(store.courses.map(\.id), [2, 2])
    }

    func testInsertCoursePersistsImmediately() {
        let repository = InMemoryTimetableRepository()
        let store = makeStore(repository: repository)

        store.insertCourse(course())

        XCTAssertEqual(repository.saveCounts["courses"], 1)
        XCTAssertEqual(repository.courses.count, 1)
    }

    func testUpdateCourseReplacesById() {
        let repository = InMemoryTimetableRepository(courses: [course(name: "旧名")])
        let store = makeStore(repository: repository)

        var edited = store.courses[0]
        edited.name = "新名"
        store.updateCourse(edited)

        XCTAssertEqual(store.courses.count, 1)
        XCTAssertEqual(store.courses[0].name, "新名")
        XCTAssertEqual(repository.courses[0].name, "新名")
    }

    func testUpdateCourseWithUnknownIdDoesNothing() {
        let repository = InMemoryTimetableRepository(courses: [course(name: "旧名")])
        let store = makeStore(repository: repository)

        var ghost = course(name: "幽灵")
        ghost.id = 99
        store.updateCourse(ghost)

        XCTAssertEqual(store.courses.count, 1)
        XCTAssertEqual(store.courses[0].name, "旧名")
        XCTAssertNil(repository.saveCounts["courses"])
    }

    func testDeleteCourseRemovesAndPersists() {
        let repository = InMemoryTimetableRepository(courses: [course(name: "A")])
        let store = makeStore(repository: repository)

        store.deleteCourse(store.courses[0])

        XCTAssertTrue(store.courses.isEmpty)
        XCTAssertTrue(repository.courses.isEmpty)
        XCTAssertEqual(repository.saveCounts["courses"], 1)
    }

    func testDeleteCourseWithUnknownIdDoesNotPersist() {
        let repository = InMemoryTimetableRepository(courses: [course(name: "A")])
        let store = makeStore(repository: repository)

        var ghost = course(name: "A")
        ghost.id = 99
        store.deleteCourse(ghost)

        XCTAssertEqual(store.courses.count, 1)
        XCTAssertNil(repository.saveCounts["courses"])
    }

    func testDeleteAllCoursesClearsAndPersists() {
        let repository = InMemoryTimetableRepository(courses: [course(name: "A")])
        let store = makeStore(repository: repository)

        store.deleteAllCourses()
        XCTAssertTrue(store.courses.isEmpty)
        XCTAssertEqual(repository.saveCounts["courses"], 1)

        store.deleteAllCourses()
        XCTAssertEqual(repository.saveCounts["courses"], 1, "已经是空表就不应再写一次")
    }

    func testReplaceAllCoursesRenumbersIds() {
        let repository = InMemoryTimetableRepository()
        let store = makeStore(repository: repository)

        store.replaceAllCourses(with: [course(name: "A"), course(name: "B")])

        XCTAssertEqual(store.courses.map(\.id), [1, 2])
        XCTAssertEqual(repository.courses.map(\.id), [1, 2])
    }

    func testReplaceAllCoursesIgnoresEmptyInput() {
        // 教务导入失败时不能把已有课表清空。
        let repository = InMemoryTimetableRepository(courses: [course(name: "A")])
        let store = makeStore(repository: repository)

        store.replaceAllCourses(with: [])

        XCTAssertEqual(store.courses.count, 1)
        XCTAssertNil(repository.saveCounts["courses"])
    }

    // MARK: - 落盘失败

    func testPersistFailureSurfacesInLastError() {
        let repository = FailingRepository()
        let store = makeStore(repository: repository)
        repository.failing = ["saveCourses"]

        store.insertCourse(course())

        XCTAssertEqual(store.courses.count, 1, "内存状态照常更新")
        XCTAssertNotNil(store.lastError)
        XCTAssertTrue(repository.memory.courses.isEmpty, "失败时不应写进存储")
    }

    func testSuccessfulWriteClearsLastError() {
        let repository = FailingRepository()
        repository.failing = ["saveCourses"]
        let store = makeStore(repository: repository)

        store.insertCourse(course())
        XCTAssertNotNil(store.lastError)

        repository.failing = []
        store.insertCourse(course(name: "第二门"))
        XCTAssertNil(store.lastError)
    }

    // MARK: - 设置、开关、凭证

    func testUpdateSettingsPersists() {
        let repository = InMemoryTimetableRepository()
        let store = makeStore(repository: repository)

        store.mutateSettings { $0.semesterWeeks = 18 }

        XCTAssertEqual(store.settings.semesterWeeks, 18)
        XCTAssertEqual(repository.settings.semesterWeeks, 18)
        XCTAssertEqual(repository.saveCounts["settings"], 1)
    }

    func testUpdateUIFlagsPersists() {
        let repository = InMemoryTimetableRepository()
        let store = makeStore(repository: repository)

        store.updateUIFlags(UIFlags(isDarkTheme: true))

        XCTAssertTrue(store.uiFlags.isDarkTheme)
        XCTAssertFalse(store.uiFlags.isOptimizeMode)
        XCTAssertTrue(repository.uiFlags.isDarkTheme)
        XCTAssertEqual(repository.saveCounts["uiFlags"], 1)
    }

    func testSaveCredentialsPersists() {
        let repository = InMemoryTimetableRepository()
        let store = makeStore(repository: repository)

        store.saveCredentials(UserCredentials(username: "2021001", password: "s3cret"))

        XCTAssertEqual(store.credentials.username, "2021001")
        XCTAssertEqual(repository.credentials.username, "2021001")
        XCTAssertEqual(repository.saveCounts["credentials"], 1)
    }

    // MARK: - 作息方案与面板

    func testAddTimetableProfileSelectsItAndPersists() {
        let repository = InMemoryTimetableRepository()
        let store = makeStore(repository: repository)

        store.addTimetableProfile(
            name: "实验楼",
            periods: [PeriodTime(index: 1, start: "08:00", end: "08:45")]
        )

        XCTAssertEqual(store.profiles.count, 2)
        let added = store.profiles[1]
        XCTAssertEqual(added.name, "实验楼")
        XCTAssertEqual(added.periodsPerDay, 1)
        XCTAssertEqual(store.settings.selectedTimetableProfileId, added.id)
        XCTAssertEqual(store.activeProfile.id, added.id)
        XCTAssertEqual(store.timeSlots, ["08:00-08:45"])
        XCTAssertEqual(repository.saveCounts["profiles"], 1)
        XCTAssertEqual(repository.saveCounts["settings"], 1)
    }

    func testSelectTimetableProfileIgnoresUnknownId() {
        let store = makeStore()
        store.selectTimetableProfile(id: "nope")
        XCTAssertEqual(store.settings.selectedTimetableProfileId, TimetableProfile.defaultId)
    }

    func testTimeSlotsFollowSelectedProfile() {
        let short = profile(id: "short", periods: 3)
        var settings = AppSettings.default
        settings.selectedTimetableProfileId = "short"
        let store = makeStore(
            repository: InMemoryTimetableRepository(settings: settings, profiles: [.defaultProfile, short])
        )

        XCTAssertEqual(store.activeProfile.id, "short")
        XCTAssertEqual(store.timeSlots.count, 3)
        XCTAssertEqual(store.periodCount, 3)
        XCTAssertEqual(store.periodBlocks, [1...3])

        store.selectTimetableProfile(id: TimetableProfile.defaultId)

        XCTAssertEqual(store.timeSlots.count, 10)
        XCTAssertEqual(store.periodCount, 10)
        XCTAssertEqual(store.periodBlocks, [1...4, 5...8, 9...10])
    }

    func testPeriodBlocksSplitIntoMorningAfternoonEvening() {
        // `TimetableGridV2.kt:362-421`：上午 1-4、下午 5-8、晚上 9-rows。
        let cases: [(periods: Int, blocks: [ClosedRange<Int>])] = [
            (3, [1...3]),
            (4, [1...4]),
            (8, [1...4, 5...8]),
            (12, [1...4, 5...8, 9...12])
        ]

        for item in cases {
            let id = "p\(item.periods)"
            var settings = AppSettings.default
            settings.selectedTimetableProfileId = id
            let store = makeStore(
                repository: InMemoryTimetableRepository(
                    settings: settings,
                    profiles: [profile(id: id, periods: item.periods)]
                )
            )

            XCTAssertEqual(store.periodBlocks, item.blocks, "\(item.periods) 节时应分成 \(item.blocks)")
        }
    }

    func testPeriodCountFallsBackToOneWhenTimeSlotsAreEmpty() {
        // 方案里一节都没有、且 settings 也算不出（每天 0 节）时，行数兜到 1。
        let empty = TimetableProfile(id: "empty", name: "空", periodsPerDay: 0, periodTimes: [])
        var settings = AppSettings.default
        settings.selectedTimetableProfileId = "empty"
        settings.periodsPerDay = 0
        let store = makeStore(
            repository: InMemoryTimetableRepository(settings: settings, profiles: [empty])
        )

        XCTAssertTrue(store.timeSlots.isEmpty)
        XCTAssertEqual(store.periodCount, 1)
        XCTAssertEqual(store.periodBlocks, [1...1])
    }

    // MARK: - 周次

    func testCurrentWeekComesFromFirstWeekStartDate() {
        var settings = AppSettings.default
        settings.firstWeekStartDate = "2026-03-02"
        let store = makeStore(repository: InMemoryTimetableRepository(settings: settings))

        XCTAssertEqual(store.currentWeek, 1)
        XCTAssertEqual(store.displayedWeek, 1)
        XCTAssertEqual(store.weekNumberText, "第1周")
    }

    func testCurrentWeekFallsBackToOneWithoutFirstWeekStartDate() {
        let store = makeStore()
        XCTAssertNil(store.settings.firstWeekStartDate)
        XCTAssertEqual(store.currentWeek, 1)
    }

    func testWeekOffsetShiftsDisplayedWeekButNotBelowOne() {
        var settings = AppSettings.default
        settings.firstWeekStartDate = "2026-03-02"
        let store = makeStore(repository: InMemoryTimetableRepository(settings: settings))

        store.shiftWeek(by: 3)
        XCTAssertEqual(store.weekOffset, 3)
        XCTAssertEqual(store.displayedWeek, 4)
        XCTAssertEqual(store.weekNumberText, "第4周")

        store.shiftWeek(by: -10)
        XCTAssertEqual(store.weekOffset, -7)
        XCTAssertEqual(store.displayedWeek, 1, "下界兜到第 1 周")

        store.resetWeekOffset()
        XCTAssertEqual(store.weekOffset, 0)
        XCTAssertEqual(store.displayedWeek, 1)
    }

    /// 「显示非本周课程」开关的真实语义（原版 `TimetableScreenKt.java:4496-4505`）：
    /// 关着 → 不属于本学期的课**不出现**；开着 → 全部出现并给出 `occursThisWeek`
    /// 让视图降透明度。
    func testCoursesForDisplayedWeekFiltersUnlessShowNonCurrentWeekCoursesIsOn() {
        var settings = AppSettings.default
        settings.firstWeekStartDate = "2026-03-02"
        let repository = InMemoryTimetableRepository(
            courses: [
                course(name: "本学期课"),
                course(name: "后半学期课", startWeek: 5, endWeek: 8)
            ],
            settings: settings
        )
        let store = makeStore(repository: repository)

        // 默认关着：后半学期课在第 1 周被滤掉。
        XCTAssertEqual(store.settings.showNonCurrentWeekCourses, false)
        let week1 = store.coursesForDisplayedWeek()
        XCTAssertEqual(week1.count, 1)
        XCTAssertEqual(week1[0].course.name, "本学期课")
        XCTAssertTrue(week1[0].occursThisWeek)

        // 第 5 周：两门课都在本学期内，都返回。
        store.shiftWeek(by: 4)
        XCTAssertEqual(store.displayedWeek, 5)
        let week5 = store.coursesForDisplayedWeek()
        XCTAssertEqual(week5.count, 2)
        XCTAssertTrue(week5.allSatisfy { $0.occursThisWeek })

        // 第 13 周：后半学期课已结束，但开关打开后仍返回（只是 occursThisWeek = false）。
        store.mutateSettings { $0.showNonCurrentWeekCourses = true }
        store.shiftWeek(by: 8)
        XCTAssertEqual(store.displayedWeek, 13)
        let week13 = store.coursesForDisplayedWeek()
        XCTAssertEqual(week13.count, 2)
        XCTAssertTrue(week13[0].occursThisWeek)
        XCTAssertFalse(week13[1].occursThisWeek)
    }

    func testVisibleWeekdaysFollowShowSaturdayAndSunday() {
        let store = makeStore()
        XCTAssertEqual(store.settings.showSaturday, false)
        XCTAssertEqual(store.settings.showSunday, false)
        XCTAssertEqual(store.visibleWeekdays, [1, 2, 3, 4, 5])
        XCTAssertEqual(store.weekDates.count, 5)

        store.mutateSettings {
            $0.showSaturday = true
            $0.showSunday = true
        }
        XCTAssertEqual(store.visibleWeekdays, [1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(store.weekDates.count, 7)
    }

    func testTodayColumnIndexPointsAtTodayWhenVisible() {
        var settings = AppSettings.default
        settings.firstWeekStartDate = "2026-03-02"
        let store = makeStore(repository: InMemoryTimetableRepository(settings: settings))

        // 2026-03-04 是周三，显示列表是 [周一…周五]。
        XCTAssertEqual(store.todayColumnIndex, 2)
        XCTAssertEqual(store.weekDates[2].date, "3/4")

        store.shiftWeek(by: 1)
        XCTAssertNil(store.todayColumnIndex, "今天不在显示的那一周里")
    }

    // MARK: - 课程合并

    func testMergedCoursesMergesAdjacentPeriods() {
        let first = course(name: "高等数学", startPeriod: 1, endPeriod: 2)
        let second = course(name: "高等数学", startPeriod: 3, endPeriod: 4)
        let store = makeStore(repository: InMemoryTimetableRepository(courses: [first, second]))

        let merged = store.mergedCourses(dayOfWeek: 1, block: 1...4)

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.startPeriod, 1)
        XCTAssertEqual(merged.first?.endPeriod, 4)
        XCTAssertTrue(store.mergedCourses(dayOfWeek: 2, block: 1...4).isEmpty)
    }

    func testMergedCoursesKeepsWholeSpanAcrossPanels() {
        // 跨面板的课（1-6 节）：`coursesInBlock` 只按「是否与本面板相交」过滤 + 合并，
        // **不**裁剪节次；裁剪发生在画卡片时（`TimetableLayout.cardVerticalGeometry`
        // 的 `coerceIn`，见 `TimetableLayoutTests.testCardGeometryClampsCrossPanelCourseIntoEachPanel`）。
        // 这里把这条分工钉住，免得以后把裁剪挪进过滤层导致两端行为分叉。
        let spanning = course(name: "连堂课", startPeriod: 1, endPeriod: 6)
        let store = makeStore(repository: InMemoryTimetableRepository(courses: [spanning]))

        for block in [1...4, 5...8] {
            let merged = store.mergedCourses(dayOfWeek: 1, block: block)
            XCTAssertEqual(merged.count, 1, "面板 \(block) 应命中这门课")
            XCTAssertEqual(merged.first?.startPeriod, 1)
            XCTAssertEqual(merged.first?.endPeriod, 6)
        }

        XCTAssertTrue(store.mergedCourses(dayOfWeek: 1, block: 9...10).isEmpty)
    }

    // MARK: - 清空

    func testClearTimetableDataResetsMemoryAndRepository() {
        let repository = InMemoryTimetableRepository(courses: [course(name: "A")])
        let store = makeStore(repository: repository)
        store.updateUIFlags(UIFlags(isDarkTheme: true, isOptimizeMode: true))
        store.shiftWeek(by: 2)

        store.clearTimetableData()

        XCTAssertTrue(store.courses.isEmpty)
        XCTAssertEqual(store.settings, .default)
        XCTAssertEqual(store.profiles, [.defaultProfile])
        XCTAssertEqual(store.credentials.username, "")
        XCTAssertEqual(store.uiFlags, .default)
        XCTAssertEqual(store.weekOffset, 0)
        XCTAssertEqual(repository.saveCounts["clear"], 1)
        XCTAssertTrue(repository.courses.isEmpty)
    }
}
