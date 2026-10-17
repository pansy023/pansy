import PhotosUI
import SwiftUI
import UIKit
import KebiaoCore

/// 设置首页。分组与文案取自 Android 1.11.5 `SettingsScreenKt.java`：
/// - 首页五张分类卡：「账号与同步」「学期与时间」「显示与样式」「提醒与权限」「其他」
///   （`SettingsScreenKt.java:1103` 一带的 `"账号与同步"` / `"学期与时间"` / `"显示与样式"`；
///   每张卡右边的「进入」`:1103`）；
/// - 账号卡内组名「账号与教务系统」、行「教务系统URL」「用户名」「密码」`:1455` 前后、
///   「定时同步教务课表」`:1454`、按钮「测试课表自动同步通知」
///   （`ComposableSingletons$SettingsScreenKt.java`）、「保存设置」；
/// - 显示卡内组名「显示选项」`:2120`、组名「界面样式」；
/// - 时间卡内组名「学期与时间」与行「学期开始日期」「第一节开始时间（HH:mm）」
///   「每节时长（分钟）」「课间时长（分钟）」「一天课程节数」「学期周数」
///   「时间表名称」「编辑时间表」。
///
/// iOS 侧的取舍（有意为之，逐条写在注释里）：
/// - 「学期与时间」不做成开关，按用户要求做成**一级入口**（`NavigationLink`）→
///   `SemesterSettingsView`，那里面才有日期选择器、作息时间表编辑与「保存设置」。
/// - 「账号与教务系统」四项走**草稿 + 保存设置**（原版也是 pending 态 + 保存设置，
///   `SettingsScreenKt.java:4675-4676`：保存时才 `saveCredentials` + `updateSettings`）；
/// - 「显示选项」「界面样式」的所有开关与滑动条**立即生效并落盘**
///   （绑定 `@AppStorage` 不适合这里：状态源是 `TimetableStore`，直接写它才能保证
///   主界面、网格、卡片同一帧跟着变）。
struct SettingsView: View {

    @EnvironmentObject private var environment: AppEnvironment

    private var store: TimetableStore { environment.store }
    private var settings: AppSettings { store.settings }
    private var dark: Bool { store.uiFlags.isDarkTheme }
    private var optimize: Bool { store.uiFlags.isOptimizeMode }

    // MARK: - 草稿与临时状态

    /// 账号与同步的草稿：只有点「保存设置」才写进 `TimetableStore`
    /// （密码进 Keychain，`username` / `jwxtUrl` 进 UserDefaults，见 `CredentialStore`）。
    @State private var draftJwxtUrl = ""
    @State private var draftUsername = ""
    @State private var draftPassword = ""
    @State private var draftAutoSync = false
    @State private var didLoadAccountDraft = false

    /// 「同步课表」的进行中状态与最近一次结果文案。
    ///
    /// 文案逐字取自原版手动刷新流程 `TimetableViewModel$refreshTimetable$1.java`：
    /// 未配置账号 `:102`、异常 `:84`、抓不到 `:147`；成功文案取自动同步通知
    /// `TimetableAutoRefreshNotifier.java:81`（「已从教务系统覆盖本地课表，共 N 门课程。」）。
    @State private var isSyncingTimetable = false
    @State private var syncStatusText = ""

    /// 背景图：相册选择器与手动地址输入。
    @State private var showingPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?
    @State private var manualImageAddress = ""

    /// 一条一次性提示（保存成功 / 通知被拒 / 背景图出错）。
    @State private var notice: Notice?

    private struct Notice: Identifiable {
        let id = UUID()
        let text: String
    }

    var body: some View {
        Form {
            syncSection
            accountSection
            semesterEntrySection
            displayOptionsSection
            appearanceSection
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadAccountDraftIfNeeded)
        .photosPicker(isPresented: $showingPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, newValue in
            guard let newValue else { return }
            Task { await savePickedBackground(newValue) }
        }
        .alert(item: $notice) { item in
            Alert(title: Text("提示"), message: Text(item.text), dismissButton: .default(Text("好")))
        }
    }

    // MARK: - ⓿ 同步课表（设置最顶端）

    /// 手动同步入口：登录教务系统 → 抓取课表 → 覆盖本地课程。
    ///
    /// 与安卓端的同一套流程对齐（`JwxtTimetableSync.fetchFromJwxt` +
    /// `TimetableViewModel$refreshTimetable$1.java`）：
    /// 1. 先落地「账号与教务系统」的草稿（URL / 用户名 / 密码），否则用户改完账号
    ///    不点保存就同步会用到旧凭证；
    /// 2. 用户名或密码为空 → 直接提示「请先在设置中配置教务系统账号」（`:102`，不发起请求）；
    /// 3. `JwxtTimetableSync.fetchFromJwxt` → 非空则整体替换本地课程
    ///    （等价 `:131-134` 的 `_courses.value = list` + `saveCourses(list)`）；
    ///    为空则**保留**本地课程并提示「未获取到课表数据」（`:147`）；
    /// 4. 失败提示「刷新失败: <原因>」（`:84`）。
    private var syncSection: some View {
        Section {
            Button {
                Task { await syncTimetable() }
            } label: {
                HStack(spacing: 8) {
                    Text("刷新课表")
                    Spacer(minLength: 8)
                    if isSyncingTimetable {
                        ProgressView()
                    }
                }
            }
            .disabled(isSyncingTimetable)

            if !syncStatusText.isEmpty {
                Text(syncStatusText)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("同步课表")
        } footer: {
            Text(
                "点「刷新课表」会用下面「账号与教务系统」里已保存的 URL、用户名、密码"
                + "登录教务系统，再抓取课表并整体覆盖本地课程（抓不到时不会清空已有课表）。"
                + "与安卓端「刷新课表」是同一套流程。"
            )
        }
    }

    /// 执行一次同步。所有状态变化都发生在主线程（`Task` 继承 SwiftUI 的 MainActor）。
    @MainActor
    private func syncTimetable() async {
        // 先把草稿落地：用户很可能刚改完账号就直接点同步。
        persistAccountDraft()

        let credentials = store.credentials
        guard !credentials.username.isEmpty, !credentials.password.isEmpty else {
            syncStatusText = "请先在设置中配置教务系统账号"
            notice = Notice(text: syncStatusText)
            return
        }

        isSyncingTimetable = true
        syncStatusText = "正在登录教务系统并抓取课表…"
        defer { isSyncingTimetable = false }

        do {
            let courses = try await JwxtTimetableSync().fetchFromJwxt(credentials: credentials)
            if courses.isEmpty {
                syncStatusText = "未获取到课表数据"
                notice = Notice(text: "未获取到课表数据；已保留本地原有课程。")
            } else {
                store.replaceAllCourses(with: courses)
                syncStatusText = "已从教务系统覆盖本地课表，共 \(courses.count) 门课程。"
                notice = Notice(text: syncStatusText)
            }
        } catch {
            syncStatusText = "刷新失败: \(error.localizedDescription)"
            notice = Notice(text: syncStatusText)
        }
    }

    // MARK: - ① 账号与同步

    private var accountSection: some View {
        Section {
            labelTextField("教务系统URL", text: $draftJwxtUrl, keyboard: .URL)
            labelTextField("用户名", text: $draftUsername)
            labelSecureField("密码", text: $draftPassword)

            Toggle("定时同步教务课表", isOn: $draftAutoSync)

            Button("测试课表自动同步通知") {
                Task { await sendTestNotification() }
            }

            Button("保存设置") {
                saveAccountSettings()
            }
        } header: {
            Text("账号与教务系统")
        } footer: {
            Text(
                "密码说明：此密码为学校抢课网站密码，非查课系统密码。"
                + "保存后密码只写进 iOS 钥匙串（Keychain），不会明文落盘。"
                + "\n「定时同步教务课表」当前只保存开关取值：iOS 侧要在阶段⑤ 用"
                + " BGAppRefreshTask 才能定时拉取，且系统不保证触发时刻"
                + "（原版 Android 是每天凌晨 1 点与中午 1 点，见 `TimetableAutoRefreshNotifier`）。"
            )
        }
    }

    /// 把账号与同步草稿落地（原版也是 pending 态，点保存才写；`SettingsScreenKt.java:4675-4676`）。
    ///
    /// 拆出来是因为「刷新课表」也要先落地草稿才能用上用户刚改的账号。
    private func persistAccountDraft() {
        let jwxtUrl = draftJwxtUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        store.saveCredentials(
            UserCredentials(
                id: store.credentials.id,
                username: draftUsername.trimmingCharacters(in: .whitespacesAndNewlines),
                password: draftPassword,
                jwxtUrl: jwxtUrl.isEmpty ? UserCredentials.defaultJwxtUrl : jwxtUrl
            )
        )
        store.mutateSettings { $0.autoSyncTimetableFromJwxt = draftAutoSync }
    }

    private func saveAccountSettings() {
        persistAccountDraft()
        notice = Notice(text: "设置已保存")
    }

    private func sendTestNotification() async {
        let ok = await LocalNotificationTester.sendTestAutoSyncNotification()
        if !ok {
            // 原版同一句提示：`SettingsScreenKt.java:1475`。
            notice = Notice(text: "无法测试：请先在系统设置中允许本应用发送通知")
        }
    }

    /// 首次出现时把已存的凭证灌进草稿；之后不再覆盖，避免打字打到一半被读盘冲掉。
    private func loadAccountDraftIfNeeded() {
        guard !didLoadAccountDraft else { return }
        didLoadAccountDraft = true
        let credentials = store.credentials
        draftJwxtUrl = credentials.jwxtUrl
        draftUsername = credentials.username
        draftPassword = credentials.password
        draftAutoSync = settings.autoSyncTimetableFromJwxt
    }

    // MARK: - ② 学期与时间（独立一级入口）

    private var semesterEntrySection: some View {
        Section {
            NavigationLink {
                SemesterSettingsView()
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("学期与时间")
                    Text(semesterSummary)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        } footer: {
            Text("点击进入：学期开始日期（弹出日期选择器）、第一节开始时间、每节时长、课间时长、一天课程节数、学期周数、时间表名称与「编辑时间表」。")
        }
    }

    private var semesterSummary: String {
        let start = settings.firstWeekStartDate ?? "未设置"
        return "开始日期 \(start) · 共 \(settings.semesterWeeks) 周 · 时间表「\(store.activeProfile.name)」"
    }

    // MARK: - ③ 显示选项

    private var displayOptionsSection: some View {
        Section {
            Toggle("深色模式", isOn: darkThemeBinding)
            Toggle("优化模式", isOn: optimizeModeBinding)
            Toggle("显示周六", isOn: settingsBinding(\.showSaturday))
            Toggle("显示周日", isOn: settingsBinding(\.showSunday))
            Toggle("显示主界面滑动条", isOn: settingsBinding(\.showWeekSlider))
            Toggle("自动检查更新", isOn: settingsBinding(\.autoCheckUpdate))
            Toggle("显示非本周课程", isOn: settingsBinding(\.showNonCurrentWeekCourses))
            Toggle("显示上课时间", isOn: settingsBinding(\.showCourseTime))
            Toggle("显示上课地点", isOn: settingsBinding(\.showCourseLocation))
            Toggle("显示授课老师", isOn: settingsBinding(\.showCourseTeacher))
        } header: {
            Text("显示选项")
        } footer: {
            Text(
                "全部开关立即生效并落盘：「深色模式」「优化模式」改整页与卡片配色；"
                + "「显示周六」「显示周日」增减网格列；「显示主界面滑动条」在课表上方显示 1…学期周数 的滑动条；"
                + "「显示非本周课程」关掉时不属于当前周的课直接不画；"
                + "「显示上课时间」「显示上课地点」「显示授课老师」控制展开卡片里的三行信息。"
                + "\n「自动检查更新」在 iOS 上只保存取值：App 更新走 App Store，"
                + "没有 Android 那种应用内检查更新的等价入口。"
            )
        }
    }

    // MARK: - ④ 界面样式

    private var appearanceSection: some View {
        Section {
            backgroundRows
            sliderRow(
                "课程卡高度",
                keyPath: \.courseCellHeightDp,
                range: 40...120,
                suffix: "dp"
            )
            sliderRow(
                "课程文字",
                keyPath: \.courseTextSizeSp,
                range: 7...30,
                suffix: "sp"
            )
            sliderRow(
                "非本周透明度",
                keyPath: \.nonCurrentWeekCourseAlphaPercent,
                range: 0...100,
                step: 5,
                suffix: "%"
            )
            sliderRow(
                "卡片透明度",
                keyPath: \.courseCardAlphaPercent,
                range: 0...100,
                step: 5,
                suffix: "%"
            )
            sliderRow(
                "卡片磨砂强度",
                keyPath: \.courseFrostedIntensityPercent,
                range: 0...100,
                step: 5,
                suffix: "%"
            )

            VStack(alignment: .leading, spacing: 8) {
                Text("课表卡片预览")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                cardPreview
                Text("预览用的就是网格里那张卡（`CourseCard`），尺寸与字号实时跟随上面三个滑动条。")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
        } header: {
            Text("界面样式")
        } footer: {
            Text(
                "「课程卡高度」= `courseCellHeightDp`（默认 69 dp），决定网格每行的高度与卡片高度；"
                + "「课程文字」= `courseTextSizeSp`（默认 10 sp），最终字号还会被原版规则"
                + " `fitTextSize` 夹在 7…30 之间；「非本周透明度」「卡片透明度」按原版"
                + " `alpha = 卡片透明度 × 非本周透明度`（仅当「显示非本周课程」打开且该课不在本周）叠加。"
                + "\n⚠️ 「卡片磨砂强度」作用在下面的预览卡上：原版 1.11.5 的主界面网格"
                + "（`TimetableGridV2.kt` 的 `CourseTile`）并不读取该值，只有已被弃用的旧"
                + " `CourseCard`（`TimetableScreenKt.java:5779`）才用它，"
                + "所以 iOS 端不给网格卡加一层原版没有的黑罩，只在预览里按同一条公式体现。"
            )
        }
    }

    // MARK: - 背景图片

    @ViewBuilder
    private var backgroundRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("背景图片")
            Text(backgroundStatusText)
                .font(.caption)
                .foregroundColor(.secondary)
        }

        Button("从相册选择背景图") {
            showingPhotoPicker = true
        }

        Button("清除背景图（恢复默认）") {
            clearBackground()
        }
        .disabled(!settings.hasCustomBackground)

        VStack(alignment: .leading, spacing: 6) {
            TextField("手动输入图片地址", text: $manualImageAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .onSubmit(applyManualImageAddress)
            Button("应用图片地址", action: applyManualImageAddress)
                .disabled(manualImageAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var backgroundStatusText: String {
        switch BackgroundImageStore.resolve(settings.backgroundImageUri) {
        case .none:
            return "当前为默认背景"
        case let .localFile(url):
            return "已选择相册图片：\(url.lastPathComponent)"
        case let .remote(url):
            return "已使用图片地址：\(url.absoluteString)"
        }
    }

    /// 相册图片落盘再写键：`backgroundImageUri` 存的是沙盒文件路径。
    private func savePickedBackground(_ item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                notice = Notice(text: "读取相册图片失败，请换一张再试")
                return
            }
            let path = try BackgroundImageStore.save(imageData: data)
            store.mutateSettings { $0.backgroundImageUri = path }
        } catch {
            notice = Notice(text: "背景图保存失败：\(error.localizedDescription)")
        }
        photoItem = nil
    }

    private func clearBackground() {
        BackgroundImageStore.removeStoredFile()
        manualImageAddress = ""
        store.mutateSettings { $0.backgroundImageUri = nil }
    }

    private func applyManualImageAddress() {
        let trimmed = manualImageAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clearBackground()
            return
        }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            notice = Notice(text: "只支持 http/https 图片地址；相册里的图片请用「从相册选择背景图」。")
            return
        }
        // 手动地址写进同一个键；沙盒里残留的旧图这时已不再被引用，顺手删掉。
        BackgroundImageStore.removeStoredFile()
        store.mutateSettings { $0.backgroundImageUri = trimmed }
    }

    // MARK: - 卡片预览

    /// 预览卡：与网格用同一个 `CourseCard`，所以高度、字号、透明度、配色全都一致。
    private var cardPreview: some View {
        // 例课取原版设置页预览用的那门（`SettingsScreenKt` 里的 "高等数学" / "张明" /
        // "6号教学楼 A310" / "1-20"）。
        let sample = Course(
            id: 0,
            name: "高等数学",
            teacher: "张明",
            location: "6号教学楼 A310",
            dayOfWeek: 1,
            startPeriod: 1,
            endPeriod: 2,
            color: 0,
            weekRange: "1-20"
        )
        // 单节课的卡片高度 = 行高 - `CardGap`，并与网格一样有 `MinCardHeight` 下限。
        let height = max(CGFloat(settings.courseCellHeightDp) - Theme.cardGap, Theme.minCardHeight)
        let mode: CardPaletteMode = optimize ? .optimized : .colorful
        let raw = mode.colors(courseName: sample.name, darkTheme: dark)

        var style = CourseCardStyle.resolve(
            course: sample,
            dark: dark,
            optimize: optimize,
            occursThisWeek: true,
            settings: settings,
            cardHeight: height
        )
        style.background = Color(
            argb: Self.frosted(raw.background, percent: settings.courseFrostedIntensityPercent)
        )

        return CourseCard(course: sample, style: style, height: height)
            .frame(maxWidth: .infinity)
    }

    /// 磨砂强度对底色的作用：逐字取自原版旧 `CourseCard` 的
    /// `lerp(tint, black, 0.06 * frosted)`（`TimetableScreenKt.java:5779`：
    /// `f5 = 0.06f * frostedIntensity`）。Compose 的 `Color.lerp` 是四通道线性插值，
    /// 向黑色插值等价于 RGB 各通道乘 `(1 - f5)`，alpha 保持不透明。
    private static func frosted(_ argb: UInt32, percent: Int) -> UInt32 {
        let clamped = Double(min(max(percent, 0), 100)) / 100.0
        let factor = 1.0 - 0.06 * clamped
        let alpha = (argb >> 24) & 0xFF
        let red = UInt32(Double((argb >> 16) & 0xFF) * factor)
        let green = UInt32(Double((argb >> 8) & 0xFF) * factor)
        let blue = UInt32(Double(argb & 0xFF) * factor)
        return (alpha << 24) | (red << 16) | (green << 8) | blue
    }

    // MARK: - 绑定
    //
    // 状态源是 `TimetableStore`：所有绑定都直写 store，写下去即落盘
    // （`TimetableStore.mutateSettings` → `UserDefaultsTimetableRepository`），
    // 不走 `@AppStorage`，避免出现「两处状态各说各话」。

    /// `AppSettings` 里某个 `Bool` 字段 ↔ `Toggle`。
    private func settingsBinding(_ keyPath: WritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { newValue in
                store.mutateSettings { $0[keyPath: keyPath] = newValue }
            }
        )
    }

    /// 两个 `uiFlags` 是全局单例式的开关，落在 `ui_dark_mode` / `ui_optimize_mode`
    /// 两个键上，所以整份 `UIFlags` 一起写回，避免只改一个字段。
    private var darkThemeBinding: Binding<Bool> {
        Binding(
            get: { store.uiFlags.isDarkTheme },
            set: { newValue in
                var flags = store.uiFlags
                flags.isDarkTheme = newValue
                store.updateUIFlags(flags)
            }
        )
    }

    private var optimizeModeBinding: Binding<Bool> {
        Binding(
            get: { store.uiFlags.isOptimizeMode },
            set: { newValue in
                var flags = store.uiFlags
                flags.isOptimizeMode = newValue
                store.updateUIFlags(flags)
            }
        )
    }

    /// 整数设置项 ↔ `Slider`（滑完即写盘，存的也是整数）。
    ///
    /// 上下界是 iOS 侧的 UI 收敛（原版是文本输入框，只校验能不能转成整数）：
    /// 卡片高度 40…120 dp、文字 7…30 sp 与 `fitTextSize` 的夹取区间一致
    /// （`TimetableLayout.fitTextSize(configured:heightDp:)` 把配置值夹在 7…30），
    /// 三个百分比项 0…100。
    private func intBinding(
        _ keyPath: WritableKeyPath<AppSettings, Int>,
        range: ClosedRange<Int>
    ) -> Binding<Double> {
        Binding(
            get: { Double(settings[keyPath: keyPath]) },
            set: { newValue in
                let value = min(max(Int(newValue.rounded()), range.lowerBound), range.upperBound)
                store.mutateSettings { $0[keyPath: keyPath] = value }
            }
        )
    }

    /// 一行「标签 + 当前值 + 滑动条」。
    private func sliderRow(
        _ title: String,
        keyPath: WritableKeyPath<AppSettings, Int>,
        range: ClosedRange<Int>,
        step: Int = 1,
        suffix: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text("\(settings[keyPath: keyPath]) \(suffix)")
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            Slider(value: intBinding(keyPath, range: range), in: Double(range.lowerBound)...Double(range.upperBound), step: Double(step))
                .accessibilityLabel(title)
        }
    }

    /// 一行「标签 + 文本输入框（右对齐）」。
    private func labelTextField(
        _ title: String,
        text: Binding<String>,
        keyboard: UIKeyboardType = .default
    ) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 12)
            TextField("", text: text)
                .multilineTextAlignment(.trailing)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel(title)
        }
    }

    /// 一行「标签 + 安全输入框（密码只进 Keychain）。
    private func labelSecureField(_ title: String, text: Binding<String>) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 12)
            SecureField("", text: text)
                .multilineTextAlignment(.trailing)
                .accessibilityLabel(title)
        }
    }
}

#if DEBUG
struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            SettingsView()
        }
        .environmentObject(
            AppEnvironment(store: TimetableStore(repository: InMemoryTimetableRepository()))
        )
    }
}
#endif
