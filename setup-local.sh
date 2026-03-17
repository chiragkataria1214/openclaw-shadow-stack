#!/bin/bash
set -euo pipefail

# ============================================================================
# OpenClaw Shadow Stack — Local Setup Script
# ============================================================================
# Run this on your LOCAL machine (Mac/Linux/WSL2).
# It pulls everything from your DigitalOcean server and starts the stack.
#
# Usage:
#   chmod +x setup-local.sh
#   ./setup-local.sh
#
# Prerequisites:
#   - Docker Desktop installed and running
#   - SSH access to your server (key-based auth recommended)
# ============================================================================

SERVER="${OPENCLAW_SERVER:-root@YOUR_SERVER_IP}"
LOCAL_HOME="$HOME"
PROJECT_DIR="$LOCAL_HOME/openclaw-shadow-stack"
CONFIG_DIR="$LOCAL_HOME/.openclaw"
ECOM_DIR="$LOCAL_HOME/ecom-platform"
GHCR_USER="chiragkataria1214"
GHCR_TOKEN="${GITHUB_TOKEN:?Set GITHUB_TOKEN env var before running}"

echo "============================================"
echo "  OpenClaw Shadow Stack — Local Setup"
echo "============================================"
echo ""

# --------------------------------------------------
# Step 1: Transfer config from server
# --------------------------------------------------
echo "[1/6] Syncing ~/.openclaw config from server..."
mkdir -p "$CONFIG_DIR"
rsync -avz --progress "$SERVER:~/.openclaw/" "$CONFIG_DIR/"
echo "  Done."
echo ""

# --------------------------------------------------
# Step 2: Transfer ecom-platform from server
# --------------------------------------------------
echo "[2/6] Syncing ~/ecom-platform from server..."
mkdir -p "$ECOM_DIR"
rsync -avz --progress "$SERVER:~/ecom-platform/" "$ECOM_DIR/"
echo "  Done."
echo ""

# --------------------------------------------------
# Step 3: Clone or pull the repo
# --------------------------------------------------
echo "[3/6] Setting up project repo..."
if [ -d "$PROJECT_DIR/.git" ]; then
  echo "  Repo exists, pulling latest..."
  cd "$PROJECT_DIR"
  git pull --rebase origin main
else
  echo "  Cloning from GitHub..."
  git clone https://github.com/chiragkataria1214/openclaw-shadow-stack.git "$PROJECT_DIR"
  cd "$PROJECT_DIR"
fi
echo "  Done."
echo ""

# --------------------------------------------------
# Step 4: Create .env with correct local paths
# --------------------------------------------------
echo "[4/6] Creating .env file..."
cat > "$PROJECT_DIR/.env" << ENVEOF
OPENCLAW_CONFIG_DIR=$CONFIG_DIR
OPENCLAW_WORKSPACE_DIR=$CONFIG_DIR/workspace
OPENCLAW_GATEWAY_PORT=18789
OPENCLAW_BRIDGE_PORT=18790
OPENCLAW_GATEWAY_BIND=lan
OPENCLAW_GATEWAY_TOKEN=b1e420e8b069008dea3becd0cd365b7019175a2bcc2f08f7d4b1a64d46cb1efe
OPENCLAW_IMAGE=ghcr.io/chiragkataria1214/openclaw-shadow-stack:latest
OPENCLAW_EXTRA_MOUNTS=
OPENCLAW_HOME_VOLUME=
OPENCLAW_DOCKER_APT_PACKAGES=
OPENCLAW_EXTENSIONS=
OPENCLAW_SANDBOX=
OPENCLAW_DOCKER_SOCKET=/var/run/docker.sock
DOCKER_GID=
OPENCLAW_INSTALL_DOCKER_CLI=
OPENCLAW_ALLOW_INSECURE_PRIVATE_WS=
BRAVE_API_KEY=\${BRAVE_API_KEY:?Set BRAVE_API_KEY}
GITHUB_TOKEN=\${GITHUB_TOKEN:?Set GITHUB_TOKEN}
NOTION_TOKEN=\${NOTION_TOKEN:?Set NOTION_TOKEN}
NOTION_DATABASE_ID=\${NOTION_DATABASE_ID:?Set NOTION_DATABASE_ID}
SLACK_BOT_TOKEN=\${SLACK_BOT_TOKEN:?Set SLACK_BOT_TOKEN}
ANTHROPIC_API_KEY=\${ANTHROPIC_API_KEY:?Set ANTHROPIC_API_KEY}
ENVEOF
echo "  Done."
echo ""

# --------------------------------------------------
# Step 5: Fix docker-compose volume paths for local
# --------------------------------------------------
echo "[5/6] Creating local docker-compose.yml..."
cat > "$PROJECT_DIR/docker-compose.local.yml" << 'DCEOF'
services:
  openclaw-gateway:
    image: ${OPENCLAW_IMAGE:-openclaw:local}
    user: root
    environment:
      HOME: /home/node
      TERM: xterm-256color
      OPENCLAW_GATEWAY_TOKEN: ${OPENCLAW_GATEWAY_TOKEN:-}
      OPENCLAW_ALLOW_INSECURE_PRIVATE_WS: ${OPENCLAW_ALLOW_INSECURE_PRIVATE_WS:-}
      CLAUDE_AI_SESSION_KEY: ${CLAUDE_AI_SESSION_KEY:-}
      CLAUDE_WEB_SESSION_KEY: ${CLAUDE_WEB_SESSION_KEY:-}
      CLAUDE_WEB_COOKIE: ${CLAUDE_WEB_COOKIE:-}
      TZ: ${OPENCLAW_TZ:-UTC}
      BRAVE_API_KEY: ${BRAVE_API_KEY:-}
      GITHUB_TOKEN: ${GITHUB_TOKEN:-}
      NOTION_TOKEN: ${NOTION_TOKEN:-}
      SLACK_BOT_TOKEN: ${SLACK_BOT_TOKEN:-}
      ANTHROPIC_API_KEY: ${ANTHROPIC_API_KEY:-}
    volumes:
      - ${OPENCLAW_CONFIG_DIR}:/home/node/.openclaw
      - ${OPENCLAW_WORKSPACE_DIR}:/home/node/.openclaw/workspace
    ports:
      - "${OPENCLAW_GATEWAY_PORT:-18789}:18789"
      - "${OPENCLAW_BRIDGE_PORT:-18790}:18790"
    init: true
    restart: unless-stopped
    command:
      [
        "node",
        "dist/index.js",
        "gateway",
        "--bind",
        "${OPENCLAW_GATEWAY_BIND:-lan}",
        "--port",
        "18789",
      ]
    healthcheck:
      test:
        [
          "CMD",
          "node",
          "-e",
          "fetch('http://127.0.0.1:18789/healthz').then((r)=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))",
        ]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 20s

  mcp-servers:
    image: node:22-slim
    network_mode: "service:openclaw-gateway"
    environment:
      HOME: /home/node
      NOTION_TOKEN: ${NOTION_TOKEN:-}
      NOTION_DATABASE_ID: ${NOTION_DATABASE_ID:-}
    volumes:
      - ${ECOM_DIR:-./ecom-platform}/mcp-servers:/app/mcp-servers:ro
      - ${ECOM_DIR:-./ecom-platform}/config:/home/node/ecom-platform/config:ro
    init: true
    restart: unless-stopped
    depends_on:
      openclaw-gateway:
        condition: service_healthy
    command:
      - sh
      - -c
      - |
        echo "Starting MCP servers..."
        cd /app/mcp-servers/client-context && PORT=3010 node index.js &
        echo "  client-context on :3010"
        cd /app/mcp-servers/theme-mapper && PORT=3011 node index.js &
        echo "  theme-mapper on :3011"
        cd /app/mcp-servers/notion-tool && PORT=3012 node index.js &
        echo "  notion-tool on :3012"
        echo "All MCP servers started."
        wait

  openclaw-cli:
    image: ${OPENCLAW_IMAGE:-openclaw:local}
    user: root
    network_mode: "service:openclaw-gateway"
    cap_drop:
      - NET_RAW
      - NET_ADMIN
    security_opt:
      - no-new-privileges:true
    environment:
      HOME: /home/node
      TERM: xterm-256color
      OPENCLAW_GATEWAY_TOKEN: ${OPENCLAW_GATEWAY_TOKEN:-}
      OPENCLAW_ALLOW_INSECURE_PRIVATE_WS: ${OPENCLAW_ALLOW_INSECURE_PRIVATE_WS:-}
      BROWSER: echo
      CLAUDE_AI_SESSION_KEY: ${CLAUDE_AI_SESSION_KEY:-}
      CLAUDE_WEB_SESSION_KEY: ${CLAUDE_WEB_SESSION_KEY:-}
      CLAUDE_WEB_COOKIE: ${CLAUDE_WEB_COOKIE:-}
      TZ: ${OPENCLAW_TZ:-UTC}
      BRAVE_API_KEY: ${BRAVE_API_KEY:-}
      GITHUB_TOKEN: ${GITHUB_TOKEN:-}
      NOTION_TOKEN: ${NOTION_TOKEN:-}
      SLACK_BOT_TOKEN: ${SLACK_BOT_TOKEN:-}
      ANTHROPIC_API_KEY: ${ANTHROPIC_API_KEY:-}
    volumes:
      - ${OPENCLAW_CONFIG_DIR}:/home/node/.openclaw
      - ${OPENCLAW_WORKSPACE_DIR}:/home/node/.openclaw/workspace
    stdin_open: true
    tty: true
    init: true
    entrypoint: ["node", "dist/index.js"]
    depends_on:
      - openclaw-gateway
DCEOF

# Add ECOM_DIR to .env
echo "ECOM_DIR=$ECOM_DIR" >> "$PROJECT_DIR/.env"

echo "  Done."
echo ""

# --------------------------------------------------
# Step 6: Login to GHCR, pull image, start stack
# --------------------------------------------------
echo "[6/6] Starting Docker stack..."
echo "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin

cd "$PROJECT_DIR"
docker compose -f docker-compose.local.yml pull
docker compose -f docker-compose.local.yml up -d

echo ""
echo "============================================"
echo "  Setup complete!"
echo "============================================"
echo ""
echo "  Gateway:  http://localhost:18789"
echo "  Config:   $CONFIG_DIR/openclaw.json"
echo "  Logs:     docker compose -f docker-compose.local.yml logs -f"
echo "  CLI:      docker compose -f docker-compose.local.yml exec openclaw-cli node dist/index.js"
echo "  Stop:     docker compose -f docker-compose.local.yml down"
echo "  Update:   docker compose -f docker-compose.local.yml pull && docker compose -f docker-compose.local.yml up -d"
echo ""
echo "  To sync config changes from server later:"
echo "    rsync -avz $SERVER:~/.openclaw/ $CONFIG_DIR/"
echo ""
