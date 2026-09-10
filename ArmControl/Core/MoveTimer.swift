import Foundation

/// Measures how long a stored program actually takes, by watching the carriage.
///
/// 🔑 **This is the number nothing in the pipeline has ever had.** The eight moves live inside the
/// PLC; the app can select and trigger them but cannot read their trajectories, and the PLC emits no
/// "program finished" signal. So every take length and every ramp-profile timing in this app has
/// been a guess against an assumed ~6s traverse — and the simulator's own honest 14.1s round trip is
/// what made the size of that guess obvious.
///
/// There is one thing the app *can* see: `CurrentPosition`. Trigger the program, sample the position
/// until the carriage stops, and three real numbers fall out:
///
/// - **latency** — trigger to first movement. Dead frames at the head of every raw pass, which is
///   the part of the clip a ramp profile silently wastes its slow-motion budget on.
/// - **duration** — first movement to settled. What the traverse should actually be.
/// - **throw** — how far this particular program pushes the carriage, in mm.
///
/// ⚠️ **THE RAIL MOVES.** This is a deliberate engineer action behind a confirmation, gated on the
/// same safety kernel as any other program trigger.
@MainActor
final class MoveTimer: ObservableObject {
    static let shared = MoveTimer()

    // MARK: Tuning
    //
    // The sample interval is the measurement's resolution AND its load on the PLC's web server.
    // 0.4s over a ~15s move is under 40 requests for the whole test — a bounded burst, not the
    // sustained fast poll that wedges the S7-1200.

    private static let interval: TimeInterval = 0.4
    /// Movement below this between samples is noise, not motion. At 85 mm/s one sample is ~34 mm,
    /// so this is nowhere near tight enough to miss a real move.
    private static let thresholdMM: Double = 2.0
    /// How long the carriage must stay put before the move counts as finished. Long enough to ride
    /// out the pause at the far end of an out-and-back without calling it the end.
    private static let stillFor: TimeInterval = 1.6
    private static let startTimeout: TimeInterval = 10
    private static let maxMove: TimeInterval = 90

    // MARK: Result

    struct Measurement: Codable, Equatable {
        var program: Int
        var at: Date
        /// Trigger → first observed movement.
        var latency: TimeInterval
        /// First movement → settled.
        var duration: TimeInterval
        /// Peak excursion from where the carriage started, in mm.
        var throwMM: Double
        var returnedToStart: Bool
        var simulated: Bool
        var samples: Int

        /// What Traverse should be set to.
        ///
        /// The take records `leadIn + traverse`, the trigger fires `leadIn` in, and the carriage
        /// then waits out its own `latency` — so the traverse has to cover latency AND duration or
        /// the clip ends mid-move. Rounded up to the next half second, with a small tail so a
        /// slightly slow run is not cut off.
        var recommendedTraverse: Double {
            let raw = latency + duration + 0.3
            return (raw * 2).rounded(.up) / 2
        }

        var summary: String {
            String(format: "%.1fs move, %.1fs to start, %.0f mm throw%@",
                   duration, latency, throwMM, returnedToStart ? ", returns home" : ", ends away")
        }
    }

    /// Resolution caveat, stated rather than implied: both edges are detected on a sample boundary,
    /// so each is up to one interval late.
    static var accuracyNote: String {
        String(format: "Accurate to about ±%.1fs — both edges land on a %.1fs sample.",
               interval, interval)
    }

    // MARK: State

    @Published private(set) var measuring: Int?
    @Published private(set) var progress = ""
    @Published private(set) var lastError: String?
    @Published private(set) var results: [Int: Measurement] = [:]

    private static let key = "armcontrol.moveTimings.v1"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([Int: Measurement].self, from: data) {
            results = decoded
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(results) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    func forget(_ program: Int) {
        results[program] = nil
        persist()
    }

    /// Swap in a whole set, e.g. from an applied event setup. Timings describe the RAIL, so an iPad
    /// pointed at the same machine inherits them rather than re-running every program to find out.
    func replaceAll(_ new: [Int: Measurement]) {
        results = new
        persist()
    }

    func forgetAll() {
        results = [:]
        persist()
    }

    // MARK: Measure

    /// Sleep to a point on a fixed sampling grid rather than for a fixed duration.
    ///
    /// A plain `sleep(interval)` drifts, because each iteration also pays for a telemetry read. In
    /// the simulator that read is free and the drift is negligible, but against the real PLC it is
    /// an HTTPS round trip — at 100ms a read, forty samples land four seconds late, and since the
    /// end of the move is detected on a sample the measured duration inflates with them. Anchoring
    /// to a grid keeps both wall-clock edges honest wherever the reads come from.
    private func sleep(until deadline: Date) async {
        let delay = deadline.timeIntervalSinceNow
        guard delay > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }

    func measure(program n: Int) async {
        guard measuring == nil else { return }

        let link = GlamaticLink.shared
        guard SafetyKernel.shared.canTriggerProgram else {
            lastError = SafetyKernel.shared.blocker?.message
                ?? "The rail will not accept a program right now."
            return
        }

        measuring = n
        lastError = nil
        defer { measuring = nil; progress = "" }

        // Drive the reads at our own rate for the duration, instead of alongside the 3s poll.
        link.suspendPolling()
        defer { link.resumePolling() }

        progress = "Reading the starting position…"
        await link.refresh()
        let baseline = link.state.currentMM
        var last = baseline
        var minP = baseline
        var maxP = baseline
        var samples = 0

        IncidentLog.shared.record(.system, "Timing program \(n)")
        progress = "Triggering program \(n)…"
        let firedAt = Date()
        guard await link.runProgram(n) else {
            lastError = "The program did not reach the rail."
            return
        }

        // 1 — wait for the carriage to actually start.
        var nextSample = firedAt
        var startedAt: Date?
        while Date().timeIntervalSince(firedAt) < Self.startTimeout {
            nextSample = nextSample.addingTimeInterval(Self.interval)
            await sleep(until: nextSample)
            await link.refresh()
            samples += 1
            let p = link.state.currentMM
            minP = min(minP, p); maxP = max(maxP, p)
            if abs(p - last) > Self.thresholdMM {
                startedAt = Date()
                last = p
                break
            }
            last = p
            progress = String(format: "Waiting for movement · %.1fs", Date().timeIntervalSince(firedAt))
        }

        guard let startedAt else {
            // Worth distinguishing: the trigger was accepted and nothing moved. On the real rail
            // that is usually a program whose throw is zero, or a carriage already at its target.
            lastError = "The trigger was accepted but the carriage never moved. Check the program number, and that the rail is not already sitting at that program's end point."
            IncidentLog.shared.record(.system, "Timing program \(n) — no movement", bad: true)
            return
        }
        let latency = startedAt.timeIntervalSince(firedAt)

        // 2 — wait for it to settle. Stillness has to persist, or the pause at the far end of an
        // out-and-back gets mistaken for the end of the move.
        var stillSince: Date?
        var settledAt: Date?
        while Date().timeIntervalSince(startedAt) < Self.maxMove {
            nextSample = nextSample.addingTimeInterval(Self.interval)
            await sleep(until: nextSample)
            await link.refresh()
            samples += 1
            let p = link.state.currentMM
            minP = min(minP, p); maxP = max(maxP, p)
            let moved = abs(p - last) > Self.thresholdMM
            last = p

            if moved {
                stillSince = nil
                progress = String(format: "Moving · %.0f mm · %.1fs", p, Date().timeIntervalSince(startedAt))
            } else {
                let since = stillSince ?? Date()
                stillSince = since
                if Date().timeIntervalSince(since) >= Self.stillFor {
                    settledAt = since
                    break
                }
                progress = String(format: "Settling · %.0f mm", p)
            }
        }

        guard let settledAt else {
            lastError = String(format: "Still moving after %.0fs — measurement abandoned.", Self.maxMove)
            IncidentLog.shared.record(.system, "Timing program \(n) — never settled", bad: true)
            return
        }

        let final = link.state.currentMM
        let m = Measurement(program: n,
                            at: Date(),
                            latency: latency,
                            duration: settledAt.timeIntervalSince(startedAt),
                            throwMM: max(abs(maxP - baseline), abs(minP - baseline)),
                            returnedToStart: abs(final - baseline) < 15,
                            simulated: link.simulated,
                            samples: samples)
        results[n] = m
        persist()
        GlamaticLink.plog("timed program \(n): \(m.summary)")
        IncidentLog.shared.record(.system, "Program \(n) timed — \(m.summary)")
    }
}
