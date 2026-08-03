# Story 10-1 — iOS: a push deep link must not act on an ambiguous tenant id

- **Status:** review — WI-1/WI-2 implemented; full `odooTests` suite green on iPhone 16 simulator.
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
| AC1–AC5 | Unit (hermetic) — `NotificationDeepLinkRouter` is a pure function; the repository half uses an in-memory Core Data stack |
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
