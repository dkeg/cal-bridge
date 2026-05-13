import "dotenv/config";
import express from "express";
import cors from "cors";
import {
  listCalendars,
  fetchEvents,
  fetchEventsWithSync,
  createNotionPage,
  checkExistingPage,
  groupByDay,
  dateRange,
  todayString,
  sendNotification,
  pollForChanges,
  storeSyncToken,
  clearSyncTokens,
  Calendar,
  DayGroup,
} from "./agent";

const app = express();
app.use(cors());
app.use(express.json());

const PORT = process.env.PORT ?? 8420;

// ── In-memory settings (overrides .env at runtime) ────────────────────────

export const runtimeSettings = {
  notificationEmail: process.env.NOTIFICATION_EMAIL ?? "drewrcraig.9@gmail.com",
  resendAPIKey: process.env.RESEND_API_KEY ?? "",
};

// ── Health ────────────────────────────────────────────────────────────────

app.get("/health", (_req, res) => {
  const missing = [];
  if (!process.env.GOOGLE_CLIENT_ID) missing.push("GOOGLE_CLIENT_ID");
  if (!process.env.GOOGLE_CLIENT_SECRET) missing.push("GOOGLE_CLIENT_SECRET");
  if (!process.env.GOOGLE_REFRESH_TOKEN) missing.push("GOOGLE_REFRESH_TOKEN");
  if (!process.env.NOTION_API_KEY) missing.push("NOTION_API_KEY");
  res.json({ ok: missing.length === 0, missing, ts: new Date().toISOString() });
});

// ── GET /settings ─────────────────────────────────────────────────────────

app.get("/settings", (_req, res) => {
  res.json({
    notificationEmail: runtimeSettings.notificationEmail,
    resendAPIKey: runtimeSettings.resendAPIKey ? "••••••••" : "",
  });
});

// ── POST /settings ────────────────────────────────────────────────────────

app.post("/settings", (req, res) => {
  const { notificationEmail, resendAPIKey } = req.body;
  if (notificationEmail !== undefined) runtimeSettings.notificationEmail = notificationEmail;
  if (resendAPIKey !== undefined && resendAPIKey !== "") runtimeSettings.resendAPIKey = resendAPIKey;
  console.log("[settings] updated:", {
    notificationEmail: runtimeSettings.notificationEmail,
    resendAPIKey: runtimeSettings.resendAPIKey ? "set" : "not set",
  });
  res.json({ ok: true });
});

// ── GET /calendars ────────────────────────────────────────────────────────

app.get("/calendars", async (_req, res) => {
  try {
    const calendars = await listCalendars();
    res.json({ calendars });
  } catch (e: any) {
    console.error("[/calendars]", e.message);
    res.status(500).json({ error: e.message });
  }
});

// ── GET /today ────────────────────────────────────────────────────────────

app.get("/today", async (_req, res) => {
  try {
    const today = todayString();
    const calendars = await listCalendars();
    const events = await fetchEvents(calendars, today, today);
    res.json({ count: events.length, events, date: today });
  } catch (e: any) {
    console.error("[/today]", e.message);
    res.status(500).json({ error: e.message });
  }
});

// ── POST /events ──────────────────────────────────────────────────────────

app.post("/events", async (req, res) => {
  try {
    const {
      calendars,
      weeksAhead = 1,
    }: { calendars: Calendar[]; weeksAhead: number } = req.body;
    const { start, end } = dateRange(weeksAhead);
    const { events, syncTokens } = await fetchEventsWithSync(calendars, start, end);
    // Store sync tokens for change detection
    for (const [calId, token] of Object.entries(syncTokens)) {
      storeSyncToken(calId, token);
    }
    console.log(`[/events] fetched ${events.length} events, stored ${Object.keys(syncTokens).length} sync tokens`);
    res.json({ events, start, end });
  } catch (e: any) {
    console.error("[/events]", e.message);
    res.status(500).json({ error: e.message });
  }
});

// ── POST /notion ──────────────────────────────────────────────────────────

app.post("/notion", async (req, res) => {
  try {
    const {
      days,
      start,
      end,
    }: { days: DayGroup[]; start: string; end: string } = req.body;

    const existing = await checkExistingPage(start, end);
    if (existing) {
      sendNotification({
        title: existing.title ?? "",
        url: existing.url,
        start,
        end,
        eventCount: days.reduce((sum, d) => sum + d.events.length, 0),
        source: "manual",
        email: runtimeSettings.notificationEmail,
        apiKey: runtimeSettings.resendAPIKey,
      }).catch(e => console.error("[notify]", e.message));
      return res.json({ ...existing, existed: true });
    }

    const result = await createNotionPage(days, start, end);
    const eventCount = days.reduce((sum, d) => sum + d.events.length, 0);

    sendNotification({
      title: result.title,
      url: result.url,
      start,
      end,
      eventCount,
      source: "manual",
      email: runtimeSettings.notificationEmail,
      apiKey: runtimeSettings.resendAPIKey,
    }).catch(e => console.error("[notify]", e.message));

    res.json({ ...result, existed: false });
  } catch (e: any) {
    console.error("[/notion]", e.message);
    res.status(500).json({ error: e.message });
  }
});

// ── GET /poll ─────────────────────────────────────────────────────────────

app.get("/poll", async (_req, res) => {
  try {
    const calendars = await listCalendars();
    const { hasChanges, changedEvents } = await pollForChanges(calendars);
    res.json({ hasChanges, changeCount: changedEvents.length, changedEvents });
  } catch (e: any) {
    console.error("[/poll]", e.message);
    res.status(500).json({ error: e.message });
  }
});

// ── POST /resync ──────────────────────────────────────────────────────────

app.post("/resync", async (req, res) => {
  try {
    const { weeksAhead = 1 }: { weeksAhead: number } = req.body;
    const calendars = await listCalendars();
    const { start, end } = dateRange(weeksAhead);

    // Full fetch and store new sync tokens
    const { events, syncTokens } = await fetchEventsWithSync(calendars, start, end);
    for (const [calId, token] of Object.entries(syncTokens)) {
      storeSyncToken(calId, token);
    }

    const days = groupByDay(events);

    // Delete existing page and create fresh
    clearSyncTokens();
    const result = await createNotionPage(days, start, end);

    sendNotification({
      title: result.title,
      url: result.url,
      start,
      end,
      eventCount: events.length,
      source: "manual",
      email: runtimeSettings.notificationEmail,
      apiKey: runtimeSettings.resendAPIKey,
    }).catch(e => console.error("[notify]", e.message));

    res.json({ ...result, events, start, end });
  } catch (e: any) {
    console.error("[/resync]", e.message);
    res.status(500).json({ error: e.message });
  }
});

// ── Start ─────────────────────────────────────────────────────────────────

app.listen(PORT, () => {
  console.log(`\n✅ cal-notion backend running on http://localhost:${PORT}`);
  console.log(`   Health: http://localhost:${PORT}/health\n`);
});