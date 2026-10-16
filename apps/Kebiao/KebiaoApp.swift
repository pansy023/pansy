import SwiftUI
import KebiaoCore

/// 应用入口。
///
/// 与原版 `MainActivity` 的对应关系：Android 侧 `setContent { KebiaoApp() }` 里挂着
/// 主题（深浅色 / 自定义背景）与一个 `Scaffold`；iOS 侧对应 `WindowGroup { RootView() }`
/// 加一层 `.preferredColorScheme(...)`。
///
/// `AppEnvironment` 在这里创建一次并注入全局：
/// - `TimetableStore` 是 `@MainActor` 的 `ObservableObject`，**只允许有一个实例**，
///   否则两个实例会各自读写同一份 `UserDefaults`，界面互相看不见对方的改动。
/// - `App` 的 `init` 与 body 都在主 actor 上执行，所以在此处构造 `@MainActor` 的 store 是安全的。
@main
struct KebiaoApp: App {

    /// `@StateObject` 保证生命周期与 App 一致：视图重建不会重新读盘。
    ///
    /// 这里直接 `static func live()` 拿真实持久化实现
    /// （`UserDefaultsTimetableRepository` + Keychain，见 `AppEnvironment.live()`）。
    @StateObject private var environment = AppEnvironment.live()

    private var store: TimetableStore { environment.store }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(environment)
                // 深浅色由设置决定，而不是跟随系统：原版主题是用户显式开关
                // （`TimetableStore.uiFlags.isDarkTheme`，落盘键 `uiDarkMode`），
                // 跟随系统会让用户在设置页里的「深色」开关失效。
                .preferredColorScheme(store.uiFlags.isDarkTheme ? .dark : .light)
                // 自定义背景图交给阶段④ 的「背景」设置页；阶段③ 只用页面底色，
                // 所以这里先不 `.ignoresSafeArea()`，让 NavigationStack 自己拿安全区。
                .background(Theme.pageBackground(dark: store.uiFlags.isDarkTheme))
        }
    }
}
