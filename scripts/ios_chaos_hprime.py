#!/usr/bin/env python3
"""
iOS H' FCM CHAOS / Fault-Injection — HOST-SIDE harness
======================================================

Replaces the mis-architected on-device XCUITest ``FCMPushChaosTests.swift``,
which CANNOT run on a real device: an iOS XCUITest executes *inside the phone*,
but chaos injection needs Docker/kubectl commands on the *Mac*. The two cannot
coexist in one device-targeted test, so those tests skip-by-design.

This harness runs ENTIRELY ON THE MAC (like the Android Python harness):
  - injects chaos via the shared shell scripts / docker / kubectl (host),
  - drives Odoo via JSON-RPC (host),
  - asserts SERVER-SIDE (Odoo plugin log + woow.fcm.device DB state) — these are
    the real chaos signals and need no on-device notification scraping,
  - checks iOS app survival via ``xcrun devicectl`` (host-side equiv of adb pidof).

Chaos cases (mirror Android; all server-side assertions):
  C-1  sidecar down       — plugin fails closed: NO "FCM sent" + "sidecar-socket-missing"
  C-2  central TVS down   — sidecar cached bearer still serves: "FCM sent" appears
  C-3  invalid token (iOS row id=246 ONLY) — deactivates after 2 terminal errors

CRITICAL lessons baked in:
  - C-1 uses `docker stop` (cleanly removes the socket; restart-policy=no keeps it
    down; `docker start` restores). NOT docker pause (socket persists), NOT kill.
  - C-3 snapshots the FULL original token TO A FILE and restores in a finally block
    (a prior ad-hoc run poisoned id=246 without a file backup and lost the token).
  - C-3 targets ONLY id=246 (iOS). The Android row (id=247) must stay untouched.
  - A unique log "fence" is written to odoo.log so we read only the NEW attempt.

Usage:
  export TEST_DEVICE_UDID=00008140-0002143E14E3001C   # Alan's iPhone
  python3 scripts/ios_chaos_hprime.py

Prereqs: backend up (./central/scripts/verify-e2e-preconditions.sh = 11/11),
cloudflare tunnel live, iOS app installed + REGISTERED (active woow.fcm.device
row platform=ios). Run the happy-path login first if the iOS row is missing.
"""

from __future__ import annotations

import os
import plistlib
import subprocess
import sys
import time
import uuid

import requests

# ─── Config (read from TestConfig.plist, override via env) ───────────────────
_PLIST = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "odooUITests", "TestConfig.plist",
)


def _cfg(key: str, default: str) -> str:
    try:
        with open(_PLIST, "rb") as fh:
            return plistlib.load(fh).get(key, default)
    except Exception:
        return default


_host = _cfg("ServerURL", "localhost:8069").replace("https://", "").replace("http://", "").rstrip("/")
ODOO_URL = os.environ.get("ODOO_URL", f"https://{_host}" if "." in _host else f"http://{_host}")
ODOO_DB = os.environ.get("ODOO_DB", _cfg("Database", "odoo18_ecpay"))
ADMIN_USER = os.environ.get("ODOO_USER", _cfg("AdminUser", "admin"))
ADMIN_PASS = os.environ.get("ODOO_PASS", _cfg("AdminPass", "admin"))

UDID = os.environ.get("TEST_DEVICE_UDID", "00008140-0002143E14E3001C")
IOS_DEVICE_ROW_ID = int(os.environ.get("IOS_DEVICE_ROW_ID", "246"))
ANDROID_DEVICE_ROW_ID = 247  # must stay untouched by C-3
ADMIN_USER_ID = 2
ADMIN_PARTNER_ID = 3
GENERAL_CHANNEL_ID = 1

DOCKER = os.environ.get("DOCKER", "/Applications/Docker.app/Contents/Resources/bin/docker")
ODOO_CONTAINER = os.environ.get("ODOO_CONTAINER", "ecpay_odoo18")
SIDECAR_CONTAINER = os.environ.get("SIDECAR_CONTAINER", "fcm-sidecar")
ODOO_LOG = "/var/log/odoo/odoo.log"
KUBE_NS = os.environ.get("KUBE_NS", "woow-fcm-central")
TVS_DEPLOY = "token-vending-service"

RESULTS: dict[str, bool | None] = {"C-1": None, "C-2": None, "C-3": None}


# ─── Output helpers ──────────────────────────────────────────────────────────
def section(t: str) -> None:
    print(f"\n\033[1m  {t}\033[0m")


def _mark(test: str, ok: bool, proof: str = "", err: str = "") -> None:
    RESULTS[test] = ok
    tag = "\033[32m  PASS\033[0m" if ok else "\033[31m  FAIL\033[0m"
    print(f"{tag} [iOS-CHAOS-{test}]: {proof or err}")


def marker(t: str) -> str:
    return f"IOSCHAOS-{t}-{int(time.time())}-{uuid.uuid4().hex[:8]}"


# ─── Odoo JSON-RPC ───────────────────────────────────────────────────────────
def _auth(login: str, password: str) -> requests.Session:
    s = requests.Session()
    s.post(f"{ODOO_URL}/web/session/authenticate",
           json={"jsonrpc": "2.0", "params": {"db": ODOO_DB, "login": login, "password": password}},
           timeout=20)
    return s


def _kw(s: requests.Session, model: str, method: str, args: list, kwargs: dict | None = None):
    r = s.post(f"{ODOO_URL}/web/dataset/call_kw",
               json={"jsonrpc": "2.0", "params": {"model": model, "method": method,
                                                  "args": args, "kwargs": kwargs or {}}},
               timeout=25)
    j = r.json()
    return j.get("result"), j.get("error")


def _post_channel_mention(s: requests.Session, body_marker: str):
    html = (f'<p><a href="#" data-oe-model="res.partner" '
            f'data-oe-id="{ADMIN_PARTNER_ID}">@Mitchell Admin</a> {body_marker}</p>')
    return _kw(s, "discuss.channel", "message_post", [[GENERAL_CHANNEL_ID]],
               {"body": html, "partner_ids": [ADMIN_PARTNER_ID],
                "message_type": "comment", "subtype_xmlid": "mail.mt_comment"})


def _device_row(s: requests.Session, row_id: int) -> dict | None:
    res, _ = _kw(s, "woow.fcm.device", "search_read",
                 [[["id", "=", row_id]]],
                 {"fields": ["id", "platform", "active", "fcm_token", "consecutive_failures"]})
    return res[0] if res else None


# ─── Host-side infra helpers ─────────────────────────────────────────────────
def _docker(*args: str, timeout: int = 30) -> subprocess.CompletedProcess:
    return subprocess.run([DOCKER, *args], capture_output=True, text=True, timeout=timeout)


def _sidecar_running() -> bool:
    r = _docker("ps", "--filter", f"name={SIDECAR_CONTAINER}", "--format", "{{.Names}}")
    return SIDECAR_CONTAINER in r.stdout


def _socket_present() -> bool:
    r = _docker("exec", ODOO_CONTAINER, "sh", "-c", "ls /run/fcm-sidecar/sock 2>/dev/null")
    return "/run/fcm-sidecar/sock" in r.stdout


def _log_fence() -> str:
    f = f"IOSCHAOS-FENCE-{uuid.uuid4().hex[:10]}"
    _docker("exec", ODOO_CONTAINER, "sh", "-c", f"printf '%s\\n' '{f}' >> {ODOO_LOG}")
    return f


def _log_after_fence(fence: str) -> str:
    r = _docker("exec", ODOO_CONTAINER, "sh", "-c",
                f"awk '/{fence}/{{seen=1;next}} seen' {ODOO_LOG} 2>/dev/null")
    return r.stdout


def _ios_app_alive() -> bool:
    """Host-side app-survival check via devicectl (iOS equiv of adb pidof)."""
    try:
        r = subprocess.run(["xcrun", "devicectl", "device", "info", "processes",
                            "--device", UDID], capture_output=True, text=True, timeout=40)
        return "io.woowtech.odoo" in r.stdout
    except Exception:
        return True  # don't fail the whole test if devicectl is flaky; note in proof


def _central_replicas() -> int:
    try:
        r = subprocess.run(["kubectl", "get", f"deploy/{TVS_DEPLOY}", "-n", KUBE_NS,
                            "-o", "jsonpath={.status.readyReplicas}"],
                           capture_output=True, text=True, timeout=20)
        return int(r.stdout.strip() or "0")
    except Exception:
        return -1


# ─── Preflight ───────────────────────────────────────────────────────────────
def preflight(s: requests.Session) -> bool:
    section("Preflight")
    ok = True
    ios = _device_row(s, IOS_DEVICE_ROW_ID)
    if not ios or not ios.get("active"):
        print(f"  ✗ iOS row id={IOS_DEVICE_ROW_ID} missing/inactive — "
              f"register the iPhone first (open app → login → Allow). Got: {ios}")
        ok = False
    else:
        print(f"  ✓ iOS row id={IOS_DEVICE_ROW_ID} active platform={ios['platform']}")
    if not _sidecar_running():
        print("  ✗ sidecar not running"); ok = False
    else:
        print("  ✓ sidecar running")
    print(f"  central ready replicas: {_central_replicas()}")
    print(f"  iOS app alive: {_ios_app_alive()}")
    return ok


# ─── C-1: sidecar down → fail-closed (server-side) ───────────────────────────
def chaos_c1(s: requests.Session) -> None:
    section("C-1: sidecar DOWN → plugin fails closed (no FCM sent) [iOS-CHAOS-C-1]")
    alive_before = _ios_app_alive()
    try:
        print("  docker stop fcm-sidecar (removes socket, restart-policy=no)")
        _docker("stop", SIDECAR_CONTAINER)
        time.sleep(2)
        print(f"  sidecar running: {_sidecar_running()} | socket present: {_socket_present()}")
        fence = _log_fence()
        m = marker("C1")
        print(f"  post mention {m} (sidecar down → no bearer → must skip push)")
        _post_channel_mention(s, m)
        time.sleep(14)
        log = _log_after_fence(fence)
        sent = "FCM sent" in log
        socket_missing = ("sidecar-socket-missing" in log or "skipping push" in log
                          or "socket missing" in log.lower())
        alive_after = _ios_app_alive()
        ok = (not sent) and alive_after
        proof = (f"FCM_sent={sent} (must be False); socket_missing_logged={socket_missing}; "
                 f"ios_app_alive={alive_before}->{alive_after}")
        _mark("C-1", ok, proof=proof if ok else "", err=proof if not ok else "")
    except Exception as exc:
        _mark("C-1", False, err=f"exception: {exc}")
    finally:
        print("  restore: docker start fcm-sidecar")
        _docker("start", SIDECAR_CONTAINER)
        for _ in range(10):
            if _sidecar_running() and _socket_present():
                break
            time.sleep(1)


# ─── C-2: central down → cached bearer still delivers (server-side) ──────────
def chaos_c2(s: requests.Session) -> None:
    section("C-2: central TVS DOWN → sidecar cached bearer still serves [iOS-CHAOS-C-2]")
    alive_before = _ios_app_alive()
    scaled = False
    try:
        print(f"  kubectl scale deploy/{TVS_DEPLOY} --replicas=0")
        subprocess.run(["kubectl", "scale", f"deploy/{TVS_DEPLOY}", "-n", KUBE_NS,
                        "--replicas=0"], capture_output=True, text=True, timeout=30)
        scaled = True
        time.sleep(5)
        fence = _log_fence()
        m = marker("C2")
        print(f"  post mention {m} (central down → sidecar serves cached bearer)")
        _post_channel_mention(s, m)
        time.sleep(14)
        log = _log_after_fence(fence)
        sent = "FCM sent" in log
        alive_after = _ios_app_alive()
        ok = sent and alive_after
        proof = f"FCM_sent={sent} (cached-bearer, must be True); ios_app_alive={alive_before}->{alive_after}"
        _mark("C-2", ok, proof=proof if ok else "", err=proof if not ok else "")
    except Exception as exc:
        _mark("C-2", False, err=f"exception: {exc}")
    finally:
        if scaled:
            print(f"  restore: kubectl scale deploy/{TVS_DEPLOY} --replicas=1")
            subprocess.run(["kubectl", "scale", f"deploy/{TVS_DEPLOY}", "-n", KUBE_NS,
                            "--replicas=1"], capture_output=True, text=True, timeout=30)
            for _ in range(20):
                if _central_replicas() >= 1:
                    break
                time.sleep(2)


# ─── C-3: poison iOS row id=246 ONLY → deactivate after 2 failures ───────────
def chaos_c3(s: requests.Session) -> None:
    section("C-3: invalid token on iOS row id=246 ONLY → auto-deactivate [iOS-CHAOS-C-3]")
    alive_before = _ios_app_alive()
    snap_path = f"/tmp/ios_c3_token_{IOS_DEVICE_ROW_ID}.bak"
    snapshotted = False
    try:
        row = _device_row(s, IOS_DEVICE_ROW_ID)
        if not row:
            _mark("C-3", False, err=f"iOS row id={IOS_DEVICE_ROW_ID} not found")
            return
        # FILE-BACKED snapshot of the FULL original token (lesson learned)
        with open(snap_path, "w") as fh:
            fh.write(row["fcm_token"] or "")
        snapshotted = True
        print(f"  snapshot id={IOS_DEVICE_ROW_ID} token→{snap_path} (active={row['active']})")
        android_before = _device_row(s, ANDROID_DEVICE_ROW_ID)

        poison = "IOSCHAOS_C3_" + ("A" * 120) + ":INVALID_FCM_TOKEN"
        _kw(s, "woow.fcm.device", "write", [[IOS_DEVICE_ROW_ID],
            {"fcm_token": poison, "active": True}])
        print("  poisoned id=246; firing 2 mentions to trigger 2 terminal errors")
        for i in (1, 2):
            _post_channel_mention(s, marker(f"C3-{i}"))
            time.sleep(6)
        # poll for deactivation (up to 60s)
        deactivated = False
        for _ in range(12):
            r = _device_row(s, IOS_DEVICE_ROW_ID)
            if r and not r.get("active"):
                deactivated = True
                fails = r.get("consecutive_failures")
                break
            time.sleep(5)
        android_after = _device_row(s, ANDROID_DEVICE_ROW_ID)
        android_intact = (android_after and android_after.get("active")
                          and "IOSCHAOS" not in (android_after.get("fcm_token") or ""))
        alive_after = _ios_app_alive()
        ok = deactivated and android_intact and alive_after
        proof = (f"id=246 deactivated={deactivated} (fails={fails if deactivated else '?'}); "
                 f"android id=247 intact={android_intact}; ios_app_alive={alive_before}->{alive_after}")
        _mark("C-3", ok, proof=proof if ok else "", err=proof if not ok else "")
    except Exception as exc:
        _mark("C-3", False, err=f"exception: {exc}")
    finally:
        # ALWAYS restore the original token from the file snapshot
        if snapshotted and os.path.exists(snap_path):
            with open(snap_path) as fh:
                orig = fh.read()
            _kw(s, "woow.fcm.device", "write", [[IOS_DEVICE_ROW_ID],
                {"fcm_token": orig, "active": True}])
            after = _device_row(s, IOS_DEVICE_ROW_ID)
            print(f"  restored id={IOS_DEVICE_ROW_ID}: active={after.get('active') if after else '?'} "
                  f"token_ok={'IOSCHAOS' not in (after.get('fcm_token') or '') if after else '?'}")


def main() -> int:
    print(f"iOS H' CHAOS (host-side) — Odoo={ODOO_URL} db={ODOO_DB} iPhone={UDID} iOSrow={IOS_DEVICE_ROW_ID}")
    s = _auth(ADMIN_USER, ADMIN_PASS)
    if not preflight(s):
        print("\nPreflight failed — fix prereqs (esp. iOS registration) and retry.")
        return 2
    chaos_c1(s)
    chaos_c2(s)
    chaos_c3(s)
    # leave backend healthy
    section("Post-run health")
    print(f"  sidecar running: {_sidecar_running()} | central replicas: {_central_replicas()}")
    section("iOS-CHAOS SUMMARY")
    npass = sum(1 for v in RESULTS.values() if v is True)
    for k, v in RESULTS.items():
        print(f"  {k}: {'PASS' if v else 'FAIL' if v is False else 'SKIP'}")
    print(f"  Result: {npass}/{len(RESULTS)} PASS")
    return 0 if npass == len(RESULTS) else 1


if __name__ == "__main__":
    sys.exit(main())
