/**
 * Run this once to get your Google OAuth refresh token.
 * Usage: ts-node auth.ts
 * It will open a browser, you log in, and it prints the refresh token to paste in .env
 */
import "dotenv/config";
import { google } from "googleapis";
import * as http from "http";
import * as url from "url";

const CLIENT_ID = process.env.GOOGLE_CLIENT_ID!;
const CLIENT_SECRET = process.env.GOOGLE_CLIENT_SECRET!;
const REDIRECT_URI = "http://localhost:8421/callback";

const oauth2Client = new google.auth.OAuth2(CLIENT_ID, CLIENT_SECRET, REDIRECT_URI);

const authUrl = oauth2Client.generateAuthUrl({
  access_type: "offline",
  scope: ["https://www.googleapis.com/auth/calendar.readonly"],
  prompt: "consent",
});

console.log("\n🔑 Opening browser for Google OAuth...");
console.log("If it doesn't open, visit:\n", authUrl, "\n");

// Try to open browser
const { exec } = require("child_process");
exec(`open "${authUrl}"`);

// Local server to catch callback
const server = http.createServer(async (req, res) => {
  const parsed = url.parse(req.url!, true);
  if (parsed.pathname !== "/callback") return;

  const code = parsed.query.code as string;
  if (!code) {
    res.end("No code received.");
    return;
  }

  try {
    const { tokens } = await oauth2Client.getToken(code);
    res.end("<h2>✅ Auth complete! Check your terminal.</h2><p>You can close this tab.</p>");
    server.close();

    console.log("\n✅ Success! Add these to your .env:\n");
    console.log(`GOOGLE_REFRESH_TOKEN=${tokens.refresh_token}`);
    console.log("\nKeep this token secret — it grants read access to your calendars.\n");
  } catch (e: any) {
    res.end("Error: " + e.message);
    server.close();
  }
});

server.listen(8421, () => {
  console.log("Waiting for OAuth callback on http://localhost:8421/callback...");
});
