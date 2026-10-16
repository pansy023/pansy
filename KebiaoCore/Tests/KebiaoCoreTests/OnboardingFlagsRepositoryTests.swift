import XCTest
@testable import KebiaoCore

/// 覆盖两个「不再提示」开关的读写：`disclaimer_dont_show`（`LocalStorage.java:281-287`）
/// 与 `usage_guide_dont_show`（`LocalStorage.java:289-295`），证据见
/// `docs/recon/storage.md` §2.5 :175-176 与 §7.3 :585-586。
///
/// 为什么单独一个文件：这两个 key 在原版**不属于** `AppSettings` 的 26 个持久化字段，
/// 而是 `LocalStorage` 上独立的一对方法。把它们塞进 `AppSettings` 会让两端的 JSON 契约
/// 都对不上，所以 iOS 端也留成独立访问器。
///
/// ⚠️ 本机没有 Swift 工具链：这些用例从未编译、从未运行过，见 `README.md` §6。
final class OnboardingFlagsRepositoryTests: XCTestCase {

    private var suiteName: String!
    private var userDefaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "OnboardingFlagsRepositoryTests.\(UUID().uuidString)"
        userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        userDefaults.removePersistentDomain(forName: suiteName)
        userDefaults = nil
        suiteName = nil
        try super.tearDownWithError()
    }

    private func makeRepository() -> UserDefaultsTimetableRepository {
        UserDefaultsTimetableRepository(
            userDefaults: userDefaults,
            credentialStore: OnboardingNoopCredentialStore()
        )
    }

    func testMissingKeysDefaultToFalse() {
        let repository = makeRepository()
        // 原版两个方法都是 `getBoolean(key, false)`（storage.md §2.5）。
        XCTAssertFalse(repository.loadDisclaimerDismissedPermanently())
        XCTAssertFalse(repository.loadUsageGuideDismissedPermanently())
    }

    func testSetAndLoadRoundTripsBothFlagsIndependently() throws {
        let repository = makeRepository()

        repository.setDisclaimerDismissedPermanently(true)
        XCTAssertTrue(repository.loadDisclaimerDismissedPermanently())
        XCTAssertFalse(
            repository.loadUsageGuideDismissedPermanently(),
            "两个键必须互不影响（原版用两个独立的 key）"
        )

        repository.setUsageGuideDismissedPermanently(true)
        XCTAssertTrue(repository.loadUsageGuideDismissedPermanently())
        XCTAssertTrue(
            repository.loadDisclaimerDismissedPermanently(),
            "写第二个键不能把第一个键冲掉"
        )
    }

    func testWritesUseAndroidLiteralKeys() throws {
        let repository = makeRepository()

        repository.setDisclaimerDismissedPermanently(true)
        repository.setUsageGuideDismissedPermanently(true)

        XCTAssertEqual(
            userDefaults.object(forKey: "disclaimer_dont_show") as? Bool, true,
            "键名必须与 LocalStorage.java:286 的字面量逐字一致"
        )
        XCTAssertEqual(
            userDefaults.object(forKey: "usage_guide_dont_show") as? Bool, true,
            "键名必须与 LocalStorage.java:294 的字面量逐字一致"
        )
        // 两个 key 都在 `clearTimetableData()` 的清理范围内（storage.md §7.3）。
        XCTAssertTrue(TimetableStorageKeys.clearedKeys.contains("disclaimer_dont_show"))
        XCTAssertTrue(TimetableStorageKeys.clearedKeys.contains("usage_guide_dont_show"))
    }

    func testWritingFalseKeepsTheKeyAtFalse() throws {
        let repository = makeRepository()

        repository.setDisclaimerDismissedPermanently(true)
        repository.setDisclaimerDismissedPermanently(false)

        // 原版是 `putBoolean(key, false)`，键仍在、值为 false —— 不是删键。
        XCTAssertEqual(userDefaults.object(forKey: "disclaimer_dont_show") as? Bool, false)
        XCTAssertFalse(repository.loadDisclaimerDismissedPermanently())
    }

    func testClearResetsBothFlags() throws {
        let repository = makeRepository()
        repository.setDisclaimerDismissedPermanently(true)
        repository.setUsageGuideDismissedPermanently(true)

        try repository.clearTimetableData()

        XCTAssertFalse(
            repository.loadDisclaimerDismissedPermanently(),
            "clearAll() 会清掉这两个键（storage.md §7.3），读回来必须是出厂值 false"
        )
        XCTAssertFalse(repository.loadUsageGuideDismissedPermanently())
    }

    func testInMemoryImplementationMirrorsTheSeam() throws {
        let repository = InMemoryTimetableRepository()

        XCTAssertFalse(repository.loadDisclaimerDismissedPermanently())
        XCTAssertFalse(repository.loadUsageGuideDismissedPermanently())

        repository.setDisclaimerDismissedPermanently(true)
        repository.setUsageGuideDismissedPermanently(true)

        XCTAssertEqual(repository.saveCounts["disclaimerDontShow"], 1)
        XCTAssertEqual(repository.saveCounts["usageGuideDontShow"], 1)

        try repository.clearTimetableData()
        XCTAssertFalse(repository.loadDisclaimerDismissedPermanently())
        XCTAssertFalse(repository.loadUsageGuideDismissedPermanently())
    }
}

/// 只为满足 `UserDefaultsTimetableRepository` 的注入点，不碰真钥匙串。
private final class OnboardingNoopCredentialStore: CredentialStore {
    func loadPassword() throws -> String? { nil }
    func savePassword(_ password: String) throws {}
    func deletePassword() throws {}
}
