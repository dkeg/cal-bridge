import "dotenv/config";
import express from "express";
import cors from "cors";
import {
  listCalendars,
  fetchEvents,
  createNotionPage,
  checkExistingPage,
  groupByDay,
  dateRange,
  todayString,
  sendNotification,
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
    const events = await fetchEvents(calendars, start, end);
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

// ── Start ─────────────────────────────────────────────────────────────────

app.listen(PORT, () => {
  console.log(`\n✅ cal-notion backend running on http://localhost:${PORT}`);
  console.log(`   Health: http://localhost:${PORT}/health\n`);
});