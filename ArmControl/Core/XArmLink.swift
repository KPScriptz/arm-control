import Foundation
import Network

/// The **second machine**: the uFactory xArm 5, on Modbus TCP at 192.168.1.231:502.
///
/// 🔑 **WHY THIS FILE EXISTS.** There are two robots in this rig and ArmControl only ever knew
/// about one. The Glamatic slider carries the camera along the rail; the xArm is the jointed arm
/// that has to fold down to park. Home parked the slider perfectly and left the arm standing —
/// "slider worked but the arm didn't fold down correctly" — because nothing in this app had ever
/// spoken to it.
///
/// ⚠️ **This is a deliberately minimal port of PivotBooth's `XArmClient` (620 lines).** It does
/// exactly what Home needs — connect, enable, fold to zero, let go — and nothing else. No jogging,
/// no velocity control, no telemetry poll, no Follow Me. Those exist in PivotBooth and belong there
/// until this app has a reason for them; a half-ported motion controller is a liability, not a
/// feature. The wire format below is copied from that client rather than re-derived, because it is
/// proven against this exact arm.
///
/// **The fold-down pose is all-joints-zero.** From PivotBooth's own client:
/// `func gotoInitial() async { await moveJoints([0,0,0,0,0]) }  // xArm5 "initial" ≈ zero`
///
/// ⚠️ **THE ARM MOVES.** Every path here is reached from an explicit Home tap. Nothing connects,
/// enables or moves on launch, matching the rule the Glamatic link follows.
@MainActor
final class XArmLink: ObservableObject {
    static let shared = XArmLink()

    private init() {
        simulated = UserDefaults.standard.bool(forKey: Self.simulatedKey)
        // didSet does not fire during init, so the loop is started explicitly.
        if simulated { startSimLoop() }
    }

    static let host = "192.168.1.231"
    static let port: UInt16 = 502

    /// Modbus function codes. Same numbering as PivotBooth's `FC`.
    private enum FC {
        static let motionEnable: UInt8 = 11
        static let setState:     UInt8 = 12
        static let getState:     UInt8 = 13
        static let getError:     UInt8 = 15
        static let cleanErr:     UInt8 = 16
        static let cleanWar:     UInt8 = 17
        static let setMode:      UInt8 = 19
        static let moveJoint:    UInt8 = 23
        static let getJointPos:  UInt8 = 42
    }

    /// How many joints this arm has. An xArm **5** — J1…J5.
    static let jointCount = 5

    @Published private(set) var status = "Not connected"
    @Published private(set) var connected = false
    /// Joint angles in degrees, when last read. Empty until a fold or a poll runs.
    @Published private(set) var joints: [Double] = []
    /// 1 = moving, 2 = ready, 3 = paused, 4 = stopped. Same numbering the arm reports.
    @Published private(set) var armState = 0
    /// The arm's own error code. 0 = none.
    @Published private(set) var errorCode = 0
    /// Whether the servos are energised. **Only ever set true by an explicit human tap.**
    @Published private(set) var motionEnabled = false
    /// Degrees per second for authored moves and jogs. 20 is PivotBooth's proven default.
    @Published var jointSpeed: Double = 20

    /// True while an E-stop is being asserted, so a jog's async teardown cannot land its
    /// "ready" after the stop and silently re-ready the arm. Lifted from PivotBooth, where
    /// that exact race was found.
    private var eStopActive = false
    private var pollTask: Task<Void, Never>?

    // MARK: - One motion sequence at a time
    //
    // 🐞 **THE ARM SHIPPED WITHOUT THE LOCK THE RAIL ALREADY HAD, AND IT GLITCHED FOR THE SAME
    // REASON.** `GlamaticLink.withMotionLock` exists because on 2026-09-08 an operator tapping Home
    // three times ran three ~12-write conversations at once and wedged the controller. Every lesson
    // in that note applies here and I did not carry it over: `walkToNeutral`, `backOut`, movement
    // playback and jogs could all run concurrently, each sampling the joints at a different instant
    // and commanding a different target every half second. Two loops fighting over five joints is a
    // jerking arm — and tapping a slow recovery button twice is all it takes to start the second one.
    //
    // 🔑 **A second sequence is REFUSED, not queued.** Queued motion is worse than none: it executes
    // later, against a machine that has since moved, for a reason nobody remembers giving.

    @Published private(set) var motionBusy = false
    private(set) var motionLabel = ""

    private func withArmMotion<T>(_ what: String, refused: T,
                                  _ body: () async -> T) async -> T {
        guard !motionBusy else {
            GlamaticLink.plog("xArm: REFUSED “\(what)” — “\(motionLabel)” is already running")
            status = "Already \(motionLabel.lowercased()) — wait for it to finish"
            return refused
        }
        motionBusy = true
        motionLabel = what
        defer { motionBusy = false; motionLabel = "" }
        return await body()
    }

    // MARK: Simulation
    //
    // ⚠️ OFF by default, and every screen that can move the arm says so when it is on. A simulated
    // arm mistakable for a real one is the worst bug this file could carry.

    static let simulatedKey = "armcontrol.arm.simulated"
    let sim = ArmSimulator()
    private var simTask: Task<Void, Never>?

    @Published var simulated: Bool {
        didSet {
            guard simulated != oldValue else { return }
            UserDefaults.standard.set(simulated, forKey: Self.simulatedKey)
            GlamaticLink.plog(simulated ? "SIMULATED ARM ON" : "SIMULATED ARM OFF")
            if simulated {
                startSimLoop()
            } else {
                simTask?.cancel(); simTask = nil
                sim.reset()
                connected = false
                motionEnabled = false
                joints = []
                status = "Not connected"
            }
        }
    }

    private func startSimLoop() {
        guard simTask == nil else { return }
        simTask = Task { [weak self] in
            // Integrate against the WALL CLOCK. A hardcoded dt is what made the simulated rail run
            // ~7% slow and cost a day chasing a measurement bug that was never there.
            var last = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard let self, self.simulated else { continue }
                let now = Date()
                let dt = now.timeIntervalSince(last)
                last = now
                self.sim.tick(dt)
                if self.connected { self.joints = self.sim.joints }
            }
        }
    }

    private var connection: NWConnection?
    private var tid: UInt16 = 0
    private var inflight = false

    private enum XArmError: Error { case timeout, notConnected }

    // MARK: The one thing this link is for

    /// Fold the arm down to its parked pose, then let go of it.
    ///
    /// Returns false if the arm could not be reached or refused — the caller reports that rather
    /// than claiming a park that did not happen. **A slider that parked and an arm that did not is
    /// exactly the failure this is here to stop, so it must never report success on silence.**
    ///
    /// `progress` is called with each phase so the Home button can say what it is doing; folding
    /// takes several seconds and a silent wait is what makes an operator tap twice.
    @discardableResult
    func foldDown(progress: @escaping (String) -> Void = { _ in }) async -> Bool {
        progress("Reaching the arm…")
        guard await connect() else {
            status = "Could not reach the arm at \(Self.host)"
            GlamaticLink.plog("xArm: connect FAILED — arm not folded")
            return false
        }

        progress("Enabling the arm…")
        // ⚠️ Must go through `enable()`, not the private `enableMotion()` — `moveJoints` is gated on
        // `motionEnabled`, so the raw call would energise the servos and then have every motion
        // command silently refused. A fold that reports success having never moved is the one
        // failure this whole file exists to prevent.
        guard await enable() else {
            GlamaticLink.plog("xArm: enable FAILED — arm not folded")
            disconnect()
            return false
        }

        progress("Folding the arm down…")
        GlamaticLink.plog("xArm: folding to zero")
        let sent = await moveJoints([0, 0, 0, 0, 0])
        guard sent else {
            status = "The arm refused the fold command"
            GlamaticLink.plog("xArm: moveJoint REFUSED")
            disconnect()
            return false
        }

        // Watch it arrive rather than assuming. A command the arm accepts and does not execute is
        // indistinguishable from one it obeys — the same lesson the slider taught.
        let ok = await waitFolded(progress: progress)
        GlamaticLink.plog("xArm: fold finished ok=\(ok) joints=\(joints.map { Int($0) })")
        status = ok ? "Arm folded" : "Arm did not reach the folded pose"
        disconnect()
        return ok
    }

    /// Poll joint angles until every one is near zero.
    private func waitFolded(progress: @escaping (String) -> Void) async -> Bool {
        for _ in 0..<60 {                       // up to ~30s
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let now = await readJoints() else { continue }
            joints = now
            let worst = now.map { abs($0) }.max() ?? 0
            progress(String(format: "Folding the arm — %.0f° to go", worst))
            if worst < 2.0 { return true }
        }
        return false
    }

    // MARK: Live joint control
    //
    // 🔑 **Added 2026-09-10 so movements can be AUTHORED, not just parked.** Everything above this
    // point exists to fold the arm to zero. Authoring a shot needs the opposite: put each joint
    // exactly where you want it, see where it is, and keep the pose. The wire format below is
    // ported from PivotBooth's `XArmClient`, which drives this same arm — re-deriving a motion
    // protocol against real hardware is how you find out what a hard stop sounds like.
    //
    // ⚠️ **ON JOINT LIMITS, AND WHY THERE ARE NO NUMBERS HERE.** The only limit anyone has actually
    // verified on this arm is J2's mechanical ≈ −118° (PivotBooth floors it at −95° for margin).
    // The other four are unknown, and a table of plausible-looking invented limits is worse than
    // none: it reads as authoritative and the first person to trust it drives a joint into a stop.
    // So the real limit is the CONTROLLER's. Jogs step a small delta from the MEASURED pose, the
    // arm refuses anything it cannot reach, and `autoRecoverJog` clears the soft fault that refusal
    // raises. A refused jog is a no-op you can see on screen, not a latched error.

    /// Energise the servos, clear faults, position mode, ready.
    ///
    /// ⚠️ **ALWAYS an explicit human tap.** Never called on launch, connect or reconnect — the same
    /// rule `SafetyKernel` holds for the rail, and for the same reason: this puts a real machine
    /// under power with whoever is standing next to it.
    @discardableResult
    func enable() async -> Bool {
        guard await connect() else { return false }
        eStopActive = false
        if simulated {
            sim.enable()
            motionEnabled = true
            status = "Arm live (simulated)"
            GlamaticLink.plog("xArm: ENABLED (simulated)")
            return true
        }
        guard await enableMotion() else {
            status = "The arm refused to enable"
            return false
        }
        motionEnabled = true
        status = "Arm live"
        GlamaticLink.plog("xArm: ENABLED (operator)")
        IncidentLog.shared.record(.safety, "Arm enabled")
        return true
    }

    /// Drop the servos. Safe at any time.
    func disable() async {
        motionEnabled = false
        if simulated { sim.disable() }
        else if connected { _ = await command(FC.setState, Data([4])) }
        status = connected ? "Arm idle" : status
        GlamaticLink.plog("xArm: disabled")
        IncidentLog.shared.record(.safety, "Arm disabled")
    }

    /// **Arm STOP — SET_STATE(4).** Always permitted, even with no session sanity elsewhere.
    func eStop() async {
        eStopActive = true
        motionEnabled = false
        if simulated { sim.eStop() }
        else { _ = await command(FC.setState, Data([4])) }
        GlamaticLink.plog("xArm: E-STOP")
        IncidentLog.shared.record(.safety, "Arm STOP", bad: true)
    }

    /// Gentle default acceleration for authored moves, °/s². The factory programs use 200–1146.
    static let defaultAcc: Double = 286      // = the original hardcoded 5 rad/s²

    /// Move to absolute joint angles (degrees, J1…J5).
    @discardableResult
    func moveJoints(_ degs: [Double], speed: Double? = nil, acc: Double? = nil) async -> Bool {
        guard motionEnabled, !eStopActive else { return false }
        if simulated { return sim.moveJoints(degs, speed: speed ?? jointSpeed) }
        var p = Data()
        // Seven slots regardless of the arm's joint count — the protocol expects a fixed frame.
        for i in 0..<7 { p.appendLE32(Float((i < degs.count ? degs[i] : 0) * .pi / 180)) }
        p.appendLE32(Float((speed ?? jointSpeed) * .pi / 180))            // speed rad/s
        p.appendLE32(Float((acc ?? Self.defaultAcc) * .pi / 180))         // acceleration rad/s²
        p.appendLE32(Float(0))                                            // mvtime
        return await command(FC.moveJoint, p) != nil
    }

    /// Nudge ONE joint by ±delta degrees from its measured position.
    ///
    /// 🔑 This is the primary authoring gesture, and it is relative on purpose: stepping a couple of
    /// degrees from where the joint actually is cannot leap somewhere unreachable the way typing an
    /// absolute angle can.
    @discardableResult
    func jogJoint(_ index: Int, _ deltaDeg: Double) async -> Bool {
        guard motionEnabled, !eStopActive else { return false }
        // A jog during a walk or a playback is two things steering at once. Refuse it rather than
        // interleaving commands — the arm cannot tell which target you meant.
        guard !motionBusy else {
            status = "Already \(motionLabel.lowercased()) — wait for it to finish"
            return false
        }
        var target = joints
        while target.count < Self.jointCount { target.append(0) }
        guard index < target.count else { return false }
        target[index] += deltaDeg
        let sent = await moveJoints(target)
        await autoRecoverJog()
        return sent
    }

    /// What the arm's error code means, in words. Table ported from PivotBooth's `XArmClient`,
    /// which was built against this arm — not invented here.
    var faultText: String {
        switch errorCode {
        case 0:       return ""
        case 1:       return "Emergency-stop button pressed"
        case 2:       return "Control-box emergency IO triggered"
        case 3:       return "Three-state switch e-stop"
        case 10...17: return "Servo motor error (joint \(errorCode - 9))"
        case 18:      return "Force/torque sensor comms error"
        case 19:      return "End-module comms error"
        case 21:      return "Kinematic error — target unreachable / singularity"
        case 22:      return "Self-collision detected"
        case 23:      return "Joint angle over limit — jog it back"
        case 24:      return "Speed over limit"
        case 25:      return "Planning error"
        case 28:      return "Motion command over limit"
        case 35:      return "Safety boundary limit"
        default:      return "Error \(errorCode)"
        }
    }

    /// Faults that clearing cannot fix, because the cause is still physically present.
    ///
    /// 🔑 **Telling these apart is the whole value of the recovery button.** Clearing a latched
    /// planning error works and the arm is usable again. "Clearing" a pressed E-stop appears to work
    /// for a moment and then the fault returns — so a button that reports success on those teaches
    /// you to press it repeatedly instead of walking over and releasing the button.
    var faultNeedsHardware: Bool { (1...3).contains(errorCode) || (10...19).contains(errorCode) }

    /// Bring the arm out of a latched fault and back to a usable, de-energised ready state.
    ///
    /// ⚠️ **It does NOT re-enable the servos.** `SafetyKernel`'s rule holds here: the app may halt,
    /// never resume. This clears the fault and leaves the arm cold; energising it is your next tap,
    /// made knowingly. The status line says exactly that when it succeeds.
    ///
    /// 🔑 **It verifies rather than assumes.** The error register is re-read after clearing and the
    /// result reports what is actually true — a "recovered" that was never checked is the same
    /// silent-lie shape that produced three bogus speed-test verdicts on this project.
    @discardableResult
    func recoverFromFault() async -> Bool {
        guard connected else {
            status = "Not connected to the arm"
            return false
        }
        let was = errorCode
        let wasText = faultText
        GlamaticLink.plog("xArm: recovery requested (error \(was) — \(wasText))")

        if simulated {
            sim.enable()          // clears the sim's stopped latch
            sim.disable()         // …then leaves it cold, matching the real path
            errorCode = 0
            eStopActive = false
            status = "Fault cleared (simulated) — tap Enable to energise"
            return true
        }

        _ = await command(FC.cleanWar)
        _ = await command(FC.cleanErr)
        _ = await command(FC.setMode, Data([0]))     // position mode
        _ = await command(FC.setState, Data([0]))    // ready
        eStopActive = false
        motionEnabled = false                         // cleared ≠ energised

        // Give the controller a moment, then check whether it really went away.
        try? await Task.sleep(nanoseconds: 400_000_000)
        if let e = await command(FC.getError), e.count >= 1 {
            errorCode = Int(e[0])
        }

        if errorCode == 0 {
            status = "Fault cleared — tap Enable to energise"
            GlamaticLink.plog("xArm: recovered from error \(was)")
            IncidentLog.shared.record(.safety, "Arm fault \(was) cleared")
            return true
        }

        status = faultNeedsHardware
            ? "Still faulted: \(faultText). This one needs fixing on the machine."
            : "Still faulted: \(faultText)"
        GlamaticLink.plog("xArm: recovery FAILED — still error \(errorCode)")
        IncidentLog.shared.record(.safety, "Arm fault \(errorCode) would not clear", bad: true)
        return false
    }

    // MARK: The neutral pose
    //
    // 🔑 **CLEARING A FAULT IS NOT THE SAME AS FIXING IT, and error 23 is the proof.** "Joint angle
    // over limit" latches because a joint IS over its limit; clear it and the joint is still there,
    // so the very next move faults again. The arm's own error text says the remedy out loud —
    // *"jog it back"*. Recovery therefore has to TRAVEL, not just acknowledge.
    //
    // Neutral defaults to all-joints-zero, which is the pose PivotBooth's client calls the xArm 5's
    // "initial" and uses to park it — a configuration proven safe on this machine rather than a
    // number chosen here. It is settable, because the pose that is safe on a booth with a camera and
    // a rail in the way is a question about the rig, not about the arm.

    static let neutralKey = "armcontrol.arm.neutralPose"

    var neutralPose: [Double] {
        get {
            let stored = (UserDefaults.standard.array(forKey: Self.neutralKey) as? [Double]) ?? []
            guard stored.count == Self.jointCount else {
                return Array(repeating: 0, count: Self.jointCount)
            }
            return stored
        }
        set {
            UserDefaults.standard.set(Array(newValue.prefix(Self.jointCount)), forKey: Self.neutralKey)
            objectWillChange.send()
        }
    }

    var neutralLabel: String {
        neutralPose.enumerated().map { "J\($0.offset + 1) \(Int($0.element))°" }.joined(separator: " · ")
    }

    /// Clear the fault **and drive the arm back to neutral**, so it is genuinely usable again.
    ///
    /// ⚠️⚠️ **THE ARM MOVES, AND IT MAY SWEEP A LONG WAY.** From an over-limit joint the path to
    /// neutral can be most of the arm's range, through whatever is in front of it — a camera, the
    /// rail, a person. Callers MUST confirm with the operator first, and the speed here is
    /// deliberately slow rather than the working speed.
    ///
    /// Refuses outright on faults with a physical cause: a pressed e-stop or a servo error is not
    /// something a move can fix, and attempting one just fails in a more confusing way.
    @discardableResult
    func recoverAndGoNeutral() async -> Bool {
        await withArmMotion("Freeing the arm", refused: false) { await recoverAndGoNeutralCore() }
    }

    private func recoverAndGoNeutralCore() async -> Bool {
        guard connected else {
            status = "Not connected to the arm"
            return false
        }
        if faultNeedsHardware {
            status = "\(faultText) — fix this on the machine first."
            GlamaticLink.plog("xArm: neutral refused, physical fault \(errorCode)")
            return false
        }

        GlamaticLink.plog("xArm: recover-to-neutral from error \(errorCode)")
        guard await recoverFromFault() else { return false }

        // Recovery leaves the arm cold by design; moving needs it live, and the operator asked for
        // exactly that by tapping this button.
        guard await enable() else {
            status = "Fault cleared, but the arm would not enable"
            return false
        }

        let ok = await walkToNeutralCore()      // already inside the lock
        IncidentLog.shared.record(.safety,
                                  ok ? "Arm freed and returned to neutral" : "Arm did not reach neutral",
                                  bad: !ok)
        return ok
    }

    /// Walk the arm to neutral in SMALL STEPS, clearing soft faults as it goes.
    ///
    /// 🐞 **THE BUG THIS REPLACES: one big commanded pose move.** From an over-limit joint or a
    /// singular configuration the planner REFUSES a full move outright — it will not plan a path
    /// from a state it considers invalid. So "clear and move to neutral" cleared the fault, sent one
    /// move, got refused, and left the arm exactly where it was. That is precisely "it won't free
    /// itself". The arm's own error text says the remedy — *"jog it back"* — and a jog is
    /// incremental by nature.
    ///
    /// So: step at most `step` degrees per joint per iteration, re-read, clear any soft fault the
    /// step raised, and go again. Each small step is a target the planner will usually accept even
    /// when the whole journey is not. If two consecutive steps make no measurable progress the walk
    /// stops and says so, rather than grinding against a physical obstruction.
    @discardableResult
    func walkToNeutral(step: Double = 8, maxIterations: Int = 60) async -> Bool {
        await withArmMotion("Walking to neutral", refused: false) {
            await walkToNeutralCore(step: step, maxIterations: maxIterations)
        }
    }

    /// ⚠️ Call only from inside `withArmMotion` — `recoverAndGoNeutral` already holds the lock, so
    /// calling the public wrapper from there would refuse its own motion.
    private func walkToNeutralCore(step: Double = 8, maxIterations: Int = 60) async -> Bool {
        let target = neutralPose
        var stalls = 0
        var lastDistance = Double.greatestFiniteMagnitude

        for i in 0..<maxIterations {
            // ⚠️ STOP must land mid-walk. Without this the loop keeps iterating while every move is
            // refused by the eStop guard, burning 60 iterations and reporting a stall instead of
            // stopping — a stop button whose effect is delayed by a minute is not a stop button.
            if Task.isCancelled || eStopActive || !motionEnabled {
                status = "Stopped."
                GlamaticLink.plog("xArm: neutral walk halted by stop")
                return false
            }
            guard let now = await refreshJoints() else {
                status = "Lost the arm while freeing it"
                return false
            }

            let deltas = zip(now, target).map { $1 - $0 }
            let distance = deltas.map { abs($0) }.max() ?? 0
            if distance <= 3 {
                status = "At neutral — ready"
                GlamaticLink.plog("xArm: freed to neutral in \(i) steps")
                return true
            }

            // No measurable progress twice running means something is physically stopping it, and
            // continuing to command it just grinds. Report the joint that is stuck.
            if lastDistance - distance < 0.5 {
                stalls += 1
                if stalls >= 3 {
                    let worst = deltas.enumerated().max { abs($0.element) < abs($1.element) }
                    let j = (worst?.offset ?? 0) + 1
                    status = String(format: "Stuck %.0f° from neutral on J%d — check the arm is clear.",
                                    distance, j)
                    GlamaticLink.plog("xArm: neutral walk STALLED at J\(j), \(Int(distance))° to go")
                    return false
                }
            } else {
                stalls = 0
            }
            lastDistance = distance

            // One bounded step toward neutral on every joint at once.
            let next = zip(now, deltas).map { here, d in
                here + max(-step, min(step, d))
            }
            status = String(format: "Freeing the arm — %.0f° to go", distance)

            if await moveJoints(next, speed: 10) {
                // Let the step actually execute before sampling again.
                try? await Task.sleep(nanoseconds: 500_000_000)
            } else {
                // Refused. Clear whatever soft fault it raised and try a smaller step next time by
                // letting the loop re-read — a refusal is information, not a reason to stop.
                GlamaticLink.plog("xArm: step refused at \(Int(distance))° to go — clearing")
                _ = await command(FC.cleanWar)
                _ = await command(FC.cleanErr)
                _ = await command(FC.setState, Data([0]))
                try? await Task.sleep(nanoseconds: 300_000_000)
            }

            // A step can raise a fresh soft fault; clear it or every later step is refused too.
            await autoRecoverJog()
        }

        status = "Could not reach neutral — still \(Int(lastDistance))° away"
        GlamaticLink.plog("xArm: neutral walk exhausted iterations")
        return false
    }

    /// Send the arm to neutral without a fault involved — the "start from a known place" tap.
    @discardableResult
    func goNeutral() async -> Bool {
        guard motionEnabled else {
            status = "Enable the arm first"
            return false
        }
        // Same incremental walk — a clean arm gets there in a few steps, and a stuck one is
        // reported instead of silently refused.
        return await walkToNeutral()
    }

    // MARK: - Hand-guiding a physically stuck arm
    //
    // 🔑 **WHEN SOFTWARE CANNOT WIN.** An arm folded back onto itself is not a planning problem; it
    // is resting on its own structure. The controller latches a collision error and refuses to plan
    // a path out of a state it considers invalid, so every clear-and-move ends the same way: fault
    // cleared, move rejected, arm exactly where it was. The manufacturer's answer for this, and the
    // honest one, is to release the joints and move it with your hands.
    //
    // **Mode 2 is joint teaching** in the xArm mode table (0 position · 1 servoj · 2 joint teach ·
    // 4 joint velocity · 5 cartesian velocity). That table is corroborated inside this project rather
    // than taken on faith: PivotBooth's velocity control uses `setMode(4)` with `vcSetJointV`, which
    // is exactly what the table says mode 4 is.
    //
    // ⚠️⚠️ **THE ARM WILL SAG OR DROP THE MOMENT THE BRAKES RELEASE.** It is held up by its servos,
    // and this takes them out of the loop. Whoever taps it must be holding the arm first. That is
    // not a disclaimer — it is the operating instruction, and the UI must not offer this without it.

    @Published private(set) var handGuiding = false

    /// Release the joints for hand-guiding.
    ///
    /// ⚠️ Callers MUST confirm with the operator, and the confirmation must say to take the weight
    /// of the arm first.
    @discardableResult
    func startHandGuiding() async -> Bool {
        guard connected else { status = "Not connected to the arm"; return false }
        if simulated {
            handGuiding = true
            status = "Joints released (simulated)"
            return true
        }
        // Clear first: the controller will not change mode while a fault is latched.
        _ = await command(FC.cleanWar)
        _ = await command(FC.cleanErr)

        guard await command(FC.motionEnable, Data([8, 1])) != nil,
              await command(FC.setMode, Data([2])) != nil,      // 2 = joint teaching
              await command(FC.setState, Data([0])) != nil else {
            status = "The arm would not release its joints"
            GlamaticLink.plog("xArm: hand-guide mode REFUSED")
            return false
        }
        handGuiding = true
        motionEnabled = false          // it is not under our command in this mode
        status = "Joints released — move the arm by hand, then lock it"
        GlamaticLink.plog("xArm: HAND-GUIDE mode on")
        IncidentLog.shared.record(.safety, "Arm joints released for hand-guiding", bad: true)
        return true
    }

    /// Put the arm back under servo control.
    @discardableResult
    func stopHandGuiding() async -> Bool {
        guard connected else { return false }
        if simulated {
            handGuiding = false
            status = "Joints locked (simulated)"
            return true
        }
        _ = await command(FC.setMode, Data([0]))     // back to position control
        _ = await command(FC.setState, Data([0]))
        handGuiding = false
        // Re-read where the hands left it, and start a fresh trail — the old one describes a path
        // through a pose the arm is no longer in.
        _ = await refreshJoints()
        history = [joints]
        if let e = await command(FC.getError), e.count >= 1 { errorCode = Int(e[0]) }
        status = errorCode == 0
            ? "Joints locked — tap Enable when you are ready"
            : "Joints locked, but still faulted: \(faultText)"
        GlamaticLink.plog("xArm: hand-guide off at \(joints.map { Int($0) })")
        return errorCode == 0
    }

    /// Clear the fault and leave the arm LIVE, so the operator can jog the offending joint by hand.
    ///
    /// 🔑 **Sometimes the only thing that knows how to escape is the person looking at it.** No
    /// automatic recovery can see that the elbow is behind the rail; whoever is standing there can.
    /// `recoverFromFault` deliberately leaves the arm cold, which is right for a general fault and
    /// exactly wrong when the next thing you need to do is nudge one joint clear.
    @discardableResult
    func clearAndEnableForJogging() async -> Bool {
        guard await recoverFromFault() else { return false }
        guard await enable() else {
            status = "Fault cleared, but the arm would not enable"
            return false
        }
        status = "Cleared and live — jog the joint that hit something"
        return true
    }

    /// After a jog, clear the *soft* faults an unreachable target raises, so a bad jog is a
    /// harmless no-op rather than a latched error that blocks every later move.
    private func autoRecoverJog() async {
        guard let e = await command(FC.getError), e.count >= 1 else { return }
        let code = Int(e[0])
        // 21 kinematic/unreachable · 23 joint limit · 25 planning · 28 singularity
        if [21, 23, 25, 28].contains(code) {
            GlamaticLink.plog("xArm: clearing soft jog fault \(code)")
            _ = await command(FC.cleanWar)
            _ = await command(FC.cleanErr)
            _ = await command(FC.setState, Data([0]))
        }
    }

    /// Where the arm has recently been, newest last.
    ///
    /// 🔑 **THIS IS THE WAY OUT OF A COLLISION.** When the arm hits something — itself, the rail, a
    /// camera — commanding it to a *new* pose is the wrong instinct: the planner has no idea what it
    /// is touching, and a path to neutral can drive it further into whatever it hit. The one path
    /// known to be clear is the one it just travelled, because it was there seconds ago. So the poll
    /// keeps a breadcrumb trail and `backOut()` walks it in reverse.
    private var history: [[Double]] = []
    private static let historyLimit = 240        // ~60s at 4 Hz

    /// Read joint angles once, publishing the result.
    @discardableResult
    func refreshJoints() async -> [Double]? {
        let now: [Double]
        if simulated {
            now = sim.joints
        } else {
            guard let read = await readJoints() else { return nil }
            now = read
        }
        joints = now

        // Only record meaningfully different positions, so a stationary arm does not fill the trail
        // with 240 copies of one pose and push the real path out of it.
        if let last = history.last {
            let moved = zip(last, now).map { abs($0 - $1) }.max() ?? 0
            if moved > 1.5 { history.append(now) }
        } else {
            history.append(now)
        }
        if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
        return now
    }

    var hasBackOutPath: Bool { history.count > 2 }

    /// Retrace the arm's recent path in reverse to escape a collision.
    ///
    /// ⚠️ **THE ARM MOVES.** It steps back through poses it actually occupied, newest first, which is
    /// the only route this app can claim was clear. Stops as soon as the fault clears and the arm has
    /// moved a sensible distance — the goal is to get OUT, not to travel all the way home.
    ///
    /// ⚠️ **It cannot help if the arm was moved by hand, or if it collided on its very first move** —
    /// there is no trail in either case. It says so rather than pretending.
    @discardableResult
    func backOut(maxSteps: Int = 25) async -> Bool {
        await withArmMotion("Backing out", refused: false) { await backOutCore(maxSteps: maxSteps) }
    }

    private func backOutCore(maxSteps: Int) async -> Bool {
        guard connected else { status = "Not connected to the arm"; return false }
        guard hasBackOutPath else {
            status = "No recent path to back out along — the arm will have to be freed by hand."
            GlamaticLink.plog("xArm: backOut refused — no history")
            return false
        }
        if faultNeedsHardware {
            status = "\(faultText) — fix this on the machine first."
            return false
        }

        GlamaticLink.plog("xArm: BACKING OUT along \(history.count) recorded poses (error \(errorCode))")
        _ = await command(FC.cleanWar)
        _ = await command(FC.cleanErr)
        _ = await command(FC.setMode, Data([0]))
        _ = await command(FC.setState, Data([0]))
        eStopActive = false
        guard await enable() else {
            status = "Cleared the fault, but the arm would not enable"
            return false
        }

        // Walk backwards from the pose before the current one.
        let trail = history.dropLast().reversed().prefix(maxSteps)
        let startedAt = joints
        var stepped = 0

        for pose in trail {
            if Task.isCancelled || eStopActive || !motionEnabled {
                status = "Stopped."
                return false
            }
            status = "Backing out — step \(stepped + 1)"
            if await moveJoints(pose, speed: 8) {
                _ = await waitArrival(pose, tol: 4, timeout: 12)
            } else {
                // A refused step going backwards is unusual; clear and keep retreating.
                _ = await command(FC.cleanWar)
                _ = await command(FC.cleanErr)
                _ = await command(FC.setState, Data([0]))
            }
            stepped += 1

            _ = await refreshJoints()
            if let e = await command(FC.getError), e.count >= 1 { errorCode = Int(e[0]) }

            // Out far enough: no fault, and a real distance from where it was stuck.
            let travelled = zip(startedAt, joints).map { abs($0 - $1) }.max() ?? 0
            if errorCode == 0, travelled > 12 {
                status = String(format: "Backed out %.0f° — clear.", travelled)
                GlamaticLink.plog("xArm: backed out ok after \(stepped) steps, \(Int(travelled))°")
                IncidentLog.shared.record(.safety, "Arm backed out of a collision")
                // Everything from here forward is no longer a path worth retracing.
                history = [joints]
                return true
            }
        }

        status = errorCode == 0
            ? "Backed out, but not far. Check the arm before moving it."
            : "Still faulted after backing out: \(faultText)"
        GlamaticLink.plog("xArm: backOut finished, error \(errorCode)")
        return errorCode == 0
    }

    /// Live telemetry while a joint screen is open.
    ///
    /// 🔑 **Authoring a pose is impossible without this.** You cannot place a joint you cannot see,
    /// and the old link only ever read angles while folding. 4 Hz is enough to follow a jog without
    /// flooding a link that serialises every request.
    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard await self.connected else {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    continue
                }
                await self.refreshJoints()
                if await self.simulated {
                    // The sim has no error or state registers to read; derive what the UI needs.
                    let moving = await self.sim.isMoving
                    await MainActor.run { self.armState = moving ? 1 : 2; self.errorCode = 0 }
                } else {
                    if let s = await self.command(FC.getState), s.count >= 1 {
                        await MainActor.run { self.armState = Int(s[0]) }
                    }
                    if let e = await self.command(FC.getError), e.count >= 1 {
                        await MainActor.run { self.errorCode = Int(e[0]) }
                    }
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Wait until every joint is within `tol`° of target.
    ///
    /// 🔑 **Returns a VERDICT.** PivotBooth's equivalent returns Void and simply falls out of its
    /// loop on timeout, so "arrived" and "gave up after 15s" are indistinguishable to the caller —
    /// the silent-lie pattern that has cost this project whole days (see the bogus speed-test
    /// results). A player that cannot tell these apart reports a move it never made.
    func waitArrival(_ target: [Double], tol: Double = 2.5, timeout: Double = 20) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled { return false }
            guard let now = await refreshJoints() else {
                try? await Task.sleep(nanoseconds: 150_000_000)
                continue
            }
            if zip(now, target).allSatisfy({ abs($0 - $1) <= tol }) { return true }
            if errorCode != 0 {
                GlamaticLink.plog("xArm: fault \(errorCode) mid-move")
                return false
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        GlamaticLink.plog("xArm: arrival FAILED — wanted \(target.map { Int($0) }), at \(joints.map { Int($0) })")
        return false
    }

    // MARK: Link

    @discardableResult
    func connect() async -> Bool {
        if simulated {
            connected = true
            joints = sim.joints
            status = "Connected (simulated)"
            return true
        }
        if connected, connection != nil { return true }
        disconnect()
        guard let port = NWEndpoint.Port(rawValue: Self.port) else { return false }
        let conn = NWConnection(host: NWEndpoint.Host(Self.host), port: port, using: .tcp)
        connection = conn

        let ok = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            var done = false
            func finish(_ v: Bool) {
                guard !done else { return }
                done = true
                cont.resume(returning: v)
            }
            conn.stateUpdateHandler = { st in
                switch st {
                case .ready:  finish(true)
                case .failed, .cancelled: finish(false)
                default: break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { finish(false) }
        }
        connected = ok
        status = ok ? "Connected to the arm" : "No answer from \(Self.host)"
        if !ok { disconnect() }
        return ok
    }

    func disconnect() {
        stopPolling()
        connection?.cancel()
        connection = nil
        connected = false
        // A dropped link is not an energised arm. Leaving this true would let the UI offer motion
        // controls for a machine nothing is talking to.
        motionEnabled = false
    }

    /// Clear faults, enable the servos, position mode, ready state.
    private func enableMotion() async -> Bool {
        _ = await command(FC.cleanWar)
        _ = await command(FC.cleanErr)
        guard await command(FC.motionEnable, Data([8, 1])) != nil else { return false }  // servo 8 = all
        guard await command(FC.setMode, Data([0])) != nil else { return false }          // 0 = position
        guard await command(FC.setState, Data([0])) != nil else { return false }         // 0 = ready
        return true
    }

    /// Degrees in, radians on the wire. Framing copied from PivotBooth's `moveJoints`.
    // `moveJoints` now lives in the live-control section above — one implementation, gated on
    // `motionEnabled` so nothing can command the arm without a deliberate enable.

    private func readJoints() async -> [Double]? {
        guard let d = await command(FC.getJointPos), d.count >= 28 else { return nil }
        var out: [Double] = []
        for i in 0..<7 {
            let lo = i * 4
            let bits = d.subdata(in: lo..<(lo + 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            out.append(Double(Float(bitPattern: UInt32(littleEndian: bits))) * 180 / .pi)
        }
        return Array(out.prefix(5))
    }

    // MARK: Wire

    /// One request at a time; the reply stream desyncs if two overlap.
    private func command(_ funcode: UInt8, _ params: Data = Data()) async -> Data? {
        guard let conn = connection, connected else { return nil }
        while inflight {
            if Task.isCancelled { return nil }
            try? await Task.sleep(nanoseconds: 3_000_000)
        }
        inflight = true
        defer { inflight = false }

        tid &+= 1
        var frame = Data()
        frame.appendBE16(tid)
        frame.appendBE16(2)                                 // protocol id = 2
        frame.appendBE16(UInt16(1 + params.count))
        frame.append(funcode)
        frame.append(params)

        do {
            try await send(conn, frame)
            let header = try await recv(conn, 6)
            let len = Int(header[4]) << 8 | Int(header[5])
            let body = try await recv(conn, len)            // [funcode][status][payload]
            guard body.count >= 2 else { return nil }
            if body[1] != 0 {
                GlamaticLink.plog("xArm: cmd \(funcode) returned status \(body[1])")
                return nil
            }
            return body.count > 2 ? body.subdata(in: 2..<body.count) : Data()
        } catch {
            // A timed-out command leaves the byte stream misaligned, so drop the link rather than
            // risk pairing the next reply with the wrong request.
            GlamaticLink.plog("xArm: link error — \(error.localizedDescription)")
            disconnect()
            return nil
        }
    }

    private func send(_ conn: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { err in
                if let err { c.resume(throwing: err) } else { c.resume() }
            })
        }
    }

    private func recv(_ conn: NWConnection, _ n: Int, seconds: Double = 3) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await self.recvExact(conn, n) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw XArmError.timeout
            }
            guard let first = try await group.next() else { throw XArmError.timeout }
            group.cancelAll()
            return first
        }
    }

    private nonisolated func recvExact(_ conn: NWConnection, _ n: Int) async throws -> Data {
        var buf = Data()
        while buf.count < n {
            let chunk: Data = try await withCheckedThrowingContinuation { c in
                conn.receive(minimumIncompleteLength: 1, maximumLength: n - buf.count) { d, _, _, err in
                    if let err { c.resume(throwing: err) } else { c.resume(returning: d ?? Data()) }
                }
            }
            if chunk.isEmpty { throw XArmError.timeout }
            buf.append(chunk)
        }
        return buf
    }
}

private extension Data {
    mutating func appendBE16(_ v: UInt16) { append(UInt8(v >> 8)); append(UInt8(v & 0xFF)) }
    mutating func appendLE32(_ f: Float) {
        var bits = f.bitPattern.littleEndian
        Swift.withUnsafeBytes(of: &bits) { append(contentsOf: $0) }
    }
}
