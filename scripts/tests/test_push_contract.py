"""Stage-3 source guards, NOT a substitute for the URLProtocol XCTest suite.

No secrets, Firebase inputs, Xcode, network, or simulator access. Positive guards
are paired with mutations for the high-risk transport and adapter boundaries.
"""
from pathlib import Path
import re
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]


def source(path):
    return (ROOT / path).read_text()


def assert_scoped_transport(api):
    scoped = api.split("if let pushSessionId {", 1)[1].split("return try await session.data(for: urlRequest)\n", 1)[0]
    assert "urlRequest.httpShouldHandleCookies = false" in scoped
    assert 'forHTTPHeaderField: "Cookie"' in scoped
    assert "session.data(for: urlRequest, delegate: PushNoRedirectDelegate())" in scoped
    assert "HTTPCookieStorage" not in scoped
    redirect = api.split("private final class PushNoRedirectDelegate", 1)[1]
    assert "completionHandler(nil)" in redirect
    assert "completionHandler(request)" not in redirect
    auth = api.split("if isolatedPushSession {", 1)[1].split("} else {", 1)[0]
    assert "HTTPCookie.cookies(withResponseHeaderFields: headers, for: responseURL)" in auth
    assert "responseURL.absoluteString == url" in auth
    assert "getSessionId(" not in auth
    assert "guard Self.isValidPushSessionId(sessionId)" in auth
    assert 'return .error(String(localized: "error_session_setup"), .serverError)' in auth
    assert 'URL(string: serverUrl)?.scheme == "https"' in api


def assert_central_adapter(push, accounts):
    for text in [push, accounts]:
        executable = "\n".join(line for line in text.splitlines() if not line.strip().startswith("//"))
        assert 'method: "register_device"' not in executable
        assert 'method: "unregister_device"' not in executable
        assert "PushDeviceRegistrar(" in text
    assert "registrar.unregister(account: account, token: oldToken)" in push
    assert "registrar.unregister(account: account, token: token)" in push
    assert "unregisterFcmToken(account: account.toDomainModel())" in accounts
    assert "unregisterFcmToken(account: entity.toDomainModel())" in accounts


def assert_serialized_credentials(credential, secure, account):
    for name in ["pushCredential", "savePushCredential", "deletePushCredential"]:
        assert f"@MainActor func {name}(" in credential
        assert f"@MainActor func {name}(" in secure
    cas = credential.split("let outcome = await MainActor.run", 1)[1].split("if outcome ==", 1)[0]
    assert "accounts.getAllAccounts().contains" in cas
    assert "storage.pushCredential(accountId: account.id) == credential" in cas
    assert cas.index("storage.pushCredential(") < cas.index("storage.savePushCredential(")
    assert "await " not in cas
    remove = account.split("private func removeApporoAccount", 1)[1]
    transaction = remove.split("let captured = await MainActor.run", 1)[1].split("guard let (account, credential, token)", 1)[0]
    for required in ["pushCredentials.deletePushCredential(", "context.delete(entity)", "PushRegistrationStatusStore.shared.remove("]:
        assert required in transaction
    assert "await " not in transaction
    assert "capturedCredential: credential" in remove


def assert_generation_commit(registrar, push):
    commit = registrar.split("private func commit(", 1)[1].split("func register(", 1)[0]
    assert "let account = operation.account" in commit
    assert "sameIdentity($0, account)" in commit
    assert "isCurrent(operation.revision, accountId: account.id)" in commit
    assert "credentials.pushCredential(accountId: account.id)?.generation == operation.credential?.generation" in commit
    assert commit.index("operation.credential?.generation") < commit.index("accounts.setTenantId(") < commit.index("PushRegistrationStatusStore.shared.set(")
    assert "await " not in commit
    assert "accountRepository.setTenantId(" not in push
    assert "captured.generation != current?.generation" in registrar
    assert "case .temporarilyUnavailable: throw Failure.temporarilyUnavailable" in registrar
    assert "case .superseded: throw Failure.superseded" in registrar


def assert_cookie_policy(auth, account, credential, web):
    for required in ["propertiesData", "cookie.properties", "cookie.expiresDate", "matchesDomain, matchesPath",
                     "encoded.removeValue(forKey: HTTPCookiePropertyKey.maximumAge.rawValue)"]:
        assert required in auth
    manual = account.split("let outcome = await MainActor.run", 1)[1].split("if let rejection = outcome.rejection {", 1)[0]
    assert "let cookie = auth.sessionCookie?.cookie()" in manual
    # pi 1001b (P1): the "no usable response cookie → reject" rule now covers BOTH brands (it used to
    # be `brand == .apporo && cookie == nil`); the response SID must be the cookie's value.
    assert "guard let cookie = auth.sessionCookie?.cookie(), !auth.sessionId.isEmpty," in manual
    assert "cookie.value == auth.sessionId else {" in manual
    assert manual.index("guard let cookie = auth.sessionCookie?.cookie()") < manual.index("$0.isActive = false")
    assert "HTTPCookieStorage.shared.setCookie(cookie)" in manual
    assert "HTTPCookie(properties:" not in manual
    assert "sessionCookie: auth.sessionCookie" in manual
    assert "return credential.sessionCookie?.cookie()" in credential
    consumer = web.split("if brand == .apporo {", 1)[1].split("} else if", 1)[0]
    assert "pushCredentials.webSessionCookie(accountId: accountId," in consumer
    assert "HTTPCookie(properties:" not in consumer


def assert_switch_commit(account):
    switch = account.split("private func switchApporoAccount", 1)[1].split("/// Honest logout", 1)[0]
    for required in ["let attempt = PushManualLoginOrder.begin()", "captured.matches(account)",
                     "apiClient.authenticatePushSession(", "sessionCookie: auth.sessionCookie",
                     "account.userId == nil || account.userId == auth.userId"]:
        assert required in switch
    commit = switch.split("let context = persistence.container.viewContext", 1)[1]
    for required in ["PushManualLoginOrder.isCurrent(attempt)", "captured.matches(target.toDomainModel())",
                     "pushCredentials.pushCredential(accountId: id)?.generation == captured.generation",
                     "let cookie = selected.sessionCookie?.cookie()", "cookie.value == selected.sessionId"]:
        assert required in commit
        assert commit.index(required) < commit.index("$0.isActive = false")
    for required in ["pushCredentials.savePushCredential(selected)", "HTTPCookieStorage.shared.setCookie(cookie)"]:
        assert required in commit
    assert "await " not in commit
    assert "getPassword(" not in switch
    assert "getSessionId(" not in switch
    assert "HTTPCookie(properties:" not in switch


def assert_begin_identity(registrar):
    begin = registrar.split("@MainActor private func begin", 1)[1].split("/// Identity, generation", 1)[0]
    assert "sameIdentity($0, account)" in begin
    reject = "if brand == .apporo && captured == nil && !identityIsCurrent { throw Failure.superseded }"
    assert reject in begin
    assert begin.index(reject) < begin.index("PushRegistrationStatusStore.shared.begin(")
    assert "captured.generation != current?.generation || !identityIsCurrent" in begin
    assert "await " not in begin


class PushContractSourceTests(unittest.TestCase):
    def test_scoped_transport_is_explicit_cookie_no_shared_jar_or_redirect(self):
        assert_scoped_transport(source("odoo/Data/API/OdooAPIClient.swift"))

    def test_scoped_transport_rejects_jar_redirect_and_ambient_sid_mutations(self):
        api = source("odoo/Data/API/OdooAPIClient.swift")
        for old, new in [
            ("urlRequest.httpShouldHandleCookies = false", "urlRequest.httpShouldHandleCookies = true"),
            ("completionHandler(nil)", "completionHandler(request)"),
            ("HTTPCookie.cookies(withResponseHeaderFields: headers, for: responseURL)", "getSessionId(for: serverUrl)"),
            ("responseURL.absoluteString == url", "true"),
            ("guard Self.isValidPushSessionId(sessionId)", "guard true"),
        ]:
            with self.assertRaises(AssertionError):
                assert_scoped_transport(api.replace(old, new))

    def test_every_repository_write_uses_the_same_adapter(self):
        assert_central_adapter(source("odoo/Data/Push/PushTokenRepository.swift"),
                               source("odoo/Data/Repository/AccountRepository.swift"))
        sites = []
        for path in (ROOT / "odoo").rglob("*.swift"):
            code = "\n".join(line for line in path.read_text().splitlines() if not line.strip().startswith("//"))
            if re.search(r'method: "(?:unregister|register)_device"', code):
                sites.append(str(path.relative_to(ROOT)))
        self.assertEqual(sites, ["odoo/Data/Push/PushDeviceRegistrar.swift"])

    def test_direct_write_bypass_mutation_is_rejected(self):
        push = source("odoo/Data/Push/PushTokenRepository.swift")
        accounts = source("odoo/Data/Repository/AccountRepository.swift")
        with self.assertRaises(AssertionError):
            assert_central_adapter(push + '\napi.callKw(method: "unregister_device")', accounts)
        with self.assertRaises(AssertionError):
            assert_central_adapter(push, accounts.replace("unregisterFcmToken(account: entity.toDomainModel())", "return"))

    def test_compound_healing_is_structurally_one_retry_and_woow_unchanged(self):
        registrar = source("odoo/Data/Push/PushDeviceRegistrar.swift")
        self.assertEqual(registrar.count("catch OdooAPIError.sessionExpired"), 1)
        self.assertEqual(registrar.count("await healer.heal("), 1)
        self.assertEqual(registrar.count("return try await capabilityAndWrite("), 2)
        woow = registrar.split("if brand == .woowtech {", 1)[1].split("guard let credential", 1)[0]
        self.assertIn("SessionHealingRegistrar", woow)
        self.assertNotIn("get_push_capabilities", woow)
        self.assertNotIn("app_brand", woow)
        compound = registrar.split("private func capabilityAndWrite", 1)[1]
        self.assertLess(compound.index('method: "get_push_capabilities"'), compound.index('branded["app_brand"] = "apporo"'))
        self.assertIn('response["app_brand"] as? String == "apporo"', compound)
        self.assertIn('Self.supportsVersion(response["push_contract_version"])', compound)
        for path in ["odoo/Data/API/SessionReauthenticator.swift", "odoo/Data/API/SessionHealingRegistrar.swift"]:
            diff = subprocess.run(["git", "diff", "HEAD", "--", path], cwd=ROOT, check=True, capture_output=True)
            self.assertEqual(diff.stdout, b"", path)

    def test_scoped_credentials_never_import_legacy_and_healing_never_publishes(self):
        credential = source("odoo/Data/Push/PushCredential.swift")
        for part in ["accountId == account.id", "serverURL == account.fullServerUrl", "database == account.database",
                     "username == account.username", "current.generation == credential.generation",
                     "api.authenticatePushSession("]:
            self.assertIn(part, credential)
        for forbidden in ["getPassword(", "getSessionId(", "HTTPCookieStorage", "reauthenticateForHost("]:
            self.assertNotIn(forbidden, credential)
        account = source("odoo/Data/Repository/AccountRepository.swift")
        self.assertIn("PushManualLoginOrder.isCurrent(attempt)", account)
        guarded = account.split("let outcome = await MainActor.run", 1)[1].split("if let rejection = outcome.rejection {", 1)[0]
        self.assertLess(guarded.index("PushManualLoginOrder.isCurrent(attempt)"), guarded.index("$0.isActive = false"))
        self.assertIn("secureStorage.saveSessionId(", guarded)
        self.assertIn("HTTPCookieStorage.shared.setCookie(cookie)", guarded)
        self.assertIn("PushManualLoginOrder.invalidate()", account)
        self.assertIn("pushCredentials.deletePushCredential(accountId: account.id)", account)
        self.assertIn("pushCredentials.deletePushCredential(accountId: entity.id)", account)

    def test_status_is_account_keyed_localized_and_never_raw_error(self):
        status = source("odoo/Data/Push/PushRegistrationStatus.swift")
        keys = re.findall(r'= "(push_status_\w+)"', status)
        self.assertEqual(len(keys), 7)
        for language in ["en", "zh-Hans", "zh-Hant"]:
            text = source(f"odoo/Resources/{language}.lproj/Localizable.strings")
            for key in keys + ["error_session_setup", "error_login_superseded"]:
                self.assertEqual(text.count(f'"{key}" = '), 1)
        view = source("odoo/UI/Settings/SettingsView.swift")
        self.assertIn("pushStatus.status(for: pushAccountId)", view)
        self.assertIn("Registration acknowledgement does not confirm notification delivery.", view)
        for path in ["odoo/Data/Push/PushDeviceRegistrar.swift", "odoo/Data/Push/PushTokenRepository.swift",
                     "odoo/Data/Repository/AccountRepository.swift"]:
            self.assertNotIn("error.localizedDescription", source(path))

    def test_push_diagnostics_are_debug_only(self):
        # W1-5: the Settings diagnostics section is gated on a DEBUG-compiled
        # build, and neither Release configuration defines DEBUG.
        view = source("odoo/UI/Settings/SettingsView.swift")
        self.assertIn("PushDiagnosticsVisibility.isVisible(", view)
        self.assertIn("isDebugBuild: PushDiagnosticsVisibility.isDebugBuild", view)
        self.assertNotIn("if AppBrand.current.code == .apporo, let pushAccountId", view)
        gate = source("odoo/UI/Settings/PushDiagnosticsVisibility.swift")
        self.assertIn("#if DEBUG", gate)
        self.assertIn("brand == .apporo && hasActiveAccount && isDebugBuild", gate)
        for name in ["WoowRelease", "ApporoRelease"]:
            line = next(l for l in source(f"Config/{name}.xcconfig").splitlines()
                        if l.startswith("SWIFT_ACTIVE_COMPILATION_CONDITIONS"))
            self.assertNotIn("DEBUG", line, name)
        for name in ["WoowDebug", "ApporoDebug"]:
            line = next(l for l in source(f"Config/{name}.xcconfig").splitlines()
                        if l.startswith("SWIFT_ACTIVE_COMPILATION_CONDITIONS"))
            self.assertIn("DEBUG", line, name)

    def test_review_shared_main_actor_owns_cas_manual_and_remove(self):
        assert_serialized_credentials(source("odoo/Data/Push/PushCredential.swift"),
                                      source("odoo/Data/Storage/SecureStorage.swift"),
                                      source("odoo/Data/Repository/AccountRepository.swift"))

    def test_review_cas_rejects_nonisolated_storage_or_split_commit_mutations(self):
        credential = source("odoo/Data/Push/PushCredential.swift")
        secure = source("odoo/Data/Storage/SecureStorage.swift")
        account = source("odoo/Data/Repository/AccountRepository.swift")
        for old, new in [("@MainActor func savePushCredential(", "func savePushCredential("),
                         ("storage.pushCredential(accountId: account.id) == credential", "true"),
                         ("storage.savePushCredential(refreshed)", "await storage.savePushCredential(refreshed)")]:
            with self.assertRaises(AssertionError):
                assert_serialized_credentials(credential.replace(old, new), secure, account)
        with self.assertRaises(AssertionError):
            assert_serialized_credentials(credential, secure.replace("@MainActor func deletePushCredential", "func deletePushCredential"), account)

    def test_review_completion_atomically_checks_identity_generation_revision_and_tenant(self):
        assert_generation_commit(source("odoo/Data/Push/PushDeviceRegistrar.swift"),
                                 source("odoo/Data/Push/PushTokenRepository.swift"))

    def test_review_completion_rejects_unguarded_or_split_tenant_mutations(self):
        registrar = source("odoo/Data/Push/PushDeviceRegistrar.swift")
        push = source("odoo/Data/Push/PushTokenRepository.swift")
        for old, new in [("sameIdentity($0, account)", "true"),
                         ("isCurrent(operation.revision, accountId: account.id)", "isAlwaysCurrent()"),
                         ("credentials.pushCredential(accountId: account.id)?.generation == operation.credential?.generation", "true"),
                         ("accounts.setTenantId(tenantId", "await accounts.setTenantId(tenantId")]:
            with self.assertRaises(AssertionError):
                assert_generation_commit(registrar.replace(old, new), push)
        with self.assertRaises(AssertionError):
            assert_generation_commit(registrar, push + "\naccountRepository.setTenantId(tenantId, forAccountId: account.id)")

    def test_review_cookie_policy_roundtrip_and_web_consumer_are_wired(self):
        assert_cookie_policy(source("odoo/Domain/Models/AuthResult.swift"),
                             source("odoo/Data/Repository/AccountRepository.swift"),
                             source("odoo/Data/Push/PushCredential.swift"),
                             source("odoo/UI/Main/OdooWebView.swift"))

    def test_review_cookie_policy_rejects_root_reconstruction_or_expiry_bypass(self):
        auth = source("odoo/Domain/Models/AuthResult.swift")
        account = source("odoo/Data/Repository/AccountRepository.swift")
        credential = source("odoo/Data/Push/PushCredential.swift")
        web = source("odoo/UI/Main/OdooWebView.swift")
        for old, new in [("matchesDomain, matchesPath", "true"), ("cookie.expiresDate", "nil")]:
            with self.assertRaises(AssertionError):
                assert_cookie_policy(auth.replace(old, new), account, credential, web)
        with self.assertRaises(AssertionError):
            assert_cookie_policy(auth, account.replace("let cookie = auth.sessionCookie?.cookie()", "let cookie = HTTPCookie(properties: [:])"), credential, web)
        with self.assertRaises(AssertionError):
            assert_cookie_policy(auth, account, credential, web.replace("pushCredentials.webSessionCookie(accountId: accountId,", "HTTPCookie(properties:"))

    def test_last_review_switch_commits_response_session_after_selection_revalidation(self):
        assert_switch_commit(source("odoo/Data/Repository/AccountRepository.swift"))

    def test_last_review_switch_rejects_legacy_auth_stale_selection_and_missing_policy_mutations(self):
        account = source("odoo/Data/Repository/AccountRepository.swift")
        for old, new in [("apiClient.authenticatePushSession(", "apiClient.authenticate("),
                         ("PushManualLoginOrder.isCurrent(attempt)", "true"),
                         ("captured.matches(target.toDomainModel())", "true"),
                         ("pushCredentials.pushCredential(accountId: id)?.generation == captured.generation", "true"),
                         ("let cookie = selected.sessionCookie?.cookie()", "let cookie = HTTPCookie(properties: [:])"),
                         ("pushCredentials.savePushCredential(selected)", "await pushCredentials.savePushCredential(selected)")]:
            with self.assertRaises(AssertionError):
                assert_switch_commit(account.replace(old, new))

    def test_last_review_begin_rejects_stale_identity_before_revision(self):
        assert_begin_identity(source("odoo/Data/Push/PushDeviceRegistrar.swift"))

    def test_last_review_begin_rejects_identity_and_order_mutations(self):
        registrar = source("odoo/Data/Push/PushDeviceRegistrar.swift")
        for old, new in [("sameIdentity($0, account)", "true"),
                         ("&& !identityIsCurrent { throw Failure.superseded }", "{ }"),
                         ("let identityIsCurrent =", "let stolen = PushRegistrationStatusStore.shared.begin(accountId: account.id)\n        let identityIsCurrent ="),
                         ("|| !identityIsCurrent", "")]:
            with self.assertRaises(AssertionError):
                assert_begin_identity(registrar.replace(old, new))

    def test_behavior_suite_is_offline_injected_without_skips_or_forwarding(self):
        test = source("odooTests/PushDeviceRegistrarTests.swift")
        self.assertGreaterEqual(test.count("    func test_"), 30)
        self.assertIn("config.protocolClasses = [PushContractURLProtocol.self]", test)
        self.assertIn("throw URLError(.cannotConnectToHost)", test)
        self.assertNotIn("XCTSkip", test)
        self.assertNotRegex(test, r"URLSession\.shared|\.dataTask\(|\.resume\(")


if __name__ == "__main__":
    unittest.main()
