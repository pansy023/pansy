import Foundation

#if canImport(Security)
import Security
#endif

// MARK: - 协议

/// 密码的去处。**只有**密码走这里；用户名 / 教务地址是普通偏好，走 `UserDefaults`。
///
/// 为什么单独抽一个协议：`CredentialStore` 是 `TimetableRepository` 的注入依赖，
/// 测试里换成内存实现就能在 Linux / CI 上跑完整个存储层（钥匙串在非 Apple 平台不存在）；
/// 同时把「钥匙串」这个细节从存储层隔离出去，将来要换 App Group 共享钥匙串
/// 或加生物识别保护也不必改 `TimetableRepository`。
///
/// - Important: 实现必须是引用类型（`AnyObject`），这样注入的实例是共享的，
///   `saveCredentials` 写进去的密码能立刻被同一实例读回来。
public protocol CredentialStore: AnyObject {
    /// 取密码。**没有存过**返回 `nil`（不是错误）。
    func loadPassword() throws -> String?
    /// 存/改密码。
    func savePassword(_ password: String) throws
    /// 删密码。**本来就没有**时也算成功（幂等），不抛 `errSecItemNotFound`。
    func deletePassword() throws
}

// MARK: - Apple 平台：钥匙串实现

#if canImport(Security)

/// 用系统钥匙串存教务密码。
///
/// 这是规格 **m03200 第七节**「不得明文存密码 / Cookie，敏感凭证用 Keychain」的落地：
/// Android 端把密码明文写进 `timetable_prefs`（`LocalStorage.java:41`，证据见
/// `docs/recon/storage.md` §4.2），iOS 端**不得**沿用；本类型是密码唯一的落盘出口，
/// `UserDefaultsTimetableRepository` 永远不会把密码写进偏好。
///
/// ## 条目形态
///
/// `kSecClassGenericPassword`（通用密码项），service 用固定常量
/// `com.kebiaocom.kebiao.credentials`，account 固定 `"password"`。
/// 全 App 只有一条记录，换来两个好处：
/// - `savePassword` 的语义天然是「覆盖」而不是「堆积」；
/// - 卸载 App / 用户在「密码与账户」里手动删除都很直观。
///
/// 因为 `kSecAttrAccessible` 用默认的 `kSecAttrAccessibleWhenUnlocked`
/// （只写了 class/accessibility 之外的最小查询属性，未显式指定 accessible，
/// 由系统取该类的默认值）：设备锁屏时读不出来，符合「密码不该在锁屏后被后台读走」。
/// `kSecAttrSynchronizable` 未设置 —— **不**同步到 iCloud 钥匙串，
/// 教务密码只在用户这台设备上（原版数据也从不出设备）。
///
/// ## 增 / 改 / 删
///
/// - 新增：`SecItemAdd`；
/// - 修改：先 `SecItemCopyMatching` 判断是否已存在，存在则 `SecItemUpdate`，
///   不存在才 `SecItemAdd` —— 比「先 add 失败再 update」少一次失败路径；
/// - 删除：`SecItemDelete`，`errSecItemNotFound` 视为成功（幂等）。
public final class KeychainCredentialStore: CredentialStore {

    /// 钥匙串条目的 service。App 内唯一，改名等于换一份存储。
    public static let defaultService = "com.kebiaocom.kebiao.credentials"

    /// 唯一的 account。原版只有一个教务账号，这里不引入多账号。
    public static let defaultAccount = "password"

    /// 「条目不存在」的 `OSStatus` 数值：`errSecItemNotFound`。
    ///
    /// ⚠️ 这里刻意写**数值**而不是引用 `errSecItemNotFound` 常量：
    /// 该常量在 Swift 里由 Security 模块的 overlay 提供，导入形态随工具链版本变过
    /// （曾出现过 `Int` 与 `OSStatus`（= `Int32`）对不上、必须转换才能比较的情况）。
    /// 直接写 `-25300` 在任何工具链上都能编译，且含义唯一。
    /// 数值证据：`Security/SecBase.h` 的 `errSecItemNotFound = -25300`。
    private static let itemNotFoundStatus: OSStatus = -25300

    private let service: String
    private let account: String

    /// - Parameters:
    ///   - service: 钥匙串 service，默认 `defaultService`。
    ///   - account: 钥匙串 account，默认 `"password"`。
    ///     ⚠️ 这两个值**不要**照抄 Android 的键名（`username` / `password` / `jwxtUrl`）：
    ///     它们是 iOS 自己的钥匙串命名空间，与 `UserDefaults` 的键名是两套东西，
    ///     混用只会让人误以为密码也存在偏好里。
    public init(
        service: String = KeychainCredentialStore.defaultService,
        account: String = KeychainCredentialStore.defaultAccount
    ) {
        self.service = service
        self.account = account
    }

    // MARK: 读

    /// 读密码。条目不存在返回 `nil`；其它 `OSStatus` 抛 `KeychainCredentialStoreError`。
    public func loadPassword() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == KeychainCredentialStore.itemNotFoundStatus {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainCredentialStoreError.unexpectedStatus(status, operation: "读取密码")
        }
        guard let data = result as? Data, let password = String(data: data, encoding: .utf8) else {
            return nil
        }
        return password
    }

    // MARK: 写

    /// 存 / 改密码。
    ///
    /// 空串按「删除」处理：存一个空密码与没存过在业务上等价，
    /// 留着空条目只会让 `loadPassword()` 返回 `""` 却让 `deletePassword()` 无事可做。
    public func savePassword(_ password: String) throws {
        guard !password.isEmpty else {
            try deletePassword()
            return
        }
        guard let data = password.data(using: .utf8) else {
            throw KeychainCredentialStoreError.notUTF8(operation: "保存密码")
        }

        if try itemExists() {
            let attributes: [String: Any] = [kSecValueData as String: data]
            let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
            guard status == errSecSuccess else {
                throw KeychainCredentialStoreError.unexpectedStatus(status, operation: "更新密码")
            }
            return
        }

        var query = baseQuery
        query[kSecValueData as String] = data
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainCredentialStoreError.unexpectedStatus(status, operation: "写入密码")
        }
    }

    // MARK: 删

    /// 删密码。`errSecItemNotFound` 当成功（幂等）。
    public func deletePassword() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        if status == errSecSuccess || status == KeychainCredentialStore.itemNotFoundStatus {
            return
        }
        throw KeychainCredentialStoreError.unexpectedStatus(status, operation: "删除密码")
    }

    // MARK: 私有

    /// 所有操作共用的定位条件：类 + service + account。
    private var baseQuery: [String: Any] {
        var query: [String: Any] = [:]
        query[kSecClass as String] = kSecClassGenericPassword
        query[kSecAttrService as String] = service
        query[kSecAttrAccount as String] = account
        return query
    }

    /// 条目是否已存在（只看有没有，不取内容）。
    private func itemExists() throws -> Bool {
        var query = baseQuery
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess { return true }
        if status == KeychainCredentialStore.itemNotFoundStatus { return false }
        throw KeychainCredentialStoreError.unexpectedStatus(status, operation: "查询密码条目")
    }
}

// MARK: - 错误

/// 钥匙串操作失败。携带原始 `OSStatus`，便于对照
/// `Security/SecBase.h` 里的常量名定位原因
/// （常见：`errSecMissingEntitlement`（-34018，缺 keychain-access-groups 能力）、
/// `errSecInteractionNotAllowed`（-25308，设备锁定中））。
public enum KeychainCredentialStoreError: Error, LocalizedError, Equatable {
    /// `Security` 返回了非 `errSecSuccess` 的状态码。
    case unexpectedStatus(OSStatus, operation: String)
    /// 待写入的字符串不是合法 UTF-8（理论上不会发生）。
    case notUTF8(operation: String)

    public var errorDescription: String? {
        switch self {
        case let .unexpectedStatus(status, operation):
            return "钥匙串\(operation)失败（OSStatus \(status)）"
        case let .notUTF8(operation):
            return "钥匙串\(operation)失败（字符串不是合法 UTF-8）"
        }
    }
}

// MARK: - 非 Apple 平台：降级实现

#else

/// 没有钥匙串的平台（Linux / Windows / CI）上的降级实现：**每次操作都抛出明确错误**。
///
/// 为什么不做「退化成文件存储」之类的降级：那等于把密码明文写到磁盘上，
/// 恰恰是规格 m03200 第七节禁止的事。这里宁可让调用方拿到一个清楚的错误
/// （`KeychainCredentialStoreError.platformUnavailable`），
/// 也不能让 `KebiaoCore` 在非 Apple 平台上悄悄变得不安全。
///
/// 这也让 `KebiaoCore` 在非 Apple 平台上**仍能编译通过**：`#if canImport(Security)`
/// 在 Linux 上落到这一支，`TimetableRepository` 的默认参数
/// `KeychainCredentialStore()` 依然存在，只是用起来会抛错。
/// 测试请注入内存版 `CredentialStore`。
public final class KeychainCredentialStore: CredentialStore {

    /// 与 Apple 分支保持同名，避免调用方写平台条件编译。
    public static let defaultService = "com.kebiaocom.kebiao.credentials"
    /// 与 Apple 分支保持同名。
    public static let defaultAccount = "password"

    public init(service: String = KeychainCredentialStore.defaultService,
                account: String = KeychainCredentialStore.defaultAccount) {
        _ = service
        _ = account
    }

    public func loadPassword() throws -> String? {
        throw KeychainCredentialStoreError.platformUnavailable
    }

    public func savePassword(_ password: String) throws {
        _ = password
        throw KeychainCredentialStoreError.platformUnavailable
    }

    public func deletePassword() throws {
        throw KeychainCredentialStoreError.platformUnavailable
    }
}

/// 非 Apple 平台上的钥匙串错误。
public enum KeychainCredentialStoreError: Error, LocalizedError, Equatable {
    /// 本平台没有钥匙串，密码无处安放。
    case platformUnavailable

    public var errorDescription: String? {
        switch self {
        case .platformUnavailable:
            return "本平台没有系统钥匙串，无法安全保存教务密码（规格 m03200 第七节禁止明文存储）"
        }
    }
}

#endif
