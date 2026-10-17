import XCTest

/// 课表主页的周次导航交互（「上一周 / 下一周 / 回到本周」）。
///
/// 这条链路最容易暴露「状态变了但界面不刷新」：翻周只改 `TimetableStore.weekOffset`，
/// 界面若不订阅 store 的变更，周次标题就一动不动——正是用户报的「按钮点了没反应」。
/// 所以这里断言的是**徽标文本真的变了**，而不是点击本身没崩。
final class WeekNavigationUITests: KebiaoUITestCase {

    func testWeekButtonsChangeDisplayedWeekAndBackRestoresIt() {
        XCTAssertTrue(weekBadge.waitForExistence(timeout: defaultTimeout), "主界面找不到周次徽标")

        let next = app.buttons["tt.week.next"]
        let prev = app.buttons["tt.week.prev"]
        let back = app.buttons["tt.week.back"]
        XCTAssertTrue(next.waitForExistence(timeout: defaultTimeout), "找不到「下一周」按钮")
        XCTAssertTrue(prev.exists, "找不到「上一周」按钮")
        XCTAssertTrue(back.exists, "找不到「回到本周」按钮")

        // ① 周次下界：一直点「上一周」，徽标最终必须停在第 1 周并且**点不动**，
        //    绝不能出现「第0周」。原版算法是
        //    `displayedWeek = max(currentWeek + weekOffset, 1)`（`TimetableStore.swift:148-150`）——
        //    已经站在第 1 周时，再点「上一周」周次本来就翻不动，
        //    所以这里断言的是「停住」，而不是「变化」。
        goToFirstDisplayedWeek()
        XCTAssertEqual(weekBadge.label, "第1周", "点「上一周」没能把周次翻回第 1 周")
        prev.tap()
        // 已经在下界，徽标必须**一直是**「第1周」——不是「等它变回来」，
        // 而是「在这一秒里它一次都不许变」（`waitForLabelToBecome` 在这里会立刻通过，
        // 证明不了「没有闪出第0周」，所以用反向等待）。
        assertLabelStays(weekBadge, "第1周", for: 1.5, "第 1 周点「上一周」后周次没有夹在下界 1")

        // ② 下一周：徽标必须真的跟着变。这条在修好「状态不刷新」之前**必失败**，
        //    正是用户报的「按钮点了没反应」。
        let week1 = weekBadge.label
        next.tap()
        XCTAssertTrue(
            waitForLabelToDiffer(weekBadge, from: week1),
            "点「下一周」后周次没有变化（仍为「\(week1)」）：界面没有跟随状态刷新"
        )
        let week2 = weekBadge.label
        XCTAssertNotEqual(week2, week1, "「下一周」翻出来的周次和上一周一模一样")

        // ③ 上一周：回到第 1 周。
        prev.tap()
        XCTAssertTrue(
            waitForLabelToBecome(weekBadge, week1),
            "点「上一周」后没有回到「\(week1)」（当前「\(weekBadge.label)」）"
        )

        // ④ 「回到本周」的完整语义：本位置灰 → 翻走可变 → 点完回到本周 → 重新置灰。
        //    这里用 `back` 自己定位「本周」，所以不依赖当前教学周到底是第几周。
        if back.isEnabled { back.tap() }
        let home = weekBadge.label
        XCTAssertFalse(back.isEnabled, "已经在本周了，「回到本周」应当置灰不可点")

        next.tap()
        XCTAssertTrue(
            waitForLabelToDiffer(weekBadge, from: home),
            "点「下一周」后周次没有变化（仍为「\(home)」）"
        )
        XCTAssertTrue(back.isEnabled, "翻走之后「回到本周」仍不可点")
        back.tap()
        XCTAssertTrue(
            waitForLabelToBecome(weekBadge, home),
            "点「回到本周」后没有恢复成本周「\(home)」（当前「\(weekBadge.label)」）"
        )
        XCTAssertFalse(back.isEnabled, "回到本周后「回到本周」没有重新置灰")
    }

    /// 主界面滑动条（`showWeekSlider` 打开时）也必须真的改周次。
    func testWeekSliderChangesDisplayedWeekWhenEnabled() {
        // 先在设置里打开「显示主界面滑动条」。
        openSettings()
        let toggle = app.switches["settings.toggle.weekSlider"]
        XCTAssertTrue(toggle.waitForExistence(timeout: defaultTimeout), "找不到「显示主界面滑动条」开关")
        scrollUntilHittable(toggle)
        XCTAssertTrue(toggle.isHittable, "「显示主界面滑动条」开关不可点")
        let original = isOn(toggle)
        if !original {
            tapToggle(toggle)
            XCTAssertTrue(waitForValue(toggle, "1"), "无法打开「显示主界面滑动条」")
        }

        // 回到主界面。
        app.navigationBars.firstMatch.buttons.firstMatch.tap()
        XCTAssertTrue(mainScreenIsVisible(), "从设置页返回主界面失败")

        let slider = app.sliders["tt.week.slider"]
        XCTAssertTrue(slider.waitForExistence(timeout: defaultTimeout), "打开开关后主界面没有出现周次滑动条")

        let before = weekBadge.label
        slider.adjust(toNormalizedSliderPosition: 0.5)
        XCTAssertTrue(
            waitForLabelToDiffer(weekBadge, from: before),
            "拖动主界面周次滑动条后周次没有变化（仍为「\(before)」）"
        )

        // 收尾：恢复开关原值与周次。
        app.buttons["tt.week.back"].tap()
        openSettings()
        let toggleAgain = app.switches["settings.toggle.weekSlider"]
        if toggleAgain.waitForExistence(timeout: defaultTimeout) {
            scrollUntilHittable(toggleAgain)
            if isOn(toggleAgain) != original { tapToggle(toggleAgain) }
        }
    }

    /// 点课程卡片应当原地展开详情浮层（不是跳页），「收起」能收回。
    func testTappingCourseCardOpensAndDismissesDetailOverlay() {
        let name = uniqueCourseName("overlay")
        createCourse(named: name)

        card(name).tap()
        let dismiss = app.buttons["overlay.button.dismiss"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: defaultTimeout), "点课程卡片后没有展开详情浮层（缺少收起按钮）")
        XCTAssertTrue(app.buttons["overlay.button.more"].exists, "展开浮层缺少「更多」按钮")
        attachScreenshot("overlay-expanded")

        dismiss.tap()
        XCTAssertTrue(
            waitForDisappearance(app.buttons["overlay.button.more"]),
            "点「收起」后浮层没有收回去"
        )

        // 收尾：删掉测试课程。
        deleteCourse(named: name)
    }
}
