import Foundation

/// A camera move described the way a person describes one.
///
/// 🔑 **WHY THIS EXISTS: the waypoint editor was correct and unusable.** `CustomMotion` is a list
/// of waypoints, each with a position, a velocity and a dwell — which is exactly what the rail
/// needs and exactly not how anybody thinks about a shot. The operator's sentence is *"go from one
/// end to the other and come back, fairly slowly, with a beat at the far end."* Turning that into
/// four waypoint records with per-leg velocities is a translation job, and asking someone to do it
/// in their head while a queue waits is how an editor ends up unused.
///
/// So this is the sentence, as five fields. It covers the shapes a camera rail actually does:
/// a one-way travel, an out-and-back, and either of those with a pause at the far end. Anything
/// more elaborate — three legs, different speeds per leg — still exists and is still editable, but
/// in the advanced waypoint list rather than here.
///
/// ⚠️ **It is a LOSSY view, and it says so.** `from(_:)` returns nil for any motion it cannot
/// represent faithfully, rather than flattening a three-leg move into two and quietly discarding
/// the third. A simple editor that silently destroys detail is worse than no simple editor.
struct SimpleMove: Equatable {
    /// Where the carriage starts.
    var start: Double
    /// The far end of the travel.
    var end: Double
    /// Return to `start` afterwards.
    var comeBack: Bool
    /// One speed for the whole move, in mm/s.
    var speed: Double
    /// Hold at the far end before coming back. Only meaningful when `comeBack` is true, but kept
    /// either way so toggling Come back does not silently throw the value away.
    var pause: Double

    static let `default` = SimpleMove(start: 0, end: 600, comeBack: true, speed: 85, pause: 0.25)

    /// How long this takes on the rail.
    var duration: Double {
        let leg = abs(end - start) / max(1, speed)
        return comeBack ? leg * 2 + pause : leg
    }

    /// One sentence describing the move, for the screen.
    var sentence: String {
        let travel = Int(abs(end - start))
        let shape = comeBack ? "there and back" : "one way"
        let beat = comeBack && pause > 0.01
            ? String(format: ", pausing %.2fs at the far end", pause)
            : ""
        return "\(travel) mm \(shape) at \(Int(speed)) mm/s\(beat) — \(String(format: "%.1f", duration))s"
    }

    /// A compact form for places with a fixed width, like a menu row.
    ///
    /// 🔑 **`sentence` is written to be read aloud; this one is written to FIT.** In the template
    /// menu the full sentence truncated — "…pausing 0.60s at the far en…" — which cut off both the
    /// hold and the duration, the two things that distinguish one template from another. Symbols
    /// instead of words, and the numbers that matter kept.
    var shortLabel: String {
        let travel = Int(abs(end - start))
        let arrow = comeBack ? "↔" : "→"
        let hold = comeBack && pause > 0.01
            ? String(format: " · hold %.2gs", pause)
            : ""
        return String(format: "%d mm %@ %d mm/s%@ · %.1fs",
                      travel, arrow, Int(speed), hold, duration)
    }

    // MARK: Bridging

    func asMotion(named name: String) -> CustomMotion {
        var points = [MotionWaypoint(position: end, velocity: speed, dwell: comeBack ? pause : 0)]
        if comeBack { points.append(MotionWaypoint(position: start, velocity: speed, dwell: 0)) }
        return CustomMotion(name: name, waypoints: points)
    }

    /// Read a motion back as a simple move, or nil when it is too detailed to represent.
    ///
    /// ⚠️ Returning nil is the important behaviour. The alternative — approximating — means opening
    /// a carefully tuned three-leg move in the simple editor and having it silently become a
    /// two-leg one the moment anything is touched.
    static func from(_ motion: CustomMotion, startingAt origin: Double) -> SimpleMove? {
        let w = motion.waypoints
        guard (1...2).contains(w.count) else { return nil }

        // Every leg must share one speed, or "Speed" here would be a lie about half the move.
        let speeds = w.map(\.clampedVelocity)
        guard let first = speeds.first,
              speeds.allSatisfy({ abs($0 - first) < 0.6 }) else { return nil }

        if w.count == 1 {
            guard w[0].dwell < 0.01 else { return nil }
            return SimpleMove(start: origin, end: w[0].clampedPosition,
                              comeBack: false, speed: first, pause: 0)
        }

        // Two waypoints only count as "there and back" if the second really returns to the start.
        guard abs(w[1].clampedPosition - origin) < 2, w[1].dwell < 0.01 else { return nil }
        return SimpleMove(start: origin, end: w[0].clampedPosition,
                          comeBack: true, speed: first, pause: w[0].dwell)
    }
}

extension SimpleMove {
    /// Starting shapes for a new movement.
    ///
    /// 🔑 **The builder could only ever COPY.** Every route into the editor began "take program N
    /// and change it", which is fine when a stock move is nearly right and useless when it is not —
    /// and it quietly taught that the 37 recorded programs are the only vocabulary available. They
    /// are not: the app drives its own moves through Position/Velocety/Execute and can make shapes
    /// the PLC was never programmed with.
    ///
    /// These are the shapes a camera rail is actually asked for, named for what they DO on screen
    /// rather than for their geometry. Each is a real starting point, not a placeholder — every one
    /// runs as-is.
    ///
    /// ⚠️ **Speeds updated 2026-09-10 when the ceiling was measured at 143 mm/s, not 100.** These
    /// were written against the documented figure, and the comment here said a fast whip "held to
    /// 100 mm/s is not a whip" — which was true and is now fixable. 143 is the speed the factory's
    /// own program 14 runs at, so it is proven on this mechanism rather than merely accepted by the
    /// controller.
    static let templates: [(name: String, detail: String, move: SimpleMove)] = [
        ("Full sweep",
         "End to end and back — the standard booth move",
         SimpleMove(start: 0, end: 600, comeBack: true, speed: 100, pause: 0)),

        ("Fast whip",
         "Full travel at the rail's top speed — 143 mm/s",
         SimpleMove(start: 0, end: 600, comeBack: true, speed: 143, pause: 0)),

        ("Slow reveal",
         "One way, as slow as the rail goes",
         SimpleMove(start: 0, end: 600, comeBack: false, speed: 70, pause: 0)),

        ("Out and hold",
         "Travel out fast, hold a beat, come back",
         SimpleMove(start: 0, end: 600, comeBack: true, speed: 143, pause: 0.6)),

        ("Half sweep",
         "Shorter travel — fits a tighter clip",
         SimpleMove(start: 0, end: 300, comeBack: true, speed: 100, pause: 0)),

        ("Centre push",
         "Starts mid-rail, pushes to the far end",
         SimpleMove(start: 300, end: 600, comeBack: true, speed: 85, pause: 0.25)),
    ]
}
