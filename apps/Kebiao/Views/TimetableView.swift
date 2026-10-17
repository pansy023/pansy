import SwiftUI
import KebiaoCore

/// 展开浮层的运行态：几何在**点开那一刻冻结**。
///
/// 冻结而不是持续重算，是为了让「原地展开」的语义稳定：
/// 手指点下去之后用户在浮层下面滚动课表，浮层不该跟着漂。
/// 几何一旦不可用（旋转、分屏改尺寸），就用无动画事务清掉它。
private struct CourseExpansion: Equatable {
    /// 被点开的课程（合并后的卡片）。
    let course: Course
    /// 起始矩形：网格里那张小卡片（浮层坐标系）。
    let sourceRect: CGRect
    /// 目标矩形：`TimetableLayout.expandTarget` 给出的展开位置（浮层坐标系）。
    let targetRect: CGRect
    /// 展开动画进度：0 = 网格态，1 = 展开态。**唯一的动画驱动值**。
    var progress: CGFloat
    /// 网格里那张卡片的样式（底色 / 文字色）。展开卡**沿用同一份**，
    /// 保证大卡片与小卡片颜色完全一致。
    let cardStyle: CourseCardStyle

    static func == (lhs: CourseExpansion, rhs: CourseExpansion) -> Bool {
        lhs.course == rhs.course
            && lhs.sourceRect == rhs.sourceRect
            && lhs.targetRect == rhs.targetRect
            && lhs.progress == rhs.progress
            && lhs.cardStyle == rhs.cardStyle
    }
}

/// 课表主页。
///
/// 结构（上 → 下）：`WeekSwitcher` 周次横幅 → `TimetableGrid` 网格 →
/// 最上层挂着原地展开的 `CourseDetailOverlay`。
///
/// 展开交互（对照 Android 1.11.x）：
/// - 点卡片：`TimetableGrid` 上报卡片在**浮层坐标系**里的矩形；这里先取
///   「网格可见区域」当夹取边框，再调用
///   `TimetableLayout.expandTarget(origin:boxWidth:boxHeight:)`
///   算出目标矩形（证据：`apk_work/kb/src2/TimetableGridV2.kt:191-207`，
///   逐行展开见 `docs/recon/algorithms.md` §5.2），最后把 `progress` 从 0 动到 1。
/// - 浮层内部**所有**视觉属性（位置、尺寸、圆角、阴影、不透明度）
///   都由这一个 `progress` 插值出来，见 `CourseDetailOverlay` 里的 `FloatingCardAnimator`。
/// - 收起：`progress` 动回 0；收到 0 之后才把 `expansion` 置 nil，
///   否则浮层会在收起动画的最后一帧闪空。
///
/// 几何失效（旋转 / 分屏 / 键盘改高度）时的处理：`GeometryReader` 尺寸一变就
/// 立刻用无动画事务取消展开，绝不让卡片停在屏幕外。
struct TimetableView: View {

    @EnvironmentObject private var environment: AppEnvironment

    /// 展开浮层所用的具名坐标系。网格与浮层都用它测量，保证同一套坐标。
    private static let overlaySpaceName = "kebiao.timetable.overlay"

    /// 展开 ≈ 300–450ms、收起 ≈ 250–350ms，单一 ease 曲线、**无弹簧回弹**。
    private static let expandAnimation: Animation = .timingCurve(0.2, 0.0, 0.2, 1.0, duration: 0.38)
    private static let collapseAnimation: Animation = .timingCurve(0.4, 0.0, 0.2, 1.0, duration: 0.30)

    @State private var expansion: CourseExpansion?
    /// 网格矩形（浮层坐标系），由 `TimetableGrid` 从下往上回传。
    @State private var gridFrameInOverlay: CGRect = .zero
    /// 根视图（浮层坐标系）的尺寸，由最外层 `GeometryReader` 提供。
    /// 用它当可见区域，避免任何 `UIScreen` 依赖。
    @State private var rootSize: CGSize = .zero

    private var store: TimetableStore { environment.store }
    private var settings: AppSettings { store.settings }
    private var dark: Bool { store.uiFlags.isDarkTheme }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 页面底色 + 自定义背景图（`AppSettings.backgroundImageUri`）。
            // 铺在**所有内容之下**并忽略安全区，这样网格面板的半透明
            // （有自定义背景时 alpha 0.62，见 `Theme.panelColor`）下面透出来的
            // 就是背景图，与原版 `hasCustomBackground` 的语义一致。
            AppBackground(uri: settings.backgroundImageUri, dark: dark)
                .ignoresSafeArea()

            GeometryReader { rootProxy in
                ZStack(alignment: .topLeading) {
                    scrollContent
                        .onChange(of: rootProxy.size, initial: true) { _, newValue in
                            rootSize = newValue
                        }

                    if let expansion {
                        overlay(for: expansion)
                    }
                }
                .coordinateSpace(.named(Self.overlaySpaceName))
                .onChange(of: rootProxy.size) { _, newValue in
                    // 旋转 / 尺寸变化：旧几何在屏幕上已不成立，直接取消展开。
                    // 不做动画 —— 屏幕正在转，任何补间都只会看起来更乱。
                    rootSize = newValue
                    if let current = expansion, !isUsable(current, containerSize: newValue) {
                        clearExpansion()
                    }
                }
            }
        }
        // TODO(阶段④): 这里接「从教务系统同步 / 下拉刷新」。
        //             当前不发起任何网络请求（对应原版 autoSyncTimetableFromJwxt，本阶段不做）。
    }

    // MARK: - 滚动内容

    private var scrollContent: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 12) {
                WeekSwitcher()

                // 「显示主界面滑动条」（`showWeekSlider`）。原版在网格**上方**
                // 画一个 1…semesterWeeks 的 Slider + 居中「第N周」小字
                // （`TimetableScreenKt.java:4367-4409`，`TimetableWeekPage`）：
                // 拖动时 `weekOffset = coerceIn(值, 1, 学期周数) - 当前教学周`。
                // 这里逐条照抄该语义，值直接取 `displayedWeek`。
                if settings.showWeekSlider {
                    weekSlider
                }

                TimetableGrid(
                    displayedWeek: store.displayedWeek,
                    visibleWeekdays: store.visibleWeekdays,
                    weekDates: store.weekDates,
                    courses: displayedCourses,
                    occursThisWeek: occursThisWeekMap,
                    onTapCard: { tap in handleTap(tap) },
                    overlaySpaceName: Self.overlaySpaceName,
                    gridFrameInOverlay: $gridFrameInOverlay
                )

                // 网格底部的呼吸空间。
                Color.clear.frame(height: 24)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
        // 换周后课程集合变了，展开卡里的数据可能已不属于这一周，直接收起。
        .onChange(of: store.displayedWeek) { _, _ in clearExpansion() }
    }

    // MARK: - 主界面周次滑动条

    /// `showWeekSlider` 打开时显示的周次滑动条。
    ///
    /// 语义逐条对应 `TimetableScreenKt.java:4367-4409`：
    /// - 上界 = `semesterWeeks.coerceAtLeast(1)`；
    /// - 当前值 = 显示周次夹在 `1…上界`；
    /// - 拖动 → `weekOffset = 新值 - 当前教学周`（原版传的是 offset，由
    ///   `TimetableViewModel.setCurrentWeekOffset` 落地）。
    private var weekSlider: some View {
        let semesterWeeks = max(settings.semesterWeeks, 1)
        let current = min(max(store.displayedWeek, 1), semesterWeeks)

        return VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { Double(current) },
                    set: { newValue in
                        let week = min(max(Int(newValue.rounded()), 1), semesterWeeks)
                        store.weekOffset = week - store.currentWeek
                    }
                ),
                in: 1...Double(semesterWeeks),
                step: 1
            )
            .accessibilityLabel("周次")
            // 拖动停止后供 VoiceOver 读出的完整周次文案（"第N周"）。
            .accessibilityValue(store.weekNumberText)
            .accessibilityIdentifier("tt.week.slider")
            Text("第\(current)周")
                .font(.system(size: 11))
                .foregroundColor(Theme.secondaryInk(dark: dark))
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.panelColor(dark: dark, hasCustomBackground: settings.hasCustomBackground))
        )
        // ⚠️ 这里**不能**用 `.accessibilityElement(children: .combine)`。
        //
        // 早先为了「让 VoiceOver 读出完整周次」在容器上加了 `.combine` + `.accessibilityValue`，
        // 结果把容器合成了**一个**无障碍元素，里面 Slider 自己的 identifier 被吞掉 ——
        // XCUITest 的 `app.sliders["tt.week.slider"]` 直接找不到元素，
        // 于是「主界面滑动条」这条链路的 UI 测试必然失败（而界面本身并没有坏）。
        // 现在把 `accessibilityValue` 挂在 Slider 自己身上，VoiceOver 语义不变，
        // 同时 Slider 仍是独立元素，可被 `app.sliders["tt.week.slider"]` 定位。
    }

    // MARK: - 数据

    /// 当前显示周要画的课程。
    /// `coursesForDisplayedWeek()` 已经处理了「是否显示非本周课程」这个设置
    /// （`TimetableStore.swift:200-213`），视图不再二次过滤。
    private var displayedCourses: [Course] {
        store.coursesForDisplayedWeek().map(\.course)
    }

    /// `Course.id → 是否在本周出现`。合并卡片沿用合并链首张的 `id`
    /// （`TimetableLayout.mergeAdjacent` 的约定，`TimetableLayout.swift:117-156`），
    /// 所以用 `id` 查表是安全的。
    private var occursThisWeekMap: [Int: Bool] {
        var map: [Int: Bool] = [:]
        for entry in store.coursesForDisplayedWeek() {
            map[entry.course.id] = entry.occursThisWeek
        }
        return map
    }

    // MARK: - 展开 / 收起

    private func handleTap(_ tap: CourseCardTap) {
        // 卡片本身没测到（第一帧）就不展开：没有起点的放大动画没有意义。
        guard !tap.frameInOverlay.isEmpty else { return }

        // 夹取边框 = 网格**当前可见**的那一块（网格矩形 ∩ 根视图矩形）。
        // 不直接用整屏：屏幕含导航栏，`expandTarget` 的
        // `[margin, box - size - margin]` 会把卡片推到导航栏底下。
        // 网格可见区域的 `minX/minY` 与根视图原点不一定相同（横向内边距），
        // 所以源矩形先换算到「可见区域的局部坐标」，算完目标矩形再平移回来。
        let viewport = visibleGridViewport()
        let viewportOrigin = viewport.origin
        let localSource = tap.frameInOverlay
            .offsetBy(dx: -viewportOrigin.x, dy: -viewportOrigin.y)

        let target = TimetableLayout.expandTarget(
            origin: LayoutRect(
                left: Double(localSource.minX),
                top: Double(localSource.minY),
                width: Double(localSource.width),
                height: Double(localSource.height)
            ),
            boxWidth: Double(viewport.width),
            boxHeight: Double(viewport.height)
        )
        let targetRect = CGRect(
            x: target.left + Double(viewportOrigin.x),
            y: target.top + Double(viewportOrigin.y),
            width: target.width,
            height: target.height
        )

        expansion = CourseExpansion(
            course: tap.course,
            sourceRect: tap.frameInOverlay,
            targetRect: targetRect,
            progress: 0,
            cardStyle: tap.style
        )
        // 先让 progress = 0 的那一帧真正渲染出来（浮层此刻还只是叠在网格卡片上的
        // 同尺寸剪影），下一轮 runloop 再动到 1。若在同一轮里既插入浮层又改 progress，
        // SwiftUI 会把初始值直接当成 1 —— 那就成了「凭空冒出一张卡」，没有从卡片长大
        // 的过程，也就丢掉了原版原地展开的观感（`TimetableGridV2.kt:173-260`）。
        DispatchQueue.main.async {
            animateProgress(to: 1, animation: Self.expandAnimation)
        }
    }

    /// 收起浮层。
    ///
    /// ⚠️ 这里**必须**在收起动画跑完之后真的把 `expansion` 置 nil，不能只把
    /// `progress` 动回 0。原因是 `CourseDetailOverlay` 的压暗层用了
    /// `.contentShape(Rectangle())` + `.onTapGesture`：`progress` 到 0 之后卡片只是
    /// `opacity 0`（仍然可命中），那一层压暗背景同样还留在视图树里 ——
    /// 结果是浮层永远收不回去，而且**课表上的每一次点击都会被它吃掉**。
    /// （CI 里 `testTappingCourseCardOpensAndDismissesDetailOverlay` 点「收起」后
    /// `overlay.button.more` 一直 `exists == 1`，就是这个缺陷的直接证据。）
    private func dismiss() {
        guard expansion != nil else { return }
        withAnimation(Self.collapseAnimation, completionCriteria: .logicallyComplete) {
            expansion?.progress = 0
        } completion: {
            // 动画结束回调可能在下一轮 runloop 才跑，这里再确认一次当前进度，
            // 避免「收起动画播到一半又被点开」时把新展开的浮层误摘掉。
            if expansion?.progress == 0 {
                expansion = nil
            }
        }
    }

    /// 无动画取消（换周、旋转、几何失效）。
    private func clearExpansion() {
        guard expansion != nil else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            expansion = nil
        }
    }

    private func animateProgress(to value: CGFloat, animation: Animation) {
        withAnimation(animation) {
            expansion?.progress = value
        }
    }

    /// 浮层用的 `progress` 绑定。
    ///
    /// `CourseDetailOverlay` 只**读**它（显隐、位置、圆角、阴影、不透明度全部由这个
    /// 值插值出来），从不往回写。所以这里也只有一个诚实的 `set`。
    ///
    /// ⚠️ 早先这里写的是「`set` 到 0 就 `expansion = nil`」，而 `dismiss()` 只调
    /// `animateProgress(to: 0)` 绕过 binding —— 那个 `nil` 分支永远走不到，
    /// 浮层因此既收不回去、又永久留在视图树里吃掉课表点击（见 `dismiss()` 的说明）。
    /// 现在摘除浮层由 `dismiss()` 的动画完成回调唯一负责，这里不再假装能做这件事。
    private var progressBinding: Binding<CGFloat> {
        Binding(
            get: { expansion?.progress ?? 0 },
            set: { expansion?.progress = $0 }
        )
    }

    // MARK: - 浮层

    @ViewBuilder
    private func overlay(for expansion: CourseExpansion) -> some View {
        // 展开卡沿用网格里那张小卡片**同一份**解算样式：小卡片是什么颜色，
        // 弹出的大卡片就是什么颜色（不再是面板色 / 白色），与安卓端一致。
        let cardStyle = expansion.cardStyle

        CourseDetailOverlay(
            course: expansion.course,
            sourceRect: expansion.sourceRect,
            targetRect: expansion.targetRect,
            cardBackground: cardStyle.background,
            cardInk: cardStyle.ink,
            progress: progressBinding,
            showsTime: settings.showCourseTime,
            showsLocation: settings.showCourseLocation,
            showsTeacher: settings.showCourseTeacher,
            timeRangeText: TimetableLayout.buildTimeRange(
                expansion.course,
                timeSlots: store.timeSlots
            ),
            gridTextSize: gridTextSize(for: expansion.course),
            onDismiss: { dismiss() },
            onMore: { course in
                // 「更多」→ 课程编辑（原版 `AddCourseScreen`，字段与校验见
                // `CourseEditorView` 头部注释）。先把展开浮层收掉：弹窗要盖住整屏，
                // 底下留一张展开卡既没有意义，收起时还会和 sheet 的转场叠在一起。
                clearExpansion()
                environment.editorRequest = .edit(course)
            }
        )
    }

    /// 网格卡片的字号（`fitTextSize` 的结果），详情标题按它放大。
    /// 高度取 `MinCardHeight`：详情标题只关心「用户配置的字号」这一项，
    /// 而 `fitTextSize` 在最小高度下会夹到 7 —— 为避免拿到被夹过的 7，
    /// 这里直接按用户配置值与夹取下限取大者。
    private func gridTextSize(for course: Course) -> Int {
        let configured = settings.courseTextSizeSp
        let fitted = TimetableLayout.fitTextSize(
            configured: configured,
            heightDp: Double(settings.courseCellHeightDp)
        )
        return max(fitted, min(max(configured, 7), 30))
    }

    // MARK: - 几何

    /// 网格当前可见的那一块（浮层坐标系）。
    ///
    /// = 网格矩形 ∩ 根视图矩形。例：网格比屏幕高时（节次多、行高大），
    /// 交集就是屏幕内那一段；展开卡因此永远被夹在看得见的地方。
    /// 网格还没测到（第一帧）时退回整块根视图：宁可稍微不准，也不要返回零矩形
    /// 让 `expandTarget` 拿 `boxW/boxH == 0` 去夹取。
    private func visibleGridViewport() -> CGRect {
        let screen = CGRect(origin: .zero, size: rootSize)
        let grid = gridFrameInOverlay
        guard !grid.isEmpty, !screen.isEmpty else { return screen }
        let intersection = grid.intersection(screen)
        guard !intersection.isNull, !intersection.isEmpty else { return screen }
        return intersection
    }

    /// 旋转 / 分屏改尺寸之后，冻结的几何是否还能用。
    ///
    /// 展开时几何是**冻结**的（点下去那一刻量到的值），所以屏幕一变就必须重新判断：
    /// 一旦起始卡片或目标矩形已经整个跑出新的可见区域，就取消展开 —— 这比让卡片
    /// 悬在屏幕外、或者瞬间跳到另一个位置要诚实得多。
    private func isUsable(_ expansion: CourseExpansion, containerSize: CGSize) -> Bool {
        guard containerSize.width > 0, containerSize.height > 0 else { return false }
        guard !expansion.sourceRect.isEmpty, !expansion.targetRect.isEmpty else { return false }
        let visible = CGRect(origin: .zero, size: containerSize)
        return !expansion.sourceRect.intersection(visible).isNull
            && !expansion.targetRect.intersection(visible).isNull
    }
}

#if DEBUG
struct TimetableView_Previews: PreviewProvider {
    static var previews: some View {
        TimetableView()
            .environmentObject(
                AppEnvironment(store: TimetableStore(repository: InMemoryTimetableRepository()))
            )
    }
}
#endif
