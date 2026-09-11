import Foundation
import Network

// MARK: - Byte-level arm diagnosis, driven from the Mac
//
// 🔑 **WHY THIS EXISTS.** "Can you make the arm move" — and the only machine that can reach the arm
// is the iPad, which has no remote screen. What the Mac CAN do is launch this app on the iPad with
// an argument and copy a file back off it. So: pass `-armcontrol.diag read` and the app connects,
// runs the factory preamble, and writes every byte it sent and received to `Documents/arm-diag.log`.
// Pass `-armcontrol.diag nudge` and it also moves J1 by 5° at 10°/s and records whether the joints
// changed. The Mac pulls the log with `devicectl device copy from`.
//
// ⚠️ **LAUNCH ARGUMENT ONLY — deliberately not a setting.** The argument domain cannot persist, so
// this cannot fire on an ordinary launch, and only Xcode or devicectl can pass it. The nudge is a
// human-requested, human-watched 5° test with the e-stop in reach; it is not an exception to the
// "never move on launch" rule so much as the operator's jog tap, issued from the Mac.
@MainActor
enum ArmDiagnostic {

    static var mode: String? {
        UserDefaults.standard.string(forKey: "armcontrol.diag")
    }

    private static var lines: [String] = []
    private static var logURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("arm-diag.log")
    }

    private static func log(_ s: String) {
        let stamp = String(format: "%.3f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000))
        lines.append("[\(stamp)] \(s)")
        try? lines.joined(separator: "\n").write(to: logURL, atomically: true, encoding: .utf8)
    }

    static func runIfRequested() async {
        // `-armcontrol.setpin NNNN` — set the booth PIN from the Mac, once, and stop. Exists because
        // the PIN default changed when the repo went public and the operator was locked out.
        if let pin = UserDefaults.standard.string(forKey: "armcontrol.setpin"), pin.count >= 4 {
            Kiosk.shared.setPIN(pin)
            lines = ["PIN set to \(pin.count) digits"]
            try? lines.joined(separator: "\n").write(to: logURL, atomically: true, encoding: .utf8)
        }
        guard let m = mode else { return }

        // `rail` — is the Glamatic box answering at all, and on which port? Port 2000 up with HTTPS
        // dead = the S7-1200 web server is wedged (power-cycle the box). Neither answering = the box
        // is off, or the e-stop is latched (it kills the switch inside the box too).
        if m == "rail" {
            lines = []
            log("RAIL PROBE host=\(GlamaticLink.host)")
            for (label, port) in [("ascii :2000", GlamaticLink.asciiPort), ("https :443", UInt16(443)), ("http :80", UInt16(80))] {
                let r = await tcpProbe(GlamaticLink.host, port)
                log("  \(label) → \(r)")
            }
            // Do NOT call connect() here — RootView's launch auto-connect already has a handshake
            // running, and connect() is single-flight, so a second call is refused as a duplicate
            // (that is not a failure, it is the lock working). Watch the app's own attempt instead.
            let link = GlamaticLink.shared
            for i in 1...12 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                log("  +\(i * 2)s connected=\(link.connected) status='\(link.status)'")
                if link.connected { break }
            }
            if link.connected {
                _ = await link.refresh()
                let s = link.state
                log("  state: pos=\(s.currentPosition) homed=\(s.homed) statusError=\(s.statusError) robotError=\(s.robotError) program=\(s.programNum)")
            } else {
                log("  NOT CONNECTED after 24s — the S7-1200 web server is answering TCP but not completing the portal login. Its session pool is probably full of dead sessions from the last dozen relaunches. Power-cycle the Glamatic box.")
            }
            log("RAIL DONE")
            return
        }

        let arm = XArmLink.shared
        lines = []
        log("ARM DIAGNOSTIC mode=\(m) host=\(XArmLink.host) simulated=\(arm.simulated)")
        arm.wireTap = { log($0) }
        defer { arm.wireTap = nil }

        if arm.simulated {
            log("ABORT: simulated arm is on — nothing to diagnose")
            return
        }

        log("--- connect ---")
        let ok = await arm.connect()
        log("connect -> \(ok) status='\(arm.status)'")
        guard ok else { log("DONE (no link)"); return }

        log("--- as found ---")
        await readAll(arm)

        // Pins mode is read-only and must NOT enable — the PLC's program is about to drive the
        // arm and our enable/mode preamble would fight it.
        if m == "pins" { await watchPins(arm); return }

        // Peek: read state, error AND warning without clearing anything, then let go of the port.
        if m == "peek" {
            if let w = await arm.readInputs() { log("pins=0x\(String(w, radix: 16))") }
            log("PEEK DONE — fault=\(arm.errorCode) '\(arm.faultText)' warn=\(arm.warnCode) state=\(arm.stateText) flags=0x\(String(arm.lastStatusFlags, radix: 16))")
            arm.disconnect()
            return
        }

        log("--- enable (clean_warn, clean_error, motion_enable, set_mode 0, set_state 0) ---")
        let en = await arm.enable()
        log("enable -> \(en) status='\(arm.status)'")
        log("--- assert mode again, checking each reply ---")
        let pre = await arm.prepareForMotion()
        log("prepareForMotion -> \(pre) problem=\(arm.preambleProblem ?? "none")")

        log("--- after preamble ---")
        await readAll(arm)

        // `play:N` runs factory program N through the normal player and logs the joints as it goes.
        if m.hasPrefix("play:"), let n = Int(m.dropFirst(5)) {
            guard let motion = ArmMotionStore.shared.motions.first(where: { $0.program == n })
                    ?? FactoryPrograms.program(n) else {
                log("ABORT: no program \(n)")
                return
            }
            if arm.errorCode != 0 {
                log("REFUSING PLAY: error \(arm.errorCode) \(arm.faultText)")
                return
            }
            log("--- PLAY \(motion.name): \(motion.poses.count) poses, \(String(format: "%.1f", motion.duration()))s ---")
            for (i, p) in motion.poses.enumerated() {
                log("  pose \(i + 1): \(p.jointLabel) @ \(Int(p.speed))°/s hold \(p.dwell)s")
            }
            let store = ArmMotionStore.shared
            store.start(motion)
            let t0 = Date()
            var lastNote = ""
            var started = false
            // start() spawns a task; `isPlaying` goes true a beat later. Wait for it to begin,
            // then watch until it ends.
            while Date().timeIntervalSince(t0) < 60 {
                if store.isPlaying { started = true }
                if started, !store.isPlaying { break }
                if !started, Date().timeIntervalSince(t0) > 3 { log("  player never started"); break }
                try? await Task.sleep(nanoseconds: 250_000_000)
                let j = arm.joints.map { String(format: "%.0f", $0) }
                if store.note != lastNote { log("  note: \(store.note)"); lastNote = store.note }
                log("  t+\(String(format: "%.2f", Date().timeIntervalSince(t0)))s step \(store.step) joints=\(j) \(arm.stateText)")
            }
            log("final note: \(store.note)")
            log("final joints=\(arm.joints.map { String(format: "%.1f", $0) })")
            log("PLAY DONE in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
            return
        }

        guard m == "nudge" else {
            log("READ DONE")
            return
        }

        if arm.errorCode != 0 {
            log("REFUSING NUDGE: error \(arm.errorCode) \(arm.faultText)")
            return
        }
        let before = arm.joints
        guard before.count >= 5 else { log("REFUSING NUDGE: no joint reading"); return }
        var target = before
        target[0] += 5
        log("--- NUDGE J1 \(before[0]) -> \(target[0]) at 10°/s ---")
        let sent = await arm.moveJoints(target, speed: 10, acc: 200)
        log("moveJoints -> \(sent)")
        for i in 0..<12 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            let j = await arm.refreshJoints() ?? []
            let q = await arm.queuedCommands()
            log("t+\(Double(i + 1) * 0.25)s joints=\(j.map { String(format: "%.1f", $0) }) state=\(arm.stateText) queue=\(q.map(String.init) ?? "?")")
        }
        let moved = abs((arm.joints.first ?? before[0]) - before[0])
        log("VERDICT: J1 moved \(String(format: "%.2f", moved))° -> \(moved > 2 ? "THE ARM MOVES" : "DID NOT MOVE")")
        if moved > 2 {
            log("--- returning ---")
            _ = await arm.moveJoints(before, speed: 10, acc: 200)
            _ = await arm.waitArrival(before, tol: 2, timeout: 10)
            log("returned to \(arm.joints.map { String(format: "%.1f", $0) })")
        }
        log("NUDGE DONE")
    }


    private static func watchPins(_ arm: XArmLink) async {
        // `pins` watches the controller's input pins for 60s and logs every change, decoded as the
    // Blockly branch number. Fire a PLC program from the Console while it runs and the log
    // says which arm branch that program number actually selects.
        log("--- WATCHING INPUT PINS for 150s — fire a PLC program now ---")
        var last: UInt16? = nil
        let t0 = Date()
        var samples = 0
        while Date().timeIntervalSince(t0) < 150 {
            if let w = await arm.readInputs() {
                samples += 1
                if w != last {
                    let bits = (0..<8).map { (w >> $0) & 1 == 1 ? "1" : "0" }.joined()
                    log("t+\(String(format: "%.1f", Date().timeIntervalSince(t0)))s pins=0x\(String(w, radix: 16)) bits[0..7]=\(bits) → BRANCH \(XArmLink.branch(fromInputs: w))  joints=\(arm.joints.map { String(format: "%.0f", $0) })")
                    last = w
                }
            } else if samples == 0 {
                log("readInputs returned nil (status 0x\(String(arm.lastStatusFlags, radix: 16)))")
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            _ = await arm.refreshJoints()
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        log("PINS DONE — \(samples) reads, last=\(last.map { "0x" + String($0, radix: 16) } ?? "none")")

    }

    /// Plain TCP connect with a 3s limit — "does anything answer on this port".
    private static func tcpProbe(_ host: String, _ port: UInt16) async -> String {
        guard let p = NWEndpoint.Port(rawValue: port) else { return "bad port" }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
        return await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            var done = false
            func finish(_ s: String) { guard !done else { return }; done = true; conn.cancel(); cont.resume(returning: s) }
            conn.stateUpdateHandler = { st in
                switch st {
                case .ready: finish("OPEN")
                case .failed(let e): finish("refused/unreachable (\(e))")
                case .waiting(let e): finish("waiting (\(e))")
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { finish("no answer in 3s") }
        }
    }

    private static func readAll(_ arm: XArmLink) async {
        _ = await arm.refreshJoints()
        let why = await arm.readiness()
        let q = await arm.queuedCommands()
        log("joints=\(arm.joints.map { String(format: "%.1f", $0) }) state=\(arm.armState)(\(arm.stateText)) error=\(arm.errorCode) readiness=\(why ?? "ready") queue=\(q.map(String.init) ?? "?") motionEnabled=\(arm.motionEnabled)")
    }
}
