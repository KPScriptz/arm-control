import Foundation

// MARK: - A five-joint arm with no arm attached
//
// 🔑 **WHY.** The xArm lives on the wired 192.168.1.x LAN, which means authoring a movement needs
// the adapter, the powered hub, the arm powered up and nobody else driving it. That is the right
// setup for *running* a shot and a terrible precondition for *designing* one. `RailSimulator` made
// the rail's whole booth loop testable indoors; this does the same for the arm, so poses and
// sequences can be built the night before and played on hardware the next day.
//
// ⚠️ **IT MODELS THE MACHINE'S REAL BEHAVIOUR, NOT CONVENIENT BEHAVIOUR.** Joints travel at the
// commanded degrees-per-second and all five move together, so a leg finishes when the joint with the
// furthest to go arrives — which is what makes a sequence's duration come out the same here as on
// the arm. Enabling is still required before anything moves, and a disable still stops it dead.
//
// ⚠️ **J2's FLOOR IS THE ONE REAL LIMIT ANYONE HAS MEASURED** (mechanical ≈ −118°; PivotBooth floors
// at −95° for margin). It is enforced here so a sequence authored in simulation cannot be one that
// the real arm would refuse on its second joint. The other four joints are deliberately
// unconstrained, for the same reason `XArmLink` ships no limit table: inventing numbers that look
// authoritative is worse than admitting they are unknown.
@MainActor
final class ArmSimulator: ObservableObject {

    /// Live joint angles, degrees, J1…J5.
    private(set) var joints: [Double] = Array(repeating: 0, count: XArmLink.jointCount)

    private var target: [Double] = Array(repeating: 0, count: XArmLink.jointCount)
    private var speed: Double = 20
    private(set) var enabled = false
    private(set) var stopped = false

    /// 🔑 **Corrected 2026-09-10 from the factory export.** This used to be a lone J2 floor of −95°
    /// inherited from PivotBooth's margin — and the manufacturer's own program 1 drives J2 to −99.9°
    /// and J3 to −183.7°, so that floor would have REFUSED the factory's move. The envelope is now
    /// what the 28 factory programs actually reach, per joint. See `FactoryPrograms.envelope`.
    static var envelope: [ClosedRange<Double>] { FactoryPrograms.envelope }

    var isMoving: Bool {
        zip(joints, target).contains { abs($0 - $1) > 0.2 }
    }

    func enable() {
        enabled = true
        stopped = false
    }

    func disable() {
        enabled = false
        // Stop where it stands rather than snapping anywhere.
        target = joints
    }

    func eStop() {
        stopped = true
        enabled = false
        target = joints
    }

    /// Accept a joint target, or refuse it the way the controller would.
    func moveJoints(_ degs: [Double], speed s: Double) -> Bool {
        guard enabled, !stopped else { return false }
        var want = degs
        while want.count < XArmLink.jointCount { want.append(0) }
        want = Array(want.prefix(XArmLink.jointCount))

        // Refuse rather than silently clamp. A simulator that quietly fixes up an illegal pose
        // teaches a sequence that the real arm will reject. Small tolerance so a factory pose
        // sitting exactly on the envelope edge is not refused by rounding.
        for (i, v) in want.enumerated() where i < Self.envelope.count {
            let r = Self.envelope[i]
            if v < r.lowerBound - 0.5 || v > r.upperBound + 0.5 { return false }
        }

        target = want
        speed = max(1, s)
        return true
    }

    /// Integrate toward the target. `dt` is real elapsed seconds, never a hardcoded interval —
    /// feeding a fixed value is what made the simulated rail run 7% slow and sent me chasing a
    /// measurement bug that did not exist.
    func tick(_ dt: Double) {
        guard enabled, !stopped else { return }
        let maxStep = speed * dt
        for i in joints.indices {
            let delta = target[i] - joints[i]
            if abs(delta) <= maxStep { joints[i] = target[i] }
            else { joints[i] += delta > 0 ? maxStep : -maxStep }
        }
    }

    func reset() {
        joints = Array(repeating: 0, count: XArmLink.jointCount)
        target = joints
        enabled = false
        stopped = false
    }
}
