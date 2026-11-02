# Apporo Facility Desk — product differentiation for the 4.3 resubmission

Date: 2026-10-30

## November 2 completed release follow-through

Source commit `f9ee2071dc40063a40ff9a1b9dda2f9188aae78f` and tag `ios-apporo-1.0-b6` are pushed. Corrected device archive, App Store export, signature and binary audits passed. Build 6 uploaded successfully at 14:19 Asia/Taipei, finished processing, and replaced build 5 in the review submission. App Store Connect now shows **1.0 (6), Waiting for Review** under submission `68131640-29ec-475c-a350-ca0ce45b691c`. Manual release is retained; no company-stamped documents were uploaded.

The review tenant now has Project and demonstration tasks. iPhone and iPad Release simulator flows created real tasks #5 (high priority) and #6 (standard), verified independently against Odoo under reviewer UID 10. English/Traditional Chinese forms, cancellation, refresh, relaunch, notification-denied iPad operation, dark appearance and stable landscape were checked. Full unit results remain 761 passed, one existing skip, zero failures. Physical iPad is still disconnected; no physical/TestFlight installation success is claimed.

Both listing languages and review notes were saved and verified; actual Facility Desk/request screenshots lead the iPhone large and iPad sets, with new English medium-iPhone assets. Evidence and exact remaining limits are in `docs/2026-11-02-Apporo-4.3-Investigation.md` and `receipts/apporo-platform-validation-1102/`. Earlier dated status below is historical.

## November 2 validation and correction plan

Execution update: the Odoo 18 transport and stale-project-response fixes are implemented. Eight new focused tests pass. The final signed-simulator ApporoUnit run completed with 762 tests (761 passed, one existing skip, zero failures), exit 0. A navigation-layout test was stabilized after observing its initial 106-to-54-point transition; its original height and inline assertions are preserved. Source test-hook audit passes. The second Apple response was sent at 12:31 Asia/Taipei, message count is four, and the exact text was verified after reload. No company-stamped documents were attached. See `docs/2026-11-02-Apporo-4.3-Investigation.md` for the evidence and remaining tenant/real-device work. The October 30 IPA predates these fixes and must not be uploaded as the corrected candidate.

The corrected ApporoRelease simulator build 1.0 (6) also passed with exit 0, including binary debug-hook/coverage audits. Use `CLANG_COVERAGE_MAPPING=NO ENABLE_CODE_COVERAGE=NO CLANG_ENABLE_CODE_COVERAGE=NO` for scheme Release builds so Swift package targets are also free of test instrumentation. This does not replace a device archive, end-to-end acceptance, or an Apple upload.

The review tenant was configured on November 2 using existing administrator credentials on the maintenance host, after a database backup. Odoo Projects is installed, review users have Project access, and site/project #1 has seeded tasks. On the Mac, reviewer UID 10 authenticated and read the data. The Release iPhone simulator UI created high-priority task #5, displayed success, refreshed the list, and read it again after relaunch. An independent server read verified project, creator, description and priority. Actual physical-device testing remains unavailable while the iPad is disconnected. Evidence is under `receipts/apporo-platform-validation-1102/`.

The initial `searchReadInSession` used the obsolete `/web/dataset/search_read` route, absent from the Odoo 18 controller. Use the existing pinned-session `call_kw` transport with model method `search_read` and its `domain`, `fields`, `offset`, `limit`, and `order` kwargs. Preserve the HTTPS/SID checks, redirect guard, and account isolation. Add offline transport regression tests for the Odoo 18 request and array result, same-host cookie isolation, invalid sessions/URLs, and expired sessions.

During review, project selection was found to skip a new task load if an older project request is in flight, allowing stale tasks under the newly selected project. Give each task load an identity and ignore superseded responses/errors. Cover out-of-order project loads and request creation/escaping/priority with deterministic offline tests. Run the Apporo unit plan with the isolated unit host; then verify real login and the facility workflow on simulator and available hardware once the review tenant is configured. Keep build 6 local until the required checks are complete, and preserve the owner's exclusion of company-stamped documents.

## Latest review check — 2026-11-02

Live App Store Connect, verified after full Chrome reload, now shows three messages. Apple replied on October 31 at 00:10 Asia/Taipei and maintained the 4.3 concern. Its reply cites binary similarities, features, overall design and user experience, and asks for unique content and functionality. It does not request company-stamped documents and does not grant approval or resolve the publishing relationship under 4.2.6. Build 1.0 (5) remains rejected with unresolved issues.

TestFlight still lists only builds 1 through 5; candidate build 6 is absent. Public App Store lookup returns no result in the eight intended territories. The Android public Google Play page remains accessible (HTTP 200). This check sent no additional reviewer message and submitted no binary. Evidence: receipts/apporo-platform-review-check-1102.json and receipts/apporo-platform-review-check-1102/.

## Why this change

The rejected App Store build shared much of the Odoo mobile client foundation with woowtech platform. The owner confirms that separate companies operate the two services in different regions and that the services are not identical. Keep Apporo platform as a separate product and listing, published under WOOW TECH's Apple developer account, following the existing Apporo aiot publisher arrangement. APPORO UNION INC. (California) is Apporo's brand and service provider; WOOW TECH CO., LTD. (Taiwan) is Apporo's contracted software development and maintenance partner and the seller on its current developer account. Apporo's listing targets building, facility, and building-automation customers in North America and Southeast Asia; woowtech platform is presented as WOOW TECH's general Odoo client. Document these operational differences without implying that the regions never overlap.

This branch adds an Apporo-only, native Facility Desk for building and facilities teams. It is an actual workflow inside the binary, not a change to colors, icons, or store copy alone.

## Implemented in this branch

- Apporo builds show a Facility Desk entry in the authenticated navigation bar. WOOW builds do not show it.
- The screen reads active Odoo Projects and recent tasks for the selected project (used as the customer's site workspace).
- A user can submit a facility request with a title, description, and standard/high priority. The app creates a `project.task` in the selected Odoo project and labels its title as a facility request.
- The screen uses the active account's stored session ID as an explicit HTTPS cookie. It does not use the shared cookie jar, so a second Odoo account on the same host cannot authorize the read or write.
- Task details are sent to and stored on the organization's Odoo server. The feature does not call an Apporo reporting service or a new third-party service.
- It requires Odoo Projects and the user's project/task read and create permissions. Existing Odoo screens remain available for customers without access.
- English, Traditional Chinese, and Simplified Chinese strings are included. The feature requests no new system permission.

## App Store impact and remaining 4.3 risk

App Store Connect's current Apporo description targets Apporo customers in North America and Southeast Asia who run buildings, facilities, and building-automation projects. The existing App Review notes identify APPORO UNION INC. (California) as Apporo's brand and service provider, and WOOW TECH CO., LTD. (Taiwan) as the developer and seller on the current account. The owner has confirmed that the companies operate distinct regional services and that those services are not identical. The public [woowtech platform listing](https://apps.apple.com/tw/app/woowtech-platform/id6814763046) describes a general mobile client for companies' self-hosted Odoo 18 Community servers. Apporo's [official product site](https://www.apporo.ai/products) describes building automation, FMS maintenance tickets, and asset lifecycle management. The published [Apporo aiot listing](https://apps.apple.com/tw/app/apporo-aiot/id6812538019) describes a companion for AP-1004S/AP-1005S building controllers, with dashboards, lighting/climate controls, live sensor status, and controller alerts. Apporo platform serves the Apporo organization's Odoo business workflow; Apporo aiot controls building systems; woowtech platform serves WOOW TECH's general Odoo customers.

The Facility Desk adds an Apporo-only workflow for selecting a site project, reviewing recent work, and creating a prioritized facilities request as an Odoo project task. This is a real Apporo-specific workflow in the candidate binary, not in rejected build 1.0 (5). It has only been compiled; it has not been exercised against a customer or review Odoo tenant. The iOS apps still share substantial Odoo client code, so Apple may view the separate bundle IDs as variants under 4.3(a). Separately, the current publisher arrangement remains exposed under 4.2.6: the listing identifies APPORO UNION INC. as the content/service provider while WOOW TECH submits from its own developer account.

The separate-listing case should document each company's legal name, region, service role, customer group, support/privacy contact, and actual workflows. The Apporo Facility Desk must be exercised in a real review Odoo environment. Apple's current [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) say apps created from a commercialized template or app-generation service should be submitted directly by the app's content provider. The response should establish the actual arrangement: WOOW TECH is Apporo's contracted software development and maintenance partner, responsible for engineering, release maintenance, and technical support; APPORO UNION INC. remains the brand, content, and service provider; and WOOW submits under its account by agreement, following the existing Apporo aiot arrangement. Explain that Apporo platform is implemented and maintained by WOOW engineers for this named Apporo service, rather than generated through a customer-facing app-generation service, while disclosing its substantial shared Odoo client foundation with woowtech platform. Ask Apple to assess whether it considers this managed custom-development relationship a 4.2.6 app-generation arrangement. The public Apporo aiot listing under WOOW TECH is useful evidence that the same publisher relationship is already in use, but it does not guarantee that Apple will reach the same result for Apporo platform's distinct 4.3/4.2.6 review.

## Company and service evidence map

| Company | Verified role and location | App/service described in current records | Evidence still needed |
|---|---|---|---|
| APPORO UNION INC. | California (El Monte); Apporo brand owner and Apporo service provider, per the existing App Review notes | Apporo platform serves building, facility, and building-automation customers in North America and Southeast Asia; Apporo aiot serves supported building controllers | Document concrete support responsibilities and Odoo/FMS workflows as evidence becomes available. Do not infer a separate legal Apporo entity for every territory. The owner excludes uploading company-stamped documents. |
| WOOW TECH CO., LTD. | Taiwan; Apple seller/developer and Apporo's software development and maintenance partner, as clarified by the owner | Publishes Apporo aiot and woowtech platform under its Apple account; woowtech platform is a general Odoo 18 Community client for WOOW TECH's customers | The owner-confirmed maintenance and publishing arrangement is described in the submitted clarification. Do not upload or promise company-stamped documents; disclose shared Odoo functionality and code. |

Keep company headquarters and customer territories as separate facts. Apporo's listed territories and WOOW's listed territories can overlap; the distinction is the separate operator and service relationship, not an unsupported claim of exclusive geography. Apporo aiot's public [App Store listing](https://apps.apple.com/tw/app/apporo-aiot/id6812538019) names WOOW TECH CO., LTD. as developer, providing a concrete precedent for the publisher model. This confirms the current relationship is already used for another Apporo product, but is not proof that Apple's review of Apporo platform must reach the same outcome.

## App Review reply submitted — 2026-10-30 17:28 Asia/Taipei

The owner explicitly requested submission of the previous written draft and excluded company-stamped documents. That instruction supersedes the earlier draft-only hold and any requirement in this plan to obtain or upload stamped corporate material before sending the clarification. Keep Apporo platform separate and retain WOOW TECH as publisher.

Submitted through the owner's logged-in Google Chrome to Apporo platform (Apple ID `6816445423`, bundle `com.apporo.odoo`), review submission `68131640-29ec-475c-a350-ca0ce45b691c`:

- A 1,382-character reply identifying APPORO UNION INC. as brand/service provider and WOOW TECH as development, maintenance, and publishing partner.
- One three-page PDF answering all nine questions. It discloses shared Odoo client implementation, limited beta records, third-party Odoo server content and standard Firebase SDK usage, the existing Apporo aiot publisher arrangement, and the fact that Facility Desk remains a local candidate feature.
- No company-stamped documents were uploaded or promised. No agreements, corporate records, or private customer records were attached.
- Corrected the old Apporo smart statement: live ASC shows 0.8.1 waiting for review, submitted October 30.

After full page reload, the message count is 2 (one Apple message and the new WOOW reply); the complete reply and PDF attachment remain present. The PDF downloaded back from Apple matches the submitted file's SHA-256: `9e33342e390a89f0078f096083379080d101bd09036fca6f86cfe52334cdb762`.

Exact submitted files and verification evidence are in `/Users/woowtech/.local/share/woowtech-smart/receipts/apporo-platform-review-reply-1030/`: `review-message.txt`, `review-clarification.txt`, `Apporo-platform-review-clarification-2026-10-30.pdf`, and `receipt.json`. The top-level receipt is `receipts/apporo-platform-apple-reply-1030.json` under the workspace root.

Apple has not replied or approved the app. Build 1.0 (5) remains rejected/unresolved; candidate 1.0 (6) is still local and was not uploaded or resubmitted in this action. The sent PDF is the authoritative external wording; do not resend the older draft or reintroduce its document promises.

## Current validation status — updated 2026-10-30

- Signed-in Firebase Console confirms the WOOW TECH account owns project `apporo-odoo-app` (“Apporo platform”). It already contains iOS apps `com.apporo.odoo` and `com.apporo.odoo.dev`, both on team `W4UWZ8NP2P`. Their matching GoogleService plist files are in the ignored local `BrandResources/Firebase/ApporoRelease/` and `ApporoDebug/` directories. The ignored `Config/ApporoFirebase.local.xcconfig` sets the verified project ID. Do not commit these local files.
- ApporoDebug and ApporoRelease simulator builds both succeed. The Release source audit initially failed because Xcode's script sandbox had not been granted the new Swift file as an input; `scripts/test_hook_audit_inputs.xcfilelist` now includes `FacilityDeskView.swift`, and the Release build/audit passes.
- A local App Store export exists at `/Users/woowtech/.local/share/woowtech-smart/artifacts/apporo-facility-desk-20261030/AppStoreExport/odoo.ipa`. It is version `1.0 (6)`, bundle `com.apporo.odoo`, signed with Apple Distribution and an App Store provisioning profile for the Apporo bundle; its packaged Firebase project and bundle IDs match. The IPA has not been uploaded.
- App Store Connect still shows build `1.0 (5)` rejected under 4.3.0. The review message cites 4.3(a), 4.3(b), and 4.2.6 and asks nine questions. Its existing Apporo listing says it serves building, facilities, and building-automation customers in North America and Southeast Asia; the existing woowtech platform listing describes a general Odoo 18 Community client. TestFlight shows build 5 with 1 internal invitation, 1 installation, 4 sessions, and 0 feedback; build 4 has 1 invitation, 1 installation, 5 sessions, and 0 feedback. There is no feedback example to claim or apply.
- Apporo aiot is also listed under the WOOW TECH developer account. Its public product page describes an AP-1004S/AP-1005S building-controller app for dashboards, device control, sensor state, and alerts. This helps explain the Apporo product suite: Apporo aiot controls building systems; Apporo platform provides the ERP/facilities work process. Live ASC now shows Apporo smart 0.8.1 waiting for review after its October 30 submission; the sent clarification reflects that status.
- The existing Apporo ASC review-notes source states that APPORO UNION INC. (California) owns the Apporo brand and provides the service, while WOOW TECH CO., LTD. (Taiwan) develops and publishes on its behalf under the WOOW account. The owner has clarified that the companies operate different regional services and that the services are not identical. The authorization was owner-confirmed. Per the owner, no company-stamped documents are to be uploaded; the clarification does not claim any executed document is attached.
- App Store Connect displays an updated Apple Developer Program agreement that the Account Holder must accept before updates/submissions, and a reminder to provide the trader status for EU distribution. These account-holder/legal actions are outstanding.
- The embedded browser had lost authentication, but the separate Google Chrome store profile remained authenticated. Chrome confirmed WOOW TECH as account and Apporo platform as target, and successfully submitted the reply and PDF. Do not infer Chrome logout from the embedded browser. Agreement/trader-status banners were not re-evaluated in this reply-only action.
- The new Facility Desk has compiled but has not been tested against a staging Odoo database, submitted through TestFlight, or exercised with the App Review account. The reviewer reply and clarification PDF have now been sent. No build upload, listing metadata update, or public release was made in this action.
- Build/archive/export logs are under `/Users/woowtech/.local/share/woowtech-smart/artifacts/apporo-facility-desk-20261030/`.

## Revised App Store description candidate

### English

Apporo platform brings your organization's Odoo ERP to iPhone and iPad, with a native Facility Desk for building and facilities teams. Review recent work by site project and submit a facility request with a priority directly to your organization's Odoo Projects workspace.

The Facility Desk requires the Odoo Projects app and permission to read and create project tasks. Requests are saved as tasks in the selected Odoo project. Other screens and records depend on the Odoo modules and permissions configured by your administrator.

The remaining sign-in, data, privacy, permission, and support sections should be carried forward only after checking that they remain accurate for the build being submitted. Do not replace the full current description with this excerpt.

### 繁體中文

Apporo platform 將組織的 Odoo ERP 帶到 iPhone 與 iPad，並為建築與設施團隊提供原生「設施工作台」。可依場域專案查看近期工作，並將附有優先級的設施服務請求直接送入組織的 Odoo「專案」工作區。

設施工作台需要 Odoo「專案」應用程式，以及讀取和建立專案任務的權限。服務請求會以任務形式儲存於所選 Odoo 專案。其他畫面與紀錄取決於管理員設定的 Odoo 模組和權限。

其餘登入、資料、隱私、權限及支援段落，須依實際送審 build 再確認後沿用。此處僅為新增功能的文案片段，不可直接取代現有完整描述。

## Required before another Apple submission

1. The Firebase client setup and signed build are ready locally. Keep the matching plists and project ID ignored; never substitute WOOW's Firebase app.
2. Complete the project-required unit/UI/device acceptance flow and verify project discovery, task reading, task creation, priority, localization, expired sessions, and same-host multi-account isolation on a dedicated staging Odoo database. No production Odoo writes have been used.
3. Seed the App Review tenant with Odoo Projects, a visible project and sample tasks, and a review account that can create tasks. Exercise the workflow with that account and capture genuine Apporo screenshots.
4. Apply the resulting TestFlight feedback, then update the existing listing description, screenshots, What's New, review notes, and privacy disclosures to match the tested build.
5. Obtain the Account Holder's acceptance of the updated developer agreement and complete the required trader-status declaration before attempting an App Store Connect submission.
6. Build a company/region/service matrix with evidence: APPORO UNION INC. / California / Apporo brand and service provider / North America and Southeast Asia customer segments; WOOW TECH CO., LTD. / Taiwan / contracted software development and maintenance partner, publisher under its own account / woowtech platform's general Odoo customer segment. Document any territory overlap and the concrete differences in customer workflow, service contract, support, and Odoo configuration.
7. The written clarification has been submitted using the owner-confirmed development/maintenance/publishing relationship and public Apporo aiot listing. Wait for Apple to identify any remaining evidence requirement. Do not upload or promise company-stamped documents. Apporo aiot approval does not guarantee platform approval.
8. Verify the Facility Desk against a dedicated review Odoo tenant, run the owner's required acceptance flow, seed a visible project and tasks, exercise the feature with the review account, and capture real screenshots/video. Only then upload the candidate build to TestFlight and gather actual feedback.
9. Reconcile the App Store listing, copyright line, support/privacy contacts, review notes, and submission account so all accurately identify Apporo Union as provider and WOOW's development/maintenance/publishing role. Resolve the WOOW Account Holder's developer-agreement acceptance and applicable trader-status requirement.
10. Keep Apporo platform as a separate listing under WOOW TECH. The requested reviewer reply and PDF are submitted and verified. Candidate build 1.0 (6) remains local; finish applicable build/test/account readiness before uploading or claiming the distinct workflow is verified. Do not treat the earlier draft-only hold as a blocker for the already authorized written clarification.
