import XCTest
@testable import KebiaoCore

/// 登录失败诊断载荷（密码位数 + 服务端原文片段）的测试。
///
/// 这两项载荷**不是原版行为**，是 iOS 侧为真机排查新增的：真机上只看到一句
/// 「登录教务系统失败，请检查账号密码」，没法区分「密码串被键盘改过」与
/// 「服务端真的判密码错」。这里锁住它们的格式。
final class JwxtLoginDiagnosticsTests: XCTestCase {

    // MARK: - 服务端原文片段

    /// 截断规则：压掉换行/制表符与首尾空白，超过 60 个字符则截到 60 再加省略号。
    func testSnippetCollapsesWhitespaceAndTruncatesAtSixty() {
        let body = "<html><body><p>" + String(repeating: "长", count: 200) + "</p>\n\n</body></html>"
        let snippet = JwxtLoginClient.responseSnippet(body)
        XCTAssertEqual(snippet.count, 61, "应为 60 个字符 + 一个省略号，实际 \(snippet.count)")
        XCTAssertTrue(snippet.hasSuffix("…"), "截断后应以省略号收尾，实际：\(snippet)")
        XCTAssertFalse(snippet.contains("\n"), "换行应被压成空格")
    }

    /// 短响应原样带出（不截断），且一定要看得见服务端那句错误文案。
    func testSnippetSurfacesServerErrorText() {
        let html = "<html><body><span>用户名或密码错误</span></body></html>"
        let snippet = JwxtLoginClient.responseSnippet(html)
        XCTAssertTrue(snippet.contains("用户名或密码错误"), "实际：\(snippet)")
        XCTAssertTrue(snippet.count <= 61, "短响应也不应超过截断上限，实际 \(snippet.count)")
    }

    // MARK: - 诊断串

    /// 诊断串必须同时带上「密码位数」与「服务端原文」，否则真机上又变成无法区分的一团。
    func testInvalidCredentialsDiagnosticCarriesPasswordLengthAndSnippet() {
        // `JwxtLoginResult` 是 `JwxtLoginClient` 的**嵌套**类型（`JwxtLoginClient.swift:127`），
        // 必须用全限定名，否则编译报 `cannot find 'JwxtLoginResult' in scope`
        // —— CI run 39088525051 就是这么红的，已实测。
        let result = JwxtLoginClient.JwxtLoginResult.invalidCredentials(
            passwordLength: 13,
            bodySnippet: "用户名或密码错误"
        )
        XCTAssertFalse(result.isLoggedIn, "口令错误永远不算登录成功")
        let diagnostic = result.diagnostic
        XCTAssertTrue(diagnostic.contains("13"), "诊断串应带上密码位数，实际：\(diagnostic)")
        XCTAssertTrue(diagnostic.contains("用户名或密码错误"), "诊断串应带上服务端原文，实际：\(diagnostic)")
    }
}
