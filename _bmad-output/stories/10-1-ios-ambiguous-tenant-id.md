# Story 10-1 — iOS: a push deep link must not act on an ambiguous tenant id

- **Status:** review-fixes-applied — WI-1/WI-2 implemented, then seven review findings fixed,
  including one my change **missed entirely** and one that proved the whole fix was untested.
- **Repo:** ios · branch `dev_spec_drift_refine` (base `9d047e3`)
- **Covers:** the **iOS half of P2-9**. The Android half is story 8-1 in that repo.

> ⛔ **No live verification.** Unit tests and static checks only; anything needing a server or a real
> push is marked 待伺服器恢復後驗證.

## The defect — identical in shape to Android's, narrower in blast radius

`OdooAccountEntity.fetchByTenantIdRequest` sets **`fetchLimit = 1`**, and
`AccountRepository.getAccount(byTenantId:)` returns that first row. `NotificationDeepLinkRouter`
then routes the push to it.

`odoo_tenant_id` is the Odoo **database name** (the plugin's `tenant_id_for`: "one database == one
tenant/box"), and spec §4.3 ships every STB box with the same `POSTGRES_DB`. Two customer servers
therefore produce two local accounts with an **identical** tenant id, and `fetchLimit = 1` makes the
routing target depend on whatever order Core Data returns — a legitimate push from server Y opening
server X's account. No attacker required.

**And the same deeper problem applies:** a tenant id names a TENANT, not an ACCOUNT. Two users on
**one** database necessarily share it, so this is not only a mis-provisioning issue. The real fix is
server-side (stamp something account-scoped on the payload) and is recorded, not attempted here.

## What iOS does NOT share with Android

Android's `switchAccount` **unregistered the previous account's FCM token**, so a mis-routed tap
killed push for an unrelated account — a denial-of-notifications primitive. **iOS has no such call**:
`unregisterFcmToken` is reached only from `logout` and `removeAccount`. Verified, and recorded so the
platforms' fixes are not assumed symmetrical.

## Work items
- **WI-1** `getAccount(byTenantId:)` returns `nil` when more than one account matches. Drop the
  `fetchLimit`, count, and refuse on ambiguity — a `LIMIT 1` on a routing key is the defect itself.
- **WI-2** The router's drop reason must distinguish ambiguity from an unknown tenant, or an operator
  reading logs cannot tell "two boxes collide" from "this push is for an account we do not have".

## Acceptance criteria
- **AC1** Two accounts sharing a tenant id → the push is dropped, with an ambiguity-specific reason.
- **AC2** Exactly one match → unchanged (`switchAndRoute`).
- **AC3** No match → unchanged (`drop(.unresolvedTenant)`).
- **AC4** Absent/blank tenant id → unchanged (`useActive`) — the old-plugin path must not regress.
- **AC5** Fetch order must not decide the outcome: asserted over BOTH insertion orders, because a
  test asserting "it picks X" would pass with the bug present — the bug is that the pick is arbitrary.

## Test plan
| Claim | Verified how |
|---|---|
| AC1–AC4 (router) | Unit (hermetic) — `NotificationDeepLinkRouter` is a pure function |
| The repository's count-and-refuse, and the write path | Unit (hermetic) — `AmbiguousTenantCoreDataTests`, real `AccountRepository` over an in-memory Core Data stack |
| ~~AC5 "fetch order must not decide the outcome"~~ | **Not proven by the router test** — see the review record |
| Two deployed boxes actually emit the same id | 待伺服器恢復後驗證 — the fix is correct either way |
| E2E: a push from server Y, tapped, must not open server X | 待伺服器恢復後驗證 |

## Follow-ups
- **The routing key cannot identify an account.** Same as Android story 8-1: the server must stamp
  something account-scoped. That is the actual fix for P2-9 and it lives in the plugin.

## Dev Agent Record

### Implementation
- `fetchByTenantIdRequest` lost its `fetchLimit = 1`. That limit **was** the defect: the caller
  cannot count and refuse if the fetch has already thrown the evidence away.
- `getAccount(byTenantId:)` returns `nil` for both "no match" and "more than one".
- `isTenantIdAmbiguous(_:)` separates the two so the drop reason is actionable — it is consulted
  ONLY to choose a reason and can never turn a drop into a navigation.

### Confirmed asymmetry with Android, recorded rather than assumed
Android's `switchAccount` unregistered the previously-active account's FCM token, so a mis-routed tap
killed push for an unrelated account. **iOS has no such call** — `unregisterFcmToken` is reached only
from `logout` and `removeAccount`. So the iOS fix is narrower, and the platforms' remediations are
deliberately not symmetrical.

### Tests
Four new tests. The decisive one asserts **negatively over BOTH orderings**: no `switchAndRoute` may
be produced for a colliding id. A test asserting "it picks X" would pass with the bug present, because
the bug is that the pick is arbitrary.

Adding a protocol member required five conforming test doubles to implement it; each defaults to "not
ambiguous" with a comment saying why, and the suites that actually exercise ambiguity supply their own
closure.

### NOT proven — 待伺服器恢復後驗證
- That two deployed boxes emit the same `odoo_tenant_id` today. The fix is correct either way.
- E2E: a push from server Y, tapped, must not open server X.

## Code review round — what the first version got wrong

| # | Finding | Fix |
|---|---|---|
| 1 | **The WRITE path still took a first match.** I hunted `fetchLimit = 1` on the read path and missed the identical `.first` in `setTenantId`, which then short-circuited on `tenantId != tenantId`. Two users on ONE database share a `serverUrl`, so the registration loop's second pass hit the SAME row and was swallowed — **only one of the two rows was ever stamped**. `isTenantIdAmbiguous` then reported false, `getAccount` returned that single row, and a push for the OTHER user opened this one's session. The evidence was destroyed at write time, one layer earlier than the defect I fixed — the same failure mode I had just written a paragraph about. | `setTenantId` stamps every row matching the server. |
| 2 | **The entire production fix was untested.** A mutation test proved it: reverting `getAccount` to `.first` and `isTenantIdAmbiguous` to `false` left all 377 tests green. All four new tests fed the router a hand-written closure that **re-implemented** the repository's logic, so the repository and the `fetchLimit` removal were exercised by nothing. | `AmbiguousTenantCoreDataTests` runs the real repository over in-memory Core Data, including the write path from #1. |
| 3 | **"Asserts negatively over BOTH orderings" was tautological.** The closure body is `matches.count == 1 ? matches[0] : nil` — order-insensitive *by construction*, so the loop could not distinguish anything and the test could not fail. Fetch order is a property of Core Data, not of a closure the test wrote. | Renamed to what it actually pins (ambiguity never yields a switch), with the limitation stated; real fetch-order behaviour moved to the Core Data suite. |
| 4 | **The story claimed coverage that did not exist** — "the repository half uses an in-memory Core Data stack". It did not. | Table corrected. |
| 5 | **"Two users on one database → their deep links now drop" was false in the common case.** Per #1, only one row got stamped, so those pushes *routed* rather than dropping. The residual risk was understated: not "they lose deep links" but "they may lose them, or get each other's, depending on login history". | Fixed by #1; the story now says so. |
| 6 | **A silent permanent drop is a worse product than the bug.** Collision is the DEFAULT deployment (§4.3), so on such an install every notification tap became a no-op with no message and no fallback. | On the ambiguous path, if the **already-active** account is one of the candidates the link is applied to it — no switch, so no cross-tenant leak; it is the same `useActive` path the old-plugin branch already uses. Dropping only when the active account is genuinely not a candidate. |
| 7 | **The test doubles were made to compile, not to model the contract** — `RoutingFakeRepository` kept `.first`, so a future ambiguity test written against it would silently assert the pre-fix behaviour. | Each fake now states what it can and cannot represent, and points at the Core Data suite for the ambiguous path. |

### On the suite being "green"
The first commit said "full odooTests suite green". A run after these fixes reported
`test_redundantReconcileTriggers_areSafe` failing; a stash-and-rerun confirmed the **baseline** passes
and a re-run with the changes passes too, so it is a pre-existing flake (the suite shares mutable
statics and the real Keychain across test instances) and not caused by this work. Worth recording,
because "the suite is green" is not currently a reliable gate and this flake will eventually be blamed
on an innocent commit.
