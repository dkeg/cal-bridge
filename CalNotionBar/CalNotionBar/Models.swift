import Foundation

// MARK: - Models

struct CalendarItem: Codable, Identifiable {
    var id: String
    var label: String
    var enabled: Bool = true
}

struct CalEvent: Codable, Identifiable {
    var id = UUID()
    var date: String
    var start: String?
    var end: String?
    var title: String
    var calendar: String
    var allDay: Bool

    enum CodingKeys: String, CodingKey {
        case date, start, end, title, calendar, allDay
    }

    var timeLabel: String {
        if allDay || start == nil { return "All day" }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        let f2 = DateFormatter()
        f2.dateStyle = .none
        f2.timeStyle = .short
        let s = start.flatMap { fmt.date(from: $0) }.map { f2.string(from: $0) } ?? start ?? ""
        let e = end.flatMap { fmt.date(from: $0) }.map { f2.string(from: $0) } ?? end ?? ""
        return "\(s) – \(e)"
    }
}

struct DayGroup: Identifiable {
    var id: String { date }
    var date: String
    var events: [CalEvent]

    var displayDate: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        guard let d = fmt.date(from: date) else { return date }
        let out = DateFormatter()
        out.dateFormat = "EEEE, MMMM d"
        return out.string(from: d)
    }
}

struct NotionResult: Codable {
    var url: String?
    var id: String?
    var title: String?
    var existed: Bool?
}

// MARK: - API Client

enum APIError: Error, LocalizedError {
    case badURL, serverError(String), decodingError

    var errorDescription: String? {
        switch self {
        case .badURL: return "Invalid URL"
        case .serverError(let msg): return msg
        case .decodingError: return "Failed to decode response"
        }
    }
}

class APIClient {
    static let shared = APIClient()
    let base = "http://localhost:8420"

    func fetchCalendars() async throws -> [CalendarItem] {
        let url = URL(string: "\(base)/calendars")!
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let calsArray = json["calendars"] as? [[String: Any]] else {
            throw APIError.decodingError
        }
        return calsArray.compactMap { dict in
            guard let id = dict["id"] as? String,
                  let label = dict["label"] as? String else { return nil }
            return CalendarItem(id: id, label: label)
        }
    }

    func fetchEvents(calendars: [CalendarItem], weeksAhead: Int) async throws -> (events: [CalEvent], start: String, end: String) {
        var req = URLRequest(url: URL(string: "\(base)/events")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "calendars": calendars.filter(\.enabled).map { ["id": $0.id, "label": $0.label] },
            "weeksAhead": weeksAhead
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let err = json?["error"] as? String { throw APIError.serverError(err) }
        let eventsData = try JSONSerialization.data(withJSONObject: json?["events"] ?? [])
        let events = try JSONDecoder().decode([CalEvent].self, from: eventsData)
        let start = json?["start"] as? String ?? ""
        let end = json?["end"] as? String ?? ""
        return (events, start, end)
    }

    func postToObsidian(days: [DayGroup], start: String, end: String) async throws -> NotionResult {
        var req = URLRequest(url: URL(string: "\(base)/obsidian")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let daysPayload = days.map { day -> [String: Any] in [
            "date": day.date,
            "events": day.events.map { e -> [String: Any] in [
                "date": e.date,
                "start": e.start as Any,
                "end": e.end as Any,
                "title": e.title,
                "calendar": e.calendar,
                "allDay": e.allDay
            ]}
        ]}
        let body: [String: Any] = ["days": daysPayload, "start": start, "end": end]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        return (try? JSONDecoder().decode(NotionResult.self, from: data)) ?? NotionResult()
    }

    func postToNotion(days: [DayGroup], start: String, end: String) async throws -> NotionResult {
        var req = URLRequest(url: URL(string: "\(base)/notion")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let daysPayload = days.map { day -> [String: Any] in [
            "date": day.date,
            "events": day.events.map { e -> [String: Any] in [
                "date": e.date,
                "start": e.start as Any,
                "end": e.end as Any,
                "title": e.title,
                "calendar": e.calendar,
                "allDay": e.allDay
            ]}
        ]}
        let body: [String: Any] = ["days": daysPayload, "start": start, "end": end]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        return (try? JSONDecoder().decode(NotionResult.self, from: data)) ?? NotionResult()
    }
}

// MARK: - Helpers

func groupByDay(_ events: [CalEvent]) -> [DayGroup] {
    var grouped: [String: [CalEvent]] = [:]
    for e in events {
        let d = e.date.isEmpty ? String(e.start?.prefix(10) ?? "") : e.date
        if !d.isEmpty { grouped[d, default: []].append(e) }
    }
    return grouped.keys.sorted().map { DayGroup(date: $0, events: grouped[$0]!) }
}
