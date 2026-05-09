import "dotenv/config";
import * as fs from "fs";
import * as path from "path";
import * as os from "os";
import { listCalendars, fetchEvents, createNotionPage, groupByDay, dateRange } from "./agent";

async function main() {
  console.log(`[autorun] Starting — ${new Date().toISOString()}`);

  const { start, end } = dateRange(1);

  const calendars = await listCalendars();
  console.log(`[autorun] Found ${calendars.length} calendars`);

  const events = await fetchEvents(calendars, start, end);
  console.log(`[autorun] Fetched ${events.length} events`);

  const days = groupByDay(events);
  const result = await createNotionPage(days, start, end);

  console.log(`[autorun] Created Notion page: ${result.title}`);
  console.log(`[autorun] URL: ${result.url}`);

  const supportDir = path.join(os.homedir(), "Library", "Application Support", "CalNotionBar");
  if (!fs.existsSync(supportDir)) fs.mkdirSync(supportDir, { recursive: true });

  const flag = {
    notionURL: result.url,
    notionTitle: result.title,
    start,
    end,
    firedAt: new Date().toISOString(),
    source: "autorun",
  };

  fs.writeFileSync(path.join(supportDir, "last-run.json"), JSON.stringify(flag, null, 2));
  console.log(`[autorun] Flag written to ${supportDir}/last-run.json`);
  console.log(`[autorun] Done — ${new Date().toISOString()}`);
}

main().catch(err => {
  console.error(`[autorun] Error: ${err.message}`);
  process.exit(1);
});
