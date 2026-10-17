import XCTest

/// 测试六：设置页逐项交互。
///
/// 每个控件都验证「能操作 → 状态真的变 → 界面跟着变」，并在需要持久化的地方重启确认。
/// 定位一律走 identifier，不依赖中文文案。
final class SettingsControlsUITests: KebiaoUITestCase {

    /// 一级设置页的 10 个开关（原版「显示选项」整组）。
    private static let displayToggleIDs = [
        "settings.toggle.dark",
        "settings.toggle.optimize",
        "settings.toggle.saturday",
        "settings.toggle.sunday",
        "settings.toggle.weekSlider",
        "settings.toggle.autoCheckUpdate",
        "settings.toggle.nonCurrentWeek",
        "settings.toggle.courseTime",
        "settings.toggle.courseLocation",
        "settings.toggle.courseTeacher",
    ]

    /// 5 个滑动条，及其「当前值」文本的 identifier。
    private static let sliderIDs = [
        "settings.slider.cellHeight",
        "settings.slider.textSize",
        "settings.slider.nonCurrentWeekAlpha",
        "settings.slider.cardAlpha",
        "settings.slider.frosted",
    ]

    func testEveryDisplayToggleActuallyFlips() {
        openSettings()

        for id in Self.displayToggleIDs {
            let toggle = app.switches[id]
            XCTAssertTrue(toggle.waitForExistence(timeout: defaultTimeout), "设置页找不到开关 \(id)")
            scrollUntilHittable(toggle)
            XCTAssertTrue(toggle.isHittable, "开关 \(id) 不可点（可能被遮挡或没有响应）")

            let before = (toggle.value as? String) ?? "?"
            let expected = before == "1" ? "0" : "1"

            tapToggle(toggle)
            XCTAssertTrue(
                waitForValue(toggle, expected),
                "开关 \(id) 点击后状态没有变化（\(before) → 期望 \(expected)）：控件没有真正绑定状态"
            )

            // 再点一次恢复原值，避免污染其它用例。
            tapToggle(toggle)
            XCTAssertTrue(
                waitForValue(toggle, before),
                "开关 \(id) 第二次点击后没有恢复原值（仍为 \(expected)）"
            )
        }
    }

    func testEveryStyleSliderChangesItsValueLabel() {
        openSettings()

        for id in Self.sliderIDs {
            let slider = app.sliders[id]
            // ⚠️ 滑动条在 `Form` 的首屏之下，屏幕外的行**不进无障碍层级**，
            // 所以必须先滚动把它翻出来再断言。原来这里是裸 `waitForExistence`，
            // 只会等到超时 —— 那是测试编排的问题，不是滑动条坏了。
            waitForHittable(slider, "设置页找不到可点的滑动条 \(id)")

            let valueLabel = app.staticTexts["\(id).value"]
            XCTAssertTrue(
                valueLabel.waitForExistence(timeout: defaultTimeout),
                "找不到滑动条 \(id) 的当前值文本"
            )
            let before = valueLabel.label

            slider.adjust(toNormalizedSliderPosition: 0.75)
            XCTAssertTrue(
                waitForLabelToDiffer(valueLabel, from: before),
                "拖动滑动条 \(id) 后数值文本没有变化（仍为「\(before)」）：界面没有跟随状态刷新"
            )
            attachScreenshot("slider-\(id)")
        }
    }

    /// 「学期与时间」：重点是两条硬要求——
    /// ①「学期开始日期」必须是**点开日期选择器的按钮**，绝不能是开关；
    /// ②「保存设置」写盘后重启仍然生效。
    func testSemesterStartDateIsPickerButtonAndPersists() {
        openSemesterPage()

        let startDateButton = app.buttons["semester.button.startDate"]
        let doneButton = app.buttons["semester.sheet.done"]

        // 硬断言：它不是一个开关。
        XCTAssertFalse(
            app.switches["semester.button.startDate"].exists,
            "「学期开始日期」被实现成了开关（用户明确要求是二级日期选择器）"
        )

        // 点开 → 出现日期选择器弹层（完成 / 清除 / 取消）。
        startDateButton.tap()
        XCTAssertTrue(doneButton.waitForExistence(timeout: defaultTimeout), "「学期开始日期」点击后没有弹出日期选择器")
        XCTAssertTrue(app.buttons["semester.sheet.clearDate"].exists, "日期选择器缺少「清除日期」")
        attachScreenshot("semester-date-picker")

        // 直接用默认日期（未设置时选择器落在今天）完成。
        doneButton.tap()

        let value = app.staticTexts["semester.value.startDate"]
        XCTAssertTrue(value.waitForExistence(timeout: defaultTimeout), "找不到学期开始日期的显示值")
        XCTAssertNotEqual(value.label, "未设置", "选完日期后显示值仍为「未设置」")
        let savedLabel = value.label

        // 保存设置 → 必须有明确反馈。
        tapWhenHittable(app.buttons["semester.button.save"], message: "找不到「保存设置」按钮")
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: defaultTimeout), "点「保存设置」后没有任何反馈")
        XCTAssertTrue(alert.staticTexts["设置已保存"].exists, "保存反馈文案不是「设置已保存」")
        alert.buttons["好"].tap()

        // 重启后仍然生效。
        app.terminate()
        app.launch()
        XCTAssertTrue(mainScreenIsVisible(), "重启后主界面没有出现")
        openSemesterPage()
        let valueAfterRelaunch = app.staticTexts["semester.value.startDate"]
        XCTAssertTrue(valueAfterRelaunch.waitForExistence(timeout: defaultTimeout))
        XCTAssertEqual(
            valueAfterRelaunch.label, savedLabel,
            "重启后学期开始日期变了（保存没有真正落盘）"
        )
    }

    /// 步进器（Stepper）必须真的把读数改掉，而不是只有两个按不动的加/减按钮。
    func testSemesterStepperActuallyChangesItsValue() {
        openSemesterPage()

        let periodDurationStepper = stepper("semester.stepper.periodDuration")
        XCTAssertTrue(
            periodDurationStepper.waitForExistence(timeout: defaultTimeout),
            "找不到「每节时长」步进器"
        )
        scrollUntilHittable(periodDurationStepper)
        XCTAssertTrue(periodDurationStepper.isHittable, "「每节时长」步进器不可点")
        XCTAssertTrue(
            periodDurationStepper.buttons.count >= 2,
            "步进器里找不到加/减按钮（说明它没有真正绑定，只是个静态读数）"
        )

        let valueLabel = app.staticTexts["semester.stepper.periodDuration.value"]
        XCTAssertTrue(valueLabel.waitForExistence(timeout: defaultTimeout), "找不到「每节时长」的读数文本")
        let before = valueLabel.label

        // 加号是第 2 个按钮（第 1 个是减号）。
        periodDurationStepper.buttons.element(boundBy: 1).tap()
        XCTAssertTrue(
            waitForLabelToDiffer(valueLabel, from: before),
            "点步进器加号后读数没有变化（仍为「\(before)」）：控件没有真正绑定状态"
        )

        // 收尾：点减号恢复原值。
        periodDurationStepper.buttons.element(boundBy: 0).tap()
    }

    func testAccountFieldsExistAndSaveIsPersisted() {
        openAccountSyncPage()

        let urlField = app.textFields["account.field.url"]
        XCTAssertTrue(urlField.exists, "找不到「教务系统 URL」输入框")
        let usernameField = app.textFields["account.field.username"]
        XCTAssertTrue(usernameField.exists, "找不到「用户名」输入框")
        let passwordField = app.secureTextFields["account.field.password"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: defaultTimeout), "找不到「密码」输入框（应为安全输入框）")

        // 「定时同步教务课表」开关要能真的切换。
        let autoSync = app.switches["account.toggle.autoSync"]
        XCTAssertTrue(autoSync.waitForExistence(timeout: defaultTimeout), "找不到「定时同步教务课表」开关")
        let beforeSync = (autoSync.value as? String) ?? "?"

        // 三个输入框从上到下依次是 URL / 用户名 / 密码。密码框在最下面：
        // 键盘弹着的时候它的坐标会落在键盘底下，直接 `tap()` 会点在键盘上
        // —— 这是 XCUITest 里最常见的假失败来源。所以每填完一个就收键盘，
        // 并且往下找之前先滚动到可点位置。
        let username = "uitest\(Int(Date().timeIntervalSince1970))"
        usernameField.tap()
        usernameField.typeText(username)
        dismissKeyboard()

        scrollUntilHittable(passwordField)
        XCTAssertTrue(passwordField.isHittable, "「密码」输入框不可点（可能被键盘或其它视图遮挡）")
        passwordField.tap()
        passwordField.typeText("uitestpass")
        dismissKeyboard()

        scrollUntilHittable(autoSync)
        XCTAssertTrue(autoSync.isHittable, "「定时同步教务课表」开关不可点")
        tapToggle(autoSync)
        XCTAssertTrue(
            waitForValue(autoSync, beforeSync == "1" ? "0" : "1"),
            "「定时同步教务课表」开关点击后状态没有变化"
        )

        // 保存 → 明确反馈。
        tapWhenHittable(app.buttons["account.button.save"], message: "找不到「保存设置」按钮")
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: defaultTimeout), "点「保存设置」后没有任何反馈")
        XCTAssertTrue(alert.staticTexts["设置已保存"].exists)
        alert.buttons["好"].tap()

        // 重启后用户名仍在（用户名落 UserDefaults，密码落 Keychain）。
        app.terminate()
        app.launch()
        XCTAssertTrue(mainScreenIsVisible(), "重启后主界面没有出现")
        openAccountSyncPage()
        let usernameAfterRelaunch = app.textFields["account.field.username"]
        XCTAssertTrue(usernameAfterRelaunch.waitForExistence(timeout: defaultTimeout))
        XCTAssertEqual(
            usernameAfterRelaunch.value as? String, username,
            "重启后用户名没有保留（保存没有真正落盘）"
        )

        // 收尾：把开关恢复原值。
        let autoSyncAgain = app.switches["account.toggle.autoSync"]
        if autoSyncAgain.waitForExistence(timeout: defaultTimeout) {
            scrollUntilHittable(autoSyncAgain)
            if ((autoSyncAgain.value as? String) ?? "?") != beforeSync {
                tapToggle(autoSyncAgain)
            }
        }
    }

    /// 背景图「手动输入图片地址 → 应用图片地址」这条链路的输入校验：
    /// 非 http/https 的地址必须被拒绝并给出提示（不能静默吞掉）。
    func testManualBackgroundAddressRejectsInvalidInput() {
        openSettings()

        let field = app.textFields["settings.field.imageAddress"]
        // 这两个控件都在 `Form` 的显示与样式区块里，位于首屏之下 ——
        // 必须先滚动把它们翻出来，裸 `waitForExistence` 只会等到超时。
        waitForHittable(field, "找不到「手动输入图片地址」输入框")

        let applyButton = app.buttons["settings.button.applyImageAddress"]
        XCTAssertTrue(
            scrollToExistence(applyButton, maxSwipes: 8),
            "滚动后仍找不到「应用图片地址」按钮"
        )
        XCTAssertFalse(applyButton.isEnabled, "地址为空时「应用图片地址」不该可点")

        field.tap()
        field.typeText("notaurl")
        XCTAssertTrue(applyButton.isEnabled, "输入地址后「应用图片地址」仍不可点")

        // 用键盘提交，与点「应用图片地址」走同一个回调（`applyManualImageAddress`）。
        field.typeText("\n")

        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: defaultTimeout), "非法图片地址没有给出任何提示")
        let message = alert.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@", "http"))
            .firstMatch
        XCTAssertTrue(message.exists, "非法地址的提示没有说明只支持 http/https")
        alert.buttons["好"].tap()
    }
}
