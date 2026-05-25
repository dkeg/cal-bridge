import "dotenv/config";
import * as fs from "fs";
import * as path from "path";
import * as os from "os";
import * as child_process from "child_process";
import {
  listCalendars,
  fetchEvents,
  createNotionPage,
  createObsidianPage,
  checkExistingPage,
  groupByDay,
  dateRange,
  sendNotification,
} from "./agent";

interface AppSettings {
  syncTarget: "notion" | "obsidian" | "both";
  obsidianAPIKey: string;
  obsidianVaultPath: string;
  obsidianFolder: string;
  obsidianFilename: string;
  notificationEmail: string;
}

function readAppSettings(): AppSettings {
  try {
    const plistPath = path.join(os.homedir(), "Library/Preferences/FarmFresh.CalBridge.plist");
    const json = child_process.execSync(`plutil -convert json -o - "${plistPath}"`).toString();
    const data = JSON.parse(json);
    return {
      syncTarget: data.syncTarget ?? "notion",
      obsidianAPIKey: data.obsidianAPIKey ?? "",
      obsidianVaultPath: data.obsidianVaultPath ?? "",
      obsidianFolder: data.obsidianFolder ?? "Calendar",
      obsidianFilename: data.obsidianFilename ?? "Upcoming Events.md",
      notificationEmail: data.notificationEmail ?? "",
    };
  } catch {
    console.warn("[autorun] Could not read app plist — using notion-only defaults");
    return {
      syncTarget: "notion",
      obsidianAPIKey: "",
      obsidianVaultPath: "",
      obsidianFolder: "Calendar",
      obsidianFilename: "Upcoming Events.md",
      notificationEmail: "",
    };
  }
}

async function main() {
  console.log(`[autorun] Starting — ${new Date().toISOString()}`);

  const settings = readAppSettings();
  console.log(`[autorun] Sync target: ${settings.syncTarget}`);

  const { start, end } = dateRange(1);

  const calendars = await listCalendars();
  console.log(`[autorun] Found ${calendars.length} calendars`);

  const events = await fetchEvents(calendars, start, end);
  console.log(`[autorun] Fetched ${events.length} events`);

  const days = groupByDay(events);

  let notionURL: string | null = null;
  let notionTitle = "";
  let obsidianURL: string | null = null;

  // ── Notion ────────────────────────────────────────────────────────────────
  if (settings.syncTarget === "notion" || settings.syncTarget === "both") {
    const existing = await checkExistingPage(start, end);
    if (existing) {
      console.log(`[autorun] Notion page already exists: ${existing.title}`);
      notionURL = existing.url;
      notionTitle = existing.title ?? "";
    } else {
      const result = await createNotionPage(days, start, end);
      console.log(`[autorun] Created Notion page: ${result.title}`);
      console.log(`[autorun] Notion URL: ${result.url}`);
      notionURL = result.url;
      notionTitle = result.title;
    }
  }

  // ── Obsidian ──────────────────────────────────────────────────────────────
  if (settings.syncTarget === "obsidian" || settings.syncTarget === "both") {
    if (!settings.obsidianAPIKey) {
      console.warn("[autorun] Obsidian API key not configured — skipping Obsidian sync");
    } else {
      const result = await createObsidianPage(days, start, end, {
        apiKey: settings.obsidianAPIKey,
        vaultPath: settings.obsidianVaultPath,
        folder: settings.obsidianFolder,
        filename: settings.obsidianFilename,
      });
      console.log(`[autorun] Written to Obsidian: ${result.title}`);
      console.log(`[autorun] Obsidian URL: ${result.url}`);
      obsidianURL = result.url;
      if (!notionTitle) notionTitle = result.title;
    }
  }

  const primaryURL = notionURL ?? obsidianURL;
  const primaryTitle = notionTitle || `Upcoming Events — ${start} to ${end}`;

  await sendNotification({
    title: primaryTitle,
    url: primaryURL,
    start,
    end,
    eventCount: events.length,
    source: "autorun",
    email: settings.notificationEmail || undefined,
  });

  writeFlagFile(notionURL, obsidianURL, primaryTitle, start, end);
  console.log(`[autorun] Done — ${new Date().toISOString()}`);
}

function writeFlagFile(
  notionURL: string | null,
  obsidianURL: string | null,
  title: string,
  start: string,
  end: string,
) {
  const supportDir = path.join(os.homedir(), "Library", "Application Support", "CalBridge");
  if (!fs.existsSync(supportDir)) fs.mkdirSync(supportDir, { recursive: true });
  const flag = {
    notionURL,
    obsidianURL,
    notionTitle: title,
    start,
    end,
    firedAt: new Date().toISOString(),
    source: "autorun",
  };
  fs.writeFileSync(path.join(supportDir, "last-run.json"), JSON.stringify(flag, null, 2));
  console.log(`[autorun] Flag written`);
}

main().catch((err) => {
  console.error(`[autorun] Error: ${err.message}`);
  process.exit(1);
});
