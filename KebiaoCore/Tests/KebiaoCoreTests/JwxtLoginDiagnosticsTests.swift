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

    // MARK: - 选课入口「进入首页」跳（recon doc §2.6）

    /// 登录响应命中选课入口时，必须 GET `xsMainV.jsp`（**不是**入口页 `xsrkxz.htmlx` 本身），
    /// 且 `timetableReferer` 必须记成那个 `.jsp` 地址。
    ///
    /// 真机截图 `status=200 title=登录 len=18942 hasTimetableId=false` 的根因就是这里：
    /// 早先版本从没发过这一跳，`jsxsd` 侧因此从未建立认证会话。
    func testGatewayHandoffRequestsXsMainVJspAndUsesItAsReferer() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [JwxtStubURLProtocol.self]

        let recorder = JwxtRequestRecorder()
        JwxtStubURLProtocol.setResponder { request in
            let url = request.url?.absoluteString ?? ""
            recorder.record(url: url, referer: request.value(forHTTPHeaderField: "Referer"))
            if url.contains("flag=sess") {
                // 真服务器实测返回的形状：`scode#sxh`。
                return (200, Data("h58B979U1618a17P44a7RZ5VbYa5P5nfpQXoa2s#11311111132323322323".utf8))
            }
            if url.contains("/Logon.do?method=logon"), request.httpMethod == "POST" {
                // 登录响应 = 选课入口页（正文含「入口选择」），命中 `login$2.java:229` 分支。
                return (200, Data(
                    "<html><head><title>入口选择</title></head><body>进入选课 进入首页</body></html>".utf8
                ))
            }
            // 其余每一跳（首页 / xsMainV.jsp / xsMainV.htmlx）都回一个**非登录页**。
            return (200, Data(
                "<html><head><title>学生个人中心</title></head><body>ok</body></html>".utf8
            ))
        }
        defer { JwxtStubURLProtocol.setResponder(nil) }

        let client = JwxtLoginClient(
            baseURL: UserCredentials.defaultJwxtUrl,
            configuration: configuration
        )
        let result = await client.login(username: "20230001", password: "Abc12345!")

        XCTAssertTrue(result.isLoggedIn, "入口页分支应判为登录成功，实际：\(result.diagnostic)")

        let jsp = UserCredentials.defaultJwxtUrl + JwxtLoginClient.gatewayHomePath
        let entry = UserCredentials.defaultJwxtUrl + JwxtLoginClient.gatewayEntryPath

        XCTAssertTrue(
            recorder.urls.contains(jsp),
            "必须真的 GET \(jsp)；实际请求过：\(recorder.urls)"
        )
        XCTAssertTrue(
            recorder.referers(for: jsp).contains(entry),
            "GET \(jsp) 的 Referer 必须是入口页 \(entry)"
        )
        XCTAssertFalse(
            recorder.urls.contains { $0.hasSuffix(JwxtLoginClient.gatewayEntryPath) },
            "入口页只当 Referer，绝不能被当成目标 GET；实际请求过：\(recorder.urls)"
        )
        XCTAssertEqual(
            result,
            JwxtLoginClient.JwxtLoginResult.selectionGateway(referer: jsp),
            "`timetableReferer` 必须是 `.jsp` 地址（原版 `QiangzhiJwxtParser.java:123` 写死 str3）"
        )
    }

    /// 即使命中入口页分支（曾无条件判「成功」），只要收尾跳拿到的**还是登录页**，
    /// 就必须如实报失败 —— 不能把问题甩给后面抓课表那一跳、让用户看到误导性的
    /// 「教务系统会话已失效」。
    func testGatewayBranchFailsWhenMainFrameIsStillTheLoginPage() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [JwxtStubURLProtocol.self]

        JwxtStubURLProtocol.setResponder { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("flag=sess") {
                return (200, Data("h58B979U1618a17P44a7RZ5VbYa5P5nfpQXoa2s#11311111132323322323".utf8))
            }
            if url.contains("/Logon.do?method=logon"), request.httpMethod == "POST" {
                return (200, Data(
                    "<html><head><title>入口选择</title></head><body>进入选课 进入首页</body></html>".utf8
                ))
            }
            if url.hasSuffix(JwxtLoginClient.mainFramePath) {
                // 收尾跳仍然是 jsxsd 登录页（真机实测 18942 字符、title=登录）。
                return (200, Data(
                    "<html><head><title>登录</title></head><body>请先登录系统</body></html>".utf8
                ))
            }
            return (200, Data(
                "<html><head><title>入口选择</title></head><body>进入选课 进入首页</body></html>".utf8
            ))
        }
        defer { JwxtStubURLProtocol.setResponder(nil) }

        let client = JwxtLoginClient(
            baseURL: UserCredentials.defaultJwxtUrl,
            configuration: configuration
        )
        let result = await client.login(username: "20230001", password: "Abc12345!")

        XCTAssertFalse(result.isLoggedIn, "收尾跳仍是登录页时不得判成功，实际：\(result.diagnostic)")
        XCTAssertEqual(result, JwxtLoginClient.JwxtLoginResult.titleRejected(title: "登录"))
    }

    // MARK: - 逐跳轨迹（真机排查用）

    /// 登录失败后必须留下**逐跳轨迹**，且轨迹里绝不能出现明文密码 / `encoded` / Cookie 值。
    ///
    /// 为什么需要：真机上只能看到一句「被跳回登录页（验活页 title=登录）」，它既说不出
    /// **是哪一跳**出的问题、也说不出**服务端到底回了什么**，2026-10-18/19 连续两轮排查
    /// 都卡在这里。这条用例锁住两件事：轨迹必须覆盖全部四跳；轨迹必须不泄露任何凭证。
    func testLastLoginTraceRecordsAllHopsWithoutLeakingSecrets() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [JwxtStubURLProtocol.self]

        JwxtStubURLProtocol.setResponder { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("flag=sess") {
                // 真服务器实测返回的形状：`scode#sxh`。
                return (200, Data("abc#12345678901234567890".utf8))
            }
            // 登录 POST 与之后的每一跳都回登录页 ⇒ 最终判定必须是 titleRejected。
            return (200, Data(
                "<html><head><title>登录</title></head><body>请先登录系统</body></html>".utf8
            ))
        }
        defer { JwxtStubURLProtocol.setResponder(nil) }

        let client = JwxtLoginClient(
            baseURL: UserCredentials.defaultJwxtUrl,
            configuration: configuration
        )
        let result = await client.login(username: "20230001", password: "Secret!123")

        XCTAssertFalse(result.isLoggedIn, "这条桩数据必须判成登录失败，实际：\(result.diagnostic)")
        XCTAssertEqual(result, JwxtLoginClient.JwxtLoginResult.titleRejected(title: "登录"))

        let trace = client.lastLoginTraceText
        XCTAssertFalse(trace.isEmpty, "登录失败时必须留下逐跳轨迹，否则真机上仍然无 clue")
        for hop in ["① GET", "② POST", "③ POST", "④ GET"] {
            XCTAssertTrue(trace.contains(hop), "轨迹缺少「\(hop)」这一跳，实际：\(trace)")
        }
        XCTAssertTrue(trace.contains("title=登录"), "轨迹必须带出服务端返回的页面标题，实际：\(trace)")

        // 红线：轨迹是给用户截图回传的，绝不能带出任何可被利用的凭证。
        XCTAssertFalse(trace.contains("Secret!123"), "轨迹绝不能包含明文密码，实际：\(trace)")
        XCTAssertFalse(trace.lowercased().contains("encoded"), "轨迹绝不能出现 encoded，实际：\(trace)")
    }

    // MARK: - 重定向与会话交接（真机「被跳回登录页」的另一半）

    /// 委托必须**拒绝**跟随重定向。
    ///
    /// 为什么这条要被锁住：本会话层的 Cookie 是自己管的（`httpShouldSetCookies = false`、
    /// `httpCookieStorage = nil`），逐跳的 `Set-Cookie` 靠 `JwxtSession.send` 的循环接住。
    /// 只要 `URLSession` 自己把 302 跟掉，**那一跳的 `Set-Cookie` 就结构性拿不到**，
    /// 会话交接静默断掉 —— 真机轨迹里 `POST /Logon.do` 之后 `final` 已经落到
    /// `/jsxsd/framework/xsrkxz.htmlx`（门户那一关过了），可 jsxsd 侧仍然只返回登录页，
    /// 根因就是这里。
    func testRedirectBlockerRefusesToFollowSoPerHopSetCookieStaysVisible() {
        let delegate = JwxtRedirectBlockingDelegate()
        let from = URL(string: "https://jwgl.xihang.com.cn/Logon.do?method=logon")!
        let target = URL(string: "https://jwgl.xihang.com.cn/jsxsd/framework/xsrkxz.htmlx")!
        let redirect = HTTPURLResponse(
            url: from,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": target.absoluteString]
        )!

        var callbackInvoked = false
        var handedBack: URLRequest? = URLRequest(url: target)
        delegate.urlSession(
            URLSession.shared,
            task: URLSession.shared.dataTask(with: from),
            willPerformHTTPRedirection: redirect,
            newRequest: URLRequest(url: target)
        ) { request in
            callbackInvoked = true
            handedBack = request
        }

        XCTAssertTrue(callbackInvoked, "委托没有被回调 —— 那就说明 URLSession 会按默认行为把 302 跟掉")
        XCTAssertNil(handedBack, "必须交回 nil（不跟随）；重定向要留给 JwxtSession.send 自己处理")
    }

    /// `send` 必须**自己**逐跳跟随重定向，并把**重定向那一跳**下发的 Cookie 带到下一跳。
    ///
    /// 这就是 jsoup / 浏览器的行为，也是安卓能过、iOS 过不去的那条链路。
    func testSendFollowsRedirectManuallyAndCarriesRedirectSetCookie() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [JwxtRedirectStubURLProtocol.self]

        let recorder = JwxtCookieRecorder()
        let logon = UserCredentials.defaultJwxtUrl + "/Logon.do?method=logon"
        let landing = UserCredentials.defaultJwxtUrl + "/jsxsd/framework/xsMainV.htmlx"

        JwxtRedirectStubURLProtocol.setResponder { request in
            let url = request.url?.absoluteString ?? ""
            recorder.record(url: url, cookie: request.value(forHTTPHeaderField: "Cookie"))
            if url == logon {
                // 门户登录成功后的典型形态：302 进 jsxsd，并在这一跳下发 jsxsd 的会话 Cookie。
                return (
                    302,
                    [
                        "Location": "/jsxsd/framework/xsMainV.htmlx",
                        "Set-Cookie": "bzb_jsxsd=authed-session; Path=/",
                    ],
                    Data()
                )
            }
            return (
                200,
                [:],
                Data("<html><head><title>学生个人中心</title></head><body>欢迎</body></html>".utf8)
            )
        }
        defer { JwxtRedirectStubURLProtocol.setResponder(nil) }

        let session = JwxtSession(baseURL: UserCredentials.defaultJwxtUrl, configuration: configuration)
        let response = try await session.send(
            logon,
            options: JwxtSession.RequestOptions(method: "POST", form: [("userAccount", "20230001")])
        )

        XCTAssertEqual(response.statusCode, 200, "302 应被逐跳跟随到 200")
        XCTAssertEqual(
            response.finalURL?.absoluteString, landing,
            "最终 URL 应是重定向目标；实际：\(response.finalURL?.absoluteString ?? "nil")"
        )
        XCTAssertEqual(
            session.cookies["bzb_jsxsd"], "authed-session",
            "重定向那一跳的 Set-Cookie 必须并进会话罐子；实际：\(session.cookies)"
        )
        XCTAssertTrue(
            recorder.cookies(for: landing).contains { ($0 ?? "").contains("bzb_jsxsd=authed-session") },
            "重定向那一跳下发的会话 Cookie 必须被带到下一跳（否则 jsxsd 会话永远建立不起来）；"
                + "实际请求：\(recorder.entries)"
        )
    }
}

/// 记录桩 `URLProtocol` 收到的每一次请求（URL + Referer），供回归断言使用。
private final class JwxtRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(url: String, referer: String?)] = []

    func record(url: String, referer: String?) {
        lock.lock()
        defer { lock.unlock() }
        entries.append((url, referer))
    }

    var urls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries.map { $0.url }
    }

    func referers(for url: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries.filter { $0.url == url }.compactMap { $0.referer }
    }
}

/// 能返回**自定义响应头**（`Location` / `Set-Cookie`）的桩。
///
/// 现有的 `JwxtStubURLProtocol` 只会回一个固定 `Content-Type`，做不出「302 + Set-Cookie」
/// 这种形态 —— 而整条「重定向那一跳的会话 Cookie 会不会丢」的链路恰恰要靠它来验证。
final class JwxtRedirectStubURLProtocol: URLProtocol {

    /// `(statusCode, headers, body)`；未设置时按 404 处理。
    private static var responder: ((URLRequest) -> (Int, [String: String], Data))?
    private static let lock = NSLock()

    static func setResponder(_ value: ((URLRequest) -> (Int, [String: String], Data))?) {
        lock.lock()
        defer { lock.unlock() }
        responder = value
    }

    private static func currentResponder() -> ((URLRequest) -> (Int, [String: String], Data))? {
        lock.lock()
        defer { lock.unlock() }
        return responder
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let responder = JwxtRedirectStubURLProtocol.currentResponder(),
              let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, headers, data) = responder(request)
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// 记录每一次请求的 URL 与**实际发出去的 `Cookie` 头**（后者是「逐跳带 Cookie」的直接证据）。
private final class JwxtCookieRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(url: String, cookie: String?)] = []

    func record(url: String, cookie: String?) {
        lock.lock()
        defer { lock.unlock() }
        entries.append((url, cookie))
    }

    func cookies(for url: String) -> [String?] {
        lock.lock()
        defer { lock.unlock() }
        return entries.filter { $0.url == url }.map { $0.cookie }
    }

    var entries: [(url: String, cookie: String?)] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}
