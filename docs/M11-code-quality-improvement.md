# M11: Code Quality Improvement

> **Goal:** Upgrade test coverage from B+ to A by making two key components testable.
> **Triggered by:** Test-automator audit graded existing suite as D+ → fixed to B+ → need A.

---

## IC19: Refactor OdooAPIClient for URLProtocol Injection

### Problem
`OdooAPIClient` creates its own `URLSession` internally. Cannot inject mock `URLSession` or `URLProtocol` for testing HTTP behavior (JSON parsing, error mapping, cookie handling).

### Fix
1. Accept `URLSession` as `init` parameter with default
2. Create `MockURLProtocol` for test HTTP responses
3. Write tests for: auth success, auth failure, network error, malformed JSON, cookie extraction

### Files Changed
- `odoo/Data/API/OdooAPIClient.swift` — add `init(session:)`
- `odooTests/MissingTests.swift` — unskip `OdooAPIClientAuthTests`

### Tests Unlocked
- `test_authenticate_givenValidResponse_returnsSuccessWithUid`
- `test_authenticate_givenUidZero_returnsInvalidCredentials`
- `test_authenticate_givenJsonRpcError_mapsToDatabaseNotFound`
- `test_authenticate_givenNetworkError_returnsNetworkError`
- `test_authenticate_givenMalformedJson_returnsUnknown`

---

## IC20: Extract AppDelegate.handleNotificationTap

### Problem
`AppDelegate.userNotificationCenter(_:didReceive:)` contains deep link extraction logic that's untestable because `UNNotificationResponse` can't be instantiated in tests.

### Fix
1. Extract `handleNotificationTap(userInfo:)` as a separate `@MainActor` method
2. Test the extracted method directly with dictionaries
3. Keep delegate method as thin wrapper

### Files Changed
- `odoo/App/AppDelegate.swift` — extract method
- `odooTests/MissingTests.swift` — unskip `AppDelegateNotificationTests`

### Tests Unlocked
- `test_handleNotificationTap_givenValidUrl_storesPendingDeepLink`
- `test_handleNotificationTap_givenExternalUrl_doesNotStore`
- `test_handleNotificationTap_givenNoUrl_doesNothing`

---

## Verification
- All 180+ existing tests must still pass (regression)
- Previously skipped tests must now pass
- Total target: 190+ tests, 0 failures, 0 skipped (except hardware-dependent)
