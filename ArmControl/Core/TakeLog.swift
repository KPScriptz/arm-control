import AVFoundation
import Foundation
import SwiftUI

/// Every finished take, so one can be found again.
///
/// 🔑 **The scenario this exists for happens at every event.** A guest scans the QR, walks off, and
/// the scan did not take — bad angle, locked phone, wrong Wi-Fi, someone stood in front of the
/// screen. They come back two minutes later and ask for it. Until now the attendant's only route
/// was the Photos app: scroll a camera roll of near-identical clips, guess which one, and AirDrop it
/// while the queue waits. This is that clip, by time, with its QR one tap away.
///
/// It doubles as the session record — how many takes ran tonight and how many had something wrong
/// with them, which is the first question after an event and the last thing anybody was counting.
@MainActor
final class TakeLog: ObservableObject {
    static let shared = TakeLog()

    struct Entry: Codable, Identifiable, Equatable {
        var id = UUID()
        var at: Date
        var program: Int
        var programName: String
        /// ⚠️ **The FILENAME, never an absolute path.** An app's container directory is not stable:
        /// its UUID changes on reinstall, and on a real device it changes across app updates and
        /// restores too. A stored absolute path therefore points into a container that no longer
        /// exists, and every take in the list reads as "pruned" the first time the app is updated.
        /// Store the name and rebuild the URL against the current temp directory at read time.
        var file: String
        var duration: Double
        /// Set when the program did not reach the rail, or the camera dropped frames.
        var warning: String?

        var url: URL { FileManager.default.temporaryDirectory.appendingPathComponent(file) }
        var isAvailable: Bool { FileManager.default.fileExists(atPath: url.path) }
    }

    /// Matched to `Storage.keepFiles` — keeping more records than there can be files would list
    /// takes that are guaranteed to be gone.
    private static let cap = Storage.keepFiles
    private static let key = "armcontrol.takes.v1"

    @Published private(set) var entries: [Entry] = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = decoded
        }
    }

    func record(program: Int, url: URL, duration: Double, warning: String?) {
        let name = ProgramStore.shared.presets.first { $0.number == program }?.display
            ?? "Program \(program)"
        entries.insert(Entry(at: Date(),
                             program: program,
                             programName: name,
                             file: url.lastPathComponent,
                             duration: duration,
                             warning: warning),
                       at: 0)
        if entries.count > Self.cap { entries.removeLast(entries.count - Self.cap) }
        persist()
    }

    func clear() {
        entries = []
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    // MARK: Session

    var today: [Entry] {
        let start = Calendar.current.startOfDay(for: Date())
        return entries.filter { $0.at >= start }
    }

    var todayWithWarnings: Int { today.filter { $0.warning != nil }.count }

    /// One line for the Setup menu, and the answer to "how did tonight go".
    var todaySummary: String {
        let n = today.count
        guard n > 0 else { return "None yet" }
        let bad = todayWithWarnings
        return bad == 0 ? "\(n) today" : "\(n) today · \(bad) flagged"
    }
}

/// First frame of a take, for the list. Cached, because scrolling a list that decodes a 120fps
/// source per row is how a smooth list becomes a stuttering one.
@MainActor
final class ThumbnailCache: ObservableObject {
    static let shared = ThumbnailCache()
    private var images: [String: UIImage] = [:]
    private var inFlight: Set<String> = []

    @Published private(set) var version = 0

    func image(for entry: TakeLog.Entry) -> UIImage? {
        if let cached = images[entry.file] { return cached }
        guard !inFlight.contains(entry.file), entry.isAvailable else { return nil }
        inFlight.insert(entry.file)
        Task { [path = entry.file, url = entry.url] in
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 240, height: 240)
            let time = CMTime(seconds: 0.2, preferredTimescale: 600)
            guard let cg = try? await generator.image(at: time).image else {
                inFlight.remove(path)
                return
            }
            images[path] = UIImage(cgImage: cg)
            inFlight.remove(path)
            version &+= 1
        }
        return nil
    }
}
