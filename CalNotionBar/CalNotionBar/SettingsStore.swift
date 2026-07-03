import Foundation
import Combine

class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private let defaults = UserDefaults.standard

    // MARK: - General
    @Published var defaultWeeks: Int {
        didSet { defaults.set(defaultWeeks, forKey: "defaultWeeks") }
    }

    @Published var disabledCalendarIDs: Set<String> {
        didSet { defaults.set(Array(disabledCalendarIDs), forKey: "disabledCalendarIDs") }
    }

    // MARK: - Sync Target
    @Published var syncTarget: String {
        didSet { defaults.set(syncTarget, forKey: "syncTarget") }
    }

    // MARK: - Obsidian
    @Published var obsidianAPIKey: String {
        didSet { defaults.set(obsidianAPIKey, forKey: "obsidianAPIKey") }
    }
    @Published var obsidianVaultPath: String {
        didSet { defaults.set(obsidianVaultPath, forKey: "obsidianVaultPath") }
    }
    @Published var obsidianFolder: String {
        didSet { defaults.set(obsidianFolder, forKey: "obsidianFolder") }
    }
    @Published var obsidianFilename: String {
        didSet { defaults.set(obsidianFilename, forKey: "obsidianFilename") }
    }

    // MARK: - Configuration
    @Published var notificationEmail: String {
        didSet { defaults.set(notificationEmail, forKey: "notificationEmail") }
    }

    @Published var resendAPIKey: String {
        didSet { defaults.set(resendAPIKey, forKey: "resendAPIKey") }
    }

    // MARK: - Change Detection
    @Published var changeDetectionEnabled: Bool {
        didSet { defaults.set(changeDetectionEnabled, forKey: "changeDetectionEnabled") }
    }

    // MARK: - Menu Bar
    @Published var showNextEventInMenuBar: Bool {
        didSet {
            defaults.set(showNextEventInMenuBar, forKey: "showNextEventInMenuBar")
            AppDelegate.shared?.fetchNextEventForMenuBar()
        }
    }

    // MARK: - Init
    private init() {
        defaultWeeks = defaults.integer(forKey: "defaultWeeks").nonZero ?? 1
        disabledCalendarIDs = Set(defaults.stringArray(forKey: "disabledCalendarIDs") ?? [])
        syncTarget = defaults.string(forKey: "syncTarget") ?? "notion"
        obsidianAPIKey = defaults.string(forKey: "obsidianAPIKey") ?? ""
        obsidianVaultPath = defaults.string(forKey: "obsidianVaultPath") ?? ""
        obsidianFolder = defaults.string(forKey: "obsidianFolder") ?? "Calendar"
        obsidianFilename = defaults.string(forKey: "obsidianFilename") ?? "Upcoming Events.md"
        notificationEmail = defaults.string(forKey: "notificationEmail") ?? ""
        changeDetectionEnabled = defaults.bool(forKey: "changeDetectionEnabled") == false ? true : defaults.bool(forKey: "changeDetectionEnabled")
        resendAPIKey = defaults.string(forKey: "resendAPIKey") ?? ""
        showNextEventInMenuBar = defaults.bool(forKey: "showNextEventInMenuBar")
    }

    // MARK: - Sync to backend
    func syncToBackend() {
        guard let url = URL(string: "http://localhost:8420/settings") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "notificationEmail": notificationEmail,
            "resendAPIKey": resendAPIKey,
            "syncTarget": syncTarget,
            "obsidianAPIKey": obsidianAPIKey,
            "obsidianVaultPath": obsidianVaultPath,
            "obsidianFolder": obsidianFolder,
            "obsidianFilename": obsidianFilename,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req) { _, _, err in
            if let err = err { print("[settings] sync error: \(err)") }
            else { print("[settings] synced to backend") }
        }.resume()
    }
}

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}

extension SettingsStore {
    func reload() {
        let newTarget = defaults.string(forKey: "syncTarget") ?? "notion"
        if newTarget != syncTarget {
            // Target changed — clear persisted URL so button resets
            defaults.removeObject(forKey: "lastNotionURL")
            defaults.removeObject(forKey: "lastNotionTitle")
            defaults.removeObject(forKey: "lastStart")
            defaults.removeObject(forKey: "lastEnd")
        }
        syncTarget = newTarget
        obsidianAPIKey = defaults.string(forKey: "obsidianAPIKey") ?? ""
        obsidianVaultPath = defaults.string(forKey: "obsidianVaultPath") ?? ""
        obsidianFolder = defaults.string(forKey: "obsidianFolder") ?? "Calendar"
        obsidianFilename = defaults.string(forKey: "obsidianFilename") ?? "Upcoming Events.md"
        notificationEmail = defaults.string(forKey: "notificationEmail") ?? ""
        resendAPIKey = defaults.string(forKey: "resendAPIKey") ?? ""
        changeDetectionEnabled = defaults.bool(forKey: "changeDetectionEnabled")
        defaultWeeks = defaults.integer(forKey: "defaultWeeks").nonZero ?? 1
        showNextEventInMenuBar = defaults.bool(forKey: "showNextEventInMenuBar")
    }
}
