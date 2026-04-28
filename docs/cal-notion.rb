cask "cal-notion" do
  version "1.0.0"
  sha256 :no_check

  url "https://github.com/dkeg/cal-notion/releases/download/v#{version}/CalNotion-v#{version}.dmg"
  name "Cal → Notion"
  desc "macOS menu bar app that syncs Google Calendar events to Notion"
  homepage "https://github.com/dkeg/cal-notion"

  app "CalNotionBar.app"

  postflight do
    system_command "#{staged_path}/CalNotionBar.app/Contents/Resources/scripts/install.sh",
                   args: ["--silent"],
                   sudo: false
  end

  zap trash: [
    "~/Library/LaunchAgents/com.cal-notion.autorun.plist",
    "~/Library/Logs/cal-notion-autorun.log",
    "~/Library/Logs/cal-notion-autorun-error.log",
  ]
end
