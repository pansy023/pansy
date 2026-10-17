import XCTest

/// 测试二：深色模式。
///
/// 这是本轮最关键的回归用例：修复前设置页的开关与整屏配色都不会跟着状态变，
/// 本用例会**真的失败**（不是警告），修复后才会通过。
///
/// 三步都做齐，缺一不可：
/// 1. 开关状态本身要变（`switch.value` 从 0→1→0）；
/// 2. 界面的**实际配色**要变（对比整屏平均亮度，而不是只看开关）；
/// 3. 重启后按设计保存（`uiDarkMode` 落盘）。
final class DarkModeUITests: KebiaoUITestCase {

    func testDarkModeToggleChangesStateAndActualAppearance() {
        openSettings()

        let toggle = app.switches["settings.toggle.dark"]
        XCTAssertTrue(toggle.waitForExistence(timeout: defaultTimeout), "设置页找不到深色模式开关")
        scrollUntilHittable(toggle)
        XCTAssertTrue(toggle.isHittable, "深色模式开关不可点")
        let original = isOn(toggle)

        // 先把开关确定地置为「关」。
        if isOn(toggle) { tapToggle(toggle) }
        XCTAssertTrue(waitForValue(toggle, "0"), "深色模式开关无法关闭（开关状态没有随点击变化）")
        attachScreenshot("dark-off-settings")
        let lightBrightness = screenBrightness()

        // 打开深色模式：开关状态必须变，界面配色也必须真的变暗。
        tapToggle(toggle)
        XCTAssertTrue(waitForValue(toggle, "1"), "深色模式开关无法打开（开关状态没有随点击变化）")
        attachScreenshot("dark-on-settings")
        let darkBrightness = screenBrightness()

        XCTAssertLessThan(
            darkBrightness,
            lightBrightness - 0.10,
            "深色模式开关已打开，但界面平均亮度几乎没变"
            + "（关=\(lightBrightness) → 开=\(darkBrightness)）：说明只有开关变色，整屏配色没有跟着变"
        )

        // 再点一次必须能恢复。
        tapToggle(toggle)
        XCTAssertTrue(waitForValue(toggle, "0"), "深色模式开关无法恢复为关闭")
        XCTAssertGreaterThan(
            screenBrightness(),
            darkBrightness + 0.10,
            "关闭深色模式后界面没有变回亮色"
        )

        // 收尾：恢复到用例开始前的状态。
        if original { tapToggle(toggle) }
    }

    func testDarkModePersistsAcrossRelaunch() {
        openSettings()

        let toggle = app.switches["settings.toggle.dark"]
        XCTAssertTrue(toggle.waitForExistence(timeout: defaultTimeout), "设置页找不到深色模式开关")
        let original = isOn(toggle)

        if isOn(toggle) { tapToggle(toggle) }
        XCTAssertTrue(waitForValue(toggle, "1"), "无法打开深色模式")

        app.terminate()
        app.launch()
        XCTAssertTrue(mainScreenIsVisible(), "重启后主界面没有出现")

        openSettings()
        let again = app.switches["settings.toggle.dark"]
        XCTAssertTrue(again.waitForExistence(timeout: defaultTimeout), "重启后设置页找不到深色模式开关")
        XCTAssertTrue(isOn(again), "重启后深色模式没有按设计保存（uiDarkMode 没有落盘）")

        // 收尾：恢复到用例开始前的状态，避免污染其它用例。
        if !original { tapToggle(again) }
    }

    /// 外观跟随策略：原版是**用户显式开关**，不跟随系统（`KebiaoApp` 里注释已说明）。
    /// 所以即使把系统外观强制成深色，开关关闭时界面也必须是亮色。
    func testAppearanceDoesNotFollowSystemWhenToggleIsOff() {
        openSettings()

        let toggle = app.switches["settings.toggle.dark"]
        XCTAssertTrue(toggle.waitForExistence(timeout: defaultTimeout))
        let original = isOn(toggle)

        if isOn(toggle) { tapToggle(toggle) }
        XCTAssertTrue(waitForValue(toggle, "0"), "无法关闭深色模式")

        app.terminate()
        app.launchArguments = ["-AppleInterfaceStyle", "Dark"]
        app.launch()
        XCTAssertTrue(mainScreenIsVisible(), "强制系统深色后主界面没有出现")

        openSettings()
        let brightness = screenBrightness()
        XCTAssertGreaterThan(
            brightness,
            0.6,
            "开关关闭时 App 不该跟随系统外观，但界面明显偏暗（平均亮度 \(brightness)）：说明跟随了系统深色"
        )

        // 收尾：把开关恢复成用例开始前的状态。
        let again = app.switches["settings.toggle.dark"]
        if again.waitForExistence(timeout: defaultTimeout), isOn(again) != original {
            tapToggle(again)
        }
    }
}
