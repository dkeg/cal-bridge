import SwiftUI
import Combine

@MainActor
class AgentViewModel: ObservableObject {
    enum Step { case idle, fetching, preview, posting, done, error }

    @Published var step: Step = .idle
    @Published var calendars: [CalendarItem] = []
    @Published var days: [DayGroup] = []
    @Published var start = ""
    @Published var end = ""
    @Published var weeksAhead = 1
    @Published var notionURL: String? = nil
    @Published var notionTitle: String? = nil
    @Published var errorMsg: String? = nil
    @Published var editingEventID: UUID? = nil
    @Published var editTitle = ""
    @Published var nextEvent: CalEvent? = nil
    @Published var notionExisted = false
    @Published var showModify = false
    @Published var hasUnsyncedChanges = false
    let settings = SettingsStore.shared

    var syncTarget: String { settings.syncTarget }
    var isObsidian: Bool { settings.syncTarget == "obsidian" }
    var isBoth: Bool { settings.syncTarget == "both" }
    @Published var pendingWeeks = 1
    @Published var persistedNotionURL: String? = nil
    @Published var persistedNotionTitle: String? = nil
    @Published var persistedStart: String? = nil
    @Published var persistedEnd: String? = nil
    @Published var autorunFiredAt: Date? = nil
    @Published var isAutorun: Bool = false
    @Published var cacheFetchedAt: Date? = nil
    @Published var isBackgroundRefreshing: Bool = false

    private let defaults = UserDefaults.standard
    private let supportDir: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CalBridge")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    var totalEvents: Int { days.reduce(0) { $0 + $1.events.count } }

    var currentRangeIsPosted: Bool {
        guard let ps = persistedStart, let pe = persistedEnd,
              !start.isEmpty, !end.isEmpty else { return false }
        return ps == start && pe == end
    }

    var effectiveNotionURL: String? { notionURL ?? (currentRangeIsPosted ? persistedNotionURL : nil) }

    func loadPersistedState() {
        persistedNotionURL = defaults.string(forKey: "lastNotionURL")
        persistedNotionTitle = defaults.string(forKey: "lastNotionTitle")
        persistedStart = defaults.string(forKey: "lastStart")
        persistedEnd = defaults.string(forKey: "lastEnd")

        let flagURL = supportDir.appendingPathComponent("last-run.json")
        if let data = try? Data(contentsOf: flagURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let isoFormatter = ISO8601DateFormatter()
            if let firedStr = json["firedAt"] as? String,
               let firedDate = isoFormatter.date(from: firedStr) {
                let lastSeen = defaults.object(forKey: "lastSeenAutorunDate") as? Date
                if lastSeen == nil || firedDate > lastSeen! {
                    autorunFiredAt = firedDate
                    isAutorun = true
                    if let url = json["notionURL"] as? String { persistedNotionURL = url }
                    if let title = json["notionTitle"] as? String { persistedNotionTitle = title }
                    if let s = json["start"] as? String { persistedStart = s }
                    if let e = json["end"] as? String { persistedEnd = e }
                }
            }
        }
    }

    func markAutorunSeen() {
        if let date = autorunFiredAt {
            defaults.set(date, forKey: "lastSeenAutorunDate")
        }
        isAutorun = false
        autorunFiredAt = nil
    }

    var cacheAgeLabel: String? {
        guard let fetchedAt = cacheFetchedAt else { return nil }
        let seconds = Int(-fetchedAt.timeIntervalSinceNow)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        return "\(seconds / 3600)h ago"
    }

    private func saveCache(events: [CalEvent], start: String, end: String, weeks: Int) {
        guard let data = try? JSONEncoder().encode(events) else { return }
        defaults.set(data, forKey: "eventsCache")
        defaults.set(start, forKey: "eventsCacheStart")
        defaults.set(end, forKey: "eventsCacheEnd")
        defaults.set(Date().timeIntervalSince1970, forKey: "eventsCacheFetchedAt")
        defaults.set(weeks, forKey: "eventsCacheWeeks")
    }

    private func loadFromCache() -> Bool {
        guard let data = defaults.data(forKey: "eventsCache"),
              let cachedStart = defaults.string(forKey: "eventsCacheStart"),
              let cachedEnd = defaults.string(forKey: "eventsCacheEnd"),
              defaults.integer(forKey: "eventsCacheWeeks") == weeksAhead,
              let events = try? JSONDecoder().decode([CalEvent].self, from: data) else { return false }
        days = groupByDay(events)
        start = cachedStart
        end = cachedEnd
        cacheFetchedAt = Date(timeIntervalSince1970: defaults.double(forKey: "eventsCacheFetchedAt"))
        return true
    }

    func backgroundRefresh() async {
        isBackgroundRefreshing = true
        defer { isBackgroundRefreshing = false }
        do {
            if calendars.isEmpty {
                calendars = try await APIClient.shared.fetchCalendars()
            }
            let result = try await APIClient.shared.fetchEvents(calendars: calendars, weeksAhead: weeksAhead)
            // Don't stomp on in-progress edits
            if editingEventID == nil {
                days = groupByDay(result.events)
                start = result.start
                end = result.end
            }
            cacheFetchedAt = Date()
            saveCache(events: result.events, start: result.start, end: result.end, weeks: weeksAhead)
        } catch {
            print("[cache] Background refresh failed: \(error.localizedDescription)")
        }
    }

    func savePostedState() {
        defaults.set(notionURL, forKey: "lastNotionURL")
        defaults.set(notionTitle, forKey: "lastNotionTitle")
        defaults.set(start, forKey: "lastStart")
        defaults.set(end, forKey: "lastEnd")
        persistedNotionURL = notionURL
        persistedNotionTitle = notionTitle
        persistedStart = start
        persistedEnd = end
    }

    func autoLoad() async {
        guard step == .idle else { return }
        weeksAhead = settings.defaultWeeks
        loadPersistedState()

        if loadFromCache() {
            // Cache is kept warm by the background timer — just show it instantly
            step = .preview
            AppDelegate.shared?.resizePopover(width: 420, height: 580)
            if effectiveNotionURL != nil && notionURL == nil {
                step = .done
            }
        } else {
            step = .fetching
            await fetchEvents()
            if effectiveNotionURL != nil && notionURL == nil {
                step = .done
            }
        }
    }

    func fetchEvents() async {
        errorMsg = nil
        step = .fetching
        AppDelegate.shared?.resizePopover(width: 420, height: 110)
        do {
            if calendars.isEmpty {
                calendars = try await APIClient.shared.fetchCalendars()
            }
            let result = try await APIClient.shared.fetchEvents(calendars: calendars, weeksAhead: weeksAhead)
            days = groupByDay(result.events)
            start = result.start
            end = result.end
            notionURL = nil
            cacheFetchedAt = Date()
            saveCache(events: result.events, start: result.start, end: result.end, weeks: weeksAhead)
            step = .preview
            AppDelegate.shared?.resizePopover(width: 420, height: 580)
        } catch {
            errorMsg = error.localizedDescription
            step = .error
            AppDelegate.shared?.resizePopover(width: 420, height: 200)
        }
    }

    func applyModify() async {
        weeksAhead = pendingWeeks
        showModify = false
        notionURL = nil
        AppDelegate.shared?.resizePopover(width: 420, height: 80)
        await fetchEvents()
    }

    func post() async {
        step = .posting
        do {
            let result: NotionResult
            if isBoth {
                async let notionResult = APIClient.shared.postToNotion(days: days, start: start, end: end)
                async let obsidianResult = APIClient.shared.postToObsidian(days: days, start: start, end: end)
                let (notion, _) = try await (notionResult, obsidianResult)
                result = notion
            } else if isObsidian {
                result = try await APIClient.shared.postToObsidian(days: days, start: start, end: end)
            } else {
                result = try await APIClient.shared.postToNotion(days: days, start: start, end: end)
            }
            notionURL = result.url
            notionTitle = result.title
            notionExisted = result.existed ?? false
            savePostedState()
            step = .done
            AppDelegate.shared?.resizePopover(width: 420, height: 580)
        } catch {
            errorMsg = error.localizedDescription
            step = .error
            AppDelegate.shared?.resizePopover(width: 420, height: 200)
        }
    }

    func fetchNextEvent() {
        guard let url = URL(string: "http://localhost:8420/today") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let eventsRaw = json["events"] as? [[String: Any]] else { return }
            let now = Date()
            let fmt = ISO8601DateFormatter()
            let upcoming = eventsRaw.compactMap { dict -> (Date, CalEvent)? in
                guard let startStr = dict["start"] as? String,
                      let startDate = fmt.date(from: startStr),
                      startDate > now else { return nil }
                let e = CalEvent(
                    date: dict["date"] as? String ?? "",
                    start: startStr,
                    end: dict["end"] as? String,
                    title: dict["title"] as? String ?? "",
                    calendar: dict["calendar"] as? String ?? "",
                    allDay: dict["allDay"] as? Bool ?? false
                )
                return (startDate, e)
            }.sorted { $0.0 < $1.0 }.first
            DispatchQueue.main.async { self?.nextEvent = upcoming?.1 }
        }.resume()
    }

    func removeEvent(dayIdx: Int, eventID: UUID) {
        days[dayIdx].events.removeAll { $0.id == eventID }
        if days[dayIdx].events.isEmpty { days.remove(at: dayIdx) }
    }

    func saveEdit(dayIdx: Int, eventID: UUID) {
        if let ei = days[dayIdx].events.firstIndex(where: { $0.id == eventID }) {
            days[dayIdx].events[ei].title = editTitle
        }
        editingEventID = nil
    }

    func toggleCalendar(_ id: String) {
        if let i = calendars.firstIndex(where: { $0.id == id }) {
            calendars[i].enabled.toggle()
        }
    }

    func checkForUnsyncedChanges() {
        guard settings.changeDetectionEnabled else { return }
        guard let url = URL(string: "http://localhost:8420/poll") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let hasChanges = json["hasChanges"] as? Bool else { return }
            DispatchQueue.main.async { self?.hasUnsyncedChanges = hasChanges }
        }.resume()
    }

    func resync() async {
        step = .fetching
        do {
            guard let url = URL(string: "http://localhost:8420/resync") else { return }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: ["weeksAhead": weeksAhead])
            let (data, _) = try await URLSession.shared.data(for: req)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let eventsRaw = json?["events"],
               let eventsData = try? JSONSerialization.data(withJSONObject: eventsRaw) {
                let events = try JSONDecoder().decode([CalEvent].self, from: eventsData)
                days = groupByDay(events)
            }
            start = json?["start"] as? String ?? start
            end = json?["end"] as? String ?? end
            notionURL = json?["url"] as? String
            notionTitle = json?["title"] as? String
            hasUnsyncedChanges = false
            AppDelegate.shared?.clearUnsyncedChanges()
            savePostedState()
            step = .done
        } catch {
            errorMsg = error.localizedDescription
            step = .error
        }
    }

    func resetForNewSession() {
        guard step != .fetching && step != .posting else { return }
        settings.reload()
        step = .idle
        days = []
        notionURL = nil
        errorMsg = nil
        showModify = false
        weeksAhead = settings.defaultWeeks
        pendingWeeks = settings.defaultWeeks
        // Reload persisted state after settings reload
        loadPersistedState()
    }

    func reset() {
        step = .idle
        calendars = []
        days = []
        notionURL = nil
        errorMsg = nil
        showModify = false
    }

    var autorunLabel: String {
        guard let date = autorunFiredAt else { return "" }
        let fmt = DateFormatter()
        fmt.dateFormat = "EEEE, MMM d 'at' h:mm a"
        return "Auto-synced \(fmt.string(from: date))"
    }
}

struct ContentView: View {
    @ObservedObject var vm: AgentViewModel

    init(vm: AgentViewModel) {
        self.vm = vm
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if vm.step == .fetching || vm.step == .posting {
                loadingView
            } else if vm.step == .error {
                errorView
                Divider()
                errorFooter
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        calendarChips
                        if vm.showModify { modifyPanel }
                        metaLine
                        eventList
                    }
                    .padding(14)
                }
                Divider()
                footer
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .frame(width: 420)
        .onAppear {
            vm.fetchNextEvent()
            vm.checkForUnsyncedChanges()
        }
    }

    var header: some View {
        HStack(alignment: .center) {
            Image(systemName: "calendar.badge.clock")
                .foregroundColor(.accentColor)
                .font(.system(size: 14))
            Text("CalBridge")
                .font(.system(size: 13, weight: .medium))
            Spacer()
            if vm.step == .fetching || vm.step == .posting {
                ProgressView().scaleEffect(0.6)
                    .frame(width: 16, height: 16)
            }
            Button {
                AppDelegate.shared?.openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .frame(height: 40)
        .padding(.horizontal, 14)
    }

    var calendarChips: some View {
        Group {
            if !vm.calendars.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Calendars — tap to toggle")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    FlowLayout(spacing: 6) {
                        ForEach(vm.calendars) { cal in
                            Button(cal.label) { vm.toggleCalendar(cal.id) }
                                .buttonStyle(ChipButtonStyle(enabled: cal.enabled))
                        }
                    }
                }
            }
        }
    }

    var modifyPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Weeks to sync")
                .font(.caption)
                .foregroundColor(.secondary)
            HStack(spacing: 4) {
                ForEach([1, 2, 3, 4], id: \.self) { w in
                    Button(action: { vm.pendingWeeks = w }) {
                        Text("\(w)w")
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(vm.pendingWeeks == w ? Color.accentColor : Color.secondary.opacity(0.15))
                            .foregroundColor(vm.pendingWeeks == w ? .white : .primary)
                            .cornerRadius(99)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Button("Cancel") {
                    vm.showModify = false
                    vm.pendingWeeks = vm.weeksAhead
                }
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .buttonStyle(.plain)
                Button("Apply") { Task { await vm.applyModify() } }
                    .font(.system(size: 12, weight: .medium))
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
            }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }

    var metaLine: some View {
        VStack(alignment: .leading, spacing: 4) {
            if vm.hasUnsyncedChanges {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 10))
                        .foregroundColor(.blue)
                    Text("Calendar changes detected")
                        .font(.caption2)
                        .foregroundColor(.blue)
                    Spacer()
                    Button("Re-sync") { Task { await vm.resync() } }
                        .font(.caption2)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.blue.opacity(0.08))
                .cornerRadius(6)
            }
            if vm.isAutorun {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10))
                        .foregroundColor(.accentColor)
                    Text(vm.autorunLabel)
                        .font(.caption2)
                        .foregroundColor(.accentColor)
                    Spacer()
                    Button("Dismiss") { vm.markAutorunSeen() }
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.accentColor.opacity(0.08))
                .cornerRadius(6)
            }
            HStack(spacing: 4) {
                Text("\(vm.totalEvents) events · \(vm.days.count) days · \(vm.start) → \(vm.end)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if vm.currentRangeIsPosted && vm.notionURL == nil {
                    Text("· ✓ posted")
                        .font(.caption)
                        .foregroundColor(.green.opacity(0.8))
                }
            }
            if let label = vm.cacheAgeLabel {
                HStack(spacing: 4) {
                    if vm.isBackgroundRefreshing {
                        ProgressView().scaleEffect(0.4).frame(width: 10, height: 10)
                    }
                    Text(vm.isBackgroundRefreshing ? "Refreshing…" : "Updated \(label)")
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.6))
                }
            }
            if vm.step == .done, let title = vm.notionTitle {
                HStack(spacing: 6) {
                    Image(systemName: vm.notionExisted ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundColor(vm.notionExisted ? .orange : .green)
                        .font(.caption)
                    Text(vm.notionExisted ? "Already existed — \(title)" : (vm.isObsidian ? "Written to Obsidian — \(title)" : vm.isBoth ? "Posted to Notion & Obsidian — \(title)" : "Posted to Notion — \(title)"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    var eventList: some View {
        ForEach(Array(vm.days.enumerated()), id: \.element.id) { di, day in
            VStack(alignment: .leading, spacing: 4) {
                Text(day.displayDate)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .padding(.bottom, 2)
                ForEach(Array(day.events.enumerated()), id: \.element.id) { _, event in
                    EventRow(
                        event: event,
                        isEditing: vm.editingEventID == event.id,
                        editTitle: $vm.editTitle,
                        onEdit: { vm.editingEventID = event.id; vm.editTitle = event.title },
                        onSave: { vm.saveEdit(dayIdx: di, eventID: event.id) },
                        onCancel: { vm.editingEventID = nil },
                        onRemove: { vm.removeEvent(dayIdx: di, eventID: event.id) }
                    )
                }
            }
        }
    }

    var loadingView: some View {
        HStack(spacing: 10) {
            ProgressView().scaleEffect(0.8)
            Text(vm.step == .posting ? (vm.isBoth ? "Posting to Notion & Obsidian…" : vm.isObsidian ? "Writing to Obsidian…" : "Creating Notion page…") : "Fetching \(vm.weeksAhead * 7) days of events…")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: 60)
    }

    var errorView: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundColor(.red)
            Text(vm.errorMsg ?? "Something went wrong")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    var errorFooter: some View {
        HStack {
            Spacer()
            Button("Try again") { Task { await vm.fetchEvents() } }
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    var footer: some View {
        HStack(spacing: 8) {
            Button {
                vm.pendingWeeks = vm.weeksAhead
                vm.showModify.toggle()
            } label: {
                Label("Modify", systemImage: "slider.horizontal.3")
                    .font(.system(size: 12))
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)

            Spacer()

            if let url = vm.effectiveNotionURL, let nsURL = URL(string: url) {
                Button {
                    NSWorkspace.shared.open(nsURL)
                } label: {
                    Label(vm.isObsidian ? "Open in Obsidian" : "Open in Notion →", systemImage: "arrow.up.right.square")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            } else {
                Button(vm.isBoth ? "Post to Both →" : vm.isObsidian ? "Post to Obsidian →" : "Post to Notion →") { Task { await vm.post() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(vm.step == .fetching || vm.step == .posting)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

struct EventRow: View {
    let event: CalEvent
    let isEditing: Bool
    @Binding var editTitle: String
    var onEdit: () -> Void
    var onSave: () -> Void
    var onCancel: () -> Void
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(event.timeLabel)
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(width: 90, alignment: .leading)
            if isEditing {
                TextField("Title", text: $editTitle)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                Button("Save", action: onSave).font(.caption)
                Button("✕", action: onCancel).font(.caption).foregroundColor(.secondary)
            } else {
                Text(event.title).font(.caption).lineLimit(1)
                Spacer()
                Text(event.calendar)
                    .font(.caption2).foregroundColor(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.1)).cornerRadius(4)
                Button(action: onEdit) { Image(systemName: "pencil").font(.caption2) }
                    .buttonStyle(.plain).foregroundColor(.secondary)
                Button(action: onRemove) { Image(systemName: "xmark").font(.caption2) }
                    .buttonStyle(.plain).foregroundColor(.red.opacity(0.7))
            }
        }
        .padding(.vertical, 4).padding(.horizontal, 8)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(6)
    }
}

struct PillButtonStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(selected ? Color.accentColor : Color.secondary.opacity(0.1))
            .foregroundColor(selected ? .white : .primary)
            .cornerRadius(99)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}

struct ChipButtonStyle: ButtonStyle {
    let enabled: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption2)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(enabled ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08))
            .foregroundColor(enabled ? .accentColor : .secondary)
            .cornerRadius(99)
            .overlay(RoundedRectangle(cornerRadius: 99).stroke(enabled ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 0.5))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for sv in subviews {
            let s = sv.sizeThatFits(.unspecified)
            if x + s.width > width && x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
        return CGSize(width: width, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for sv in subviews {
            let s = sv.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX && x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            sv.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
    }
}
