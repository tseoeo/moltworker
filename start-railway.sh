#!/bin/bash
# Startup script for Moltbot on Railway
# Simplified from Cloudflare version - no R2 sync needed
# Railway volumes persist data automatically

set -e

# Check if clawdbot gateway is already running
if pgrep -f "clawdbot gateway" > /dev/null 2>&1; then
    echo "Moltbot gateway is already running, exiting."
    exit 0
fi

# Paths
# Railway volume is mounted at /data
# /root/.clawdbot is symlinked to /data/.clawdbot for persistence
CONFIG_DIR="/data/.clawdbot"
CONFIG_FILE="$CONFIG_DIR/clawdbot.json"
TEMPLATE_DIR="/root/.clawdbot-templates"
TEMPLATE_FILE="$TEMPLATE_DIR/moltbot.json.template"

echo "=== Moltbot Railway Startup ==="
echo "Config directory: $CONFIG_DIR"

# Create config directory if it doesn't exist
mkdir -p "$CONFIG_DIR"

# ============================================================
# CONFIGURE GIT CREDENTIALS
# ============================================================
if [ -n "$GITHUB_TOKEN" ]; then
    echo "Configuring git with GitHub token..."
    git config --global credential.helper store
    echo "https://x-access-token:${GITHUB_TOKEN}@github.com" > /root/.git-credentials
    chmod 600 /root/.git-credentials
    git config --global user.email "moltbot@railway.app"
    git config --global user.name "Moltbot"
    echo "Git credentials configured"
fi

# ============================================================
# INITIALIZE CONFIG
# ============================================================
if [ ! -f "$CONFIG_FILE" ]; then
    echo "No existing config found, initializing..."
    if [ -f "$TEMPLATE_FILE" ]; then
        cp "$TEMPLATE_FILE" "$CONFIG_FILE"
        echo "Created config from template"
    else
        # Create minimal config
        cat > "$CONFIG_FILE" << 'EOFCONFIG'
{
  "agents": {
    "defaults": {
      "workspace": "/root/clawd"
    }
  },
  "gateway": {
    "port": 18789,
    "mode": "local"
  }
}
EOFCONFIG
        echo "Created minimal config"
    fi
else
    echo "Using existing config from Railway volume"
fi

# ============================================================
# UPDATE CONFIG FROM ENVIRONMENT VARIABLES
# ============================================================
node << 'EOFNODE'
const fs = require('fs');

const configPath = '/data/.clawdbot/clawdbot.json';
console.log('Updating config at:', configPath);
let config = {};

try {
    config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
} catch (e) {
    console.log('Starting with empty config');
}

// Ensure nested objects exist
config.agents = config.agents || {};
config.agents.defaults = config.agents.defaults || {};
config.agents.defaults.model = config.agents.defaults.model || {};
config.gateway = config.gateway || {};
config.channels = config.channels || {};

// Clean up any broken anthropic provider config from previous runs
if (config.models?.providers?.anthropic?.models) {
    const hasInvalidModels = config.models.providers.anthropic.models.some(m => !m.name);
    if (hasInvalidModels) {
        console.log('Removing broken anthropic provider config (missing model names)');
        delete config.models.providers.anthropic;
    }
}

// Gateway configuration - use PORT env var (Railway sets this)
config.gateway.port = parseInt(process.env.PORT) || 18789;
config.gateway.mode = 'local';

// Trust Railway's proxy - allows token auth to work behind load balancer
// Railway uses 100.64.0.0/10 (CGNAT range) for internal proxies
config.gateway.trustedProxies = ['100.64.0.0/10', '10.0.0.0/8'];

// Set gateway token if provided
if (process.env.CLAWDBOT_GATEWAY_TOKEN) {
    config.gateway.auth = config.gateway.auth || {};
    config.gateway.auth.token = process.env.CLAWDBOT_GATEWAY_TOKEN;
}

// Allow insecure auth for dev mode
if (process.env.CLAWDBOT_DEV_MODE === 'true') {
    config.gateway.controlUi = config.gateway.controlUi || {};
    config.gateway.controlUi.allowInsecureAuth = true;
}

// Telegram configuration
if (process.env.TELEGRAM_BOT_TOKEN) {
    config.channels.telegram = config.channels.telegram || {};
    config.channels.telegram.botToken = process.env.TELEGRAM_BOT_TOKEN;
    config.channels.telegram.enabled = true;
    const telegramDmPolicy = process.env.TELEGRAM_DM_POLICY || 'pairing';
    config.channels.telegram.dmPolicy = telegramDmPolicy;
    if (process.env.TELEGRAM_DM_ALLOW_FROM) {
        config.channels.telegram.allowFrom = process.env.TELEGRAM_DM_ALLOW_FROM.split(',');
    } else if (telegramDmPolicy === 'open') {
        config.channels.telegram.allowFrom = ['*'];
    }
}

// Discord configuration
if (process.env.DISCORD_BOT_TOKEN) {
    config.channels.discord = config.channels.discord || {};
    config.channels.discord.token = process.env.DISCORD_BOT_TOKEN;
    config.channels.discord.enabled = true;
    const discordDmPolicy = process.env.DISCORD_DM_POLICY || 'pairing';
    config.channels.discord.dm = config.channels.discord.dm || {};
    config.channels.discord.dm.policy = discordDmPolicy;
    if (discordDmPolicy === 'open') {
        config.channels.discord.dm.allowFrom = ['*'];
    }
}

// Slack configuration
if (process.env.SLACK_BOT_TOKEN && process.env.SLACK_APP_TOKEN) {
    config.channels.slack = config.channels.slack || {};
    config.channels.slack.botToken = process.env.SLACK_BOT_TOKEN;
    config.channels.slack.appToken = process.env.SLACK_APP_TOKEN;
    config.channels.slack.enabled = true;
}

// Base URL override (e.g., for AI Gateway)
const baseUrl = (process.env.AI_GATEWAY_BASE_URL || process.env.ANTHROPIC_BASE_URL || '').replace(/\/+$/, '');
const isOpenAI = baseUrl.endsWith('/openai');

if (isOpenAI) {
    console.log('Configuring OpenAI provider with base URL:', baseUrl);
    config.models = config.models || {};
    config.models.providers = config.models.providers || {};
    config.models.providers.openai = {
        baseUrl: baseUrl,
        api: 'openai-responses',
        models: [
            { id: 'gpt-5.2', name: 'GPT-5.2', contextWindow: 200000 },
            { id: 'gpt-5', name: 'GPT-5', contextWindow: 200000 },
            { id: 'gpt-4.5-preview', name: 'GPT-4.5 Preview', contextWindow: 128000 },
        ]
    };
    config.agents.defaults.models = config.agents.defaults.models || {};
    config.agents.defaults.models['openai/gpt-5.2'] = { alias: 'GPT-5.2' };
    config.agents.defaults.models['openai/gpt-5'] = { alias: 'GPT-5' };
    config.agents.defaults.models['openai/gpt-4.5-preview'] = { alias: 'GPT-4.5' };
    config.agents.defaults.model.primary = 'openai/gpt-5.2';
} else if (baseUrl) {
    console.log('Configuring Anthropic provider with base URL:', baseUrl);
    config.models = config.models || {};
    config.models.providers = config.models.providers || {};
    const providerConfig = {
        baseUrl: baseUrl,
        api: 'anthropic-messages',
        models: [
            { id: 'claude-opus-4-5-20251101', name: 'Claude Opus 4.5', contextWindow: 200000 },
            { id: 'claude-sonnet-4-5-20250929', name: 'Claude Sonnet 4.5', contextWindow: 200000 },
            { id: 'claude-haiku-4-5-20251001', name: 'Claude Haiku 4.5', contextWindow: 200000 },
        ]
    };
    if (process.env.ANTHROPIC_API_KEY) {
        providerConfig.apiKey = process.env.ANTHROPIC_API_KEY;
    }
    config.models.providers.anthropic = providerConfig;
    config.agents.defaults.models = config.agents.defaults.models || {};
    config.agents.defaults.models['anthropic/claude-opus-4-5-20251101'] = { alias: 'Opus 4.5' };
    config.agents.defaults.models['anthropic/claude-sonnet-4-5-20250929'] = { alias: 'Sonnet 4.5' };
    config.agents.defaults.models['anthropic/claude-haiku-4-5-20251001'] = { alias: 'Haiku 4.5' };
    config.agents.defaults.model.primary = 'anthropic/claude-haiku-4-5-20251001';
} else {
    // Default to Anthropic without custom base URL
    // Still need to configure provider with API key
    if (process.env.ANTHROPIC_API_KEY) {
        console.log('Configuring Anthropic provider with default API');
        config.models = config.models || {};
        config.models.providers = config.models.providers || {};
        config.models.providers.anthropic = {
            baseUrl: 'https://api.anthropic.com',
            api: 'anthropic-messages',
            apiKey: process.env.ANTHROPIC_API_KEY,
            models: [
                { id: 'claude-opus-4-5-20251101', name: 'Claude Opus 4.5', contextWindow: 200000 },
                { id: 'claude-sonnet-4-5-20250929', name: 'Claude Sonnet 4.5', contextWindow: 200000 },
                { id: 'claude-haiku-4-5-20251001', name: 'Claude Haiku 4.5', contextWindow: 200000 },
            ]
        };
        config.agents.defaults.models = config.agents.defaults.models || {};
        config.agents.defaults.models['anthropic/claude-opus-4-5-20251101'] = { alias: 'Opus 4.5' };
        config.agents.defaults.models['anthropic/claude-sonnet-4-5-20250929'] = { alias: 'Sonnet 4.5' };
        config.agents.defaults.models['anthropic/claude-haiku-4-5-20251001'] = { alias: 'Haiku 4.5' };
    }
    config.agents.defaults.model.primary = 'anthropic/claude-haiku-4-5-20251001';
}

// Clean up old custom openrouter provider (not openrouter-custom)
if (config.models?.providers?.openrouter) {
    console.log('Removing old custom openrouter provider');
    delete config.models.providers.openrouter;
}

// OpenRouter configuration
if (process.env.OPENROUTER_API_KEY) {
    console.log('OpenRouter API key detected - configuring Kimi K2.5 custom provider');
    config.models = config.models || {};
    config.models.mode = 'merge';
    config.models.providers = config.models.providers || {};

    // Custom provider for Kimi K2.5 - bypasses built-in catalog lag
    // This is needed because clawdbot's built-in OpenRouter catalog doesn't
    // have K2.5 metadata yet, causing "Unknown model" errors
    config.models.providers['openrouter-custom'] = {
        baseUrl: 'https://openrouter.ai/api/v1',
        apiKey: process.env.OPENROUTER_API_KEY,
        api: 'openai-responses',
        models: [
            {
                id: 'moonshotai/kimi-k2.5',
                name: 'Kimi K2.5',
                input: ['text', 'image'],
                contextWindow: 262144
            }
        ]
    };

    // Add models to allowlist
    config.agents.defaults.models = config.agents.defaults.models || {};
    config.agents.defaults.models['openrouter-custom/moonshotai/kimi-k2.5'] = { alias: 'Kimi K2.5' };
    config.agents.defaults.models['openrouter/moonshotai/kimi-k2'] = { alias: 'Kimi K2' };
    config.agents.defaults.models['openrouter/moonshotai/kimi-k2-instruct'] = { alias: 'Kimi K2 Instruct' };
    config.agents.defaults.models['openrouter/moonshotai/kimi-k2-thinking'] = { alias: 'Kimi K2 Thinking' };
    config.agents.defaults.models['openrouter/openrouter/auto'] = { alias: 'Auto (OpenRouter)' };

    // Set Kimi K2.5 as default model (multimodal - handles text + images)
    config.agents.defaults.model.primary = 'openrouter-custom/moonshotai/kimi-k2.5';

    // Set imageModel to K2.5 as well - Clawdbot needs this explicitly for image processing
    // Even though K2.5 is multimodal, Clawdbot checks imageModel separately
    config.agents.defaults.imageModel = config.agents.defaults.imageModel || {};
    config.agents.defaults.imageModel.primary = 'openrouter-custom/moonshotai/kimi-k2.5';
}

// Override default model if specified via environment
if (process.env.DEFAULT_MODEL) {
    console.log('Setting default model from env:', process.env.DEFAULT_MODEL);
    config.agents.defaults.model.primary = process.env.DEFAULT_MODEL;
}

// Configure image/vision model for multimodal tasks
if (process.env.IMAGE_MODEL) {
    console.log('Setting image model from env:', process.env.IMAGE_MODEL);
    config.agents.defaults.imageModel = config.agents.defaults.imageModel || {};
    config.agents.defaults.imageModel.primary = process.env.IMAGE_MODEL;
    // Add to models allowlist
    config.agents.defaults.models[process.env.IMAGE_MODEL] = { alias: 'Vision Model' };
}

// Clean up any invalid config keys that might have been added
if (config.messages?.mediaUnderstanding) {
    console.log('Removing invalid mediaUnderstanding key');
    delete config.messages.mediaUnderstanding;
}

// Brave Search API configuration
if (process.env.BRAVE_API_KEY) {
    console.log('Brave API key detected - configuring web search');
    config.tools = config.tools || {};
    config.tools.web = config.tools.web || {};
    config.tools.web.search = config.tools.web.search || {};
    config.tools.web.search.enabled = true;
    config.tools.web.search.apiKey = process.env.BRAVE_API_KEY;
}

// Write updated config
fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
console.log('Configuration updated successfully');
console.log('Config:', JSON.stringify(config, null, 2));
EOFNODE

# ============================================================
# START GATEWAY
# ============================================================
# Use Railway's PORT env var (defaults to 18789)
GATEWAY_PORT="${PORT:-18789}"

echo ""
echo "=== Starting Moltbot Gateway ==="
echo "Gateway will be available on port $GATEWAY_PORT"

# Clean up stale lock files
rm -f /tmp/clawdbot-gateway.lock 2>/dev/null || true
rm -f "$CONFIG_DIR/gateway.lock" 2>/dev/null || true

# Railway exposes containers directly, bind to all interfaces
BIND_MODE="lan"

if [ -n "$CLAWDBOT_GATEWAY_TOKEN" ]; then
    echo "Starting gateway with token auth..."
    exec clawdbot gateway --port "$GATEWAY_PORT" --verbose --allow-unconfigured --bind "$BIND_MODE" --token "$CLAWDBOT_GATEWAY_TOKEN"
else
    echo "Starting gateway with device pairing (no token)..."
    exec clawdbot gateway --port "$GATEWAY_PORT" --verbose --allow-unconfigured --bind "$BIND_MODE"
fi
