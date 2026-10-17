import Combine
import XCTest
import KebiaoCore
@testable import Kebiao

/// App 宿主模块（`Kebiao`）的单元测试。
///
/// ## 为什么需要这一层
/// `KebiaoCore` 的 `swift test` 跑的是**纯逻辑包**：它不编译 App、也看不到
/// `AppEnvironment`。而本次审计里最致命的那条缺陷（P0-1：
/// `AppEnvironment` 没有转发 `TimetableStore.objectWillChange` → 翻周 / 深色开关 /
/// 所有设置项在界面上都不刷新，看起来就是「按钮点了没反应」）**只存在于 App 层**。
/// 因此它必须由宿主 App 里的测试守住 —— `swift test` 无论在哪个平台跑都覆盖不到。
///
/// ## 这些用例能证明什么、不能证明什么
/// - 能证明：store 发生变更时，`AppEnvironment` 自己也会发出 `objectWillChange`，
///   并且变更**确实写进了仓库**（落盘）。这是「界面为什么能刷新」的机制性证据。
/// - **不能**证明：像素层面真的重绘了、深色配色真的变暗了 ——
///   那属于 XCUITest（`apps/KebiaoUITests/DarkModeUITests.swift`，用整屏亮度采样验证）。
@MainActor
final class AppEnvironmentTests: XCTestCase {

    /// 造一个不碰任何持久化的环境：内存仓库 + 真实 `TimetableStore` + 真实 `AppEnvironment`。
    private func makeEnvironment() -> (environment: AppEnvironment, repository: InMemoryTimetableRepository) {
        let repository = InMemoryTimetableRepository()
        let environment = AppEnvironment(store: TimetableStore(repository: repository))
        return (environment, repository)
    }

    /// P0-1 的回归防线：store 的变更**必须**被转发成 `AppEnvironment.objectWillChange`。
    ///
    /// 去掉 `AppEnvironment.init` 里的 `store.objectWillChange.sink { … }` 这行，
    /// 本用例就会失败 —— 这正是修复前整个应用「点什么都没反应」的根因。
    func testStoreChangeIsForwardedToEnvironmentObjectWillChange() {
        let (environment, _) = makeEnvironment()

        var forwarded = 0
        let observation = environment.objectWillChange.sink { _ in forwarded += 1 }

        XCTAssertEqual(forwarded, 0, "只是构造环境、还没改任何数据，不该有任何转发")

        environment.store.shiftWeek(by: 1)

        XCTAssertEqual(environment.store.weekOffset, 1, "翻周必须真的写进 store")
        XCTAssertEqual(
            forwarded, 1,
            "store.weekOffset 是 TimetableStore 自己的 @Published，变更只触发 store.objectWillChange；"
                + "AppEnvironment 若不转发，视图就收不到通知、界面不会刷新"
        )

        withExtendedLifetime(observation) {}
    }

    /// 深色模式这条链路（用户明确报告的「开关切不动」）：
    /// 开关值要真的写进 store **且**落盘，同时要被转发出去让界面重绘。
    func testDarkThemeFlagIsForwardedToEnvironmentAndPersisted() {
        let (environment, repository) = makeEnvironment()

        var forwarded = 0
        let observation = environment.objectWillChange.sink { _ in forwarded += 1 }

        environment.store.updateUIFlags(UIFlags(isDarkTheme: true, isOptimizeMode: false))

        XCTAssertTrue(environment.store.uiFlags.isDarkTheme, "深色开关必须真的写进 store")
        XCTAssertGreaterThanOrEqual(forwarded, 1, "写入必须被转发成 AppEnvironment.objectWillChange")
        XCTAssertTrue(repository.uiFlags.isDarkTheme, "必须落盘（重启后要读得回来）")
        XCTAssertEqual(repository.saveCounts["uiFlags"], 1, "落盘要走仓库的 saveUIFlags，且只写一次")

        withExtendedLifetime(observation) {}
    }

    /// 反过来的方向也要成立：关掉深色时同样写入 + 落盘 + 转发。
    /// （防止「只有打开那一次生效」这类只测单向的假通过。）
    func testTurningDarkThemeBackOffIsAlsoPersisted() {
        let (environment, repository) = makeEnvironment()

        environment.store.updateUIFlags(UIFlags(isDarkTheme: true, isOptimizeMode: false))
        environment.store.updateUIFlags(UIFlags(isDarkTheme: false, isOptimizeMode: false))

        XCTAssertFalse(environment.store.uiFlags.isDarkTheme)
        XCTAssertFalse(repository.uiFlags.isDarkTheme)
        XCTAssertEqual(repository.saveCounts["uiFlags"], 2)
    }
}
