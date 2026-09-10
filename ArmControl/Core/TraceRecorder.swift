import Foundation

/// Captures what a stored program does, by running it once and watching `CurrentPosition`.
///
/// 🔑 **This is the only way to "scrape" a program, and it is worth doing once.** The PLC exposes
/// no trajectory — see the note in `MotionTrace` — but it does expose a live position. Run the
/// program, sample densely, and the result is a real record of the move that
/// `VirtualArm` can replay forever with nothing plugged in.
///
/// Related to `MoveTimer`, and deliberately not merged with it: MoveTimer answers "how long and
/// how far" in three numbers so a traverse can be set, and samples slowly enough to be gentle.
/// This keeps the whole curve, which is what a preview needs.
///
/// ⚠️ **THIS MOVES THE RAIL.** Every caller gates it behind an explicit confirmation.
@MainActor
final class TraceRecorder: ObservableObject {
    static let shared = TraceRecorder()
    private init() {}

    @Published private(set) var capturing: Int?          // program being captured
    @Published private(set) var progress = ""
    @Published private(set) var lastError: String?

    private let link = GlamaticLink.shared

    /// How long to keep watching after the carriage stops before calling it finished.
    private static let settleSeconds = 2.0
    /// Give up on a program that never settles. A full 600 mm round trip at the slowest 70 mm/s is
    /// ~17s, so this is generous without being unbounded.
    private static let maxSeconds = 45.0
    /// 0.2s. Faster than MoveTimer's 0.4s because a preview wants curve detail, but still a
    /// bounded burst rather than the sustained fast poll that wedges the S7-1200's web server.
    private static let interval = 0.2

    var isCapturing: Bool { capturing != nil }

    /// Fire `program` and record where the carriage goes.
    @discardableResult
    func capture(program: Int) async -> MotionTrace? {
        guard !isCapturing else { return nil }
        guard link.connected else {
            lastError = "Not connected to the rail."
            return nil
        }
        capturing = program
        lastError = nil
        defer { capturing = nil; progress = "" }

        GlamaticLink.plog("trace capture: program \(program)")
        // The sampling below IS the telemetry for the duration; the background poll would only be
        // a second concurrent socket on a web server that does not cope with them.
        link.suspendPolling()
        defer { link.resumePolling() }

        await link.refresh()
        let start = link.state.currentMM
        var samples: [MotionTrace.Sample] = [.init(t: 0, mm: start)]

        guard await link.runProgram(program) else {
            lastError = "The rail refused the program."
            return nil
        }

        let t0 = Date()
        var lastMoved = Date()
        var everMoved = false
        var previous = start

        // Grid-anchored, so an HTTP round trip that takes 100 ms does not make every subsequent
        // sample land late and stretch the recorded timing. Same reasoning as MoveTimer.
        var step = 1
        while Date().timeIntervalSince(t0) < Self.maxSeconds {
            let target = t0.addingTimeInterval(Double(step) * Self.interval)
            let wait = target.timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            step += 1

            await link.refresh()
            let now = link.state.currentMM
            let elapsed = Date().timeIntervalSince(t0)
            samples.append(.init(t: elapsed, mm: now))

            if abs(now - previous) > 1.0 {
                lastMoved = Date()
                everMoved = true
            }
            previous = now
            progress = String(format: "%.1fs · %.0f mm", elapsed, now)

            if link.state.hasFault {
                lastError = "The PLC faulted during the capture."
                GlamaticLink.plog("trace capture aborted: fault")
                return nil
            }
            // Finished once it has moved and then been still for a beat.
            if everMoved, Date().timeIntervalSince(lastMoved) > Self.settleSeconds { break }
        }

        guard everMoved else {
            lastError = "The carriage never moved — nothing to record."
            GlamaticLink.plog("trace capture: program \(program) never moved")
            return nil
        }

        // Trim the trailing settle so the trace ends when the movement does, not two seconds later.
        if let lastMotion = samples.lastIndex(where: { abs($0.mm - samples[0].mm) > 1 }) {
            let keep = min(samples.count - 1, lastMotion + 2)
            samples = Array(samples.prefix(keep + 1))
        }

        let trace = MotionTrace(samples: samples,
                                source: .recorded,
                                capturedAt: Date(),
                                simulated: link.simulated)
        TraceLibrary.shared.store(trace, for: program)
        GlamaticLink.plog("trace captured: program \(program) — \(samples.count) samples, \(String(format: "%.1f", trace.duration))s, \(Int(trace.throwMM))mm")
        IncidentLog.shared.record(.system,
                                  "Recorded program \(program): \(trace.summary)")
        return trace
    }

    /// Capture several in sequence, pausing between so the rail settles and the web server gets a
    /// breath. Returns how many were captured.
    @discardableResult
    func captureAll(_ programs: [Int]) async -> Int {
        var done = 0
        for n in programs {
            guard !Task.isCancelled else { break }
            progress = "Program \(n)…"
            if await capture(program: n) != nil { done += 1 }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        return done
    }
}
