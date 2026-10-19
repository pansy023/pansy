import Foundation

/// 强智教务（Qiangzhi JWXT）会话层：Cookie 累积 + 每次请求的显式头构造。
///
/// 证据：`docs/recon/02-jwxt-login-and-parser.md` §1（网络库/超时/UA/Referer/重定向/编码）、
/// §3（会话管理）。对应 Android 端 `QiangzhiJwxtParser` 的实例字段
/// `private Map<String,String> cookies`（`QiangzhiJwxtParser.java:49`）+ 每一跳的
/// `Jsoup.connect(...).cookies(map).header(...)` 链式调用。
///
/// ## 与原版一一对应的行为
///
/// - **HTTP→HTTPS 强制提升**：原版所有 URL 都过 `getSecureBaseUrl()`
///   （`QiangzhiJwxtParser.java:98`），把 `http://` 前缀替换成 `https://`
///   （`QiangzhiJwxtParser.java:76-82`）。
/// - **超时 30s**：原版**没有**任何 `.timeout(...)`，依赖 jsoup 默认（连接 30s / 读取 30s）。
///   iOS 端必须显式设置才能复刻（recon doc §1.1 与 §11 第 1 条明确要求显式 30s）。
/// - **User-Agent**：逐字 `"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"`，
///   原版只在「成功收尾跳」与「抓课表跳」设置（`login$2.java:251-257`、`fetchTimetable$2.java:96-98`）。
///   recon doc §1.2 的建议是**全部请求都设这个 UA**（更保守、差异更小），本实现采用全量设置。
/// - **Referer**：登录 POST 用 `{base}/`（`login$2.java:199`）；选课入口网关用
///   `{base}/jsxsd/framework/xsrkxz.htmlx`（`QiangzhiJwxtParser.java:118-120`）；成功收尾与
///   抓课表都用 `timetableReferer ?? {base}/jsxsd/framework/xsMainV.htmlx`
///   （`login$2.java:247-257`、`fetchTimetable$2.java:80-84`）。
/// - **ignoreHttpErrors(true)**：原版**每一处** `Jsoup.connect` 都带这个开关，4xx/5xx 不抛异常。
///   本实现在 `JwxtHTTPSession` 层不做状态码校验，把状态码原样交给调用方判断。
/// - **不使用 `HTTPCookieStorage`**：原版 jsoup 的 `Connection` 对象不复用，Cookie 全靠**显式**
///   `.cookies(map)` 传递，并逐跳 `putAll(response.cookies())` 累积
///   （`login$2.java:206-209`、`:257`）。因此这里也自建 `JwxtCookieJar`，通过每条请求的
///   `Cookie` 头逐条携带 —— 而不是依赖 URLSession 的共享 Cookie 存储，行为因此完全可控、可测。
///
/// ## 与原生实现刻意不同的两处（已在注释中说明理由，不是「自由发挥」）
///
/// 1. **字符集**：原版不做任何解码控制，交给 jsoup 按 `Content-Type: charset` → `<meta>` 探测
///    （recon doc §1.5、§11 第 2 条）。URLSession **不会**自动探测 `<meta charset>`，所以这里
///    按 recon doc 的建议做「`Content-Type` charset → UTF-8 → GBK」回落。GBK 用
///    `CFStringConvertEncodingToNSStringEncoding` 取，它是 Foundation/CoreFoundation 自带能力，
///    不引入依赖。
/// 2. **重定向**：原版靠 jsoup 自动跟随（并**保留沿途下发的 Cookie**），再用 `execute.url()`
///    取最终 URL；过期判断写的是 `statusCode() == 302`（`fetchTimetable$2.java:104`）。
///    iOS 这边改由 `send` **自己逐跳跟随**：每一跳先并 `Set-Cookie`、再决定要不要跟，
///    与 jsoup 的语义一致。为此必须用 `JwxtRedirectBlockingDelegate` 把 `URLSession`
///    **自己**的自动跟随关掉 —— 否则那一跳的响应（连同 `Set-Cookie`）我们根本看不到，
///    会话交接会静默断掉（真机实测的「被跳回登录页」就是这么来的，见该委托的注释）。
///    过期判断仍按 recon doc §1.4 的建议走「最终 URL 或 location 含 `Login`」。
public final class JwxtSession: @unchecked Sendable {

    /// 原版硬编码的 UA（`login$2.java:251-257`、`fetchTimetable$2.java:96-98`）。
    public static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"

    /// jsoup 默认超时（recon doc §1.1：「连接 30s / 读取 30s」，原版未显式设置）。
    public static let defaultTimeout: TimeInterval = 30

    /// 教务系统根 URL（未做 HTTPS 化的原值）。
    public let baseURL: String
    /// `http://` → `https://` 之后的基址（等价 `getSecureBaseUrl()`）。
    public let secureBaseURL: String

    private let jar: JwxtCookieJar
    private let configuration: URLSessionConfiguration
    private let urlSession: URLSession

    /// 阻止 `URLSession` **自己**跟掉重定向的委托。
    ///
    /// ⚠️ 没有它，本类那句「重定向由本方法自己处理」就是**假的** —— `URLSession` 会把 302 跟掉，
    /// 我们只能看到最后一跳的响应，**重定向那一跳的 `Set-Cookie` 结构性拿不到**。
    /// 详见 `JwxtRedirectBlockingDelegate` 的注释与文件头第 2 点。
    private let redirectBlocker = JwxtRedirectBlockingDelegate()

    /// 选课入口页 URL。命中选课网关后，它会成为后续请求的 Referer
    /// （`QiangzhiJwxtParser.java:123` 的 `this.timetableReferer = str3`）。
    private let refererBox: JwxtBox<String?>

    /// 建会话。
    ///
    /// - Parameter configuration: 测试用 `URLProtocol` 桩时传一个装了
    ///   `protocolClasses` 的配置；生产环境传 `nil` 会用 `.default` 并设 30s 超时。
    ///
    /// ⚠️ `configuration` 会被**拷贝**一份（`URLSessionConfiguration` 是引用语义的类），
    /// 避免外部后续修改影响本会话。
    public init(baseURL: String, configuration: URLSessionConfiguration? = nil) {
        let config = (configuration?.copy() as? URLSessionConfiguration) ?? URLSessionConfiguration.default
        config.timeoutIntervalForRequest = JwxtSession.defaultTimeout
        config.timeoutIntervalForResource = JwxtSession.defaultTimeout
        // 与 Android 端一致：Cookie 由我们自己显式携带，不让系统 Cookie 存储介入。
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        self.baseURL = baseURL
        self.secureBaseURL = JwxtSession.secureURLString(fromBase: baseURL)
        self.configuration = config
        self.urlSession = URLSession(configuration: config)
        self.jar = JwxtCookieJar()
        self.refererBox = JwxtBox(nil)
    }

    // MARK: - HTTPS 提升

    /// 等价 `getSecureBaseUrl()`：仅当以 `http://` 开头时替换为 `https://`。
    ///
    /// 逐字对应 `QiangzhiJwxtParser.java:76-82`。
    public static func secureURLString(fromBase base: String) -> String {
        if base.hasPrefix("http://") {
            return base.replacingOccurrences(of: "http://", with: "https://")
        }
        return base
    }

    /// 拼接绝对 URL：`getSecureBaseUrl() + path`。
    public func url(_ path: String) -> URL? {
        URL(string: secureBaseURL + path)
    }

    // MARK: - 会话状态

    /// 当前累积的 Cookie（等价原版实例字段 `cookies`）。
    public var cookies: [String: String] { jar.snapshot() }

    /// 当前选课入口 Referer（等价原版 `timetableReferer`）。
    public var timetableReferer: String? { refererBox.value }

    /// 手动合并 Cookie（等价 `mutableMap.putAll(response.cookies())`）。
    public func mergeCookies(_ incoming: [String: String]) {
        jar.merge(incoming)
    }

    /// 手动设置选课入口 Referer（等价 `this.timetableReferer = str3`）。
    public func setTimetableReferer(_ value: String?) {
        refererBox.value = value
    }

    // MARK: - 通用请求

    /// 一次请求的构造参数：与原版链式调用的开关一一对应。
    public struct RequestOptions: Sendable {
        public var method: String
        /// 表单体。原版 `.data("k","v")` 会做 URL 编码并自动设
        /// `Content-Type: application/x-www-form-urlencoded`（`login$2.java:244-247`）。
        public var form: [(String, String)]
        /// 额外请求头（`Referer` / `User-Agent` 等）。
        public var headers: [String: String]
        /// 是否附带当前 Cookie（原版 `.cookies(map)`；首页跳也有，见 `login$2.java:145`）。
        public var carriesCookies: Bool
        public var body: Data?
        public var contentType: String?

        public init(
            method: String = "GET",
            form: [(String, String)] = [],
            headers: [String: String] = [:],
            carriesCookies: Bool = true,
            body: Data? = nil,
            contentType: String? = nil
        ) {
            self.method = method
            self.form = form
            self.headers = headers
            self.carriesCookies = carriesCookies
            self.body = body
            self.contentType = contentType
        }

        /// 登录 POST 用：`application/x-www-form-urlencoded`。
        public static let formURLEncoded = "application/x-www-form-urlencoded"
    }

    /// 一次请求的结果。
    public struct Response: Sendable {
        public let statusCode: Int
        /// 跟随重定向之后的**最终** URL（等价 `execute.url().toString()`，`login$2.java:218`）。
        public let finalURL: URL?
        /// 原始 `Location` 响应头（未跟随重定向时才有值；原版读法见 `fetchTimetable$2.java:100`）。
        public let locationHeader: String?
        public let body: String
        public let rawBody: Data
        /// 本次响应带来的 Cookie（等价 `execute.cookies()`）。
        public let cookies: [String: String]
        public let headers: [String: String]
    }

    /// 发出一次请求，并按原版语义累积 Cookie。
    ///
    /// 重定向由本方法自己处理：每一跳的 `Set-Cookie` 都会先并进罐子，再带着它去下一跳
    /// （`URLSession` 的自动跟随由 `redirectBlocker` 关掉），原因见文件头第 2 点。
    public func send(_ urlString: String, options: RequestOptions = RequestOptions()) async throws -> Response {
        guard let startURL = URL(string: urlString), let scheme = startURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw JwxtSessionError.invalidURL(urlString)
        }

        var currentURL = startURL
        var method = options.method.uppercased()
        var body = options.body
        var contentType = options.contentType
        var pendingForm = options.form
        var extraHeaders = options.headers
        let maxHops = 10

        for hop in 0...maxHops {
            var request = URLRequest(url: currentURL)
            request.httpMethod = method
            request.timeoutInterval = JwxtSession.defaultTimeout
            for (key, value) in extraHeaders {
                request.setValue(value, forHTTPHeaderField: key)
            }
            if let contentType {
                request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            }
            if !pendingForm.isEmpty {
                request.setValue(JwxtSession.RequestOptions.formURLEncoded, forHTTPHeaderField: "Content-Type")
                body = JwxtSession.formEncodedBody(pendingForm)
                pendingForm = []
            }
            request.httpBody = body

            // recon §1.2 明确要求**所有请求**都带这个桌面 UA，原版靠的是 jsoup 的默认 UA
            // —— jsoup 自 1.10.2 起「Connect now uses a desktop user agent by default」
            // （release notes 原文），所以 Android 那几跳实际发的也是桌面浏览器 UA。
            //
            // 不能让 URLSession 用它自己的默认 UA：那是
            // `<App 名字>/<版本> CFNetwork/<版本> Darwin/<版本>`，服务端会把请求认成
            // 非浏览器客户端。真机实测（2026-10-19）：**同一账号、同一密码**，
            // 手机 Safari 能正常登录进入系统内部页面，App 却报
            // 「登录教务系统失败…（诊断：被跳回登录页（验活页 title=登录））」，
            // 而逐跳比对下来，与 Android 唯一的**系统性**差异就是这几跳的 UA
            // （Referer / Content-Type / Cookie 携带方式都已逐条对齐）。
            //
            // 调用方显式传了 User-Agent 的（收尾跳、网关跳、抓课表跳）保持原样 —— 那几处
            // 本来就逐字对齐原版，值也是同一个常量。
            if extraHeaders["User-Agent"] == nil {
                request.setValue(JwxtSession.userAgent, forHTTPHeaderField: "User-Agent")
            }

            if options.carriesCookies, let cookieHeader = jar.cookieHeader(), !cookieHeader.isEmpty {
                request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            }

            // ⚠️ 必须传 `delegate:` —— 否则 `URLSession` 会**自己**把 302 跟掉，
            // 我们就只能看到最后一跳的响应，**重定向那一跳的 `Set-Cookie` 会永久丢失**
            // （`httpShouldSetCookies = false` + `httpCookieStorage = nil` 也意味着
            // URLSession 不会替我们把那个 Cookie 带到下一跳）。这正是真机上
            // 「门户登录过了、jsxsd 会话却建立不起来」的原因。
            let (data, urlResponse) = try await urlSession.data(for: request, delegate: redirectBlocker)
            guard let http = urlResponse as? HTTPURLResponse else {
                throw JwxtSessionError.notHTTPResponse
            }

            let responseCookies = JwxtSession.cookies(from: http)
            // 先并 Cookie，**再**决定要不要跟 —— 这样重定向那一跳下发的会话 Cookie
            // 会跟着下一次循环的 `Cookie` 头一起发出去，与 jsoup / 浏览器的行为一致。
            jar.merge(responseCookies)

            let location = http.value(forHTTPHeaderField: "Location")
            let redirecting = (300...399).contains(http.statusCode) && location != nil

            if redirecting, hop < maxHops,
               let next = JwxtSession.resolveLocation(location, relativeTo: currentURL) {
                if http.statusCode == 303 || ((http.statusCode == 301 || http.statusCode == 302) && method == "POST") {
                    // recon doc §1.4 的不确定项：jsoup 是否跟随 POST 的 302 未知，且 302→GET
                    // 是浏览器（也是 URLSession）的普遍行为。这里采用浏览器行为。
                    method = "GET"
                    body = nil
                    contentType = nil
                    extraHeaders.removeValue(forKey: "Content-Type")
                }
                currentURL = next
                continue
            }

            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                headers[String(describing: key)] = String(describing: value)
            }

            return Response(
                statusCode: http.statusCode,
                finalURL: http.url ?? currentURL,
                locationHeader: location,
                body: JwxtSession.decodeBody(data, response: http),
                rawBody: data,
                cookies: responseCookies,
                headers: headers
            )
        }

        throw JwxtSessionError.tooManyRedirects(startURL.absoluteString)
    }

    // MARK: - 编码

    /// 表单编码（等价 jsoup `.data(k, v)` 的行为）。
    ///
    /// jsoup 用 `URLEncoder.encode(value, "UTF-8")`，其语义是
    /// **空格 → `+`**、其余按 UTF-8 百分号编码。`URLComponents` 会用 `%20`，与 jsoup 不同，
    /// 所以这里手写，避免与服务端行为产生偏差。
    static func formEncodedBody(_ pairs: [(String, String)]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.*")
        let joined = pairs.map { key, value in
            "\(formEncode(key, allowed: allowed))=\(formEncode(value, allowed: allowed))"
        }.joined(separator: "&")
        return Data(joined.utf8)
    }

    private static func formEncode(_ value: String, allowed: CharacterSet) -> String {
        var out = ""
        for scalar in value.unicodeScalars {
            if scalar == " " {
                out.append("+")
            } else if allowed.contains(scalar) {
                out.unicodeScalars.append(scalar)
            } else {
                for byte in String(scalar).utf8 {
                    out += String(format: "%%%02X", byte)
                }
            }
        }
        return out
    }

    /// 响应体解码：`Content-Type` charset → UTF-8 → GBK。
    ///
    /// recon doc §1.5 说明原版不做这件事（依赖 jsoup 的探测），并**建议** iOS 端这样回落。
    static func decodeBody(_ data: Data, response: HTTPURLResponse) -> String {
        if let contentType = response.value(forHTTPHeaderField: "Content-Type"),
           let charsetRange = contentType.range(of: "charset=", options: [.caseInsensitive]) {
            let raw = contentType[charsetRange.upperBound...]
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t\"';"))
                .lowercased()
            if let encoding = stringEncoding(named: raw),
               let text = String(data: data, encoding: encoding) {
                return text
            }
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        if let encoding = stringEncoding(named: "gbk"), let text = String(data: data, encoding: encoding) {
            return text
        }
        return ""
    }

    /// charset 名 → `String.Encoding`。
    ///
    /// GBK/GB18030 在 Foundation 里没有 `String.Encoding` 常量，必须经 CoreFoundation 转换
    /// （`CFStringConvertEncodingToNSStringEncoding` 是 Foundation 自带 API，不引入依赖）。
    static func stringEncoding(named name: String) -> String.Encoding? {
        switch name {
        case "utf-8", "utf8": return .utf8
        case "iso-8859-1", "latin1", "latin-1": return .isoLatin1
        case "us-ascii", "ascii": return .ascii
        case "utf-16", "utf16": return .utf16
        case "utf-16le", "utf16le": return .utf16LittleEndian
        case "utf-16be", "utf16be": return .utf16BigEndian
        case "gb2312", "gbk", "gb18030", "x-gbk":
            let cf = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
            return String.Encoding(rawValue: cf)
        case "big5":
            let cf = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue))
            return String.Encoding(rawValue: cf)
        default:
            return nil
        }
    }

    // MARK: - Cookie 工具

    /// 从 `HTTPURLResponse` 里取出 Set-Cookie（等价 jsoup `execute().cookies()`）。
    ///
    /// 逐个 `Set-Cookie` 头解析，只保留 `name=value`，与原版 `Map<String,String>` 语义一致
    /// （一个名字对应一个值；同名后者覆盖前者）。
    static func cookies(from response: HTTPURLResponse) -> [String: String] {
        var out: [String: String] = [:]
        let headers = response.allHeaderFields
        for (key, value) in headers {
            guard String(describing: key).lowercased() == "set-cookie" else { continue }
            for piece in splitSetCookieHeader(String(describing: value)) {
                guard let pair = firstCookiePair(in: piece) else { continue }
                out[pair.0] = pair.1
            }
        }
        return out
    }

    /// 一个 Set-Cookie 头里可能塞了多个 cookie（用 `, ` 分隔），但 `Expires=Wed, 21 Oct...`
    /// 里的逗号不能当分隔符，所以按「逗号后紧跟 `name=`」的形状切。
    static func splitSetCookieHeader(_ raw: String) -> [String] {
        var pieces: [String] = []
        var current = ""
        var index = raw.startIndex
        while index < raw.endIndex {
            let ch = raw[index]
            if ch == "," {
                let rest = raw[raw.index(after: index)...]
                let trimmed = rest.drop { $0 == " " }
                if let equals = trimmed.firstIndex(of: "=") {
                    let name = trimmed[trimmed.startIndex..<equals]
                    let semicolon = trimmed.firstIndex(of: ";") ?? trimmed.endIndex
                    // 名称里不能有空格；`Expires` 的 `21 Oct 2015` 会在空格处失败，从而被正确拼回。
                    if !name.isEmpty, !name.contains(" "), equals < semicolon {
                        pieces.append(current)
                        current = ""
                        index = raw.index(after: index)
                        continue
                    }
                }
            }
            current.append(ch)
            index = raw.index(after: index)
        }
        pieces.append(current)
        return pieces.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// 取片段里第一个 `name=value`。
    static func firstCookiePair(in piece: String) -> (String, String)? {
        let firstSegment = piece.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        guard let equals = firstSegment.firstIndex(of: "=") else { return nil }
        let name = String(firstSegment[firstSegment.startIndex..<equals]).trimmingCharacters(in: .whitespaces)
        let value = String(firstSegment[firstSegment.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        return (name, value)
    }

    static func resolveLocation(_ location: String?, relativeTo base: URL) -> URL? {
        guard let location, !location.isEmpty else { return nil }
        return URL(string: location, relativeTo: base)?.absoluteURL
    }
}

/// 会话层错误。
public enum JwxtSessionError: Error, LocalizedError, Equatable, Sendable {
    case invalidURL(String)
    case notHTTPResponse
    case tooManyRedirects(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidURL(value):
            return "无效的教务系统地址：\(value)"
        case .notHTTPResponse:
            return "教务系统返回了非 HTTP 响应"
        case let .tooManyRedirects(value):
            return "重定向次数过多：\(value)"
        }
    }
}

/// Cookie 罐子。
///
/// Android 端是 `MutableMap`，单线程。iOS 端网络回调可能在任意线程，
/// 所以这里用 `NSLock` 保护（`NSLock` 来自 Foundation，无额外依赖）。
public final class JwxtCookieJar: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    public init(_ initial: [String: String] = [:]) {
        self.storage = initial
    }

    /// 合并（等价 `map.putAll(other)`）。
    public func merge(_ incoming: [String: String]) {
        guard !incoming.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        for (key, value) in incoming { storage[key] = value }
    }

    /// 当前快照。
    public func snapshot() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    /// 输出 `Cookie` 请求头的值（插入顺序与字典一致即可，服务端不关心顺序）。
    public func cookieHeader() -> String? {
        let snapshot = self.snapshot()
        guard !snapshot.isEmpty else { return nil }
        return snapshot.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "; ")
    }

    /// Cookie 字典 → jsoup 风格的 `Map<String,String>` 解析（给测试与复用）。
    public static func dictionary(fromCookieHeader header: String) -> [String: String] {
        var out: [String: String] = [:]
        for piece in header.split(separator: ";") {
            let text = piece.trimmingCharacters(in: .whitespaces)
            guard let equals = text.firstIndex(of: "=") else { continue }
            let name = String(text[text.startIndex..<equals])
            let value = String(text[text.index(after: equals)...])
            if !name.isEmpty { out[name] = value }
        }
        return out
    }
}

/// 极简可变盒子（给 `JwxtSession.timetableReferer` 用，避免把整个类做成 actor）。
final class JwxtBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { self.storage = value }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            storage = newValue
        }
    }
}

/// 阻止 `URLSession` **自己**跟随重定向的委托（返回 `nil` = 不跟）。
///
/// ## 为什么必须有它（真机证据，2026-10-19）
///
/// 本会话层的 Cookie 是**自己管**的：`httpShouldSetCookies = false`、`httpCookieStorage = nil`、
/// `httpCookieAcceptPolicy = .never` —— 逐跳的 `Set-Cookie` 全靠 `JwxtSession.send` 的循环
/// 「读出来 → 并进罐子 → 带进下一跳」。**但这只有在 `URLSession` 不自己跟重定向时才成立**：
/// 一旦它把 302 跟掉，我们拿到的是**最后一跳**的响应，那一跳（302）的响应头连同它的
/// `Set-Cookie` 就**结构性拿不到**了；而 URLSession 自己的 Cookie 机制又被我们关掉了，
/// 于是那个 Cookie 两边都没接住 —— **直接丢失**。
///
/// 后果（真机「登录教务系统失败…被跳回登录页」的逐跳轨迹）：
/// `POST /Logon.do?method=logon` 之后 `final` 已经落在 `/jsxsd/framework/xsrkxz.htmlx`
/// （说明门户那一关过了），可我们手里只有**那张登录页**发来的 `bzb_jsxsd`（匿名会话），
/// 服务端在重定向里写给 jsxsd 的会话 Cookie 丢了；此后所有 jsxsd 路径都返回
/// 同一张 18942 字节的登录页 ⇒ 判成 `titleRejected`。
///
/// 对照：Android 的 jsoup 自动跟随重定向时**会保留并带上沿途下发的 Cookie**，所以安卓是通的。
///
/// ⚠️ 这里是**实现与注释不一致**的第二处（第一处是 UA 的全量设置）：本类原先的
/// `send` 注释写着「`URLSession` 的自动跟随被关掉」，但全工程从来没有实现过任何
/// `URLSessionTaskDelegate` —— 那句话一直只是「意图」。现在把它兑现。
///
/// ⚠️ 用 `URLSessionTaskDelegate` 的**经典 completionHandler 形式**（不是 async 形式）：
/// 它是 Foundation 里真正声明的那条 ObjC 协议方法，`data(for:delegate:)` 一定会调到它。
final class JwxtRedirectBlockingDelegate: NSObject, URLSessionTaskDelegate {

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // 交回 nil：不跟随。重定向由 `JwxtSession.send` 的逐跳循环处理，
        // 那一跳的 `Set-Cookie` 因此能被抓住并带走。
        completionHandler(nil)
    }
}
