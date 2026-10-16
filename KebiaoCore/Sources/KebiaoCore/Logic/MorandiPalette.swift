import Foundation

/// 课程卡片的莫兰迪配色。
///
/// 证据：`apk_work/kb/src2/TimetableGridV2.kt:80-93`（12 个 ARGB 值，顺序不可改）
/// 与 `:765-768`（取色表达式）。
///
/// 原版行为（`TimetableGridV2.kt:545-560` 的卡片循环）：
/// - 关闭「优化模式」时：`tint = paletteColor(course.name)`，字色为纯白 `0xFFFFFFFF`；
/// - 开启「优化模式」时：`tint = 深色主题 ? 0xFFFFFFFF : 0xFF1A1A1A`，
///   字色取反（深色主题下 `0xFF1A1A1A`，浅色主题下 `0xFFFFFFFF`），
///   即所谓「灰度/反色」模式，此时不看课程名配色。
///
/// 因此 `Course.color` 字段在原版路径里**并不参与**网格取色；iOS 端若要完全一致，
/// 同样以课程名 hash 取色。
public enum MorandiPalette {

    /// 12 色，顺序与 Compose 源码逐字一致（`0xFFA8A8C0` 起）。
    public static let argbValues: [UInt32] = [
        0xFFA8_A8C0,
        0xFFAC_A7C5,
        0xFFA7_95A5,
        0xFF45_4350,
        0xFF79_7C67,
        0xFFC9_AA7C,
        0xFFDA_ACB6,
        0xFFD1_DBDA,
        0xFFBE_BAAE,
        0xFF8D_89A2,
        0xFFB7_C0B2,
        0xFFC8_B4A8
    ]

    /// `MorandiPalette[(name.hashCode() and 0x7fffffff) % 12]`。
    ///
    /// 空串特判：原版 `val h = if (name.isEmpty()) 0 else name.hashCode() and 0x7fffffff`
    /// ——注意 `0 and 0x7fffffff == 0`，所以空串与「hash 恰好为 0 的字符串」等价，
    /// 结果都是 `argbValues[0]`。这里保留显式特判以贴合原版。
    public static func colorIndex(forCourseNamed name: String) -> Int {
        let bucket = name.isEmpty ? 0 : JavaHash.nonNegativeBucket(name)
        return bucket % argbValues.count
    }

    public static func argb(forCourseNamed name: String) -> UInt32 {
        argbValues[colorIndex(forCourseNamed: name)]
    }

    /// 课程名 → 0xRRGGBB 形式的十六进制字符串，便于日志与测试断言。
    public static func hexString(forCourseNamed name: String) -> String {
        String(format: "%06X", argb(forCourseNamed: name) & 0x00FF_FFFF)
    }
}

/// 「优化模式」（原版 `kebiaocom.example.ui.theme.OptimizeMode`）。
///
/// 原版把开关状态存在 SharedPreferences 里（`.../ui/theme/OptimizeMode.java:4`
/// 有 `import android.content.SharedPreferences`）。iOS 端同样是纯开关，
/// 具体取值由其实现决定；这里只描述它对配色的影响。
public enum CardPaletteMode: Sendable {
    /// 按课程名取莫兰迪色，白字。
    case colorful
    /// 灰度/反色：深色主题下白底黑字，浅色主题下黑底白字。
    case optimized

    /// 返回 (背景色 ARGB, 文字色 ARGB)。
    /// 证据：`TimetableGridV2.kt:550-557`。
    public func colors(courseName: String, darkTheme: Bool) -> (background: UInt32, ink: UInt32) {
        switch self {
        case .colorful:
            return (MorandiPalette.argb(forCourseNamed: courseName), 0xFFFF_FFFF)
        case .optimized:
            let tint: UInt32 = darkTheme ? 0xFFFF_FFFF : 0xFF1A_1A1A
            let ink: UInt32 = darkTheme ? 0xFF1A_1A1A : 0xFFFF_FFFF
            return (tint, ink)
        }
    }
}
