import SwiftUI

/// The session's history — what connected, what dropped, what ran, what failed.
///
/// Newest first, because after an event the question is always "what just happened", never "how did
/// it boot". Faults are tinted so a long list can be skimmed for the red.
struct IncidentLogView: View {
    @StateObject private var log = IncidentLog.shared
    @State private var confirmClear = false
    @State private var query = ""

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM"
        return f
    }()

    var body: some View {
        Group {
            if log.entries.isEmpty {
                ContentUnavailableView("Nothing logged yet",
                                       systemImage: "list.bullet.rectangle",
                                       description: Text("Connections, faults, stops and takes appear here as they happen."))
            } else if grouped.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List {
                    ForEach(grouped, id: \.0) { day, items in
                        Section(day) {
                            ForEach(items) { entry in
                                row(entry)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("History")
        // An event fills this with hundreds of lines and the question afterwards is always narrow —
        // "what happened around the time it dropped", "how many faults". Scrolling for it is the
        // un-Apple answer.
        .searchable(text: $query, prompt: "Search the log")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ShareLink(item: log.export) {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    Button(role: .destructive) { confirmClear = true } label: {
                        Label("Clear", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .disabled(log.entries.isEmpty)
            }
        }
        .confirmationDialog("Clear the history?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { log.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This is the only record of when things dropped during an event.")
        }
    }

    /// Grouped by day so a multi-day install does not read as one undifferentiated stream.
    private var grouped: [(String, [IncidentLog.Entry])] {
        let matching = query.isEmpty
            ? log.entries
            : log.entries.filter { $0.text.localizedCaseInsensitiveContains(query) }
        var out: [(String, [IncidentLog.Entry])] = []
        for entry in matching {
            let key = Self.day.string(from: entry.at)
            if let i = out.firstIndex(where: { $0.0 == key }) {
                out[i].1.append(entry)
            } else {
                out.append((key, [entry]))
            }
        }
        return out
    }

    private func row(_ entry: IncidentLog.Entry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: entry.kind.symbol)
                .font(.footnote)
                .foregroundStyle(entry.bad ? Theme.bad : Theme.secondary)
                .frame(width: 20)

            Text(entry.display)
                .font(.subheadline)
                .foregroundStyle(entry.bad ? Theme.bad : Theme.label)

            Spacer(minLength: 12)

            Text(Self.time.string(from: entry.at))
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.tertiary)
        }
    }
}
