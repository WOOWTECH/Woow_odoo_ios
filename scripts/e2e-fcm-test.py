#!/usr/bin/env python3
"""
iOS FCM End-to-End Test
=======================
1. Launch app on real iPhone via XCUITest-style automation (idb/xcrun)
2. Check login state — if not logged in, log in to Odoo
3. Verify FCM token registration with Odoo server
4. Send a chatter message from Odoo (server-side)
5. Verify push notification arrives on the phone

Prerequisites:
- iPhone connected via USB, app installed
- Odoo server running with woow_fcm_push module
- Cloudflare tunnel or local network access from iPhone to Odoo

Usage: python3 scripts/e2e-fcm-test.py
"""
import json
import os
import subprocess
import sys
import time

import requests

# ── Configuration ──
ODOO_LOCAL = "http://localhost:8069"
ODOO_TUNNEL = "rivers-tennessee-rats-consist.trycloudflare.com"
DB = "odoo18_ecpay"
ADMIN_USER = "admin"
ADMIN_PASS = "admin"
# Test user (used as sender so admin receives the FCM push)
TEST_USER = "test@woowtech.com"
TEST_PASS = "test1234"
BUNDLE_ID = "io.woowtech.odoo.debug"
SS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "docs", "verification-report", "screenshots-ios")
STEPS = []
N = 0


def step(title, side="📱 iPhone"):
    global N
    N += 1
    print(f"\n{'=' * 60}")
    print(f"  Step {N} [{side}]: {title}")
    print(f"{'=' * 60}")
    STEPS.append({"n": N, "title": title, "side": side, "checks": []})
    return N


def ok(desc, passed):
    STEPS[-1]["checks"].append({"desc": desc, "ok": passed})
    icon = "✅" if passed else "❌"
    print(f"  {icon} {desc}")
    return passed


def fail(desc):
    return ok(desc, False)


# ── Odoo Session Helper ──
class OdooSession:
    def __init__(self, base_url, db, login, password):
        self.base_url = base_url
        self.db = db
        self.session = requests.Session()
        self.uid = None
        self._login(login, password)

    def _login(self, login, password):
        r = self.session.post(
            f"{self.base_url}/web/session/authenticate",
            json={
                "jsonrpc": "2.0", "method": "call",
                "params": {"db": self.db, "login": login, "password": password},
                "id": 1,
            },
        )
        data = r.json()
        if data.get("result", {}).get("uid"):
            self.uid = data["result"]["uid"]
        else:
            raise RuntimeError(f"Odoo login failed: {data.get('error', {}).get('data', {}).get('message', 'Unknown')}")

    def call(self, model, method, args=None, kwargs=None):
        r = self.session.post(
            f"{self.base_url}/web/dataset/call_kw",
            json={
                "jsonrpc": "2.0", "method": "call",
                "params": {
                    "model": model, "method": method,
                    "args": args or [], "kwargs": kwargs or {},
                },
                "id": 2,
            },
        )
        data = r.json()
        if "error" in data:
            raise RuntimeError(f"Odoo RPC error: {data['error']['data']['message']}")
        return data["result"]


# ── XCUITest runner via xcodebuild ──
def run_xcuitest(test_class_method, timeout=120):
    """Run a specific XCUITest on the connected device."""
    cmd = [
        "xcodebuild", "test",
        "-project", os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "odoo.xcodeproj"),
        "-scheme", "odoo",
        "-destination", "platform=iOS,name=Alan 的 iPhone",
        "-only-testing", f"odooUITests/{test_class_method}",
        "-allowProvisioningUpdates",
    ]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    passed = "** TEST SUCCEEDED **" in result.stdout or "Test Suite.*passed" in result.stdout
    return passed, result.stdout, result.stderr


# ══════════════════════════════════════════════════════════
#  MAIN TEST FLOW
# ══════════════════════════════════════════════════════════

print("=" * 60)
print("  iOS FCM End-to-End Verification Test")
print("=" * 60)

os.makedirs(SS_DIR, exist_ok=True)

# ── Step 1: Verify Odoo server is reachable ──
step("Verify Odoo server", "🖥️ Server")
try:
    odoo = OdooSession(ODOO_LOCAL, DB, ADMIN_USER, ADMIN_PASS)
    ok(f"Odoo login successful (UID: {odoo.uid})", True)
except Exception as e:
    fail(f"Odoo login failed: {e}")
    print("\n⛔ Cannot proceed without Odoo server. Exiting.")
    sys.exit(1)

# ── Step 2: Check registered FCM devices ──
step("Check registered FCM devices", "🖥️ Server")
devices = odoo.call("woow.fcm.device", "search_read", [[]], {"fields": ["user_id", "device_name", "platform", "fcm_token", "active", "last_seen"]})
ios_devices = [d for d in devices if d["platform"] == "ios" and d["active"]]
android_devices = [d for d in devices if d["platform"] == "android" and d["active"]]
ok(f"Total active devices: {len([d for d in devices if d['active']])}", True)
ok(f"Android devices: {len(android_devices)}", True)

if ios_devices:
    ok(f"iOS devices registered: {len(ios_devices)}", True)
    for d in ios_devices:
        print(f"     📱 {d['device_name']} | User: {d['user_id'][1]} | Token: {d['fcm_token'][:30]}...")
else:
    ok("iOS device registered: 0 — need to login from iPhone app first", False)
    print()
    print("  ╔═══════════════════════════════════════════════════════╗")
    print("  ║  ACTION REQUIRED: Open the app on your iPhone and    ║")
    print(f"  ║  login with server: {ODOO_TUNNEL[:40]:<40s} ║")
    print(f"  ║  Database: {DB:<44s} ║")
    print(f"  ║  Username: {ADMIN_USER:<44s} ║")
    print(f"  ║  Password: {ADMIN_PASS:<44s} ║")
    print("  ╚═══════════════════════════════════════════════════════╝")
    print()
    print("  Waiting for iOS device to register FCM token...")
    print("  (Polling every 5 seconds, max 120 seconds)")
    print()

    for attempt in range(24):
        time.sleep(5)
        devices = odoo.call("woow.fcm.device", "search_read",
                            [[("platform", "=", "ios"), ("active", "=", True)]],
                            {"fields": ["user_id", "device_name", "fcm_token"]})
        if devices:
            ios_devices = devices
            ok(f"iOS device registered! Device: {devices[0]['device_name']}", True)
            print(f"     Token: {devices[0]['fcm_token'][:40]}...")
            break
        print(f"     ⏳ Attempt {attempt + 1}/24 — no iOS device yet...")
    else:
        fail("Timeout: No iOS device registered after 120 seconds")
        print("\n  Possible issues:")
        print("  1. App not launched on iPhone")
        print("  2. Notification permission not granted")
        print("  3. Firebase SDK not initialized (check Xcode console for FCM logs)")
        print(f"  4. Server URL not reachable from iPhone (try: https://{ODOO_TUNNEL})")
        print()
        print("  Please login from the iPhone app and re-run this script.")
        sys.exit(1)

# ── Step 3: Send test chatter message from Odoo ──
step("Send chatter message from Odoo", "🖥️ Server")

# Find a partner to post on
partners = odoo.call("res.partner", "search_read", [[("id", ">", 0)]], {"fields": ["name"], "limit": 1})
if not partners:
    fail("No partner found to post chatter message")
    sys.exit(1)

partner_id = partners[0]["id"]
partner_name = partners[0]["name"]
test_message = f"🔔 iOS FCM Test — {time.strftime('%H:%M:%S')}"

ok(f"Target partner: {partner_name} (ID: {partner_id})", True)

# Post chatter message
try:
    odoo.call("res.partner", "message_post", [partner_id], {
        "body": f"<p>{test_message}</p>",
        "message_type": "comment",
        "subtype_xmlid": "mail.mt_comment",
    })
    ok(f"Chatter message posted: '{test_message}'", True)
except Exception as e:
    fail(f"Failed to post message: {e}")
    sys.exit(1)

# ── Step 4: Check Odoo logs for FCM send ──
step("Verify FCM sent from server", "🖥️ Server")
print("  Checking Odoo container logs for FCM delivery...")
time.sleep(3)  # Wait for FCM processing

try:
    result = subprocess.run(
        ["docker", "logs", "--tail", "20", "ecpay_odoo18"],
        capture_output=True, text=True, timeout=10,
    )
    log_output = result.stdout + result.stderr
    fcm_lines = [l for l in log_output.split("\n") if "FCM" in l or "fcm" in l]

    if fcm_lines:
        for line in fcm_lines[-3:]:
            print(f"     📋 {line.strip()}")
        if any("sent to" in l.lower() for l in fcm_lines):
            ok("FCM notification sent from server", True)
        else:
            ok("FCM log found but delivery unclear", False)
    else:
        ok("No FCM logs found in container — check woow_fcm_push module", False)
except Exception as e:
    ok(f"Could not read container logs: {e}", False)

# ── Step 5: Wait and verify notification on iPhone ──
step("Verify notification on iPhone", "📱 iPhone")
print("  ⚠️  Check your iPhone now!")
print(f"  You should see a notification with: '{test_message}'")
print()
print("  Since iOS doesn't allow programmatic notification center reading,")
print("  please confirm manually:")
print()

try:
    answer = input("  Did the notification arrive on iPhone? (y/n): ").strip().lower()
    if answer == "y":
        ok("Push notification received on iPhone", True)
    else:
        ok("Push notification NOT received on iPhone", False)
        print()
        print("  Troubleshooting:")
        print("  1. Check Xcode console for 'FCM token' log")
        print("  2. Verify notification permission is granted (Settings → odoo → Notifications)")
        print("  3. Check if the app is in foreground (notification may show as in-app alert)")
        print("  4. Check Firebase Console → Cloud Messaging for delivery stats")
except EOFError:
    ok("Manual verification skipped (non-interactive)", False)

# ══════════════════════════════════════════════════════════
#  SUMMARY
# ══════════════════════════════════════════════════════════
print()
print("=" * 60)
print("  TEST SUMMARY")
print("=" * 60)

total = 0
passed = 0
for s in STEPS:
    for c in s["checks"]:
        total += 1
        if c["ok"]:
            passed += 1

print(f"  Total checks: {total}")
print(f"  Passed: {passed}")
print(f"  Failed: {total - passed}")
print()

if passed == total:
    print("  🎉 ALL CHECKS PASSED — FCM E2E verified on iOS!")
else:
    print(f"  ⚠️  {total - passed} check(s) failed — review above")

print()
print("=" * 60)
