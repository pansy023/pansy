import XCTest

/// 测试一：应用启动。
///
/// 覆盖用户要求的三件事：主界面正常显示、不崩溃/不白屏、关键控件存在。
/// 以及「首次启动」与「已有数据启动」两种情况——`setUp` 用的是当前模拟器容器里
/// 已有的状态；`testAppLaunchesWithExistingData` 会先造一门课再重启来模拟第二种。
final class LaunchUITests: KebiaoUITestCase {

    /// 首次启动：主界面渲染出网格与全部关键控件。
    func testFreshLaunchShowsMainScreenAndKeyControls() {
        XCTAssertTrue(app.buttons["tt.nav.settings"].exists, "主界面缺少「设置」入口")
        XCTAssertTrue(app.buttons["tt.nav.addCourse"].exists, "主界面缺少「添加课程」入口")

        XCTAssertTrue(app.buttons["tt.week.prev"].exists, "主界面缺少「上一周」按钮")
        XCTAssertTrue(app.buttons["tt.week.next"].exists, "主界面缺少「下一周」按钮")
        XCTAssertTrue(
            weekBadge.waitForExistence(timeout: defaultTimeout),
            "主界面缺少周次徽标（周次标题没有渲染）"
        )

        // 网格真的要画出来：表头「周一」必须存在，否则就是白屏 / 空页面。
        XCTAssertTrue(
            app.staticTexts["周一"].waitForExistence(timeout: defaultTimeout),
            "课表网格没有渲染（表头「周一」缺失），可能是白屏或空页面"
        )

        // 启动过程不应该弹出任何异常提示。
        XCTAssertFalse(app.alerts.firstMatch.exists, "启动时出现了异常弹窗")
        attachScreenshot("fresh-launch")
    }

    /// 已有数据启动：先新增一门课，重启后主界面仍能正常显示并且课程还在。
    func testLaunchWithExistingDataShowsSavedCourse() {
        let name = uniqueCourseName("launch")

        createCourse(named: name)

        app.terminate()
        app.launch()
        XCTAssertTrue(mainScreenIsVisible(), "已有数据启动时主界面没有出现")
        XCTAssertTrue(
            card(name).waitForExistence(timeout: defaultTimeout),
            "已有数据启动后课程「\(name)」没有显示出来"
        )

        // 收尾：把测试课程删掉，不给其它用例留脏数据。
        deleteCourse(named: name)
    }
}
