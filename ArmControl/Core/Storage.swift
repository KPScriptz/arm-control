import Foundation

/// Keeps the temporary directory from quietly filling up over an event.
///
/// 🔑 Every take writes several files: the raw pass, one or two generated still clips, and the
/// finished render. Nothing deleted them. A busy evening is hundreds of takes and several GB, and
/// the failure mode is horrible — iOS starts refusing writes, the render fails in front of a guest,
/// and nothing on screen says the disk is full. This runs after every take.
enum Storage {

    /// How many finished clips to keep. These are what the Takes list, the delivery server and a
    /// guest coming back for a failed scan all depend on, and they are small — a few hundred KB.
    static let keepFiles = 60

    /// 🔑 **How many RAW passes to keep, which is a completely different number.**
    ///
    /// The old policy kept the newest 60 files of any kind, and that was quietly the wrong shape.
    /// A take writes a raw pass, a render and a still or two, so 60 files was only about twenty
    /// takes — and two thirds of what it kept were the raw passes, which at 1080p120 are on the
    /// order of **two hundred times the size of the render**. The count-based cap therefore spent
    /// almost all of the disk on the files nobody needs after the render finishes, while evicting
    /// the finished clips a guest might come back for.
    ///
    /// Nothing re-renders a pass from earlier in an evening; Post's "Use last take" wants the most
    /// recent one, and tuning wants the last handful.
    static let keepRawPasses = 6

    /// Flash and end-card clips. `RampRenderer` deletes its own via `defer`, so any survivor is an
    /// orphan from a render that was interrupted.
    static let keepStills = 4

    private static let renderPrefixes = ["ramp-"]
    private static let rawPrefixes = ["pass-", "synthetic-", "source-"]
    private static let stillPrefixes = ["still-"]

    /// Below this, refuse to start another take rather than fail halfway through one.
    static let minimumFreeBytes: Int64 = 300_000_000

    static var freeBytes: Int64 {
        let url = FileManager.default.temporaryDirectory
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? .max
    }

    static var isLow: Bool { freeBytes < minimumFreeBytes }

    static var freeDescription: String {
        ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)
    }

    /// Delete the oldest generated files, newest-first retention.
    ///
    /// Only touches files this app generates, matched by prefix — never anything a user put there.
    /// Prune each kind of file against its own budget, newest-first.
    ///
    /// Only touches files this app generates, matched by prefix — never anything a user put there.
    @discardableResult
    static func prune() -> Int {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: fm.temporaryDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return 0 }

        func newestFirst(_ prefixes: [String]) -> [URL] {
            items
                .filter { url in prefixes.contains { url.lastPathComponent.hasPrefix($0) } }
                .sorted { a, b in
                    let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    return da > db
                }
        }

        var removed = 0
        for (prefixes, keep) in [(renderPrefixes, keepFiles),
                                 (rawPrefixes, keepRawPasses),
                                 (stillPrefixes, keepStills)] {
            for url in newestFirst(prefixes).dropFirst(keep) where (try? fm.removeItem(at: url)) != nil {
                removed += 1
            }
        }
        if removed > 0 {
            GlamaticLink.plog("pruned \(removed) old media files, \(freeDescription) free")
        }
        return removed
    }
}
