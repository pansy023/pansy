import SwiftUI
import KebiaoCore

/// 网格里的一张课程卡片（静止态）。
///
/// 尺寸由调用方（`TimetableGrid`）算好并**通过 `.frame` 给出**——卡片自己不参与
/// 布局计算，因为纵向几何必须逐字来自 `TimetableLayout.cardVerticalGeometry`
/// （证据：`apk_work/kb/src2/TimetableGridV2.kt:550-566`，对应
/// `docs/recon/algorithms.md` §5.1）。卡片只负责画。
///
/// 卡片正文竖排「课程名 / 时间 / 〔楼名〕 / 教室 / 教师」，与安卓端主界面小卡片一致
/// （参考截图：每张小卡片依次显示课程名、时间区间、带 〔〕 的楼名、教室、教师，各占一行）。
///
/// 字号仍只用 `style.textSize`（= `TimetableLayout.fitTextSize(configured:heightDp:)`，
/// `TimetableGridV2.kt:571`、`:726-731`）。
///
/// 卡片高度放不下全部行时，用 `ViewThatFits` 从「全信息」逐级降级到「只显示课程名」：
/// 安卓端是 Compose 直接裁切，iOS 必须显式降级，否则文字会溢出到卡片之外。
struct CourseCard: View {

    let course: Course
    /// 由 `CourseCardStyle.resolve(...)` 解算出的底色/文字色/透明度/字号。
    let style: CourseCardStyle
    /// 面板内高度（pt，数值等于 Android 的 dp）。
    let height: CGFloat
    /// 时间区间文本，由调用方用
    /// `TimetableLayout.buildTimeRange(_:timeSlots:)` 生成（`TimetableGridV2.kt:796-805`）。
    var timeRangeText: String = ""
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
                ViewThatFits(in: .vertical) {
                    lines(time: true, location: true, teacher: true)
                    lines(time: true, location: true, teacher: false)
                    lines(time: true, location: false, teacher: false)
                    lines(time: false, location: false, teacher: false)
                }
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

    /// 竖排正文。`time` / `location` / `teacher` 控制后三行是否参与排版，
    /// 供 `ViewThatFits` 按可用高度逐级降级。
    private func lines(time: Bool, location: Bool, teacher: Bool) -> some View {
        VStack(spacing: 1) {
            Text(course.name)
                .font(.system(size: CGFloat(style.textSize), weight: .medium))
                .lineLimit(2)
                .minimumScaleFactor(0.85)

            if time, !timeRangeText.isEmpty {
                detailLine(timeRangeText)
            }
            if location, !buildingText.isEmpty {
                detailLine(buildingText)
            }
            if location, !roomText.isEmpty {
                detailLine(roomText)
            }
            if teacher, !course.teacher.isEmpty {
                detailLine(course.teacher)
            }
        }
        .multilineTextAlignment(.center)
        .foregroundColor(style.ink)
    }

    private func detailLine(_ value: String) -> some View {
        Text(value)
            .font(.system(size: CGFloat(style.textSize)))
            .lineLimit(2)
            .minimumScaleFactor(0.8)
    }

    /// 楼名行 `〔楼名〕`。`Course.building` = 地点里第一个空格之前的部分
    /// （`TimetableGridV2.kt:733-736`）；安卓端小卡片就是把它用 〔〕 括起来显示。
    private var buildingText: String {
        let building = course.building
        return building.isEmpty ? "" : "〔\(building)〕"
    }

    /// 教室行。`Course.room` = 地点里第一个空格之后的部分（`TimetableGridV2.kt:738-741`）。
    private var roomText: String { course.room }

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
                height: 60,
                timeRangeText: "08:10-09:50"
            )
            CourseCard(
                course: sample,
                style: CourseCardStyle(
                    background: Color(argb: MorandiPalette.argb(forCourseNamed: sample.name)),
                    ink: .white,
                    alpha: 0.35,
                    textSize: 10
                ),
                height: 30,
                timeRangeText: "08:10-09:50"
            )
        }
        .padding()
    }
}
#endif
