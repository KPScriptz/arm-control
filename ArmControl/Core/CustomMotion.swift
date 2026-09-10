import Foundation

/// A named move the **app** drives, rather than one stored inside the PLC.
///
/// 🔑 **Why this exists, and why it is not a stored program.** The eight programs live in the
/// controller; the app can select and trigger them but cannot read, edit or author one. That is
/// fine until you want a move shaped to a specific reference — and it is a hard stop when the
/// stored-program trigger is the thing that will not fire. This walks the carriage through
/// waypoints using `Position` + `Velocety` + `Execute`, which is the manufacturer's own manual
/// drive path (their `AWP_In_Variable` list declares all three, and their web page's Execute
/// button posts exactly this sequence).
///
/// ⚠️ **The velocity clamp still applies: 70–100 mm/s, a 1.43:1 range.** Nothing here escapes it,
/// and nothing here is trying to — the cinematic speed range is bought in post by
/// `RampProfile`, not on the rail. What a custom motion controls is **where the carriage is and
/// when**, so the ramp has the right footage to sample. Matching a reference means matching the
/// *duration and shape* of the travel, then letting the profile do the speed.
struct MotionWaypoint: Codable, Equatable, Identifiable {
    var id = UUID()
    /// Absolute target in mm, clamped to the machine's 0–600.
    var position: Double
    /// mm/s, clamped to the machine's 70–143 (measured 2026-09-10; the documented 100 was wrong).
    var velocity: Double
    /// Seconds to hold once it arrives. A beat at the turnaround is what gives the ramp a
    /// distinct moment to punch on.
    var dwell: Double = 0

    var clampedPosition: Double {
        min(PLC.positionRange.upperBound, max(PLC.positionRange.lowerBound, position))
    }
    var clampedVelocity: Double {
        min(PLC.velocityRange.upperBound, max(PLC.velocityRange.lowerBound, velocity))
    }
}

struct CustomMotion: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var waypoints: [MotionWaypoint]

    /// How long this takes from a given starting position — the number that has to match the
    /// take's Traverse, and the one the ramp profile is authored against.
    func duration(from start: Double) -> Double {
        var here = start
        var total = 0.0
        for w in waypoints {
            let target = w.clampedPosition
            total += abs(target - here) / w.clampedVelocity + w.dwell
            here = target
        }
        return total
    }

    var throwRange: (min: Double, max: Double) {
        let ps = waypoints.map(\.clampedPosition)
        return (ps.min() ?? 0, ps.max() ?? 0)
    }

    // MARK: The reference

    /// **Whalefall** — shaped to the premiere reference clip.
    ///
    /// A full 600 mm out-and-back at 85 mm/s is **14.1 s**, which is both what `MoveTimer`
    /// measured for the PLC's own Program 1 (587 mm in 14.1 s) and exactly the length
    /// `RampProfile.whalefallPremiere` is authored against. So the out-leg, the turnaround and
    /// the back-leg land under the passes that expect them.
    ///
    /// The 0.25 s dwell at the far end is deliberate: it is the beat the triple-flash staccato
    /// sits on. Without it the turnaround is a single frame and the two short beats either side
    /// of it sample a carriage that is still accelerating.
    static let whalefall = CustomMotion(
        name: "Whalefall",
        waypoints: [
            MotionWaypoint(position: 600, velocity: 85, dwell: 0.25),
            MotionWaypoint(position: 0, velocity: 85, dwell: 0),
        ])
}

/// The saved motions, and the player that walks one.
@MainActor
final class MotionStore: ObservableObject {
    static let shared = MotionStore()

    private static let key = "armcontrol.motions.v1"
    private static let seededKey = "armcontrol.motions.seeded"

    @Published private(set) var motions: [CustomMotion] = []

    /// Which motion is running, and how far through. Nil when idle.
    @Published private(set) var playing: CustomMotion?
    @Published private(set) var step = 0
    @Published private(set) var progressNote = ""

    private var task: Task<Void, Never>?
    /// Set by `stop()`, checked by the playback loop.
    ///
    /// 🔑 **Why a flag and not just task cancellation.** Three call sites `await play(...)` for its
    /// Bool (the take runner, the Studio, the console) inside tasks this store never sees, so
    /// `Task.isCancelled` is only ever true for the one path that goes through `start(_:)`. A flag
    /// the loop checks works no matter who called it — and "STOP only works if you started it the
    /// right way" is not a property a stop button may have.
    private var cancelRequested = false
    private let link = GlamaticLink.shared

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([CustomMotion].self, from: data) {
            motions = decoded
        }
        // Seeded once, and only once — so a Whalefall the operator edited or deleted stays that
        // way instead of reappearing on every launch.
        if !UserDefaults.standard.bool(forKey: Self.seededKey) {
            motions.append(.whalefall)
            UserDefaults.standard.set(true, forKey: Self.seededKey)
            persist()
        }
    }

    func save(_ motion: CustomMotion) {
        if let i = motions.firstIndex(where: { $0.id == motion.id }) { motions[i] = motion }
        else { motions.append(motion) }
        persist()
    }

    func delete(_ motion: CustomMotion) {
        motions.removeAll { $0.id == motion.id }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(motions) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    // MARK: Playing

    var isPlaying: Bool { playing != nil }

    /// Walk the waypoints. Returns true only if every one of them was reached.
    ///
    /// ⚠️ THE RAIL MOVES. Callers gate this behind the same arm/home checks a preset uses; it does
    /// not arm anything itself, because arming is always a human tap.
    @discardableResult
    func play(_ motion: CustomMotion) async -> Bool {
        guard !isPlaying else { return false }
        guard link.connected else { progressNote = "Not connected."; return false }

        playing = motion
        step = 0
        cancelRequested = false
        defer { playing = nil; step = 0 }

        GlamaticLink.plog("motion “\(motion.name)”: \(motion.waypoints.count) waypoints")
        // One conversation with the PLC at a time — the arrival poll below IS the telemetry for
        // the duration, so the background poll would only be a second concurrent socket.
        link.suspendPolling()
        defer { link.resumePolling() }

        for (i, w) in motion.waypoints.enumerated() {
            guard !Task.isCancelled, !cancelRequested else {
                progressNote = "Stopped."
                GlamaticLink.plog("motion “\(motion.name)” stopped by operator")
                return false
            }
            step = i + 1
            let target = w.clampedPosition
            progressNote = String(format: "Leg %d of %d — %.0f mm at %.0f mm/s",
                                  i + 1, motion.waypoints.count, target, w.clampedVelocity)

            guard await link.move(to: target, velocity: w.clampedVelocity) else {
                progressNote = "The PLC refused the move."
                GlamaticLink.plog("motion aborted: move to \(Int(target)) refused")
                return false
            }
            guard await waitForArrival(at: target, velocity: w.clampedVelocity) else {
                progressNote = String(format: "Never reached %.0f mm.", target)
                GlamaticLink.plog("motion aborted: never arrived at \(Int(target))")
                return false
            }
            if w.dwell > 0 {
                progressNote = String(format: "Holding %.2fs", w.dwell)
                try? await Task.sleep(nanoseconds: UInt64(w.dwell * 1_000_000_000))
            }
        }

        progressNote = "Done."
        GlamaticLink.plog("motion “\(motion.name)” complete")
        return true
    }

    /// Poll `CurrentPosition` until the carriage is there.
    ///
    /// 🔑 The PLC gives no "move finished" signal, so arrival is something to observe rather than
    /// wait for. The timeout is derived from the distance and the commanded speed plus slack, so a
    /// long leg is not cut off and a stalled short one does not hang the take.
    private func waitForArrival(at target: Double, velocity: Double) async -> Bool {
        let start = Double(link.state.currentPosition) ?? 0
        let expected = abs(target - start) / max(1, velocity)
        let deadline = Date().addingTimeInterval(expected + 5)
        var furthest = start
        while Date() < deadline {
            // A leg can be 14s long, so the stop has to land mid-leg rather than at the next
            // waypoint boundary.
            guard !Task.isCancelled, !cancelRequested else { return false }
            try? await Task.sleep(nanoseconds: 250_000_000)
            await link.refresh()
            let now = Double(link.state.currentPosition) ?? 0
            furthest = abs(now - start) > abs(furthest - start) ? now : furthest
            // 🔑 **±5 mm, not ±3.** The recorded traces show this machine finishing a 600 mm
            // command at 597 and a 590 mm one at 595 — it stops a few millimetres short and stays
            // there. At ±3 a perfectly good move is judged "never arrived", the motion aborts, and
            // the booth reports a failed take on a shot that actually happened.
            if abs(now - target) <= 5 { return true }
            if link.state.hasFault {
                GlamaticLink.plog("motion aborted: PLC faulted mid-leg")
                return false
            }
        }
        // ⚠️ Say WHERE it got to. "Never arrived" alone cannot distinguish a rail that never moved
        // from one that stopped short, and those have completely different causes — a distinction
        // that cost several runs today.
        GlamaticLink.plog(String(format: "arrival FAILED: target %.0f, started %.0f, furthest %.0f, now %.0f",
                                 target, start, furthest, Double(link.state.currentPosition) ?? 0))
        return false
    }

    /// Start a motion and OWN the task, so it can be stopped.
    ///
    /// 🐞 **FIXED 2026-09-10, and it was a live safety hole.** `task` was declared here and never
    /// once assigned: `play` is an `async` func, and every caller wrote `Task { await store.play(m) }`
    /// without keeping the handle. So `stop()` cancelled nothing, and the `Task.isCancelled` guards
    /// inside `play` could never fire. STOP dropped Enable while the waypoint loop carried on
    /// writing Position/Execute — which is exactly the standing-request state that detonates the
    /// next time anything energises the drive. Callers should use this, not a bare `Task {}`.
    func start(_ motion: CustomMotion) {
        guard !isPlaying else { return }
        task = Task { [weak self] in
            await self?.play(motion)
            await MainActor.run { self?.task = nil }
        }
    }

    /// Cancel playback and bring the rail to rest.
    ///
    /// Cancelling alone is not enough — the loop may be parked in an `await` on a move that is
    /// still executing, and the trigger levels have to be cleared rather than left standing.
    func stop() {
        cancelRequested = true
        task?.cancel()
        task = nil
        Task {
            if link.connected { _ = await link.stop() }
            progressNote = "Stopped."
        }
    }
}

extension CustomMotion {
    /// Turn a **recorded** movement into an editable one.
    ///
    /// 🔑 **This is the only way to "edit a preset".** The eight programs are compiled logic inside
    /// the PLC and cannot be read, written or altered — established exhaustively. What can be done
    /// is to take the curve the machine was *observed* producing and rebuild it as waypoints the
    /// app drives itself, which then IS editable: trajectory, speed and dwell all become numbers.
    ///
    /// The waypoints are the places the carriage reversed, plus the start and the end, with each
    /// leg's velocity taken from how fast it actually covered that distance — clamped to the
    /// machine's 70–143 mm/s, because a driven move has to live inside that window even when the
    /// stored program did not.
    static func from(trace: MotionTrace, name: String) -> CustomMotion {
        var points: [Double] = []
        var times: [Double] = []
        // Start at the first movement, not at the trigger — the dead head is not part of the shape.
        times.append(trace.latency)
        points.append(trace.position(at: trace.latency))
        for t in trace.turnarounds {
            times.append(t)
            points.append(trace.position(at: t))
        }
        let end = trace.latency + trace.moveDuration
        times.append(end)
        points.append(trace.position(at: end))

        var waypoints: [MotionWaypoint] = []
        for i in 1..<max(1, points.count) {
            let distance = abs(points[i] - points[i - 1])
            let seconds = max(0.05, times[i] - times[i - 1])
            let speed = min(PLC.velocityRange.upperBound,
                            max(PLC.velocityRange.lowerBound, distance / seconds))
            waypoints.append(MotionWaypoint(position: points[i], velocity: speed, dwell: 0))
        }
        if waypoints.isEmpty {
            waypoints = [MotionWaypoint(position: trace.maxMM, velocity: 85, dwell: 0),
                         MotionWaypoint(position: trace.minMM, velocity: 85, dwell: 0)]
        }
        return CustomMotion(name: name, waypoints: waypoints)
    }
}
