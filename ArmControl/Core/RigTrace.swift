import Foundation

// MARK: - Recording the whole rig over time
//
// 🔑 **WHY THIS IS NOT `MotionTrace`.** `MotionTrace` records ONE channel — `mm`, the carriage
// position — because it was built to answer "how long does stored program N take and how far does it
// go". That is the right shape for the rail and useless for a rig with six moving things.
//
// ⚠️ **AND THE THING THAT MUST BE SAID OUT LOUD: the stored programs drive the RAIL ONLY.** Program
// 14 is two ASCII bytes to port 2000 on the Siemens PLC; it moves the carriage. It does not command
// the xArm, so recording it yields a real rail curve and five flat joint tracks. That is not a bug in
// this recorder — it is what the machine did. The joint tracks fill in when something actually drives
// the joints: a jog, or playing an `ArmMotion`.
//
// So this records **every channel at once, continuously**, and whatever moved shows up. Run a stored
// program and jog the arm during it and you get both, on one shared clock — which is the only way a
// timeline can show how they relate.

struct RigSample: Codable, Equatable {
    /// Seconds since the recording started.
    var t: Double
    /// Carriage position in mm, or nil when the rail was not being recorded.
    var rail: Double?
    /// Joint angles in degrees, J1…J5. Empty when the arm was not being recorded.
    var joints: [Double]
}

struct RigTrace: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var samples: [RigSample]
    /// Which stored program was fired to produce this, if any.
    var program: Int?
    var recorded = Date()

    var duration: Double { samples.last?.t ?? 0 }
    var hasRail: Bool { samples.contains { $0.rail != nil } }
    var hasJoints: Bool { samples.contains { !$0.joints.isEmpty } }

    /// The values of one channel over time. Channel −1 is the rail; 0…4 are J1…J5.
    func track(_ channel: Int) -> [(t: Double, v: Double)] {
        samples.compactMap { s in
            if channel < 0 {
                guard let r = s.rail else { return nil }
                return (s.t, r)
            }
            guard channel < s.joints.count else { return nil }
            return (s.t, s.joints[channel])
        }
    }

    /// How far a channel actually moved. **This is what distinguishes a real track from a flat one**,
    /// and the timeline uses it to say "J3 never moved" rather than drawing a straight line and
    /// leaving you to wonder whether the recording failed.
    func range(_ channel: Int) -> (min: Double, max: Double)? {
        let vs = track(channel).map(\.v)
        guard let lo = vs.min(), let hi = vs.max() else { return nil }
        return (lo, hi)
    }

    func moved(_ channel: Int, threshold: Double = 1.0) -> Bool {
        guard let r = range(channel) else { return false }
        return r.max - r.min > threshold
    }

    /// Value of a channel at an arbitrary time, linearly interpolated.
    func value(_ channel: Int, at time: Double) -> Double {
        let pts = track(channel)
        guard let first = pts.first else { return 0 }
        if time <= first.t { return first.v }
        guard let last = pts.last else { return first.v }
        if time >= last.t { return last.v }
        for i in 1..<pts.count where pts[i].t >= time {
            let a = pts[i - 1], b = pts[i]
            let span = b.t - a.t
            guard span > 0 else { return b.v }
            let f = (time - a.t) / span
            return a.v + (b.v - a.v) * f
        }
        return last.v
    }
}

// MARK: - The recorder

@MainActor
final class RigRecorder: ObservableObject {
    static let shared = RigRecorder()

    private static let key = "armcontrol.rigTraces.v1"

    @Published private(set) var traces: [RigTrace] = []
    @Published private(set) var recording = false
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var note = ""

    /// Which channels to sample. Rail costs an HTTPS round trip per sample against a controller with
    /// a tiny connection pool, so it is opt-in.
    @Published var includeRail = true
    @Published var includeArm = true

    private var task: Task<Void, Never>?
    private let rail = GlamaticLink.shared
    private let arm = XArmLink.shared

    private init() {
        if let d = UserDefaults.standard.data(forKey: Self.key),
           let t = try? JSONDecoder().decode([RigTrace].self, from: d) {
            traces = t
        }
    }

    // MARK: Recording

    /// Start sampling. Optionally fires a stored program first, so the recording starts a beat
    /// before the movement rather than after it.
    ///
    /// ⚠️ THE RAIL MOVES if `program` is given.
    func start(name: String, program: Int? = nil, seconds: Double = 20) {
        guard !recording else { return }
        recording = true
        elapsed = 0
        note = program.map { "Running program \($0)…" } ?? "Recording…"

        task = Task { [weak self] in
            guard let self else { return }

            // 🔑 The rail's background poll is suspended for the duration: the sampling loop below
            // IS the telemetry, and a second concurrent socket is what wedges the S7-1200's tiny
            // web server. Same reasoning as MoveTimer.
            if await self.includeRail { await self.rail.suspendPolling() }
            defer { Task { @MainActor in
                if self.includeRail { self.rail.resumePolling() }
            } }

            var samples: [RigSample] = []
            let began = Date()
            // 🔑 Record the CONDITIONS, not just the values. "The joints didn't move" and "the
            // joints weren't being read" produce the same flat track, and telling them apart after
            // the fact has already cost a debate. Count the reads that came back empty.
            var armReadsAttempted = 0
            var armReadsFailed = 0
            let armWasConnected = await self.arm.connected
            let armWasSimulated = await self.arm.simulated

            // Fire the program AFTER the clock starts, so the trigger latency — the dead head before
            // the carriage moves — is part of the record rather than silently cropped.
            if let p = program {
                _ = await self.rail.runProgram(p)
            }

            // Sleep to a FIXED GRID rather than sleeping the interval. Each rail read is an HTTPS
            // round trip; at 100ms a read, forty interval-sleeps land four seconds late and every
            // recorded time is stretched with them.
            let interval = 0.25
            var tick = 0
            while !Task.isCancelled {
                let now = Date().timeIntervalSince(began)
                if now >= seconds { break }

                var railMM: Double?
                if await self.includeRail {
                    await self.rail.refresh()
                    railMM = Double(await self.rail.state.currentPosition)
                }
                var joints: [Double] = []
                if await self.includeArm, await self.arm.connected {
                    armReadsAttempted += 1
                    if let j = await self.arm.refreshJoints() { joints = j }
                    else { armReadsFailed += 1 }
                }

                samples.append(RigSample(t: now, rail: railMM, joints: joints))
                await MainActor.run { self.elapsed = now }

                tick += 1
                let nextAt = began.addingTimeInterval(Double(tick) * interval)
                let wait = nextAt.timeIntervalSinceNow
                if wait > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                }
            }

            await MainActor.run {
                self.finish(name: name, program: program, samples: samples,
                            armConnected: armWasConnected, armSimulated: armWasSimulated,
                            armReads: armReadsAttempted, armFailed: armReadsFailed)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        recording = false
        note = "Stopped."
    }

    private func finish(name: String, program: Int?, samples: [RigSample],
                        armConnected: Bool, armSimulated: Bool, armReads: Int, armFailed: Int) {
        recording = false
        task = nil
        guard samples.count > 1 else {
            note = "Nothing recorded — the link may be down."
            return
        }
        let trace = RigTrace(name: name, samples: samples, program: program)
        traces.append(trace)
        persist()

        // Say what actually moved. A recording whose tracks are all flat looks identical to a
        // broken recorder, and those have completely different causes.
        var movedNames: [String] = []
        if trace.moved(-1) { movedNames.append("rail") }
        for j in 0..<XArmLink.jointCount where trace.moved(j) { movedNames.append("J\(j + 1)") }

        var line = movedNames.isEmpty
            ? "Recorded \(samples.count) samples — but NOTHING moved."
            : "Recorded \(String(format: "%.1f", trace.duration))s — moved: \(movedNames.joined(separator: ", "))"

        // 🔑 If the joints are flat, say WHICH kind of flat. Three causes, one appearance:
        let jointsMoved = (0..<XArmLink.jointCount).contains { trace.moved($0) }
        if includeArm, !jointsMoved {
            if !armConnected {
                line += " · joints NOT RECORDED — the arm was not connected"
            } else if armSimulated {
                line += " · joints flat — SIMULATED arm cannot follow a real program"
            } else if armReads > 0, armFailed == armReads {
                line += " · joints NOT RECORDED — every read failed (arm busy or link dropped)"
            } else if armReads > 0 {
                line += " · joints read \(armReads)× fine and genuinely did not move"
            }
        }
        note = line
        GlamaticLink.plog("rig trace “\(name)”: \(samples.count) samples, moved \(movedNames), arm reads \(armReads) failed \(armFailed) connected \(armConnected) sim \(armSimulated)")
    }

    func delete(_ t: RigTrace) {
        traces.removeAll { $0.id == t.id }
        persist()
    }

    private func persist() {
        guard let d = try? JSONEncoder().encode(traces) else { return }
        UserDefaults.standard.set(d, forKey: Self.key)
    }
}

// MARK: - Turning a recording into something editable

extension RigTrace {
    /// Reduce a dense recording to the points that describe its shape.
    ///
    /// 🔑 **A 20-second recording at 4 Hz is 80 samples per channel — 480 draggable dots.** That is
    /// not a timeline anybody can edit; it is a scatter plot. The points worth keeping are the ones
    /// where a channel CHANGES DIRECTION, plus the ends: those define the move, and everything
    /// between them is the machine travelling in a straight line from one to the next.
    ///
    /// Uses a deadband so sensor jitter around a stationary value does not register as a hundred
    /// tiny reversals.
    func keyTimes(_ channel: Int, deadband: Double = 2.0) -> [Double] {
        let pts = track(channel)
        guard pts.count > 2 else { return pts.map(\.t) }

        // 🔑 **Three kinds of moment define a move: it reverses, it STOPS, and it STARTS again.**
        // The first version kept only reversals, so a 6-second hold at the far end collapsed into a
        // single peak — and the hold is the beat a ramp punches on, the one thing you most want to
        // be able to drag. Now a plateau keeps both its ends.
        var times: [Double] = [pts[0].t]
        var direction = 0              // -1 falling, +1 rising, 0 still
        var stillSince: Double?        // when the current pause began, if in one
        let minHold = 0.6              // shorter than this is the machine settling, not a hold

        for i in 1..<pts.count {
            let dv = pts[i].v - pts[i - 1].v
            let moving = abs(dv) > deadband * 0.5
            let dir = moving ? (dv > 0 ? 1 : -1) : 0

            if !moving {
                if stillSince == nil { stillSince = pts[i - 1].t }
                continue
            }

            // Resuming after a real hold: keep both ends of it.
            if let s = stillSince {
                if pts[i - 1].t - s >= minHold {
                    if times.last.map({ abs($0 - s) > 0.15 }) ?? true { times.append(s) }
                    times.append(pts[i - 1].t)
                }
                stillSince = nil
            }

            // A genuine reversal mid-motion.
            if direction != 0, dir != direction {
                times.append(pts[i - 1].t)
            }
            direction = dir
        }

        // A hold that runs to the end still has a start worth keeping.
        if let s = stillSince, (pts.last?.t ?? 0) - s >= minHold,
           times.last.map({ abs($0 - s) > 0.15 }) ?? true {
            times.append(s)
        }
        if let last = pts.last?.t, times.last.map({ abs($0 - last) > 0.15 }) ?? true {
            times.append(last)
        }
        return times.sorted()
    }

    /// Every channel's turnarounds merged onto one shared set of times, so a pose captures the whole
    /// rig at each moment that mattered to any part of it.
    func keyframeTimes(deadband: Double = 2.0) -> [Double] {
        var all: Set<Double> = []
        if hasRail { all.formUnion(keyTimes(-1, deadband: deadband)) }
        for j in 0..<XArmLink.jointCount where moved(j) {
            all.formUnion(keyTimes(j, deadband: deadband))
        }
        if all.isEmpty { all = [0, duration] }
        // Merge times within 150ms — two channels turning "at the same moment" should be one pose.
        let sorted = all.sorted()
        var merged: [Double] = []
        for t in sorted where merged.last.map({ t - $0 > 0.15 }) ?? true {
            merged.append(t)
        }
        return merged
    }

    /// Rebuild the recording as an editable movement.
    ///
    /// Speeds come from what the rig actually did between keyframes — the largest joint sweep
    /// divided by the time it took — clamped to what the arm will accept.
    func asMotion(named name: String, includeRail: Bool) -> ArmMotion {
        let times = keyframeTimes()
        var poses: [ArmPose] = []

        for i in 1..<max(1, times.count) {
            let t = times[i]
            let dt = max(0.05, t - times[i - 1])
            let joints = (0..<XArmLink.jointCount).map { value($0, at: t) }
            let prev = (0..<XArmLink.jointCount).map { value($0, at: times[i - 1]) }
            let sweep = zip(joints, prev).map { abs($0 - $1) }.max() ?? 0
            let speed = min(60, max(5, sweep / dt))
            poses.append(ArmPose(joints: joints,
                                 speed: speed,
                                 dwell: 0,
                                 rail: includeRail && hasRail ? value(-1, at: t) : nil))
        }
        if poses.isEmpty {
            poses = [ArmPose(joints: Array(repeating: 0, count: XArmLink.jointCount),
                             speed: 20, dwell: 0, rail: nil)]
        }
        return ArmMotion(name: name, poses: poses)
    }
}
