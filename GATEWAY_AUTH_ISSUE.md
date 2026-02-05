# Gateway Authentication Issue on Railway

## Problem Summary

The Clawdbot gateway is running on Railway but rejects all WebSocket connections with error `1008: pairing required`, even when:
1. The correct gateway token is provided in the URL (`?token=xxx`)
2. The `trustedProxies` configuration was added to trust Railway's internal network

## Observed Behavior

### What Works
- Gateway starts successfully
- Listens on `ws://0.0.0.0:18789`
- Telegram provider connects and receives messages
- Token is correctly written to config file
- Config shows: `"auth": { "token": "44fcc7ad31ac4a1edfc0583cb33b09c93e9da2d491ef3a83412bffd0c9829d48" }`

### What Fails
- Web UI shows "disconnected (1008): pairing required"
- All WebSocket connections are rejected
- Token in URL is not being accepted

### Log Evidence

```
[ws] Proxy headers detected from untrusted address. Connection will not be treated as local.
Configure gateway.trustedProxies to restore local client detection behind your proxy.

[ws] closed before connect conn=xxx remote=100.64.0.x fwd=92.247.56.32
origin=https://moltworker-production.up.railway.app code=1008 reason=pairing required
```

## Architecture

```
User Browser (92.247.56.32)
    ↓
Railway Load Balancer (adds X-Forwarded-For header)
    ↓
Railway Internal Proxy (100.64.0.x - CGNAT range)
    ↓
Clawdbot Container (listening on 0.0.0.0:18789)
```

## Theories

### Theory 1: trustedProxies Config Path is Wrong

**Hypothesis**: The config path `gateway.trustedProxies` might not be recognized by clawdbot. The actual config key might be different.

**Evidence**:
- The error message says "Configure gateway.trustedProxies" but this might be a user-facing hint, not the actual config path
- No confirmation in logs that trustedProxies was applied

**To verify**:
- Check clawdbot source code or documentation for exact config schema
- Look for config validation errors in logs
- Try alternative paths: `gateway.proxy.trusted`, `gateway.trust`, etc.

### Theory 2: WebSocket Token Passing

**Hypothesis**: The web UI might not pass the token correctly to the WebSocket connection.

**Evidence**:
- URL has `?token=xxx` but WebSocket connections use different mechanisms
- Possible WebSocket auth methods:
  - Query string on WS URL: `wss://host/?token=xxx`
  - Sec-WebSocket-Protocol header
  - First message after connection
  - Cookie-based

**To verify**:
- Check browser DevTools → Network → WS tab to see the actual WebSocket URL
- Check if token is passed in WS handshake or as first message

### Theory 3: Proxy Header Mismatch

**Hypothesis**: Railway uses different proxy headers than what clawdbot expects.

**Evidence**:
- Railway typically uses `X-Forwarded-For`, `X-Forwarded-Proto`
- Clawdbot might expect `Forwarded` (RFC 7239) or other headers
- The gateway sees `remote=100.64.0.x fwd=92.247.56.32` - so it IS reading the forwarded header

**To verify**:
- Check what headers Railway sends
- Check what headers clawdbot reads

### Theory 4: Token Auth vs Device Pairing Are Separate

**Hypothesis**: Token auth might only work for API access, not for the Control UI. The Control UI might always require device pairing.

**Evidence**:
- Clawdbot distinguishes between:
  - API clients (use token)
  - Control UI clients (need device pairing)
  - Channel clients (Telegram, Discord - use channel pairing)
- The error is specifically about "pairing" not "authentication"

**To verify**:
- Check if there's a separate UI pairing mechanism
- Check if `controlUi.allowInsecureAuth` helps
- Check clawdbot docs for Control UI authentication

### Theory 5: CIDR Format Issue

**Hypothesis**: The trustedProxies value `['100.64.0.0/10', '10.0.0.0/8']` might be in the wrong format.

**Evidence**:
- Some systems expect arrays, others expect comma-separated strings
- Some expect individual IPs, not CIDR ranges

**To verify**:
- Try `"100.64.0.0/10"` as string instead of array
- Try specific IP: `"100.64.0.1"`
- Try wildcard: `"*"` (trust all - for testing only)

## Attempted Fixes

| Fix | Result |
|-----|--------|
| Added `?token=xxx` to URL | Still shows pairing required |
| Added `gateway.trustedProxies = ['100.64.0.0/10']` | Still shows pairing required |
| Set `healthcheckTimeout = 120` | Health checks pass now |
| Configured Anthropic API key properly | API key is in config |

## Next Steps to Try

### 1. Enable Debug/Dev Mode
Add to Railway environment:
```
CLAWDBOT_DEV_MODE=true
```
This sets `controlUi.allowInsecureAuth = true` which might bypass the issue.

### 2. Check Actual Config on Container
Run in Railway shell (if accessible):
```bash
cat /data/.clawdbot/clawdbot.json | jq '.gateway'
```
Verify trustedProxies is actually in the file.

### 3. Try Alternative trustedProxies Formats
```javascript
// Current (array of CIDR)
config.gateway.trustedProxies = ['100.64.0.0/10'];

// Alternative 1: string
config.gateway.trustedProxies = '100.64.0.0/10';

// Alternative 2: trust all (testing only)
config.gateway.trustedProxies = '*';

// Alternative 3: specific IPs
config.gateway.trustedProxies = ['100.64.0.1', '100.64.0.2', '100.64.0.3'];
```

### 4. Check WebSocket Connection in Browser
1. Open DevTools (F12)
2. Go to Network tab
3. Filter by "WS"
4. Reload the page with `?token=xxx`
5. Check:
   - What URL does the WebSocket connect to?
   - Is the token in the WS URL or headers?
   - What's the first message exchanged?

### 5. Verify Token in Container Environment
```bash
railway run printenv | grep -i token
railway run printenv | grep -i CLAWDBOT
```

## Questions for Clawdbot Documentation

1. What is the exact config path for trusting reverse proxies?
2. How does the Control UI authenticate with a token?
3. Is there a separate device pairing flow for the web UI?
4. What proxy headers does clawdbot read for client IP detection?
5. Can token auth bypass device pairing for Control UI?

## Temporary Workarounds

### For Telegram (user rejected this)
Set `TELEGRAM_DM_POLICY=open` to allow all DMs without pairing.

### For Web UI
Unknown - need to solve the proxy/token auth issue first.

---

*Last updated: 2026-02-04*
*Issue status: UNRESOLVED*

---

## Additions (from Codex)
From Codex: detailed diagnosis + an unblock‑first runbook.

### What the logs are really telling us
- The log line:
  ```
  [ws] Proxy headers detected from untrusted address. Connection will not be treated as local.
  ```
  means the gateway intentionally refuses to treat the client as “local” because the proxy IP is not in `gateway.trustedProxies`. That disables any “local auto‑approval” behavior and forces pairing.
- The `1008: pairing required` error means the Control UI device identity is not paired/approved. It does **not** necessarily mean the token is missing or wrong.

### The Control UI token is NOT the same as `?token=…`
- The Control UI uses `connect.params.auth.token` and expects the token to be entered in the UI settings (it stores it and sends it over the WebSocket connection).
- A query string token (`?token=…`) is not a documented auth mechanism for the Control UI, so it often does nothing.
- Therefore, even with `?token=…`, the gateway can still require pairing and reject the WS connection.

### Most likely root cause (given the evidence)
- The UI is behind Railway’s proxy, so the gateway does not treat it as “local.”
- The device identity is not paired/approved (or could not be generated).
- The token in the URL is not being sent in the expected way.
- Result: pairing required → WS closed with 1008.

### Unblock‑first runbook (do in order)
1. **Use the Control UI token field (not URL query)**
   - Open the Control UI in the browser over HTTPS.
   - Go to Settings → Connection → Token (exact label may vary).
   - Paste the gateway token and save.
   - Reload the page and reconnect.
2. **Pair the Control UI device**
   - If the UI prompts for pairing, complete it.
   - If pairing is blocked, proceed to the temporary bypass below.
3. **Temporary bypass (only if stuck)**
   - Set `gateway.controlUi.allowInsecureAuth = true` in config.
   - Restart the gateway and connect.
   - Once connected and stable, revert this setting.
4. **Make proxy trust explicit**
   - Add Railway proxy IP ranges (e.g., `100.64.0.0/10`) to `gateway.trustedProxies`.
   - Restart gateway and retry UI.

### If the UI still cannot pair
- Check that the page is served over HTTPS (or localhost). The Control UI uses WebCrypto; if it can’t create a device identity in an insecure context, pairing fails.
- Confirm the gateway is using your updated config:
  ```bash
  cat /data/.clawdbot/clawdbot.json | jq '.gateway'
  ```
- Confirm the token in config matches the one you entered in the UI.

### How to verify the token is actually sent
1. Open DevTools → Network → WS.
2. Click the WS connection and inspect:
   - Request URL
   - Request headers
   - Messages (first client message should include auth token in payload)
3. If there is no token in the payload, the UI is not configured correctly.

### Safer long‑term configuration
- Keep `gateway.controlUi.allowInsecureAuth = false` in production.
- Keep `gateway.trustedProxies` limited to Railway proxy ranges only.
- Require pairing for new Control UI devices.

### Minimal config snippet (reference)
```json
{
  "gateway": {
    "auth": { "mode": "token", "token": "YOUR_TOKEN" },
    "trustedProxies": ["100.64.0.0/10"],
    "controlUi": { "allowInsecureAuth": false }
  }
}
```
