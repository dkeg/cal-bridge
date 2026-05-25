# Changelog

All notable changes to Cal → Notion are documented here.

---

## [1.2.0] — 2026-05-09

### Added
- **Settings window** — gear icon in popover header opens a three-tab settings panel
- **General tab** — configure default weeks (1–4) and default calendar selection; persisted across relaunches
- **Configuration tab** — set notification email and Resend API key without touching `.env`
- **About tab** — app version, year, and "Check for updates" button that pings GitHub releases API
- **Runtime settings endpoint** — `GET /settings` and `POST /settings` on the backend; settings applied in-memory without restarting
- **`NOTIFICATION_EMAIL`** environment variable support as a `.env` fallback for notification email

### Changed
- Notification email and Resend API key moved from hardcoded values to configurable settings
- `sendNotification()` now accepts `email` and `apiKey` params, falling back to `.env` values if not set via settings
- Version check uses numeric comparison (`orderedDescending`) instead of string equality

### Fixed
- "Check for updates" no longer shows false positive when GitHub has an older release tag than local version

---

## [1.1.0] — 2026-05-09

### Added
- **Auto-load on hover** — events fetch automatically when the popover opens; no run button needed
- **Modify panel** — inline week selector (1–4 wk pills) replaces the old weeks + play button UI
- **Smart primary button** — shows "Post to Notion →" when unposted, switches to "Open in Notion" after posting
- **Persisted posted state** — UserDefaults stores the last posted Notion URL and date range; survives app relaunches
- **Sunday autorun** — launchd agent fires every Sunday at 9 PM (moved from Monday 7 AM)
- **Email notifications** — Resend integration sends an email on every post, both manual and autorun
- **Autorun banner** — "Auto-synced Sunday, May X at 9:00 PM" banner appears on next popover open after autorun fires
- **Autorun flag file** — `~/Library/Application Support/CalBridge/last-run.json` written after each autorun with Notion URL, title, date range, and timestamp
- **`RESEND_API_KEY`** environment variable for email notification support

### Changed
- Popover now opens small (80px) with a spinner, then expands to full height (580px) once events load — eliminates gray flash on open
- Default weeks ahead changed from 2 to 1
- autorun compiled to `dist/autorun.js` — no ts-node dependency at runtime
- Removed Re-fetch button from footer; replaced with Modify
- Removed compact idle state and play button UI

### Fixed
- launchd agent now uses correct node path (`/opt/homebrew/bin/node`)
- Email `to` address corrected (`drewrcraig.9@gmail.com`)
- Existing page path now also triggers email notification
- Old DerivedData build caches cleaned up
- `.DS_Store` and `.xcuserstate` added to `.gitignore`

---

## [1.0.0] — 2026-04-19

### Added
- Initial release
- Native macOS menu bar app (Swift/SwiftUI)
- Google Calendar integration via OAuth 2.0
- Notion page creation with day-by-day event table
- Calendar toggle chips
- Inline event editing and removal
- Step indicator during fetch/post flow
- Monday 7 AM autorun via launchd
- Existing page detection with warning
- Backend Express server on localhost:8420
