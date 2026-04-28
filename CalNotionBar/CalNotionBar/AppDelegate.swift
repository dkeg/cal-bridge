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

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        NSApp.setActivationPolicy(.accessory)

        if #available(macOS 13.0, *) {
            try? SMAppService.mainApp.register()
        }

        startBackend()

        // Set up status bar
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateMenuBarTitle(count: nil)

        if let button = statusItem?.button {
            button.action = #selector(togglePopover)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Set up popover
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 280, height: 160)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: ContentView())
        self.popover = popover

        // Poll mouse position to detect hover over menu bar button
        mouseTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.checkHover()
        }

        // Wait for backend then fetch
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            self.waitForBackendThenFetch()
        }
        todayTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.fetchTodayCount()
        }
    }

    // MARK: - Hover via mouse position polling

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
            // Only close if mouse isn't in the popover
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
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
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

    // MARK: - Resize popover

    func resizePopover(width: CGFloat, height: CGFloat) {
        DispatchQueue.main.async {
            self.popover?.contentSize = NSSize(width: width, height: height)
        }
    }

    // MARK: - Menu bar badge

    func updateMenuBarTitle(count: Int?) {
        DispatchQueue.main.async {
            if let button = self.statusItem?.button {
                let config = NSImage.SymbolConfiguration(pointSize: 20, weight: .medium)
                let image = NSImage(systemSymbolName: "calendar", accessibilityDescription: "Calendar")?
                    .withSymbolConfiguration(config)
                button.image = image
                button.imagePosition = .imageOnly
                button.title = ""
            }
        }
    }

    func waitForBackendThenFetch() {
        guard let url = URL(string: "http://localhost:8420/health") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let ok = json["ok"] as? Bool, ok {
                self?.fetchTodayCount()
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
                  let count = json["count"] as? Int else { return }
            self?.updateMenuBarTitle(count: count)
        }.resume()
    }

    // MARK: - Backend

    func startBackend() {
        startBackendAt(path: "/Users/drewcraig/Projects/cal-notion-v3/backend")
    }

    func startBackendAt(path: String) {
        let killer = Process()
        killer.executableURL = URL(fileURLWithPath: "/bin/sh")
        killer.arguments = ["-c", "lsof -ti:8420 | xargs kill -9 2>/dev/null || true"]
        try? killer.run()
        killer.waitUntilExit()

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
            print("[CalNotionBar] Backend started at pid \(process.processIdentifier)")
        } catch {
            print("[CalNotionBar] Failed to start backend: \(error)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        backendProcess?.terminate()
        todayTimer?.invalidate()
        hoverTimer?.invalidate()
        mouseTimer?.invalidate()
    }
}
