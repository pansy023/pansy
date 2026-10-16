import Foundation

/// 与 Android 端 `kebiaocom.example.data.UserCredentials` 一一对应。
///
/// 证据：`上课早枝道-源码-1.11.5/app/src/main/kotlin/kebiaocom/example/data/UserCredentials.kt:3-14`
///
/// ⚠️ **安全要求（m03200 第七节）**：原版把用户名/密码经 SharedPreferences 持久化。
/// iOS 端**不得**沿用明文方案：`password` 必须存进 Keychain（`kSecClassGenericPassword`），
/// 只有非敏感的 `username` / `jwxtUrl` 允许进 UserDefaults。
/// 本类型只是内存中的传输对象；落盘策略见 `KebiaoCore/Storage/CredentialStore`（待实现）。
///
/// ⚠️ 待确认：Android 端密码是否明文存储，由 `docs/recon/storage.md` 给出证据后
/// 再决定是否需要写一次「明文 → Keychain」的迁移。
public struct UserCredentials: Codable, Equatable, Sendable {
    public var id: Int
    public var username: String
    /// 仅存在于内存/Keychain，不参与 UserDefaults 序列化。
    public var password: String
    /// 强智教务系统地址。
    public var jwxtUrl: String

    public init(
        id: Int = 1,
        username: String,
        password: String,
        jwxtUrl: String = UserCredentials.defaultJwxtUrl
    ) {
        self.id = id
        self.username = username
        self.password = password
        self.jwxtUrl = jwxtUrl
    }

    /// 与原版 `UserCredentials.DEFAULT_JWXT_URL` 常量一致。
    public static let defaultJwxtUrl = "https://jwgl.xihang.com.cn"
}
