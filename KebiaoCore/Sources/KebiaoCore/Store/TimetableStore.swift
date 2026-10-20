import Combine
import Foundation

/// App 的唯一状态源：把原版 `TimetableViewModel` 的七个 `MutableStateFlow`
/// 收成一个 `ObservableObject`，并去掉 Android 版的协程/`Job` 包装。
///
/// 证据：
/// - `上课早枝道-源码-1.11.5/app/src/main/java/kebiaocom/example/ui/TimetableViewModel.java`
///   （七个状态流：`_courses` / `_settings` / `_timetableProfiles` / `_credentials` /
///   `_isLoading` / `_error` / `_currentWeekOffset`；四个写操作各起一个 Job，
///   写完立刻 `localStorage.saveXxx(...)`）
/// - 逐个写操作的语义取自各自的 lambda 类，例如
///   `TimetableViewModel$insertCourse$1.java:59-79`
///
/// 与原版的三处**有意**差异（都不改变外界可观察的数据行为）：
/// 1. 原版 `insertCourse` 用 `courses.size + 1` 当新 `id`（不是 `max + 1`），
///    照抄了——尽管删除后再新增会撞 id，但改掉会让 iOS 与 Android 的
///    本地数据分叉，所以保持原样并在此标注；
/// 2. 原版写操作是 `launch { }` 异步的，iOS 端同步落盘（`UserDefaults` 本来就是同步的），
///    调用返回即表示已写；这样测试不需要等待；
/// 3. 原版把失败只写进 `_error` 供界面弹 toast，这里统一进 `lastError` 并**不抛错**，
///    保证存储层异常不会让 App 起不来（见 `TimetableRepositoryError` 的说明）。
@MainActor
public final class TimetableStore: ObservableObject {

    // MARK: - 已发布状态

    /// 全部课程（未按周次过滤）。
    @Published public private(set) var courses: [Course]
    /// 全局设置。
    @Published public private(set) var settings: AppSettings
    /// 作息时间方案（可能多套）。
    @Published public private(set) var profiles: [TimetableProfile]
    /// 教务凭证。`password` 只该来自 Keychain。
    @Published public private(set) var credentials: UserCredentials
    /// 深色 / 优化模式两个开关。
    @Published public private(set) var uiFlags: UIFlags
    /// 最近一次存储层报错（人话），成功后仍是上次的值，直到 `clearLastError()`。
    /// 原版对应 `_error: StateFlow<String?>`。
    @Published public private(set) var lastError: String?

    /// 相对「本周」的周次偏移：0 = 本周，-1 = 上周，1 = 下周。
    ///
    /// 对应原版 `TimetableViewModel._currentWeekOffset`
    /// （`TimetableViewModel.java:33`）。注意原版**只允许下界**：
    /// 显示用的周次是 `max(currentWeek + offset, 1)`
    /// （`TimetableScreenKt.java:319-321` 的 `getWeekNumberDisplay`）。
    @Published public var weekOffset: Int = 0

    // MARK: - 依赖

    /// 存储实现。测试里换成 `InMemoryTimetableRepository`。
    public let repository: TimetableRepository
    private let now: () -> Date
    public let calendar: Calendar

    // MARK: - 初始化

    /// - Parameters:
    ///   - repository: 存储实现。
    ///   - now: 取「现在」的方式。测试注入固定时间，避免依赖真实时钟。
    ///   - calendar: 周次计算用的日历；默认与 Android 端等效（周一为一周之首）。
    public init(
        repository: TimetableRepository,
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .app
    ) {
        self.repository = repository
        self.now = now
        self.calendar = calendar

        // 读取失败一律回落到出厂值，只把问题记进 `lastError`：
        // 原版 `LocalStorage` 在 JSON 损坏时也是静默回落，不能让配置读不出来就崩。
        var problems: [String] = []
        func load<T>(_ label: String, _ body: () throws -> T, fallback: T) -> T {
            do {
                return try body()
            } catch {
                problems.append("\(label)：\(error.localizedDescription)")
                return fallback
            }
        }

        self.courses = load("课程", { try repository.loadCourses() }, fallback: [])
        self.settings = load("设置", { try repository.loadSettings() }, fallback: .default)
        self.profiles = load("作息方案", { try repository.loadProfiles() }, fallback: [.defaultProfile])
        self.credentials = load(
            "教务凭证",
            { try repository.loadCredentials() },
            fallback: UserCredentials(username: "", password: "")
        )
        // 密码侧的失败是**局部失败**：用户名 / 教务 URL 已经从 `UserDefaults` 读到并保留，
        // 只有密码没读到。实现把原因记在 `credentialLoadWarning` 里而不是抛错，
        // 所以这里必须单独把它并进 `lastError` —— 账号留住了，错误也不能被吞掉。
        if let credentialWarning = repository.credentialLoadWarning {
            problems.append("教务密码：\(credentialWarning)")
        }
        self.uiFlags = load("界面开关", { try repository.loadUIFlags() }, fallback: .default)
        self.lastError = problems.isEmpty ? nil : problems.joined(separator: "；")

        if self.profiles.isEmpty {
            self.profiles = [.defaultProfile]
        }
    }

    public func clearLastError() {
        lastError = nil
    }

    // MARK: - 派生：作息与节次

    /// 当前选中的作息方案；选不中时退回第一套、再退回内置默认。
    public var activeProfile: TimetableProfile {
        profiles.first { $0.id == settings.selectedTimetableProfileId }
            ?? profiles.first
            ?? .defaultProfile
    }

    /// 生效的时间槽，形如 `["08:10-08:55", …]`。
    public var timeSlots: [String] {
        TimeSlotLogic.effectiveTimeSlots(settings: settings, profiles: profiles)
    }

    /// 网格行数。原版传的是 `timeSlots.size().coerceAtLeast(1)`
    /// （`TimetableScreenKt.java:4558`）。
    public var periodCount: Int {
        max(timeSlots.count, 1)
    }

    /// **网格实际要画的行数** = 作息方案行数 与「已保存课程的最大节次」取大者。
    ///
    /// 为什么需要它（2026-10-20 真机诊断确认的缺口）：教务课表页有 **6 个大节行**，解析时
    /// 课程节次全部走「大节号 × 2」兜底（真机诊断 `节次区间=0/兜底 49`），于是第 6 大节
    /// → 第 **11–12** 节；而出厂作息方案只有 10 节（`TimetableProfile.defaultProfile`），
    /// 网格行数 = `periodCount` = 10、面板只到 `9...10` ⇒ **第 11–12 节的课永远不会被画出来**，
    /// 表现为「同步成功、共 49 门，界面上却看不到这几门」。
    /// 课程编辑器的下拉已经做了等价保证（`CourseEditorView.periodRange` 取
    /// `max(store.periodCount, draft.endPeriod, …)`），网格这里补齐同一口径。
    public var gridPeriodCount: Int {
        max(periodCount, courses.map(\.endPeriod).max() ?? 0, 1)
    }

    /// 一天拆成的三个面板：上午 `1...4`、下午 `5...8`、晚上 `9...rows`
    /// （`apk_work/kb/src2/TimetableGridV2.kt:362-421`）。
    public var periodBlocks: [ClosedRange<Int>] {
        TimetableStore.blocks(forRows: periodCount)
    }

    /// 网格**实际**使用的面板划分：行数改用 `gridPeriodCount`（见其说明）。
    /// `TimetableGrid` 用这一个；`periodBlocks` 保持「作息方案」原义不变。
    public var gridPeriodBlocks: [ClosedRange<Int>] {
        TimetableStore.blocks(forRows: gridPeriodCount)
    }

    private static func blocks(forRows rows: Int) -> [ClosedRange<Int>] {
        guard rows >= 1 else { return [] }
        var blocks: [ClosedRange<Int>] = [1...min(rows, 4)]
        if rows > 4 { blocks.append(5...min(rows, 8)) }
        if rows > 8 { blocks.append(9...rows) }
        return blocks
    }

    /// 展示层诊断：把「已保存的课」与「课表实际会画出来的课」对齐。
    ///
    /// 存在的理由：2026-10-20 的真机诊断已证明**同步链路没丢课**（英语 / 体育 / 高等数学
    /// 都 `最终=1/1/2`），丢失发生在**展示环节**。这段文本追加在同步状态文案后面，
    /// 只记计数与目标课关键词（允许出现），不含教师 / 班级等个人信息。
    ///
    /// - Parameter keywords: 目标课关键词（包含式、大小写不敏感）。默认取
    ///   `JwxtParseDiagnostics.targetKeywords`；测试可传入自己的关键词集。
    public func displayDiagnosticSummary(
        keywords: [String] = JwxtParseDiagnostics.targetKeywords
    ) -> String {
        let visible = coursesForDisplayedWeek()
        let visibleIds = Set(visible.map { $0.course.id })

        var lines = ["【展示层诊断】"]
        // 「单值周次」= `weekRange` 里既没有 `-` 也没有 `,`（例如被解析成 "4"）。
        // 正常的教学周区间是 `1-16` 这种形态；单值课程只会在那一周出现，
        // 其余周次一律被「非本周」过滤掉 —— 这是「保存了却看不见」的第二大来源。
        let singleWeekCourses = courses.filter {
            !$0.weekRange.contains("-") && !$0.weekRange.contains(",")
        }
        // 周末两天默认不显示列（`showSaturday` / `showSunday` 默认 false）：
        // 落在六 / 周日的课会保存成功但没有任何一列可画。
        let hiddenWeekendCourses = courses.filter {
            ($0.dayOfWeek == 6 && !settings.showSaturday)
                || ($0.dayOfWeek == 7 && !settings.showSunday)
        }
        lines.append(
            "作息节数=\(periodCount) 网格行数=\(gridPeriodCount)"
            + " 显示周次=\(displayedWeek) 已存课程=\(courses.count)"
            + " 本周可见=\(visible.count) 非本周被滤=\(courses.count - visible.count)"
            + " 超出生效作息节数的课=\(courses.filter { $0.endPeriod > periodCount }.count)"
            + " 超出网格行数的课=\(courses.filter { $0.endPeriod > gridPeriodCount }.count)"
        )
        lines.append(
            "周次单值课程=\(singleWeekCourses.count)"
            + "(正常应为区间如 1-16；单值只会在那一周出现)"
            + " 周末无列被隐藏=\(hiddenWeekendCourses.count)"
        )
        for keyword in keywords {
            let matched = courses.filter { JwxtParseDiagnostics.contains($0.name, keyword) }
            guard let first = matched.first else {
                lines.append("  \(keyword) 无匹配课程")
                continue
            }
            lines.append(
                "  \(keyword) 课数=\(matched.count) 首门 日=\(first.dayOfWeek)"
                + " 节=\(first.startPeriod)-\(first.endPeriod) 周次=\(first.weekRange)"
                + " 单双=\(JwxtParseDiagnostics.parityText(first.isOdd))"
                + " 本周可见=\(JwxtParseDiagnostics.yesNo(visibleIds.contains(first.id)))"
                + " 超出网格=\(JwxtParseDiagnostics.yesNo(first.endPeriod > gridPeriodCount))"
            )
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 派生：周次与日期

    /// 当前教学周（受 `firstWeekStartDate` / `semesterWeeks` 影响）。
    public var currentWeek: Int {
        WeekLogic.teachingWeek(
            firstWeekStartDate: settings.firstWeekStartDate,
            semesterWeeks: settings.semesterWeeks,
            now: now(),
            calendar: calendar
        )
    }

    /// 界面上显示的周次 = `max(当前周 + 偏移, 1)`。与 `getWeekNumberDisplay` 一致。
    public var displayedWeek: Int {
        max(currentWeek + weekOffset, 1)
    }

    /// `"第N周"`。
    public var weekNumberText: String {
        WeekLogic.weekNumberDisplay(displayedWeek)
    }

    /// 一周里要显示的日期（含周六/周日的开关）。
    public var weekDates: [WeekDate] {
        WeekLogic.weekDates(
            weekOffset: weekOffset,
            showSaturday: settings.showSaturday,
            showSunday: settings.showSunday,
            now: now(),
            calendar: calendar
        )
    }

    /// 要显示的星期编号（1 = 周一 … 7 = 周日），顺序与 `weekDates` 一致。
    public var visibleWeekdays: [Int] {
        weekDates.map { TimetableLayout.dayIndexOf($0.label) }
    }

    // MARK: - 派生：课程

    /// 某一天在某个面板里的课程（已做相邻合并）。
    public func mergedCourses(dayOfWeek: Int, block: ClosedRange<Int>) -> [Course] {
        TimetableLayout.coursesInBlock(
            courses,
            dayOfWeek: dayOfWeek,
            blockStartPeriod: block.lowerBound,
            blockEndPeriod: block.upperBound
        )
    }

    /// 这周应该显示的课程（是否含非本周课程由设置决定）。
    ///
    /// 原版在 `TimetableScreenKt.java:4496-4505`：`showNonCurrentWeekCourses` 为 false 时
    /// **先把不属于本周的课从列表里滤掉**，只有开着这个开关才把它们一起画出来、
    /// 再用 `nonCurrentWeekCourseAlphaPercent` 降低透明度（`:4558` 把该开关继续传给网格）。
    /// 所以这里不是「全返回 + 让视图自己判断」，而是真的过滤。
    ///
    /// - Returns: `(course, occursThisWeek)`。`occursThisWeek == false` 时，
    ///   视图应按 `settings.nonCurrentWeekCourseAlphaPercent` 降低透明度。
    public func coursesForDisplayedWeek() -> [(course: Course, occursThisWeek: Bool)] {
        let week = displayedWeek
        return courses.compactMap { course in
            let occurs = WeekLogic.courseOccursInWeek(course, week: week)
            if !occurs, !settings.showNonCurrentWeekCourses { return nil }
            return (course, occurs)
        }
    }

    // MARK: - 写操作：课程

    /// 新增一门课。**`id` 用 `courses.count + 1`**，与
    /// `TimetableViewModel$insertCourse$1.java:63` 的 `copy(id = size + 1)` 逐字一致。
    @discardableResult
    public func insertCourse(_ course: Course) -> Course {
        var inserted = course
        inserted.id = courses.count + 1
        courses.append(inserted)
        persistCourses()
        return inserted
    }

    /// 批量导入：原版先 `deleteAllCourses()` 再插入（全量覆盖）。
    /// 空数组时**不**覆盖（避免教务登录失败把已有课表清空）。
    public func replaceAllCourses(with newCourses: [Course]) {
        guard !newCourses.isEmpty else { return }
        courses = newCourses.enumerated().map { index, course in
            var copy = course
            copy.id = index + 1
            return copy
        }
        persistCourses()
    }

    /// 按 `id` 覆盖一门课；`id` 不存在时什么都不做。
    public func updateCourse(_ course: Course) {
        guard let index = courses.firstIndex(where: { $0.id == course.id }) else { return }
        courses[index] = course
        persistCourses()
    }

    /// 按 `id` 删除一门课。
    public func deleteCourse(_ course: Course) {
        let before = courses.count
        courses.removeAll { $0.id == course.id }
        guard courses.count != before else { return }
        persistCourses()
    }

    /// 清空全部课程。
    public func deleteAllCourses() {
        guard !courses.isEmpty else { return }
        courses.removeAll()
        persistCourses()
    }

    // MARK: - 写操作：设置与开关

    /// 整份替换设置。
    public func updateSettings(_ settings: AppSettings) {
        self.settings = settings
        persist { try repository.saveSettings(settings) }
    }

    /// 用闭包就地改设置（推荐入口，避免调用方忘掉落盘）。
    public func mutateSettings(_ body: (inout AppSettings) -> Void) {
        var copy = settings
        body(&copy)
        updateSettings(copy)
    }

    public func updateUIFlags(_ flags: UIFlags) {
        uiFlags = flags
        persist { try repository.saveUIFlags(flags) }
    }

    /// 与 `TimetableViewModel.addTimetableProfile` 对应：新增一套作息方案并选中它。
    public func addTimetableProfile(name: String, periods: [PeriodTime]? = nil) {
        let profile = TimetableProfile(
            id: UUID().uuidString,
            name: name,
            periodsPerDay: periods?.count ?? settings.periodsPerDay,
            periodTimes: periods ?? []
        )
        profiles.append(profile)
        mutateSettings { $0.selectedTimetableProfileId = profile.id }
        persist { try repository.saveProfiles(profiles) }
    }

    /// 换用某套作息方案。
    public func selectTimetableProfile(id: String) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        mutateSettings { $0.selectedTimetableProfileId = id }
    }

    /// 整套覆盖作息方案。
    ///
    /// 逐字对应 Android `TimetableViewModel.saveTimetableProfiles(profiles)`
    /// （`TimetableViewModel.java:128-132` → `TimetableViewModel$saveTimetableProfiles$1.java:57-59`：
    /// `_timetableProfiles.value = profiles` 后 `localStorage.saveTimetableProfiles(profiles)`）。
    /// 设置页的「编辑时间表」就是靠它把改好的 `periodTimes` 写回去
    /// （原版是逐节调 `updatePeriodTime(profileId,periodIndex,start,end)`，
    /// 语义等价：都是替换该方案的 `periodTimes` 再落盘）。
    ///
    /// 与原版的一处**有意**差异：空数组不覆盖。原版无条件替换，但 iOS 端
    /// `activeProfile` 依赖「至少有一套方案」（`profiles.first ?? .defaultProfile`），
    /// 允许清空会让下次启动的时间槽来源变得不可预测（理由同 `replaceAllCourses`）。
    public func saveTimetableProfiles(_ profiles: [TimetableProfile]) {
        guard !profiles.isEmpty else { return }
        self.profiles = profiles
        persist { try repository.saveProfiles(profiles) }
    }

    public func saveCredentials(_ credentials: UserCredentials) {
        self.credentials = credentials
        persist { try repository.saveCredentials(credentials) }
    }

    // MARK: - 写操作：周次导航

    /// 翻周。`delta` 为 ±1；周次不设上界（与原版一致），下界由 `displayedWeek` 兜住。
    public func shiftWeek(by delta: Int) {
        weekOffset += delta
    }

    /// 回到本周。
    public func resetWeekOffset() {
        weekOffset = 0
    }

    // MARK: - 清空

    /// 清空课表相关数据（不含日志），并把内存状态一起复位。
    public func clearTimetableData() {
        persist { try repository.clearTimetableData() }
        courses = []
        settings = .default
        profiles = [.defaultProfile]
        credentials = UserCredentials(username: "", password: "")
        uiFlags = .default
        weekOffset = 0
    }

    // MARK: - 落盘

    private func persistCourses() {
        persist { try repository.saveCourses(courses) }
    }

    /// 统一的落盘入口：失败不抛错，只记 `lastError`（原版写进 `_error`）。
    private func persist(_ body: () throws -> Void) {
        do {
            try body()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }
}
