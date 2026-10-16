import SwiftUI
import KebiaoCore

/// 根视图：`NavigationStack` + 课表主页，并在**这一处**统一呈现课程编辑弹窗。
///
/// 导航栏两个入口，对应原版 `MainActivity` 里用得上、且本阶段已实现的功能：
/// - 左上「设置」→ `SettingsView`（对应原版 `SettingsScreen`）。
/// - 右上「＋」→ 新增课程（原版从抽屉 / 设置页进的 `AddCourseScreen`）。
///
/// 编辑弹窗只在这里挂一次：`AppEnvironment.editorRequest` 是唯一入口，
/// 网格卡片点「更多」与右上「＋」写的是同一个状态，不会出现两层弹窗互相盖住。
///
/// 不做空数据特判的原因：`TimetableStore` 在无数据时的派生值都是合法的
/// （`courses == []`、`periodCount >= 1`、`visibleWeekdays` 由 `weekDates` 推出，
/// 见 `KebiaoCore/Sources/KebiaoCore/Store/TimetableStore.swift:120-186`），
/// 网格画出来就是一张空表，不需要额外的「无数据」分支。
struct RootView: View {

    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        NavigationStack {
            TimetableView()
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        NavigationLink {
                            SettingsView()
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("设置")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            environment.editorRequest = .create
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("添加课程")
                    }
                }
        }
        // `CourseEditorView.Mode` 是 `Identifiable`，闭包退出时 SwiftUI 会自动把
        // `editorRequest` 写回 nil；编辑器里的「取消 / 保存 / 删除」都走 `dismiss()`。
        .sheet(item: $environment.editorRequest) { mode in
            NavigationStack {
                CourseEditorView(mode: mode)
            }
        }
    }
}

#if DEBUG
struct RootView_Previews: PreviewProvider {
    static var previews: some View {
        RootView()
            .environmentObject(
                AppEnvironment(
                    // 预览不落盘：用一个内存仓库，避免预览进程写入真实 UserDefaults。
                    store: TimetableStore(repository: InMemoryTimetableRepository())
                )
            )
    }
}
#endif
