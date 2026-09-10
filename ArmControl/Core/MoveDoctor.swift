import Foundation

/// Finds the sequence that actually makes the carriage move, by trying them and watching the
/// position.
///
/// 🔑 **Why this exists.** The rail is connected, homed, faultless, and reports a live position —
/// and nothing moves. Every command the app sends is a *write*, and this PLC's answer to a write
/// it does not like is **HTTP 200 and silence**: an unauthenticated write, a write in the wrong
/// mode, and a write it acted on are indistinguishable from the app's side. So the trace fills
/// with `"IOMotor".Manual = 1` and `ascii '12' → sent`, every one of them a success, and the
/// carriage sits still.
///
/// The only ground truth is **CurrentPosition**. This runs each candidate sequence and watches
/// that number. Whichever one moves the rail is the answer, and the rest is noise.
///
/// ⚠️⚠️ **THIS MOVES THE RAIL.** It is gated behind an explicit confirmation, it never runs itself,
/// and STOP stays live throughout. Stand clear before using it.
@MainActor
final class MoveDoctor: ObservableObject {
    static let shared = MoveDoctor()
    private init() {}

    struct Step: Identifiable {
        let id = UUID()
        var name: String
        var moved: Bool?          // nil = not a movement test
        var detail: String
    }

    @Published private(set) var steps: [Step] = []
    @Published private(set) var running = false
    @Published private(set) var conclusion: String?

    private let link = GlamaticLink.shared

    private var position: Double {
        Double(link.state.currentPosition.trimmingCharacters(in: .whitespaces)) ?? -1
    }

    /// Watch CurrentPosition for `seconds`, returning the largest movement seen.
    ///
    /// Polls at 0.5s with the background poll already suspended by the caller — this is a bounded
    /// burst, not the sustained fast polling that wedges the S7-1200.
    private func watchForMotion(seconds: Double) async -> Double {
        let start = position
        var peak = 0.0
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
            await link.refresh()
            let delta = abs(position - start)
            if delta > peak { peak = delta }
            // A clear move is enough; no need to sit through the whole traverse.
            if peak > 15 { break }
        }
        return peak
    }

    /// `moved` is judged against a few millimetres of slack — the readout jitters by a digit or two
    /// even at rest, and calling that a move would make every test pass.
    private static let threshold = 5.0

    func run(program: Int) async {
        guard !running else { return }
        running = true
        steps = []
        conclusion = nil
        defer { running = false }

        GlamaticLink.plog("=== MOVE DOCTOR: program \(program) ===")
        link.suspendPolling()
        defer { link.resumePolling() }

        // 0. Is the session even alive? Everything below is meaningless if it is not.
        let alive = await link.refresh()
        add(Step(name: "Session",
                 detail: alive
                    ? "Live. Position \(link.state.currentPosition) mm, homed \(link.state.isHomed ? "yes" : "no"), StatusError \(link.state.statusError), RobotError \(link.state.robotError), ProgramNum \(link.state.programNum)."
                    : "DEAD — the PLC returned no data (\(link.lastRead)). Everything below would be written into a discarded session."))
        guard alive else {
            conclusion = "The web session is dead. Reconnect first — until then every write is accepted and thrown away."
            return
        }

        if link.state.hasFault {
            add(Step(name: "Fault latched",
                     detail: "StatusError=\(link.state.statusError) RobotError=\(link.state.robotError). The PLC refuses moves while this is set. Clear it from the Console, then run this again."))
            conclusion = "A latched fault will block every sequence below. Clear it first."
            return
        }

        // 1. THE DECISIVE TEST — do writes actually land?
        //
        // Writing ProgramNumber and reading it back is the one probe that separates "the PLC is
        // ignoring us" from "the PLC is listening but the mode is wrong". It moves nothing.
        let probeValue = program == 1 ? 2 : 1
        _ = await link.write(.programNumber, String(probeValue))
        try? await Task.sleep(nanoseconds: 400_000_000)
        await link.refresh()
        let stuck = link.state.programNum == String(probeValue)
        add(Step(name: "Do writes land?",
                 detail: stuck
                    ? "YES — wrote ProgramNumber=\(probeValue) and read it back. The session is authenticated and the PLC is accepting tag writes."
                    : "NO — wrote ProgramNumber=\(probeValue), read back “\(link.state.programNum)”. The PLC is discarding writes. That is a login/session problem, not a motion problem."))
        guard stuck else {
            conclusion = "Writes are being silently discarded — the classic symptom of an unauthenticated session. Reconnect and check the PLC login."
            return
        }

        // 2. Automatic mode. A stored program is an AUTO-mode action; Manual=1 puts the PLC in
        //    jog mode, where a RunProgram request is a perfectly legal thing to ignore.
        await tryMove(name: "RunProgram with Manual=0 (automatic mode)",
                      program: program) {
            _ = await self.link.setManual(false)
            _ = await self.link.setEnable(true)
            try? await Task.sleep(nanoseconds: 200_000_000)
            _ = await self.link.write(.programNumber, String(program))
            try? await Task.sleep(nanoseconds: 300_000_000)
            _ = await self.link.write(.runProgram, "1")
        }
        if conclusion != nil { return }

        // 3. The way the app does it today: armed, then RunProgram.
        await tryMove(name: "RunProgram with Manual=1 + Enable=1 (how the app arms today)",
                      program: program) {
            _ = await self.link.setManual(true)
            _ = await self.link.setEnable(true)
            try? await Task.sleep(nanoseconds: 200_000_000)
            _ = await self.link.write(.programNumber, String(program))
            try? await Task.sleep(nanoseconds: 300_000_000)
            _ = await self.link.write(.runProgram, "1")
        }
        if conclusion != nil { return }

        // 4. The raw ASCII channel, in automatic mode. This is what PivotBooth's working buttons
        //    call, and what the original CanonPivotBot used — with no web session at all, so it
        //    cannot have depended on Manual/Enable.
        await tryMove(name: "Raw port \(GlamaticLink.asciiPort) trigger with Manual=0",
                      program: program) {
            _ = await self.link.setManual(false)
            try? await Task.sleep(nanoseconds: 200_000_000)
            _ = await self.link.triggerProgramRaw(program)
        }
        if conclusion != nil { return }

        // 5. Raw channel exactly as the app sends it now.
        await tryMove(name: "Raw port \(GlamaticLink.asciiPort) trigger while armed",
                      program: program) {
            _ = await self.link.setManual(true)
            _ = await self.link.setEnable(true)
            try? await Task.sleep(nanoseconds: 200_000_000)
            _ = await self.link.triggerProgramRaw(program)
        }
        if conclusion != nil { return }

        // 6. Nothing moved it. A direct manual move is the last discriminator: if THIS works the
        //    PLC and the wiring are fine and the problem is specifically the stored programs.
        let here = position
        let target = here < 300 ? here + 60 : here - 60
        await tryMove(name: "Direct manual move to \(Int(target)) mm",
                      program: program) {
            _ = await self.link.setManual(true)
            _ = await self.link.setEnable(true)
            try? await Task.sleep(nanoseconds: 200_000_000)
            _ = await self.link.move(to: target, velocity: 80)
        }
        if conclusion != nil {
            conclusion = "Manual drive moves the carriage, but no stored-program trigger does. The rail and the link are fine — programs \(program) may be empty on the PLC, or stored under a different number. Try another program number, or check the program list on the PLC's own web page."
            return
        }

        conclusion = "Nothing moved the carriage — not a stored program on either channel, and not a direct manual move. Since writes demonstrably land, this points at the PLC itself: a hardware enable, an E-stop still latched, or the drive not powered. Check the control box."
    }

    /// Run one candidate and watch the position.
    private func tryMove(name: String, program: Int, _ body: () async -> Void) async {
        GlamaticLink.plog("move doctor: trying \(name)")
        let before = position
        await body()
        let peak = await watchForMotion(seconds: 8)
        let moved = peak >= Self.threshold
        add(Step(name: name,
                 moved: moved,
                 detail: moved
                    ? String(format: "MOVED — %.0f mm from %.0f. This is the sequence that works.", peak, before)
                    : String(format: "No movement. Position stayed at %.0f mm (largest change %.1f mm).", before, peak)))
        GlamaticLink.plog("move doctor: \(name) → \(moved ? "MOVED \(Int(peak))mm" : "nothing")")
        if moved {
            conclusion = "“\(name)” moves the rail. That is the sequence the app should use for presets."
            // Leave it where it stopped; do not chase it back. An unrequested return trip is
            // another unannounced movement, which is exactly what this screen warns about.
        }
    }

    private func add(_ s: Step) { steps.append(s) }

    var export: String {
        var out = ["Arm Control — move test", "\(Date().formatted()) · rail at \(GlamaticLink.host)", ""]
        for s in steps {
            let mark = s.moved.map { $0 ? "[MOVED]" : "[still]" } ?? "[info]"
            out.append("\(mark) \(s.name)")
            out.append("   \(s.detail)")
        }
        if let conclusion { out.append(""); out.append("→ \(conclusion)") }
        return out.joined(separator: "\n")
    }
}
