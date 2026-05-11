import "dotenv/config";
import * as fs from "fs";
import * as path from "path";
import * as os from "os";
import { listCalendars, fetchEvents, createNotionPage, checkExistingPage, groupByDay, dateRange, sendNotification } from "./agent";

async function main() {
  console.log(`[autorun] Starting — ${new Date().toISOString()}`);

  const { start, end } = dateRange(1);

  const calendars = await listCalendars();
  console.log(`[autorun] Found ${calendars.length} calendars`);

  const events = await fetchEvents(calendars, start, end);
  console.log(`[autorun] Fetched ${events.length} events`);

  const days = groupByDay(events);

  // Check for existing page first — avoid duplicates
  const existing = await checkExistingPage(start, end);
  if (existing) {
    console.log(`[autorun] Page already exists: ${existing.title}`);
    console.log(`[autorun] URL: ${existing.url}`);
    await sendNotification({
      title: existing.title ?? "",
      url: existing.url,
      start,
      end,
      eventCount: events.length,
      source: "autorun",
    });
    writeFlagFile(existing.url, existing.title ?? "", start, end);
    console.log(`[autorun] Done — ${new Date().toISOString()}`);
    return;
  }

  const result = await createNotionPage(days, start, end);
  console.log(`[autorun] Created Notion page: ${result.title}`);
  console.log(`[autorun] URL: ${result.url}`);

  await sendNotification({
    title: result.title,
    url: result.url,
    start,
    end,
    eventCount: events.length,
    source: "autorun",
  });

  writeFlagFile(result.url, result.title, start, end);
  console.log(`[autorun] Done — ${new Date().toISOString()}`);
}

function writeFlagFile(url: string | null, title: string, start: string, end: string) {
  const supportDir = path.join(os.homedir(), "Library", "Application Support", "CalNotionBar");
  if (!fs.existsSync(supportDir)) fs.mkdirSync(supportDir, { recursive: true });
  const flag = { notionURL: url, notionTitle: title, start, end, firedAt: new Date().toISOString(), source: "autorun" };
  fs.writeFileSync(path.join(supportDir, "last-run.json"), JSON.stringify(flag, null, 2));
  console.log(`[autorun] Flag written`);
}

main().catch(err => {
  console.error(`[autorun] Error: ${err.message}`);
  process.exit(1);
});
