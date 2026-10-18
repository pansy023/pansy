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

    /// 循环上界必须是 `code` 的长度（Java `while (i < length)`、登录页 JS
    /// `for (i = 0; i < code.length; i++)` 都是这个上界），**不是**常量 20。
    func testShortCodeDoesNotCrashWhenAllDigitsAreZero() {
        // sxh 全为 '0' → 每轮 take=0 → 输出应等于 code 的字符（此处只有 3 个），
        // 循环在 i=3 处因 `i == code.length` 收尾。
        XCTAssertEqual(
            JwxtEncryptor.encryptCode(raw: "abc", scode: "XYZ", sxh: String(repeating: "0", count: 20)),
            "abc"
        )
    }

    /// 短 code 且 `sxh` 位非零——这是能区分「上界 20」与「上界 code.length」的判别性用例。
    ///
    /// 早期实现把上界写成常量 20：code 取完后仍在空转，会把多余的 `scode` 片段
    /// （`"6789"`）拼到 encoded 尾部，与服务端算出的值不一致 → 服务端解密失败
    /// → 登录被误判为「密码错误」。
    func testShortCodeStopsAtCodeLengthInsteadOfTwenty() {
        // code  : "abc"          （3 字符）
        // scode : "0123456789"   （10 字符）
        // sxh   : "12345678901234567890"
        //   i=0 d=1 → "a" + "0"      scode 剩 123456789
        //   i=1 d=2 → "b" + "12"     scode 剩 3456789
        //   i=2 d=3 → "c" + "345"    scode 剩 6789
        //   i=3 == code.length → 结束，剩下的 "6789" **不** 拼接
        XCTAssertEqual(
            JwxtEncryptor.encryptCode(raw: "abc", scode: "0123456789", sxh: "12345678901234567890"),
            "a0b12c345"
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

    // MARK: - 切分单位必须是 UTF-16 code unit（对齐 JS / Java，而不是 Swift 的字符簇）

    /// 非 BMP 字符（emoji）在 JS / Java 里是 **2 个 UTF-16 单元**，在 Swift 的
    /// `Array(_:)` 里是 **1 个字符**；按字符簇切分会让 encoded 与服务端算出的值分叉
    /// （2026-10 实测确认：同一密码，两边 encoded 不同 → 服务端判「密码错误」）。
    ///
    /// 手工推演（raw = "a😀b" → 4 个单元，scode = "0123456789"，sxh 每位即其数字）：
    ///   i=0 d=1 → 'a' + "0"，scode 剩 123456789
    ///   i=1 d=2 → 高代理项 + "12"，scode 剩 3456789
    ///   i=2 d=3 → 低代理项 + "345"，scode 剩 6789
    ///   i=3 d=4 → 'b' + "6789"，scode 空
    /// 末尾 `String(decoding:as:)` 把两个落单代理项各还原成 U+FFFD —— 这正是浏览器把
    /// 含落单代理项的字符串序列化成表单数据时的行为，因此与服务端收到的字节一致。
    ///
    /// 反例（旧实现按 `Array(raw)` 切分）会得到 "a0😀12b345"，两者不同。
    func testNonBMPCharactersAreSplitByUTF16CodeUnit() {
        XCTAssertEqual(
            JwxtEncryptor.encryptCode(
                raw: "a\u{1F600}b",
                scode: "0123456789",
                sxh: "12345678901234567890"
            ),
            "a0\u{FFFD}12\u{FFFD}345b6789"
        )
    }

    // MARK: - 真 JS 引擎对照向量（oracle 不是手推的）

    /// 期望值**不是手推的**，也不是「跑一遍 Swift 实现再把输出抄下来」的，
    /// 而是把真服务器登录页 `real-index.html:535-545`（取证样本，19800 字节）
    /// 的循环体**原样**放进 Windows 自带的 JScript 引擎里跑出来的：
    ///
    ///     cscript //nologo js-ref.js corpus-vectors.tsv js-vectors-out.tsv
    ///
    /// 为什么要这么费劲：上一轮的错误正是「两边都以为一致，其实在非 BMP 上分叉」，
    /// 而手推的期望值有可能与实现「一起错」。用真 JS 引擎当 oracle，
    /// 才能把「Swift 实现 == 服务端 JS」这件事钉死在这里，而不是靠推理。
    ///
    /// ⚠️ 与手推向量（上面那些）不同，这里**按 UTF-16 code unit 比较**而不是比
    /// `String`：Swift 的 `==` 走 canonical equivalence，「é」与「e + U+0301」
    /// 会被判等，用 `String` 比较会把组合字符上的真实差异吃掉。
    ///
    /// ⚠️ 唯一刻意的差异：JS 输出里可能出现**落单代理项**，而 Swift 的
    /// `String(decoding:as:)` 会把它还原成 U+FFFD（这正是浏览器按 WHATWG 规则
    /// 序列化表单数据时的行为），因此期望值取的是**归一化之后**的形式。
    /// 归一化规则与 4028 例差分自测（含 2223 例带动代理项、2204 例带组合标记）
    /// 见 `.../kebiao-ci/selftest_encrypt.py`，结论：与真 JS 引擎 0 处分叉。
    func testMatchesRealServerJSEngineVectors() {
        typealias Vector = (label: String, raw: String, scode: String, sxh: String, expected: String)
        let vectors: [Vector] = [
            (
                "real-shaped: 10-digit id + strong 8-char pw",
                "2023012345%%%p@ssW0rd!23",
                "0123456789ABCDEFGHIJ",
                "12345678901234567890",
                "200122345367890ABCDE1FGHIJ2345%%%p@ssW0rd!23"
            ),
            (
                "real-shaped: 12-digit id + all specials",
                "202301234567%%%Aa1!%+&=*~!'\"()#@$,",
                "0123456789ABCDEFGHIJ",
                "12345678901234567890",
                "200122345367890ABCDE1FGHIJ234567%%%Aa1!%+&=*~!'\"()#@$,"
            ),
            (
                "astral (emoji) inside the password",
                "2023012345%%%Aa1!\u{1F600}x",
                "0123456789ABCDEFGHIJ",
                "12345678901234567890",
                "200122345367890ABCDE1FGHIJ2345%%%Aa1!\u{1F600}x"
            ),
            (
                "astral in username, code length under 20",
                "202301\u{1F680}45%%%Aa1!aa",
                "0123456789ABCDEFGHIJ",
                "12345678901234567890",
                "200122345367890ABCDE1FGHIJ\u{1F680}45%%%Aa1!aa"
            ),
            (
                "combining marks (e + U+0301) x12",
                "e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}",
                "0123456789ABCDEFGHIJ",
                "33333333333333333333",
                "e012\u{301}345e678\u{301}9ABeCDE\u{301}FGHeIJ\u{301}e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}"
            ),
            (
                "21-char password: raw length 34 (> 20)",
                "2023012345%%%Aa1!xxxxxxxxxxxxxxxxxxxxx",
                "0123456789ABCDEFGHIJ",
                "12345678901234567890",
                "200122345367890ABCDE1FGHIJ2345%%%Aa1!xxxxxxxxxxxxxxxxxxxxx"
            ),
            (
                "boundary: code length exactly 20",
                "12345678901234567890",
                "0123456789ABCDEFGHIJ",
                "12345678901234567890",
                "102123345467895ABCDE6FGHIJ78901234567890"
            ),
            (
                "boundary: code length exactly 21",
                "12345678901234567890A",
                "0123456789ABCDEFGHIJ",
                "12345678901234567890",
                "102123345467895ABCDE6FGHIJ78901234567890A"
            ),
            (
                "scode empty",
                "2023012345%%%Aa1!aaaa",
                "",
                "12345678901234567890",
                "2023012345%%%Aa1!aaaa"
            ),
            (
                "sxh shorter than 20",
                "2023012345%%%Aa1!aaaa",
                "0123456789ABCDEFGHIJ",
                "1234567",
                "200122345367890ABCDE1FGHIJ2345%%%Aa1!aaaa"
            ),
            (
                "sxh with non-digits",
                "2023012345%%%Aa1!aaaa",
                "0123456789ABCDEFGHIJ",
                "12ab5678901234567890",
                "2001223034567189ABCD2EFGHIJ345%%%Aa1!aaaa"
            ),
            (
                "NBSP (U+00A0) and space/tab inside the password",
                "2023012345%%%Aa 1!\u{A0}\tzz",
                "0123456789ABCDEFGHIJ",
                "12345678901234567890",
                "200122345367890ABCDE1FGHIJ2345%%%Aa 1!\u{A0}\tzz"
            ),
            (
                "CJK inside the password",
                "2023012345%%%\u{5BC6}\u{7801}Aa1!",
                "0123456789ABCDEFGHIJ",
                "12345678901234567890",
                "200122345367890ABCDE1FGHIJ2345%%%\u{5BC6}\u{7801}Aa1!"
            ),
            (
                "scode shorter than the digits ask for",
                "2023012345%%%Aa1!aaaa",
                "ABCDE",
                "12345678901234567890",
                "2A0BC2DE3012345%%%Aa1!aaaa"
            ),
        ]
        XCTAssertEqual(vectors.count, 14, "向量条数变了请同步更新本注释与 CI 说明")
        for v in vectors {
            let actual = JwxtEncryptor.encryptCode(raw: v.raw, scode: v.scode, sxh: v.sxh)
            XCTAssertEqual(
                Array(actual.utf16),
                Array(v.expected.utf16),
                "向量「\(v.label)」与真 JS 引擎结果不一致（按 UTF-16 code unit 比较，"
                + "避免 Swift 的 canonical equivalence 把组合字符上的差异吃掉）"
            )
        }
    }
}
