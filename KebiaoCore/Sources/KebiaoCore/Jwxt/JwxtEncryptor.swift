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
        // ⚠️ 循环上界是 **`code` 的长度**，不是常量 20。Java 是 `while (i < length)`
        // （`QiangzhiJwxtParser.java:129-132`，`length = code.length()`），登录页自带的
        // JS 同样是 `for (var i = 0; i < code.length; i++)`，并且 `else` 分支里
        // `i = code.length` 立刻收尾 —— 二者一致。
        //
        // 早先这里写成 `while i < interleaveLimit`（固定 20），当
        // `用户名+长度("3")+密码 < 20`（例如 10 位学号 + 6 位密码 = 19）时，
        // code 已经取完却仍在空转，会把多余的 `scode` 片段拼到 encoded 尾部，
        // 与服务端算出的值不一致 → 服务端解密失败 → 登录被判「密码错误」。
        while i < code.count {
            if i < interleaveLimit {
                // `sxh.substring(i, i+1)` 后 `StringsKt.toIntOrNull`：非数字按 0 处理；
                // `sxh` 本身短于 20 时按越界保护取 0（Java 在这里会抛下标越界）。
                let digit = i < x.count ? (Int(String(x[i])) ?? 0) : 0
                // Java 的 `intValue <= scodeOrig.length() ? scodeOrig.substring(0, intValue) : scodeOrig`
                // 等价于「取前 min(digit, 剩余长度) 个字符」——剩余不足时 Java 取全部并让 scode 置空。
                let take = min(digit, scode.count)
                out += String(code[i])
                out += String(scode[0..<take])
                scode.removeFirst(take)
                i += 1
            } else {
                // `:156-158` / JS 的 `else` 分支：下标 20 起的剩余部分原样追加，随即结束。
                out += String(code[i...])
                break
            }
        }
        return out
    }
}
