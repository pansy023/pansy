import SwiftUI
import KebiaoCore

/// 「添加课程 / 编辑课程」二级页面。
///
/// 字段与文案**逐条**取自 Android 1.11.5 的反编译产物：
/// - 标题「添加课程」/「编辑课程」：`AddCourseScreenKt.java:362`
/// - 文本框标签「课程名称」「教师」「地点」：
///   `ComposableSingletons$AddCourseScreenKt.java:71` / `:94` / `:117`
/// - 下拉标签「星期」「开始节数」「结束节数」「周次起」「周次止」「单双周」：
///   `AddCourseScreenKt.java:659` / `:867` / `:937` / `:1077` / `:1147` / `:1192`
/// - 候选值：星期「周一」…「周日」`:294`；单双周「全周」「单周」「双周」`:303`
/// - 保存按钮「添加课程」/「保存修改」`:1456`；删除「删除此课程」
///   `ComposableSingletons$AddCourseScreenKt.java:164`（点击调 `deleteCourse`，`:1482`）
///
/// **没有颜色选择**：1.9.0 起原版已把 8 个颜色圆点连同标题一并移除
/// （`CHANGELOG.md:201-203`），所以 iOS 版也不提供；配色由 `MorandiPalette` 按课程名生成。
///
/// 三处**刻意**照抄的原版行为（都是取证得到的，不是笔误）：
/// 1. 新课程的 `weekRange` 取反编译出的初值 `"1-16周"`
///    （`AddCourseScreenKt.java:249`），它确实被当作 `Course` 的第 9 个实参传下去
///    （`:1431`）。`WeekLogic.courseOccursInWeek` 会**同时**用 `startWeek`/`endWeek`
///    与 `weekRange` 判周次，因此新建课程默认第 17 周以后不上课 —— 与 Android 一致。
///    编辑已有课程时原样保留其 `weekRange`，不做任何改写。
/// 2. 新课程的 `color` 取 `-10354454`（紫色，`AddCourseScreenKt.java:258`）。
///    该值同样会被写进 `Course`（`:1431` 第 8 个实参）。未开启「优化模式」时配色实际由
///    `MorandiPalette` 决定，这个字段不参与显示。
/// 3. 保存前的钳制：课程名空则**直接不保存**（`:1400-1402` 的提前 `return`）、
///    `endPeriod` 被抬到不小于 `startPeriod`（`:1404-1406` 的 `coerceAtLeast`）、
///    `isOdd` 被夹到 `0...2`（`:1431` 的 `coerceIn`）。iOS 端把「名称为空」表现成
///    保存按钮置灰（同样的规则、更明确的反馈），其余钳制在做改变时同步施加。
struct CourseEditorView: View {

    /// 由 `AppEnvironment.editorRequest` 承载，所以需要 `Identifiable`
    /// 才能直接喂给 `.sheet(item:)`。
    enum Mode: Identifiable {
        case create
        case edit(Course)

        /// 新增用固定 id；编辑用课程 id —— 同一门课重复请求时 sheet 不会重挂。
        var id: String {
            switch self {
            case .create: return "create"
            case let .edit(course): return "edit-\(course.id)"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var environment: AppEnvironment

    private let mode: Mode
    @State private var draft: Course
    @State private var showsDeleteConfirmation = false

    /// 与 `AddCourseScreenKt.java:294` 的候选列表逐字一致。
    private static let weekdayNames = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
    /// 与 `AddCourseScreenKt.java:303` 的候选列表逐字一致。
    private static let parityNames = ["全周", "单周", "双周"]

    init(mode: Mode) {
        self.mode = mode
        switch mode {
        case .create:
            // 初值全部来自 `AddCourseScreenKt.java` 的 `remember` 块：
            // 开始节数 1（`:233` 的 i3 在新增路径下为 1）、结束节数 2（`:241`）、
            // weekRange "1-16周"（`:249`）、color 紫色（`:258`）、
            // 周次起 1（`:266`）、周次止 20（`:275`）、单双周 0（`:286`）。
            _draft = State(initialValue: Course(
                name: "",
                teacher: "",
                location: "",
                dayOfWeek: 1,
                startPeriod: 1,
                endPeriod: 2,
                color: -10354454,
                weekRange: "1-16周",
                startWeek: 1,
                endWeek: 20,
                isOdd: 0
            ))
        case let .edit(course):
            _draft = State(initialValue: course)
        }
    }

    private var store: TimetableStore { environment.store }
    private var settings: AppSettings { store.settings }
    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    /// 节次下拉的上界。取「网格实际行数」与该课程已用节次的最大值，
    /// 保证课程自身保存的节次永远可选，不因为作息方案被改小而选不回来。
    private var periodRange: ClosedRange<Int> {
        let upper = max(store.periodCount, draft.endPeriod, draft.startPeriod, 1)
        return 1...max(upper, 2)
    }

    /// 周次下拉的上界。取学期周数与该课程已用周次的最大值，理由同上。
    private var weekRange: ClosedRange<Int> {
        let upper = max(settings.semesterWeeks, draft.endWeek, draft.startWeek, 1)
        return 1...max(upper, 20)
    }

    private var canSave: Bool {
        // `AddCourseScreenKt.java:1400-1402`：课程名为空时原版直接 return，不落库。
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("课程名称") {
                    TextField("必填", text: $draft.name)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("教师") {
                    TextField("可留空", text: $draft.teacher)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("地点") {
                    TextField("可留空", text: $draft.location)
                        .multilineTextAlignment(.trailing)
                }
            }

            Section {
                Picker("星期", selection: $draft.dayOfWeek) {
                    // 索引 0…6 对应 dayOfWeek 1…7（`Course.dayOfWeek` 的取值约定）。
                    ForEach(Array(Self.weekdayNames.enumerated()), id: \.offset) { index, name in
                        Text(name).tag(index + 1)
                    }
                }

                Picker("开始节数", selection: $draft.startPeriod) {
                    ForEach(periodRange, id: \.self) { period in
                        Text("第 \(period) 节").tag(period)
                    }
                }
                .onChange(of: draft.startPeriod) { _, newValue in
                    // `:1404-1406` 的 `coerceAtLeast(endPeriod, startPeriod)`。
                    if draft.endPeriod < newValue { draft.endPeriod = newValue }
                }

                Picker("结束节数", selection: $draft.endPeriod) {
                    ForEach(draft.startPeriod...periodRange.upperBound, id: \.self) { period in
                        Text("第 \(period) 节").tag(period)
                    }
                }
            } header: {
                Text("上课时间")
            }

            Section {
                Picker("周次起", selection: $draft.startWeek) {
                    ForEach(weekRange, id: \.self) { week in
                        Text("第 \(week) 周").tag(week)
                    }
                }
                .onChange(of: draft.startWeek) { _, newValue in
                    if draft.endWeek < newValue { draft.endWeek = newValue }
                }

                Picker("周次止", selection: $draft.endWeek) {
                    ForEach(draft.startWeek...weekRange.upperBound, id: \.self) { week in
                        Text("第 \(week) 周").tag(week)
                    }
                }

                Picker("单双周", selection: $draft.isOdd) {
                    ForEach(Array(Self.parityNames.enumerated()), id: \.offset) { index, name in
                        Text(name).tag(index)
                    }
                }
            } header: {
                Text("周次")
            } footer: {
                Text("周次还会受导入时的周次描述（weekRange=\(draft.weekRange)）约束；该字段不在手机上编辑。")
            }

            if isEditing {
                Section {
                    Button("删除此课程", role: .destructive) {
                        showsDeleteConfirmation = true
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
        .navigationTitle(isEditing ? "编辑课程" : "添加课程")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isEditing ? "保存修改" : "添加课程") { save() }
                    .disabled(!canSave)
            }
        }
        .confirmationDialog(
            "删除「\(draft.name)」？",
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除此课程", role: .destructive) {
                store.deleteCourse(draft)
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("原版点该按钮会直接删除；iOS 端多加一次确认，避免误触后无法撤销。")
        }
    }

    private func save() {
        guard canSave else { return }
        // `Course.isOdd` 的合法区间由 `:1431` 的 `coerceIn(..., 0, 2)` 与
        // `Course.WeekParity` 一起保证；这里再夹一次，防止后续 UI 改动绕过 Picker。
        draft.isOdd = min(max(draft.isOdd, 0), 2)
        switch mode {
        case .create:
            // `insertCourse` 内部会用 `courses.count + 1` 覆盖 id（原版怪癖，
            // 见 `TimetableViewModel$insertCourse$1.java:63`）。
            store.insertCourse(draft)
        case .edit:
            store.updateCourse(draft)
        }
        dismiss()
    }
}

#if DEBUG
struct CourseEditorView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            CourseEditorView(mode: .create)
        }
        .environmentObject(
            AppEnvironment(store: TimetableStore(repository: InMemoryTimetableRepository()))
        )
    }
}
#endif
