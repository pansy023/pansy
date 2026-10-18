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

    /// 转场从齿轮按钮出发、向外扩张，并且**不是**瞬间切到整屏。
    ///
    /// 断言依据（全部是像素采样，不是看代码猜）：
    /// - 与点击前的基线相比，第一帧就出现变化，且变化区域**紧贴齿轮按钮**
    ///   （按钮中心 50pt 内就有变化）⇒ 转场真的发生，且起点落在按钮上；
    /// - 把**相邻两帧**相减，得到的是「这一小段时间里新铺开的那一圈」。对 32 条射线
    ///   分别量这一圈的内沿 / 外沿半径：它们必须互相吻合（实测离散度只有 0～12pt）
    ///   ⇒ 新铺开的区域是**以按钮为圆心的圆环**；圆心若不在按钮上，这个离散度会是几百 pt；
    /// - 圆环的内沿与外沿都逐帧往外走 ⇒ 是连续扩张，不是跳变；
    /// - 最后一帧的半径仍远小于「按钮到屏幕最远角」的距离 ⇒ 还没铺满整屏。
    func testTransitionStartsAtGearButtonAndExpandsOutward() {
        let entry = app.buttons["tt.nav.settings"]
        XCTAssertTrue(entry.waitForExistence(timeout: defaultTimeout), "主界面找不到设置入口 tt.nav.settings")
        let buttonFrame = entry.frame
        XCTAssertFalse(buttonFrame.isEmpty, "齿轮按钮的 frame 读不到，无法判定动画起点")

        let baseline = app.screenshot()

        entry.tap()
        // 三帧之间**显式 sleep**：截图自身的往返延迟是会变的（两轮 CI 实测差了 5 倍以上），
        // 不睡的话三帧可能全挤在动画最开头那一小段里，「这一圈铺开了多少」就没有意义了。
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
        // 按钮中心到**最远角**的距离。全程用 Double 计算：`CGFloat` 的 `sqrt`/`pow`
        // 重载不在标准库里，显式转成 Double 最稳。
        let diagonal = (
            pow(Double(max(center.x, screen.width - center.x)), 2)
                + pow(Double(max(center.y, screen.height - center.y)), 2)
        ).squareRoot()

        var vsBaseline: [ChangedRegion] = []
        for (index, shot) in frames.enumerated() {
            guard let region = changedRegion(from: baseline, to: shot, origin: center, screen: screen) else {
                XCTFail("第 \(index + 1) 帧截图解码失败，无法做像素比较")
                return
            }
            vsBaseline.append(region)
        }
        for region in vsBaseline {
            XCTAssertGreaterThan(region.probeCount, 0, "点击后没有任何像素变化：转场没有发生")
        }
        // ① 起点落在按钮上：转场刚出现时，变化区域紧贴齿轮按钮，而且这时还没铺满。
        XCTAssertLessThanOrEqual(
            vsBaseline[0].nearest, 50,
            "第一帧的变化区域没有贴住齿轮按钮（最近 \(vsBaseline[0].nearest)pt）"
        )
        XCTAssertLessThan(
            vsBaseline[0].farthest, diagonal * 0.9,
            "第一帧就已经铺到屏幕最远角附近（\(vsBaseline[0].farthest)pt / 对角 \(diagonal)pt）"
        )

        // ② 相邻两帧相减 = 「这一小段时间里新铺开的那一圈」。逐条射线量它的内沿 / 外沿：
        //    32 条射线上量出来的半径必须互相吻合 ⇒ 这一圈是**以按钮为圆心的圆环**。
        var rings: [ChangedRegion] = []
        for index in 0..<(frames.count - 1) {
            guard let ring = changedRegion(
                from: frames[index],
                to: frames[index + 1],
                origin: center,
                screen: screen
            ) else {
                XCTFail("第 \(index + 1)/\(index + 2) 帧之间无法比较像素")
                return
            }
            rings.append(ring)
        }
        XCTAssertEqual(rings.count, frames.count - 1, "相邻帧比较的组数不对")
        for (index, ring) in rings.enumerated() {
            let label = "第 \(index + 1)→\(index + 2) 帧"
            XCTAssertGreaterThan(ring.probeCount, 0, "\(label)之间没有任何变化：展开是跳变的，不是连续的")
            XCTAssertGreaterThanOrEqual(
                ring.rayCount, 6,
                "\(label)的有效射线只有 \(ring.rayCount) 条，不足以判断圆环形状"
            )
            // 两轮 CI 真帧实测：内沿离散度 0～12pt、外沿 0～12pt。这里放到 60pt 已是 5 倍余量；
            // 圆心一旦不在按钮上（例如从屏幕中心长出来），这个值会是几百 pt，必被抓到。
            XCTAssertLessThanOrEqual(
                ring.innerSpread, 60,
                "\(label)的内沿半径散得太开（\(ring.innerSpread)pt）：新铺开的区域不是以按钮为圆心的圆环"
            )
            XCTAssertLessThanOrEqual(
                ring.outerSpread, 60,
                "\(label)的外沿半径散得太开（\(ring.outerSpread)pt）：新铺开的区域不是以按钮为圆心的圆环"
            )
        }
        XCTAssertGreaterThan(
            rings[1].medianInner, rings[0].medianInner,
            "圆环的内沿没有往外走（\(rings[0].medianInner)pt → \(rings[1].medianInner)pt）"
        )
        XCTAssertGreaterThan(
            rings[1].medianOuter, rings[0].medianOuter,
            "圆环的外沿没有往外走（\(rings[0].medianOuter)pt → \(rings[1].medianOuter)pt）"
        )
        XCTAssertLessThan(
            rings[1].medianOuter, diagonal * 0.9,
            "已经铺到屏幕最远角附近（\(rings[1].medianOuter)pt / 对角 \(diagonal)pt）：看起来更像瞬间铺满整屏"
        )

        // 转场结束后：内容完整、可点，返回能收拢回主界面。
        waitForTransition(slowdown: Double(Self.slowdown))
        XCTAssertTrue(app.buttons["settings.nav.account"].exists, "转场结束后设置页内容缺失")
        attachScreenshot("transition-settled-settings")

        app.buttons["settings.nav.back"].tap()
        XCTAssertTrue(
            waitForDisappearance(app.buttons["settings.nav.account"], timeout: 60),
            "点「返回」后设置页没有收拢消失"
        )
        XCTAssertTrue(mainScreenIsVisible(), "返回后主界面没有恢复")
    }

    // MARK: - ② 连点与状态保持

    /// 连点两下齿轮：只开出一个设置页；返回后主界面照旧可交互、周次没被重置。
    func testRapidDoubleTapOpensOneSettingsPageAndKeepsMainScreenState() {
        let entry = app.buttons["tt.nav.settings"]
        XCTAssertTrue(entry.waitForExistence(timeout: defaultTimeout), "主界面找不到设置入口 tt.nav.settings")
        let weekBefore = weekBadge.label

        entry.tap()
        // 第二下刻意打在**同一屏幕坐标**上：此刻浮层已经盖住按钮，
        // 用坐标点击才能确定性地制造「转场途中连点」这个场景。
        entry.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        XCTAssertTrue(
            app.buttons["settings.nav.account"].waitForExistence(timeout: defaultTimeout),
            "连点两下后设置页没有打开"
        )
        // ⚠️ 必须等展开动画真的跑完再点返回，否则点击会被转场闸门吃掉（见
        // `waitForTransition` 的说明）。这一步故意**不**用 `isHittable` 判断。
        waitForTransition(slowdown: Double(Self.slowdown))
        // 「只开出一个」：同一个入口在无障碍树里只能有一份。
        // 计数必须走 `matching(identifier:)` —— `XCUIElement` 本身没有 `count`。
        XCTAssertEqual(
            app.buttons.matching(identifier: "settings.nav.account").count, 1,
            "存在多个设置页实例（重复呈现）"
        )
        XCTAssertEqual(
            app.buttons.matching(identifier: "settings.nav.back").count, 1,
            "存在多个「返回」按钮（重复呈现）"
        )

        app.buttons["settings.nav.back"].tap()
        XCTAssertTrue(
            waitForDisappearance(app.buttons["settings.nav.account"], timeout: 60),
            "点「返回」后设置页没有收拢消失"
        )

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
        /// 逐条射线量到的「内沿半径」（该射线上最靠近圆心的变化点距离）；无变化的射线不进来。
        let rayInnerRadii: [CGFloat]
        /// 逐条射线量到的「外沿半径」。
        let rayOuterRadii: [CGFloat]

        /// 有变化的射线数。
        var rayCount: Int { rayInnerRadii.count }
        /// 内沿半径的离散度（最大 − 最小）。**它是不是圆环、圆心在不在按钮上，就看这个值**。
        var innerSpread: CGFloat { Self.spread(rayInnerRadii) }
        var outerSpread: CGFloat { Self.spread(rayOuterRadii) }
        var medianInner: CGFloat { Self.median(rayInnerRadii) }
        var medianOuter: CGFloat { Self.median(rayOuterRadii) }

        private static func spread(_ values: [CGFloat]) -> CGFloat {
            guard let low = values.min(), let high = values.max() else { return 0 }
            return high - low
        }

        /// 中位数：比平均数抗「被屏幕边缘切掉的少数射线」这种离群值。
        private static func median(_ values: [CGFloat]) -> CGFloat {
            guard !values.isEmpty else { return 0 }
            return values.sorted()[values.count / 2]
        }
    }

    /// 从按钮中心沿 32 个方向、每 25pt 取一个样，找出有变化的最近 / 最远距离。
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
        var rayInner: [CGFloat] = []
        var rayOuter: [CGFloat] = []

        for ray in 0..<rayCount {
            let angle = 2 * Double.pi * Double(ray) / Double(rayCount)
            let dx = CGFloat(cos(angle))
            let dy = CGFloat(sin(angle))
            var hits: [CGFloat] = []
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
                hits.append(distance)
                nearest = min(nearest, distance)
                farthest = max(farthest, distance)
            }
            // 这条射线上变化区间的内沿 / 外沿。`hits` 天然按距离递增，首尾就是内外沿。
            if let inner = hits.first, let outer = hits.last {
                rayInner.append(inner)
                rayOuter.append(outer)
            }
        }

        return ChangedRegion(
            probeCount: probeCount,
            nearest: nearest,
            farthest: farthest,
            rayInnerRadii: rayInner,
            rayOuterRadii: rayOuter
        )
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
