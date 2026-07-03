import AppKit
import SwiftUI
import ServiceManagement

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var popover: NSPopover?
    var backendProcess: Process?
    var todayTimer: Timer?
    var hoverTimer: Timer?
    var mouseTimer: Timer?

    static var shared: AppDelegate?
    var settingsWindow: NSWindow?
    var setupWindow: NSWindow?
    var sharedVM: AgentViewModel?
    var pendingOAuthCompletion: ((String) -> Void)?
    var pollTimer: Timer?
    var cacheRefreshTimer: Timer?
    var hasUnsyncedChanges = false {
        didSet { updateMenuBarIcon() }
    }
    var nextEvent: CalEvent? = nil {
        didSet { updateMenuBarIcon() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        migrateFromCalNotionIfNeeded()
        NSApp.setActivationPolicy(.accessory)

        // Check if setup is needed
        if !UserDefaults.standard.bool(forKey: "setupComplete") || !KeychainHelper.shared.hasCredentials {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.showSetupWindow()
            }
        } else {
            // Sync existing Keychain credentials and settings to backend after it starts
            DispatchQueue.global().asyncAfter(deadline: .now() + 4) {
                self.syncKeychainToBackend()
            }
        }

        if #available(macOS 13.0, *) {
            try? SMAppService.mainApp.register()
        }

        startBackend()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateMenuBarIcon()

        if let button = statusItem?.button {
            button.action = #selector(togglePopover)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let vm = AgentViewModel()
        sharedVM = vm
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 420, height: 80)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: ContentView(vm: vm))
        self.popover = popover

        mouseTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.checkHover()
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            self.waitForBackendThenFetch()
        }
        // Sync settings after backend is ready
        DispatchQueue.global().asyncAfter(deadline: .now() + 6) {
            self.syncSettingsToBackend()
        }
        todayTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.fetchTodayCount()
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            self?.pollForChanges()
        }
    }

    var isHovering = false

    func checkHover() {
        guard let button = statusItem?.button,
              let window = button.window else { return }

        let mouseLocation = NSEvent.mouseLocation
        let buttonFrameInScreen = window.convertToScreen(button.convert(button.bounds, to: nil))
        let nowHovering = buttonFrameInScreen.contains(mouseLocation)

        if nowHovering && !isHovering {
            isHovering = true
            hoverTimer?.invalidate()
            hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
                DispatchQueue.main.async { self?.showPopover() }
            }
        } else if !nowHovering && isHovering {
            isHovering = false
            hoverTimer?.invalidate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self, let popover = self.popover, popover.isShown else { return }
                if let popoverWindow = popover.contentViewController?.view.window {
                    if !popoverWindow.frame.contains(NSEvent.mouseLocation) {
                        popover.performClose(nil)
                    }
                }
            }
        }
    }

    func showPopover() {
        guard let button = statusItem?.button, let popover = popover else { return }
        if !popover.isShown {
            popover.contentSize = NSSize(width: 420, height: 80)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            syncSettingsToBackend()
            Task { @MainActor in
                self.sharedVM?.resetForNewSession()
                await self.sharedVM?.autoLoad()
            }
        }
    }

    @objc func togglePopover() {
        guard let button = statusItem?.button, let popover = popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    func resizePopover(width: CGFloat, height: CGFloat) {
        DispatchQueue.main.async {
            self.popover?.contentSize = NSSize(width: width, height: height)
        }
    }

    func fetchNextEventForMenuBar() {
        guard SettingsStore.shared.showNextEventInMenuBar else {
            nextEvent = nil
            return
        }
        guard let url = URL(string: "http://localhost:8420/next-event") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            var event: CalEvent? = nil
            if let eventDict = json["event"] as? [String: Any],
               let eventData = try? JSONSerialization.data(withJSONObject: eventDict) {
                event = try? JSONDecoder().decode(CalEvent.self, from: eventData)
            }
            DispatchQueue.main.async { self?.nextEvent = event }
        }.resume()
    }

    static func menuBarAttributedTitle(icon: NSImage, event: CalEvent) -> NSAttributedString {
        let font = NSFont.menuBarFont(ofSize: 0)
        let iconSize: CGFloat = 15

        let attachment = NSTextAttachment()
        attachment.image = icon
        // NSTextAttachment bounds are relative to the text baseline (y = 0).
        // Keep the icon at a legible size, but center it on the text's cap
        // height so it doesn't visually sit lower than the text.
        attachment.bounds = CGRect(x: 0, y: (font.capHeight - iconSize) / 2, width: iconSize, height: iconSize)

        let result = NSMutableAttributedString(attachment: attachment)
        result.append(NSAttributedString(
            string: "  " + menuBarLabel(for: event),
            attributes: [.font: font]
        ))
        return result
    }

    static func menuBarLabel(for event: CalEvent) -> String {
        var timeStr = ""
        if let startStr = event.start {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
            fmt.locale = Locale(identifier: "en_US_POSIX")
            if let date = fmt.date(from: startStr) {
                let out = DateFormatter()
                out.dateStyle = .none
                out.timeStyle = .short
                timeStr = out.string(from: date)
            }
        }
        let title = event.title.count > 30 ? String(event.title.prefix(30)) + "…" : event.title
        return timeStr.isEmpty ? title : "\(timeStr)  \(title)"
    }

    func waitForBackendThenFetch() {
        guard let url = URL(string: "http://localhost:8420/health") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let ok = json["ok"] as? Bool, ok {
                self?.fetchTodayCount()
                self?.pollForChanges()
                self?.syncSettingsToBackend()
                // Populate the cache immediately, then keep it warm every 10 minutes
                Task { @MainActor [weak self] in
                    await self?.sharedVM?.backgroundRefresh()
                }
                DispatchQueue.main.async {
                    self?.cacheRefreshTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
                        Task { @MainActor [weak self] in
                            await self?.sharedVM?.backgroundRefresh()
                        }
                    }
                }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    self?.waitForBackendThenFetch()
                }
            }
        }.resume()
    }

    func fetchTodayCount() {
        guard let url = URL(string: "http://localhost:8420/today") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let _ = json["count"] as? Int else { return }
            self?.fetchNextEventForMenuBar()
        }.resume()
    }

    func startBackend() {
        startBackendAt(path: "/Users/drewcraig/Projects/cal-bridge/backend")
    }

    func startBackendAt(path: String) {
        // Only kill existing backend if we started it (check via lockfile)
        let lockFile = "/tmp/calbridge-backend.pid"
        if let pidStr = try? String(contentsOfFile: lockFile),
           let pid = Int(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)) {
            kill(Int32(pid), SIGTERM)
            Thread.sleep(forTimeInterval: 0.5)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path + "/node_modules/.bin/ts-node")
        process.arguments = [path + "/server.ts"]
        process.currentDirectoryURL = URL(fileURLWithPath: path)

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["PORT"] = "8420"

        if let envFile = try? String(contentsOfFile: path + "/.env", encoding: .utf8) {
            for line in envFile.split(separator: "\n") {
                let parts = line.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    env[String(parts[0]).trimmingCharacters(in: .whitespaces)] =
                        String(parts[1]).trimmingCharacters(in: .whitespaces)
                }
            }
        }

        process.environment = env

        do {
            try process.run()
            backendProcess = process
            print("[CalBridge] Backend started at pid \(process.processIdentifier)")
            try? "\(process.processIdentifier)".write(toFile: "/tmp/calbridge-backend.pid", atomically: true, encoding: .utf8)
        } catch {
            print("[CalBridge] Failed to start backend: \(error)")
        }
    }

    func pollForChanges() {
        guard SettingsStore.shared.changeDetectionEnabled else { return }
        guard let url = URL(string: "http://localhost:8420/poll") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let hasChanges = json["hasChanges"] as? Bool else { return }
            DispatchQueue.main.async {
                self?.hasUnsyncedChanges = hasChanges
            }
        }.resume()
    }

    func updateMenuBarIcon() {
        DispatchQueue.main.async {
            guard let button = self.statusItem?.button else { return }
            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
            guard let base = NSImage(systemSymbolName: "calendar", accessibilityDescription: "Calendar")?
                .withSymbolConfiguration(config) else { return }

            let icon: NSImage
            if self.hasUnsyncedChanges {
                // Draw calendar icon with blue dot overlay
                let size = NSSize(width: 22, height: 22)
                let composite = NSImage(size: size)
                composite.lockFocus()
                base.draw(in: NSRect(x: 1, y: 1, width: 18, height: 18))
                NSColor.systemBlue.setFill()
                let dot = NSBezierPath(ovalIn: NSRect(x: 14, y: 14, width: 7, height: 7))
                dot.fill()
                // White ring around dot
                NSColor.white.setStroke()
                let ring = NSBezierPath(ovalIn: NSRect(x: 13, y: 13, width: 9, height: 9))
                ring.lineWidth = 1.5
                ring.stroke()
                composite.unlockFocus()
                composite.isTemplate = false
                icon = composite
            } else {
                base.isTemplate = true
                icon = base
            }

            if SettingsStore.shared.showNextEventInMenuBar, let event = self.nextEvent {
                // Compose icon + text as one attributed string so both share a
                // baseline — separate image/title layout doesn't align reliably.
                button.image = nil
                button.imagePosition = .noImage
                button.attributedTitle = AppDelegate.menuBarAttributedTitle(icon: icon, event: event)
            } else {
                button.attributedTitle = NSAttributedString(string: "")
                button.image = icon
                button.imagePosition = .imageOnly
                button.title = ""
            }
        }
    }

    func clearUnsyncedChanges() {
        hasUnsyncedChanges = false
    }

    func openSettings() {
        if settingsWindow == nil {
            let view = NSHostingView(rootView: SettingsView())
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "CalBridge — Settings"
            window.contentView = view
            window.center()
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value else { return }
        print("[oauth] received callback with code")
        // Store code for backend polling
        guard let backendURL = URL(string: "http://localhost:8420/oauth/store-code") else { return }
        var req = URLRequest(url: backendURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["code": code])
        URLSession.shared.dataTask(with: req).resume()
    }

    func showSetupWindow() {
        if setupWindow == nil {
            let view = SetupView {
                self.setupWindow?.close()
                self.setupWindow = nil
                self.syncKeychainToBackend()
            }
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.title = "Set Up CalBridge"
            window.contentView = NSHostingView(rootView: view)
            window.center()
            window.isReleasedWhenClosed = false
            setupWindow = window
        }
        setupWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func syncSettingsToBackend() {
        // Read directly from plist — UserDefaults.standard uses wrong domain
        let plistPath = NSHomeDirectory() + "/Library/Preferences/FarmFresh.CalBridge.plist"
        guard let dict = NSDictionary(contentsOfFile: plistPath) as? [String: Any] else {
            print("[settings] plist not found at \(plistPath)")
            return
        }
        let syncTarget = dict["syncTarget"] as? String ?? "notion"
        print("[settings] syncing — syncTarget: \(syncTarget)")
        guard let url = URL(string: "http://localhost:8420/settings") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "syncTarget": syncTarget,
            "obsidianAPIKey": dict["obsidianAPIKey"] as? String ?? "",
            "obsidianVaultPath": dict["obsidianVaultPath"] as? String ?? "",
            "obsidianFolder": dict["obsidianFolder"] as? String ?? "Calendar",
            "obsidianFilename": dict["obsidianFilename"] as? String ?? "Upcoming Events.md",
            "notificationEmail": dict["notificationEmail"] as? String ?? "",
            "resendAPIKey": dict["resendAPIKey"] as? String ?? "",
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req) { _, _, err in
            if let err = err {
                print("[settings] sync error: \(err)")
            } else {
                print("[settings] sync complete — syncTarget: \(syncTarget)")
            }
        }.resume()
    }

    func syncKeychainToBackend() {
        guard let url = URL(string: "http://localhost:8420/credentials") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "googleRefreshToken": KeychainHelper.shared.load(KeychainHelper.googleRefreshToken) ?? "",
            "notionAPIKey": KeychainHelper.shared.load(KeychainHelper.notionAPIKey) ?? ""
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req).resume()
    }

    func migrateFromCalNotionIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "migratedFromCalNotion") else { return }
        let oldPlist = NSHomeDirectory() + "/Library/Preferences/FarmFresh.CalNotionBar.plist"
        if let dict = NSDictionary(contentsOfFile: oldPlist) as? [String: Any] {
            for (key, value) in dict where !key.hasPrefix("NS") {
                defaults.set(value, forKey: key)
            }
            print("[CalBridge] Migrated settings from CalNotionBar")
        }
        // Migrate Application Support files
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let oldDir = home.appendingPathComponent("Library/Application Support/CalNotionBar")
        let newDir = home.appendingPathComponent("Library/Application Support/CalBridge")
        if fm.fileExists(atPath: oldDir.path) && !fm.fileExists(atPath: newDir.path) {
            try? fm.copyItem(at: oldDir, to: newDir)
            print("[CalBridge] Migrated Application Support from CalNotionBar")
        }
        defaults.set(true, forKey: "migratedFromCalNotion")
    }

    func applicationWillTerminate(_ notification: Notification) {
        backendProcess?.terminate()
        todayTimer?.invalidate()
        hoverTimer?.invalidate()
        mouseTimer?.invalidate()
        pollTimer?.invalidate()
        cacheRefreshTimer?.invalidate()
    }
}
// test
