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

    // MARK: - Configuration
    @Published var notificationEmail: String {
        didSet { defaults.set(notificationEmail, forKey: "notificationEmail") }
    }

    @Published var resendAPIKey: String {
        didSet { defaults.set(resendAPIKey, forKey: "resendAPIKey") }
    }

    // MARK: - Init
    private init() {
        defaultWeeks = defaults.integer(forKey: "defaultWeeks").nonZero ?? 1
        disabledCalendarIDs = Set(defaults.stringArray(forKey: "disabledCalendarIDs") ?? [])
        notificationEmail = defaults.string(forKey: "notificationEmail") ?? ""
        resendAPIKey = defaults.string(forKey: "resendAPIKey") ?? ""
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
