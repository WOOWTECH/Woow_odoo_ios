# Repeated push navigation

The coordinator remembers the last URL for its lifetime. A second notification for
the same conversation is therefore ignored after the user returns to Inbox.

Use a per-intake event ID from PendingDeepLink through MainViewModel and the
WebView, so repeated SwiftUI updates of one event navigate once while a new event
with the same URL navigates again. Consume only the event that was applied; an
older scheduled consume must not clear a newer notification. Preserve account
binding, existing manager TTL behavior, URL validation and the initial account-load gate.

Scope excludes session self-heal changes, build numbers, release artifacts,
devices, upload and deployment. Known follow-up: warm navigation currently
consumes before navigation success, and session-expiry recovery can replace it
with a base-page load. This change does not claim to repair that separate risk.
Another pre-existing limitation is that TTL is checked during manager consumption,
after navigation has already been requested. An expired event may therefore still
navigate; this change does not add a pre-navigation TTL gate.

Use the existing Apporo unit-test simulator and guarded unit host, heavy.sh with
an apporo label, one build job, and at least 3 GiB internal disk free. Independent
review follows passing focused tests.
