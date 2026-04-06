# Test Environment Setup Guide

**Date:** 2026-04-06
**Purpose:** Document the steps to prepare the testing environment for XCUITests.

---

## Prerequisites

- Docker Desktop running
- `cloudflared` installed (`brew install cloudflared`)
- Xcode with iOS Simulator
- Odoo 18 Docker container (`ecpay_odoo18`)

---

## Step 1: Start the Odoo Server (Docker)

The Odoo server runs as a Docker container with PostgreSQL.

```bash
# Check if containers are running
docker ps | grep ecpay_odoo18

# If not running, start them
cd /path/to/deployment && docker compose up -d

# Verify health
docker ps --format "table {{.Names}}\t{{.Status}}"
# Expected:
#   ecpay_odoo18       Up X minutes (healthy)
#   ecpay_odoo18_db    Up X minutes (healthy)

# Verify Odoo responds
curl -s -o /dev/null -w "%{http_code}" http://localhost:8069/web/login
# Expected: 200
```

**Ports:**
- Odoo: `localhost:8069` (HTTP)
- PostgreSQL: `localhost:5433`

---

## Step 2: Start Cloudflare Tunnel (HTTPS for iOS)

The iOS app enforces HTTPS (`OdooAPIClient` rejects `http://`). A Cloudflare quick tunnel
provides a temporary HTTPS URL for the local Odoo server.

```bash
cloudflared tunnel --url http://localhost:8069
```

**Output (look for the URL):**
```
INF +----------------------------+
INF |  Your quick Tunnel has been created! Visit it at:
INF |  https://RANDOM-WORDS.trycloudflare.com
INF +----------------------------+
```

**Important:** The tunnel URL changes every time you restart `cloudflared`. After getting
a new URL, update `TestConfig.plist`:

```xml
<key>ServerURL</key>
<string>NEW-TUNNEL-URL-HERE.trycloudflare.com</string>
```

**Verify tunnel works:**
```bash
TUNNEL_URL="https://YOUR-TUNNEL.trycloudflare.com"
curl -s -o /dev/null -w "%{http_code}" "$TUNNEL_URL/web/login"
# Expected: 200
```

---

## Step 3: Create Test Accounts on Odoo

Two dedicated test accounts are needed for XCUITests:

| Account | Login | Password | Purpose |
|---------|-------|----------|---------|
| Primary | `xctest@woowtech.com` | `XCTest2026!` | All login-dependent E2E tests |
| Secondary | `xctest2@woowtech.com` | `XCTest2026!` | Multi-account switch test (UX-68) |

### Create via curl (one-time setup)

```bash
COOKIE_JAR=$(mktemp)

# Authenticate as admin
curl -s -c "$COOKIE_JAR" -X POST http://localhost:8069/web/session/authenticate \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"call","params":{
    "db":"odoo18_ecpay","login":"admin","password":"admin"
  }}' > /dev/null

# Create primary test user
curl -s -b "$COOKIE_JAR" -X POST http://localhost:8069/web/dataset/call_kw \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":2,"method":"call","params":{
    "model":"res.users","method":"create",
    "args":[[{"login":"xctest@woowtech.com","name":"XCTest User",
              "password":"XCTest2026!","groups_id":[[4,1]]}]],
    "kwargs":{}}}'

# Create secondary test user
curl -s -b "$COOKIE_JAR" -X POST http://localhost:8069/web/dataset/call_kw \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":3,"method":"call","params":{
    "model":"res.users","method":"create",
    "args":[[{"login":"xctest2@woowtech.com","name":"XCTest User 2",
              "password":"XCTest2026!","groups_id":[[4,1]]}]],
    "kwargs":{}}}'

rm -f "$COOKIE_JAR"
```

### Verify accounts work

```bash
# Test primary account via tunnel
curl -s -X POST "$TUNNEL_URL/web/session/authenticate" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"call","params":{
    "db":"odoo18_ecpay","login":"xctest@woowtech.com","password":"XCTest2026!"
  }}' | python3 -c "import sys,json; r=json.load(sys.stdin); print('UID:', r['result']['uid'])"
# Expected: UID: 641 (or similar positive number)

# Test secondary account
curl -s -X POST "$TUNNEL_URL/web/session/authenticate" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"call","params":{
    "db":"odoo18_ecpay","login":"xctest2@woowtech.com","password":"XCTest2026!"
  }}' | python3 -c "import sys,json; r=json.load(sys.stdin); print('UID:', r['result']['uid'])"
# Expected: UID: 642 (or similar positive number)
```

---

## Step 4: Update TestConfig.plist

After getting the tunnel URL and creating accounts, update `odooUITests/TestConfig.plist`:

```xml
<key>ServerURL</key>
<string>YOUR-TUNNEL.trycloudflare.com</string>
<key>Database</key>
<string>odoo18_ecpay</string>
<key>AdminUser</key>
<string>admin</string>
<key>AdminPass</key>
<string>admin</string>
<key>TestUser</key>
<string>xctest@woowtech.com</string>
<key>TestPass</key>
<string>XCTest2026!</string>
<key>SecondUser</key>
<string>xctest2@woowtech.com</string>
<key>SecondPass</key>
<string>XCTest2026!</string>
```

---

## Step 5: Run XCUITests

### From Xcode
1. Open `odoo.xcodeproj`
2. Select `odooUITests` scheme
3. Choose iPhone 16 Pro simulator (iOS 18.x)
4. `Cmd+U` to run all tests

### From Command Line
```bash
xcodebuild test \
  -project odoo.xcodeproj \
  -scheme odoo \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:odooUITests/E2E_WebViewTests \
  -only-testing:odooUITests/E2E_BiometricPINTests \
  -only-testing:odooUITests/E2E_LoginAccountTests \
  -only-testing:odooUITests/E2E_PINLockoutTests
```

---

## App Debug Hooks (Launch Arguments)

These hooks are available in `#if DEBUG` builds to set deterministic test state:

| Argument | Value | Effect |
|----------|-------|--------|
| `-ResetAppState` | (flag only) | Clears Keychain + Core Data + cookies (first-launch state) |
| `-SetTestPIN` | `1234` | Hashes and stores a 4-digit PIN |
| `-AppLockEnabled` | `YES` or `NO` | Forces app lock on or off |
| `-ResetPINLockout` | `YES` | Clears failed PIN attempts and lockout timer |
| `-AppleLanguages` | `(en)` | Forces English locale |

---

## Troubleshooting

### Tunnel URL expired
Cloudflare quick tunnels are temporary. Restart `cloudflared tunnel --url http://localhost:8069`
and update `TestConfig.plist` with the new URL.

### Test accounts already exist
If you get an error creating accounts, they may already exist. Search first:
```bash
curl -s -b "$COOKIE_JAR" -X POST http://localhost:8069/web/dataset/call_kw \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"call","params":{
    "model":"res.users","method":"search_read",
    "args":[[["login","ilike","xctest"]]],
    "kwargs":{"fields":["login","name","id"]}}}'
```

### Tests skip with "No logged-in account"
Ensure TestConfig.plist has the correct tunnel URL and test credentials. The test
calls `loginWithTestCredentials()` which navigates the UI to log in.

### Docker container unhealthy
```bash
docker logs ecpay_odoo18 --tail 20
docker restart ecpay_odoo18
```

---

## Current Environment (2026-04-06)

| Component | Value |
|-----------|-------|
| Odoo Docker | `ecpay_odoo18` (healthy, port 8069) |
| PostgreSQL | `ecpay_odoo18_db` (healthy, port 5433) |
| Database | `odoo18_ecpay` |
| Tunnel URL | `photography-bool-charlotte-step.trycloudflare.com` |
| Primary test user | `xctest@woowtech.com` (UID 641) |
| Secondary test user | `xctest2@woowtech.com` (UID 642) |
| Admin | `admin` / `admin` (UID 2) |
