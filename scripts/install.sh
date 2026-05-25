#!/bin/bash
set -e

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}   CalBridge  •  Setup${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

BACKEND_DIR="$(cd "$(dirname "$0")/../backend" && pwd)"
PLIST_NAME="com.drewcraig.cal-bridge-autorun"
PLIST_PATH="$HOME/Library/LaunchAgents/$PLIST_NAME.plist"

# ── Check dependencies ────────────────────────────────────────────────────

echo -e "${CYAN}Checking dependencies...${NC}"

if ! command -v node &>/dev/null; then
  echo -e "${RED}✗ Node.js not found. Install from https://nodejs.org or via Homebrew:${NC}"
  echo "  brew install node"
  exit 1
fi
echo -e "${GREEN}✓ Node.js $(node -v)${NC}"

if ! command -v npx &>/dev/null; then
  echo -e "${RED}✗ npx not found. Install Node.js first.${NC}"
  exit 1
fi
echo -e "${GREEN}✓ npx found${NC}"

# ── Install backend dependencies ──────────────────────────────────────────

echo ""
echo -e "${CYAN}Installing backend dependencies...${NC}"
cd "$BACKEND_DIR"
npm install --silent
echo -e "${GREEN}✓ Dependencies installed${NC}"

# ── Collect credentials ───────────────────────────────────────────────────

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  Google Calendar Setup${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "You need a Google Cloud project with the Calendar API enabled."
echo "Guide: https://github.com/dkeg/cal-bridge#google-setup"
echo ""
read -p "Google Client ID: " GOOGLE_CLIENT_ID
read -p "Google Client Secret: " GOOGLE_CLIENT_SECRET

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  Notion Setup${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "Create a Notion integration at https://notion.so/my-integrations"
echo "Then share your target page with the integration."
echo ""
read -p "Notion API Key (starts with ntn_ or secret_): " NOTION_API_KEY
read -p "Notion Parent Page ID (32-char ID from page URL): " NOTION_PARENT_PAGE_ID

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  Anthropic Setup${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "Get your API key from https://console.anthropic.com"
echo ""
read -p "Anthropic API Key: " ANTHROPIC_API_KEY

# ── Write .env ────────────────────────────────────────────────────────────

echo ""
echo -e "${CYAN}Writing .env file...${NC}"
cat > "$BACKEND_DIR/.env" << EOF
GOOGLE_CLIENT_ID=$GOOGLE_CLIENT_ID
GOOGLE_CLIENT_SECRET=$GOOGLE_CLIENT_SECRET
NOTION_API_KEY=$NOTION_API_KEY
NOTION_PARENT_PAGE_ID=$NOTION_PARENT_PAGE_ID
ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY
PORT=8420
EOF
echo -e "${GREEN}✓ .env written${NC}"

# ── Google OAuth ──────────────────────────────────────────────────────────

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  Google OAuth — getting refresh token${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "A browser window will open. Sign in and grant calendar access."
echo "The refresh token will be added to your .env automatically."
echo ""
read -p "Press Enter to open browser..."

# Run auth script and capture refresh token
REFRESH_TOKEN=$(npx ts-node "$BACKEND_DIR/auth.ts" 2>/dev/null | grep "GOOGLE_REFRESH_TOKEN=" | cut -d= -f2-)

if [ -z "$REFRESH_TOKEN" ]; then
  echo -e "${YELLOW}⚠ Could not auto-capture token. Run manually:${NC}"
  echo "  cd backend && npx ts-node auth.ts"
  echo "  Then paste GOOGLE_REFRESH_TOKEN into backend/.env"
else
  echo "GOOGLE_REFRESH_TOKEN=$REFRESH_TOKEN" >> "$BACKEND_DIR/.env"
  echo -e "${GREEN}✓ Refresh token saved${NC}"
fi

# ── Test connection ───────────────────────────────────────────────────────

echo ""
echo -e "${CYAN}Testing backend...${NC}"
cd "$BACKEND_DIR"
npm start &
SERVER_PID=$!
sleep 8

HEALTH=$(curl -s http://localhost:8420/health 2>/dev/null)
kill $SERVER_PID 2>/dev/null

if echo "$HEALTH" | grep -q '"ok":true'; then
  echo -e "${GREEN}✓ Backend healthy${NC}"
else
  echo -e "${YELLOW}⚠ Backend test inconclusive — check manually with: npm start${NC}"
fi

# ── Optional auto-run ─────────────────────────────────────────────────────

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
read -p "Set up weekly auto-run every Monday at 7am? (y/n): " AUTORUN

if [[ "$AUTORUN" == "y" || "$AUTORUN" == "Y" ]]; then
  NODE_PATH=$(which node)
  TSNODE_PATH="$BACKEND_DIR/node_modules/.bin/ts-node"

  cat > "$PLIST_PATH" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$PLIST_NAME</string>
    <key>ProgramArguments</key>
    <array>
        <string>$NODE_PATH</string>
        <string>$TSNODE_PATH</string>
        <string>$BACKEND_DIR/autorun.ts</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>
    <key>WorkingDirectory</key>
    <string>$BACKEND_DIR</string>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Weekday</key>
        <integer>2</integer>
        <key>Hour</key>
        <integer>7</integer>
        <key>Minute</key>
        <integer>0</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>$HOME/Library/Logs/cal-bridge-autorun.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/Library/Logs/cal-bridge-autorun-error.log</string>
    <key>RunAtLoad</key>
    <false/>
</dict>
</plist>
EOF

  launchctl load "$PLIST_PATH"
  echo -e "${GREEN}✓ Auto-run scheduled every Monday at 7am${NC}"
  echo "  Logs: ~/Library/Logs/cal-bridge-autorun.log"
fi

# ── Done ──────────────────────────────────────────────────────────────────

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  ✓ Setup complete!${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "Next steps:"
echo "  1. Copy CalBridge.app to /Applications"
echo "  2. Launch it — the backend starts automatically"
echo "  3. Hover over the calendar icon in your menu bar"
echo ""
