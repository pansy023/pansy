import SwiftUI
import KebiaoCore

/// 设置页。文案与分组取自 Android 1.11.5 的 `SettingsScreenKt.java`：
/// 组名「学期与时间」`:1103` / `:1132`、组名「显示与样式」`:1160`。
///
/// 本页只放**已经确认在 iOS 侧真正生效**的项：每一项写下去都能在界面上看到变化
/// （学期开始日期 → 当前周次；学期周数 → 周次上下界；开关 → `TimetableStore` 的派生值
/// 与 `CourseCardStyle` 的观感）。原版「显示与样式」里的其余项（背景图、磨砂强度、
/// 卡片高度/字号、时间表管理等）留到后续阶段，**不在这里放一个点了没反应的开关**。
///
/// 逐字沿用原版标签：
/// - 「学期开始日期」`:1628`、值「未设置」`:1626`、行内以 `yyyy-MM-dd` 字符串存取
/// - 「学期周数」`:1901`（原版是文本输入框，见 `:395` 的 `String.valueOf(...)`；
///   iOS 用 Stepper 收窄到 1…60，避免输入非法值）
/// - 「深色模式」`:2150`、「优化模式」`:2151`、「显示周六」`:2177`、「显示周日」`:2204`、
///   「显示非本周课程」`:2282`、「显示上课时间」`:2308`、「显示上课地点」`:2334`、
///   「显示授课老师」`:2360`、「非本周透明度」`:2577`、「卡片透明度」`:2606`
struct SettingsView: View {

    @EnvironmentObject private var environment: AppEnvironment

    private var store: TimetableStore { environment.store }
    private var settings: AppSettings { store.settings }

    var body: some View {
        Form {
            semesterSection
            appearanceSection
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 学期与时间

    private var semesterSection: some View {
        Section {
            Toggle("设置学期开始日期", isOn: hasSemesterStartBinding)

            if hasSemesterStartBinding.wrappedValue {
                DatePicker(
                    "学期开始日期",
                    selection: semesterStartBinding,
                    displayedComponents: .date
                )
            }

            Stepper(value: semesterWeeksBinding, in: 1...60) {
                LabeledContent("学期周数") {
                    Text("\(settings.semesterWeeks) 周").monospacedDigit()
                }
            }
        } header: {
            Text("学期与时间")
        } footer: {
            Text(
                "未设置开始日期时当前周次恒为第 1 周（与原版 `getCurrentTeachingWeek` 一致）。"
                + "学期周数会把当前周次夹在 1…N 之间，也决定课程编辑页「周次止」的上界。"
            )
        }
    }

    // MARK: - 显示与样式

    private var appearanceSection: some View {
        Section {
            Toggle("深色模式", isOn: darkThemeBinding)
            Toggle("优化模式", isOn: optimizeModeBinding)
            Toggle("显示周六", isOn: settingsBinding(\.showSaturday))
            Toggle("显示周日", isOn: settingsBinding(\.showSunday))
            Toggle("显示非本周课程", isOn: settingsBinding(\.showNonCurrentWeekCourses))

            if settings.showNonCurrentWeekCourses {
                percentSliderRow("非本周透明度", keyPath: \.nonCurrentWeekCourseAlphaPercent)
            }

            Toggle("显示上课时间", isOn: settingsBinding(\.showCourseTime))
            Toggle("显示上课地点", isOn: settingsBinding(\.showCourseLocation))
            Toggle("显示授课老师", isOn: settingsBinding(\.showCourseTeacher))

            percentSliderRow("卡片透明度", keyPath: \.courseCardAlphaPercent)
        } header: {
            Text("显示与样式")
        } footer: {
            Text(
                "「优化模式」把卡片改成黑白高对比、不再使用课程配色。"
                + "「显示非本周课程」关掉时，不属于当前周的课不会画在网格里（与原版一致）；"
                + "打开后它们仍会出现，只是按「非本周透明度」变淡。"
                + "背景图、磨砂强度、卡片高度/字号、作息时间表管理尚未接入。"
            )
        }
    }

    // MARK: - 绑定

    /// `Date` ↔ `settings.firstWeekStartDate`（`"yyyy-MM-dd"` 字符串）。
    /// 换日期格式统一走 `WeekLogic.formatDate/parseDate`，不在视图里另写一套 formatter。
    private var semesterStartBinding: Binding<Date> {
        Binding(
            get: {
                if let raw = settings.firstWeekStartDate,
                   let date = WeekLogic.parseDate(raw) {
                    return date
                }
                // 未设置时 DatePicker 仍要有个值可显示，取今天。
                return Date()
            },
            set: { newValue in
                store.mutateSettings { $0.firstWeekStartDate = WeekLogic.formatDate(newValue) }
            }
        )
    }

    /// 是否已设置学期开始日期。关掉即写回 nil（原版对应空白串 / 无键，两种都落到第 1 周）。
    private var hasSemesterStartBinding: Binding<Bool> {
        Binding(
            get: {
                guard let raw = settings.firstWeekStartDate else { return false }
                return WeekLogic.parseDate(raw) != nil
            },
            set: { newValue in
                store.mutateSettings { settings in
                    settings.firstWeekStartDate = newValue ? WeekLogic.formatDate(Date()) : nil
                }
            }
        )
    }

    /// 学期周数。下限 1 与 `WeekLogic.teachingWeek` 的 `max(semesterWeeks, 1)` 一致。
    private var semesterWeeksBinding: Binding<Int> {
        Binding(
            get: { settings.semesterWeeks },
            set: { newValue in
                store.mutateSettings { $0.semesterWeeks = max(newValue, 1) }
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

    /// `AppSettings` 里某个 `Bool` 字段 ↔ `Toggle`。
    private func settingsBinding(_ keyPath: WritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { newValue in
                store.mutateSettings { $0[keyPath: keyPath] = newValue }
            }
        )
    }

    /// 百分比字段 ↔ `Slider`（0…100，步长 5）。存的是整数，显示也是整数。
    private func percentBinding(_ keyPath: WritableKeyPath<AppSettings, Int>) -> Binding<Double> {
        Binding(
            get: { Double(settings[keyPath: keyPath]) },
            set: { newValue in
                let percent = min(max(Int(newValue.rounded()), 0), 100)
                store.mutateSettings { $0[keyPath: keyPath] = percent }
            }
        )
    }

    /// 一行「标签 + 当前百分比 + 滑块」。
    private func percentSliderRow(
        _ title: String,
        keyPath: WritableKeyPath<AppSettings, Int>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text("\(settings[keyPath: keyPath])%")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: percentBinding(keyPath), in: 0...100, step: 5)
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
