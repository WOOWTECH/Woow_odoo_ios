//
//  SessionIsolationBoundaryTests.swift
//  odooTests
//
//  EP-07R (iOS)：實例 session 與連線隔離的邊界重現。
//
//  minimal-remediation §7 點名三處。本檔逐一以隔離 fixture 鎖定**實際**邊界，
//  而不是沿用文件敘述 —— 實測結果與 Android 側並不相同（見 ANALYSIS.md）。
//
//  分類原則：
//  - 「既定支援範圍」＝不同 host。這裡的斷言是**真正的驗收**，失敗即產品缺陷。
//  - 「風險探測」＝同 host 多 DB／不同 port。支援範圍待 owner 決定，
//    因此採 characterisation test：斷言「目前會碰撞」為 PASS，語意是
//    **已重現並鎖定此行為**，不是「此行為正確」。owner 若決定支援，
//    把 assertEqual 改成 assertNotEqual 即為現成紅測。
//

import XCTest
@testable import odoo

final class SessionIsolationBoundaryTests: XCTestCase {

    // 兩個不同 host —— 首版既定支援範圍（每客戶一台獨立主機）
    private let hostA = "https://alpha-odoo.woowtech.invalid"
    private let hostB = "https://beta-odoo.woowtech.invalid"
    // 同 host、不同 port / 不同 DB —— 風險探測，支援待決
    private let sameHostP1 = "https://shared-odoo.woowtech.invalid"
    private let sameHostP2 = "https://shared-odoo.woowtech.invalid:8069"

    // MARK: - 缺陷 2：SecureStorage 的 key 組成（credential / session 歸屬）

    /// 既定支援範圍：不同帳號的同名使用者，密碼必須各自獨立。pi 1001d：密碼以帳號 id 定址。
    func test_secureStorageKey_givenDifferentAccounts_isolatesCredentials() {
        let store = MockSecureStorage()
        store.savePassword(accountId: "acct-A", password: "pw-A")
        store.savePassword(accountId: "acct-B", password: "pw-B")

        XCTAssertEqual(store.getPassword(accountId: "acct-A"), "pw-A",
                       "不同帳號的憑證必須各自獨立 —— 這是既定支援範圍")
        XCTAssertEqual(store.getPassword(accountId: "acct-B"), "pw-B")
        XCTAssertEqual(store.store.count, 2, "應產生兩把相異的 key")
    }

    /// 既定支援範圍：session 同理。pi 1001c：session 以帳號 id 定址，同 host、同 username、
    /// 不同資料庫的兩個帳號也各自獨立（舊的 host＋username 鍵會撞在一起）。
    func test_secureStorageKey_givenDifferentAccounts_isolatesSessions() {
        let store = MockSecureStorage()
        store.saveSessionId(accountId: "acct-db1", sessionId: "sess-1")
        store.saveSessionId(accountId: "acct-db2", sessionId: "sess-2")

        XCTAssertEqual(store.getSessionId(accountId: "acct-db1"), "sess-1")
        XCTAssertEqual(store.getSessionId(accountId: "acct-db2"), "sess-2")
        store.deleteSessionId(accountId: "acct-db1")
        XCTAssertNil(store.getSessionId(accountId: "acct-db1"))
        XCTAssertEqual(store.getSessionId(accountId: "acct-db2"), "sess-2")
    }

    /// 原風險探測（同 host 不同 port、同 host 不同 DB 共用一把 key）已依檔頭說明翻轉為驗收：
    /// pi 1001d 決定支援同 host 多 DB／多 port，密碼改以帳號 id 定址後，兩個帳號各自獨立。
    func test_secureStorageKey_givenSameHostDifferentPortOrDatabase_isolatesCredentials() {
        let store = MockSecureStorage()
        store.savePassword(accountId: "acct-port-443", password: "pw-port-443")
        store.savePassword(accountId: "acct-port-8069", password: "pw-port-8069")
        store.savePassword(accountId: "acct-db-alpha", password: "pw-db-alpha")
        store.savePassword(accountId: "acct-db-beta", password: "pw-db-beta")

        XCTAssertEqual(store.store.count, 4, "每個帳號一把 key")
        XCTAssertEqual(store.getPassword(accountId: "acct-port-443"), "pw-port-443")
        XCTAssertEqual(store.getPassword(accountId: "acct-port-8069"), "pw-port-8069")
        XCTAssertEqual(store.getPassword(accountId: "acct-db-alpha"), "pw-db-alpha",
                       "第二個 DB 的密碼不再覆蓋第一個")
        XCTAssertEqual(store.getPassword(accountId: "acct-db-beta"), "pw-db-beta")
    }

    // MARK: - 缺陷 3：tenant 回寫的歸屬（可修）

    /// 既定支援範圍：不同 host 時，tenant 必須回寫到對應的那一筆。
    func test_setTenantId_givenDistinctServerUrls_writesToCorrectAccount() {
        let persistence = PersistenceController(inMemory: true)
        let repo = AccountRepository(persistence: persistence)
        repo.replaceAccountsForTesting([
            SeededAccount(serverURL: hostA, database: "alpha", username: "admin",
                          sessionCookie: "s-A", tenantId: nil, isActive: true),
            SeededAccount(serverURL: hostB, database: "beta", username: "admin",
                          sessionCookie: "s-B", tenantId: nil, isActive: false),
        ])

        repo.setTenantId("tenant-B", forServerUrl: hostB)

        let all = repo.getAllAccounts()
        XCTAssertEqual(all.first(where: { $0.serverUrl == hostB })?.tenantId, "tenant-B")
        XCTAssertNil(all.first(where: { $0.serverUrl == hostA })?.tenantId,
                     "A 不得被寫入 B 的 tenant id")
    }

    /// ★ 核心紅測：兩筆帳號共用同一個 serverUrl（同 host 多 DB）時，
    /// 以 serverUrl 為鍵的回寫**無從辨識該寫哪一筆**。
    ///
    /// 目前實作 `AccountRepository.setTenantId(_:forServerUrl:)` 取
    /// `(try? context.fetch(request))?.first` —— 直接挑第一筆，等同猜測。
    ///
    /// 正確契約應與本輪 EP-08F 的 `getAccount(byTenantId:)` 一致：
    /// **歧義即拒絕**，不猜。把錯的 tenant 寫進帳號會讓後續推播導到錯誤實例。
    func test_setTenantId_givenAmbiguousServerUrl_refusesInsteadOfGuessing() {
        let persistence = PersistenceController(inMemory: true)
        let repo = AccountRepository(persistence: persistence)
        // 同一台主機上的兩個資料庫 —— serverUrl 完全相同
        repo.replaceAccountsForTesting([
            SeededAccount(serverURL: sameHostP1, database: "alpha", username: "admin",
                          sessionCookie: "s-1", tenantId: nil, isActive: true),
            SeededAccount(serverURL: sameHostP1, database: "beta", username: "admin",
                          sessionCookie: "s-2", tenantId: nil, isActive: false),
        ])

        repo.setTenantId("tenant-for-beta", forServerUrl: sameHostP1)

        let written = repo.getAllAccounts().filter { $0.tenantId != nil }
        XCTAssertTrue(written.isEmpty,
                      "serverUrl 對應到兩筆帳號時必須拒絕回寫，不得挑第一筆猜 —— " +
                      "猜錯會把推播導到錯誤的實例（實際寫入了 \(written.count) 筆）")
    }
}
