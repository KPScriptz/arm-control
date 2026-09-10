import Foundation

/// A stand-in for the Glamatic rail, so the whole booth loop can be rehearsed without hardware.
///
/// 🔑 **It models the machine's REAL limits, not convenient ones.** Velocity stays inside the PLC's
/// 70–100 mm/s clamp and travel inside 0–600 mm, so a full-throw out-and-back takes the ~12–17s it
/// genuinely takes. A simulator tuned to make the preset timings look right would be worse than no
/// simulator at all — it would hide exactly the mismatch you want to find indoors.
///
/// It also refuses commands for the same reasons the PLC does: not homed, not armed, faulted.
@MainActor
final class RailSimulator: ObservableObject {

    enum Leg { case idle, out, back }

    // Live state, mirroring the tags the real PLC reports.
    private(set) var position: Double = 0
    private(set) var homed = false
    private(set) var fault = false
    private(set) var programNum = 0

    // Write-only gate, mirroring Manual/Enable.
    var manual = false
    var enable = false

    /// How far a stored program throws the carriage. The real programs live in the PLC and could be
    /// anything; this is the knob that lets you match one.
    @Published var throwMM: Double = 600

    /// Speed the simulated programs run at, inside the PLC's own clamp.
    @Published var programVelocity: Double = 85

    private var leg: Leg = .idle
    private var target: Double = 0
    private var velocity: Double = 85
    private var homingRemaining: Double = 0

    // MARK: Link faults
    //
    // 🔑 The rail's MECHANICS are not what killed the old client — the S7-1200's WEB SERVER was.
    // So the simulator has to be able to fail the way the link fails, not just the way the machine
    // fails. Without this, the silent-read counter, the session-expiry branch and the whole
    // auto-reconnect path are code that has never once been executed.
    //
    // Both are off by default and live in Engineer settings next to the soak test.

    private static let dropKey = "armcontrol.sim.dropRate"
    private static let expireKey = "armcontrol.sim.expireAfter"

    /// Chance that one telemetry read gets no reply at all (0…1). Three in a row drop the link.
    @Published var dropRate: Double = UserDefaults.standard.double(forKey: dropKey) {
        didSet { UserDefaults.standard.set(dropRate, forKey: Self.dropKey) }
    }

    /// How many seconds a web session survives before the PLC starts returning the login page
    /// instead of JSON. 0 = never expires. This is the failure that looks like nothing is wrong:
    /// the socket stays up and every read quietly stops meaning anything.
    @Published var expireAfter: Double = UserDefaults.standard.double(forKey: expireKey) {
        didSet { UserDefaults.standard.set(expireAfter, forKey: Self.expireKey) }
    }

    /// Injection persists across a relaunch — a three-hour soak that lost its fault settings when
    /// iOS restarted the app would prove nothing — but it is wiped whenever simulation is switched
    /// off, so it can never be lying in wait for the next person who turns the simulator on.
    func clearInjectedFaults() {
        dropRate = 0
        expireAfter = 0
    }

    private var sessionAge: Double = 0

    enum ReadOutcome { case ok, silent, expired }

    /// What the next telemetry read should do. Called by the link layer in place of a real request.
    func rollRead() -> ReadOutcome {
        if expireAfter > 0, sessionAge >= expireAfter { return .expired }
        if dropRate > 0, Double.random(in: 0..<1) < dropRate { return .silent }
        return .ok
    }

    /// A fresh session starts the expiry clock again.
    func noteReconnected() { sessionAge = 0 }

    var injectsLinkFaults: Bool { dropRate > 0 || expireAfter > 0 }

    /// How long a full out-and-back takes at the current settings. Surfaced in the UI because it is
    /// usually the surprise: at the PLC's top speed a 600 mm round trip is still 12 seconds.
    var roundTripSeconds: Double {
        programVelocity > 0 ? (throwMM * 2) / programVelocity : 0
    }

    var isMoving: Bool { leg != .idle || abs(position - target) > 0.5 || homingRemaining > 0 }

    // MARK: Commands

    /// Programs 1–9 run an out-and-back. Program 0 is Home / stand still, as on the real console.
    func runProgram(_ n: Int) -> Bool {
        guard !fault, homed, manual, enable else { return false }
        programNum = n
        if n == 0 {
            leg = .idle
            target = position
            return true
        }
        velocity = programVelocity
        leg = .out
        target = min(600, throwMM)
        return true
    }

    func moveTo(_ p: Double, velocity v: Double) -> Bool {
        guard !fault, homed, manual, enable else { return false }
        leg = .idle
        target = min(600, max(0, p))
        // ⚠️ **Derived, never duplicated.** This was hardcoded `min(100, max(70, v))`, which was
        // correct until the ceiling was measured at 143 on 2026-09-10 — at which point the
        // simulator silently began contradicting the machine it simulates, capping moves the real
        // rail performs. A simulator that disagrees with the hardware is worse than none: every
        // timing taken from it is wrong in a way nobody would think to check.
        velocity = min(PLC.velocityRange.upperBound, max(PLC.velocityRange.lowerBound, v))
        return true
    }

    /// Homing takes real time on the rail, and clears a latched fault when it completes — the same
    /// "not referenced" behaviour the real S7-1200 has.
    func startHoming() -> Bool {
        guard manual, enable else { return false }
        leg = .idle
        homingRemaining = 3.0
        return true
    }

    func stop() {
        leg = .idle
        target = position
    }

    /// Edge-triggered on the real PLC and ignored unless Manual+Enable are on. Clearing the flag
    /// alone does NOT make the rail usable — homing is what actually references it.
    func resetError() {
        guard manual, enable else { return }
        fault = false
    }

    /// For exercising the fault-recovery UI without an E-stop.
    func injectFault() {
        fault = true
        leg = .idle
        target = position
        homed = false
    }

    func powerCycle() {
        position = 0
        homed = false
        fault = false
        leg = .idle
        target = 0
        manual = false
        enable = false
        sessionAge = 0
    }

    // MARK: Integration

    func tick(_ dt: Double) {
        sessionAge += dt

        if homingRemaining > 0 {
            homingRemaining -= dt
            position = max(0, position - 200 * dt)
            if homingRemaining <= 0 {
                position = 0
                homed = true
                fault = false          // a successful homing clears the "not referenced" status
                homingRemaining = 0
            }
            return
        }

        guard !fault else { return }

        let delta = target - position
        if abs(delta) <= velocity * dt {
            position = target
            switch leg {
            case .out:
                leg = .back
                target = 0
            case .back:
                leg = .idle
            case .idle:
                break
            }
        } else {
            position += (delta > 0 ? 1 : -1) * velocity * dt
        }
    }
}
