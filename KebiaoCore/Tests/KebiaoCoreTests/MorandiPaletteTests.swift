import XCTest
@testable import KebiaoCore

/// 课程卡片配色与「优化模式」取值的测试。
///
/// 期望的 12 个 ARGB 与索引来自 `apk_work/kb/src2/TimetableGridV2.kt:80-93` 的
/// `MorandiPalette`（并已与 APK 内 `TimetableGridV2Kt.smali` 的 `<clinit>` 常量
/// 逐一比对一致），hash 期望值由 `tools/java_hash_expectations.py` 生成。
final class MorandiPaletteTests: XCTestCase {

    // MARK: - 调色板本体

    func testPaletteHasTwelveValuesInComposeOrder() {
        let expected: [UInt32] = [
            0xFFA8A8C0,
            0xFFACA7C5,
            0xFFA795A5,
            0xFF454350,
            0xFF797C67,
            0xFFC9AA7C,
            0xFFDAACB6,
            0xFFD1DBDA,
            0xFFBEBAAE,
            0xFF8D89A2,
            0xFFB7C0B2,
            0xFFC8B4A8,
        ]
        XCTAssertEqual(MorandiPalette.argbValues.count, 12)
        XCTAssertEqual(MorandiPalette.argbValues, expected)
    }

    // MARK: - 索引

    func testEmptyNameFallsBackToFirstColor() {
        // 原版对空串特判为 0（`if (name.isEmpty()) 0 else hashCode() and 0x7fffffff`）。
        XCTAssertEqual(MorandiPalette.colorIndex(forCourseNamed: ""), 0)
        XCTAssertEqual(MorandiPalette.argb(forCourseNamed: ""), 0xFFA8A8C0)
    }

    func testKnownCourseNameColorIndices() {
        let expectations: [(String, Int)] = [
            ("a", 1),
            ("ab", 9),
            ("abc", 6),
            ("Hello", 2),
            ("高等数学", 3),
            ("大学英语", 3),
            ("线性代数", 1),
            ("数据结构", 7),
            ("体育", 3),
            ("计算机组成原理", 7),
            ("马克思主义基本原理", 5),
            ("操作系统", 3),
            ("编译原理", 6),
        ]
        for (name, expected) in expectations {
            XCTAssertEqual(
                MorandiPalette.colorIndex(forCourseNamed: name), expected,
                "「\(name)」应落在调色板第 \(expected) 号"
            )
        }
    }

    func testNegativeHashNameStillLandsInRange() {
        // 负 hash 是最容易出错的一类：直接 `% 12` 会得到负数并越界崩溃。
        let index = MorandiPalette.colorIndex(forCourseNamed: "马克思主义基本原理")
        XCTAssertEqual(index, 5)
        XCTAssertEqual(MorandiPalette.argb(forCourseNamed: "马克思主义基本原理"), 0xFFC9AA7C)
    }

    func testSurrogatePairNameIndex() {
        XCTAssertEqual(MorandiPalette.colorIndex(forCourseNamed: "😀"), 7)
        XCTAssertEqual(MorandiPalette.argb(forCourseNamed: "😀"), 0xFFD1DBDA)
    }

    func testIndexIsAlwaysInRange() {
        let samples = [
            "", "a", "z", "Hello", "高等数学", "大学英语", "线性代数", "数据结构",
            "体育", "计算机组成原理", "马克思主义基本原理", "操作系统", "编译原理",
            "😀", "～！＠＃", "   ", "1234567890",
        ]
        for name in samples {
            let index = MorandiPalette.colorIndex(forCourseNamed: name)
            XCTAssertTrue(
                (0..<12).contains(index),
                "「\(name)」的索引 \(index) 越界"
            )
        }
    }

    func testIndexEqualsBucketModuloTwelve() {
        // 索引的定义就是 `nonNegativeBucket % 12`；这条把两层实现绑在一起。
        for name in ["", "a", "高等数学", "马克思主义基本原理", "😀"] {
            XCTAssertEqual(
                MorandiPalette.colorIndex(forCourseNamed: name),
                JavaHash.nonNegativeBucket(name) % 12,
                "「\(name)」的索引应与 bucket % 12 一致"
            )
        }
    }

    // MARK: - 十六进制便于日志核对

    func testHexStringIsRgbWithoutAlpha() {
        XCTAssertEqual(MorandiPalette.hexString(forCourseNamed: "高等数学"), "454350")
        XCTAssertEqual(MorandiPalette.hexString(forCourseNamed: ""), "A8A8C0")
        XCTAssertEqual(MorandiPalette.hexString(forCourseNamed: "😀"), "D1DBDA")
    }

    // MARK: - 优化模式

    func testColorfulModeUsesMorandiTintAndWhiteInk() {
        let colors = CardPaletteMode.colorful.colors(courseName: "高等数学", darkTheme: false)
        XCTAssertEqual(colors.background, 0xFF454350)
        XCTAssertEqual(colors.ink, 0xFFFFFFFF)

        // 深色主题下「按课程名取色」不变（原版只把 theme 用在优化模式分支）。
        let dark = CardPaletteMode.colorful.colors(courseName: "高等数学", darkTheme: true)
        XCTAssertEqual(dark.background, 0xFF454350)
        XCTAssertEqual(dark.ink, 0xFFFFFFFF)
    }

    func testOptimizedModeInvertsPerTheme() {
        // 浅色主题：近黑底 + 白字。
        let light = CardPaletteMode.optimized.colors(courseName: "高等数学", darkTheme: false)
        XCTAssertEqual(light.background, 0xFF1A1A1A)
        XCTAssertEqual(light.ink, 0xFFFFFFFF)

        // 深色主题：白底 + 近黑字。
        let dark = CardPaletteMode.optimized.colors(courseName: "高等数学", darkTheme: true)
        XCTAssertEqual(dark.background, 0xFFFFFFFF)
        XCTAssertEqual(dark.ink, 0xFF1A1A1A)
    }

    func testOptimizedModeIgnoresCourseName() {
        let a = CardPaletteMode.optimized.colors(courseName: "高等数学", darkTheme: false)
        let b = CardPaletteMode.optimized.colors(courseName: "体育", darkTheme: false)
        XCTAssertEqual(a.background, b.background)
        XCTAssertEqual(a.ink, b.ink)
    }
}
