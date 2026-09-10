import SwiftUI

/// Edit one captured pose.
///
/// 🔑 **Capturing a pose is not the same as being finished with it.** The first version could only
/// append and delete, so getting a move right meant deleting a pose, re-jogging the whole arm and
/// keeping it again — and doing that for pose 2 of 5 meant redoing 3, 4 and 5 as well, because the
/// arm was no longer where those were taught from. Every joint, the speed and the hold are editable
/// here, and **Show me** drives the arm to the pose so a number can be judged by looking at the arm
/// rather than by imagining it.
struct PoseEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var arm = XArmLink.shared
    @StateObject private var store = ArmMotionStore.shared

    @State var pose: ArmPose
    /// Which position in the sequence this is, for the title.
    let index: Int

    @State private var previewing = false
    @State private var railOn: Bool

    init(pose: ArmPose, index: Int) {
        _pose = State(initialValue: pose)
        _railOn = State(initialValue: pose.rail != nil)
        self.index = index
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(0..<XArmLink.jointCount, id: \.self) { i in
                        jointRow(i)
                    }
                } header: {
                    Text("Joints")
                } footer: {
                    Text("Live arm position: \(liveLabel)")
                        .font(.caption.monospacedDigit())
                }

                Section {
                    Button {
                        // Re-teach this pose from where the arm is standing now — the fastest way
                        // to fix one beat of a move without redoing the ones after it.
                        var j = arm.joints
                        while j.count < XArmLink.jointCount { j.append(0) }
                        pose.joints = Array(j.prefix(XArmLink.jointCount))
                    } label: {
                        Label("Use the arm's current position", systemImage: "arrow.down.to.line")
                    }
                    .disabled(arm.joints.isEmpty)

                    Button {
                        previewing = true
                        Task {
                            await store.preview(pose)
                            previewing = false
                        }
                    } label: {
                        Label(previewing ? "Moving…" : "Show me — move the arm here",
                              systemImage: "eye")
                    }
                    .disabled(!arm.motionEnabled || previewing)

                    if !arm.motionEnabled {
                        Text("Enable the arm to move it to this pose.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("Timing") {
                    LabeledContent("Speed") {
                        Text("\(Int(pose.speed))°/s").monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: $pose.speed, in: 5...FactoryPrograms.maxSpeed, step: 1)

                    LabeledContent("Hold on arrival") {
                        Text(String(format: "%.2fs", pose.dwell)).monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $pose.dwell, in: 0...3, step: 0.05)
                }

                Section {
                    Toggle("Also move the rail", isOn: $railOn)
                    if railOn {
                        LabeledContent("Carriage") {
                            Text("\(Int(pose.rail ?? 0)) mm").monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(get: { pose.rail ?? 0 },
                                              set: { pose.rail = $0 }),
                               in: PLC.positionRange, step: 5)
                    }
                } header: {
                    Text("The rail")
                } footer: {
                    // ⚠️ Say plainly that this is a second machine with its own preconditions,
                    // rather than letting a silently-skipped leg look like a broken rail.
                    Text(railOn
                         ? "The carriage moves with this pose. It is skipped — and says so — unless the rail is connected, armed and homed."
                         : "Off: this pose leaves the carriage alone.")
                }
            }
            .navigationTitle("Pose \(index)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if !railOn { pose.rail = nil }
                        store.updatePose(pose)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private var liveLabel: String {
        guard !arm.joints.isEmpty else { return "not connected" }
        return arm.joints.prefix(XArmLink.jointCount).enumerated()
            .map { "J\($0.offset + 1) \(Int($0.element.rounded()))°" }
            .joined(separator: " · ")
    }

    private func jointRow(_ i: Int) -> some View {
        var j = pose.joints
        while j.count < XArmLink.jointCount { j.append(0) }
        let value = j[i]
        return HStack(spacing: 12) {
            Text("J\(i + 1)")
                .font(.subheadline.weight(.semibold))
                .frame(width: 34, alignment: .leading)
            Text("\(Int(value.rounded()))°")
                .font(.body.monospacedDigit())
                .frame(width: 60, alignment: .trailing)
            Spacer()
            Stepper("") {
                setJoint(i, value + 1)
            } onDecrement: {
                setJoint(i, value - 1)
            }
            .labelsHidden()
            Button {
                setJoint(i, value - 15)
            } label: {
                Text("−15").font(.caption.weight(.semibold)).frame(width: 44)
            }
            .buttonStyle(.bordered)
            Button {
                setJoint(i, value + 15)
            } label: {
                Text("+15").font(.caption.weight(.semibold)).frame(width: 44)
            }
            .buttonStyle(.bordered)
        }
    }

    private func setJoint(_ i: Int, _ v: Double) {
        var j = pose.joints
        while j.count < XArmLink.jointCount { j.append(0) }
        j[i] = v
        pose.joints = j
    }
}
