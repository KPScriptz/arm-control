import Foundation

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
        guard let m = mode else { return }
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

        log("--- enable (clean_warn, clean_error, motion_enable, set_mode 0, set_state 0) ---")
        let en = await arm.enable()
        log("enable -> \(en) status='\(arm.status)'")
        log("--- assert mode again, checking each reply ---")
        let pre = await arm.prepareForMotion()
        log("prepareForMotion -> \(pre) problem=\(arm.preambleProblem ?? "none")")

        log("--- after preamble ---")
        await readAll(arm)

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

    private static func readAll(_ arm: XArmLink) async {
        _ = await arm.refreshJoints()
        let why = await arm.readiness()
        let q = await arm.queuedCommands()
        log("joints=\(arm.joints.map { String(format: "%.1f", $0) }) state=\(arm.armState)(\(arm.stateText)) error=\(arm.errorCode) readiness=\(why ?? "ready") queue=\(q.map(String.init) ?? "?") motionEnabled=\(arm.motionEnabled)")
    }
}
