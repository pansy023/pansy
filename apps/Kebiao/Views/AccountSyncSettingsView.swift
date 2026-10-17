import SwiftUI
import UIKit
import KebiaoCore

/// 「账号与同步」二级页（设置首页 → `NavigationLink`）。
///
/// 排版与文案逐条对齐 Android 1.11.5 `SettingsScreenKt.java` 的 `ACCOUNT_SYNC`
/// 分页（也就是用户给的图一）：
/// - 组名「账号与教务系统」`:1228`；三行值行「教务系统 URL」「用户名」「密码」
///   `:1426` 前后；密码行下的小字 `:1429`（逐字照抄）；
/// - 开关行「定时同步教务课表」`:1455`；其下小字 `:1456`（逐字照抄）；
/// - 按钮「测试课表自动同步通知」与「保存设置」。
///
/// 账号三项走**草稿态**，点「保存设置」才落盘（原版同样是 pending + 保存，
/// `SettingsScreenKt.java:4675-4676`：保存时才 `saveCredentials` + `updateSettings`）。
/// 密码只写进 iOS 钥匙串（`CredentialStore`），不明文落盘。
///
/// 有意差异（保留在页面上并写在注释里）：本页额外多一个「刷新课表」按钮。
/// 安卓端的手动刷新入口在**课表页**（`TimetableScreenKt.java` 里 4 处），
/// 设置页没有；但 iOS 的后台定时同步受系统限制（`BGAppRefreshTask` 且不保证触发时刻），
/// 若不留手动入口，用户将无法把教务系统的课表拉下来。
struct AccountSyncSettingsView: View {

    @EnvironmentObject private var environment: AppEnvironment

    private var store: TimetableStore { environment.store }
    private var settings: AppSettings { store.settings }

    // MARK: - 草稿与临时状态

    /// 账号与同步的草稿：只有点「保存设置」才写进 `TimetableStore`
    /// （密码进 Keychain，`username` / `jwxtUrl` 进 UserDefaults，见 `CredentialStore`）。
    @State private var draftJwxtUrl = ""
    @State private var draftUsername = ""
    @State private var draftPassword = ""
    @State private var draftAutoSync = false
    @State private var didLoadAccountDraft = false

    /// 「刷新课表」的进行中状态与最近一次结果文案。
    ///
    /// 文案逐字取自原版手动刷新流程 `TimetableViewModel$refreshTimetable$1.java`：
    /// 未配置账号 `:102`、异常 `:84`、抓不到 `:147`；成功文案取自动同步通知
    /// `TimetableAutoRefreshNotifier.java:81`（「已从教务系统覆盖本地课表，共 N 门课程。」）。
    @State private var isSyncingTimetable = false
    @State private var syncStatusText = ""

    /// 一条一次性提示（保存成功 / 通知被拒）。
    @State private var notice: Notice?

    private struct Notice: Identifiable {
        let id = UUID()
        let text: String
    }

    var body: some View {
        Form {
            accountSection
            autoSyncSection
            actionSection
        }
        .navigationTitle("账号与同步")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadAccountDraftIfNeeded)
        .alert(item: $notice) { item in
            Alert(title: Text("提示"), message: Text(item.text), dismissButton: .default(Text("好")))
        }
    }

    // MARK: - ① 账号与教务系统

    private var accountSection: some View {
        Section {
            labelTextField(
                "教务系统 URL",
                text: $draftJwxtUrl,
                identifier: "account.field.url",
                keyboard: .URL
            )
            labelTextField("用户名", text: $draftUsername, identifier: "account.field.username")
            labelSecureField("密码", text: $draftPassword, identifier: "account.field.password")
        } header: {
            Text("账号与教务系统")
        } footer: {
            Text(
                // 小字逐字取自 `SettingsScreenKt.java:1429`。
                "此密码为学校抢课网站密码，非查课系统密码；"
                + "若一直提示账号密码错误，请将上方教务系统 URL 复制到浏览器中尝试登录。"
                + "\n保存后密码只写进 iOS 钥匙串（Keychain），不会明文落盘。"
            )
        }
    }

    // MARK: - ② 定时同步

    private var autoSyncSection: some View {
        Section {
            Toggle("定时同步教务课表", isOn: $draftAutoSync)
                .accessibilityIdentifier("account.toggle.autoSync")
        } footer: {
            Text(
                // 小字逐字取自 `SettingsScreenKt.java:1456`。
                "开启后每天中午 1 点与凌晨 1 点自动从教务系统拉取课表并覆盖本地；"
                + "完成后在通知栏显示一条常驻消息（需通知权限）。"
                + "\n⚠️ iOS 侧「定时同步」目前只保存开关取值：iOS 的定时抓取要用"
                + " BGAppRefreshTask，且系统不保证触发时刻，无法照搬 Android 的定点后台任务。"
            )
        }
    }

    // MARK: - ③ 三个按钮

    private var actionSection: some View {
        Section {
            Button {
                Task { await syncTimetable() }
            } label: {
                HStack(spacing: 8) {
                    Text("刷新课表")
                    Spacer(minLength: 8)
                    if isSyncingTimetable {
                        ProgressView()
                    }
                }
            }
            .disabled(isSyncingTimetable)
            .accessibilityIdentifier("account.button.refresh")

            if !syncStatusText.isEmpty {
                Text(syncStatusText)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("account.status.sync")
            }

            Button("测试课表自动同步通知") {
                Task { await sendTestNotification() }
            }
            .accessibilityIdentifier("account.button.testNotification")

            Button("保存设置") {
                saveAccountSettings()
            }
            .accessibilityIdentifier("account.button.save")
        } footer: {
            Text(
                "「刷新课表」用本页已保存的 URL、用户名、密码登录教务系统并抓取课表，"
                + "抓到的课表整体覆盖本地（抓不到时不清空已有课表）。"
                + "安卓端这个入口在课表页上、不在设置里；iOS 因为后台定时同步受系统限制，"
                + "必须保留这个手动入口，否则课表无法更新。"
            )
        }
    }

    // MARK: - 行为

    /// 执行一次同步。所有状态变化都发生在主线程（`Task` 继承 SwiftUI 的 MainActor）。
    @MainActor
    private func syncTimetable() async {
        // 先把草稿落地：用户很可能刚改完账号就直接点同步。
        persistAccountDraft()

        let credentials = store.credentials
        guard !credentials.username.isEmpty, !credentials.password.isEmpty else {
            syncStatusText = "请先在设置中配置教务系统账号"
            notice = Notice(text: syncStatusText)
            return
        }

        isSyncingTimetable = true
        syncStatusText = "正在登录教务系统并抓取课表…"
        defer { isSyncingTimetable = false }

        do {
            let courses = try await JwxtTimetableSync().fetchFromJwxt(credentials: credentials)
            if courses.isEmpty {
                syncStatusText = "未获取到课表数据"
                notice = Notice(text: "未获取到课表数据；已保留本地原有课程。")
            } else {
                store.replaceAllCourses(with: courses)
                syncStatusText = "已从教务系统覆盖本地课表，共 \(courses.count) 门课程。"
                notice = Notice(text: syncStatusText)
            }
        } catch {
            syncStatusText = "刷新失败: \(error.localizedDescription)"
            notice = Notice(text: syncStatusText)
        }
    }

    /// 把账号与同步草稿落地（原版也是 pending 态，点保存才写；`SettingsScreenKt.java:4675-4676`）。
    ///
    /// 拆出来是因为「刷新课表」也要先落地草稿才能用上用户刚改的账号。
    private func persistAccountDraft() {
        let jwxtUrl = draftJwxtUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        store.saveCredentials(
            UserCredentials(
                id: store.credentials.id,
                username: draftUsername.trimmingCharacters(in: .whitespacesAndNewlines),
                password: draftPassword,
                jwxtUrl: jwxtUrl.isEmpty ? UserCredentials.defaultJwxtUrl : jwxtUrl
            )
        )
        store.mutateSettings { $0.autoSyncTimetableFromJwxt = draftAutoSync }
    }

    private func saveAccountSettings() {
        persistAccountDraft()
        notice = Notice(text: "设置已保存")
    }

    private func sendTestNotification() async {
        let ok = await LocalNotificationTester.sendTestAutoSyncNotification()
        if !ok {
            // 原版同一句提示：`SettingsScreenKt.java:1475`。
            notice = Notice(text: "无法测试：请先在系统设置中允许本应用发送通知")
        }
    }

    /// 首次出现时把已存的凭证灌进草稿；之后不再覆盖，避免打字打到一半被读盘冲掉。
    private func loadAccountDraftIfNeeded() {
        guard !didLoadAccountDraft else { return }
        didLoadAccountDraft = true
        let credentials = store.credentials
        draftJwxtUrl = credentials.jwxtUrl
        draftUsername = credentials.username
        draftPassword = credentials.password
        draftAutoSync = settings.autoSyncTimetableFromJwxt
    }

    // MARK: - 行控件

    /// 一行「标签 + 文本输入框（右对齐）」，对齐原版 `SettingValueRow` 的排版。
    private func labelTextField(
        _ title: String,
        text: Binding<String>,
        identifier: String,
        keyboard: UIKeyboardType = .default
    ) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 12)
            TextField("", text: text)
                .multilineTextAlignment(.trailing)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel(title)
                .accessibilityIdentifier(identifier)
        }
    }

    /// 一行「标签 + 安全输入框」（密码只进 Keychain）。
    private func labelSecureField(
        _ title: String,
        text: Binding<String>,
        identifier: String
    ) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 12)
            SecureField("", text: text)
                .multilineTextAlignment(.trailing)
                .accessibilityLabel(title)
                .accessibilityIdentifier(identifier)
        }
    }
}

#if DEBUG
struct AccountSyncSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            AccountSyncSettingsView()
        }
        .environmentObject(
            AppEnvironment(store: TimetableStore(repository: InMemoryTimetableRepository()))
        )
    }
}
#endif
