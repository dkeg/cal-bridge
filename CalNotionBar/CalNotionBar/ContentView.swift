import SwiftUI
import Combine

// MARK: - ViewModel

@MainActor
class AgentViewModel: ObservableObject {
    enum Step { case idle, discovering, fetching, preview, posting, done, error }

    @Published var step: Step = .idle
    @Published var calendars: [CalendarItem] = []
    @Published var days: [DayGroup] = []
    @Published var start = ""
    @Published var end = ""
    @Published var weeksAhead = 2
    @Published var notionURL: String? = nil
    @Published var notionTitle: String? = nil
    @Published var errorMsg: String? = nil
    @Published var editingEventID: UUID? = nil
    @Published var editTitle = ""
    @Published var nextEvent: CalEvent? = nil
    @Published var notionExisted = false

    var totalEvents: Int { days.reduce(0) { $0 + $1.events.count } }

    func fetchNextEvent() {
        guard let url = URL(string: "http://localhost:8420/today") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let eventsRaw = json["events"] as? [[String: Any]] else { return }
            let now = Date()
            let fmt = ISO8601DateFormatter()
            // Find next upcoming event
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
            DispatchQueue.main.async {
                self?.nextEvent = upcoming?.1
            }
        }.resume()
    }

    func run() async {
        errorMsg = nil
        notionURL = nil

        step = .discovering
        do { calendars = try await APIClient.shared.fetchCalendars() }
        catch { errorMsg = error.localizedDescription; step = .error; return }

        step = .fetching
        do {
            let result = try await APIClient.shared.fetchEvents(calendars: calendars, weeksAhead: weeksAhead)
            days = groupByDay(result.events)
            start = result.start
            end = result.end
        } catch { errorMsg = error.localizedDescription; step = .error; return }

        step = .preview
        AppDelegate.shared?.resizePopover(width: 420, height: 580)
    }

    func post() async {
        step = .posting
        do {
            let result = try await APIClient.shared.postToNotion(days: days, start: start, end: end)
            notionURL = result.url
            notionTitle = result.title
            notionExisted = result.existed ?? false
            step = .done
        } catch { errorMsg = error.localizedDescription; step = .error }
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

    func reset() {
        step = .idle
        calendars = []
        days = []
        notionURL = nil
        errorMsg = nil
        AppDelegate.shared?.resizePopover(width: 280, height: 160)
    }
}

// MARK: - Main View

struct ContentView: View {
    @StateObject var vm = AgentViewModel()

    var body: some View {
        VStack(spacing: 0) {
            // Header always visible
            header
            Divider()

            if vm.step == .idle || vm.step == .error {
                compactBody
            } else if vm.step == .discovering || vm.step == .fetching || vm.step == .posting {
                loadingView
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        switch vm.step {
                        case .preview, .done: previewView
                        case .error: errorView
                        default: EmptyView()
                        }
                    }
                    .padding(16)
                }
                Divider()
                footer
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear { vm.fetchNextEvent() }
    }

    // MARK: Header
    var header: some View {
        HStack {
            Image(systemName: "calendar.badge.clock")
                .foregroundColor(.accentColor)
                .font(.system(size: 14))
            Text("Calendar → Notion")
                .font(.system(size: 13, weight: .medium))
            Spacer()
            if vm.step != .idle && vm.step != .error {
                StepIndicator(step: vm.step)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Compact idle body
    var compactBody: some View {
        VStack(spacing: 12) {
            // Next event
            if let next = vm.nextEvent {
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Text("Next: \(next.title)")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Text(next.timeLabel)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 14)
            } else {
                Text("No more events today")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 14)
            }

            Divider()
                .padding(.horizontal, 14)

            // Weeks + play button
            HStack(spacing: 8) {
                Text("Weeks")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                HStack(spacing: 4) {
                    ForEach([1, 2, 3, 4], id: \.self) { w in
                        Button("\(w)") { vm.weeksAhead = w }
                            .buttonStyle(PillButtonStyle(selected: vm.weeksAhead == w))
                    }
                }

                Spacer()

                // Play button
                Button {
                    Task { await vm.run() }
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                .help("Fetch and post to Notion")
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 4)
        }
        .padding(.vertical, 10)
        .frame(width: 280)
    }

    // MARK: Loading
    var loadingView: some View {
        HStack(spacing: 10) {
            ProgressView()
                .scaleEffect(0.8)
            Text(loadingMessage)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 280)
    }

    var loadingMessage: String {
        switch vm.step {
        case .discovering: return "Discovering your calendars…"
        case .fetching: return "Fetching \(vm.weeksAhead * 7) days of events…"
        case .posting: return "Creating Notion page…"
        default: return ""
        }
    }

    // MARK: Preview
    var previewView: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !vm.calendars.isEmpty && vm.step == .preview {
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

            if vm.step == .done, let title = vm.notionTitle {
                HStack {
                    Image(systemName: vm.notionExisted ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundColor(vm.notionExisted ? .orange : .green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(vm.notionExisted ? "Page already existed" : "Notion page created")
                            .font(.caption).foregroundColor(.secondary)
                        Text(title).font(.caption2).foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(10)
                .background(vm.notionExisted ? Color.orange.opacity(0.1) : Color.green.opacity(0.1))
                .cornerRadius(8)
            }

            Text("\(vm.totalEvents) events · \(vm.days.count) days · \(vm.start) → \(vm.end)")
                .font(.caption)
                .foregroundColor(.secondary)

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
    }

    // MARK: Error
    var errorView: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundColor(.red)
            Text(vm.errorMsg ?? "Something went wrong")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    // MARK: Footer
    var footer: some View {
        HStack(spacing: 8) {
            if vm.step == .error {
                Button("Try again") { Task { await vm.run() } }
                    .buttonStyle(.borderedProminent)
            }
            if vm.step == .preview {
                Button("↻ Re-fetch") { Task { await vm.run() } }
                Spacer()
                Button("Post to Notion →") { Task { await vm.post() } }
                    .buttonStyle(.borderedProminent)
            }
            if vm.step == .done {
                Button("Start over") { vm.reset() }
                if let url = vm.notionURL, let nsURL = URL(string: url) {
                    Spacer()
                    Button("Open in Notion ↗") { NSWorkspace.shared.open(nsURL) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .controlSize(.regular)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Event Row

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

// MARK: - Step Indicator

struct StepIndicator: View {
    let step: AgentViewModel.Step
    let order: [AgentViewModel.Step] = [.discovering, .fetching, .preview, .posting, .done]
    var currentIndex: Int { order.firstIndex(of: step) ?? 0 }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<order.count, id: \.self) { i in
                Circle()
                    .fill(i < currentIndex ? Color.green : i == currentIndex ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 6, height: 6)
            }
        }
    }
}

// MARK: - Button Styles

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

// MARK: - Flow Layout

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

