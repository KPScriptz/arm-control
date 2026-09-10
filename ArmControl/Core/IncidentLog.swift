import Foundation

/// A timestamped record of everything that went wrong, and everything that ran.
///
/// 🔑 Why this matters more than it looks: the Glamatic's web server has a history of going quiet
/// mid-session, and "it kept dropping" is not something you can debug the next morning from memory.
/// This is the post-event proof of WHEN the link died, how often, and what the booth was doing at
/// the time. It survives relaunches, because a crash or a restart is exactly when you most want it.
@MainActor
final class IncidentLog: ObservableObject {
    static let shared = IncidentLog()

    enum Kind: String, Codable {
        case link       // connected / dropped / session expired
        case fault      // PLC fault raised or cleared
        case safety     // armed, disarmed, halted, stopped
        case take       // a take ran, or failed
        case system     // storage, permissions, kiosk

        var symbol: String {
            switch self {
            case .link:   return "cable.connector"
            case .fault:  return "exclamationmark.triangle.fill"
            case .safety: return "bolt.fill"
            case .take:   return "film"
            case .system: return "gearshape"
            }
        }
    }

    struct Entry: Codable, Identifiable {
        var id = UUID()
        var at: Date
        var kind: Kind
        var text: String
        var bad: Bool
        /// How many times this happened in a row. Optional so entries written before it existed
        /// still decode; `nil` and `1` both mean "once".
        var repeats: Int?

        var occurrences: Int { max(1, repeats ?? 1) }
        /// What the row should read, count included when there was more than one.
        var display: String { occurrences > 1 ? "\(text)  ×\(occurrences)" : text }
    }

    private static let key = "armcontrol.incidents.v1"
    private static let cap = 300

    @Published private(set) var entries: [Entry] = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = decoded
        }
    }

    /// Newest first — the thing you want after an event is what just happened, not the first boot.
    func record(_ kind: Kind, _ text: String, bad: Bool = false) {
        // Collapse an identical consecutive entry rather than filling the log with one flapping
        // link.
        //
        // 🐞 This used to just `return`, which threw the repeat away entirely. A link that dropped
        // forty times in two minutes logged **once**, and the count is precisely the thing being
        // looked for afterwards — "it kept dropping" is a complaint, "×40 in two minutes" is a
        // diagnosis. The occurrence is now folded into the entry, and its timestamp moves to the
        // most recent one so the log reads as "last seen at", not "first seen at".
        if let first = entries.first, first.kind == kind, first.text == text,
           Date().timeIntervalSince(first.at) < 120 {
            entries[0].repeats = (first.repeats ?? 1) + 1
            entries[0].at = Date()
            persist()
            return
        }
        entries.insert(Entry(at: Date(), kind: kind, text: text, bad: bad), at: 0)
        if entries.count > Self.cap { entries.removeLast(entries.count - Self.cap) }
        persist()
        GlamaticLink.plog("[\(kind.rawValue)] \(text)")
    }

    func clear() {
        entries.removeAll()
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    /// Plain text, newest first, for AirDrop or a message to whoever was not at the venue.
    var export: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let body = entries.map { "\(f.string(from: $0.at))  [\($0.kind.rawValue)] \($0.display)" }
        return (["Arm Control — incident log", ""] + body).joined(separator: "\n")
    }

    /// Faults **today**, not since the app was installed.
    ///
    /// A lifetime total sits in the Setup menu as a permanent red badge that only ever grows, which
    /// stops meaning anything within a week and trains people to ignore the one place that should
    /// be worth looking at. What an operator needs to know is whether this event is going badly.
    var faultCountToday: Int {
        let start = Calendar.current.startOfDay(for: Date())
        return entries.filter { $0.bad && $0.at >= start }.reduce(0) { $0 + $1.occurrences }
    }

    var faultCount: Int { entries.filter(\.bad).count }
}
