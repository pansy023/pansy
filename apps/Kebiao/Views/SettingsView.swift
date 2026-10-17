import PhotosUI
import SwiftUI
import KebiaoCore

/// 设置首页。分组与文案取自 Android 1.11.5 `SettingsScreenKt.java`：
/// - 一级页顶部是「设置分类」卡（`:1055`）：两个可进入的二级项
///   「账号与同步」`:1103` 与「学期与时间」`:1132`（原版行尾缀「进入」）；
/// - 「显示与样式」按用户要求**直接铺在一级页面**（安卓把它放在
///   `DISPLAY_STYLE` 二级页里，用户明确要求放到一级）：组名「显示选项」`:2120`、
///   组名「界面样式」`:2367`，内含背景图、五个滑动条与「课表卡片预览」`:2677`。
///
/// iOS 侧的取舍（有意为之，逐条写在注释里）：
/// - 「账号与同步」「学期与时间」都做成**一级入口**（`NavigationLink`）→
///   `AccountSyncSettingsView` / `SemesterSettingsView`：账号、密码、定时同步、
///   首次同步的重试提示都在账号页；日期选择器与作息时间表编辑都在学期页。
/// - 「显示选项」「界面样式」的所有开关与滑动条**立即生效并落盘**
///   （绑定 `@AppStorage` 不适合这里：状态源是 `TimetableStore`，直接写它才能保证
///   主界面、网格、卡片同一帧跟着变）。
struct SettingsView: View {

    @EnvironmentObject private var environment: AppEnvironment

    private var store: TimetableStore { environment.store }
    private var settings: AppSettings { store.settings }
    private var dark: Bool { store.uiFlags.isDarkTheme }
    private var optimize: Bool { store.uiFlags.isOptimizeMode }

    // MARK: - 临时状态

    /// 背景图：相册选择器与手动地址输入。
    @State private var showingPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?
    @State private var manualImageAddress = ""

    /// 一条一次性提示（背景图出错）。
    @State private var notice: Notice?

    private struct Notice: Identifiable {
        let id = UUID()
        let text: String
    }

    var body: some View {
        Form {
            categorySection
            displayOptionsSection
            appearanceSection
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .photosPicker(isPresented: $showingPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, newValue in
            guard let newValue else { return }
            Task { await savePickedBackground(newValue) }
        }
        .alert(item: $notice) { item in
            Alert(title: Text("提示"), message: Text(item.text), dismissButton: .default(Text("好")))
        }
    }

    // MARK: - ⓿ 设置分类（两个可进入的一级入口）

    /// 一级页顶部的两个入口，对齐 `SettingsScreenKt.java:1103` / `:1132` 的
    /// `SettingValueRow("账号与同步", "进入")` / `("学期与时间", "进入")`。
    ///
    /// 两者内容都在各自的二级页里：
    /// - `AccountSyncSettingsView`：账号与教务系统、定时同步、刷新课表、保存设置；
    /// - `SemesterSettingsView`：学期开始日期、第一节开始时间、每节/课间时长、
    ///   一天课程节数、学期周数、时间表名称与「编辑时间表」。
    private var categorySection: some View {
        Section {
            NavigationLink {
                AccountSyncSettingsView()
            } label: {
                Text("账号与同步")
            }
            .accessibilityIdentifier("settings.nav.account")
            NavigationLink {
                SemesterSettingsView()
            } label: {
                Text("学期与时间")
            }
            .accessibilityIdentifier("settings.nav.semester")
        } footer: {
            Text(
                "「账号与同步」里是教务系统 URL、用户名、密码、定时同步与刷新课表；"
                + "「学期与时间」里是学期开始日期（点开弹日期选择器）、第一节开始时间、"
                + "每节时长、课间时长、一天课程节数、学期周数、时间表名称与「编辑时间表」。"
            )
        }
    }

    // MARK: - ① 显示选项

    private var displayOptionsSection: some View {
        Section {
            Toggle("深色模式", isOn: darkThemeBinding)
                .accessibilityIdentifier("settings.toggle.dark")
            Toggle("优化模式", isOn: optimizeModeBinding)
                .accessibilityIdentifier("settings.toggle.optimize")
            Toggle("显示周六", isOn: settingsBinding(\.showSaturday))
                .accessibilityIdentifier("settings.toggle.saturday")
            Toggle("显示周日", isOn: settingsBinding(\.showSunday))
                .accessibilityIdentifier("settings.toggle.sunday")
            Toggle("显示主界面滑动条", isOn: settingsBinding(\.showWeekSlider))
                .accessibilityIdentifier("settings.toggle.weekSlider")
            Toggle("自动检查更新", isOn: settingsBinding(\.autoCheckUpdate))
                .accessibilityIdentifier("settings.toggle.autoCheckUpdate")
            Toggle("显示非本周课程", isOn: settingsBinding(\.showNonCurrentWeekCourses))
                .accessibilityIdentifier("settings.toggle.nonCurrentWeek")
            Toggle("显示上课时间", isOn: settingsBinding(\.showCourseTime))
                .accessibilityIdentifier("settings.toggle.courseTime")
            Toggle("显示上课地点", isOn: settingsBinding(\.showCourseLocation))
                .accessibilityIdentifier("settings.toggle.courseLocation")
            Toggle("显示授课老师", isOn: settingsBinding(\.showCourseTeacher))
                .accessibilityIdentifier("settings.toggle.courseTeacher")
        } header: {
            Text("显示选项")
        } footer: {
            Text(
                "全部开关立即生效并落盘：「深色模式」「优化模式」改整页与卡片配色"
                + "（「优化模式」把卡片改为黑白高对比、不再使用课表配色）；"
                + "「显示周六」「显示周日」增减网格列；「显示主界面滑动条」在课表上方显示 1…学期周数 的滑动条；"
                + "「显示非本周课程」关掉后不属于当周的课程不会出现在网格里；"
                + "「显示上课时间」「显示上课地点」「显示授课老师」控制展开卡片里的三行信息。"
                + "\n「自动检查更新」在 iOS 上只保存取值：App 更新走 App Store，"
                + "没有 Android 那种应用内检查更新的等价入口。"
            )
        }
    }

    // MARK: - ② 界面样式

    private var appearanceSection: some View {
        Section {
            backgroundRows
            sliderRow(
                "课程卡高度",
                keyPath: \.courseCellHeightDp,
                range: 40...120,
                suffix: "dp",
                identifier: "settings.slider.cellHeight"
            )
            sliderRow(
                "课程文字",
                keyPath: \.courseTextSizeSp,
                range: 7...30,
                suffix: "sp",
                identifier: "settings.slider.textSize"
            )
            sliderRow(
                "非本周透明度",
                keyPath: \.nonCurrentWeekCourseAlphaPercent,
                range: 0...100,
                step: 5,
                suffix: "%",
                identifier: "settings.slider.nonCurrentWeekAlpha"
            )
            sliderRow(
                "卡片透明度",
                keyPath: \.courseCardAlphaPercent,
                range: 0...100,
                step: 5,
                suffix: "%",
                identifier: "settings.slider.cardAlpha"
            )
            sliderRow(
                "卡片磨砂强度",
                keyPath: \.courseFrostedIntensityPercent,
                range: 0...100,
                step: 5,
                suffix: "%",
                identifier: "settings.slider.frosted"
            )

            VStack(alignment: .leading, spacing: 8) {
                Text("课表卡片预览")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                cardPreview
                    .accessibilityIdentifier("settings.preview.card")
                Text("预览用的就是网格里那张卡（`CourseCard`），尺寸、字号与配色实时跟随上面的滑动条变化。")
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
        .accessibilityIdentifier("settings.button.pickPhoto")

        Button("清除背景图（恢复默认）") {
            clearBackground()
        }
        .disabled(!settings.hasCustomBackground)
        .accessibilityIdentifier("settings.button.clearPhoto")

        VStack(alignment: .leading, spacing: 6) {
            TextField("手动输入图片地址", text: $manualImageAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .onSubmit(applyManualImageAddress)
                .accessibilityIdentifier("settings.field.imageAddress")
            Button("应用图片地址", action: applyManualImageAddress)
                .disabled(manualImageAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("settings.button.applyImageAddress")
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
    ///
    /// 例课取原版设置页预览用的那一门（`SettingsScreenKt.java:2675` 的
    /// `Course(1, "高等数学", "张明", "6号教学楼 A310", …)`）。改动任一滑动条，
    /// 这里的尺寸 / 字号 / 透明度 / 底色都会立刻跟着变。
    private var cardPreview: some View {
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
        suffix: String,
        identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text("\(settings[keyPath: keyPath]) \(suffix)")
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                    .accessibilityIdentifier("\(identifier).value")
            }
            Slider(value: intBinding(keyPath, range: range), in: Double(range.lowerBound)...Double(range.upperBound), step: Double(step))
                .accessibilityLabel(title)
                .accessibilityIdentifier(identifier)
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
