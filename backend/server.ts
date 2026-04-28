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
  Calendar,
  DayGroup,
} from "./agent";

const app = express();
app.use(cors());
app.use(express.json());

const PORT = process.env.PORT ?? 8420;

// ── Health ────────────────────────────────────────────────────────────────

app.get("/health", (_req, res) => {
  const missing = [];
  if (!process.env.GOOGLE_CLIENT_ID) missing.push("GOOGLE_CLIENT_ID");
  if (!process.env.GOOGLE_CLIENT_SECRET) missing.push("GOOGLE_CLIENT_SECRET");
  if (!process.env.GOOGLE_REFRESH_TOKEN) missing.push("GOOGLE_REFRESH_TOKEN");
  if (!process.env.NOTION_API_KEY) missing.push("NOTION_API_KEY");
  res.json({ ok: missing.length === 0, missing, ts: new Date().toISOString() });
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
      weeksAhead = 2,
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

    // Check for existing page first
    const existing = await checkExistingPage(start, end);
    if (existing) {
      return res.json({ ...existing, existed: true });
    }

    const result = await createNotionPage(days, start, end);
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
