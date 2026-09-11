import Combine
import Foundation
import SwiftUI

/// Everything that decides whether the rail is allowed to move, and what halts it.
///
/// Design rule, carried over from the booth watchdog and not negotiable:
/// **the kernel may HALT. It may never ARM, HOME, or RESUME.**
/// Recovering motion hardware with nobody watching is a physical safety liability, so every
/// re-energising action is an explicit human tap.
@MainActor
final class SafetyKernel: ObservableObject {
    static let shared = SafetyKernel()

    /// Why motion is refused right now. `nil` means the rail will accept a command.
    enum Blocker: Equatable {
        case notConnected
        case notHomed
        case fault(String)
        case notArmed
        case appNotActive

        var message: String {
            switch self {
            case .notConnected: return "Not connected to the slider"
            case .notHomed:     return "NOT HOMED — home before moving"
            case .fault(let c): return "FAULT \(c) — clear and re-home"
            case .notArmed:     return "Not armed — tap ARM to energise"
            case .appNotActive: return "App not in foreground"
            }
        }
    }

    @Published private(set) var armed = false
    @Published private(set) var blocker: Blocker? = .notConnected
    @Published private(set) var lastHalt: String?

    /// Raw-channel triggers do not need the web session, so a preset can still be fired while the
    /// telemetry link is down. Off by default: without telemetry there is no fault or homed
    /// readout, so the operator is flying blind. Engineer mode can turn it on deliberately.
    ///
    /// Backed by UserDefaults directly rather than @AppStorage — @AppStorage inside an
    /// ObservableObject reads and writes correctly but never fires objectWillChange, so a Toggle
    /// bound to it looks stuck.
    private static let blindKey = "armcontrol.allowBlindTrigger"
    @Published var allowBlindTrigger: Bool = UserDefaults.standard.bool(forKey: blindKey) {
        didSet { UserDefaults.standard.set(allowBlindTrigger, forKey: Self.blindKey) }
    }

    private let link = GlamaticLink.shared
    private var bag = Set<AnyCancellable>()

    private init() {
        // Recompute the blocker whenever anything it depends on changes. The hop through Task
        // keeps the call site explicitly on the main actor rather than relying on the scheduler.
        link.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in self?.recompute() }
            }
            .store(in: &bag)
        recompute()
    }

    private func recompute() {
        let s = link.state
        if !link.connected            { blocker = .notConnected }
        else if s.hasFault            { blocker = .fault(s.statusError != "0" ? "E\(s.statusError)" : "R\(s.robotError)") }
        else if !s.isHomed            { blocker = .notHomed }
        else if !armed                { blocker = .notArmed }
        else                          { blocker = nil }
    }

    /// True when a stored program may be fired.
    var canTriggerProgram: Bool {
        if allowBlindTrigger { return armed }
        return blocker == nil
    }

    /// True when a manual position/velocity move may be sent.
    var canDrive: Bool { blocker == nil }

    // MARK: Arm / disarm

    /// Energise the drive gate. FACT: the PLC needs Manual=1 AND Enable=1 before it executes a
    /// move. This is ALWAYS an explicit operator action — never on launch, never on reconnect.
    /// Arming energises the servos; it moves nothing on its own.
    @discardableResult
    func arm() async -> Bool {
        guard link.connected else { return false }
        guard await link.setManual(true), await link.setEnable(true) else {
            GlamaticLink.plog("ARM failed — gate writes rejected")
            return false
        }
        armed = true
        lastHalt = nil
        GlamaticLink.plog("ARMED")
        IncidentLog.shared.record(.safety, "Armed")
        recompute()
        return true
    }

    /// Arm and home automatically — **simulation only**.
    ///
    /// The rule that arming is always a deliberate human act exists to stop real servos being
    /// energised with nobody watching. A simulated rail has no servos, and making rehearsal walk
    /// the whole arm/home ritual first just means it does not get rehearsed. Guarded on
    /// `simulated` so it can never touch real hardware.
    func prepareSimulatedRail() async {
        guard link.simulated, !link.state.isHomed || !armed else { return }
        guard await arm() else { return }
        _ = await link.home()
        _ = await link.waitHomed(timeout: 10)
        GlamaticLink.plog("simulated rail auto-armed and homed for rehearsal")
    }

    /// Drop the drive gate. Safe to call at any time, including when already disarmed.
    func disarm(reason: String) async {
        armed = false
        lastHalt = reason
        GlamaticLink.plog("DISARM (\(reason))")
        IncidentLog.shared.record(.safety, "Disarmed — \(reason)",
                                  bad: reason.lowercased().contains("stop"))
        if link.connected {
            _ = await link.setEnable(false)
            // ⚠️ Disarm must return the PLC to AUTOMATIC too. Dropping Enable alone leaves it in
            // manual mode with a position setpoint loaded — a state the UI calls "disarmed" and
            // the machine does not agree with.
            _ = await link.setManual(false)
        }
        recompute()
    }

    /// Operator STOP. Fires the session-free stop path first, then drops the gate.
    ///
    /// 🔑 **It must also cancel playback, on BOTH machines.** Dropping Enable while a motion player
    /// keeps walking its waypoints leaves trigger levels standing on the rail and a move queued on
    /// the arm — the state that detonates on the next energise. Stopping the gate without stopping
    /// the thing issuing commands is not a stop.
    func emergencyStop() async {
        _ = await link.stop()
        MotionStore.shared.stop()
        ArmMotionStore.shared.stop()
        await XArmLink.shared.eStop()
        await disarm(reason: "Operator STOP")
    }

    // MARK: Lifecycle halt
    //
    // The single most important safety rule on iPad: if this app is not on screen, nothing is
    // watching the rail. Backgrounding, screen lock, an incoming call, a swipe to another app —
    // all of them mean drop the gate now.

    func handleScenePhase(_ phase: ScenePhase) {
        guard phase != .active else { return }
        // ⚠️ The arm is checked separately from `armed`, which tracks the RAIL's gate only. An
        // enabled arm with a movement running is the more dangerous of the two to leave unattended,
        // and it would have sailed straight past a single `guard armed`.
        let armLive = XArmLink.shared.motionEnabled || ArmMotionStore.shared.isPlaying
        let armLinked = XArmLink.shared.connected && !XArmLink.shared.simulated
        guard armed || armLive || armLinked else { return }
        Task {
            MotionStore.shared.stop()
            ArmMotionStore.shared.stop()
            if armLive { await XArmLink.shared.disable() }
            // 🔑 **Let go of the arm's control slot, cleanly.** The xArm allows ONE control-port
            // client and holds a dead session for 30–60s. An app that backgrounds or is killed
            // without closing leaves its ghost in that slot, and the next launch connects as a
            // SECOND client — whose commands are acknowledged and silently ignored. That is
            // "accepted, queue 0, no motion". Close the socket on the way out so the slot is free.
            if armLinked { XArmLink.shared.disconnect() }
            if armed { await disarm(reason: "App left the foreground") }
        }
    }
}
