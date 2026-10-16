import Foundation

/// 强智教务（Qiangzhi JWXT）登录客户端。
///
/// 本文件逐句对应 Android 端 `QiangzhiJwxtParser.kt` 的 `login(...)`
/// （反编译体为 `QiangzhiJwxtParser$login$2.java`，下文引用的行号都指该文件）。
///
/// ## 完整流程（4 个请求，顺序不可换）
///
/// 1. `GET  {secureBase}/`            → 播种 JSESSIONID（`login$2.java:145`）
/// 2. `POST {secureBase}/Logon.do?method=logon&flag=sess` → 取 `scode#sxh`（`:158`）
/// 3. `POST {secureBase}/Logon.do?method=logon`           → 真正登录（`:199`）
/// 4. `GET  {secureBase}/jsxsd/framework/xsMainV.htmlx`   → 验活并续 Cookie（`:232`）
///
/// ## 登录成功判定（`:227-242`）——**三段式，顺序敏感**
///
/// ```
/// if body.contains("欢迎") || body.contains("主页")            → 成功（跳过验活跳）
/// else if body.contains("用户名或密码错误") || body.contains("密码错误") → 失败
/// else if url.contains("xsrkxz") || body.contains("入口选择")
///         || (body.contains("进入选课") && body.contains("进入首页")) → 成功（选课入口页）
/// else → GET xsMainV.htmlx，取 <title>；title == "登录" 或含 "Login" → 失败，否则成功
/// ```
///
/// ⚠️ **两处 Java 层面的缺陷，本实现刻意不复制**（其余行为逐条对齐）：
///
/// - **缺陷 A（`z` 未初始化）**：`z` 在 `try` 成功路径上只在「选课入口页」分支里被赋值
///   （`:253`、`:290`、`:326`）。走「验活跳 `title` 检查」路径时 `z` 仍是未赋值状态，
///   若 `title != "登录"` 且不含 `"Login"`（`:240-242`），`return Boxing.boxBoolean(z)`
///   会抛 `NullPointerException`…… 会被 `:345` 的 `catch (Exception)` 吞掉并返回 `false`，
///   于是**登录成功也会被报成失败**。但新版本 javac 对明确未赋值的局部变量会直接编译报错，
///   所以真实 APK 里 Kotlin 编译器生成的字节码应当不同（这份 jadx 反编译体已被标注
///   `Code decompiled incorrectly`，`:56`），**证据不足以确定原始语义**。
///   处理：本实现把「验活跳 title 非 Login」视作**成功**（这是唯一自洽的语义），并在
///   `JwxtLoginResult.titleVerified` 这个独立 case 上标注出来，不做其它猜测。
/// - **缺陷 B（子条件恒真）**：`:229` 的
///   `!contains(body,"进入选课") || !contains(body,"进入首页")` 用 `||` —— 除两词同时出现外
///   恒为真，等于「只要 `url` 不含 `xsrkxz` 且 `body` 不含 `入口选择` 就进这个分支」。
///   这是 bug 而**不是**有意规则，本实现改用 `&&`（即「标题页含『进入选课』和『进入首页』
///   才算选课入口页」），并在 `JwxtLoginResult.selectionGateway` 上标注。
///
/// ## 已导入 / 重复导入
///
/// ⚠️ 这一步**在 `login` 之外**：`sessions` 的写入、旧课表清理与「是否已导入」判断位于
/// `sync/JwxtTimetableSync.java` 与 `TimetableStore` 侧，recon doc §8 只给了「先清后插、
/// 保留已有周次」的行为描述，**没有给出一个可从登录响应里读出的「已导入」标志**。
/// 因此这里**不发明**任何「已导入」字段或接口，只在 `JwxtLoginClient` 上保留
/// `hasImportedBefore` 这个可注入的查询闭包作为接缝（默认 `{ false }`），
/// 供上层 sync 层按自己的持久化状态判断。详见 `docs/recon/notes-jwxt-implementation.md`。
///
/// ## 未发现的流程（不得发明）
///
/// - **验证码（captcha）**：反编译源码与 recon doc 中**没有任何**验证码字段、图片验证或
///   `captcha`/`checkcode` 相关的 `.data(...)`。因此**不实现验证码流程**，
///   仅在 `JwxtLoginResult.unknown` 的说明里提示「若响应既非成功也非任一已知失败串，
///   可能是服务端新增了交互（如验证码），需要重新取证」。
/// - **专属认证（webvpn / `专属认证`）**：源码中没有该校验，登录失败时只会落到上面的
///   「用户名或密码错误」或「登录失败」。因此**不实现**，只保留 `unknown` 分支。
public final class JwxtLoginClient: @unchecked Sendable {

    /// 与会话层共用的标签（对齐 Android 端 `TAG = "QiangzhiJwxtParser"`）。
    public static let tag = "QiangzhiJwxtParser"

    /// `HttpConnection.FORM_URL_ENCODED`，即 `application/x-www-form-urlencoded`
    /// （`login$2.java:199`）。
    public static let formURLEncoded = "application/x-www-form-urlencoded"

    /// 登录 POST 的固定路径（`login$2.java:193`）。
    public static let logonPath = "/Logon.do?method=logon"
    /// 取加密参数的固定路径（`login$2.java:152`）。
    public static let sessionKeyPath = "/Logon.do?method=logon&flag=sess"
    /// 验活页固定路径（`login$2.java:232`、`:247`、`:285`、`:321`）。
    public static let mainFramePath = "/jsxsd/framework/xsMainV.htmlx"

    /// 成功判定用的中文串，逐字来自 `login$2.java:227-229`
    /// —— **禁止改动这些字面量**。
    public enum Marker {
        public static let welcome = "欢迎"          // :227
        public static let home = "主页"             // :227
        public static let badCredentials = "用户名或密码错误" // :228
        public static let badPassword = "密码错误"   // :228
        public static let gatewayURL = "xsrkxz"     // :229
        public static let gatewayTitle = "入口选择"  // :229
        public static let enterSelection = "进入选课" // :229
        public static let enterHome = "进入首页"     // :229
        public static let loginTitle = "登录"        // :240
        public static let loginTitleEnglish = "Login" // :242
    }

    /// 注入的会话（持 Cookie、管重定向与编码）。
    public let session: JwxtSession

    /// 「此前是否导入过」的接缝。默认恒 `false`；上层可注入真实实现。
    ///
    /// ⚠️ evidence 只证明「旧课表清理 + 保留周次」发生在写入阶段（recon doc §8），
    /// 不足以证明登录阶段读得到「已导入」标志；此处不发明协议，只留闭包。
    public var hasImportedBefore: @Sendable () -> Bool

    public init(
        session: JwxtSession,
        hasImportedBefore: @escaping @Sendable () -> Bool = { false }
    ) {
        self.session = session
        self.hasImportedBefore = hasImportedBefore
    }

    /// 便捷构造：直接给教务根地址。
    public convenience init(baseURL: String, configuration: URLSessionConfiguration? = nil) {
        self.init(session: JwxtSession(baseURL: baseURL, configuration: configuration))
    }

    // MARK: - 结果类型

    /// 登录结果分类。每个 case 都对应 `login$2.java` 的一个真实分支。
    public enum JwxtLoginResult: Equatable, Sendable {
        /// `body` 含「欢迎」或「主页」（`:227`、`:312-335`）。
        case successWelcome
        /// 命中选课入口页（`:229`、`:276-299` 或 `:275` 的 `进入选课` 分支）。
        case selectionGateway(referer: String?)
        /// 走到验活跳且 `<title>` 既不是「登录」也不含「Login」（`:240-243`）。
        ///
        /// 这一分支在 Java 反编译体里会因未初始化的 `z` 抛异常 → 被吞成 `false`
        /// （见文件头「缺陷 A」）。本实现按唯一自洽语义返回成功，并单独标注。
        case titleVerified(title: String)
        /// `body` 含「用户名或密码错误」或「密码错误」（`:228`、`:300-310`）。
        case invalidCredentials
        /// `GET /Logon.do?...&flag=sess` 的响应为空、为 `"no"` 或不含 `#`（`:172`、`:337-341`）。
        case sessionKeyMissing
        /// 验活跳的 `<title>` 是「登录」或含「Login」（`:240-242`、`:268-274`）。
        case titleRejected(title: String)
        /// 网络/解析异常（对应 `catch (Exception)`，`:168`、`:345`）。
        case transportFailure(message: String)
        /// 响应既非成功也非任一已知失败串。
        ///
        /// ⚠️ 原版在这种情况下会落到 `<title>` 检查，本实现也一样；只有当 `<title>`
        /// 也为空（拿不到标题）时才归入此 case。**这不是原版的一个分支**，是本实现对
        /// 「证据不足」的显式归口，避免默默返回成功。
        /// 若服务端新增了验证码之类的交互，请重新取证后再实现。
        case unknown(detail: String)

        /// 是否应当继续后续的抓课表流程。
        public var isLoggedIn: Bool {
            switch self {
            case .successWelcome, .selectionGateway, .titleVerified: return true
            case .invalidCredentials, .sessionKeyMissing, .titleRejected,
                 .transportFailure, .unknown: return false
            }
        }
    }

    /// ⚠️ 注意命名：为免与 `JwxtSession` 底层错误混淆，登录层错误单独定义（见文件尾）。
    public enum JwxtLoginError: Error, LocalizedError, Equatable, Sendable {
        case emptyBaseURL
        case emptyUsername

        public var errorDescription: String? {
            switch self {
            case .emptyBaseURL: return "教务系统地址为空"
            case .emptyUsername: return "用户名为空"
            }
        }
    }

    // MARK: - 登录主流程

    /// 执行登录。返回分类结果；**不抛业务异常**（网络错误会被归成
    /// `.transportFailure`，对齐原版 `catch (Exception) → false` 的语义）。
    ///
    /// - Parameters:
    ///   - username: 学号（`UserCredentials.username`）。
    ///   - password: 明文密码（来自 Keychain）。加密在 `encryptCode` 内部完成。
    public func login(username: String, password: String) async -> JwxtLoginResult {
        let base = session.secureBaseURL
        guard !base.isEmpty else { return .transportFailure(message: "教务系统地址为空") }
        guard !username.isEmpty else { return .transportFailure(message: "用户名为空") }

        // `login$2.java:136`：每次登录前清空 timetableReferer。
        session.setTimetableReferer(nil)

        // ── 步骤 1：访问首页播种 JSESSIONID（`:139-145`）────────────────────
        let seedURL = base + "/"
        var seedCookies: [String: String]
        do {
            let seed = try await session.send(
                seedURL,
                options: JwxtSession.RequestOptions(method: "GET", headers: [:], carriesCookies: false)
            )
            seedCookies = seed.cookies
        } catch {
            return .transportFailure(message: String(describing: error))
        }
        // 对齐 `:206` 的 `toMutableMap(cookies)`：后面每一步都在同一个可变 Map 上累积。
        var accumulated = seedCookies

        // ── 步骤 2：取加密参数（`:151-167`）────────────────────────────────
        let sessionKeyURL = base + JwxtLoginClient.sessionKeyPath
        var keyBody = ""
        do {
            let keyResponse = try await session.send(
                sessionKeyURL,
                options: JwxtSession.RequestOptions(method: "POST", headers: [:], carriesCookies: false)
            )
            keyBody = keyResponse.body
            for (name, value) in keyResponse.cookies { accumulated[name] = value }
        } catch {
            return .transportFailure(message: String(describing: error))
        }

        // `:172`：`body != "no" && body.contains("#")`，否则记「获取加密参数失败」并返回 false。
        guard keyBody != "no", keyBody.contains("#") else {
            session.mergeCookies(accumulated)
            return .sessionKeyMissing
        }

        // `:173-175`：split("#")，取第 0、1 段（**不是** limit=2，但只读前两段）。
        let pieces = keyBody.components(separatedBy: "#")
        guard pieces.count >= 2 else { return .sessionKeyMissing }
        let scode = pieces[0]
        let sxh = pieces[1]

        // `:186`：`encryptCode(username + "%%%" + password, scode, sxh)`。
        let encoded = JwxtEncryptor.encryptCode(raw: username + "%%%" + password, scode: scode, sxh: sxh)

        // ── 步骤 3：POST 登录（`:192-224`）─────────────────────────────────
        let logonURL = base + JwxtLoginClient.logonPath
        let loginResponse: JwxtSession.Response
        do {
            loginResponse = try await session.send(
                logonURL,
                options: JwxtSession.RequestOptions(
                    method: "POST",
                    form: [
                        ("userAccount", username),     // :199
                        ("userPassword", ""),          // :199 —— 原版就传空串，密码在 encoded 里
                        ("encoded", encoded),          // :199
                    ],
                    headers: [
                        // :199 的 header("Referer", str4)；str4 == secureBaseUrl + "/"
                        "Referer": seedURL,
                        "Content-Type": JwxtLoginClient.formURLEncoded,
                    ],
                    carriesCookies: false
                )
            )
        } catch {
            return .transportFailure(message: String(describing: error))
        }
        for (name, value) in loginResponse.cookies { accumulated[name] = value }

        // `:210-217`：优先 `execute.parse().text()`（DOM 文本），失败才退回 `execute.body()`。
        // 「parse 失败」不是 HTML 不合法，而是 jsoup 遇到超长/畸形文档时的内部异常，
        // 在 iOS 上等价的判断是「文本抽取结果为空」→ 回退到原始 body。
        let body: String = {
            let text = JwxtHTML.plainText(loginResponse.body)
            return text.isEmpty ? loginResponse.body : text
        }()
        let finalURL = loginResponse.finalURL?.absoluteString ?? logonURL

        // `:227`：欢迎 / 主页 → 成功。
        if body.contains(JwxtLoginClient.Marker.welcome) || body.contains(JwxtLoginClient.Marker.home) {
            return await finishLogin(accumulated: accumulated, logonFinalURL: finalURL, logonBody: body)
        }

        // `:228`：明确的口令错误。
        if body.contains(JwxtLoginClient.Marker.badCredentials) || body.contains(JwxtLoginClient.Marker.badPassword) {
            session.mergeCookies(accumulated)
            return .invalidCredentials
        }

        // `:229`：选课入口页判定。
        // 原版是 `!url.contains("xsrkxz") && !body.contains("入口选择") && (!body.contains("进入选课") || !body.contains("进入首页"))`
        // → 取反进入标题检查；这里改写成「命中入口页」的正向条件（见文件头「缺陷 B」）。
        let urlIsGateway = finalURL.lowercased().contains(JwxtLoginClient.Marker.gatewayURL.lowercased())
        let bodyIsGateway = body.contains(JwxtLoginClient.Marker.gatewayTitle)
            || (body.contains(JwxtLoginClient.Marker.enterSelection) && body.contains(JwxtLoginClient.Marker.enterHome))
        if urlIsGateway || bodyIsGateway {
            return await finishLogin(accumulated: accumulated, logonFinalURL: finalURL, logonBody: body)
        }

        // ── 兜底：GET 验活页取 <title>（`:230-242`）──────────────────────────
        let title = await fetchMainFrameTitle(cookies: accumulated, logonFinalURL: finalURL, logonBody: body)
        guard !title.isEmpty else {
            // 拿不到标题：原版会因 `z` 未初始化而整体返回 false，本实现显式归为 unknown。
            session.mergeCookies(accumulated)
            return .unknown(detail: "登录响应既非已知成功串也非已知失败串，且无法获取验活页标题")
        }
        if title == JwxtLoginClient.Marker.loginTitle || title.contains(JwxtLoginClient.Marker.loginTitleEnglish) {
            return .titleRejected(title: title)
        }
        return await finishLogin(accumulated: accumulated, logonFinalURL: finalURL, logonBody: body, verifiedTitle: title)
    }

    // MARK: - 收尾

    /// 成功收尾：过选课网关 → GET xsMainV.htmlx 续 Cookie → 写回会话（`:243-265`、`:281-299`、
    /// `:317-335`）。
    ///
    /// - Parameter verifiedTitle: 仅当走的是「验活跳」成功分支时才有值。
    private func finishLogin(
        accumulated: [String: String],
        logonFinalURL: String,
        logonBody: String,
        verifiedTitle: String? = nil
    ) async -> JwxtLoginResult {
        var cookies = accumulated

        // `:245` / `:283` / `:319`：过选课入口网关（可能改写 timetableReferer）。
        let gatewayReferer = await passCourseSelectionGatewayIfNeeded(
            loginFinalURL: logonFinalURL,
            loginBody: logonBody,
            cookies: &cookies
        )

        // `:246-256`：GET 主页，Referer = timetableReferer ?? xsMainV.htmlx，带原版 UA。
        let mainURL = session.secureBaseURL + JwxtLoginClient.mainFramePath
        let referer = session.timetableReferer ?? mainURL
        do {
            let main = try await session.send(
                mainURL,
                options: JwxtSession.RequestOptions(
                    method: "GET",
                    headers: [
                        "Referer": referer,
                        "User-Agent": JwxtSession.userAgent,
                    ],
                    carriesCookies: false
                )
            )
            for (name, value) in main.cookies { cookies[name] = value }
        } catch {
            return .transportFailure(message: String(describing: error))
        }

        // `:257` / `:294` / `:330`：`this.cookies = mutableMap2`。
        session.mergeCookies(cookies)

        if let verifiedTitle {
            return .titleVerified(title: verifiedTitle)
        }
        if gatewayReferer != nil {
            return .selectionGateway(referer: gatewayReferer)
        }
        return .successWelcome
    }

    /// 取验活页 `<title>`（`:232` 的 `.parse().select("title").text()`）。
    ///
    /// 失败时返回空串（原版 `:233-234` 吞掉异常，`str5` 保持 `""`）。
    private func fetchMainFrameTitle(
        cookies: [String: String],
        logonFinalURL: String,
        logonBody: String
    ) async -> String {
        var working = cookies
        _ = await passCourseSelectionGatewayIfNeeded(
            loginFinalURL: logonFinalURL,
            loginBody: logonBody,
            cookies: &working
        )
        let mainURL = session.secureBaseURL + JwxtLoginClient.mainFramePath
        do {
            let main = try await session.send(
                mainURL,
                options: JwxtSession.RequestOptions(method: "GET", headers: [:], carriesCookies: false)
            )
            session.mergeCookies(working)
            for (name, value) in main.cookies { session.mergeCookies([name: value]) }
            return JwxtHTML.title(main.body)
        } catch {
            session.mergeCookies(working)
            return ""
        }
    }

    /// 选课入口网关。
    ///
    /// 与 `QiangzhiJwxtParser.java`（反编译体第 111-137 行）的 `passCourseSelectionGatewayIfNeeded`
    /// 对应：先看有没有 `xsrkxz` 相关的入口页，再 GET `{base}/jsxsd/framework/xsrkxz.htmlx`
    /// （仅当 `jsxsd` 出现在传入 URL 里），把 `timetableReferer` 记为跳转后的最终 URL。
    ///
    /// 返回被采用的 Referer（`nil` 表示没走网关）。
    ///
    /// ⚠️ 这里只复刻 recon doc §2 记录到的行为：进入条件为
    /// `url.contains("jsxsd")`，无匹配则直接返回。原始 `parseCourseSelectionGateway`
    /// 对响应 HTML 的具体选择器，recon doc 标注为**未取证**，因此这里只保存跳转后的 URL，
    /// 不去猜任何选择器。
    @discardableResult
    private func passCourseSelectionGatewayIfNeeded(
        loginFinalURL: String,
        loginBody: String,
        cookies: inout [String: String]
    ) async -> String? {
        let lowered = loginFinalURL.lowercased()
        // 只有命中选课入口才需要过网关（`:117`：`str.contains("xsrkxz")` 或正文含「入口选择」）。
        let hit = lowered.contains(JwxtLoginClient.Marker.gatewayURL.lowercased())
            || loginBody.contains(JwxtLoginClient.Marker.gatewayTitle)
        guard hit else { return nil }
        // `jsxsd` 出现在 URL 里才继续（原版 `str.contains("jsxsd")` 的等价判断）。
        guard lowered.contains("jsxsd") else { return nil }

        guard let gatewayURL = session.url("/jsxsd/framework/xsrkxz.htmlx") else { return nil }
        do {
            let response = try await session.send(
                gatewayURL.absoluteString,
                options: JwxtSession.RequestOptions(
                    method: "GET",
                    headers: ["Referer": loginFinalURL],
                    carriesCookies: false
                )
            )
            for (name, value) in response.cookies { cookies[name] = value }
            let referer = response.finalURL?.absoluteString ?? gatewayURL.absoluteString
            session.setTimetableReferer(referer)
            return referer
        } catch {
            return nil
        }
    }
}

/// 登录层可能抛出的错误（预留给上层；`login` 本身不抛）。
public enum JwxtLoginFailure: Error, LocalizedError, Equatable, Sendable {
    case notLoggedIn

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn: return "尚未登录教务系统"
        }
    }
}
