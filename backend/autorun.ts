import "dotenv/config";
import { listCalendars, fetchEvents, createNotionPage, groupByDay, dateRange } from "./agent";

async function main() {
    console.log(`[autorun] Starting — ${new Date().toISOString()}`);

    const { start, end } = dateRange(2);

    const calendars = await listCalendars();
    console.log(`[autorun] Found ${calendars.length} calendars`);

    const events = await fetchEvents(calendars, start, end);
    console.log(`[autorun] Fetched ${events.length} events`);

    const days = groupByDay(events);
    const result = await createNotionPage(days, start, end);

    console.log(`[autorun] Created Notion page: ${result.title}`);
    console.log(`[autorun] URL: ${result.url}`);
    console.log(`[autorun] Done — ${new Date().toISOString()}`);
}

main().catch(err => {
    console.error(`[autorun] Error: ${err.message}`);
    process.exit(1);
});
