import SwiftUI
import KebiaoCore

/// 齿轮按钮（工具栏左上）在**屏幕坐标**里的矩形。
///
/// 「设置」转场的起点就是它 —— 不做任何硬编码坐标。`reduce` 只接受非空值：
/// 工具栏按钮在首帧可能还没量到，空矩形不能把已经量到的值盖掉。
private struct GearFramePreferenceKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if !next.isEmpty { value = next }
    }
}

/// 根视图：课表主页 + 「设置」页的圆形铺开转场，并在**这一处**统一呈现课程编辑弹窗。
///
/// 两个入口（对照原版 `MainActivity`）：
/// - 左上「齿轮」→ 不再走 `NavigationLink` 的「从右向左 push」，而是 `openSettings()`
///   把 `SettingsRevealOverlay` 盖上来：以**齿轮按钮为圆心**做圆形遮罩扩张
///   （实现见 `SettingsTransition.swift`），返回时同一条几何路径反向收拢。
/// - 右上「＋」→ 新增课程（仍是 `editorRequest` → `.sheet`）。
///
/// 为什么设置页不再是 `NavigationStack` 的一个目的地：圆形铺开要求「起点在按钮上、
/// 终点是整屏内容」，而 push 会把主页整块换掉（圆形之外无处可露、必然露黑），
/// 而且自带一层从右向左的位移转场 —— 两层转场叠在一起必然打架。
/// 改成同一棵视图树里的浮层之后，**主页全程不卸载**：周次、滚动位置、课程数据
/// 原样保留，返回不需要任何「还原」逻辑。
///
/// 编辑弹窗仍然只在这里挂一次：`AppEnvironment.editorRequest` 是唯一入口，
/// 网格卡片点「更多」与右上「＋」写的是同一个状态，不会出现两层弹窗互相盖住。
struct RootView: View {

    @EnvironmentObject private var environment: AppEnvironment
    /// 系统「减弱动态效果」。
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    // MARK: - 转场时间常量
    //
    // 时间尺度参考「Apple 原生转场的自然感」，刻意不用带弹性的曲线：
    // 起点响应快、中段连续扩张、末段自然减速，全程没有回弹 / 过冲 / 果冻。

    /// 主体展开时长（0.55s，落在 0.45～0.60s 区间内）。
    private static let revealSeconds: TimeInterval = 0.55
    /// 收拢时长。比展开略短：退出比进入快一档，是 iOS 的既有节奏。
    private static let collapseSeconds: TimeInterval = 0.34
    /// 内容显现的滞后（与主体展开**重叠**，不产生空等）+ 自身的淡入时长。
    private static let contentDelaySeconds: TimeInterval = 0.16
    private static let contentSeconds: TimeInterval = 0.34
    /// 按钮按压反馈：缩到 0.96 到位约 0.08s，恢复约 0.10s。
    /// 它**不参与**减速（见 `transitionSlowdown`）：那是一次独立的、极短的触觉式反馈。
    private static let pressSeconds: TimeInterval = 0.08
    private static let pressRecoverySeconds: TimeInterval = 0.10
    private static let gearPressScale: CGFloat = 0.96
    /// 「防连点窗口」：设置页刚出现的这段时间里忽略「返回」。
    ///
    /// 为什么需要它：工具栏那颗返回键与齿轮在**屏幕上的同一坐标**，而 CI 实测
    /// （run `39109889672`）证明转场途中它就已经能被点到。真实用户「双击齿轮」的
    /// 第二下落在 ~0.3s 内，必须被这一窗口吃掉，否则会变成「刚打开又被自己关掉」。
    /// 过了这一窗口再点返回，就是**中途反悔** —— 按原路立即退回，不等到展开动画跑完。
    private static let reverseGuardSeconds: TimeInterval = 0.35
    /// 导航栏 leading 圆形按钮的默认布局（仅在几何量不到时兜底）。
    private static let navigationBarHeight: CGFloat = 44
    private static let leadingInset: CGFloat = 16

    // MARK: - UI 测试用的两个注入点
    //
    // ⚠️ 这两个键**只**在 UI 测试里通过启动参数打开，正常运行（含真机）都不存在，
    //    取值分别是 1 与 false，也就是「不减速、不强制减弱动态效果」。
    //    留这两个口子是为了让转场**可被看见**，而不是为了让断言变绿：
    //    - 转场只有 0.5 秒，而 `xcodebuild test` 的截图往返本身就有上百毫秒，
    //      CI 上根本截不到中间帧，「从按钮向外铺开」就只能靠肉眼猜；
    //    - 模拟器的「减弱动态效果」没法从测试进程里打开，只能在这里等价注入。
    //    减速只改**快慢**：几何、曲线形状、图层顺序、代码路径完全一致。

    /// 转场减速倍数。正常运行时恒为 1。
    private static let slowdownKey = "KebiaoTransitionSlowdown"
    /// 强制走「减弱动态效果」的替代转场。正常运行时恒为 false。
    private static let forceReduceMotionKey = "KebiaoForceReduceMotion"

    private let transitionSlowdown: Double

    init() {
        let requested = UserDefaults.standard.double(forKey: Self.slowdownKey)
        transitionSlowdown = requested > 0 ? requested : 1
    }

    private var reduceMotion: Bool {
        systemReduceMotion || UserDefaults.standard.bool(forKey: Self.forceReduceMotionKey)
    }

    // MARK: - 转场动画

    /// 主体展开：**临界阻尼弹簧**（`bounce: 0`）。spring 的起步比 ease 曲线更「跟手」，
    /// 末段自然收速；`bounce: 0` 保证全程没有回弹与过冲。
    private var revealAnimation: Animation {
        .spring(duration: Self.revealSeconds * transitionSlowdown, bounce: 0)
    }

    /// 内容显现：与主体展开重叠，但**略微滞后**（延迟 0.16s），不会出现
    /// 「等背景全铺完才看到内容」的空档感。
    private var revealContentAnimation: Animation {
        .easeOut(duration: Self.contentSeconds * transitionSlowdown)
            .delay(Self.contentDelaySeconds * transitionSlowdown)
    }

    /// 收拢：同一条几何路径反向播放，不是另换一套退出动画。
    private var collapseAnimation: Animation {
        .timingCurve(0.4, 0.0, 0.2, 1.0, duration: Self.collapseSeconds * transitionSlowdown)
    }

    /// 收拢时内容先淡出（比圆形收缩更快），免得圆缩小时还挂着一整页文字。
    private var collapseContentAnimation: Animation {
        .easeIn(duration: 0.14 * transitionSlowdown)
    }

    /// 「减弱动态效果」下的替代转场：没有圆形铺开，只做一次很短的整体淡入。
    private var reduceMotionAnimation: Animation {
        .easeInOut(duration: 0.22 * transitionSlowdown)
    }

    // MARK: - 转场状态

    @State private var settingsReveal: SettingsReveal?
    /// 齿轮按钮在屏幕坐标里的矩形，由按钮自己量（`GearFramePreferenceKey`）。
    @State private var gearFrame: CGRect = .zero
    /// 按压反馈：短暂缩到 0.96 再自然恢复，不拖慢后面的页面展开。
    @State private var gearPressed = false
    /// 安全区左上角在屏幕坐标里的位置（兜底起点的锚点）。
    @State private var safeAreaOrigin: CGPoint = .zero

    var body: some View {
        GeometryReader { rootProxy in
            ZStack {
                mainNavigation

                if let reveal = settingsReveal {
                    SettingsRevealOverlay(
                        reveal: reveal,
                        reduceMotion: reduceMotion,
                        pageBackground: Color(uiColor: .systemGroupedBackground)
                    ) {
                        SettingsPageHost(onBack: { closeSettings() })
                    }
                    // 盖住整屏（含导航栏），所以必须压在导航层之上。
                    .zIndex(1)
                }
            }
            .onPreferenceChange(GearFramePreferenceKey.self) { frame in
                gearFrame = frame
            }
            .onAppear { syncSafeAreaOrigin(rootProxy) }
            .onChange(of: rootProxy.size) { _, _ in syncSafeAreaOrigin(rootProxy) }
            .onChange(of: rootProxy.safeAreaInsets) { _, _ in syncSafeAreaOrigin(rootProxy) }
        }
        // `CourseEditorView.Mode` 是 `Identifiable`，闭包退出时 SwiftUI 会自动把
        // `editorRequest` 写回 nil；编辑器里的「取消 / 保存 / 删除」都走 `dismiss()`。
        .sheet(item: $environment.editorRequest) { mode in
            NavigationStack {
                CourseEditorView(mode: mode)
            }
        }
    }

    // MARK: - 主界面

    private var mainNavigation: some View {
        NavigationStack {
            TimetableView()
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        settingsEntry
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            environment.editorRequest = .create
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("添加课程")
                        .accessibilityIdentifier("tt.nav.addCourse")
                    }
                }
        }
    }

    /// 左上角齿轮：设置页转场的**唯一**入口，同时是整段动画的视觉起点。
    ///
    /// 它自己把矩形报到 `GearFramePreferenceKey`，所以动画起点永远等于
    /// **这一刻按钮在屏幕上的真实位置**（旋转、分屏、状态栏高度变化都会跟着变）。
    private var settingsEntry: some View {
        Button(action: openSettings) {
            Image(systemName: "gearshape")
                .scaleEffect(gearPressed ? Self.gearPressScale : 1)
        }
        .accessibilityLabel("设置")
        // XCUITest 定位用；改中文文案不会影响测试。
        .accessibilityIdentifier("tt.nav.settings")
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: GearFramePreferenceKey.self,
                    value: proxy.frame(in: .global)
                )
            }
        )
    }

    // MARK: - 打开 / 收起

    /// 打开设置页：以齿轮为圆心向外铺开。
    private func openSettings() {
        // 转场途中再点：直接忽略。绝不会开出第二个设置页、也不会重复导航。
        guard settingsReveal == nil else { return }

        let origin = gearFrame.isEmpty ? fallbackOrigin() : gearFrame

        // 按压反馈先动起来，但**不等它**：页面展开与它并行，反馈不会拖慢主转场。
        withAnimation(.easeOut(duration: Self.pressSeconds)) { gearPressed = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pressSeconds) {
            withAnimation(.easeInOut(duration: Self.pressRecoverySeconds)) { gearPressed = false }
        }

        settingsReveal = SettingsReveal(
            origin: origin,
            openedAt: Date(),
            progress: 0,
            contentVisible: false,
            interactive: false
        )

        // 先让 `progress = 0` 那一帧真正渲染出来（此刻圆只盖住按钮本身，等于「按钮
        // 变成了页面底色」），下一轮 runloop 再动到 1。若在同一轮里既插入浮层又改
        // `progress`，SwiftUI 会把初始值直接当成 1 —— 那就成了「凭空出现一整页」，
        // 丢掉从按钮长出来的过程。
        DispatchQueue.main.async {
            if reduceMotion {
                // 减弱动态效果：不做圆形铺开，只做一次很短的整体淡入。
                withAnimation(reduceMotionAnimation, completionCriteria: .logicallyComplete) {
                    settingsReveal?.progress = 1
                    settingsReveal?.contentVisible = true
                } completion: {
                    settingsReveal?.interactive = true
                }
            } else {
                withAnimation(revealAnimation, completionCriteria: .logicallyComplete) {
                    settingsReveal?.progress = 1
                } completion: {
                    settingsReveal?.interactive = true
                }
                withAnimation(revealContentAnimation) {
                    settingsReveal?.contentVisible = true
                }
            }
        }

        scheduleInteractionSafetyNet()
    }

    /// 收起设置页：圆形沿原路径收拢回齿轮按钮。
    ///
    /// **展开跑完**再点返回是正常退出；**跑到一半**点返回是「中途反悔」——
    /// 一样按同一条几何路径立即收拢，不用等动画跑完。
    ///
    /// 唯一的例外是下面那道 `reverseGuardSeconds` 窗口（理由见该常量的说明）。
    /// 为什么这个判断必须留在**状态**这一层、不能只靠命中测试：CI run `39109889672`
    /// 的日志里，转场途中（t=17.03s）那颗「返回」按钮**确实被合成了一次点击**，
    /// 而页面没有关 —— 挡下那一击的正是状态判断，不是命中测试。
    private func closeSettings() {
        // `progress > 0`：已经在收拢途中（模型值已到 0）再点就不重复触发。
        guard let reveal = settingsReveal, reveal.progress > 0 else { return }
        // 防连点窗口内忽略：那颗返回键与齿轮在同一坐标上，真实双击会落在这里。
        guard Date().timeIntervalSince(reveal.openedAt) >= Self.reverseGuardSeconds else { return }

        settingsReveal?.interactive = false
        withAnimation(collapseContentAnimation) { settingsReveal?.contentVisible = false }
        withAnimation(collapseAnimation, completionCriteria: .logicallyComplete) {
            settingsReveal?.progress = 0
        } completion: {
            // 只有真的收到 0 才摘掉浮层：否则会在收起动画的最后一帧闪空。
            if settingsReveal?.progress == 0 { settingsReveal = nil }
        }
        scheduleTeardownSafetyNet()
    }

    /// 兜底：万一收起动画的 completion 没有回调，也**保证浮层一定会被摘掉**。
    ///
    /// 为什么必须有：`progress` 被「打开 → 收起」两次动画接力之后，收起的 completion
    /// 在 CI 上表现为根本没有回调（run `39132644334`：页面视觉上已经收拢完，
    /// 浮层却仍留在视图树里，`waitForDisappearance` 一直等到 60s 超时）。
    /// 摘不掉浮层 = 主界面被一层看不见的遮罩永久挡着 —— 代价太大，不值得只靠一次回调。
    private func scheduleTeardownSafetyNet() {
        let delay = Self.collapseSeconds * transitionSlowdown + 0.3
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if let current = settingsReveal, current.progress == 0 {
                settingsReveal = nil
            }
        }
    }

    /// 兜底：万一动画的 completion 没有回调，也不让设置页停在「点不动」的状态。
    ///
    /// 这不是替代 completion，而是它的保险：`interactive` 卡在 false 会让整页永久
    /// 无法点击，代价太大，不值得只靠一次回调。
    private func scheduleInteractionSafetyNet() {
        let delay = (Self.revealSeconds + 0.3) * transitionSlowdown
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if let current = settingsReveal, !current.interactive, current.progress >= 1 {
                settingsReveal?.interactive = true
            }
        }
    }

    // MARK: - 几何

    /// 兜底起点：万一工具栏按钮的几何没量到（首帧 / 系统改了工具栏布局），
    /// 用安全区左上角 + iOS 导航栏的默认布局推一颗按钮出来，
    /// 保证动画**仍然从左上角那颗按钮的位置**开始，而不是从屏幕中心或屏幕外。
    private func fallbackOrigin() -> CGRect {
        let side = SettingsRevealCircle.minimumStartDiameter
        return CGRect(
            x: safeAreaOrigin.x + Self.leadingInset,
            y: safeAreaOrigin.y + (Self.navigationBarHeight - side) / 2,
            width: side,
            height: side
        )
    }

    /// 记录安全区左上角在屏幕坐标里的位置。
    ///
    /// 两种习惯都要兼容：有的布局里 `GeometryReader` 的 `frame` 本身已经缩进安全区
    /// （此时 `minY` 就是上边距），有的则是满屏 + `safeAreaInsets` 给出边距。
    /// 取两者较大值，任何一边为 0 都不会把结果带偏。
    private func syncSafeAreaOrigin(_ proxy: GeometryProxy) {
        let frame = proxy.frame(in: .global)
        safeAreaOrigin = CGPoint(
            x: max(frame.minX, proxy.safeAreaInsets.leading),
            y: max(frame.minY, proxy.safeAreaInsets.top)
        )
    }
}

#if DEBUG
struct RootView_Previews: PreviewProvider {
    static var previews: some View {
        RootView()
            .environmentObject(
                AppEnvironment(
                    // 预览不落盘：用一个内存仓库，避免预览进程写入真实 UserDefaults。
                    store: TimetableStore(repository: InMemoryTimetableRepository())
                )
            )
    }
}
#endif
