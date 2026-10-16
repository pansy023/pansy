import SwiftUI
import KebiaoCore

/// 网格里的一张课程卡片（静止态）。
///
/// 尺寸由调用方（`TimetableGrid`）算好并**通过 `.frame` 给出**——卡片自己不参与
/// 布局计算，因为纵向几何必须逐字来自 `TimetableLayout.cardVerticalGeometry`
/// （证据：`apk_work/kb/src2/TimetableGridV2.kt:550-566`，对应
/// `docs/recon/algorithms.md` §5.1）。卡片只负责画。
///
/// 文字只用 `style.textSize`（= `TimetableLayout.fitTextSize(configured:heightDp:)`，
/// `TimetableGridV2.kt:571`、`:726-731`），**不要**在这里再叠一层
/// `.minimumScaleFactor` 或 `.lineLimit` 之外的降级，否则会偏离原版的字号规则。
struct CourseCard: View {

    let course: Course
    /// 由 `CourseCardStyle.resolve(...)` 解算出的底色/文字色/透明度/字号。
    let style: CourseCardStyle
    /// 面板内高度（pt，数值等于 Android 的 dp）。
    let height: CGFloat
    /// 点击回调。nil 表示这张卡（例如展开浮层里显示的同一门课）不可再点。
    var onTap: (() -> Void)?

    var body: some View {
        ZStack {
            // 圆角 + 底色。透明度只作用在底面上：文字保持不透明，
            // 与原版 `Modifier.alpha(...)` 作用在整张卡片上相比，
            // 差别仅在「非本周课程的名字会不会一起变淡」；这里选择让名字始终可读。
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(style.background)
                .opacity(style.alpha)

            if showsTitle {
                Text(course.name)
                    .font(.system(size: CGFloat(style.textSize), weight: .medium))
                    .foregroundColor(style.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.85)
                    // 与左侧内缩 1pt：原版卡片左右各 `padding(horizontal = 2.dp)`
                    // 已经由 TimetableGrid 给出，这里只是文字不贴边。
                    .padding(.horizontal, 2)
            }
        }
        .frame(height: height)
        .contentShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .onTapGesture { onTap?() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(course.name)
        .accessibilityAddTraits(onTap == nil ? [] : .isButton)
    }

    /// 卡片矮到放不下 7pt 文字时就不画字了（原版也会被 `minCardHeight = 12.dp`
    /// 裁掉字形，只是 Compose 不会崩）。这里显式判断，避免出现 2pt 高的残缺字。
    private var showsTitle: Bool {
        guard !course.name.isEmpty, height >= 12, style.textSize >= 7 else { return false }
        return true
    }
}

#if DEBUG
struct CourseCard_Previews: PreviewProvider {
    static var previews: some View {
        let sample = Course(
            id: 1,
            name: "高等数学",
            teacher: "张三",
            location: "教一楼 201",
            dayOfWeek: 1,
            startPeriod: 1,
            endPeriod: 2,
            color: 0,
            weekRange: "1-16"
        )
        return VStack(spacing: 8) {
            CourseCard(
                course: sample,
                style: CourseCardStyle(
                    background: Color(argb: MorandiPalette.argb(forCourseNamed: sample.name)),
                    ink: .white,
                    alpha: 1,
                    textSize: 13
                ),
                height: 60
            )
            CourseCard(
                course: sample,
                style: CourseCardStyle(
                    background: Color(argb: MorandiPalette.argb(forCourseNamed: sample.name)),
                    ink: .white,
                    alpha: 0.35,
                    textSize: 10
                ),
                height: 30
            )
        }
        .padding()
    }
}
#endif
