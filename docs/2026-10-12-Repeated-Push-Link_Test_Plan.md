# Repeated push navigation tests

1. RED: coordinator regression for notification URL, consumed/nil update, then
   another notification with the same URL; observe two navigation requests.
2. GREEN: same event multiple updates navigates once; different events with the
   same URL navigate twice even if SwiftUI coalesces the intervening nil.
3. Pending manager only consumes the expected event; a newer same-account event
   survives an older consume. Event identity reaches MainViewModel.
4. Preserve cold-start load ordering and existing multi-account routing tests.

Run XCTest with ApporoUnit and UNIT_TEST_HOST; injected load closures prevent
network requests. Physical push delivery is a separate coordinator-owned check.

## Results (2026-10-12)

Base: `2819bcb` (`ios-fix-0930b`, TestFlight build 4 source). No version change.

- RED: 3 ColdStartDeepLinkOrderTests executed, 2 passed and the new
  `test_sameURL_afterConsumedUpdate_navigatesAgain` failed with navigation count
  **1 instead of 2**. This was an assertion failure, not an environment failure.
- GREEN: **28 executed, 28 passed, 0 failed, 0 skipped**. Suites: cold-start/order
  (5), deep-link binding (5), external intake (5), multi-account AppDelegate (3),
  navigation plan (9), repeated event/view-model/consume (1).
- `scripts/audit_test_hook_naming.sh`: PASS. `git diff --check`: PASS.
- Both XCTest runs used `heavy.sh run apporo-ios-repeat`, scheme `apporoodoo`,
  `ApporoUnit`, `DEBUG UNIT_TEST_HOST`, one build job and disabled parallel tests.
  Simulator: existing `Apporo-Odoo-UnitTests-20260924`; shutdown after each run.
  Disk guard checked at least 3 GiB free throughout; final free space ~4 GiB.

Evidence: `research/apporo-odoo/validation/ios-repeat-push-20261012/` in the
WOOW-mobile-app-analysis workspace (`red.log`, `red.summary.json`, `red.xcresult`,
`green.log`, `green.summary.json`, `green.xcresult`, `run-focused.sh`).

This is focused simulator/unit evidence, not physical APNs delivery, a full test
suite, a release archive, or a TestFlight update. Session-heal and pre-navigation
TTL limitations remain as recorded in the implementation plan.
