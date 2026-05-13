import SwiftUI

struct SettingsView: View {
    @ObservedObject var store = SettingsStore.shared
    @State private var selectedTab = 0
    @State private var availableCalendars: [CalendarItem] = []
    @State private var savedIndicator = false

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            HStack(spacing: 0) {
                ForEach(["General", "Configuration", "About"].indices, id: \.self) { i in
                    Button(["General", "Configuration", "About"][i]) {
                        selectedTab = i
                    }
                    .buttonStyle(TabButtonStyle(selected: selectedTab == i))
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            // Tab content
            ScrollView {
                Group {
                    if selectedTab == 0 { generalTab }
                    else if selectedTab == 1 { configurationTab }
                    else { aboutTab }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(24)
            }

            Divider()

            // Footer
            HStack {
                if savedIndicator {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.caption)
                        Text("Saved")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 440, height: 400)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear { loadCalendars() }
    }

    // MARK: - General Tab

    var generalTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Change detection
            HStack {
                Text("Change detection")
                    .frame(width: 130, alignment: .leading)
                Toggle("", isOn: $store.changeDetectionEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                Text("Check every 30 min")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            // Default weeks
            HStack {
                Text("Default weeks")
                    .frame(width: 130, alignment: .leading)
                HStack(spacing: 6) {
                    ForEach([1, 2, 3, 4], id: \.self) { w in
                        Button("\(w) wk") { store.defaultWeeks = w }
                            .buttonStyle(PillButtonStyle(selected: store.defaultWeeks == w))
                    }
                }
            }

            // Calendar defaults
            VStack(alignment: .leading, spacing: 8) {
                Text("Default calendars")
                    .frame(width: 130, alignment: .leading)
                if availableCalendars.isEmpty {
                    Text("Loading calendars…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    FlowLayout(spacing: 6) {
                        ForEach(availableCalendars) { cal in
                            Button(cal.label) {
                                if store.disabledCalendarIDs.contains(cal.id) {
                                    store.disabledCalendarIDs.remove(cal.id)
                                } else {
                                    store.disabledCalendarIDs.insert(cal.id)
                                }
                            }
                            .buttonStyle(ChipButtonStyle(enabled: !store.disabledCalendarIDs.contains(cal.id)))
                        }
                    }
                }
            }
        }
    }

    // MARK: - Configuration Tab

    var configurationTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsRow(label: "Notification email") {
                TextField("your@email.com", text: $store.notificationEmail)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
            }

            settingsRow(label: "Resend API key") {
                SecureField("re_xxxxxxxxxxxx", text: $store.resendAPIKey)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
            }
        }
    }

    // MARK: - About Tab

    var aboutTab: some View {
        VStack(alignment: .center, spacing: 12) {
            Spacer()
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 36))
                .foregroundColor(.accentColor)
            Text("Cal Notion Bar")
                .font(.headline)
            Text("v1.1.0 · 2026")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Button("Check for updates") { checkForUpdates() }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Helpers

    func settingsRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center) {
            Text(label)
                .frame(width: 130, alignment: .leading)
            content()
        }
    }

    func save() {
        store.syncToBackend()
        withAnimation {
            savedIndicator = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { savedIndicator = false }
        }
    }

    func loadCalendars() {
        guard let url = URL(string: "http://localhost:8420/calendars") else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let calsArray = json["calendars"] as? [[String: Any]] else { return }
            let cals = calsArray.compactMap { dict -> CalendarItem? in
                guard let id = dict["id"] as? String,
                      let label = dict["label"] as? String else { return nil }
                return CalendarItem(id: id, label: label)
            }
            DispatchQueue.main.async { availableCalendars = cals }
        }.resume()
    }

    func checkForUpdates() {
        guard let url = URL(string: "https://api.github.com/repos/dkeg/cal-notion/releases/latest") else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else { return }
            DispatchQueue.main.async {
                let current = "v1.1.0"
                let isNewer = tag.compare(current, options: .numeric) == .orderedDescending
                if isNewer {
                    let alert = NSAlert()
                    alert.messageText = "Update available: \(tag)"
                    alert.informativeText = "You are on \(current). Visit GitHub to download the latest version."
                    alert.addButton(withTitle: "Open GitHub")
                    alert.addButton(withTitle: "Dismiss")
                    if alert.runModal() == .alertFirstButtonReturn {
                        NSWorkspace.shared.open(URL(string: "https://github.com/dkeg/cal-notion/releases")!)
                    }
                } else {
                    let alert = NSAlert()
                    alert.messageText = "You're up to date"
                    alert.informativeText = "\(current) is the latest version."
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }.resume()
    }
}

// MARK: - Tab Button Style

struct TabButtonStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: selected ? .medium : .regular))
            .foregroundColor(selected ? .accentColor : .secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(selected ? Color.accentColor.opacity(0.1) : Color.clear)
            .cornerRadius(6)
    }
}
