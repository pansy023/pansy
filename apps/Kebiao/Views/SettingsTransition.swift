import SwiftUI

/// 「课表主页 → 设置页」转场的状态。整段动画**只**由这里的数据驱动。
///
/// 三个字段共用同一条时间线（时间参数集中在 `RootView` 的时间常量里）：
/// - `progress`：圆形遮罩的展开进度。0 = 与齿轮按钮等大（只盖住按钮本身），
///   1 = 覆盖整屏四角；
/// - `contentVisible`：设置页内容的淡入开关，比遮罩**略滞后**（重叠，不空等）；
/// - `interactive`：内容是否接受点击。**动画跑完才置 `true`**，
///   这样转场途中的连点会被挡下，不会出现「点开一半又被点回去」或重复导航。
///   ⚠️ 这一位不能省：导航栏里的工具栏按钮由 UIKit 托管，SwiftUI 的
///   `allowsHitTesting` 拦不住它（实测见 `RootView.closeSettings` 的说明），
///   真正挡下「动画途中点返回」的是这个状态位。
///
/// `origin` 是齿轮按钮在**屏幕坐标**（`.global`）里的矩形，由按钮自己量出来
/// （`RootView` 的 `GearFramePreferenceKey`），不是硬编码坐标。
struct SettingsReveal: Equatable {
    let origin: CGRect
    var progress: CGFloat
    var contentVisible: Bool
    var interactive: Bool
}

/// 一次圆形展开的几何：圆心（遮罩图层的本地坐标）+ 起始 / 终止半径。
///
/// 两个图层各算一次（背景层铺满整屏、内容层在安全区里），所以这里必须接收
/// `layerFrame` 把屏幕坐标换算成各自的本地坐标 —— 圆心在屏幕上是同一个点。
struct SettingsRevealCircle: Equatable {

    /// 起始直径的下限。
    ///
    /// iOS 26 的工具栏按钮是「圆形玻璃底 + 图标」：能量到的往往只是**图标**的矩形
    /// （约 24pt），而系统画出来的圆形按钮触摸目标是 44pt。若直接用图标矩形当起点，
    /// 展开的第一帧会出现「灰底圆比按钮圆小一圈」的破绽（按钮的玻璃底从圆外露出来）。
    static let minimumStartDiameter: CGFloat = 44

    let center: CGPoint
    let startRadius: CGFloat
    let endRadius: CGFloat

    /// - Parameters:
    ///   - origin: 齿轮按钮在屏幕坐标里的矩形（`SettingsReveal.origin`）。
    ///   - layerFrame: 遮罩图层自己的屏幕坐标矩形（`.global`）。
    init(origin: CGRect, layerFrame: CGRect) {
        let center = CGPoint(
            x: origin.midX - layerFrame.minX,
            y: origin.midY - layerFrame.minY
        )
        let side = max(min(origin.width, origin.height), Self.minimumStartDiameter)
        let start = side / 2

        // 终止半径取到**最远角**的距离，再乘 1.02 留一点余量：
        // progress = 1 时圆一定盖住整块图层的四个角，不会留背景闪烁 / 黑边 / 透明空洞。
        // （全程用 Double 算：`CGFloat` 的 `sqrt` 重载不在标准库里，显式转换最稳。）
        let farX = max(center.x, max(layerFrame.width - center.x, 0))
        let farY = max(center.y, max(layerFrame.height - center.y, 0))
        let diagonal = (Double(farX) * Double(farX) + Double(farY) * Double(farY)).squareRoot()
        let end = max(CGFloat(diagonal) * 1.02, start + 1)

        self.center = center
        self.startRadius = start
        self.endRadius = end
    }
}

/// 以按钮中心为心、半径随 `progress` 从 `start` 长到 `end` 的圆形遮罩。
///
/// 动 `scaleEffect` 而不是动 `frame`：变换插值在合成层完成，不会被布局往返拖慢，
/// 也不会让被遮罩的 `NavigationStack` 每一帧重新测量一遍。
/// （`scaleEffect` 必须在 `.position` **之前**：`.position` 之后视图已经被撑成整块图层，
/// 那时再缩放就会绕图层中心缩放，圆心会漂走。）
private struct RevealCircleMask: View {

    let progress: CGFloat
    let circle: SettingsRevealCircle

    var body: some View {
        let clamped = min(max(progress, 0), 1)
        let radius = circle.startRadius + (circle.endRadius - circle.startRadius) * clamped
        Circle()
            .frame(width: circle.endRadius * 2, height: circle.endRadius * 2)
            .scaleEffect(circle.endRadius > 0 ? radius / circle.endRadius : 1)
            .position(circle.center)
    }
}

/// 把设置页从齿轮按钮位置**向外铺开**的转场容器。
///
/// 为什么用圆形遮罩，而不是「整页缩放 + 淡入」：遮罩的圆心与起始半径直接取自按钮矩形，
/// 所以展开区域的起点与按钮**严格重合**；终态半径取到屏幕最远角，四角必被覆盖。
///
/// 图层（从下到上）：
/// 1. 铺满整屏（含状态栏 / Home 指示器区域）的展开背景 —— 被圆形遮罩裁剪；
/// 2. 转场途中的点击闸门 —— 动画没跑完时把点击全部吃掉；
/// 3. 设置页内容 —— 同一个圆形遮罩，但布局在**安全区**里，淡入 + 从下方 10pt 归位。
///
/// 背景与内容刻意分成两层、各自量自己的 `.global` 矩形：`.ignoresSafeArea()` 会把
/// 子视图的安全区一并吃掉，若把内容放进同一个忽略安全区的容器里，「设置」标题会顶进
/// 状态栏。分成两层才能同时做到「背景铺满整屏」与「内容尊重安全区」。
struct SettingsRevealOverlay<Content: View>: View {

    let reveal: SettingsReveal
    /// 系统「减弱动态效果」：不做圆形铺开，退化成一次很短的整体淡入。
    let reduceMotion: Bool
    /// 展开背景色。取 `systemGroupedBackground` —— 与设置页 `Form` 的底色**完全相同**，
    /// 否则背景铺满与内容显现交界处会有一次肉眼可见的颜色跳变。
    let pageBackground: Color
    @ViewBuilder var content: () -> Content

    /// 内容归位前的下沉量（pt）：从下方 10pt 处浮上来，落在「6～12pt」区间内。
    private static var contentOffset: CGFloat { 10 }

    var body: some View {
        ZStack {
            fullScreenBackground

            if !reveal.interactive {
                // 纯透明但**参与命中测试**：转场途中的点击在这里被吃掉，
                // 既不会点到还没铺开的内容，也不会穿透下去点课表。
                // 转场结束后这一层直接消失，不留任何遮挡或无法点击的残留视图。
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
            }

            contentLayer
        }
    }

    // MARK: - 图层

    /// ① 铺满整屏的展开背景（圆形遮罩的实际载体）。
    private var fullScreenBackground: some View {
        GeometryReader { proxy in
            let circle = SettingsRevealCircle(
                origin: reveal.origin,
                layerFrame: proxy.frame(in: .global)
            )
            let background = pageBackground
                .frame(width: proxy.size.width, height: proxy.size.height)

            if reduceMotion {
                background.opacity(reveal.contentVisible ? 1 : 0)
            } else {
                background.mask(RevealCircleMask(progress: reveal.progress, circle: circle))
            }
        }
        .ignoresSafeArea()
    }

    /// ③ 设置页内容（安全区内正常布局，同样被圆形遮罩裁剪）。
    private var contentLayer: some View {
        GeometryReader { proxy in
            let circle = SettingsRevealCircle(
                origin: reveal.origin,
                layerFrame: proxy.frame(in: .global)
            )
            let layer = content()
                .frame(width: proxy.size.width, height: proxy.size.height)
                .opacity(reveal.contentVisible ? 1 : 0)
                // `.offset` 只做渲染位移、不改布局矩形，所以下面 `.mask` 的圆心
                // 仍然钉在按钮上：内容是「在固定圆里从下方 10pt 归位」，
                // 不是「整页带着圆一起位移」。
                .offset(y: reveal.contentVisible || reduceMotion ? 0 : Self.contentOffset)

            if reduceMotion {
                layer
            } else {
                layer.mask(RevealCircleMask(progress: reveal.progress, circle: circle))
            }
        }
        // 动画跑完之前不接受点击；期间由上面的闸门接管转场途中的点击。
        .allowsHitTesting(reveal.interactive)
    }
}

/// 转场目标：设置页本身。
///
/// 为什么这里自己起一个 `NavigationStack`：设置页原先是 `NavigationStack` 的一个
/// `NavigationLink` 目的地，靠系统返回键退出；现在它是浮层里的**根**，没有系统返回键，
/// 所以左上角那颗圆形返回按钮由这里提供（文案/图标/iOS 26 的圆形玻璃样式与系统一致）。
/// 页内的两个二级入口（「账号与同步」「学期与时间」）仍是普通 push，保持不变。
///
/// ⚠️ 整个转场里**只**创建这一个设置页实例：状态源仍是全局唯一的 `TimetableStore`，
/// 不会出现两个设置页各说各话。
struct SettingsPageHost: View {

    let onBack: () -> Void

    var body: some View {
        NavigationStack {
            SettingsView()
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: onBack) {
                            Image(systemName: "chevron.left")
                        }
                        .accessibilityLabel("返回")
                        .accessibilityIdentifier("settings.nav.back")
                    }
                }
        }
    }
}
