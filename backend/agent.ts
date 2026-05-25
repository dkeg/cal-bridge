import "dotenv/config";
import { google } from "googleapis";
import { Client as NotionClient } from "@notionhq/client";

export interface Calendar {
  id: string;
  label: string;
}
export interface CalEvent {
  date: string;
  start: string | null;
  end: string | null;
  title: string;
  calendar: string;
  allDay: boolean;
}
export interface DayGroup {
  date: string;
  events: CalEvent[];
}

export const NOTION_PARENT_ID =
  process.env.NOTION_PARENT_PAGE_ID ?? "34fe3e22-d20b-8187-9919-c0c030f1eba3";

function getGoogleAuth() {
  const oauth2 = new google.auth.OAuth2(
    process.env.GOOGLE_CLIENT_ID,
    process.env.GOOGLE_CLIENT_SECRET,
  );
  oauth2.setCredentials({ refresh_token: process.env.GOOGLE_REFRESH_TOKEN });
  return oauth2;
}

function getCalendarClient() {
  return google.calendar({ version: "v3", auth: getGoogleAuth() });
}

function getNotionClient() {
  return new NotionClient({ auth: process.env.NOTION_API_KEY });
}

export async function listCalendars(): Promise<Calendar[]> {
  const cal = getCalendarClient();
  const res = await cal.calendarList.list();
  return (res.data.items ?? []).map((c) => ({
    id: c.id!,
    label: c.summary ?? c.id!,
  }));
}

export async function fetchEvents(
  calendars: Calendar[],
  start: string,
  end: string,
): Promise<CalEvent[]> {
  const cal = getCalendarClient();
  const all: CalEvent[] = [];
  await Promise.all(
    calendars.map(async (c) => {
      try {
        const res = await cal.events.list({
          calendarId: c.id,
          timeMin: `${start}T00:00:00Z`,
          timeMax: `${end}T23:59:59Z`,
          singleEvents: true,
          orderBy: "startTime",
          maxResults: 250,
        });
        for (const e of res.data.items ?? []) {
          const allDay = !e.start?.dateTime;
          const date = allDay
            ? (e.start?.date ?? "")
            : (e.start?.dateTime?.split("T")[0] ?? "");
          all.push({
            date,
            start: e.start?.dateTime ?? null,
            end: e.end?.dateTime ?? null,
            title: e.summary ?? "(no title)",
            calendar: c.label,
            allDay,
          });
        }
      } catch (err: any) {
        console.warn(`[agent] Skipping calendar ${c.label}: ${err.message}`);
      }
    }),
  );
  return all.sort((a, b) => {
    if (a.date !== b.date) return a.date.localeCompare(b.date);
    return (a.start ?? "").localeCompare(b.start ?? "");
  });
}

const CAL_EMOJI: Record<string, string> = {
  drew: "👤",
  kristen: "👤",
  family: "👨‍👩‍👧",
  farmfresh: "🌿",
  holiday: "🎉",
  default: "📅",
};

function getEmoji(calLabel: string): string {
  const key = Object.keys(CAL_EMOJI).find((k) =>
    calLabel.toLowerCase().includes(k),
  );
  return key ? CAL_EMOJI[key] : CAL_EMOJI["default"];
}

// Build a table block for a single day's events
// Columns: Time | Event | Calendar
function buildDayTable(events: CalEvent[]): any {
  const tableRows: any[] = [];

  // Header row
  tableRows.push({
    object: "block",
    type: "table_row",
    table_row: {
      cells: [
        [
          {
            type: "text",
            text: { content: "Time" },
            annotations: { bold: true, color: "gray" },
          },
        ],
        [
          {
            type: "text",
            text: { content: "Event" },
            annotations: { bold: true, color: "gray" },
          },
        ],
        [
          {
            type: "text",
            text: { content: "Calendar" },
            annotations: { bold: true, color: "gray" },
          },
        ],
      ],
    },
  });

  // Event rows
  for (const e of events) {
    const time =
      e.allDay || !e.start
        ? "All day"
        : `${fmtTime(e.start)} – ${fmtTime(e.end ?? e.start)}`;

    tableRows.push({
      object: "block",
      type: "table_row",
      table_row: {
        cells: [
          [
            {
              type: "text",
              text: { content: time },
              annotations: { color: "gray" },
            },
          ],
          [{ type: "text", text: { content: e.title } }],
          [
            {
              type: "text",
              text: { content: `${getEmoji(e.calendar)} ${e.calendar}` },
              annotations: { color: "gray" },
            },
          ],
        ],
      },
    });
  }

  return {
    object: "block",
    type: "table",
    table: {
      table_width: 3,
      has_column_header: true,
      has_row_header: false,
      children: tableRows,
    },
  };
}

export async function checkExistingPage(
  start: string,
  end: string
): Promise<{ url: string | null; id: string | null; title: string } | null> {
  const notion = getNotionClient();
  const title = `Upcoming Events — ${start} to ${end}`;
  try {
    const results = await notion.search({
      query: title,
      filter: { property: "object", value: "page" },
    });
    const match = results.results.find(
      (p: any) => p.properties?.title?.title?.[0]?.plain_text === title
    );
    if (match) {
      return { url: (match as any).url, id: match.id, title };
    }
  } catch { }
  return null;
}

export async function createNotionPage(
  days: DayGroup[],
  start: string,
  end: string,
): Promise<{ url: string | null; id: string | null; title: string }> {
  const notion = getNotionClient();
  const title = `Upcoming Events — ${start} to ${end}`;
  const totalEvents = days.reduce((s, d) => s + d.events.length, 0);
  const calNames = [
    ...new Set(days.flatMap((d) => d.events.map((e) => e.calendar))),
  ];
  const blocks: any[] = [];

  // Summary callout
  blocks.push({
    object: "block",
    type: "callout",
    callout: {
      rich_text: [
        {
          type: "text",
          text: {
            content: `${totalEvents} events · ${days.length} days · ${calNames.length} calendars\n`,
          },
          annotations: { bold: true },
        },
        {
          type: "text",
          text: { content: `${fmtDateLong(start)} → ${fmtDateLong(end)}` },
        },
      ],
      icon: { emoji: "🗓️" },
      color: "blue_background",
    },
  });

  // Calendar legend
  blocks.push({
    object: "block",
    type: "paragraph",
    paragraph: {
      rich_text: calNames.flatMap((cal, i) => [
        {
          type: "text",
          text: { content: `${getEmoji(cal)} ${cal}` },
          annotations: { code: true },
        },
        {
          type: "text",
          text: { content: i < calNames.length - 1 ? "   " : "" },
        },
      ]),
    },
  });

  blocks.push({ object: "block", type: "divider", divider: {} });

  // One section per day
  for (const { date, events } of days) {
    // Day heading
    blocks.push({
      object: "block",
      type: "heading_2",
      heading_2: {
        rich_text: [
          { type: "text", text: { content: `📆  ${fmtDate(date)}` } },
        ],
        is_toggleable: false,
      },
    });

    // Table of events for this day
    blocks.push(buildDayTable(events));

    // Divider between days
    blocks.push({ object: "block", type: "divider", divider: {} });
  }

  // Create page — tables with children must be sent nested
  // Notion API requires table children sent with the table block itself
  // Split into top-level blocks (non-table) and handle tables carefully
  const page = await notion.pages.create({
    parent: { page_id: NOTION_PARENT_ID },
    icon: { emoji: "🗓️" },
    properties: { title: { title: [{ text: { content: title } }] } },
    children: blocks.slice(0, 100),
  });

  if (blocks.length > 100) {
    const remaining = blocks.slice(100);
    for (let i = 0; i < remaining.length; i += 100) {
      await notion.blocks.children.append({
        block_id: page.id,
        children: remaining.slice(i, i + 100),
      });
    }
  }

  return { url: (page as any).url ?? null, id: page.id, title };
}

export function fmtTime(iso: string): string {
  return new Date(iso).toLocaleTimeString([], {
    hour: "numeric",
    minute: "2-digit",
  });
}

export function fmtDate(dateStr: string): string {
  return new Date(dateStr + "T12:00:00").toLocaleDateString([], {
    weekday: "long",
    month: "long",
    day: "numeric",
    year: "numeric",
  });
}

export function fmtDateLong(dateStr: string): string {
  return new Date(dateStr + "T12:00:00").toLocaleDateString([], {
    month: "long",
    day: "numeric",
    year: "numeric",
  });
}

export function dateRange(weeksAhead = 2): { start: string; end: string } {
  const now = new Date();
  const start = now.toISOString().split("T")[0];
  const end = new Date(now.getTime() + weeksAhead * 7 * 86400000)
    .toISOString()
    .split("T")[0];
  return { start, end };
}

export function todayString(): string {
  return new Date().toISOString().split("T")[0];
}

export function groupByDay(events: CalEvent[]): DayGroup[] {
  const grouped: Record<string, CalEvent[]> = {};
  for (const e of events) {
    const d = e.date || e.start?.split("T")[0];
    if (!d) continue;
    if (!grouped[d]) grouped[d] = [];
    grouped[d].push(e);
  }
  return Object.keys(grouped)
    .sort()
    .map((date) => ({ date, events: grouped[date] }));
}

// ── Email Notification ────────────────────────────────────────────────────

export async function sendNotification({
  title,
  url,
  start,
  end,
  eventCount,
  source = "manual",
  email,
  apiKey,
}: {
  title: string;
  url: string | null;
  start: string;
  end: string;
  eventCount: number;
  source?: "manual" | "autorun";
  email?: string;
  apiKey?: string;
}): Promise<void> {
  const resolvedKey = apiKey || process.env.RESEND_API_KEY;
  const resolvedEmail = email || process.env.NOTIFICATION_EMAIL || "drewrcraig.9@gmail.com";

  if (!resolvedKey) {
    console.warn("[notify] RESEND_API_KEY not set — skipping email");
    return;
  }

  const label = source === "autorun" ? "Auto-synced" : "Posted";
  const notionLink = url ? `<a href="${url}">${title}</a>` : title;

  const html = `
    <div style="font-family: sans-serif; max-width: 480px;">
      <h3 style="margin-bottom: 4px;">📅 CalBridge — ${label}</h3>
      <p style="color: #555; margin-top: 0;">${start} → ${end} · ${eventCount} events</p>
      <p>${notionLink}</p>
      ${source === "autorun" ? `<p style="color: #888; font-size: 12px;">Sent automatically by your Sunday night autorun.</p>` : ""}
    </div>
  `;

  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${resolvedKey}`,
    },
    body: JSON.stringify({
      from: process.env.RESEND_FROM ?? "onboarding@resend.dev",
      to: resolvedEmail,
      subject: `CalBridge ${label}: ${title}`,
      html,
    }),
  });

  if (!res.ok) {
    const err = await res.text();
    console.error("[notify] Resend error:", err);
  } else {
    console.log(`[notify] Email sent — ${title}`);
  }
}

// ── Sync Token Storage ────────────────────────────────────────────────────

import * as fs from "fs";
import * as path from "path";
import * as os from "os";

const syncTokenPath = path.join(os.homedir(), "Library", "Application Support", "CalBridge", "sync-token.json");

export function storeSyncToken(calendarId: string, token: string): void {
  console.log(`[sync] Storing token for ${calendarId} at ${syncTokenPath}`);
  const dir = path.dirname(syncTokenPath);
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
  let tokens: Record<string, string> = {};
  if (fs.existsSync(syncTokenPath)) {
    try { tokens = JSON.parse(fs.readFileSync(syncTokenPath, "utf8")); } catch {}
  }
  tokens[calendarId] = token;
  fs.writeFileSync(syncTokenPath, JSON.stringify(tokens, null, 2));
}

export function loadSyncTokens(): Record<string, string> {
  if (!fs.existsSync(syncTokenPath)) return {};
  try { return JSON.parse(fs.readFileSync(syncTokenPath, "utf8")); } catch { return {}; }
}

export function clearSyncTokens(): void {
  if (fs.existsSync(syncTokenPath)) fs.unlinkSync(syncTokenPath);
}

// ── Poll For Changes ──────────────────────────────────────────────────────

export async function pollForChanges(calendars: Calendar[]): Promise<{
  hasChanges: boolean;
  changedEvents: CalEvent[];
}> {
  const cal = getCalendarClient();
  const tokens = loadSyncTokens();
  const changedEvents: CalEvent[] = [];
  let hasChanges = false;

  for (const calendar of calendars) {
    const syncToken = tokens[calendar.id];
    if (!syncToken) continue; // no token yet — skip until first full sync

    try {
      const params: any = {
        calendarId: calendar.id,
        singleEvents: true,
        syncToken,
      };

      const res = await cal.events.list(params);
      const items = res.data.items ?? [];

      if (items.length > 0) {
        hasChanges = true;
        for (const item of items) {
          if (item.status === "cancelled") continue;
          changedEvents.push(mapEvent(item, calendar.label));
        }
      }

      // Store updated sync token
      if (res.data.nextSyncToken) {
        storeSyncToken(calendar.id, res.data.nextSyncToken);
      }
    } catch (err: any) {
      // 410 Gone means sync token expired — clear and do full sync next time
      if (err?.code === 410) {
        console.warn(`[poll] Sync token expired for ${calendar.label} — clearing`);
        const tokens = loadSyncTokens();
        delete tokens[calendar.id];
        fs.writeFileSync(syncTokenPath, JSON.stringify(tokens, null, 2));
      } else {
        console.error(`[poll] Error polling ${calendar.label}:`, err.message);
      }
    }
  }

  return { hasChanges, changedEvents };
}

// ── Store sync tokens during full fetch ───────────────────────────────────

export async function fetchEventsWithSync(
  calendars: Calendar[],
  start: string,
  end: string
): Promise<{ events: CalEvent[]; syncTokens: Record<string, string> }> {
  const cal = getCalendarClient();
  const syncTokens: Record<string, string> = {};

  const results = await Promise.allSettled(calendars.map(async (calendar) => {
    const res = await cal.events.list({
      calendarId: calendar.id,
      timeMin: new Date(start + "T00:00:00Z").toISOString(),
      timeMax: new Date(end + "T23:59:59Z").toISOString(),
      singleEvents: true,
      orderBy: "startTime",
      maxResults: 250,
    });

    const events: CalEvent[] = [];
    for (const item of res.data.items ?? []) {
      if (item.status === "cancelled") continue;
      events.push(mapEvent(item, calendar.label));
    }

    // Use the sync token from the main fetch — scoped to this time range,
    // which is all we need for detecting changes to upcoming events.
    if (res.data.nextSyncToken) {
      syncTokens[calendar.id] = res.data.nextSyncToken;
      console.log(`[sync] stored token for ${calendar.label}`);
    }

    return events;
  }));

  const all: CalEvent[] = [];
  for (const result of results) {
    if (result.status === "fulfilled") all.push(...result.value);
    else console.error("[fetch] calendar error:", result.reason?.message);
  }

  return { events: all.sort((a, b) => {
    if (a.date !== b.date) return a.date.localeCompare(b.date);
    return (a.start ?? "").localeCompare(b.start ?? "");
  }), syncTokens };
}

function mapEvent(item: any, calendarLabel: string): CalEvent {
  const start = item.start?.dateTime ?? item.start?.date ?? "";
  const end = item.end?.dateTime ?? item.end?.date ?? "";
  const allDay = !item.start?.dateTime;
  const date = allDay ? start : start.split("T")[0];
  return {
    date,
    start: allDay ? undefined : start,
    end: allDay ? undefined : end,
    title: item.summary ?? "(No title)",
    calendar: calendarLabel,
    allDay,
  };
}

// ── Obsidian Integration ──────────────────────────────────────────────────

import * as https from "https";
import nodeFetch from "node-fetch";
const obsidianAgent = new https.Agent({ rejectUnauthorized: false });
const obsidianFetch = (url: string, options: any) => nodeFetch(url, { ...options, agent: obsidianAgent });

export async function createObsidianPage(
  days: DayGroup[],
  start: string,
  end: string,
  options: {
    apiKey: string;
    vaultPath: string;
    folder: string;
    filename: string;
  }
): Promise<{ url: string | null; title: string }> {
  const totalEvents = days.reduce((sum, d) => sum + d.events.length, 0);
  const title = `Upcoming Events — ${start} to ${end}`;

  // Build Obsidian-native markdown
  const lines: string[] = [
    `# 📅 Upcoming Events`,
    `*${formatDisplayDate(start)} → ${formatDisplayDate(end)} · ${totalEvents} events*`,
    ``,
  ];

  for (const day of days) {
    lines.push(`## ${formatDayHeader(day.date)}`);
    for (const event of day.events) {
      const time = event.allDay ? "All day" : `${formatTime(event.start ?? "")} – ${formatTime(event.end ?? "")}`;
      lines.push(`- ${time} · ${event.title} · *${event.calendar}*`);
    }
    lines.push(``);
  }

  const markdown = lines.join("\n");

  // Ensure folder exists
  if (options.folder) {
    await ensureObsidianFolder(options.folder, options.apiKey);
  }

  // Write to Obsidian vault via Local REST API
  const folder = options.folder ? `${options.folder}/` : "";
  const filename = options.filename.endsWith(".md") ? options.filename : `${options.filename}.md`;
  const filePath = `${folder}${filename}`;

  const obsidianURL = `https://127.0.0.1:27124/vault/${encodeURIComponent(filePath)}`;

  const res = await obsidianFetch(obsidianURL, {
    method: "PUT",
    headers: {
      "Content-Type": "text/markdown",
      "Authorization": `Bearer ${options.apiKey}`,
    },
    body: markdown,
  });

  if (!res.ok) {
    const err = await res.text();
    throw new Error(`Obsidian API error: ${err}`);
  }

  console.log(`[obsidian] Written to vault: ${filePath}`);

  return {
    url: `obsidian://open?vault=${encodeURIComponent(options.vaultPath)}&file=${encodeURIComponent(filePath)}`,
    title,
  };
}

function formatDisplayDate(dateStr: string): string {
  const d = new Date(dateStr + "T12:00:00");
  return d.toLocaleDateString([], { month: "short", day: "numeric" });
}

function formatDayHeader(dateStr: string): string {
  const d = new Date(dateStr + "T12:00:00");
  return d.toLocaleDateString([], { weekday: "long", month: "long", day: "numeric" });
}

function formatTime(iso: string): string {
  if (!iso) return "";
  const d = new Date(iso);
  return d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
}

// ── Obsidian folder creation helper ──────────────────────────────────────

export async function ensureObsidianFolder(folder: string, apiKey: string): Promise<void> {
  if (!folder) return;
  const url = `https://127.0.0.1:27124/vault/${encodeURIComponent(folder)}/`;
  const res = await obsidianFetch(url, {
    method: "GET",
    headers: { "Authorization": `Bearer ${apiKey}` },
  });
  if (res.status === 404) {
    // Create folder by putting a placeholder file then deleting it
    const placeholderURL = `https://127.0.0.1:27124/vault/${encodeURIComponent(folder)}/.gitkeep`;
    await obsidianFetch(placeholderURL, {
      method: "PUT",
      headers: {
        "Content-Type": "text/plain",
        "Authorization": `Bearer ${apiKey}`,
      },
      body: "",
    });
    console.log(`[obsidian] Created folder: ${folder}`);
  }
}
