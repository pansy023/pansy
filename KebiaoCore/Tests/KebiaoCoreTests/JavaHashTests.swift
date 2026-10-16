import XCTest
@testable import KebiaoCore

/// Java `String.hashCode()` 等价实现的测试。
///
/// 期望值全部由 `上课早枝道-iOS/tools/java_hash_expectations.py` 生成（该脚本用
/// UTF-16 code unit + 32 位回绕独立实现一遍 Java 语义），不是手算的。
///
/// 为什么这件事值得单独一个测试文件：课程卡片的颜色由课程名 hash 决定，
/// 一旦 Swift 侧算出的 hash 与 Java 不同，同一门课在 Android 与 iOS 上就是
/// 两种颜色——这是最容易被「看起来正常」掩盖过去的偏差。
final class JavaHashTests: XCTestCase {

    // MARK: - 基础

    func testEmptyStringHashesToZero() {
        XCTAssertEqual(JavaHash.stringHashCode(""), 0)
        XCTAssertEqual(JavaHash.nonNegativeBucket(""), 0)
    }

    func testKnownAsciiValuesMatchJavaSpec() {
        // "a" = 97；"ab" = 97*31 + 98 = 3105；"abc" = 3105*31 + 99 = 96354。
        XCTAssertEqual(JavaHash.stringHashCode("a"), 97)
        XCTAssertEqual(JavaHash.stringHashCode("ab"), 3105)
        XCTAssertEqual(JavaHash.stringHashCode("abc"), 96354)
        // "Hello" = 69609650（Java 官方文档里的经典例子）。
        XCTAssertEqual(JavaHash.stringHashCode("Hello"), 69609650)
    }

    // MARK: - 中文课程名

    func testChineseCourseNames() {
        let expectations: [(String, Int32)] = [
            ("高等数学", 1212073767),
            ("大学英语", 703480443),
            ("线性代数", 990935605),
            ("数据结构", 799106959),
            ("体育", 662463),
            ("计算机组成原理", 376996087),
            ("操作系统", 789304755),
            ("编译原理", 1004310786),
        ]
        for (name, expected) in expectations {
            XCTAssertEqual(
                JavaHash.stringHashCode(name), expected,
                "「\(name)」的 Java hashCode 应为 \(expected)"
            )
        }
    }

    // MARK: - 溢出与符号

    func testNegativeHashWrapsToNegativeInt32() {
        // 溢出的真实样本：Java 算出的是负数，Swift 侧必须同样得到负数，
        // 而不是被 Int32 溢出陷阱 trap 掉。
        XCTAssertEqual(JavaHash.stringHashCode("马克思主义基本原理"), -1316657211)
    }

    func testNonNegativeBucketClearsSignBit() {
        // `and 0x7fffffff` 只抹掉符号位，不取绝对值：
        // -1316657211 + 2^32 = 2978310085；2978310085 & 0x7fffffff = 830826437。
        XCTAssertEqual(JavaHash.nonNegativeBucket("马克思主义基本原理"), 830826437)
        XCTAssertEqual(JavaHash.nonNegativeBucket("a"), 97)
    }

    func testBucketIsNeverNegative() {
        for name in ["", "a", "高等数学", "马克思主义基本原理", "😀", "～！＠＃"] {
            XCTAssertGreaterThanOrEqual(JavaHash.nonNegativeBucket(name), 0)
        }
    }

    // MARK: - UTF-16 语义

    func testNonBmpCharacterUsesSurrogatePair() {
        // "😀" = U+1F600 → UTF-16 是 [0xD83D, 0xDE00]（55357, 56832）。
        // 逐 char 累加：55357 → 31*55357 + 56832 = 1772899。
        //
        // 如果实现遍历的是 Swift 的 `Character`（把它当作单个标量 0x1F600 = 128512），
        // 结果会是 128512，与本断言不符——这条就是「必须遍历 utf16」的守门测试。
        XCTAssertEqual(JavaHash.stringHashCode("😀"), 1772899)
        XCTAssertNotEqual(JavaHash.stringHashCode("😀"), 128512)
    }

    func testLongStringMatchesIndependentInt64Reference() {
        // 用 Int64 累加并在每一步掩到 32 位（acc < 2^32，31*acc+unit < 2^37，不会溢出）
        // 作为独立参照；快路径用 Int32 回绕，两者必须逐位一致。
        let value = String(repeating: "高等数学ABC~!", count: 200)
        XCTAssertGreaterThan(value.utf16.count, 1000)

        var reference: Int64 = 0
        for unit in value.utf16 {
            reference = (31 * reference + Int64(unit)) & 0xFFFF_FFFF
        }
        let expected = Int32(truncatingIfNeeded: reference)

        XCTAssertEqual(JavaHash.stringHashCode(value), expected)
    }
}
