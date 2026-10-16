import SwiftUI
import KebiaoCore

// MARK: - 单值驱动的展开动画

/// 从 `source` 到 `target` 的插值。**所有**视觉属性都只由 `progress` 驱动：
/// 位置、尺寸、圆角、阴影、底色不透明度。
///
/// 为什么不用 `scaleEffect`：原版是用 `animateRectAsState` 对矩形本身做插值
/// （`apk_work/kb/src2/TimetableGridV2.kt:173-260` 的展开动画段），
/// 而 `scaleEffect` 只会把已经排好版的卡片整体拉大——字号、行距、内边距全部失真，
/// 所以这里改成「真·改帧」：内容每次都以当前插值出的宽高重新排版。
private struct FloatingCardAnimator: AnimatableModifier {

    /// 0 = 还是网格里那张小卡片；1 = 完整的展开卡片。
    var progress: CGFloat
    let source: CGRect
    let target: CGRect
    let panelColor: Color

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let p = min(max(progress, 0), 1)

        let rect = CGRect(
            x: source.minX + (target.minX - source.minX) * p,
            y: source.minY + (target.minY - source.minY) * p,
            width: source.width + (target.width - source.width) * p,
            height: source.height + (target.height - source.height) * p
        )
        let radius = Theme.cardRadius + (Theme.expandedCardRadius - Theme.cardRadius) * p
        let shadowRadius = 2 + 16 * p
        let shadowOpacity = 0.10 + 0.22 * p
        let borderOpacity = 0.20 * p

        return ZStack(alignment: .topLeading) {
            Color.clear
            content
                // 用 `.frame` 把「插值出的尺寸」真正落到布局上，内容因此重新排版。
                .frame(width: rect.width, height: rect.height)
                // 不透明底座：展开后卡片必须完全盖住下面网格里那张小卡片。
                .background(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(panelColor)
                )
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Color.white.opacity(borderOpacity), lineWidth: 0.5)
                )
                .shadow(
                    color: Color.black.opacity(shadowOpacity),
                    radius: shadowRadius,
                    x: 0,
                    y: 2 + 6 * p
                )
                .offset(x: rect.minX, y: rect.minY)
                // 进度为 0 时彻底不可见：避免「点了没反应」的那一帧里
                // 浮层还留着一个和网格卡片重叠的影子。
                .opacity(Double(min(1, p * 4)))
        }
    }
}

private extension View {
    func floatingCard(
        progress: CGFloat,
        source: CGRect,
        target: CGRect,
        panelColor: Color
    ) -> some View {
        modifier(
            FloatingCardAnimator(
                progress: progress,
                source: source,
                target: target,
                panelColor: panelColor
            )
        )
    }
}

// MARK: - 展开浮层

/// 原地展开的课程详情浮层——没有 `NavigationLink`，没有 `.sheet`，没有 push。
///
/// 行为对照 Android 1.11.x：
/// - 点卡片 → 同一张卡片以自身中心为锚点长大成详情卡（`TimetableGridV2.kt:191-207`
///   的 `expandTarget` + `:173-260` 的展开动画）；
/// - 点背景 / 点右上角 ✕ → 收回网格原位；
/// - 展开期间不做页面跳转，也不阻断整个 App（背景只做压暗，不拦手势之外的交互）。
struct CourseDetailOverlay: View {

    /// 正在展开的课程（合并后的卡片，`id` 是合并链首张的 id）。
    let course: Course
    /// 起点：网格里那张小卡片在浮层坐标系里的矩形。
    let sourceRect: CGRect
    /// 终点：`TimetableLayout.expandTarget` 算出的矩形（浮层坐标系）。
    let targetRect: CGRect
    /// 卡片的配景色（展开态统一用面板色打底，保证文字对比度稳定）。
    let panelColor: Color
    /// 展开/收回的进度：0 网格态，1 展开态。显隐由它驱动，不用 `.transition`。
    /// 写 0 表示「收起完成」，调用方据此摘掉浮层。
    @Binding var progress: CGFloat
    /// 三行详情各自的显示开关，来自设置。
    let showsTime: Bool
    let showsLocation: Bool
    let showsTeacher: Bool
    /// 时间区间文本。**必须**由调用方用
    /// `TimetableLayout.buildTimeRange(_:timeSlots:)` 生成（`TimetableGridV2.kt:796-805`）。
    let timeRangeText: String
    /// 网格卡片用的字号（`fitTextSize` 的结果），详情标题按它放大。
    let gridTextSize: Int
    /// 点击背景 / ✕ / 旋转失效时的关闭回调。
    let onDismiss: () -> Void
    /// 底部「更多」。
    let onMore: (Course) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 压暗背景。点它收回，和原版「点空白处收起」一致。
            Color.black.opacity(0.28 * Double(progress))
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }
                .accessibilityHidden(true)

            detailCard
                .floatingCard(
                    progress: progress,
                    source: sourceRect,
                    target: targetRect,
                    panelColor: panelColor
                )
                // 卡片自己要吃掉点击，避免穿透到背景把浮层关掉。
                .contentShape(Rectangle())
        }
        // 浮层的出现没有自己的过渡：显隐完全由 `progress` 驱动
        // （progress → 0 时卡片缩回原卡片大小并淡出）。
    }

    // MARK: 详情内容

    private var detailCard: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(course.name)
                        .font(.system(size: titleSize, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(3)
                        .minimumScaleFactor(0.8)
                        .padding(.trailing, 26)

                    if let locationLine {
                        detailRow(systemImage: "mappin.and.ellipse", text: locationLine)
                    }
                    if showsTeacher, !course.teacher.isEmpty {
                        detailRow(systemImage: "person", text: course.teacher)
                    }
                    if showsTime, !timeRangeText.isEmpty {
                        detailRow(systemImage: "clock", text: timeRangeText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 54)
            }

            // ✕：右上角固定，不随内容滚动。
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white.opacity(0.9))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.black.opacity(0.18)))
            }
            .padding(8)
            .accessibilityLabel("收起")

            // 「更多」：固定在卡片底部，永远可点（不放在 ScrollView 里，
            // 免得内容超高时按钮被顶出可视区）。
            VStack {
                Spacer(minLength: 0)
                Button {
                    onMore(course)
                } label: {
                    Text("更多")
                        .font(Theme.detailBodyFont.weight(.medium))
                        .foregroundColor(.white.opacity(0.95))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.black.opacity(0.16))
                        )
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func detailRow(systemImage: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.85))
                .frame(width: 14)
            Text(text)
                .font(Theme.detailBodyFont)
                .foregroundColor(.white.opacity(0.95))
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
    }

    /// 标题比网格卡片大，但跟 `fitTextSize` 的结果联动 —— 用户把字号调大时，
    /// 详情卡也跟着变大，不会出现「网格里字比详情页还大」的割裂感。
    private var titleSize: CGFloat {
        CGFloat(min(max(gridTextSize + 4, 14), 20))
    }

    /// 地点行的文本：优先「楼名 + 教室」，两者都没有就不显示。
    ///
    /// `building` / `room` 都直接来自模型（`Course.building` / `Course.room`，
    /// 对应 `TimetableGridV2.kt:733-741` 的 `buildingOf` / `roomOf`），
    /// 这里只做拼接，不做任何解析。
    private var locationLine: String? {
        guard showsLocation, !course.location.isEmpty else { return nil }
        let building = course.building
        let room = course.room
        if !building.isEmpty, !room.isEmpty, building != course.location {
            return "\(building) · \(room)"
        }
        return course.location
    }
}

#if DEBUG
struct CourseDetailOverlay_Previews: PreviewProvider {
    static var previews: some View {
        let sample = Course(
            id: 1,
            name: "数据结构与算法",
            teacher: "李四",
            location: "教二楼 305",
            dayOfWeek: 2,
            startPeriod: 3,
            endPeriod: 4,
            color: 0,
            weekRange: "1-16"
        )
        // 预览里复现一遍真实调用方的几何约定：
        // 源卡片与目标矩形同处「浮层坐标系」，而 `expandTarget` 的 box 用**可见网格**
        // （这里假设网格从 y = 90 开始、高 610），所以源卡片先平移到网格局部坐标，
        // 算完再把结果平移回浮层坐标。`TimetableView.handleTap` 是同一套换算。
        let source = CGRect(x: 120, y: 260, width: 46, height: 60)
        let gridViewport = CGRect(x: 0, y: 90, width: 390, height: 610)
        let localSource = source.offsetBy(dx: -gridViewport.minX, dy: -gridViewport.minY)
        let target = TimetableLayout.expandTarget(
            origin: LayoutRect(
                left: Double(localSource.minX),
                top: Double(localSource.minY),
                width: Double(localSource.width),
                height: Double(localSource.height)
            ),
            boxWidth: Double(gridViewport.width),
            boxHeight: Double(gridViewport.height)
        )
        let targetRect = CGRect(
            x: target.left + Double(gridViewport.minX),
            y: target.top + Double(gridViewport.minY),
            width: target.width,
            height: target.height
        )
        return CourseDetailOverlay(
            course: sample,
            sourceRect: source,
            targetRect: targetRect,
            panelColor: Color(argb: MorandiPalette.argb(forCourseNamed: sample.name)),
            progress: .constant(1),
            showsTime: true,
            showsLocation: true,
            showsTeacher: true,
            timeRangeText: "10:20-12:00",
            gridTextSize: 13,
            onDismiss: {},
            onMore: { _ in }
        )
        .frame(width: 390, height: 700)
        .background(Color.gray)
    }
}
#endif
