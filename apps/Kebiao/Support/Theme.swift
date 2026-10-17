import SwiftUI
import KebiaoCore

// MARK: - 数值 → 颜色
//
// `KebiaoCore` 刻意不依赖 CoreGraphics / UIKit，所以 12 个莫兰迪色是以 ARGB 的
// `UInt32` 形式给出的（`MorandiPalette.argbValues`）。App 层负责把 ARGB 拆成
// SwiftUI 的 `Color` —— 这是 App 层唯一的「颜色算术」，放在这里集中一处。

extension Color {

    /// `0xFFA8A8C0` → `Color(.sRGB, red: 168/255, green: 168/255, blue: 192/255, opacity: 1)`。
    ///
    /// 逐位取通道，刻意不做任何 gamma / 色彩空间转换，以便与 Compose 的
    /// `Color(0xFFA8A8C0)`（sRGB 直通）看起来一致。
    /// 证据：`apk_work/kb/src2/TimetableGridV2.kt:80-93`。
    init(argb: UInt32) {
        let alpha = Double((argb >> 24) & 0xFF) / 255.0
        let red = Double((argb >> 16) & 0xFF) / 255.0
        let green = Double((argb >> 8) & 0xFF) / 255.0
        let blue = Double(argb & 0xFF) / 255.0
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}

// MARK: - 面板配色的前置判断
//
// `panelColor(dark:hasCustomBackground:)` 的第二个参数不是「有没有背景图字符串」，
// 原版的 `hasCustomBackground` 是
// `uri != null && uri.isNotBlank()`（`TimetableGridV2.kt:768-771`）。
// 空串 / 全空白串必须**当作没有背景**（→ 面板 alpha 0.88 而不是 0.62），
// 否则用户在设置里清空背景图之后，面板会莫名其妙半透明一大截。
public extension AppSettings {
    /// 是否有可用的自定义背景图。逐字对应 `TimetableGridV2.kt:768-771`。
    var hasCustomBackground: Bool {
        guard let uri = backgroundImageUri else { return false }
        return !uri.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// App 层的颜色 / 间距 / 字号常量。
///
/// 全部数值来自反编译证据，**不要在视图里就地写魔数**：
/// - 12 色莫兰迪 + 取色规则：`apk_work/kb/src2/TimetableGridV2.kt:80-93`、`:765-768`
///   —— 用 `MorandiPalette.argb(forCourseNamed:)`（Java `String.hashCode()`），
///   **绝不能**用 SwiftUI 的 `hashValue`（跨进程随机种子，同一个课程名会换色）。
/// - 网格尺寸常量：`apk_work/kb/src2/TimetableGridV2.kt:96-112`
///   —— 数值已在 `TimetableLayout` 里给出，这里只做「同一数值 + 明确单位」的转写。
/// - 面板配色：`apk_work/kb/src2/TimetableGridV2.kt:126-135`。
/// - 左列字号：`apk_work/kb/src2/TimetableGridV2.kt:510-531`。
/// - 表头字号：`apk_work/kb/src2/TimetableGridV2.kt:331-344`。
/// - 周次徽标：`apk_work/kb/src2/TimetableGridV2.kt:296-322`。
enum Theme {

    // MARK: - 网格尺寸（与 TimetableLayout 的常量一一对应）

    /// `LeftColumnWide = 50.dp` / `LeftColumnNarrow = 42.dp`
    /// （`TimetableGridV2.kt:684-693`，规则见 `TimetableLayout.leftColumnWidth(dayCount:)`）。
    static var leftColumnWide: CGFloat { CGFloat(TimetableLayout.leftColumnWide) }
    static var leftColumnNarrow: CGFloat { CGFloat(TimetableLayout.leftColumnNarrow) }
    /// `HeaderHeight = 46.dp`。
    static var headerHeight: CGFloat { CGFloat(TimetableLayout.headerHeight) }
    /// `BlockGap = 10.dp`：每个面板**前**一个裸间隔，整个网格底部再补一个
    /// （`TimetableGridV2.kt:427`，见 `docs/recon/01-timetable-algorithms.md` §7.2）。
    static var blockGap: CGFloat { CGFloat(TimetableLayout.blockGap) }
    /// `CardGap = 5.dp`。
    static var cardGap: CGFloat { CGFloat(TimetableLayout.cardGap) }
    /// `MinCardHeight = 12.dp`。
    static var minCardHeight: CGFloat { CGFloat(TimetableLayout.minCardHeight) }
    /// `PanelRadius = 16.dp`。
    static var panelRadius: CGFloat { CGFloat(TimetableLayout.panelRadius) }
    /// `PanelPadding = 4.dp`。
    static var panelPadding: CGFloat { CGFloat(TimetableLayout.panelPadding) }

    // MARK: - 卡片圆角 / 阴影

    /// 网格里静止卡片的圆角。Compose 侧没有直接给「卡片」圆角常量
    /// （卡片本身只 `clip` 了面板与左列的 `RoundedCornerShape`），
    /// 这里取 8pt 与左列单元格（`RoundedCornerShape(8.dp)`，`:511` 一带）一致。
    static let cardRadius: CGFloat = 8
    /// 展开后的卡片圆角。取值与 `expandTarget` 的观感匹配（更大的矩形配更大的圆角）。
    static let expandedCardRadius: CGFloat = 18
    /// 卡片的横向内缩：`Modifier.padding(horizontal = 2.dp)`（`TimetableGridV2.kt:817`）。
    static let cardHorizontalInset: CGFloat = 2

    // MARK: - 面板 / 页面配色

    /// `panelColor(dark:hasCustomBackground:)`，证据 `TimetableGridV2.kt:126-135`：
    /// `alpha = if (hasCustomBackground) 0.62f else 0.88f`，
    /// 深色 `0xFF1C1C1C`，浅色 `0xFFFFFFFF`。
    static func panelColor(dark: Bool, hasCustomBackground: Bool) -> Color {
        let alpha = hasCustomBackground ? 0.62 : 0.88
        return dark
            ? Color(.sRGB, red: 0x1C / 255, green: 0x1C / 255, blue: 0x1C / 255, opacity: alpha)
            : Color(.sRGB, red: 1, green: 1, blue: 1, opacity: alpha)
    }

    /// 页面底色。比面板更深/更浅一档，保证半透明面板的边缘可见。
    static func pageBackground(dark: Bool) -> Color {
        dark
            ? Color(.sRGB, red: 0.055, green: 0.055, blue: 0.063, opacity: 1)
            : Color(.sRGB, red: 0.925, green: 0.925, blue: 0.937, opacity: 1)
    }

    /// 左列 / 表头的文字色（`MaterialTheme.colorScheme.onSurfaceVariant` 的等价物）。
    static func secondaryInk(dark: Bool) -> Color {
        dark
            ? Color(.sRGB, red: 0.78, green: 0.78, blue: 0.80, opacity: 1)
            : Color(.sRGB, red: 0.36, green: 0.36, blue: 0.40, opacity: 1)
    }

    /// 正文文字色。
    static func primaryInk(dark: Bool) -> Color {
        dark
            ? Color(.sRGB, red: 0.93, green: 0.93, blue: 0.94, opacity: 1)
            : Color(.sRGB, red: 0.10, green: 0.10, blue: 0.12, opacity: 1)
    }

    /// 中性浅底：用来给按钮、徽标这类小控件压一层灰底。
    ///
    /// ⚠️ 曾用名 `todayHighlight`（蓝色系），当时被用于「今天所在列」整列高亮；
    /// 1.11.5 的原版网格**不**高亮任何一列（`TimetableGridV2.kt:324-345` 只画
    /// `"周" + label` 与 `prettyDate(date)`），所以那份高亮已按用户要求删除。
    /// 剩下的三处调用（周次徽标、翻周圆钮、回到本周）只需要一层无色偏的浅底，
    /// 这里改成纯灰阶，避免再出现「某一列/某一天莫名变蓝」的观感。
    static func subtleFill(dark: Bool) -> Color {
        dark
            ? Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 0.10)
            : Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 0.06)
    }

    // MARK: - 字号
    //
    // 卡片字号**必须**走 `TimetableLayout.fitTextSize(configured:heightDp:)`，
    // 这里只给出那些固定不变的字号（左列、表头、徽标、展开卡片）。

    /// 左列节次数字：`13.sp` / 行高 `15.sp` Bold（`TimetableGridV2.kt:510-531`）。
    static let periodNumberFont = Font.system(size: 13, weight: .bold)
    static let periodNumberLineHeight: CGFloat = 15
    /// 左列起止时间：`9.sp` / 行高 `11.sp`。
    static let periodTimeFont = Font.system(size: 9)
    static let periodTimeLineHeight: CGFloat = 11

    /// 表头星期：`13.sp` / 行高 `16.sp` Medium（`TimetableGridV2.kt:331-344`）。
    static let weekdayFont = Font.system(size: 13, weight: .medium)
    static let weekdayLineHeight: CGFloat = 16
    /// 表头日期：`11.sp` / 行高 `13.sp`，色 `onSurfaceVariant`。
    static let weekdayDateFont = Font.system(size: 11)
    static let weekdayDateLineHeight: CGFloat = 13

    /// 周次徽标：「第」/「周」`9.sp`，数字 `19.sp` Bold（`TimetableGridV2.kt:296-322`）。
    static let weekBadgeAffixFont = Font.system(size: 9)
    static let weekBadgeNumberFont = Font.system(size: 19, weight: .bold)
    static let weekBadgeRadius: CGFloat = 10

    /// 展开卡片的标题 / 详情字号。展开卡片不是网格卡片，不参与 `fitTextSize`
    /// （它的高度由 `TimetableLayout.expandTarget` 的目标尺寸决定，与卡片高度无关）。
    static let detailTitleFont = Font.system(size: 17, weight: .semibold)
    static let detailBodyFont = Font.system(size: 13)
    static let detailCaptionFont = Font.system(size: 11)
}

// MARK: - 卡片外观

/// 一张课程卡片解算后的外观：底色、文字色、总透明度、字号。
///
/// 解算规则**逐条**来自原版卡片刻：
/// - 取色：`tint = if (optimize) cardTint else paletteColor(raw.name)`，
///   `ink = cardInk`（`apk_work/kb/src2/TimetableGridV2.kt:542-549`、`:584` 一带）。
///   iOS 端直接用 `CardPaletteMode.colors(courseName:darkTheme:)`，
///   它已经把这段（含「优化模式」的黑白反色）封装好了。
/// - 透明度：`alpha = (cardAlpha * weekAlpha).coerceIn(0f, 1f)`，其中
///   `cardAlpha = settings.courseCardAlphaPercent.coerceIn(0,100)/100f`、
///   `weekAlpha = if (showNonCurrentWeek && !occurs) nonCurrentWeekCourseAlphaPercent.coerceIn(0,100)/100f else 1f`
///   （`TimetableGridV2.kt:542-549`、`:805-806`）。
struct CourseCardStyle: Equatable {
    var background: Color
    var ink: Color
    var alpha: Double
    var textSize: Int

    /// 解算一张卡片的样式。
    ///
    /// - Parameters:
    ///   - course: 要画的课程（已做相邻合并的版本，`id` 取合并链首张）。
    ///   - dark: `TimetableStore.uiFlags.isDarkTheme`（原版深色开关）。
    ///   - optimize: `TimetableStore.uiFlags.isOptimizeMode`（原版 `OptimizeMode.isEnabled()`）。
    ///   - occursThisWeek: `TimetableStore.coursesForDisplayedWeek()` 给出的第二项。
    ///   - settings: 只读，用于取四个百分比与「显示非本周课程」开关。
    ///   - cardHeight: 卡片高度（pt，数值等于 Android 的 dp），用于 `fitTextSize`。
    static func resolve(
        course: Course,
        dark: Bool,
        optimize: Bool,
        occursThisWeek: Bool,
        settings: AppSettings,
        cardHeight: CGFloat
    ) -> CourseCardStyle {
        let mode: CardPaletteMode = optimize ? .optimized : .colorful
        let colors = mode.colors(courseName: course.name, darkTheme: dark)

        let cardAlpha = Self.clampedPercent(settings.courseCardAlphaPercent)
        let weekAlpha: Double
        if settings.showNonCurrentWeekCourses, !occursThisWeek {
            weekAlpha = Self.clampedPercent(settings.nonCurrentWeekCourseAlphaPercent)
        } else {
            weekAlpha = 1
        }
        let alpha = min(max(cardAlpha * weekAlpha, 0), 1)

        return CourseCardStyle(
            background: Color(argb: colors.background),
            ink: Color(argb: colors.ink),
            alpha: alpha,
            textSize: TimetableLayout.fitTextSize(
                configured: settings.courseTextSizeSp,
                heightDp: Double(cardHeight)
            )
        )
    }

    /// `percent.coerceIn(0, 100) / 100f`。
    private static func clampedPercent(_ percent: Int) -> Double {
        Double(min(max(percent, 0), 100)) / 100.0
    }
}
