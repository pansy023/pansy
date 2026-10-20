import Foundation

/// 「登录教务系统 → 抓取课表 → 回填 id」的编排层。
///
/// 逐字对应 Android 1.11.5 `kebiaocom/example/sync/JwxtTimetableSync.java`
/// （`JwxtTimetableSync$fetchFromJwxt$1` 协程体，行号引用该反编译体）：
///
/// ```
/// var url = credentials.jwxtUrl
/// if (url.isEmpty()) url = UserCredentials.DEFAULT_JWXT_URL   // :49-51
/// parser = QiangzhiJwxtParser(url, logManager)                // :52
/// ok = parser.login(credentials.username, credentials.password) // :57
/// if (ok) throw Exception("登录教务系统失败，请检查账号密码")   // :84-85 ← jadx 取反，见下
/// list = parser.fetchTimetable()                              // :89
/// return list.mapIndexed { index, c -> c.copy(id = index + 1) } // :68-79
/// ```
///
/// ## jadx 反编译取反（recon doc §11 第 6 条）
///
/// `:84-85` 的反编译结果是 `if (loginResult) { throw ... }`，即「登录**成功**才抛
/// 登录失败异常」，显然不可能。Kotlin 源码必然是 `if (!ok) throw ...`，jadx 把
/// 「取反跳转」渲染丢了。本实现按自洽语义：`!result.isLoggedIn` → 抛
/// `JwxtSyncError.loginFailed`，`errorDescription` **逐字**为 Android 的异常文案
/// 「登录教务系统失败，请检查账号密码」（`:85`）。
///
/// ## 与原版一致的一处关键点
///
/// Android 每一跳都在**同一个 `QiangzhiJwxtParser` 实例**上累积 Cookie（实例字段
/// `cookies`，recon doc §3），所以登录与抓课表必须共用同一个 `JwxtSession`。
/// 这里照做：整个 `fetchFromJwxt` 期间只建一个 `JwxtSession`，把登录的 Cookie
/// 直接延续给抓课表那一跳。会话**不跨调用持久化**（每次 `fetchFromJwxt` 新建），
/// 与原版「每次同步 new 一个 parser」一致。
public final class JwxtTimetableSync: @unchecked Sendable {

    /// 可选日志出口（原版 `LogManager` 的等价缝）。iOS 端不新增日志基础设施，默认丢弃。
    public let log: (@Sendable (String) -> Void)?

    /// 测试用 `URLProtocol` 桩时传入装了 `protocolClasses` 的配置；生产传 `nil`。
    public let configuration: URLSessionConfiguration?

    /// 最近一次「抓课表」那一跳的**分段诊断汇总**（多行文本；真机上直接展示在状态文案里）。
    ///
    /// 成功与失败都写：定位「英语 / 体育 / 高等数学 在哪一环丢」靠的就是它。
    /// 根本没走到抓课表（例如登录就没过）时为空串 —— 那种情况由错误文案里的
    /// 登录轨迹 + Cookie 诊断覆盖，不重复追加。
    ///
    /// 为什么这个类型是 `class` 而不是 `struct`：`fetchFromJwxt` 由调用方在 `let`
    /// 临时实例上直接调用，`struct` 里的 `attempt` 无法把结果写回调用方看得见的地方。
    /// 行为与初始化方式（`JwxtTimetableSync()` / `JwxtTimetableSync(log:configuration:)`）不变。
    public private(set) var lastSyncDiagnostics = ""

    public init(
        log: (@Sendable (String) -> Void)? = nil,
        configuration: URLSessionConfiguration? = nil
    ) {
        self.log = log
        self.configuration = configuration
    }

    /// 登录教务系统并抓取课表。
    ///
    /// - Parameter credentials: `jwxtUrl` 为空时回落到 `UserCredentials.defaultJwxtUrl`
    ///   （等价 `:49-51`）。
    /// - Returns: 抓到的课程，`id` 已按 `index + 1` 回填（等价 `:68-79`）。
    /// - Throws: `JwxtSyncError.loginFailed`（登录未通过）；
    ///   `JwxtFetchError.sessionExpired` / `.pageStructureUnsupported`（抓课表那一跳失败）。
    ///
    /// ⚠️ **与原版刻意不同的一处**：原版抓课表失败时返回空表（`fetchTimetable` 内部吞成 `[]`），
    /// iOS 侧 `fetchTimetable` 改为抛 `JwxtFetchError`（见该文件文件头「有意差异 4」）。
    /// 这里额外做一次**自愈重试**：若失败原因是「会话已失效」（服务端直接回登录页、
    /// 不重定向，原版判据在 iOS 上永不命中），就**重新走一遍完整登录**再抓一次；
    /// 仍失败则把诊断抛给上层，让 UI 显示具体原因而不是误导性的「未获取到课表数据」。
    public func fetchFromJwxt(credentials: UserCredentials) async throws -> [Course] {
        let rawURL = credentials.jwxtUrl
        let jwxtUrl = rawURL.isEmpty ? UserCredentials.defaultJwxtUrl : rawURL

        do {
            return try await attempt(jwxtUrl: jwxtUrl, credentials: credentials)
        } catch JwxtFetchError.sessionExpired(let diagnostic) {
            log?("会话已失效，重新登录后再抓一次（首次诊断：\(diagnostic)）")
            return try await attempt(jwxtUrl: jwxtUrl, credentials: credentials)
        }
    }

    /// 一次「登录 → 抓课表」的完整尝试（每次新建 `JwxtSession`，与原版一致）。
    private func attempt(jwxtUrl: String, credentials: UserCredentials) async throws -> [Course] {
        let session = JwxtSession(baseURL: jwxtUrl, configuration: configuration)
        // 诊断：把会话层每一跳的 **Cookie 名称 + 长度**收进来（不含值），
        // 登录失败时随错误文案一起带出去 —— 这样真机截图就能看出 Cookie 是在哪一跳丢的。
        let cookieLog = JwxtCookieDiagnosticBuffer()
        session.log = { line in cookieLog.append(line) }
        let loginClient = JwxtLoginClient(session: session)
        let loginResult = await loginClient.login(
            username: credentials.username,
            password: credentials.password
        )
        guard loginResult.isLoggedIn else {
            log?("登录教务系统失败，请检查账号密码")
            // 把**逐跳轨迹**与**逐跳 Cookie 诊断**一并带出去：真机上只看到一句
            // 「被跳回登录页」是定位不了根因的（2026-10-18/19/20 连续三轮都卡在这里）。
            // 轨迹里只有状态码 / 长度 / 标题 / 服务端原文片段 / **Cookie 名称与长度**，
            // 不含任何 Cookie 值与 `encoded`
            // （红线见 `JwxtLoginClient.lastLoginTrace` 与 `JwxtSession.log` 的注释）。
            var parts = [loginResult.diagnostic]
            let trace = loginClient.lastLoginTraceText
            if !trace.isEmpty { parts.append(trace) }
            let cookies = cookieLog.sectionText
            if !cookies.isEmpty { parts.append(cookies) }
            throw JwxtSyncError.loginFailed(detail: parts.joined(separator: "｜"))
        }

        let parser = QiangzhiJwxtParser(session: session, log: log)
        // 分段诊断：覆盖 ① 原始响应 ② 表格结构 ③ 单元格 ④ 课程文本 ⑤ 过滤与保存，
        // 并逐段追踪「英语 / 体育 / 高等数学」。只记计数与阶段名，不含账号 / Cookie / 令牌。
        let diagnostics = JwxtParseDiagnostics()
        parser.diagnostics = diagnostics
        let courses: [Course]
        do {
            courses = try await parser.fetchTimetable()
        } catch {
            // 失败也要把已记到的诊断带出去：至少能看到 ① 的 status/len/特征串
            // 与 ② 的表格结构计数，「课在哪一环丢」才有证据可言。
            lastSyncDiagnostics = diagnostics.summary()
            throw error
        }
        lastSyncDiagnostics = diagnostics.summary()
        return courses.enumerated().map { index, course in
            var copy = course
            copy.id = index + 1
            return copy
        }
    }
}

/// 同步层错误。
///
/// 文案以 Android `JwxtTimetableSync.java:85` 的
/// 「登录教务系统失败，请检查账号密码」**为前缀逐字保留**，后面再追加括号里的
/// 具体诊断（`detail`）—— 安卓原版只有这一句，但它在真机上无法区分失败原因，
/// 排查成本极高；括号内的部分是 iOS 侧新增的诊断信息，不改变原句本身。
public enum JwxtSyncError: Error, LocalizedError, Equatable, Sendable {
    /// 登录未通过（`!loginResult.isLoggedIn`）。
    case loginFailed(detail: String)

    public var errorDescription: String? {
        switch self {
        case let .loginFailed(detail):
            return "登录教务系统失败，请检查账号密码（诊断：\(detail)）"
        }
    }
}

/// 收集会话层每一跳输出的 Cookie 诊断行（只含**名称 + 值长度**，不含值）。
///
/// 为什么要单独一个类：`JwxtSession.log` 的回调可能来自任意线程，
/// 而 `JwxtTimetableSync` 是值类型、不能持有可变数组（`attempt` 也不是 `mutating`）。
/// 用一个加锁的小缓冲把两边的约束拆开，不改变既有分层。
final class JwxtCookieDiagnosticBuffer: @unchecked Sendable {

    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        lines.append(line)
    }

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return lines.isEmpty
    }

    /// 拼成一段可读文本（每跳一行）；空则返回 `""`。
    var sectionText: String {
        lock.lock()
        defer { lock.unlock() }
        guard !lines.isEmpty else { return "" }
        return "【Cookie 诊断】" + lines.joined(separator: "\n")
    }
}
