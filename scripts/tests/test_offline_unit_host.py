"""Compile-only offline-host source contracts; stdlib, no Xcode or network.

These deliberately pin the audited transport seams. New seams require human
review, not an automatic assertion that all URLSessions are safe.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


def source(path):
    return (ROOT / path).read_text()


def offline_branch(text):
    return text.split("#if DEBUG && UNIT_TEST_HOST\n", 1)[1].split("#else", 1)[0]


def assert_launch_contract(delegate, app):
    branch = offline_branch(delegate)
    executable = "\n".join(line for line in branch.splitlines() if not line.strip().startswith("//"))
    assert executable.strip() == (
        "precondition(URLProtocol.registerClass(OfflineUnitHostURLProtocol.self))\n"
        "        return true"
    )
    root = offline_branch(app)
    executable = "\n".join(line for line in root.splitlines() if not line.strip().startswith("//"))
    assert executable.strip() == "EmptyView()"


def assert_transport_contract(api):
    default_init = api.split("    init() {", 1)[1].split("    /// Testable init", 1)[0]
    assert re.search(
        r"#if DEBUG && UNIT_TEST_HOST\s+//[^\n]*\n\s*"
        r"config.protocolClasses = \[OfflineUnitHostURLProtocol.self\]\s+#endif", default_init
    )
    assert default_init.index("config.protocolClasses") < default_init.index("URLSession(configuration: config)")
    assert "init(session: URLSession) {\n        self.session = session\n    }" in api


def allow_audited_cookie_consumer_apply(text):
    # Only this exact consumer-chain test may construct/apply a WebView. Its base
    # navigation is intercepted after real cookie-store completion; no remote load.
    name = "test_apporo_switchAccount_expiredAThroughBToA_withoutToken_reachesWebCookieConsumer"
    start = text.index("    func " + name + "()")
    end = text.index("    private func switchRepository()", start)
    test = text[start:end]
    for required in ["let stores = [a.id: WKWebsiteDataStore.nonPersistent(), b.id: WKWebsiteDataStore.nonPersistent()]",
                     "websiteDataStore: { stores[$0]! }, loadBaseRequest: { webView, request in",
                     "webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in",
                     'openExternalURL: { _ in XCTFail("No Safari") }',
                     "loaded[index].fulfill()"]:
        assert required in test
    assert test.count("coordinator.apply(serverUrl:") == 3
    assert test.count("deepLink: nil)") == 3
    assert test.count("await fulfillment(of: [loaded[") == 3
    assert "deepLink:" not in test.replace("deepLink: nil)", "")
    return text[:start] + test.replace("coordinator.apply(serverUrl:", "auditedCookieApply(serverUrl:") + text[end:]


def allow_audited_keyboard_restorer_apply(text):
    # The keyboard-restorer wiring test needs the coordinator's real child WKWebView. It builds
    # one with a non-persistent store, no session cookie (no Keychain read), no deep link, and a
    # base-load closure that does nothing: no request is ever issued.
    name = "test_coordinator_keyboardDidHide_restoresChildWebViewScrollOffset"
    start = text.index("    func " + name + "()")
    end = text.index("\n    }\n", start) + len("\n    }\n")
    test = text[start:end]
    for required in ["websiteDataStore: { _ in .nonPersistent() },",
                     "loadBaseRequest: { _, _ in },",
                     'openExternalURL: { _ in XCTFail("No Safari") },',
                     "brand: .woowtech,",
                     "sessionId: nil, deepLink: nil)"]:
        assert required in test
    assert test.count("coordinator.apply(serverUrl:") == 1
    assert "deepLink:" not in test.replace("deepLink: nil)", "")
    return text[:start] + test.replace("coordinator.apply(serverUrl:", "auditedKeyboardApply(serverUrl:") + text[end:]


def allow_audited_cold_start_deeplink_apply(text):
    # D4 (demo111 2026-09-29) ordering test needs the coordinator's real apply/rebuild path so the
    # session cookie goes through a real (non-persistent) cookie store whose completion issues the
    # base load. Both the base load and the deep-link load are intercepted closures that only
    # record; didFinish is driven through `accountPageDidFinish(loadedHost:)`. No request is issued.
    for required in ["websiteDataStore: { _ in .nonPersistent() },",
                     'loadBaseRequest: { [weak self] _, _ in self?.events.append("base") },',
                     "loadDeepLinkRequest: { [weak self] _, request in",
                     'openExternalURL: { _ in XCTFail("No Safari") },',
                     "brand: .woowtech,"]:
        assert required in text, required
    assert text.count("OdooWebViewCoordinator(") == 1
    assert text.count("sut.apply(serverUrl:") == 4
    assert text.count(".apply(serverUrl:") == 4
    return text.replace("sut.apply(serverUrl:", "auditedColdStartApply(serverUrl:")


def allow_audited_stale_instance_apply(text):
    # F1 (0930) stale-instance tests drive the coordinator's real apply/rebuild path so each
    # account switch builds a fresh child WebView; the WebView factory only pins `url` (no load),
    # the data store is non-persistent, and base / deep-link loads are intercepted closures that
    # only record. No request is issued.
    for required in ["websiteDataStore: { _ in .nonPersistent() },",
                     "loadBaseRequest: { [weak self] webView, _ in",
                     "loadDeepLinkRequest: { [weak self] _, request in",
                     'openExternalURL: { _ in XCTFail("No Safari") },',
                     "makeWebView: { config in PinnedURLWebView(frame: .zero, configuration: config) }",
                     "override var url: URL? { pinnedURL }",
                     "brand: .woowtech,"]:
        assert required in text, required
    assert text.count("OdooWebViewCoordinator(") == 1
    # Baseline c1afa58 (F1): 13 applies. Current 0930b (pi P2): +3 for the retire-notice tests,
    # same isolated store / intercepted loads.
    assert text.count("sut.apply(serverUrl:") == 16
    assert text.count(".apply(serverUrl:") == 16
    return text.replace("sut.apply(serverUrl:", "auditedStaleInstanceApply(serverUrl:")


def allow_audited_heal_reload_apply(text):
    # 1001 (demo111 defect 1): the heal-reload tests drive the coordinator's real apply/rebuild path
    # so the healed cookie lands in a real (non-persistent) per-account store. Base loads are an
    # intercepted closure that only counts; there is no session cookie at apply and no deep link.
    # No request is issued.
    for required in ["let store = WKWebsiteDataStore.nonPersistent()",
                     "loadBaseRequest: { [weak self] _, _ in self?.baseLoads += 1 },",
                     "loadDeepLinkRequest: { _, _ in }",
                     'openExternalURL: { _ in XCTFail("No Safari") },',
                     "brand: .woowtech,"]:
        assert required in text, required
    assert text.count("OdooWebViewCoordinator(") == 1
    assert text.count("sut.apply(serverUrl:") == 3
    assert text.count(".apply(serverUrl:") == 3
    assert text.count("sessionId: nil, deepLink: nil)") == 3
    return text.replace("sut.apply(serverUrl:", "auditedHealReloadApply(serverUrl:")


AUDITED_SESSION_PROTOCOLS = {
    # Baseline 0930b: ("SwitchURLProtocol",). Current 1001 (demo111 defect 1): a second, equally
    # offline SwitchURLProtocol session for the heal-then-switch reuse test.
    "ApporoSwitchSessionReuseTests.swift": ("SwitchURLProtocol", "SwitchURLProtocol"),
    "HonestLogoutS4Tests.swift": ("LogoutURLProtocol",),
    "LoginAccessDeniedMessageTests.swift": ("JsonRpcErrorURLProtocol",),
    "LogoutRevokesAccountWebDataTests.swift": ("DestroyCaptureURLProtocol",),
    "LoginServerErrorMessageTests.swift": ("CloudflareOriginDownURLProtocol",),
    "LoginUnexpectedResponseMessageTests.swift": ("HTMLPageURLProtocol",),
    "LogoutUnregisterURLTests.swift": ("RecordingURLProtocol",),
    "MissingTests.swift": ("StubURLProtocol",),
    "SessionReauthenticatorTests.swift": ("SequencedURLProtocol",),
    "SwitchAccountNoUnregisterTests.swift": ("RecordingURLProtocol", "RecordingURLProtocol"),
    "odooTests.swift": ("MockURLProtocol",),
    "OfflineUnitHostTests.swift": ("OfflineHostMockURLProtocol",),
    "PushDeviceRegistrarTests.swift": ("PushContractURLProtocol",),
    "SelfHealSharedJarIsolationTests.swift": ("HealJarURLProtocol",),  # 0930b (pi P1): offline authenticate replies only
    "SelfHealWebViewRecoveryTests.swift": ("RecoveryURLProtocol",),  # 1001 (demo111 defect 1): offline authenticate/destroy replies only
    "ServerUrlInputTests.swift": ("AuthRecordingURLProtocol",),
}


def assert_switch_account_session_scopes(text):
    # Pin the two reviewed method prefixes through construction, not a file-wide
    # first protocol assignment. No intervening statement can overwrite or alias
    # the fresh config. Deliberately not a Swift parser/network-safety proof:
    # changes to these exact source shapes require review.
    prefixes = (
        """    override func setUp() async throws {
        try await super.setUp()
        RecordingURLProtocol.reset()

        persistence = PersistenceController(inMemory: true)
        secureStorage = SecureStorage.shared

        // Recording OdooAPIClient over an ephemeral session — fully offline.
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecordingURLProtocol.self]
        let session = URLSession(configuration: config)""",
        """    func test_apporo_switchAccount_givenMismatchedScopedCredential_preservesSelectionWithoutRequests() async throws {
        // Explicit Apporo coverage also runs in the WOOW suite. A legacy password
        // is present, but it must not rescue a credential bound to a different database.
        let accountB = try XCTUnwrap(repo.getAllAccounts().first { $0.database == "demo888" })
        let otherDatabase = OdooAccount(id: accountB.id, serverUrl: accountB.serverUrl,
            database: "other-database", username: accountB.username,
            displayName: accountB.displayName, userId: accountB.userId)
        let mismatched = PushCredential(account: otherDatabase, password: passwordB, sessionId: "wrong-db")
        secureStorage.savePushCredential(mismatched)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecordingURLProtocol.self]
        let apporoRepo = AccountRepository(persistence: persistence, secureStorage: secureStorage,
            apiClient: OdooAPIClient(session: URLSession(configuration: config)), brand: .apporo)""",
    )
    for prefix in prefixes:
        assert text.count(prefix) == 1, "Changed audited SwitchAccount session scope"


def assert_audited_urlsession_inventory(sources):
    actual = {}
    for name, text in sources.items():
        assert not re.search(r"URLSession\.shared|URLSessionConfiguration\.background|NWConnection\(", text), name
        constructors = re.findall(r"URLSession\s*\(\s*configuration\s*:", text)
        if constructors:
            expected = AUDITED_SESSION_PROTOCOLS.get(name)
            assert expected is not None, f"Unaudited session file: {name}"
            assert len(constructors) == len(expected), f"Unaudited constructor count: {name}"
            assert text.count("URLSession(configuration: config)") == len(expected), name
            protocols = tuple(re.findall(r"config.protocolClasses = \[(\w+)\.self\]", text))
            assert len(re.findall(r"\bconfig\.protocolClasses\s*=", text)) == len(expected), name
            actual[name] = protocols
            if name == "SwitchAccountNoUnregisterTests.swift":
                assert_switch_account_session_scopes(text)
    assert actual == AUDITED_SESSION_PROTOCOLS, "Changed session file/protocol inventory"


def unit_test_sources():
    return {str(path.relative_to(ROOT / "odooTests")): path.read_text()
            for path in (ROOT / "odooTests").rglob("*.swift")}


class OfflineUnitHostSourceTests(unittest.TestCase):
    def test_launch_excludes_business_bootstrap_and_url_routing(self):
        delegate = source("odoo/App/AppDelegate.swift")
        app = source("odoo/odooApp.swift")
        assert_launch_contract(delegate, app)
        normal = delegate.split("#else", 1)[1].split("// MARK: - XCUITest Debug Hooks", 1)[0]
        for required in ["processTestLaunchArguments()", "FirebaseApp.configure(options: options)",
                         "requestAuthorization", "setNotificationCategories", "registerForRemoteNotifications()"]:
            self.assertIn(required, normal)
        normal_root = app.split("#else", 1)[1].split("#endif", 1)[0]
        self.assertIn("AppRootView()", normal_root)
        self.assertIn(".onOpenURL", normal_root)
        self.assertIn("handleIncomingURL(url)", normal_root)

    def test_launch_contract_rejects_firebase_and_business_root_mutations(self):
        delegate = source("odoo/App/AppDelegate.swift")
        app = source("odoo/odooApp.swift")
        with self.assertRaises(AssertionError):
            assert_launch_contract(delegate.replace("        return true", "        FirebaseApp.configure()\n        return true", 1), app)
        with self.assertRaises(AssertionError):
            assert_launch_contract(delegate, app.replace("EmptyView()", "AppRootView()", 1))

    def test_transport_explicit_default_guard_and_unchanged_injected_session(self):
        assert_transport_contract(source("odoo/Data/API/OdooAPIClient.swift"))

    def test_transport_contract_rejects_missing_guard_and_replaced_mock(self):
        api = source("odoo/Data/API/OdooAPIClient.swift")
        with self.assertRaises(AssertionError):
            assert_transport_contract(api.replace("config.protocolClasses = [OfflineUnitHostURLProtocol.self]", "config.protocolClasses = []"))
        with self.assertRaises(AssertionError):
            assert_transport_contract(api.replace("self.session = session", "self.session = URLSession.shared"))

    def test_release_compile_error_and_guard_has_no_forwarding_transport(self):
        guard = source("odoo/App/OfflineUnitHost.swift")
        self.assertTrue(guard.startswith('#if UNIT_TEST_HOST && !DEBUG\n#error('))
        self.assertIn('#if DEBUG && UNIT_TEST_HOST\nimport Foundation', guard)
        self.assertIn('scheme == "http" || scheme == "https"', guard)
        self.assertIn('didFailWithError: NSError(', guard)
        self.assertIn('domain: Self.errorDomain, code: 1', guard)
        self.assertNotRegex(guard, r"URLSession\s*[.(]|\.resume\(|didReceive:\s*response")

    def test_flag_not_persisted_in_build_configuration_or_runtime_gate(self):
        paths = list((ROOT / "Config").glob("*.xcconfig"))
        paths += list((ROOT / "odoo.xcodeproj/xcshareddata/xcschemes").glob("*.xcscheme"))
        paths += [ROOT / "odoo.xcodeproj/project.pbxproj", ROOT / "odoo/App/TestHookGate.swift"]
        # Do not read ignored local configuration (may contain protected values).
        for path in paths:
            if ".local." not in path.name:
                self.assertNotIn("UNIT_TEST_HOST", path.read_text(), str(path))
        gate = source("odoo/App/TestHookGate.swift")
        self.assertIn("#if DEBUG", gate)
        self.assertIn("ProcessInfo.processInfo.arguments.contains(launchArgumentMarker)", gate)
        self.assertIn('return false', gate)
        self.assertEqual(source("odooTests/TestHookGateTest.swift").count("    func test_"), 4)

    def test_audited_urlsession_constructor_inventory(self):
        assert_audited_urlsession_inventory(unit_test_sources())
        app_sessions = [str(p.relative_to(ROOT)) for p in (ROOT / "odoo").rglob("*.swift")
                        if re.search(r"URLSession\(configuration:", p.read_text())]
        self.assertEqual(app_sessions, ["odoo/Data/API/OdooAPIClient.swift"])

    def assert_switch_scope_mutation_rejected(self, old, new, scope_index=1):
        sources = unit_test_sources()
        name = "SwitchAccountNoUnregisterTests.swift"
        # Mutate just one occurrence; the other scope remains intact.
        parts = sources[name].split(old)
        self.assertEqual(len(parts), 3, "Mutation must target both audited scopes")
        replacements = [old, old]
        replacements[scope_index] = new
        sources[name] = parts[0] + replacements[0] + parts[1] + replacements[1] + parts[2]
        with self.assertRaises(AssertionError):
            assert_audited_urlsession_inventory(sources)

    def test_session_inventory_rejects_only_second_protocol_removed(self):
        self.assert_switch_scope_mutation_rejected(
            "        config.protocolClasses = [RecordingURLProtocol.self]\n", "")

    def test_session_inventory_rejects_only_second_protocol_changed(self):
        self.assert_switch_scope_mutation_rejected(
            "config.protocolClasses = [RecordingURLProtocol.self]",
            "config.protocolClasses = [OtherURLProtocol.self]")

    def test_session_inventory_rejects_protocol_overwrite_before_each_constructor(self):
        for scope in (0, 1):
            for overwrite in ("config.protocolClasses = []", "config.protocolClasses = nil"):
                with self.subTest(scope=scope, overwrite=overwrite):
                    binding = "config.protocolClasses = [RecordingURLProtocol.self]"
                    self.assert_switch_scope_mutation_rejected(binding, binding + "\n        " + overwrite, scope)

    def test_session_inventory_rejects_missing_fresh_config_in_each_scope(self):
        for scope in (0, 1):
            with self.subTest(scope=scope):
                self.assert_switch_scope_mutation_rejected(
                    "        let config = URLSessionConfiguration.ephemeral\n", "", scope)

    def test_session_inventory_rejects_intervening_config_mutation_in_each_scope(self):
        # Keep assignment counts/protocol inventory unchanged: only the scoped
        # shape check can reject the intervening call or a conditional binding.
        binding = "        config.protocolClasses = [RecordingURLProtocol.self]\n"
        for scope in (0, 1):
            for changed in (binding + "        mutate(config)\n",
                            "        if false {\n    " + binding + "        }\n"):
                with self.subTest(scope=scope, changed=changed):
                    self.assert_switch_scope_mutation_rejected(binding, changed, scope)

    def test_session_inventory_rejects_different_constructor_config_in_each_scope(self):
        for scope in (0, 1):
            with self.subTest(scope=scope):
                self.assert_switch_scope_mutation_rejected(
                    "URLSession(configuration: config)", "URLSession(configuration: otherConfig)", scope)

    def test_session_inventory_rejects_unreviewed_method_names(self):
        for method in ("setUp", "test_apporo_switchAccount_givenMismatchedScopedCredential_preservesSelectionWithoutRequests"):
            with self.subTest(method=method):
                sources = unit_test_sources()
                name = "SwitchAccountNoUnregisterTests.swift"
                sources[name] = sources[name].replace("func " + method + "()", "func unreviewed()", 1)
                with self.assertRaises(AssertionError):
                    assert_audited_urlsession_inventory(sources)

    def test_session_inventory_rejects_extra_constructor_in_every_audited_file(self):
        for name, protocols in AUDITED_SESSION_PROTOCOLS.items():
            with self.subTest(name=name):
                sources = unit_test_sources()
                sources[name] += ("\nlet config = URLSessionConfiguration.ephemeral\n"
                                  f"config.protocolClasses = [{protocols[0]}.self]\n"
                                  "let extra = URLSession(configuration: config)\n")
                with self.assertRaises(AssertionError):
                    assert_audited_urlsession_inventory(sources)

    def test_session_inventory_rejects_new_or_relocated_constructor_file(self):
        for destination in ("Unaudited.swift", "Nested/SwitchAccountNoUnregisterTests.swift"):
            with self.subTest(destination=destination):
                sources = unit_test_sources()
                sources[destination] = sources.pop("SwitchAccountNoUnregisterTests.swift")
                with self.assertRaises(AssertionError):
                    assert_audited_urlsession_inventory(sources)

    def test_session_inventory_preserves_whole_file_transport_bans(self):
        for name in ("SwitchAccountNoUnregisterTests.swift", "NoConstructors.swift"):
            for forbidden in ("URLSession.shared", "URLSessionConfiguration.background", "NWConnection("):
                with self.subTest(name=name, forbidden=forbidden):
                    sources = unit_test_sources()
                    sources[name] = sources.get(name, "") + "\n" + forbidden
                    with self.assertRaises(AssertionError):
                        assert_audited_urlsession_inventory(sources)

    def test_external_navigation_spy_preserves_default_order(self):
        web = source("odoo/UI/Main/OdooWebView.swift")
        self.assertIn('openExternalURL: @escaping (URL) -> Void = { UIApplication.shared.open($0) }', web)
        self.assertIn('self.openExternalURL = openExternalURL', web)
        self.assertIn('case .openInSafari(let url):\n            openExternalURL(url)\n            decisionHandler(.cancel)', web)
        test = source("odooTests/MissingTests.swift").split('func test_navigationPolicy_givenExternalHost_cancels()', 1)[1].split('// Blob URLs', 1)[0]
        for assertion in ['openExternalURL: { openedURLs.append($0) }', 'XCTAssertEqual(openedURLs, [externalURL]',
                          'XCTAssertEqual(policyCalls, 1', 'XCTAssertEqual(policy, .cancel']:
            self.assertIn(assertion, test)

    def test_unit_webkit_calls_are_not_remote_loads(self):
        for path in (ROOT / "odooTests").rglob("*.swift"):
            # Remove whole-line comments; .load pattern matching in pure planning tests is not I/O.
            text = "\n".join(line for line in path.read_text().splitlines()
                             if not line.strip().startswith("//") and "guard case .load(" not in line)
            if path.name == "PushDeviceRegistrarTests.swift":
                text = allow_audited_cookie_consumer_apply(text)
            if path.name == "WebViewKeyboardScrollRestorerTests.swift":
                text = allow_audited_keyboard_restorer_apply(text)
            if path.name == "ColdStartDeepLinkOrderTests.swift":
                text = allow_audited_cold_start_deeplink_apply(text)
            if path.name == "StaleWebViewInstanceTests.swift":
                text = allow_audited_stale_instance_apply(text)
            if path.name == "SelfHealWebViewRecoveryTests.swift":
                text = allow_audited_heal_reload_apply(text)
            self.assertNotRegex(text, r"\.load\(|\.loadHTMLString\(|\.reload\(|\.apply\(serverUrl:|createWebViewWith:")
            self.assertNotRegex(text, r"UIApplication\.shared\.open|Data\(contentsOf:|String\(contentsOf:")

    def test_cookie_consumer_exception_requires_isolated_store_and_navigation_interception(self):
        text = source("odooTests/PushDeviceRegistrarTests.swift")
        allow_audited_cookie_consumer_apply(text)
        for old, new in [("WKWebsiteDataStore.nonPersistent()", "WKWebsiteDataStore.default()"),
                         ("loadBaseRequest: { webView, request in", "unsafeLoad: { webView, request in"),
                         ("deepLink: nil)", 'deepLink: "https://push.invalid/web")')]:
            with self.assertRaises(AssertionError):
                allow_audited_cookie_consumer_apply(text.replace(old, new))
        web = source("odoo/UI/Main/OdooWebView.swift")
        self.assertIn("loadBaseRequest: @escaping (WKWebView, URLRequest) -> Void = { webView, request in webView.load(request) }", web)
        self.assertIn("loadBaseRequest(webView, URLRequest(url: url))", web)
        self.assertIn("config.websiteDataStore = websiteDataStore(accountId)", web)
        self.assertIn("OdooWebViewCoordinator.dataStore(forAccountId: $0)", web)

    def test_stale_instance_exception_requires_isolated_store_and_intercepted_loads(self):
        text = source("odooTests/StaleWebViewInstanceTests.swift")
        allow_audited_stale_instance_apply(text)
        for old, new in [("{ _ in .nonPersistent() }", "{ _ in .default() }"),
                         ("loadBaseRequest: { [weak self] webView, _ in", "loadBaseRequest: { webView, request in webView.load(request)"),
                         ("override var url: URL? { pinnedURL }", "override var title: String? { nil }"),
                         ("brand: .woowtech,", "brand: .apporo,")]:
            with self.assertRaises(AssertionError):
                allow_audited_stale_instance_apply(text.replace(old, new))

    def test_heal_reload_exception_requires_isolated_store_intercepted_loads_no_session_no_link(self):
        text = source("odooTests/SelfHealWebViewRecoveryTests.swift")
        allow_audited_heal_reload_apply(text)
        for old, new in [("let store = WKWebsiteDataStore.nonPersistent()", "let store = WKWebsiteDataStore.default()"),
                         ("loadBaseRequest: { [weak self] _, _ in self?.baseLoads += 1 },",
                          "loadBaseRequest: { webView, request in webView.load(request) },"),
                         ("sessionId: nil, deepLink: nil)", 'sessionId: "sid", deepLink: nil)'),
                         ("brand: .woowtech,", "brand: .apporo,")]:
            with self.assertRaises(AssertionError):
                allow_audited_heal_reload_apply(text.replace(old, new))

    def test_keyboard_restorer_exception_requires_no_load_no_session_no_link(self):
        text = source("odooTests/WebViewKeyboardScrollRestorerTests.swift")
        allow_audited_keyboard_restorer_apply(text)
        for old, new in [("loadBaseRequest: { _, _ in },", "loadBaseRequest: { webView, request in webView.load(request) },"),
                         ("{ _ in .nonPersistent() }", "{ _ in .default() }"),
                         ("sessionId: nil, deepLink: nil)", 'sessionId: "sid", deepLink: nil)'),
                         ("brand: .woowtech,", "brand: .apporo,")]:
            with self.assertRaises(AssertionError):
                allow_audited_keyboard_restorer_apply(text.replace(old, new))

    def test_runtime_cases_exist_without_skipping_existing_cases(self):
        tests = source("odooTests/OfflineUnitHostTests.swift")
        self.assertTrue(tests.startswith("#if DEBUG && UNIT_TEST_HOST\n"))
        self.assertEqual(tests.count("    func test_"), 6)
        self.assertNotIn("XCTSkip", tests)
        self.assertIn('XCTAssertEqual(failure.domain, "OfflineUnitHost.NetworkDenied"', tests)
        self.assertIn('XCTAssertEqual(result as? String, "offline-mock-reached")', tests)


if __name__ == "__main__":
    unittest.main()
