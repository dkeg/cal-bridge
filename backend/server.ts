import "dotenv/config";
import express from "express";
import cors from "cors";
import {
  listCalendars,
  fetchEvents,
  fetchEventsWithSync,
  createNotionPage,
  createObsidianPage,
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
  syncTarget: "notion" as "notion" | "obsidian",
  obsidianAPIKey: "",
  obsidianVaultPath: "",
  obsidianFolder: "Calendar",
  obsidianFilename: "Upcoming Events.md",
};

// ── Health ────────────────────────────────────────────────────────────────

app.get("/health", (_req, res) => {
  const missing = [];
  if (!process.env.GOOGLE_CLIENT_ID) missing.push("GOOGLE_CLIENT_ID");
  if (!process.env.GOOGLE_REFRESH_TOKEN) missing.push("GOOGLE_REFRESH_TOKEN");
  if (!process.env.NOTION_API_KEY) missing.push("NOTION_API_KEY");
  res.json({ ok: missing.length === 0, missing, ts: new Date().toISOString() });
});

// ── OAuth callback server (port 8421) ────────────────────────────────────────

import * as http from "http";

let pendingOAuthCode: string | null = null;

const oauthServer = http.createServer((req, res) => {
  const url = new URL(req.url ?? "/", "http://localhost:8421");
  if (url.pathname === "/oauth2callback") {
    const code = url.searchParams.get("code");
    res.writeHead(200, { "Content-Type": "text/html" });
    res.end("<html><body><h2>Authorization complete!</h2><p>You can close this tab and return to Cal Notion Bar.</p></body></html>");
    if (code) {
      pendingOAuthCode = code;
      console.log("[oauth] code received, ready for exchange");
    }
  } else {
    res.writeHead(404);
    res.end();
  }
});

oauthServer.listen(8421, () => {
  console.log("OAuth callback server running on http://localhost:8421");
});

// ── POST /oauth/store-code ───────────────────────────────────────────────────

app.post("/oauth/store-code", (req, res) => {
  const { code } = req.body;
  if (code) {
    pendingOAuthCode = code;
    console.log("[oauth] code stored from URI callback");
  }
  res.json({ ok: true });
});

// ── GET /oauth/code ──────────────────────────────────────────────────────────

app.get("/oauth/code", (_req, res) => {
  if (pendingOAuthCode) {
    const code = pendingOAuthCode;
    pendingOAuthCode = null;
    res.json({ code });
  } else {
    res.json({ code: null });
  }
});

// ── POST /oauth/exchange ─────────────────────────────────────────────────────

app.post("/oauth/exchange", async (req, res) => {
  try {
    const { code, redirectURI } = req.body;
    const clientId = process.env.GOOGLE_CLIENT_ID;
    const clientSecret = process.env.GOOGLE_CLIENT_SECRET;

    if (!clientId) {
      return res.status(500).json({ error: "Missing Google credentials in .env" });
    }

    // iOS clients don't use client_secret
    const isIOSClient = clientId.includes(".apps.googleusercontent.com") && !clientSecret;
    const params = new URLSearchParams({
      code,
      client_id: clientId,
      redirect_uri: redirectURI || "com.googleusercontent.apps.89308251794-5vntu2vjqs36mdpcetqn0lb4oi0tke8t:/oauth2callback",
      grant_type: "authorization_code",
      ...(clientSecret ? { client_secret: clientSecret } : {}),
    });

    const response = await fetch("https://oauth2.googleapis.com/token", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: params.toString(),
    });

    const data = await response.json() as any;
    if (data.refresh_token) {
      process.env.GOOGLE_REFRESH_TOKEN = data.refresh_token;
      console.log("[oauth] refresh token obtained and set");
      res.json({ refresh_token: data.refresh_token });
    } else {
      console.error("[oauth] no refresh token:", data);
      res.status(400).json({ error: data.error ?? "No refresh token returned" });
    }
  } catch (e: any) {
    console.error("[oauth/exchange]", e.message);
    res.status(500).json({ error: e.message });
  }
});

// ── POST /credentials ────────────────────────────────────────────────────────

app.post("/credentials", (req, res) => {
  const { googleRefreshToken, notionAPIKey } = req.body;
  if (googleRefreshToken) process.env.GOOGLE_REFRESH_TOKEN = googleRefreshToken;
  if (notionAPIKey) process.env.NOTION_API_KEY = notionAPIKey;
  console.log("[credentials] updated from Keychain");
  res.json({ ok: true });
});

// ── GET /settings ─────────────────────────────────────────────────────────

app.get("/settings", (_req, res) => {
  res.json({
    notificationEmail: runtimeSettings.notificationEmail,
    resendAPIKey: runtimeSettings.resendAPIKey ? "••••••••" : "",
    syncTarget: runtimeSettings.syncTarget,
    obsidianVaultPath: runtimeSettings.obsidianVaultPath,
    obsidianFolder: runtimeSettings.obsidianFolder,
    obsidianFilename: runtimeSettings.obsidianFilename,
    obsidianAPIKey: runtimeSettings.obsidianAPIKey ? "••••••••" : "",
  });
});

// ── POST /settings ────────────────────────────────────────────────────────

app.post("/settings", (req, res) => {
  const { notificationEmail, resendAPIKey, syncTarget, obsidianAPIKey, obsidianVaultPath, obsidianFolder, obsidianFilename } = req.body;
  if (notificationEmail !== undefined) runtimeSettings.notificationEmail = notificationEmail;
  if (resendAPIKey !== undefined && resendAPIKey !== "") runtimeSettings.resendAPIKey = resendAPIKey;
  if (syncTarget !== undefined) runtimeSettings.syncTarget = syncTarget;
  if (obsidianAPIKey !== undefined && obsidianAPIKey !== "") runtimeSettings.obsidianAPIKey = obsidianAPIKey;
  if (obsidianVaultPath !== undefined) runtimeSettings.obsidianVaultPath = obsidianVaultPath;
  if (obsidianFolder !== undefined) runtimeSettings.obsidianFolder = obsidianFolder;
  if (obsidianFilename !== undefined) runtimeSettings.obsidianFilename = obsidianFilename;
  console.log("[settings] updated — syncTarget:", runtimeSettings.syncTarget);
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

// ── POST /obsidian ───────────────────────────────────────────────────────────

app.post("/obsidian", async (req, res) => {
  try {
    const { days, start, end }: { days: DayGroup[]; start: string; end: string } = req.body;
    const result = await createObsidianPage(days, start, end, {
      apiKey: runtimeSettings.obsidianAPIKey,
      vaultPath: runtimeSettings.obsidianVaultPath,
      folder: runtimeSettings.obsidianFolder,
      filename: runtimeSettings.obsidianFilename,
    });

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
    console.error("[/obsidian]", e.message);
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