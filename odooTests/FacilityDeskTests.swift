import XCTest
@testable import odoo

/// Offline Odoo 18 contract and account/project isolation tests. No live tenant is contacted.
@MainActor
final class FacilityDeskTests: XCTestCase {
    private var session: URLSession!
    private var api: OdooAPIClient!
    private let server = "https://facility.invalid/base/"

    override func setUp() async throws {
        try await super.setUp()
        FacilityTransport.reset([])
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FacilityTransport.self]
        config.httpCookieStorage = .shared
        session = URLSession(configuration: config)
        api = OdooAPIClient(session: session)
    }

    override func tearDown() async throws {
        session.invalidateAndCancel()
        for cookie in HTTPCookieStorage.shared.cookies ?? [] where cookie.domain.contains("facility.invalid") {
            HTTPCookieStorage.shared.deleteCookie(cookie)
        }
        FacilityTransport.reset([])
        try await super.tearDown()
    }

    private func read(_ sid: String = "account-a") async throws -> [[String: Any]] {
        try await api.searchReadInSession(serverUrl: server, sessionId: sid,
            model: "project.project", fields: ["id", "name"], domain: [["active", "=", true]],
            offset: 2, limit: 15, sort: "name asc")
    }

    func test_searchRead_usesOdoo18ModelMethodAndReturnsRecords() async throws {
        FacilityTransport.reset([.result([["id": 12, "name": "Building A"]])])
        let records = try await read()
        XCTAssertEqual(records.first?["name"] as? String, "Building A")
        let call = try XCTUnwrap(FacilityTransport.calls.first)
        XCTAssertEqual(call.request.url?.absoluteString, "https://facility.invalid/base/web/dataset/call_kw")
        XCTAssertEqual(call.params["model"] as? String, "project.project")
        XCTAssertEqual(call.params["method"] as? String, "search_read")
        let kwargs = try XCTUnwrap(call.params["kwargs"] as? [String: Any])
        XCTAssertEqual(kwargs["fields"] as? [String], ["id", "name"])
        XCTAssertEqual(kwargs["offset"] as? Int, 2)
        XCTAssertEqual(kwargs["limit"] as? Int, 15)
        XCTAssertEqual(kwargs["order"] as? String, "name asc")
        let domain = try XCTUnwrap(kwargs["domain"] as? [[Any]])
        XCTAssertEqual(domain.first?.first as? String, "active")
        XCTAssertEqual(domain.first?.last as? Bool, true)
    }

    func test_accountScopedReadAndCreate_ignoreSameHostAmbientCookie() async throws {
        let ambient = try XCTUnwrap(HTTPCookie(properties: [
            .name: "session_id", .value: "wrong-account", .domain: "facility.invalid",
            .path: "/", .secure: "TRUE"
        ]))
        HTTPCookieStorage.shared.setCookie(ambient)
        FacilityTransport.reset([.result([]), .result(51)])
        _ = try await read("account-a")
        _ = try await api.callKwInSession(serverUrl: server, sessionId: "account-b",
            model: "project.task", method: "create", args: [["name": "Fixture"]])
        XCTAssertEqual(FacilityTransport.calls.map { $0.request.value(forHTTPHeaderField: "Cookie") },
                       ["session_id=account-a", "session_id=account-b"])
        XCTAssertTrue(FacilityTransport.calls.allSatisfy { !$0.request.httpShouldHandleCookies })
        XCTAssertEqual(api.getSessionId(for: server), "wrong-account")
    }

    func test_invalidURLOrSession_failsBeforeNetwork() async {
        for (url, sid) in [("http://facility.invalid", "sid"),
                           ("https://user@facility.invalid", "sid"),
                           ("https://facility.invalid?db=wrong", "sid"),
                           (server, ""), (server, "sid; other=bad"), (server, "sid\r\nX:bad")] {
            do {
                _ = try await api.searchReadInSession(serverUrl: url, sessionId: sid,
                    model: "project.project", fields: ["id"])
                XCTFail("Unsafe session request must fail")
            } catch { XCTAssertEqual(error as? OdooAPIError, .invalidUrl) }
        }
        XCTAssertTrue(FacilityTransport.calls.isEmpty)
    }

    func test_expiredSessionAndMalformedResult_doNotBecomeEmptySuccess() async {
        FacilityTransport.reset([.expired, .result(["records": []])])
        do { _ = try await read(); XCTFail("Expected session expiry") }
        catch { XCTAssertEqual(error as? OdooAPIError, .sessionExpired) }
        do { _ = try await read(); XCTFail("Odoo 18 result must be an array") }
        catch { XCTAssertEqual(error as? OdooAPIError, .invalidResponse) }
    }

    func test_noSession_doesNotReadOrCreate() async {
        let vm = FacilityDeskViewModel(serverUrl: server, sessionId: nil, apiClient: api, onSessionExpired: {})
        await vm.loadProjects()
        let created = await vm.createRequest(title: "Request", details: "Details", priority: .high)
        XCTAssertFalse(created)
        XCTAssertEqual(vm.errorMessageKey, "facility_session_required_detail")
        XCTAssertTrue(FacilityTransport.calls.isEmpty)
    }

    func test_createRequest_keepsProjectPriorityAndEscapesUserContent() async throws {
        FacilityTransport.reset([
            .result([["id": 10, "name": "Site <A>"]]), .result([]), .result(52),
            .result([["id": 52, "name": "Facility request: Lamp", "priority": "1", "stage_id": [1, "New"]]])
        ])
        let vm = FacilityDeskViewModel(serverUrl: server, sessionId: "account-a", apiClient: api, onSessionExpired: {})
        await vm.loadProjects()
        let created = await vm.createRequest(title: "Lamp", details: "<script>unsafe</script>\nCheck A & B", priority: .high)
        XCTAssertTrue(created)
        let call = try XCTUnwrap(FacilityTransport.calls.first { $0.params["method"] as? String == "create" })
        let values = try XCTUnwrap((call.params["args"] as? [[String: Any]])?.first)
        XCTAssertEqual(values["project_id"] as? Int, 10)
        XCTAssertEqual(values["priority"] as? String, "1")
        let description = try XCTUnwrap(values["description"] as? String)
        XCTAssertTrue(description.contains("Site &lt;A&gt;"))
        XCTAssertTrue(description.contains("&lt;script&gt;unsafe&lt;/script&gt;"))
        XCTAssertTrue(description.contains("<p>Check A &amp; B</p>"))
        XCTAssertFalse(description.contains("<script>"))
        XCTAssertEqual(vm.tasks.first?.id, 52)
        XCTAssertEqual(vm.tasks.first?.isHighPriority, true)
    }

    func test_switchProject_ignoresLateSuccessAndLateErrorFromPreviousProject() async throws {
        for lateReply in [FacilityTransport.Reply.result([["id": 99, "name": "Old project task"]]), .expired] {
            var heldReply = lateReply
            heldReply.hold = true
            FacilityTransport.reset([
                .result([["id": 10, "name": "A"], ["id": 20, "name": "B"]]),
                .result([]), heldReply,
                .result([["id": 21, "name": "B task", "priority": "0"]])
            ])
            var expirySignals = 0
            let vm = FacilityDeskViewModel(serverUrl: server, sessionId: "account-a", apiClient: api,
                                           onSessionExpired: { expirySignals += 1 })
            await vm.loadProjects()
            let oldLoad = Task { await vm.refreshTasks() }
            try await waitUntil { FacilityTransport.hasHeldReply }
            vm.selectProject(id: 20)
            try await waitUntil { vm.tasks.first?.id == 21 && !vm.isLoadingTasks }
            FacilityTransport.releaseHeld()
            await oldLoad.value
            XCTAssertEqual(vm.selectedProjectId, 20)
            XCTAssertEqual(vm.tasks.map(\.id), [21])
            XCTAssertNil(vm.errorMessageKey)
            XCTAssertEqual(expirySignals, 0, "Superseded project reads cannot log out the current view")
        }
    }

    func test_currentSessionExpiry_signalsReloginAndClearsTasks() async {
        FacilityTransport.reset([.result([["id": 10, "name": "A"]]), .expired])
        var expirySignals = 0
        let vm = FacilityDeskViewModel(serverUrl: server, sessionId: "account-a", apiClient: api,
                                       onSessionExpired: { expirySignals += 1 })
        await vm.loadProjects()
        XCTAssertEqual(expirySignals, 1)
        XCTAssertEqual(vm.errorMessageKey, "facility_session_expired")
        XCTAssertTrue(vm.tasks.isEmpty)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), "Timed out waiting for controlled transport state")
    }
}

private final class FacilityTransport: URLProtocol {
    struct Call { let request: URLRequest; let params: [String: Any] }
    struct Reply {
        let body: [String: Any]
        var hold = false
        static func result(_ value: Any) -> Reply { Reply(body: ["jsonrpc": "2.0", "id": "r1", "result": value]) }
        static let expired = Reply(body: ["error": ["code": 100, "message": "Odoo Session Expired"]])
    }
    private static let lock = NSLock()
    private static var recorded: [Call] = []
    private static var replies: [Reply] = []
    private static var held: [(FacilityTransport, Reply)] = []
    static var calls: [Call] { lock.lock(); defer { lock.unlock() }; return recorded }
    static var hasHeldReply: Bool { lock.lock(); defer { lock.unlock() }; return !held.isEmpty }
    static func reset(_ responses: [Reply]) {
        lock.lock(); defer { lock.unlock() }
        recorded = []; replies = responses; held = []
    }
    static func releaseHeld() {
        lock.lock(); let pending = held; held = []; lock.unlock()
        for (transport, response) in pending { transport.deliver(response) }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let root = try JSONSerialization.jsonObject(with: Self.body(request)) as? [String: Any]
            Self.lock.lock()
            Self.recorded.append(Call(request: request, params: root?["params"] as? [String: Any] ?? [:]))
            let reply = Self.replies.isEmpty ? nil : Self.replies.removeFirst()
            if let reply, reply.hold { Self.held.append((self, reply)) }
            Self.lock.unlock()
            guard let reply else { throw URLError(.cannotConnectToHost) }
            if !reply.hold { deliver(reply) }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    private func deliver(_ reply: Reply) {
        do {
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: reply.body))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
    private static func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
