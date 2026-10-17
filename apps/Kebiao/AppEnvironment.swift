import Combine
import Foundation
import SwiftUI
import KebiaoCore

/// App 层的依赖容器。
///
/// 存在的理由：`KebiaoCore` 只提供「一个 `TimetableStore` + 一个 `TimetableRepository`」，
/// 而 App 还想要服务/工具这类横切依赖（阶段④ 的教务客户端、阶段⑤ 的编辑器）。
/// 先把「谁拥有 store」这条边界定下来，后面加依赖不必再改 `KebiaoApp` 的签名。
///
/// 唯一的硬性内容就是 `store`：界面全部通过 `.environmentObject(environment)` →
/// `@EnvironmentObject var env: AppEnvironment` 取到它，**不再**另起第二个状态源
/// （原版七个 `MutableStateFlow` 已经收在 `TimetableStore` 里）。
@MainActor
final class AppEnvironment: ObservableObject {

    /// 全局唯一状态源。`@MainActor` 隔离在 `TimetableStore` 的类型上
    /// （`KebiaoCore/Sources/KebiaoCore/Store/TimetableStore.swift:23-24`），
    /// 所以本类型也标 `@MainActor`，视图层不允许在别处改它。
    let store: TimetableStore

    /// 「添加课程 / 编辑课程」的展示请求。
    ///
    /// 卡片可能出现在网格里、展开浮层里，将来还会出现在别处；把「要打开哪一门课」
    /// 收成一个可空状态，由 `RootView` 一处 `.sheet(item:)` 统一呈现，
    /// 视图层就不必各自持有 sheet 状态、也不会出现两层弹窗互相盖住。
    ///
    /// 写 `nil` 即关闭；`CourseEditorView` 保存/删除后会自己 `dismiss()`，
    /// 由 `.sheet(item:)` 的回调把这里清回 `nil`。
    @Published var editorRequest: CourseEditorView.Mode?

    /// `store` 变更的转发订阅。见 `init` 里的说明。
    private var storeObservation: AnyCancellable?

    /// - Parameter store: 注入的 store。测试 / 预览可以传一个用
    ///   `InMemoryTimetableRepository` 构造的实例。
    init(store: TimetableStore) {
        self.store = store
        // ⚠️ 必须转发，否则整个界面不会刷新。
        //
        // 八个视图（`RootView` / `TimetableView` / `TimetableGrid` / `WeekSwitcher` /
        // `CourseEditorView` / `SettingsView` / `AccountSyncSettingsView` /
        // `SemesterSettingsView`）拿数据的写法都是
        // `@EnvironmentObject private var environment: AppEnvironment` +
        // `environment.store`。而 `@EnvironmentObject` 只订阅 `AppEnvironment`
        // **自身**的 `objectWillChange` —— `TimetableStore` 的 `courses` / `settings` /
        // `uiFlags` / `weekOffset` 都是它**自己**的 `@Published`，变更时只会触发
        // `TimetableStore.objectWillChange`，没有任何视图订阅它。
        //
        // 症状：点「上一周 / 下一周」翻周、拨「深色模式 / 优化模式」或任一设置开关、
        // 拖设置页滑条 —— 数据其实已经写进 store 并落盘，但界面一个字都不变，
        // 看起来就是「按钮点了没反应」「开关切不动」。
        //
        // 之所以看着「有时候又是好的」：`CourseEditorView` 保存后 `dismiss()`、
        // `SemesterSettingsView` 保存后设本地 `notice`（`@State`），这些**视图自己的**
        // 状态变化会顺带触发一次重绘，把 store 的新值带出来 —— 那是偶然，不是设计。
        storeObservation = store.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    /// App 运行时使用的构造方式：真实持久化实现。
    ///
    /// `UserDefaultsTimetableRepository` 的默认参数就是
    /// `UserDefaults.standard` + `KeychainCredentialStore()`
    /// （`KebiaoCore/Sources/KebiaoCore/Storage/UserDefaultsTimetableRepository.swift:240-246`），
    /// 与 Android 端 `LocalStorage` 的键名逐字一致；密码进钥匙串，不进偏好设置。
    ///
    /// 读取失败不会抛错：`TimetableStore.init` 会把失败记进 `lastError` 并回落到出厂值
    /// （`TimetableStore.swift:72-97`），所以这里不需要 `try`。
    static func live() -> AppEnvironment {
        AppEnvironment(
            store: TimetableStore(repository: UserDefaultsTimetableRepository())
        )
    }
}
