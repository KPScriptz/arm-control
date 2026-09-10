import Foundation

/// What a movement actually does, as a position-vs-time curve.
///
/// 🔑 **WHY THIS EXISTS, AND WHY IT IS A RECORDING RATHER THAN A DOWNLOAD.** The eight programs
/// live inside the S7-1200 and **there is no tag that returns a trajectory** — the readable set is
/// `StatusError / Velocety / Position / StatusHomed / CurrentPosition / RobotError /
/// RobotOfflineTask / ProgramNum`, and the manufacturer's own web page cannot dump a program
/// either. So a program cannot be scraped in the sense of being read out.
///
/// What it CAN do is be watched. `CurrentPosition` is live, so running a program once while
/// sampling it densely produces a real record of the move — where the carriage went, when, and how
/// fast. That record is then replayable forever with no rail attached, which is the whole point:
/// **connect once, preview for the rest of the project.**
///
/// Custom motions need no capture at all. Their waypoints fully determine the curve, so
/// `synthesised(from:)` computes it exactly — those preview on a laptop, today, with nothing
/// plugged in.
struct MotionTrace: Codable, Equatable {

    struct Sample: Codable, Equatable {
        var t: Double     // seconds from trigger
        var mm: Double    // carriage position
    }

    /// Where the curve came from. Kept in the data because a **predicted** curve and a **recorded**
    /// one must never look alike on screen — one is what the machine did, the other is a guess
    /// drawn from three numbers, and confusing them is how somebody trusts a preview that was
    /// never checked against the rail.
    enum Source: String, Codable {
        /// Sampled off the real rail.
        case recorded
        /// Computed exactly from a custom motion's own waypoints. As true as the motion itself.
        case synthesised
        /// Inferred from a `MoveTimer` measurement (latency, duration, throw). The shape is a
        /// guess; only the endpoints and the timing are real.
        case predicted

        var label: String {
            switch self {
            case .recorded:    return "Recorded from the rail"
            case .synthesised: return "Computed from the waypoints"
            case .predicted:   return "Predicted from a timing measurement"
            }
        }

        /// True when the SHAPE of the curve is trustworthy, not just its endpoints.
        var shapeIsReal: Bool { self != .predicted }
    }

    var samples: [Sample]
    var source: Source
    var capturedAt: Date?
    /// Set when the capture came from the simulated rail, so a preview can say so rather than
    /// passing a simulation off as the machine.
    var simulated: Bool = false

    var duration: Double { samples.last?.t ?? 0 }
    var isEmpty: Bool { samples.count < 2 }

    // MARK: Reading the curve

    /// Position at an arbitrary time, linearly interpolated. Out-of-range clamps to the ends.
    func position(at time: Double) -> Double {
        guard let first = samples.first else { return 0 }
        if time <= first.t { return first.mm }
        guard let last = samples.last else { return first.mm }
        if time >= last.t { return last.mm }
        // Linear scan is fine: a trace is a few hundred samples and this is called once per frame.
        for i in 1..<samples.count where samples[i].t >= time {
            let a = samples[i - 1], b = samples[i]
            let span = b.t - a.t
            guard span > 0 else { return b.mm }
            let f = (time - a.t) / span
            return a.mm + (b.mm - a.mm) * f
        }
        return last.mm
    }

    /// Signed mm/s at a time, from the neighbouring samples. Negative means travelling back.
    func velocity(at time: Double) -> Double {
        guard samples.count > 1 else { return 0 }
        let dt = 0.15
        return (position(at: time + dt) - position(at: time - dt)) / (2 * dt)
    }

    /// Seconds from the trigger to the first observed movement.
    ///
    /// 🔑 **This is the number the whole ramp hangs off, and on this rail it is enormous** —
    /// measured 3.9s to 9.4s across the eight programs, against the 0.4s the simulator reported.
    /// Every pass timing in every profile is written from the START OF THE MOVE, so if this is
    /// wrong the clip opens on seconds of motionless rail played at 4× slow.
    var latency: Double {
        guard let first = samples.first else { return 0 }
        for s in samples where abs(s.mm - first.mm) > 1.0 { return max(0, s.t - 0.2) }
        return 0
    }

    /// First movement to last movement — how long the carriage is actually in motion.
    var moveDuration: Double {
        guard let first = samples.first else { return 0 }
        var last = 0.0
        for i in 1..<max(1, samples.count) where abs(samples[i].mm - samples[i - 1].mm) > 1.0 {
            last = samples[i].t
        }
        return max(0, last - latency)
    }

    /// What Traverse should be, for a take that must cover this whole movement.
    ///
    /// The camera rolls for `leadIn + traverse` and the trigger fires `leadIn` in, so the traverse
    /// has to cover the latency AND the movement, with a little tail so a slightly slow run is not
    /// clipped.
    var recommendedTraverse: Double {
        ((latency + moveDuration + 0.5) * 2).rounded(.up) / 2
    }

    var minMM: Double { samples.map(\.mm).min() ?? 0 }
    var maxMM: Double { samples.map(\.mm).max() ?? 0 }
    var throwMM: Double { maxMM - minMM }

    var peakSpeed: Double {
        guard samples.count > 2 else { return 0 }
        var peak = 0.0
        var t = 0.0
        while t <= duration {
            peak = max(peak, abs(velocity(at: t)))
            t += 0.1
        }
        return peak
    }

    /// Ends within a few mm of where it started — an out-and-back rather than a one-way move.
    var returnsToStart: Bool {
        guard let a = samples.first, let b = samples.last else { return false }
        return abs(a.mm - b.mm) < 8
    }

    /// Times where travel reverses. These are the moments a ramp profile wants to sample, so the
    /// virtual preview marks them and `RampTimeline` can use them for its "turn" marker.
    var turnarounds: [Double] {
        guard samples.count > 4 else { return [] }
        var out: [Double] = []
        var lastSign = 0
        var t = 0.1
        while t < duration - 0.1 {
            let v = velocity(at: t)
            let sign = abs(v) < 3 ? 0 : (v > 0 ? 1 : -1)
            if sign != 0, lastSign != 0, sign != lastSign {
                // Collapse a cluster — a real reversal is one event, not the six samples it spans.
                if out.last.map({ t - $0 > 0.5 }) ?? true { out.append(t) }
            }
            if sign != 0 { lastSign = sign }
            t += 0.1
        }
        return out
    }

    /// One line for a list row.
    var summary: String {
        guard !isEmpty else { return "Not captured yet" }
        return String(format: "%.1fs · %.0f mm · peak %.0f mm/s%@",
                      duration, throwMM, peakSpeed,
                      returnsToStart ? " · returns" : " · one way")
    }

    // MARK: Building one without hardware

    /// The exact curve a custom motion produces. Constant-velocity legs and dwells, which is
    /// precisely what `MotionStore.play` commands — so this is not an approximation of the motion,
    /// it *is* the motion.
    static func synthesised(from motion: CustomMotion, start: Double = 0) -> MotionTrace {
        var samples: [Sample] = [Sample(t: 0, mm: start)]
        var here = start
        var t = 0.0
        for w in motion.waypoints {
            let target = w.clampedPosition
            let legTime = abs(target - here) / max(1, w.clampedVelocity)
            if legTime > 0.001 {
                // Sample the leg rather than only its endpoints, so the speed readout and the
                // graph have something to draw between them.
                let steps = max(2, Int(legTime * 20))
                for s in 1...steps {
                    let f = Double(s) / Double(steps)
                    samples.append(Sample(t: t + legTime * f, mm: here + (target - here) * f))
                }
                t += legTime
            }
            if w.dwell > 0 {
                t += w.dwell
                samples.append(Sample(t: t, mm: target))
            }
            here = target
        }
        return MotionTrace(samples: samples, source: .synthesised, capturedAt: nil)
    }

    /// A plausible curve for a program that has been TIMED but never traced.
    ///
    /// ⚠️ The shape is invented — a trapezoid with a short accel and decel — and only the latency,
    /// the duration, the throw and whether it returned are real. Marked `.predicted` so every
    /// screen can say so. It exists because "we know it travels 587 mm in 14.1s and comes back" is
    /// far more useful than an empty box, not because it is a substitute for capturing the thing.
    static func predicted(from m: MoveTimer.Measurement, start: Double = 0) -> MotionTrace {
        let peak = start + m.throwMM
        var samples: [Sample] = [Sample(t: 0, mm: start)]
        let move = m.duration

        func add(_ t: Double, _ mm: Double) { samples.append(Sample(t: t, mm: mm)) }

        /// One leg: accelerate for `ramp`, cruise, decelerate for `ramp`.
        ///
        /// 🐞 **The distance split used to be a guess (12% / 88%) and it produced impossible
        /// speeds.** With a 0.6s shoulder on a 7.05s leg, putting 12% of the travel in the last
        /// shoulder made that shoulder *faster* than the cruise — the readout claimed 117 mm/s on a
        /// machine that physically clamps at 100. A predicted curve is allowed to be a guess about
        /// shape; it is not allowed to imply a speed the rail cannot reach.
        ///
        /// Derived instead: under constant acceleration a shoulder covers `v·r/2`, so
        /// `D = v(T − r)` and the cruise speed is `D / (T − r)`. Everything follows from that and
        /// stays inside the machine's envelope.
        func leg(from a: Double, to b: Double, t0: Double, T: Double) {
            let d = b - a
            let ramp = min(0.6, T * 0.2)
            let cruiseWindow = max(0.05, T - ramp)
            let v = d / cruiseWindow                     // signed mm/s
            let shoulder = v * ramp / 2                  // distance covered while accelerating
            add(t0 + ramp, a + shoulder)
            add(t0 + T - ramp, a + shoulder + v * (T - 2 * ramp))
            add(t0 + T, b)
        }

        if m.returnedToStart {
            let half = move / 2
            leg(from: start, to: peak, t0: 0, T: half)
            leg(from: peak, to: start, t0: half, T: half)
        } else {
            leg(from: start, to: peak, t0: 0, T: move)
        }
        return MotionTrace(samples: samples, source: .predicted,
                           capturedAt: m.at, simulated: m.simulated)
    }
}

/// Every captured trace, by program number, plus lookup for custom motions.
@MainActor
final class TraceLibrary: ObservableObject {
    static let shared = TraceLibrary()

    private static let key = "armcontrol.traces.v1"

    /// Program number → what it does.
    @Published private(set) var byProgram: [Int: MotionTrace] = [:]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([Int: MotionTrace].self, from: data) {
            byProgram = decoded
        }
    }

    func store(_ trace: MotionTrace, for program: Int) {
        byProgram[program] = trace
        persist()
    }

    func forget(_ program: Int) {
        byProgram.removeValue(forKey: program)
        persist()
    }

    /// The best curve available for a program: a real recording, else a prediction from its
    /// timing, else nothing.
    func best(for program: Int) -> MotionTrace? {
        if let recorded = byProgram[program], !recorded.isEmpty { return recorded }
        if let m = MoveTimer.shared.results[program], m.throwMM > 1 {
            return .predicted(from: m)
        }
        return nil
    }

    var capturedCount: Int { byProgram.values.filter { !$0.isEmpty }.count }

    private func persist() {
        guard let data = try? JSONEncoder().encode(byProgram) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    func replaceAll(_ traces: [Int: MotionTrace]) {
        byProgram = traces
        persist()
    }
}
