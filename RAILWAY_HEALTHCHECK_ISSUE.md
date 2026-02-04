# Railway Health Check Issue - Analysis & Solutions

## The Problem

The Moltbot deployment on Railway keeps failing with "Healthcheck failed!" even though the container starts successfully and the gateway is running.

### Observed Behavior

From the logs:
```
Path: /
Retry window: 30s

Attempt #1 failed with service unavailable. Continuing to retry for 19s
Attempt #2 failed with service unavailable. Continuing to retry for 8s

1/1 replicas never became healthy!
Healthcheck failed!
```

But later in the same deployment, we see:
```
[gateway] listening on ws://0.0.0.0:18789 (PID 24)
[telegram] [default] starting provider (@bigend_hbot)
```

**The gateway IS starting successfully - it just takes ~40 seconds, but the health check gives up after 30 seconds.**

---

## Root Cause Analysis

### 1. Startup Time vs Retry Window Mismatch

The clawdbot gateway has a cold start time of approximately 35-45 seconds due to:
- Loading Node.js runtime
- Installing and initializing skills
- Connecting to Telegram API
- Starting the websocket server

Railway's health check has a **30-second retry window** that cannot be increased through the UI.

### 2. Railway's Health Check Architecture

According to [Railway documentation](https://docs.railway.com/guides/healthchecks):

- Health checks run **only during deployment** (not continuous monitoring)
- The check loops continuously until either:
  - HTTP 200 is received (success)
  - The timeout expires (failure)
- Default timeout: 300 seconds
- **Retry window**: Appears to be a separate, undocumented limit (~30 seconds)

### 3. UI Values Are "Sticky"

Per [Railway Help Station](https://station.railway.com/questions/increasing-delay-between-health-checks-d-a18c607f):

> "The Retry Window in the logs reflects the UI's value which cannot be cleared out, instead of the value of the variable that was set."

Once a health check path is set in the UI, it cannot be fully cleared. The only workarounds are:
1. Use **Config as Code** (railway.json) to override
2. Delete and recreate the service
3. Contact Railway support to manually remove it

### 4. Our Current Configuration

`railway.toml` has:
```toml
healthcheckPath = "/"
healthcheckTimeout = 30
```

This **enables** the health check with a 30-second timeout - the exact cause of our failure.

---

## Theory

The health check is failing because:

1. We explicitly configured `healthcheckPath = "/"` in `railway.toml`
2. The `healthcheckTimeout = 30` is too short for the gateway startup time
3. Even when we tried to clear it from the UI, Railway still runs the check because the `.toml` file has it configured
4. The 30-second "retry window" is a hard limit that cannot be extended through normal means

---

## Solutions

### Solution 1: Disable Health Check via Config (Recommended)

Update `railway.toml` to explicitly disable the health check:

```toml
[deploy]
healthcheckPath = ""
```

Or use `railway.json` (takes precedence over UI):

```json
{
  "$schema": "https://railway.com/railway.schema.json",
  "deploy": {
    "healthcheckPath": null,
    "healthcheckTimeout": null
  }
}
```

According to [Railway Config as Code docs](https://docs.railway.com/reference/config-as-code):
> "Configuration defined in code will always override values from the dashboard."

### Solution 2: Increase Timeout Significantly

Set a much longer timeout (e.g., 120 seconds) to accommodate the startup time:

```toml
[deploy]
healthcheckPath = "/"
healthcheckTimeout = 120
```

Or via environment variable:
```
RAILWAY_HEALTHCHECK_TIMEOUT_SEC=120
```

### Solution 3: Add a Lightweight Health Endpoint

Create a `/health` endpoint that responds immediately, before the full gateway is ready. This requires modifying the startup script to spawn a simple HTTP server first.

### Solution 4: Recreate the Service

If UI values are stuck and config files don't override them:
1. Delete the current Railway service
2. Create a new service from scratch
3. Don't set any health check path initially

---

## Recommended Action

**Use Solution 1**: Update `railway.toml` to disable the health check entirely:

```toml
[build]
dockerfilePath = "Dockerfile.railway"

[deploy]
numReplicas = 1
restartPolicyType = "ON_FAILURE"
restartPolicyMaxRetries = 3
startCommand = "/usr/local/bin/start-railway.sh"
# Disable health check - gateway takes ~40s to start
# healthcheckPath = "/"
# healthcheckTimeout = 30
```

Then push and redeploy.

---

## Sources

- [Railway Healthchecks Guide](https://docs.railway.com/guides/healthchecks)
- [Railway Config as Code Reference](https://docs.railway.com/reference/config-as-code)
- [Railway Help: Increasing delay between health checks](https://station.railway.com/questions/increasing-delay-between-health-checks-d-a18c607f)
- [Railway Help: Raising the healthcheck timeout](https://station.railway.com/feedback/raising-the-healthcheck-timeout-8fab1cf9)
