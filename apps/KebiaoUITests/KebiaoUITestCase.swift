import UIKit
import XCTest

/// 所有 XCUITest 用例的基类。
///
/// 它只做三件事，不做别的：
/// 1. 每个用例启动一个**真实的 App 进程**（`XCUIApplication().launch()`）——
///    这一步就是「App 真的在 iPhone 模拟器里跑起来了」的证据，不是编译通过；
/// 2. 按 `accessibilityIdentifier` 定位元素，并封装「翻周 / 开关 / 滑条 / 增删改课程」
///    这些公共动作，用例只写断言；
/// 3. 每个用例结束（含失败）都把整屏截图挂到 `.xcresult` 上，CI 失败时能直接看到界面。
///
/// 遵守两条硬规矩：
/// - **不伪造**：不等同于「编译成功」，也不跳过任何断言。断言失败就是失败。
/// - **不依赖中文文案**：所有定位都用 identifier（见 `docs/audit/functional-audit.md`），
///   改文案不会让测试变红或变绿。
///
/// ⚠️ 这些用例**必须**用 `xcodebuild test -scheme Kebiao -destination '...模拟器...'` 跑；
/// `swift test` 既不编译 App，也不会执行这里的任何一行。
class KebiaoUITestCase: XCTestCase {

    /// 被驱动的宿主 App。
    var app: XCUIApplication!

    /// 定位等待上限。CI 上模拟器冷启动较慢，给足时间以避免「假失败」。
    let defaultTimeout: TimeInterval = 30

    // MARK: - 生命周期

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(mainScreenIsVisible(), "App 启动后主界面没有出现（连「添加课程」入口都找不到）")
    }

    override func tearDownWithError() throws {
        if let app = app, app.exists {
            attachScreenshot("tearDown-\(name)")
        }
        app = nil
        try super.tearDownWithError()
    }

    // MARK: - 截图

    /// 把当前整屏截图挂到 `.xcresult`（`lifetime = .keepAlways`，成功也保留）。
    func attachScreenshot(_ label: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = label
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// 整屏平均亮度（0…1）。
    ///
    /// 用途只有一个：客观判断「深色模式有没有真的让界面变暗」。
    /// 只看开关自身的 `value` 是不够的——开关动了但界面配色没变，同样属于缺陷。
    /// 这里把截图缩到 64×64 后按 Rec.601 亮度公式求均值，对界面做一次真实像素采样。
    func screenBrightness() -> Double {
        guard let image = UIImage(data: app.screenshot().pngRepresentation),
              let cgImage = image.cgImage else {
            XCTFail("无法从截图中解码像素，亮度采样失败")
            return -1
        }
        let width = 64
        let height = 64
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            XCTFail("无法创建位图上下文，亮度采样失败")
            return -1
        }
        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var sum = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let red = Double(pixels[index])
            let green = Double(pixels[index + 1])
            let blue = Double(pixels[index + 2])
            sum += 0.299 * red + 0.587 * green + 0.114 * blue
        }
        return sum / Double(width * height) / 255.0
    }

    // MARK: - 导航

    @discardableResult
    func mainScreenIsVisible(timeout: TimeInterval? = nil) -> Bool {
        app.buttons["tt.nav.addCourse"].waitForExistence(timeout: timeout ?? defaultTimeout)
    }

    func openSettings() {
        let entry = app.buttons["tt.nav.settings"]
        XCTAssertTrue(entry.waitForExistence(timeout: defaultTimeout), "主界面找不到设置入口 tt.nav.settings")
        scrollUntilHittable(entry)
        entry.tap()
        XCTAssertTrue(
            app.buttons["settings.nav.account"].waitForExistence(timeout: defaultTimeout),
            "设置页没有打开（找不到 settings.nav.account）"
        )
    }

    func openAccountSyncPage() {
        openSettings()
        let entry = app.buttons["settings.nav.account"]
        XCTAssertTrue(entry.waitForExistence(timeout: defaultTimeout))
        entry.tap()
        XCTAssertTrue(
            app.textFields["account.field.url"].waitForExistence(timeout: defaultTimeout),
            "「账号与同步」二级页没有打开"
        )
    }

    func openSemesterPage() {
        openSettings()
        let entry = app.buttons["settings.nav.semester"]
        XCTAssertTrue(entry.waitForExistence(timeout: defaultTimeout))
        entry.tap()
        XCTAssertTrue(
            app.buttons["semester.button.startDate"].waitForExistence(timeout: defaultTimeout),
            "「学期与时间」二级页没有打开"
        )
    }

    /// 反复点「上一周」直到徽标停在第 1 周为止（周次下界）。
    ///
    /// 原版算法是 `displayedWeek = max(currentWeek + weekOffset, 1)`
    /// （`KebiaoCore/…/Store/TimetableStore.swift:148-150`）：已经站在第 1 周时，
    /// 再点「上一周」周次**本来就翻不动**，徽标不该有任何变化。
    /// 所以这里先无条件翻到下界，后面的用例才有一个确定的起点。
    func goToFirstDisplayedWeek(maxTaps: Int = 40) {
        let prev = app.buttons["tt.week.prev"]
        for _ in 0..<maxTaps {
            if weekBadge.label == "第1周" { return }
            let before = weekBadge.label
            prev.tap()
            // 徽标没变 ⇒ 已经撞到下界，收工。
            if !waitForLabelToDiffer(weekBadge, from: before, timeout: 2) { return }
        }
    }

    /// 收起键盘：点导航栏空白处。
    ///
    /// 不点屏幕中央 —— 那可能正落在某个输入框上，反而把焦点移过去。
    /// 导航栏除标题与返回键外没有控件，点它既能收键盘又不会改动任何状态。
    func dismissKeyboard() {
        guard app.keyboards.count > 0 else { return }
        app.navigationBars.firstMatch.tap()
    }

    // MARK: - 滚动

    /// 元素已存在但不在可视区时，来回滚动把它带到可点位置。
    ///
    /// ⚠️ 它**只在元素已经存在时**有用：`SwiftUI` 的 `Form` / `List` 是懒实体化的，
    /// 屏幕外的行根本不进无障碍层级，所以对这类元素直接调用本方法会立刻返回、
    /// 什么也不做。要「翻到屏幕外的控件」请用 `waitForHittable(_:_:)`。
    func scrollUntilHittable(_ element: XCUIElement, maxAttempts: Int = 10) {
        guard element.exists else { return }
        var attempts = 0
        while !element.isHittable, attempts < maxAttempts {
            app.swipeUp()
            attempts += 1
        }
        attempts = 0
        while !element.isHittable, attempts < maxAttempts {
            app.swipeDown()
            attempts += 1
        }
    }

    /// 边滚动边等元素**出现**（不要求可点）。返回它是否出现过。
    ///
    /// 单独抽出来的理由：`Form` / `List` 里屏幕外的行根本不进无障碍层级，
    /// 只写 `waitForExistence` 会一直等到超时。凡是「要翻到屏幕外才看得到」的控件，
    /// 都得先走一遍这个流程。不要求可点，是因为有些控件只需要读状态，
    /// 例如**禁用**状态的按钮：断言的是 `isEnabled`，`isHittable` 对它语义不确定。
    func scrollToExistence(_ element: XCUIElement, maxSwipes: Int = 12) -> Bool {
        if element.waitForExistence(timeout: 3) { return true }
        // 往下翻：屏幕外的行需要先滚进可视区才会进入无障碍层级。
        for _ in 0..<maxSwipes {
            app.swipeUp()
            if element.exists { return true }
        }
        // 再往上翻：有可能一次滚过头了。
        for _ in 0..<maxSwipes {
            app.swipeDown()
            if element.exists { return true }
        }
        return false
    }

    /// 等元素在屏上**停稳**（滚动惯性走完）：连续两次采样位置一致即视为停稳。
    ///
    /// 为什么必须等：`app.swipeUp()` / `swipeDown()` 之后 `Form` / `List` 还带惯性，
    /// 惯性没停时落下来的第一条手势会被滚动视图吃掉（只用来「刹住」滚动），
    /// 控件根本收不到那次拖拽。
    @discardableResult
    func waitUntilFrameStable(_ element: XCUIElement, timeout: TimeInterval = 3) -> Bool {
        guard element.exists else { return false }
        var previous = element.frame
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            guard element.exists else { return false }
            let current = element.frame
            if current == previous { return true }
            previous = current
        }
        return false
    }

    /// 把元素滚到**整条**都落在屏内，并等它停稳。
    ///
    /// 不能拿「中心点可点」(`isHittable`) 代替，实测栽过两次：
    /// 1. 只判中心点的话，一个控件可以「只从屏幕底边露出一点点」就算可点。此时按它
    ///    当前位置推算出的拖拽起点会落到屏幕外，事件被系统丢弃，控件的值根本不变 ——
    ///    「非本周透明度」滑动条就是这样：它要先滑一下才露出来，而它上面两条
    ///    （课程卡高度、课程文字）一开始就在屏内、无需滚动，所以只有那一条失败；
    /// 2. 惯性未停时第一条手势会被滚动视图吃掉（见 `waitUntilFrameStable`）。
    ///
    /// 比可视区还高的元素滚不「全」，遇到就直接放弃（只保证中心点可点）。
    func scrollFullyIntoViewAndSettle(_ element: XCUIElement, maxSwipes: Int = 8) {
        let safe = app.frame.insetBy(dx: 0, dy: 24)
        guard element.exists, element.frame.height <= safe.height else { return }
        var swipes = 0
        while element.exists, swipes < maxSwipes {
            let frame = element.frame
            if frame.minY >= safe.minY, frame.maxY <= safe.maxY { break }
            if frame.maxY > safe.maxY {
                app.swipeUp()
            } else {
                app.swipeDown()
            }
            swipes += 1
            waitUntilFrameStable(element)
        }
        waitUntilFrameStable(element)
    }

    /// 边滚动边等元素出现**且可点**，返回该元素。
    @discardableResult
    func waitForHittable(
        _ element: XCUIElement,
        _ message: String,
        maxSwipes: Int = 12,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        XCTAssertTrue(
            scrollToExistence(element, maxSwipes: maxSwipes),
            "\(message)（来回滚动 \(maxSwipes * 2) 次后仍未出现）",
            file: file,
            line: line
        )
        scrollUntilHittable(element)
        XCTAssertTrue(element.isHittable, "\(message)（存在但不可点，可能被遮挡）", file: file, line: line)
        return element
    }

    func tapWhenHittable(_ element: XCUIElement, message: String) {
        waitForHittable(element, message)
        element.tap()
    }

    // MARK: - 等待

    func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval? = nil) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout ?? defaultTimeout) == .completed
    }

    func waitForValue(_ element: XCUIElement, _ expected: String, timeout: TimeInterval? = nil) -> Bool {
        let predicate = NSPredicate(format: "value == %@", expected)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout ?? defaultTimeout) == .completed
    }

    func waitForLabelToBecome(_ element: XCUIElement, _ expected: String, timeout: TimeInterval? = nil) -> Bool {
        let predicate = NSPredicate(format: "label == %@", expected)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout ?? defaultTimeout) == .completed
    }

    func waitForLabelToDiffer(_ element: XCUIElement, from old: String, timeout: TimeInterval? = nil) -> Bool {
        let predicate = NSPredicate(format: "label != %@", old)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout ?? defaultTimeout) == .completed
    }

    /// 断言元素的 label 在 `duration` 内**一次都没有变过**。
    ///
    /// 用于「本该点不动」的场景（例如周次已在下界时再点「上一周」）。
    /// 不能用 `waitForLabelToBecome` 代替：那个谓词此刻已经成立，会立刻通过，
    /// 根本证明不了「中间没有闪出第0周」；这里是反向等待 ——
    /// 只有「label 变了」这个事件在整段时间里都没发生，才算通过。
    func assertLabelStays(
        _ element: XCUIElement,
        _ expected: String,
        for duration: TimeInterval,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let predicate = NSPredicate(format: "label != %@", expected)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        expectation.isInverted = true
        let result = XCTWaiter().wait(for: [expectation], timeout: duration)
        XCTAssertEqual(
            result, .completed,
            "\(message)（当前「\(element.label)」，期望全程都是「\(expected)」）",
            file: file,
            line: line
        )
    }

    // MARK: - 元素

    /// 按 label 找任意类型的元素（课程卡片的 accessibilityLabel 就是课程名）。
    func card(_ name: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", name))
            .firstMatch
    }

    /// 周次徽标：`WeekSwitcher` 把三个 Text 合成一个无障碍元素，label 形如「第N周」。
    var weekBadge: XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label MATCHES %@", "^第[0-9]+周$"))
            .firstMatch
    }

    /// `Toggle` 的取值：`"1"` = 开，`"0"` = 关。
    func isOn(_ toggle: XCUIElement) -> Bool {
        (toggle.value as? String) == "1"
    }

    /// 点开关。
    ///
    /// 特意点在行**右侧**而不是元素中心：`Toggle` 的无障碍元素常常覆盖整行，
    /// 开关控件在右端；点中心会落在文字上，有些 iOS 版本不会因此翻转。
    func tapToggle(_ toggle: XCUIElement) {
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
    }

    func uniqueCourseName(_ tag: String) -> String {
        // 只用小写 ASCII + 数字：`typeText` 在模拟器软键盘上输入这些字符最稳，
        // 避免中文/大写带来的输入法不确定性（课程名本身允许任意字符）。
        "uitest\(tag)\(Int(Date().timeIntervalSince1970))"
    }

    /// 按 `identifier` 找**任意类型**的元素。
    ///
    /// 用在「SwiftUI 控件的 XCUITest 元素类型不确定」的场合（见 `stepper(_:)`）。
    /// 这只是换一种找法，元素必须真实存在，断言强度不变。
    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// 找 `Stepper`。
    ///
    /// SwiftUI 的 `Stepper` 在 XCUITest 里报成什么类型会随 iOS 版本变化
    /// （有时是 `.stepper`，有时只是普通容器），所以不赌类型：
    /// 先按 `.stepper` 找，找不到再按 identifier 找任意类型。
    func stepper(_ identifier: String) -> XCUIElement {
        let typed = app.steppers[identifier]
        if typed.exists { return typed }
        return element(identifier)
    }

    // MARK: - 课程增删改（走「＋ / 卡片 → 更多」这条真实路径）

    func createCourse(named name: String) {
        XCTAssertTrue(mainScreenIsVisible(), "新增课程前主界面不可见")
        app.buttons["tt.nav.addCourse"].tap()

        let field = app.textFields["editor.field.name"]
        XCTAssertTrue(field.waitForExistence(timeout: defaultTimeout), "新增课程页没有出现「课程名称」输入框")
        field.tap()
        field.typeText(name)

        let save = app.buttons["editor.button.save"]
        XCTAssertTrue(save.isEnabled, "填了课程名后「保存」仍不可点（原版规则：课程名为空不落库）")
        save.tap()

        XCTAssertTrue(
            card(name).waitForExistence(timeout: defaultTimeout),
            "保存后主界面没有出现课程卡片「\(name)」"
        )
    }

    /// 点课程卡片 → 展开浮层的「更多」→ 进入编辑页。
    func openCardEditor(named name: String) {
        let target = card(name)
        XCTAssertTrue(target.waitForExistence(timeout: defaultTimeout), "主界面找不到课程卡片「\(name)」")
        waitForHittable(target, "课程卡片「\(name)」不可点")
        target.tap()

        let more = app.buttons["overlay.button.more"]
        XCTAssertTrue(more.waitForExistence(timeout: defaultTimeout), "点开卡片后没有出现「更多」按钮")
        // ⚠️ 这里**不再**用 `more.isHittable` 当闸门（2026-10-17 经用户批准改的）。
        //
        // 实测证据（CI run 39023926057）：同一张卡片、同一层的「收起」按钮是**可点的**
        // （日志里真实合成了点击事件，随后「浮层已收起」断言通过）；「更多」的 frame
        // 也在卡内、与滚动区零重叠（滚动区下沿 400.3，按钮上沿 400.3），失败截图里
        // 它完整可见、无任何东西压在上面 —— 但 `isHittable` 恒为 false。
        // 那是 XCUITest 的读数误判，不是遮挡。真正的证据在下面那句：点完之后
        // 编辑页必须**真的出现**；按钮若真不可用，这一句照样必失败。
        more.tap()

        XCTAssertTrue(
            app.textFields["editor.field.name"].waitForExistence(timeout: defaultTimeout),
            """
            「更多」没有打开课程编辑页 —— 这说明它真的不可用，而不只是 isHittable 读数误判。
            more.exists = \(more.exists)，more.isHittable = \(more.isHittable)
            more.frame = \(more.frame)
            app.frame  = \(app.frame)
            """
        )
    }

    func renameCourse(from oldName: String, to newName: String) {
        openCardEditor(named: oldName)
        let field = app.textFields["editor.field.name"]
        XCTAssertTrue(field.waitForExistence(timeout: defaultTimeout))
        XCTAssertEqual(field.value as? String, oldName, "编辑页没有带出原课程名")

        // 清空再写入：用退格键逐字删掉旧值。
        //
        // 不用 `doubleTap()` 选中整词来覆盖 —— 双击选中的是「一个词」，
        // 课程名一旦含有分隔字符就只会删掉一半，测试结果变得依赖输入法行为。
        // 逐字退格与名字内容无关，是确定的。测试课程名都是小写 ASCII，
        // 退格键在模拟器软键盘上输入稳定。
        field.tap()
        let existing = (field.value as? String) ?? ""
        let backspaces = String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count)
        field.typeText(backspaces + newName)

        app.buttons["editor.button.save"].tap()
        XCTAssertTrue(
            card(newName).waitForExistence(timeout: defaultTimeout),
            "改名后主界面没有出现新名字的卡片「\(newName)」"
        )
        XCTAssertFalse(
            card(oldName).waitForExistence(timeout: 2),
            "改名后旧名字的卡片「\(oldName)」仍然存在"
        )
    }

    /// 「删除此课程」的二次确认按钮。
    ///
    /// `CourseEditorView` 用 `.confirmationDialog` 呈现确认，而 SwiftUI 并不保证把
    /// `accessibilityIdentifier` 透传到 action sheet 的按钮上（随版本而变）。
    /// 所以优先按 identifier 找，找不到就退到对话框容器里按文案找 ——
    /// 编辑页本身也有一个「删除此课程」按钮，因此必须限定在 sheet / alert 容器内，
    /// 否则会点到那个刚点过的行按钮（那只会重新弹一次对话框，测试变成假阳性）。
    func deleteConfirmationButton() -> XCUIElement {
        // ⚠️ 三个分支都必须 `.firstMatch`（2026-10-17 实测）：SwiftUI 的
        // `.confirmationDialog` 会把同一颗确认按钮投影成「Button 套 Button」，
        // 两层都带同一个 identifier —— `app.buttons["…"]` 因此命中 2 个元素，
        // 直接 `.tap()` 会抛 `Multiple matching elements found`
        //（CI run 39026024600 的 `Sparse tree of matches` 直接拍下了这个嵌套）。
        // 这不是 App 缺陷（确认删除的动作只有一个），只是无障碍投影重复；
        // `.firstMatch` 不降低强度：调用方仍然断言「弹窗必须出现」与「删除后卡片必须消失」。
        let byIdentifier = app.buttons["editor.dialog.confirmDelete"].firstMatch
        if byIdentifier.waitForExistence(timeout: 8) { return byIdentifier }

        let inSheet = app.sheets.buttons["删除此课程"].firstMatch
        if inSheet.waitForExistence(timeout: 8) { return inSheet }

        return app.alerts.buttons["删除此课程"].firstMatch
    }

    func deleteCourse(named name: String) {
        openCardEditor(named: name)

        let deleteButton = app.buttons["editor.button.delete"]
        tapWhenHittable(deleteButton, message: "编辑页找不到「删除此课程」按钮")

        let confirm = deleteConfirmationButton()
        XCTAssertTrue(confirm.waitForExistence(timeout: defaultTimeout), "删除确认弹窗没有出现（按钮没有真正触发业务）")
        confirm.tap()

        XCTAssertTrue(
            waitForDisappearance(card(name)),
            "删除后课程「\(name)」仍然出现在主界面"
        )
    }
}
