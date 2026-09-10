import Foundation

// MARK: - Movements that move the whole rig
//
// 🔑 **WHY THIS EXISTS ALONGSIDE `CustomMotion`.** `CustomMotion` describes the RAIL: one number,
// a position in millimetres, because the Glamatic is a single linear axis. That is the whole
// machine. But the rig has a second one — a uFactory xArm 5, five jointed axes — and until now
// ArmControl only ever told it to fold to zero. A shot shaped by hand ("pan round as it travels,
// tilt down at the far end, hold, come back") is not expressible as one number, so it could not be
// authored at all.
//
// An `ArmPose` is therefore the whole rig at one instant: five joint angles, and optionally where
// the carriage is. A sequence of them is a movement.
//
// ⚠️ **THE RAIL CHANNEL IS OPT-IN PER POSE, AND THAT IS DELIBERATE.** `rail` is `Double?`, and nil
// means "do not touch the carriage". Two machines in one playback loop is exactly the situation that
// produced three runaways on 2026-09-10 — and the cause turned out to be a *second app* driving the
// same rail. A movement that silently commands the carriage because a default said 0 mm would
// recreate that class of surprise. You opt the rail in, per pose, and the editor shows it.

/// The rig at one instant.
struct ArmPose: Codable, Equatable, Identifiable {
    var id = UUID()
    /// Joint angles in degrees, J1…J5.
    var joints: [Double]
    /// Degrees per second used to REACH this pose.
    var speed: Double = 20
    /// Seconds to hold on arrival. The beat a ramp punches on.
    var dwell: Double = 0
    /// Carriage target in mm, or nil to leave the rail alone for this pose.
    var rail: Double?
    /// Joint acceleration in °/s², or nil for the gentle default.
    ///
    /// 🔑 The factory programs run 200–1146 °/s²; the app's original hardcoded 5 rad/s² is
    /// 286 °/s², so a faithfully-imported program played back soft. Carried per pose so an
    /// imported move keeps its snap and an authored one keeps its gentleness.
    var acc: Double?

    /// Joint list padded/trimmed to the arm's real joint count, so a pose saved against a
    /// different assumption can never index out of range.
    var normalised: [Double] {
        var j = joints
        while j.count < XArmLink.jointCount { j.append(0) }
        return Array(j.prefix(XArmLink.jointCount))
    }

    var clampedRail: Double? {
        guard let rail else { return nil }
        return min(PLC.positionRange.upperBound, max(PLC.positionRange.lowerBound, rail))
    }

    /// "J1 −40° · J2 12° · J3 −90°…" — what the row in the list reads.
    var jointLabel: String {
        normalised.enumerated()
            .map { "J\($0.offset + 1) \(Int($0.element.rounded()))°" }
            .joined(separator: " · ")
    }
}

struct ArmMotion: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var poses: [ArmPose]
    /// The factory program this was imported from, if any. Nil for authored movements.
    var program: Int?
    /// Parts of the factory program this import could not represent — cartesian moves and arcs.
    /// Non-empty means "this is the joint-space part of the program, not all of it."
    var caveats: [String] = []

    /// Longest joint sweep between consecutive poses, divided by speed, plus dwells.
    ///
    /// 🔑 The arm moves every joint simultaneously and finishes when the SLOWEST one does, so the
    /// leg's length is set by the joint with the furthest to travel — not by the sum, and not by J1.
    /// Getting this wrong makes every take length wrong.
    func duration(from start: [ArmPose]? = nil) -> Double {
        var here = start?.first?.normalised ?? poses.first?.normalised ?? Array(repeating: 0, count: XArmLink.jointCount)
        var total = 0.0
        for p in poses {
            let target = p.normalised
            let sweep = zip(here, target).map { abs($0 - $1) }.max() ?? 0
            total += sweep / max(1, p.speed) + p.dwell
            here = target
        }
        return total
    }

    var usesRail: Bool { poses.contains { $0.rail != nil } }
}

// MARK: - The store and the player

@MainActor
final class ArmMotionStore: ObservableObject {
    static let shared = ArmMotionStore()

    private static let key = "armcontrol.armMotions.v1"
    private static let factorySeededKey = "armcontrol.armMotions.factorySeeded.v1"

    @Published private(set) var motions: [ArmMotion] = []

    /// The sequence being built by capturing poses, before it is named and saved.
    @Published var recording: [ArmPose] = []

    /// Which saved movement `recording` was loaded from, if any.
    ///
    /// 🐞 **Without this, editing a saved movement silently DUPLICATED it.** The pencil loaded the
    /// poses into `recording`, and Save then appended a second movement with the same name — so a
    /// tweak to "Whalefall arm" left you with two of them and no clue which one the booth would
    /// play. Tracking the origin means Save updates what you opened.
    @Published private(set) var editingID: UUID?
    @Published private(set) var editingName: String?

    /// Which movement is running, how far through, and what it is doing.
    @Published private(set) var playing: ArmMotion?
    @Published private(set) var step = 0
    @Published private(set) var note = ""

    /// 🔑 **THE HANDLE, RETAINED — this is the bug the rail's `MotionStore` still has.**
    /// There, `play` is an `async` func that never assigns `self.task`, and every caller writes
    /// `Task { await store.play(m) }` without keeping the handle. So `stop()` cancels nothing and
    /// the `Task.isCancelled` checks inside the loop can never fire: STOP drops Enable while the
    /// waypoint loop keeps writing Execute, which is precisely the standing-request state that
    /// detonates on the next arm. Playback here is started through `start(_:)`, which OWNS the task,
    /// so `stop()` has something to cancel.
    private var playTask: Task<Void, Never>?

    private let arm = XArmLink.shared
    private let rail = GlamaticLink.shared

    private init() {
        if let d = UserDefaults.standard.data(forKey: Self.key),
           let m = try? JSONDecoder().decode([ArmMotion].self, from: d) {
            motions = m
        }
        // 🔑 The factory programs land in the library ONCE, as ordinary editable movements. Seeded
        // once rather than merged on every launch so a program you have edited or deleted stays
        // that way — the same rule the rail's Whalefall seed follows. `restoreFactory` brings any
        // of them back untouched.
        if !UserDefaults.standard.bool(forKey: Self.factorySeededKey) {
            motions.append(contentsOf: FactoryPrograms.all)
            UserDefaults.standard.set(true, forKey: Self.factorySeededKey)
            persist()
        }
    }

    /// Put a factory program back exactly as delivered, replacing any edited copy.
    func restoreFactory(_ n: Int) {
        guard let fresh = FactoryPrograms.program(n) else { return }
        motions.removeAll { $0.program == n }
        motions.append(fresh)
        persist()
    }

    // MARK: Library

    func save(_ m: ArmMotion) {
        if let i = motions.firstIndex(where: { $0.id == m.id }) { motions[i] = m }
        else { motions.append(m) }
        persist()
    }

    func delete(_ m: ArmMotion) {
        motions.removeAll { $0.id == m.id }
        persist()
    }

    private func persist() {
        guard let d = try? JSONEncoder().encode(motions) else { return }
        UserDefaults.standard.set(d, forKey: Self.key)
    }

    // MARK: Teaching

    /// Keep the arm exactly where it is now as the next pose.
    ///
    /// 🔑 **This is the authoring gesture.** Jog the joints until the shot looks right, then keep
    /// it. No angle has to be typed or imagined, which is the difference between an editor that
    /// gets used and the waypoint table that did not.
    @discardableResult
    func capturePose(dwell: Double = 0.3) -> Bool {
        let j = arm.joints
        guard j.count >= XArmLink.jointCount else { return false }
        recording.append(ArmPose(joints: Array(j.prefix(XArmLink.jointCount)),
                                 speed: arm.jointSpeed,
                                 dwell: dwell,
                                 rail: nil))
        return true
    }

    func clearRecording() {
        recording = []
        editingID = nil
        editingName = nil
    }

    /// Open a saved movement for editing, remembering where it came from.
    func loadForEditing(_ m: ArmMotion) {
        recording = m.poses
        editingID = m.id
        editingName = m.name
    }

    @discardableResult
    func saveRecording(as name: String) -> ArmMotion? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, !recording.isEmpty else { return nil }
        // Keep the original id when editing, so this replaces rather than duplicates.
        let m = ArmMotion(id: editingID ?? UUID(), name: n, poses: recording)
        save(m)
        clearRecording()
        return m
    }

    // MARK: Editing poses

    func updatePose(_ pose: ArmPose) {
        guard let i = recording.firstIndex(where: { $0.id == pose.id }) else { return }
        recording[i] = pose
    }

    func movePose(_ pose: ArmPose, by offset: Int) {
        guard let i = recording.firstIndex(where: { $0.id == pose.id }) else { return }
        let j = i + offset
        guard recording.indices.contains(j) else { return }
        recording.swapAt(i, j)
    }

    func removePose(_ pose: ArmPose) {
        recording.removeAll { $0.id == pose.id }
    }

    /// Drive the arm to a pose so it can be seen before it is committed.
    ///
    /// ⚠️ THE ARM MOVES. Used by the editor's "Show me" button, which is an explicit tap.
    @discardableResult
    func preview(_ pose: ArmPose) async -> Bool {
        guard arm.motionEnabled else { return false }
        let target = pose.normalised
        guard await arm.moveJoints(target, speed: pose.speed, acc: pose.acc) else { return false }
        return await arm.waitArrival(target)
    }

    // MARK: Playing

    var isPlaying: Bool { playing != nil }

    /// Run a movement. Returns immediately; watch `playing` / `step` / `note`.
    ///
    /// ⚠️ **THE ARM MOVES, AND SO MAY THE RAIL.** This never enables anything — the arm must
    /// already be enabled by a human tap, and a pose's rail leg is skipped unless the rail is armed
    /// and homed. Arming is not something a playback loop gets to do.
    func start(_ motion: ArmMotion) {
        guard !isPlaying else { return }
        playTask = Task { [weak self] in
            await self?.run(motion)
        }
    }

    /// Cancel playback and bring both machines to rest.
    ///
    /// 🔑 Cancelling the task is not enough on its own: the loop may be parked inside an `await` on
    /// a move that is still executing, so the machines are told to stop as well.
    func stop() {
        playTask?.cancel()
        playTask = nil
        Task {
            await arm.eStop()
            if rail.connected { _ = await rail.stop() }
            note = "Stopped."
            playing = nil
            step = 0
        }
    }

    private func run(_ motion: ArmMotion) async {
        guard arm.motionEnabled else {
            note = "The arm is not enabled — tap Enable first."
            return
        }
        // Playback is a motion sequence like any other: it must not run alongside a walk-to-neutral
        // or a back-out, or the two take turns commanding different targets and the arm jerks.
        guard !arm.motionBusy else {
            note = "The arm is busy — wait for it to finish."
            return
        }
        playing = motion
        step = 0
        defer { playing = nil; step = 0 }

        GlamaticLink.plog("arm motion “\(motion.name)”: \(motion.poses.count) poses")

        for (i, pose) in motion.poses.enumerated() {
            if Task.isCancelled { note = "Stopped."; return }
            step = i + 1
            let target = pose.normalised
            note = "Pose \(i + 1) of \(motion.poses.count) — \(pose.jointLabel)"

            // The rail leg first, so the carriage and the joints travel together rather than the
            // arm arriving and then the rail starting.
            if let mm = pose.clampedRail {
                if SafetyKernel.shared.canDrive {
                    _ = await rail.move(to: mm, velocity: 85)
                } else {
                    // Say so rather than skipping in silence — a movement authored with rail legs
                    // that quietly runs joints-only looks like the rail is broken.
                    note = "Pose \(i + 1): rail skipped — \(SafetyKernel.shared.blocker?.message ?? "not ready")"
                    GlamaticLink.plog("arm motion: rail leg skipped at pose \(i + 1)")
                }
            }

            guard await arm.moveJoints(target, speed: pose.speed, acc: pose.acc) else {
                note = "The arm refused pose \(i + 1)."
                GlamaticLink.plog("arm motion aborted: pose \(i + 1) refused")
                return
            }
            guard await arm.waitArrival(target) else {
                note = "Never reached pose \(i + 1)."
                GlamaticLink.plog("arm motion aborted: pose \(i + 1) not reached")
                return
            }
            if pose.dwell > 0 {
                note = String(format: "Holding %.2fs", pose.dwell)
                try? await Task.sleep(nanoseconds: UInt64(pose.dwell * 1_000_000_000))
            }
        }

        note = "Done."
        GlamaticLink.plog("arm motion “\(motion.name)” complete")
    }
}
