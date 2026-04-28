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
