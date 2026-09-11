import SwiftUI

// MARK: - Edit one program, one pose at a time
//
// 🔑 **"THIS ALL FEELS COMPLICATED. I NEED THE PROCESS TO BE A LOT SIMPLER."** The Arm tab grew
// five cards and a 28-row library, and the one thing an operator does — open program 14, change a
// beat of it, watch the arm, play it — was buried under connect/enable/neutral/record/timeline.
//
// This screen is that one thing. One pose on screen at a time, big. Joints named for what they DO
// (pan, lift, bend, tilt, roll) with arrows for which way each button sends them, because "J3"
// tells you nothing when you are standing next to the machine. What has changed from the factory
// version is spelled out under the pose, and putting it back is a labelled button rather than an
// icon you have to guess at.
//
// The advanced machinery is still one tab over. It is simply not in the way here.
struct ProgramEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var arm = XArmLink.shared
    @StateObject private var store = ArmMotionStore.shared

    @State private var motion: ArmMotion
    @State private var index = 0
    @State private var previewing = false
    @State private var dirty = false
    @State private var confirmReset = false

    init(motion: ArmMotion) {
        _motion = State(initialValue: motion)
    }

    /// What each joint does on this rig, and which way the arrows point.
    ///
    /// xArm 5 joint order: base rotation, shoulder, elbow, wrist pitch, wrist roll. The words are
    /// what a camera operator would say; the symbols are the direction the + button sends it.
    private static let jointGuide: [(name: String, minus: String, plus: String)] = [
        ("Pan",  "arrow.turn.up.left",  "arrow.turn.up.right"),
        ("Lift", "arrow.down",          "arrow.up"),
        ("Bend", "arrow.down.right",    "arrow.up.left"),
        ("Tilt", "arrow.down",          "arrow.up"),
        ("Roll", "arrow.counterclockwise", "arrow.clockwise"),
    ]

    private var factory: ArmMotion? {
        motion.program.flatMap { FactoryPrograms.program($0) }
    }

    private var pose: ArmPose {
        guard motion.poses.indices.contains(index) else {
            return ArmPose(joints: Array(repeating: 0, count: XArmLink.jointCount))
        }
        return motion.poses[index]
    }

    private var factoryPose: ArmPose? {
        guard let f = factory, f.poses.indices.contains(index) else { return nil }
        return f.poses[index]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    poseHeader
                    jointsCard
                    timingCard
                    changesCard
                    actions
                }
                .padding()
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .navigationTitle(motion.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(dirty ? "Cancel" : "Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.save(motion)
                        dirty = false
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(!dirty)
                }
            }
            .task { arm.startPolling() }
            .onDisappear { arm.stopPolling() }
            .confirmationDialog("Put \(motion.name) back to the factory version?",
                                isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Reset to factory", role: .destructive) {
                    if let n = motion.program {
                        store.restoreFactory(n)
                        if let fresh = FactoryPrograms.program(n) { motion = fresh }
                        dirty = false
                        index = min(index, max(0, motion.poses.count - 1))
                    }
                }
                Button("Keep my changes", role: .cancel) { }
            } message: {
                Text("Every pose goes back to exactly what the arm shipped with. Your edits to this program are discarded.")
            }
        }
    }

    // MARK: Which pose

    private var poseHeader: some View {
        HStack(spacing: 16) {
            Button {
                index = max(0, index - 1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.title2.weight(.semibold))
                    .frame(width: 56, height: 56)
            }
            .buttonStyle(.bordered)
            .disabled(index == 0)

            VStack(spacing: 4) {
                Text("Pose \(index + 1) of \(motion.poses.count)")
                    .font(.title2.weight(.bold))
                Text(beatDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)

            Button {
                index = min(motion.poses.count - 1, index + 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.title2.weight(.semibold))
                    .frame(width: 56, height: 56)
            }
            .buttonStyle(.bordered)
            .disabled(index >= motion.poses.count - 1)
        }
    }

    /// "First pose" / "Last pose" / "Hold 0.3s here" — what this beat IS, not just its number.
    private var beatDescription: String {
        if index == 0 { return "Where the move starts" }
        if index == motion.poses.count - 1 { return "Where the move ends" }
        if pose.dwell > 0.05 { return String(format: "Holds here for %.1fs", pose.dwell) }
        return "Passes through"
    }

    // MARK: The joints

    private var jointsCard: some View {
        VStack(spacing: 0) {
            ForEach(0..<XArmLink.jointCount, id: \.self) { i in
                jointRow(i)
                if i < XArmLink.jointCount - 1 { Divider().padding(.leading, 16) }
            }
        }
        .pivotGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func jointRow(_ i: Int) -> some View {
        let guide = Self.jointGuide[i]
        let value = pose.normalised[i]
        let was = factoryPose?.normalised[i]
        let changed = was.map { abs($0 - value) > 0.5 } ?? false

        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(guide.name)
                    .font(.headline)
                Text("J\(i + 1)")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .frame(width: 64, alignment: .leading)

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(Int(value.rounded()))°")
                    .font(.title2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(changed ? Pivot.caution : .primary)
                if changed, let was {
                    Text("was \(Int(was.rounded()))°")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Pivot.caution)
                }
            }
            .frame(width: 84, alignment: .trailing)

            Spacer()

            // The arrows ARE the explanation: this button sends Pan left, that one sends Lift up.
            nudge(i, -5, guide.minus)
            nudge(i, -1, "minus")
            nudge(i, +1, "plus")
            nudge(i, +5, guide.plus)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func nudge(_ i: Int, _ delta: Double, _ symbol: String) -> some View {
        Button {
            var j = pose.normalised
            j[i] += delta
            var p = pose
            p.joints = j
            replacePose(p)
        } label: {
            VStack(spacing: 2) {
                Image(systemName: symbol).font(.headline)
                Text(delta > 0 ? "+\(Int(delta))" : "\(Int(delta))")
                    .font(.caption2.monospacedDigit())
            }
            .frame(width: 50, height: 50)
        }
        .buttonStyle(.bordered)
    }

    // MARK: Timing

    private var timingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Speed to get here").font(.subheadline)
                Spacer()
                Text("\(Int(pose.speed))°/s")
                    .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { pose.speed },
                                  set: { var p = pose; p.speed = $0; replacePose(p) }),
                   in: 5...FactoryPrograms.maxSpeed, step: 5)

            HStack {
                Text("Hold here").font(.subheadline)
                Spacer()
                Text(String(format: "%.1fs", pose.dwell))
                    .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { pose.dwell },
                                  set: { var p = pose; p.dwell = $0; replacePose(p) }),
                   in: 0...3, step: 0.1)
        }
        .padding()
        .pivotGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: What changed

    @ViewBuilder
    private var changesCard: some View {
        if let f = factory {
            let diffs = changesFromFactory(f)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(diffs.isEmpty ? "Matches the factory version" : "Changed from factory",
                          systemImage: diffs.isEmpty ? "checkmark.seal" : "pencil.line")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(diffs.isEmpty ? Pivot.mint : Pivot.caution)
                    Spacer()
                    if !diffs.isEmpty {
                        Button("Reset to factory") { confirmReset = true }
                            .font(.subheadline)
                            .foregroundStyle(Pivot.danger)
                    }
                }
                ForEach(diffs, id: \.self) { d in
                    Text("• \(d)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .pivotGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    /// Every difference from the factory version, across ALL poses, in words.
    private func changesFromFactory(_ f: ArmMotion) -> [String] {
        var out: [String] = []
        if motion.poses.count != f.poses.count {
            out.append("Now \(motion.poses.count) poses, factory has \(f.poses.count)")
        }
        for (i, (a, b)) in zip(motion.poses, f.poses).enumerated() {
            for j in 0..<XArmLink.jointCount {
                let x = a.normalised[j], y = b.normalised[j]
                if abs(x - y) > 0.5 {
                    out.append("Pose \(i + 1) \(Self.jointGuide[j].name): \(Int(y.rounded()))° → \(Int(x.rounded()))°")
                }
            }
            if abs(a.speed - b.speed) > 0.5 {
                out.append("Pose \(i + 1) speed: \(Int(b.speed)) → \(Int(a.speed))°/s")
            }
            if abs(a.dwell - b.dwell) > 0.05 {
                out.append(String(format: "Pose %d hold: %.1fs → %.1fs", i + 1, b.dwell, a.dwell))
            }
        }
        return out
    }

    // MARK: Actions

    private var actions: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    previewing = true
                    Task {
                        await store.preview(pose)
                        previewing = false
                    }
                } label: {
                    Label(previewing ? "Moving…" : "Show me this pose", systemImage: "eye")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!arm.motionEnabled || previewing || store.isPlaying)

                Button {
                    store.save(motion)
                    dirty = false
                    store.start(motion)
                } label: {
                    Label("Play the whole move", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!arm.motionEnabled || store.isPlaying)
            }

            // 🔑 The note stays after playback ends. "Play did nothing" was the report, and the
            // reason WHY was in a string that vanished the instant playback returned.
            if !store.note.isEmpty {
                HStack(alignment: .top) {
                    Text(store.note)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(store.note.hasPrefix("Won't") || store.note.contains("NOT")
                                         || store.note.contains("REFUSED") ? Pivot.danger : Pivot.caution)
                    Spacer()
                    if store.isPlaying {
                        Button {
                            store.stop()
                        } label: {
                            Label("STOP", systemImage: "stop.fill").font(.subheadline.weight(.bold))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Pivot.danger)
                    }
                }
            }

            // What the CONTROLLER says, next to what the app believes.
            Text("Arm reports: \(arm.stateText)\(arm.errorCode != 0 ? " · fault \(arm.errorCode)" : "")\(arm.simulated ? " · SIMULATED" : "")")
                .font(.caption.monospacedDigit())
                .foregroundStyle(arm.armState == 4 || arm.armState == 3 || arm.errorCode != 0 ? Pivot.danger : .secondary)

            if !arm.motionEnabled {
                // The reason, not a grey button.
                Text(arm.connected
                     ? "Enable the arm on the Arm tab to see poses move."
                     : "Connect the arm on the Arm tab to see poses move.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func replacePose(_ p: ArmPose) {
        guard motion.poses.indices.contains(index) else { return }
        motion.poses[index] = p
        dirty = true
    }
}
