import Foundation

/// 强智教务登录表单 `encoded` 字段的生成器。
///
/// 算法逐字来自 Android 端 `QiangzhiJwxtParser.java:127-162` 的
/// `encryptCode(code, scodeOrig, sxh)`，逐字 Java 原文与 Swift 等价写法见
/// `docs/recon/02-jwxt-login-and-parser.md` §2.4。
///
/// **不是** MD5 / DES / Base64：它是强智官方的 `encrypt` 变体 —— 把
/// `用户名 + "%%%" + 密码` 的字符按服务端下发的 `scode` / `sxh` 做字符交错。
/// 服务端只在 `/Logon.do?method=logon&flag=sess` 响应里给出这两个材料。
///
/// ⚠️ 与 Java 版**只差一处，且是刻意的越界保护**：Java 在 `code` 短于 20 字符时
/// `code.substring(i, i + 1)` 会抛 `StringIndexOutOfBoundsException`（jadx 反编译体
/// 未加保护）；recon doc §2.4 明确要求 iOS 端加保护，因此越界位置按空串参与拼接，
/// 其余循环体逐条不变。
///
/// ⚠️ 输入含明文密码的派生串，**绝不可写入日志**。原版 `login$2.java:190` 会打印
/// `"加密后的encoded: " + encryptCode`，而该串可由用户名 + 密码逆推（算法公开），
/// 等价于密码泄露 —— iOS 端不复制这一行为（见 `docs/recon/02-jwxt-login-and-parser.md`
/// 的风险清单）。
public enum JwxtEncryptor {

    /// 交错循环的固定上界，对应 `QiangzhiJwxtParser.java:128` 的 `while (i < 20)`。
    public static let interleaveLimit = 20

    /// 对应 `QiangzhiJwxtParser.encryptCode(code, scodeOrig, sxh)`。
    ///
    /// - Parameters:
    ///   - raw: 明文派生串 `用户名 + "%%%" + 密码`。
    ///   - scode: `/Logon.do?method=logon&flag=sess` 响应按 `#` 分割的 **[0]** 段
    ///     （`login$2.java:173-175`）。
    ///   - sxh: 同一响应按 `#` 分割的 **[1]** 段。
    /// - Returns: 可直接放进登录表单 `encoded` 字段的字符串。
    public static func encryptCode(raw: String, scode: String, sxh: String) -> String {
        let code = Array(raw)
        var scode = Array(scode)
        let x = Array(sxh)

        var out = ""
        var i = 0
        while i < interleaveLimit {
            // `sxh.substring(i, i+1)` 后 `StringsKt.toIntOrNull`：越界或非数字一律按 0 处理。
            let digit = i < x.count ? (Int(String(x[i])) ?? 0) : 0
            // `code.substring(i, i+1)`：越界位置按空串处理（见类型注释里的越界保护）。
            let codeChar = i < code.count ? String(code[i]) : ""
            // Java 的 `intValue <= scodeOrig.length() ? scodeOrig.substring(0, intValue) : scodeOrig`
            // 等价于「取前 min(digit, 剩余长度) 个字符」——剩余不足时 Java 取全部并让 scode 置空。
            let take = min(digit, scode.count)
            out += codeChar + String(scode[0..<take])
            scode.removeFirst(take)
            i += 1
        }
        // `:158`：下标 20 之后的剩余部分原样追加。
        if i < code.count {
            out += String(code[i...])
        }
        return out
    }
}
