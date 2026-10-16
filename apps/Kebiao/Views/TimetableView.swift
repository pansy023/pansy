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

    static func == (lhs: CourseExpansion, rhs: CourseExpansion) -> Bool {
        lhs.course == rhs.course
            && lhs.sourceRect == rhs.sourceRect
            && lhs.targetRect == rhs.targetRect
            && lhs.progress == rhs.progress
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
        .background(Theme.pageBackground(dark: dark))
        // TODO(阶段④): 这里接「从教务系统同步 / 下拉刷新」。
        //             当前不发起任何网络请求（对应原版 autoSyncTimetableFromJwxt，本阶段不做）。
    }

    // MARK: - 滚动内容

    private var scrollContent: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 12) {
                WeekSwitcher()

                TimetableGrid(
                    displayedWeek: store.displayedWeek,
                    visibleWeekdays: store.visibleWeekdays,
                    weekDates: store.weekDates,
                    courses: displayedCourses,
                    occursThisWeek: occursThisWeekMap,
                    todayColumnIndex: store.todayColumnIndex,
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
            progress: 0
        )
        // 先让 progress = 0 的那一帧真正渲染出来（浮层此刻还只是叠在网格卡片上的
        // 同尺寸剪影），下一轮 runloop 再动到 1。若在同一轮里既插入浮层又改 progress，
        // SwiftUI 会把初始值直接当成 1 —— 那就成了「凭空冒出一张卡」，没有从卡片长大
        // 的过程，也就丢掉了原版原地展开的观感（`TimetableGridV2.kt:173-260`）。
        DispatchQueue.main.async {
            animateProgress(to: 1, animation: Self.expandAnimation)
        }
    }

    private func dismiss() {
        guard expansion != nil else { return }
        animateProgress(to: 0, animation: Self.collapseAnimation)
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

    /// 浮层用的 `progress` 绑定：写 1 = 展开，写 0 = 收起并摘除浮层。
    /// 这样 `CourseDetailOverlay` 不必知道收起动画的时长与曲线。
    private var progressBinding: Binding<CGFloat> {
        Binding(
            get: { expansion?.progress ?? 0 },
            set: { newValue in
                if newValue == 0 {
                    expansion = nil
                } else {
                    expansion?.progress = newValue
                }
            }
        )
    }

    // MARK: - 浮层

    @ViewBuilder
    private func overlay(for expansion: CourseExpansion) -> some View {
        // 展开卡统一用面板色打底：莫兰迪底色偏浅、白字读不清，
        // 详情卡优先保证可读性，而不是「和网格卡片同色」。
        let panelColor = Theme.panelColor(
            dark: dark,
            hasCustomBackground: settings.hasCustomBackground
        )

        CourseDetailOverlay(
            course: expansion.course,
            sourceRect: expansion.sourceRect,
            targetRect: expansion.targetRect,
            panelColor: panelColor,
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
