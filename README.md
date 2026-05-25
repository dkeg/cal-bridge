# Cal → Notion

Note - screen captures and recording are behind most recent version, but core functioniliy is the same.

A native macOS menu bar app that fetches events from all your Google Calendars and posts a formatted weekly schedule to Notion — automatically every Sunday night, or on demand.

<br>

<table>
  <tr>
    <td align="center" width="220">
      <img src="docs/popover-idle.png" width="200" alt="Compact popover"/><br/>
      <sub>Hover to open</sub>
    </td>
    <td align="center" width="280">
      <img src="docs/popover-preview.png" width="260" alt="Preview events"/><br/>
      <sub>Preview &amp; edit events</sub>
    </td>
    <td align="center" width="280">
      <img src="docs/notion-result.png" width="260" alt="Notion output"/><br/>
      <sub>Posted to Notion</sub>
    </td>
  </tr>
</table>

<br>

---

## Demo

▶ [Watch the demo on Loom](https://www.loom.com/share/20bf6148ad0d41f1aa7a11e7843245d0)

## Features

- 🗓️ Hover over the menu bar icon — events load automatically, no button needed
- 📅 Fetches 1 week by default; modify to 1–4 weeks inline
- ✏️ Preview and edit events before posting
- 📝 Posts a beautifully formatted day-by-day table to Notion
- 🔁 Auto-runs every Sunday at 9 PM via launchd
- ✉️ Email notification on every post (manual and autorun)
- 💾 Persists posted state across relaunches — shows "Open in Notion" when already posted
- ✨ Autorun banner shows when the Sunday sync has fired
- ⚠️ Warns if a page for that date range already exists

---

## Install

### Option A — Homebrew (recommended)

```bash
brew tap dkeg/cal-notion
brew install --cask cal-notion
```

Then run the setup script:

```bash
./scripts/install.sh
```

### Option B — Direct download

1. Download the latest `CalNotion.dmg` from [Releases](https://github.com/dkeg/cal-notion/releases)
2. Open the DMG, drag `CalNotionBar.app` to `/Applications`
3. Clone this repo and run the setup script:

```bash
git clone https://github.com/dkeg/cal-notion.git
cd cal-notion
chmod +x scripts/install.sh
./scripts/install.sh
```

---

## Setup

### Prerequisites

- macOS 13+
- Node.js 18+ (`brew install node`)
- A Google account
- A Notion account
- A [Resend](https://resend.com) account (free tier, for email notifications)

### First-time setup

Cal Notion Bar includes a built-in setup flow — no terminal or config file editing required.

1. Launch `CalNotionBar.app` from `/Applications`
2. The setup window appears automatically on first launch
3. Click **Connect with Google** — your browser opens for OAuth authorization
4. Authorize access to Google Calendar
5. Return to the app — it captures the token automatically
6. Enter your Notion integration token (get it at [notion.so/my-integrations](https://notion.so/my-integrations))
7. Click **Finish Setup**

Your credentials are stored securely in macOS Keychain — no `.env` editing needed.

### Notion page setup

1. Go to [notion.so/my-integrations](https://notion.so/my-integrations)
2. Create a new integration → copy the **Integration Token**
3. Open the Notion page you want to post under
4. Click `···` → Connections → connect your integration

### Resend (email notifications)

1. Sign up at [resend.com](https://resend.com)
2. Copy your **API Key** from the dashboard
3. Enter it in **Settings → Configuration → Resend API Key**

---

## Usage

1. Launch `CalNotionBar.app` from `/Applications`
2. Hover over the calendar icon — events load automatically
3. Optionally click **Modify** to change the number of weeks (1–4)
4. Toggle calendars on/off, edit or remove individual events
5. Click **Post to Notion →** to post
6. Button changes to **Open in Notion** once posted — persists across relaunches

---

## Autorun

The app runs automatically every Sunday at 9 PM via a launchd agent. After firing it:
- Writes a flag file to `~/Library/Application Support/CalNotionBar/last-run.json`
- Sends an email notification to your configured address
- Shows an "Auto-synced" banner the next time you open the popover

To set up or recreate the launchd agent:

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.drewcraig.cal-notion-autorun.plist
```

To test manually:

```bash
node ~/Projects/cal-notion-v3/backend/dist/autorun.js
```

---

## Development

```bash
# Clone
git clone https://github.com/dkeg/cal-notion.git
cd cal-notion

# Backend
cd backend
cp .env.example .env
# fill in credentials
npm install
npx ts-node auth.ts   # get Google refresh token
npm start             # runs on localhost:8420

# Compile autorun
npx tsc autorun.ts --outDir dist --esModuleInterop --resolveJsonModule --module commonjs --target es2020

# Swift app
open CalNotionBar/CalNotionBar.xcodeproj
# Build and run in Xcode (⌘R)
```

### Releasing a new version

```bash
git tag v1.1.0
git push origin v1.1.0
```

GitHub Actions will automatically build the `.dmg` and create a release.

---

## Architecture

```
CalNotionBar.app (Swift/SwiftUI)
  └── spawns → backend (Express + TypeScript) on localhost:8420
                 ├── /calendars  → Google Calendar API
                 ├── /events     → Google Calendar API
                 ├── /today      → Google Calendar API (badge count)
                 └── /notion     → Notion API + Resend email

launchd agent (Sunday 9 PM)
  └── dist/autorun.js
        ├── fetches 1 week of events
        ├── posts to Notion
        ├── sends email via Resend
        └── writes ~/Library/Application Support/CalNotionBar/last-run.json
```

---

## Environment Variables

| Variable | Description |
|----------|-------------|
| `GOOGLE_CLIENT_ID` | Google OAuth client ID |
| `GOOGLE_CLIENT_SECRET` | Google OAuth client secret |
| `GOOGLE_REFRESH_TOKEN` | Long-lived refresh token (from `auth.ts`) |
| `NOTION_API_KEY` | Notion integration token |
| `NOTION_PARENT_PAGE_ID` | ID of the parent Notion page |
| `RESEND_API_KEY` | Resend API key for email notifications |
| `PORT` | Backend port (default: 8420) |

---

## License

MIT
