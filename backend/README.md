# cal-notion backend v3

Direct Google Calendar API + Notion API — no MCP, no Claude session dependency.

## Setup

### 1. Install dependencies
```bash
npm install
```

### 2. Google Cloud setup (one-time, ~5 min)

> Note: You need a Google account that can create a Google Cloud project.
> If your account can't create projects, use any personal Gmail to create
> the project, then grant it access to your calendar via sharing.

1. Go to https://console.cloud.google.com
2. Create a new project (e.g. "cal-notion")
3. Enable **Google Calendar API**: APIs & Services → Enable APIs → search "Google Calendar API"
4. Create credentials: APIs & Services → Credentials → Create Credentials → OAuth 2.0 Client ID
   - Application type: **Desktop app**
   - Name: "cal-notion"
5. Download the credentials JSON — copy `client_id` and `client_secret`

### 3. Notion setup (one-time, ~2 min)

1. Go to https://notion.so/my-integrations
2. Click "New integration" → name it "cal-notion" → select your workspace
3. Copy the **Internal Integration Token**
4. Open your Notion "Upcoming Schedules" page
5. Click ••• → Connections → Connect to "cal-notion"

### 4. Configure .env
```bash
cp .env.example .env
```

Fill in:
```
GOOGLE_CLIENT_ID=your_client_id
GOOGLE_CLIENT_SECRET=your_client_secret
NOTION_API_KEY=your_notion_token
NOTION_PARENT_PAGE_ID=34fe3e22-d20b-8187-9919-c0c030f1eba3
```

### 5. Get Google refresh token (one-time)
```bash
npx ts-node auth.ts
```

This opens a browser, you log in with your Google account, and it prints
your refresh token. Add it to `.env`:
```
GOOGLE_REFRESH_TOKEN=1//0g...
```

### 6. Start the server
```bash
npm start
```

### 7. Test
```bash
curl http://localhost:8420/health
curl http://localhost:8420/calendars
```

## API

| Route | Method | Description |
|-------|--------|-------------|
| `/health` | GET | Config check — shows missing env vars |
| `/calendars` | GET | Lists all Google Calendars |
| `/today` | GET | Today's events + count (for menu bar badge) |
| `/events` | POST | `{ calendars, weeksAhead }` → events |
| `/notion` | POST | `{ days, start, end }` → creates Notion page |
