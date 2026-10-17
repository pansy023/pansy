import SwiftUI
import KebiaoCore

/// 「学期与时间」二级页（设置首页 → `NavigationLink`）。
///
/// 内容对应 Android 1.11.5 `SettingsScreenKt.java` 的「学期与时间」卡片：
/// - 「学期开始日期」`:1628`（`SettingValueRow`，点开弹日期选择器）；
/// - 「第一节开始时间」`:1683`；「每节时长」「课间时长」「一天课程节数」「学期周数」
///   `:1685-1901`；
/// - 「时间表名称」`:1926`（点开弹输入框 → `addTimetableProfile`，`:1959`）；
/// - 「编辑时间表」`:1975`：列出当前方案 `periodTimes`（按 `index` 升序，
///   `:2024-2029`），每行可改起止时间（原版逐行调 `updatePeriodTime`）。
///
/// iOS 侧的三处要点：
/// 1. 「学期开始日期」是**按钮 + 弹出日期选择器**，不是开关（用户明确要求）；
/// 2. `firstWeekStartDate` 的读写走 `WeekLogic.formatDate/parseDate`，
///    格式、时区、非宽松解析都与原版 `SimpleDateFormat("yyyy-MM-dd")` 对齐；
/// 3. 「一天课程节数」与「编辑时间表」的行数在 iOS 端**保持一致**，
///    Android 端两者独立（易踩坑见 `docs/recon/01-timetable-algorithms.md` §9.3）。
///    取舍理由写在 `save()` 上方。
///
/// 全部控件都是**草稿态**，点底部「保存设置」才落盘（原版同样是 pending + 保存）。
struct SemesterSettingsView: View {

    @EnvironmentObject private var environment: AppEnvironment

    private var store: TimetableStore { environment.store }

    // MARK: - 草稿

    /// 学期开始日期。`nil` = 未设置（与原版 `firstWeekStartDate: String?` 对齐）。
    @State private var draftSemesterStartDate: Date?
    @State private var draftFirstPeriodStartTime = Date()
    @State private var draftPeriodDurationMinutes = 45
    @State private var draftBreakDurationMinutes = 10
    @State private var draftPeriodsPerDay = 10
    @State private var draftSemesterWeeks = 20
    /// 「编辑时间表」的行；下标即行序，`PeriodTime.index` 只在保存时统一重编号。
    @State private var draftPeriodTimes: [PeriodTime] = []
    @State private var didLoadDraft = false

    // MARK: - 交互状态

    /// 正在展开编辑的行下标；`nil` 表示所有行都收起。
    @State private var expandedRow: Int?
    @State private var activeSheet: Modal?
    @State private var pickerStartDate = Date()
    @State private var newProfileName = ""
    @State private var notice: Notice?

    private enum Modal: String, Identifiable {
        case startDate
        case profileName
        var id: String { rawValue }
    }

    private struct Notice: Identifiable {
        let id = UUID()
        let text: String
    }

    var body: some View {
        Form {
            basicsSection
            periodTimesSection
            saveSection
        }
        .navigationTitle("学期与时间")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadDraftIfNeeded)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .startDate:
                startDateSheet
            case .profileName:
                profileNameSheet
            }
        }
        .alert(item: $notice) { item in
            Alert(title: Text("提示"), message: Text(item.text), dismissButton: .default(Text("好")))
        }
    }

    // MARK: - ① 基础信息

    private var basicsSection: some View {
        Section {
            // 「学期开始日期」：点击弹日期选择器（绝不做成开关）。
            Button {
                pickerStartDate = draftSemesterStartDate ?? Date()
                activeSheet = .startDate
            } label: {
                HStack {
                    Text("学期开始日期")
                        .foregroundColor(.primary)
                    Spacer(minLength: 12)
                    Text(draftSemesterStartDate.map { WeekLogic.formatDate($0, calendar: store.calendar) } ?? "未设置")
                        .foregroundColor(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
            }

            DatePicker(
                "第一节开始时间",
                selection: $draftFirstPeriodStartTime,
                displayedComponents: .hourAndMinute
            )

            stepperRow("每节时长", value: $draftPeriodDurationMinutes, range: 5...120, suffix: "分钟")
            stepperRow("课间时长", value: $draftBreakDurationMinutes, range: 0...60, suffix: "分钟")
            stepperRow(
                "一天课程节数",
                value: Binding(
                    get: { draftPeriodsPerDay },
                    set: { newValue in
                        draftPeriodsPerDay = newValue
                        resizePeriodRows(to: newValue)
                    }
                ),
                range: 1...20,
                suffix: "节"
            )
            stepperRow("学期周数", value: $draftSemesterWeeks, range: 1...30, suffix: "周")

            // 「时间表名称」：显示当前方案名；点开输入新名称 → 新增一套方案。
            Button {
                newProfileName = ""
                activeSheet = .profileName
            } label: {
                HStack {
                    Text("时间表名称")
                        .foregroundColor(.primary)
                    Spacer(minLength: 12)
                    Text(store.activeProfile.name)
                        .foregroundColor(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
            }
        } header: {
            // 组名对齐原版 `SettingsScreenKt.java:1489` 的 `SectionTitle("学期与时间")`。
            Text("学期与时间")
        } footer: {
            Text(
                "「第一节开始时间」「每节时长」「课间时长」「一天课程节数」只有当前时间表"
                + "没有逐节时间时才用来推算（原版 `generateTimeSlots`）；"
                + "有逐节时间时以「编辑时间表」里的为准。"
                + "\n「时间表名称」点开是新建一套作息方案（原版同名对话框「新建时间表名称」，"
                + "`SettingsScreenKt.java:1940`；留空则名为「新课表」，`:96-98`）。"
                + "⚠️ 原版新建后**不**自动切换，iOS 端沿用已有 `addTimetableProfile`"
                + "（它会选中新方案，便于立刻在下面编辑并看到效果）。"
            )
        }
    }

    private func stepperRow(
        _ title: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        suffix: String
    ) -> some View {
        Stepper(value: value, in: range) {
            HStack {
                Text(title)
                Spacer(minLength: 12)
                Text("\(value.wrappedValue) \(suffix)")
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
        }
    }

    // MARK: - ② 编辑时间表

    private var periodTimesSection: some View {
        Section {
            if draftPeriodTimes.isEmpty {
                Text("当前时间表还没有逐节时间")
                    .foregroundColor(.secondary)
            } else {
                ForEach(Array(draftPeriodTimes.indices), id: \.self) { index in
                    periodRow(index)
                }
            }
        } header: {
            Text("编辑时间表")
        } footer: {
            Text(
                "逐行列出当前时间表的每一节；点一行展开，用两个时间选择器改开始/结束时间。"
                + "\n共 \(draftPeriodTimes.count) 节，第一节 \(firstPeriodTimeText)。"
                + "\n⚠️ Android 端「编辑时间表」只列方案里已存的时间（可能为空），"
                + "iOS 端在方案为空时会按上面的「基础信息」先生成行，保证列表始终可见可编辑。"
            )
        }
    }

    /// 一行：折叠态显示「第 N 节 / 起-止」；展开后出现两个时间选择器。
    @ViewBuilder
    private func periodRow(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("第 \(index + 1) 节")
                Spacer(minLength: 12)
                Text("\(draftPeriodTimes[index].start) - \(draftPeriodTimes[index].end)")
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                Image(systemName: expandedRow == index ? "chevron.up" : "chevron.down")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                expandedRow = (expandedRow == index) ? nil : index
            }

            if expandedRow == index {
                DatePicker(
                    "开始时间",
                    selection: clockBinding(at: index, isStart: true),
                    displayedComponents: .hourAndMinute
                )
                DatePicker(
                    "结束时间",
                    selection: clockBinding(at: index, isStart: false),
                    displayedComponents: .hourAndMinute
                )
            }
        }
    }

    private var firstPeriodTimeText: String {
        guard let first = draftPeriodTimes.first else { return "—" }
        return "\(first.start) - \(first.end)"
    }

    // MARK: - ③ 保存

    private var saveSection: some View {
        Section {
            Button("保存设置") {
                save()
            }
        } footer: {
            Text(
                "「保存设置」把本页所有改动一次写入：学期开始日期、第一节开始时间、"
                + "每节时长、课间时长、一天课程节数、学期周数写进设置，"
                + "「编辑时间表」的逐节时间写回当前作息方案。"
                + "\n⚠️ iOS 端把「一天课程节数」与方案节数统一：保存后方案的"
                + "`periodsPerDay` 与设置里的同名值都会等于列表行数。"
            )
        }
    }

    /// 提交所有草稿。
    ///
    /// 两处**有意**的 iOS 取舍（都写在这里，避免以后被当成 bug）：
    /// 1. 「一天课程节数」与「编辑时间表」行数联动：改节数会即时增删行，
    ///    保存时同时写 `settings.periodsPerDay` 与方案 `periodsPerDay`，
    ///    让两者与可见列表自洽。Android 端这两个值互相独立，改节数不会动列表
    ///    （`docs/recon/01-timetable-algorithms.md` §9.3：只有方案 `periodTimes`
    ///    为空时才用 `settings` 那套参数生成）。
    /// 2. 方案 `periodTimes` 为空时，进入页面会先生成行，保存会把生成结果物化；
    ///    Android 端是每次读时现算。二者数据等价（生成结果相同），
    ///    只是 iOS 端把结果落盘，便于用户逐节编辑。
    private func save() {
        let startDateText = draftSemesterStartDate.map {
            WeekLogic.formatDate($0, calendar: store.calendar)
        }
        let firstPeriodText = clock(from: draftFirstPeriodStartTime)

        store.mutateSettings { settings in
            settings.firstWeekStartDate = startDateText
            settings.firstPeriodStartTime = firstPeriodText
            settings.periodDurationMinutes = draftPeriodDurationMinutes
            settings.breakDurationMinutes = draftBreakDurationMinutes
            settings.periodsPerDay = draftPeriodsPerDay
            settings.semesterWeeks = draftSemesterWeeks
        }

        // 逐节时间按行序重编号（1 起数）后写回当前方案。
        let normalized = draftPeriodTimes.enumerated().map { offset, period in
            PeriodTime(index: offset + 1, start: period.start, end: period.end)
        }
        var profiles = store.profiles
        if let index = profiles.firstIndex(where: { $0.id == store.activeProfile.id }) {
            profiles[index].periodTimes = normalized
            profiles[index].periodsPerDay = draftPeriodsPerDay
            store.saveTimetableProfiles(profiles)
        }

        notice = Notice(text: "设置已保存")
    }

    // MARK: - 两个弹层

    /// 学期开始日期：图形化日期选择器 + 取消 / 清除 / 完成。
    private var startDateSheet: some View {
        NavigationStack {
            DatePicker(
                "学期开始日期",
                selection: $pickerStartDate,
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .padding()
            .navigationTitle("学期开始日期")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { activeSheet = nil }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("清除日期") {
                        draftSemesterStartDate = nil
                        activeSheet = nil
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        draftSemesterStartDate = store.calendar.startOfDay(for: pickerStartDate)
                        activeSheet = nil
                    }
                }
            }
        }
    }

    /// 新建时间表名称：留空则用原版的「新课表」。
    private var profileNameSheet: some View {
        NavigationStack {
            Form {
                TextField("时间表名称", text: $newProfileName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .navigationTitle("新建时间表名称")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { activeSheet = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确定") { createProfile() }
                }
            }
        }
    }

    /// 新增一套作息方案。
    ///
    /// 名称留空取原版的 `"新课表"`；逐节时间沿用当前草稿（对齐
    /// `TimetableViewModel$addTimetableProfile$1.java:78-85`：新方案的
    /// `periodTimes` 是既有第一套的副本，而不是空表）。
    private func createProfile() {
        let trimmed = newProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "新课表" : trimmed
        store.addTimetableProfile(name: name, periods: normalizedDraftPeriodTimes())
        activeSheet = nil
    }

    // MARK: - 草稿装载

    /// 首次出现时把当前设置与当前方案的逐节时间灌进草稿；之后不再覆盖。
    private func loadDraftIfNeeded() {
        guard !didLoadDraft else { return }
        didLoadDraft = true

        let settings = store.settings
        draftSemesterStartDate = settings.firstWeekStartDate.flatMap {
            WeekLogic.parseDate($0, calendar: store.calendar)
        }
        draftFirstPeriodStartTime = date(fromClock: settings.firstPeriodStartTime)
        draftPeriodDurationMinutes = settings.periodDurationMinutes
        draftBreakDurationMinutes = settings.breakDurationMinutes
        draftSemesterWeeks = settings.semesterWeeks

        let rows = store.activeProfile.periodTimes.sorted { $0.index < $1.index }
        if rows.isEmpty {
            // 方案没有逐节时间：按 `settings` 的四个参数生成行，
            // 与 `TimeSlotLogic.effectiveTimeSlots` 的回落分支同源。
            draftPeriodTimes = TimeSlotLogic.generateTimeSlots(
                firstPeriodStartTime: settings.firstPeriodStartTime,
                periodDurationMinutes: settings.periodDurationMinutes,
                breakDurationMinutes: settings.breakDurationMinutes,
                periodsPerDay: settings.periodsPerDay
            ).enumerated().map { offset, slot in
                let parts = slot.components(separatedBy: TimeSlotLogic.separator)
                return PeriodTime(
                    index: offset + 1,
                    start: parts.first ?? "",
                    end: parts.count > 1 ? parts[1] : ""
                )
            }
            draftPeriodsPerDay = max(draftPeriodTimes.count, settings.periodsPerDay, 1)
        } else {
            draftPeriodTimes = rows
            draftPeriodsPerDay = max(rows.count, 1)
        }
    }

    /// 增删「编辑时间表」的行，使行数与「一天课程节数」一致。
    private func resizePeriodRows(to count: Int) {
        let target = min(max(count, 1), 20)
        if target < draftPeriodTimes.count {
            draftPeriodTimes = Array(draftPeriodTimes.prefix(target))
        }
        while draftPeriodTimes.count < target {
            draftPeriodTimes.append(nextPeriod())
        }
    }

    /// 追加一节：以上一节的结束时间 + 课间为开始，再走一个每节时长。
    /// 第一节没有前驱时用「第一节开始时间」。整点进位规则与
    /// `TimeSlotLogic.generateTimeSlots` 相同（不取模 24）。
    private func nextPeriod() -> PeriodTime {
        let startMinutes: Int
        if let last = draftPeriodTimes.last {
            startMinutes = minutes(fromClock: last.end) + draftBreakDurationMinutes
        } else {
            startMinutes = minutes(fromClock: clock(from: draftFirstPeriodStartTime))
        }
        let endMinutes = startMinutes + draftPeriodDurationMinutes
        return PeriodTime(
            index: draftPeriodTimes.count + 1,
            start: clock(totalMinutes: startMinutes),
            end: clock(totalMinutes: endMinutes)
        )
    }

    private func normalizedDraftPeriodTimes() -> [PeriodTime] {
        draftPeriodTimes.enumerated().map { offset, period in
            PeriodTime(index: offset + 1, start: period.start, end: period.end)
        }
    }

    // MARK: - 时间字符串 ↔ Date

    /// 行内「开始/结束时间」↔ 该行的草稿值。
    ///
    /// `get` 把 `"HH:mm"` 变成 `DatePicker` 需要的 `Date`；`set` 再写成
    /// 两位补零的 `"HH:mm"`。下标做越界保护：数组被增删后，旧的绑定不会越界。
    private func clockBinding(at index: Int, isStart: Bool) -> Binding<Date> {
        Binding(
            get: {
                guard draftPeriodTimes.indices.contains(index) else { return Date() }
                let value = isStart ? draftPeriodTimes[index].start : draftPeriodTimes[index].end
                return date(fromClock: value)
            },
            set: { newValue in
                guard draftPeriodTimes.indices.contains(index) else { return }
                let text = clock(from: newValue)
                if isStart {
                    draftPeriodTimes[index].start = text
                } else {
                    draftPeriodTimes[index].end = text
                }
            }
        )
    }

    /// `"08:10"` → 只带「时:分」的 `Date`（年月日取日历默认，选择器不显示日期）。
    private func date(fromClock value: String) -> Date {
        var components = DateComponents()
        components.hour = Int(value.components(separatedBy: ":").first ?? "") ?? 8
        let parts = value.components(separatedBy: ":")
        components.minute = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
        return store.calendar.date(from: components) ?? Date()
    }

    /// `Date` → `"HH:mm"`（两位补零，与原版 `String.format("%02d:%02d")` 一致）。
    private func clock(from date: Date) -> String {
        let components = store.calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }

    /// `"08:10"` → 自 0 点起的分钟数。
    private func minutes(fromClock value: String) -> Int {
        let parts = value.components(separatedBy: ":")
        let hour = Int(parts.first ?? "") ?? 8
        let minute = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
        return hour * 60 + minute
    }

    /// 分钟数 → `"HH:mm"`；不取模 24（与 `TimeSlotLogic.generateTimeSlots` 一致）。
    private func clock(totalMinutes: Int) -> String {
        String(format: "%02d:%02d", totalMinutes / 60, totalMinutes % 60)
    }
}

#if DEBUG
struct SemesterSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            SemesterSettingsView()
        }
        .environmentObject(
            AppEnvironment(store: TimetableStore(repository: InMemoryTimetableRepository()))
        )
    }
}
#endif
