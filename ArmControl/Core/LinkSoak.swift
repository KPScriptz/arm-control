import Foundation

/// The endurance test for the one thing about this app that has never been proven: whether the
/// link to the PLC survives a whole event.
///
/// 🔑 **This is the test that matters, and it deserves a number rather than a vibe.** The old
/// client's failure was not a wrong command — it was the S7-1200's web server degrading under a
/// sustained session until reads stopped meaning anything. That takes minutes to show up, it looks
/// completely fine for the first thirty seconds, and "leave it running for ten minutes and see"
/// asks an operator to notice the absence of something. So this counts instead: every telemetry
/// read, every silent one, every expired session, every recovery, and the longest stretch the app
/// spent with no idea where the carriage was.
///
/// ⚠️ **It deliberately generates no traffic of its own.** The 3s poll in `GlamaticLink` IS the
/// load being tested; a soak that issued its own reads would double the request volume and measure
/// a machine under twice the stress it will actually see. So this watches the link's own monotonic
/// counters and subtracts. The only thing it can add — off by default — is a periodic program
/// trigger, because an event is polling *plus* someone hitting Start every ninety seconds.
@MainActor
final class LinkSoak: ObservableObject {
    static let shared = LinkSoak()

    // MARK: Report

    struct Report: Codable, Equatable {
        var startedAt = Date()
        var duration: TimeInterval = 0
        var reads = 0
        var silent = 0
        var expired = 0
        var reconnects = 0
        var triggers = 0
        var triggerFailures = 0
        /// Longest stretch with no successful telemetry read — the time the app was blind.
        var longestGap: TimeInterval = 0
        var endedConnected = true
        var simulated = false

        var goodReads: Int { reads }
        var faults: Int { silent + expired }

        /// A one-line answer to "did it hold?".
        var verdict: String {
            if !endedConnected {
                return "FAILED — the link was down when the test ended."
            }
            // ⚠️ A run stopped before a single poll completed used to come back "Solid. 0 reads,
            // nothing dropped" with a green seal — a pass awarded for observing nothing, which is
            // strictly worse than no test at all. Zero reads is never evidence.
            if reads == 0 {
                return "Too short to tell — not one telemetry read completed."
            }
            if faults == 0 && reconnects == 0 {
                return String(format: "Solid. %d reads, nothing dropped, longest gap %.1fs.",
                              reads, longestGap)
            }
            if reconnects == 0 {
                return String(format: "Held, with %d blip%@. Longest gap %.1fs.",
                              faults, faults == 1 ? "" : "s", longestGap)
            }
            return String(format: "Recovered %d time%@ from %d fault%@. Longest blind spot %.1fs.",
                          reconnects, reconnects == 1 ? "" : "s",
                          faults, faults == 1 ? "" : "s", longestGap)
        }

        /// One or two words for a menu row. "0 events" would be the literal count for a run that
        /// never read anything, and it would look like a pass.
        var shortLabel: String {
            if !endedConnected { return "Failed" }
            if reads == 0 { return "Inconclusive" }
            if clean { return "Clean" }
            let n = faults + reconnects
            return "\(n) event\(n == 1 ? "" : "s")"
        }

        /// Green only when nothing needed recovering. A link that reconnected is a link that will
        /// reconnect in front of a guest, and that is worth showing as amber rather than a tick.
        var clean: Bool { endedConnected && reads > 0 && faults == 0 && reconnects == 0 }

        var export: String {
            let f = ISO8601DateFormatter()
            return """
            Glamatic link soak
            started      \(f.string(from: startedAt))
            duration     \(Int(duration))s\(simulated ? "   (SIMULATED RAIL)" : "")
            reads ok     \(reads)
            silent       \(silent)
            expired      \(expired)
            reconnects   \(reconnects)
            triggers     \(triggers) (\(triggerFailures) failed)
            longest gap  \(String(format: "%.1f", longestGap))s
            ended        \(endedConnected ? "connected" : "DISCONNECTED")
            verdict      \(verdict)
            """
        }
    }

    // MARK: Settings

    private static let minutesKey = "armcontrol.soak.minutes"
    private static let triggerKey = "armcontrol.soak.triggerEvery"
    private static let lastKey = "armcontrol.soak.lastReport"

    /// How long to run. Ten minutes is the figure that matters — it is roughly where the old
    /// client used to die — but a full evening is the honest rehearsal.
    @Published var minutes: Int {
        didSet { UserDefaults.standard.set(minutes, forKey: Self.minutesKey) }
    }

    /// Fire the booth's program every N seconds during the soak. 0 = observe only.
    @Published var triggerEvery: Int {
        didSet { UserDefaults.standard.set(triggerEvery, forKey: Self.triggerKey) }
    }

    // MARK: Live state

    @Published private(set) var running = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var live = Report()
    @Published private(set) var last: Report?

    var remaining: TimeInterval { max(0, Double(minutes * 60) - elapsed) }
    var progress: Double {
        let total = Double(minutes * 60)
        return total > 0 ? min(1, elapsed / total) : 0
    }

    private let link = GlamaticLink.shared
    private var task: Task<Void, Never>?

    private init() {
        let m = UserDefaults.standard.integer(forKey: Self.minutesKey)
        minutes = m > 0 ? m : 10
        triggerEvery = UserDefaults.standard.integer(forKey: Self.triggerKey)
        if let data = UserDefaults.standard.data(forKey: Self.lastKey),
           let decoded = try? JSONDecoder().decode(Report.self, from: data) {
            last = decoded
        }
    }

    // MARK: Run

    func start() {
        guard !running, link.connected else { return }

        // Snapshot the link's monotonic counters. Everything reported is a delta from here, so the
        // soak measures this run and not the whole session.
        let base = (ok: link.readsOK, silent: link.readsSilent,
                    expired: link.readsExpired, reconnects: link.reconnects)
        let startedAt = Date()
        var report = Report(startedAt: startedAt, simulated: link.simulated)

        running = true
        elapsed = 0
        live = report
        GlamaticLink.plog("soak start — \(minutes)min, trigger every \(triggerEvery)s")
        IncidentLog.shared.record(.system, "Link soak started — \(minutes) min")

        task = Task { [weak self] in
            guard let self else { return }
            var lastTrigger = startedAt
            let deadline = startedAt.addingTimeInterval(Double(self.minutes * 60))

            while !Task.isCancelled, Date() < deadline {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { break }

                let now = Date()
                self.elapsed = now.timeIntervalSince(startedAt)

                report.duration = self.elapsed
                report.reads = self.link.readsOK - base.ok
                report.silent = self.link.readsSilent - base.silent
                report.expired = self.link.readsExpired - base.expired
                report.reconnects = self.link.reconnects - base.reconnects

                // The gap runs from the last good read, or from the start of the test if there has
                // not been one yet — otherwise a link that never came back would report a gap of 0.
                let since = self.link.lastGoodRead.map { max($0, startedAt) } ?? startedAt
                report.longestGap = max(report.longestGap, now.timeIntervalSince(since))

                if self.triggerEvery > 0,
                   now.timeIntervalSince(lastTrigger) >= Double(self.triggerEvery) {
                    lastTrigger = now
                    await self.fireTrigger(&report)
                }

                report.endedConnected = self.link.connected
                self.live = report
            }

            report.duration = Date().timeIntervalSince(startedAt)
            report.endedConnected = self.link.connected
            self.finish(report)
        }
    }

    /// Fire the booth's own program, so the soak exercises the raw channel alongside the poll the
    /// way a real evening does. Refused rather than forced when the rail is not in a state to move —
    /// a soak test is not a reason to energise anything.
    private func fireTrigger(_ report: inout Report) async {
        guard SafetyKernel.shared.canTriggerProgram else {
            report.triggerFailures += 1
            return
        }
        let program = max(0, UserDefaults.standard.integer(forKey: "armcontrol.take.program"))
        let ok = await link.runProgram(program == 0 ? 1 : program)
        report.triggers += 1
        if !ok { report.triggerFailures += 1 }
    }

    /// Cancel the run and let the task's own tail write the report.
    ///
    /// 🐞 It used to build and finish a report here as well. `cancel()` is not synchronous, so the
    /// loop still fell through to its own `finish()` a moment later and every stopped soak logged
    /// its verdict TWICE, one second apart — which reads like two separate tests in the History an
    /// operator is trying to interpret after an event. One owner of the ending, not two.
    func stop() {
        task?.cancel()
        task = nil
    }

    private func finish(_ report: Report) {
        guard running else { return }
        running = false
        live = report
        last = report
        if let data = try? JSONEncoder().encode(report) {
            UserDefaults.standard.set(data, forKey: Self.lastKey)
        }
        GlamaticLink.plog("soak done — \(report.verdict)")
        IncidentLog.shared.record(.system,
                                  "Link soak \(Int(report.duration))s — \(report.verdict)",
                                  bad: !report.clean)
    }
}
