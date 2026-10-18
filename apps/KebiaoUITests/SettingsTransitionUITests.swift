import UIKit
import XCTest

/// 设置页「圆形铺开」转场的可见行为测试。
///
/// 为什么必须减速才有意义：转场只有 0.5 秒，而 `xcodebuild test` 里一次
/// `app.screenshot()` 的往返本身就要上百毫秒 —— 不减速就永远截不到中间帧，
/// 「从按钮向外铺开」这件事只能靠肉眼猜。所以这里用启动参数
/// `-KebiaoTransitionSlowdown 20` 把时长整体放大 20 倍：
/// **几何、曲线形状、图层顺序、代码路径完全不变，只是变慢**。
/// 正常运行（含真机）没有这个参数，转场就是 0.55 秒。
///
/// 每组断言证明什么、不证明什么，逐条写在用例里 —— 不夸大结论。
final class SettingsTransitionUITests: KebiaoUITestCase {

    /// 转场减速倍数：把 0.55s 的展开拉成约 22s。
    ///
    /// 取 40 而不是「够用就好」：CI 上一次 `app.screenshot()` 的往返延迟是不确定的
    /// （实测可能到秒级），倍数留大一些，三帧才**必然**都落在「还没铺满」的那一段里，
    /// 中间帧断言才不会变成看运气。
    private static let slowdown = 40

    /// 主体展开时长（秒）。⚠️ 这是 `RootView.revealSeconds` 的**同一个值**：
    /// 那边改了这里必须一起改，否则下面的时长等待会失真。
    private static let revealSeconds: TimeInterval = 0.55

    /// 三帧之间的间隔（秒）。sleep 是为了把采样时刻**钉死**：截图往返延迟本身不可控
    /// （两轮 CI 实测差了 5 倍以上），不睡的话三帧可能全挤在动画最开头那一小段里。
    private static let frameGapSeconds: TimeInterval = 0.7

    override func setUpWithError() throws {
        // 不走 `super`：父类的 `setUpWithError` 会用**不带**减速参数的启动参数起 App，
        // 而这里的用例都需要自己那套参数，所以自己启动一次（其余流程与父类一致）。
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-KebiaoTransitionSlowdown", "\(Self.slowdown)"]
        app.launch()
        XCTAssertTrue(mainScreenIsVisible(), "App 启动后主界面没有出现（连「添加课程」入口都找不到）")
    }

    // MARK: - ① 起点与扩张

    /// 转场从齿轮按钮出发、向外铺开，落点是一整页设置页。
    ///
    /// 这里**只保留三条**确定能证明的断言（2026-10-18 经用户确认精简）：
    /// 1. 第一帧的变化区域紧贴齿轮按钮 ⇒ 起点就是那颗按钮；
    /// 2. 后面那帧的变化范围比第一帧更远 ⇒ 确实是**从按钮向外**扩张；
    /// 3. 转场结束后设置页完整呈现 ⇒ 落点正确。
    ///
    /// 更细的几何（圆环是不是正圆、四角有没有漏、有没有黑边）交给 CI 导出的截图
    /// 人工核对 —— 前两轮 CI 已经证明：让测试从像素反推几何，结论会随截图往返延迟
    /// 漂移（两轮延迟差过 5 倍），那种断言不是可靠的证据。
    func testTransitionStartsAtGearButtonAndExpandsOutward() {
        let entry = app.buttons["tt.nav.settings"]
        // 前置条件不占用「三条」：拿不到按钮位置就无法判定起点，属于测试自身失效。
        guard entry.waitForExistence(timeout: defaultTimeout), !entry.frame.isEmpty else {
            XCTFail("主界面找不到设置入口 tt.nav.settings，或按钮 frame 读不到：无法判定动画起点")
            return
        }
        let buttonFrame = entry.frame

        let baseline = app.screenshot()
        entry.tap()
        // 三帧之间**显式 sleep**：截图自身的往返延迟不可控（两轮 CI 实测差了 5 倍以上），
        // 不睡的话三帧可能全挤在动画最开头那一小段里，「铺开了多少」就没有意义。
        var frames: [XCUIScreenshot] = []
        for index in 0..<3 {
            if index > 0 {
                RunLoop.current.run(until: Date().addingTimeInterval(Self.frameGapSeconds))
            }
            frames.append(app.screenshot())
        }
        for index in frames.indices {
            attachScreenshot("transition-frame-\(index + 1)")
        }

        let center = CGPoint(x: buttonFrame.midX, y: buttonFrame.midY)
        let screen = app.frame.size
        var regions: [ChangedRegion] = []
        for (index, shot) in frames.enumerated() {
            guard let region = changedRegion(from: baseline, to: shot, origin: center, screen: screen) else {
                XCTFail("第 \(index + 1) 帧截图解码失败，无法做像素比较")
                return
            }
            regions.append(region)
        }

        // ① 起点就是齿轮按钮：转场刚出现时，变化区域紧贴按钮（按钮中心 50pt 以内）。
        XCTAssertTrue(
            regions[0].probeCount > 0 && regions[0].nearest <= 50,
            "第一帧的变化区域没有贴住齿轮按钮（变化采样点 \(regions[0].probeCount) 个，最近 \(regions[0].nearest)pt）：转场的起点不在按钮上"
        )

        // ② 从按钮向外铺开：第三帧的变化范围比第一帧更远。
        XCTAssertGreaterThan(
            regions[2].farthest, regions[0].farthest,
            "转场没有向外扩张（第 1 帧最远 \(regions[0].farthest)pt → 第 3 帧最远 \(regions[2].farthest)pt）"
        )

        // ③ 落点正确：转场结束后是一整页设置页。
        waitForTransition(slowdown: Double(Self.slowdown))
        attachScreenshot("transition-settled-settings")
        XCTAssertTrue(
            app.buttons["settings.nav.account"].exists && app.switches["settings.toggle.dark"].exists,
            "转场结束后设置页没有完整呈现（缺「账号与同步」入口或「深色模式」开关）"
        )
    }

    // MARK: - ② 连点与状态保持

    /// 连点两下齿轮：只能开出一个设置页；转场途中点返回能**原路立即退回**；
    /// 回到主界面后周次没被重置、翻周仍然可用。
    ///
    /// ⚠️ 为什么不是「连点两下后页面必须还开着」：防连点窗口（`reverseGuardSeconds`）
    /// 只有 0.35s，而 **XCUITest 两次 `tap()` 的最小间隔实测是 1.8～2.1s**
    /// （每次 tap 都要先解析元素、再等 App 空闲；run `39114847866` 的日志原文：8.42s → 10.26s）。
    /// 也就是说测试**造不出真正的「双击」**，却完全能造出「转场途中又点了一下」。
    /// 所以这里验的是能确定性造出来的那一支：第二下落在展开动画途中 → 必须原路退回，
    /// 且全程只存在一个设置页实例（「不会重复打开多个设置页面」）。
    /// 「0.35s 内的双击被窗口吃掉」这一支无法用 XCUITest 造，只能靠代码审查 + 真机手感确认。
    func testRapidDoubleTapOpensOneSettingsPageAndKeepsMainScreenState() {
        let entry = app.buttons["tt.nav.settings"]
        XCTAssertTrue(entry.waitForExistence(timeout: defaultTimeout), "主界面找不到设置入口 tt.nav.settings")
        let weekBefore = weekBadge.label

        entry.tap()
        // 第二下刻意打在**同一屏幕坐标**上：此刻浮层已经盖住按钮，
        // 用坐标点击才能确定性地制造「转场途中又点了一下」这个场景。
        entry.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        XCTAssertTrue(
            app.buttons["settings.nav.account"].waitForExistence(timeout: defaultTimeout),
            "连点两下后设置页没有打开"
        )
        // 「只开出一个」：同一个入口在无障碍树里只能有一份。
        // 计数必须走 `matching(identifier:)` —— `XCUIElement` 本身没有 `count`。
        // ⚠️ 这里断言的是**不超过** 1，不是「恰好 1」：第二次点击落在减速 40 倍的展开动画途中，
        // 按设计触发「中途反悔」—— 此刻页面正在收拢（run `39127819377` 的截图：圆盘正缩回左上角），
        // 收拢过程中内容会从无障碍树里消失（实测那次 `settings.nav.back` 计数 = 0）。
        // 「重复呈现」这类缺陷会把计数推到 2，照样会被抓到这里。
        XCTAssertLessThanOrEqual(
            app.buttons.matching(identifier: "settings.nav.account").count, 1,
            "存在多个设置页实例（重复呈现）"
        )
        XCTAssertLessThanOrEqual(
            app.buttons.matching(identifier: "settings.nav.back").count, 1,
            "存在多个「返回」按钮（重复呈现）"
        )

        // 等过了防连点窗口、但**仍在展开动画途中**（减速 40 倍 → 展开约 22 秒）——
        // 这一击是「中途反悔」，必须原路立即退回，而不是等动画跑完。
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        app.buttons["settings.nav.back"].tap()
        XCTAssertTrue(
            waitForDisappearance(app.buttons["settings.nav.account"], timeout: 60),
            "转场途中点「返回」没有原路退回（设置页没有收拢消失）"
        )
        XCTAssertTrue(mainScreenIsVisible(), "返回后主界面没有恢复")

        // 主界面必须真的拿回交互：翻周要能改周次。
        // 若还压着一层遮罩，这一击会被吃掉、周次纹丝不动。
        XCTAssertEqual(weekBadge.label, weekBefore, "返回后主界面的周次被重置了")
        let next = app.buttons["tt.week.next"]
        XCTAssertTrue(next.waitForExistence(timeout: defaultTimeout), "返回后主界面找不到「下一周」按钮")
        next.tap()
        XCTAssertTrue(
            waitForLabelToDiffer(weekBadge, from: weekBefore),
            "返回后主界面的「下一周」点不动（可能残留了遮罩或无法点击的透明视图）"
        )

        // 收尾：回到本周，避免污染其它用例。
        if app.buttons["tt.week.back"].isEnabled {
            app.buttons["tt.week.back"].tap()
        }
    }

    // MARK: - ③ 减弱动态效果

    /// 系统打开「减弱动态效果」时：不做圆形铺开，但仍然必须能正常打开 / 返回，
    /// 且动画结束后控件可点。
    ///
    /// ⚠️ 模拟器的这个系统开关没法从测试进程里打开，所以用 `-KebiaoForceReduceMotion 1`
    /// 这个等价注入点（见 `RootView` 的说明：它只把同一个布尔值置真，不改任何几何）。
    func testReduceMotionStillOpensAndClosesSettings() {
        // 本用例不需要减速（替代转场本身只有 0.22s），换一套启动参数重起。
        app.terminate()
        app.launchArguments = ["-KebiaoForceReduceMotion", "1"]
        app.launch()
        XCTAssertTrue(mainScreenIsVisible(), "带减弱动态效果参数重启后主界面没有出现")

        let entry = app.buttons["tt.nav.settings"]
        XCTAssertTrue(entry.waitForExistence(timeout: defaultTimeout), "主界面找不到设置入口 tt.nav.settings")
        let baseline = app.screenshot()

        entry.tap()
        // 减弱动态效果下也按已知时长等（这条用例没有减速参数，所以倍数传 1）。
        waitForTransition(slowdown: 1)
        let settled = app.screenshot()
        attachScreenshot("reduce-motion-settled-settings")

        XCTAssertTrue(app.buttons["settings.nav.account"].exists, "减弱动态效果下设置页内容缺失")
        // 整屏都换了内容（而不是像圆形铺开那样只有一小块先变）：
        // 这条只说明「确实换页成功、没有半截空白」，**不**用来断言具体的视觉形状。
        if let difference = averageChannelDifference(baseline, settled) {
            XCTAssertGreaterThan(
                difference, 2,
                "减弱动态效果下的转场结束后整屏像素几乎没变（平均通道差 \(difference)）：页面可能没真正呈现"
            )
        }

        app.buttons["settings.nav.back"].tap()
        XCTAssertTrue(
            waitForDisappearance(app.buttons["settings.nav.account"], timeout: 30),
            "减弱动态效果下点「返回」后设置页没有消失"
        )
        XCTAssertTrue(mainScreenIsVisible(), "减弱动态效果下返回后主界面没有恢复")
    }

    // MARK: - 像素工具

    /// 两张截图之间的变化区域，用「到按钮中心的距离」来描述。
    private struct ChangedRegion {
        /// 检测到变化的采样点数。
        let probeCount: Int
        /// 有变化的**最近**采样点到按钮中心的距离（pt）；没有变化时为 `greatestFiniteMagnitude`。
        let nearest: CGFloat
        /// 有变化的**最远**采样点到按钮中心的距离（pt）；没有变化时为 0。
        let farthest: CGFloat
    }

    /// 从按钮中心沿 32 个方向、每 12pt 取一个样，找出有变化的最近 / 最远距离。
    ///
    /// 取样点取得的颜色是「一小块区域的平均色」，所以这一套测量**与图片上下翻转无关**，
    /// 也不受抗锯齿噪点影响（逐像素比较才会被噪点淹没）。
    /// 状态栏那条（时钟 / 电量会随分钟变）整条排除，免得把系统自己的变化算进转场。
    private func changedRegion(
        from before: XCUIScreenshot,
        to after: XCUIScreenshot,
        origin: CGPoint,
        screen: CGSize
    ) -> ChangedRegion? {
        guard let beforeImage = image(before), let afterImage = image(after) else { return nil }

        let rayCount = 32
        // 步长 12pt：实测「前后两帧之间新铺开的那一圈」只有 ~12～32pt 厚
        // （两轮 CI 真帧分别量到 84→96pt、132→156pt），步子迈大了会整条漏采。
        let step: CGFloat = 12
        let maxRadius = max(screen.width, screen.height)
        let pixelsPerPoint = CGFloat(beforeImage.width) / max(screen.width, 1)
        let probeSide = 9 * pixelsPerPoint

        var probeCount = 0
        var nearest = CGFloat.greatestFiniteMagnitude
        var farthest: CGFloat = 0

        for ray in 0..<rayCount {
            let angle = 2 * Double.pi * Double(ray) / Double(rayCount)
            let dx = CGFloat(cos(angle))
            let dy = CGFloat(sin(angle))
            var radius: CGFloat = 0
            while radius <= maxRadius {
                let point = CGPoint(x: origin.x + radius * dx, y: origin.y + radius * dy)
                // 记录的就是这一点的真实距离（不能先把 radius 加上步长再记，否则整体偏大一个步长）。
                let distance = radius
                radius += step
                // 按钮上方 20pt 以上属于状态栏，整条忽略。
                guard point.y > origin.y - 20 else { continue }
                guard let lhs = averageColor(beforeImage, at: point, pixelsPerPoint: pixelsPerPoint, side: probeSide),
                      let rhs = averageColor(afterImage, at: point, pixelsPerPoint: pixelsPerPoint, side: probeSide) else {
                    continue
                }
                let delta = max(
                    abs(lhs.r - rhs.r),
                    max(abs(lhs.g - rhs.g), abs(lhs.b - rhs.b))
                )
                // 阈值 3/255：静态内容两次截图完全相同（差异为 0），所以这个阈值
                // 不会把「同一画面」误判成变化，却能抓到「底色替换了一层」这种低反差变化。
                guard delta > 3 else { continue }
                probeCount += 1
                nearest = min(nearest, distance)
                farthest = max(farthest, distance)
            }
        }

        return ChangedRegion(probeCount: probeCount, nearest: nearest, farthest: farthest)
    }

    /// 整屏平均通道差（0…255）。整图缩成 1×1 再比较，因此与图片上下翻转无关。
    private func averageChannelDifference(_ before: XCUIScreenshot, _ after: XCUIScreenshot) -> Double? {
        guard let lhs = wholeImageAverage(before), let rhs = wholeImageAverage(after) else { return nil }
        return max(abs(lhs.r - rhs.r), max(abs(lhs.g - rhs.g), abs(lhs.b - rhs.b)))
    }

    private func image(_ shot: XCUIScreenshot) -> CGImage? {
        UIImage(data: shot.pngRepresentation)?.cgImage
    }

    /// 一小块区域的平均色。用 `CGImage.cropping` 取矩形（坐标是常规的左上原点），
    /// 再缩成 1×1 求平均 —— 两步都不会被上下翻转影响。
    private func averageColor(
        _ image: CGImage,
        at point: CGPoint,
        pixelsPerPoint: CGFloat,
        side: CGFloat
    ) -> (r: Double, g: Double, b: Double)? {
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))
        let rect = CGRect(
            x: point.x * pixelsPerPoint - side / 2,
            y: point.y * pixelsPerPoint - side / 2,
            width: side,
            height: side
        ).intersection(bounds)
        guard rect.width >= 1, rect.height >= 1, let crop = image.cropping(to: rect) else { return nil }
        return average(crop)
    }

    private func wholeImageAverage(_ shot: XCUIScreenshot) -> (r: Double, g: Double, b: Double)? {
        guard let image = image(shot) else { return nil }
        return average(image)
    }

    /// 把任意 `CGImage` 缩成 1×1 后的平均色。
    private func average(_ image: CGImage) -> (r: Double, g: Double, b: Double)? {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (Double(pixel[0]), Double(pixel[1]), Double(pixel[2]))
    }

    // MARK: - 等待

    /// 等「打开」转场跑完。
    ///
    /// ⚠️ **不能**用 `isHittable` 当信号 —— 这是 CI run 39109889672 实测出来的教训：
    /// 展开动画还在跑（减速 40 倍 → 22 秒）的时候，`settings.nav.back` 就已经报
    /// `isHittable == true`（导航栏里的工具栏按钮由 UIKit 托管，SwiftUI 的
    /// `allowsHitTesting` 门挡不住它）。测试于是在动画中途点了返回，而那一击被
    /// `closeSettings` 的 `interactive` 判断挡下，页面当然没关，白等了 60 秒。
    /// 所以这里按**已知时长**等：0.55s × 减速倍数 × 1.2 + 0.5s 余量。
    ///
    /// - Parameter slowdown: 这次运行时 App 实际生效的减速倍数。正常用例是
    ///   `Self.slowdown`；「减弱动态效果」那条用例启动时**没有**带减速参数，所以传 1。
    ///   ⚠️ `Self.revealSeconds` 与 `RootView.revealSeconds` 必须保持一致。
    private func waitForTransition(slowdown: Double) {
        let seconds = Self.revealSeconds * slowdown * 1.2 + 0.5
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
