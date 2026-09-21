cask "cal-bridge" do
  version "1.15.0"
  sha256 :no_check

  url "https://github.com/dkeg/cal-bridge/releases/download/v#{version}/CalBridge-v#{version}.dmg"
  name "CalBridge"
  desc "macOS menu bar app that syncs Google Calendar events to Notion, Obsidian, or Bear"
  homepage "https://github.com/dkeg/cal-bridge"

  app "CalBridge.app"

  postflight do
    system_command "#{staged_path}/CalBridge.app/Contents/Resources/scripts/install.sh",
                   args: ["--silent"],
                   sudo: false
  end

  zap trash: [
    "~/Library/LaunchAgents/com.drewcraig.cal-bridge-autorun.plist",
    "~/Library/Logs/cal-bridge-autorun.log",
    "~/Library/Logs/cal-bridge-autorun-error.log",
    "~/Library/Application Support/CalBridge",
    "~/Library/Preferences/FarmFresh.CalBridge.plist",
  ]
end
