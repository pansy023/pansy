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
public struct JwxtTimetableSync: @unchecked Sendable {

    /// 可选日志出口（原版 `LogManager` 的等价缝）。iOS 端不新增日志基础设施，默认丢弃。
    public let log: (@Sendable (String) -> Void)?

    /// 测试用 `URLProtocol` 桩时传入装了 `protocolClasses` 的配置；生产传 `nil`。
    public let configuration: URLSessionConfiguration?

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
    ///   抓不到课表时返回**空数组**（原版 `fetchTimetable` 也是返回空表，不抛错）。
    /// - Throws: `JwxtSyncError.loginFailed`（登录未通过）。
    ///   抓课表时的网络/解析异常照原样抛出（原版 `fetchTimetable` 内部 catch 后返回空表，
    ///   见 `QiangzhiJwxtParser$fetchTimetable$2.java`；iOS 侧 `fetchTimetable` 保持同语义）。
    public func fetchFromJwxt(credentials: UserCredentials) async throws -> [Course] {
        let rawURL = credentials.jwxtUrl
        let jwxtUrl = rawURL.isEmpty ? UserCredentials.defaultJwxtUrl : rawURL

        let session = JwxtSession(baseURL: jwxtUrl, configuration: configuration)
        let loginClient = JwxtLoginClient(session: session)
        let loginResult = await loginClient.login(
            username: credentials.username,
            password: credentials.password
        )
        guard loginResult.isLoggedIn else {
            log?("登录教务系统失败，请检查账号密码")
            throw JwxtSyncError.loginFailed
        }

        let parser = QiangzhiJwxtParser(session: session, log: log)
        let courses = try await parser.fetchTimetable()
        return courses.enumerated().map { index, course in
            var copy = course
            copy.id = index + 1
            return copy
        }
    }
}

/// 同步层错误。文案逐字取自 Android `JwxtTimetableSync.java:85`。
public enum JwxtSyncError: Error, LocalizedError, Equatable, Sendable {
    /// 登录未通过（`!loginResult.isLoggedIn`）。
    case loginFailed

    public var errorDescription: String? {
        switch self {
        case .loginFailed: return "登录教务系统失败，请检查账号密码"
        }
    }
}
