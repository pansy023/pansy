import XCTest
@testable import KebiaoCore

/// `JwxtEncryptor.encryptCode` 的测试。
///
/// 期望值**不是**「先跑一遍实现再把输出抄下来」，而是按
/// `docs/recon/02-jwxt-login-and-parser.md` §2.4 的 Java 原文手工推演的，
/// 目的是验证 Swift 移植有没有把「交错 / 截断 / 尾部追加 / 越界保护」的语义写歪。
///
/// 原版没有留下任何测试或样例数据，所以这些对照向量是重新推的，
/// **不代表**原版跑出来的结果 —— 它们只用来保证 Swift 版与 Java 版**同一套规则**。
final class JwxtEncryptorTests: XCTestCase {

    // MARK: - 主向量：code ≥ 20 字符，走满 20 轮交错 + 尾部原样追加

    func testInterleavesFirstTwentyCharactersThenAppendsRemainder() {
        // code  : 12345678901234567890AB  （22 字符）
        // scode : 0123456789ABCDEFGHIJ    （20 字符）
        // sxh   : 12345678901234567890    （每位都是数字）
        //
        // 逐轮推演（i 轮：取 sxh[i] 的数字 d，从 scode 头部取 min(d, scode 剩余) 个字符，
        // 拼在 code[i] 之后，并把取走的部分从 scode 里删掉）：
        //   i=0  d=1 code='1' take='0'     scode 剩 123456789ABCDEFGHIJ
        //   i=1  d=2 code='2' take='12'    scode 剩 3456789ABCDEFGHIJ
        //   i=2  d=3 code='3' take='345'   scode 剩 6789ABCDEFGHIJ
        //   i=3  d=4 code='4' take='6789'  scode 剩 ABCDEFGHIJ
        //   i=4  d=5 code='5' take='ABCDE' scode 剩 FGHIJ
        //   i=5  d=6 take=min(6,5)=5       scode 空
        //   i=6…9  take=0                  → '7' '8' '9' '0'
        //   i=10…19 take=0                 → code[10…19] 原样 1234567890
        //   尾部 code[20…]                  → AB
        let expected = "102123345467895ABCDE6FGHIJ78901234567890AB"
        XCTAssertEqual(
            JwxtEncryptor.encryptCode(
                raw: "12345678901234567890AB",
                scode: "0123456789ABCDEFGHIJ",
                sxh: "12345678901234567890"
            ),
            expected
        )
    }

    // MARK: - 越界保护：code 短于 20 字符

    /// Java 版在这里会抛 `StringIndexOutOfBoundsException`（recon doc §2.4 注明 jadx 未加保护），
    /// iOS 端按文档要求加了保护：越界位置按空串参与拼接。
    func testShortCodeDoesNotCrashWhenAllDigitsAreZero() {
        // sxh 全为 '0' → 每轮 take=0 → 输出应等于 code 的字符（此处只有 3 个），
        // 第 4 轮起 code 越界、按空串处理，尾部追加也为空。
        XCTAssertEqual(
            JwxtEncryptor.encryptCode(raw: "abc", scode: "XYZ", sxh: String(repeating: "0", count: 20)),
            "abc"
        )
    }

    // MARK: - 非数字的 sxh 位按 0 处理（对齐 StringsKt.toIntOrNull 返回 null）

    func testNonDigitSxhPositionsBehaveAsZero() {
        // 20 位全是字母 → toIntOrNull 全为 null → 每位 take=0 → 输出 = code 前 20 字符 + 尾部。
        let raw = "abcdefghijklmnopqrstUV"   // 22 字符
        XCTAssertEqual(
            JwxtEncryptor.encryptCode(
                raw: raw,
                scode: "0123456789ABCDEFGHIJ",
                sxh: "abcdefghijklmnopqrst"
            ),
            "abcdefghijklmnopqrst" + "UV"
        )
    }

    // MARK: - scode 被取空后不再消费

    func testScodeExhaustionStopsConsuming() {
        // sxh 全为 '9' → 每轮想取 9 个字符，但 scode 只有 5 个：
        //   i=0  d=9 take=min(9,5)=5 → 取光 ABCDE，scode 清空
        //   i=1…19 take=0            → code[1…19] 原样
        XCTAssertEqual(
            JwxtEncryptor.encryptCode(
                raw: "01234567890123456789",
                scode: "ABCDE",
                sxh: String(repeating: "9", count: 20)
            ),
            "0ABCDE" + "1234567890123456789"
        )
    }
}
