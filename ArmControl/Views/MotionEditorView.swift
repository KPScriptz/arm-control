import SwiftUI

/// Shape a movement — where it goes, how fast, how long it waits — and watch the change as you
/// make it.
///
/// 🔑 **Why the preview sits at the top and never moves.** Every control below rewrites the curve,
/// and a number only means something once you have seen what it does to the carriage. Dragging a
/// speed slider with the rail redrawing above it is the entire point; putting the preview behind a
/// button would make this the same guessing game as editing the PLC's own programs.
///
/// ⚠️ This edits an **app-driven** motion, never a stored PLC program — those are compiled logic
/// and cannot be altered. `CustomMotion.from(trace:)` is how a recorded preset becomes something
/// editable in the first place.
struct MotionEditorView: View {
    @StateObject private var store = MotionStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var motion: CustomMotion
    @State private var confirmRun = false

    /// The recorded original this was copied from, drawn as a ghost behind the curve so an edit
    /// can be judged against what the machine actually does.
    private let ghost: MotionTrace?

    /// Edits a copy; nothing is written until Save.
    init(motion: CustomMotion, ghost: MotionTrace? = nil) {
        _motion = State(initialValue: motion)
        self.ghost = ghost
    }

    private var trace: MotionTrace { .synthesised(from: motion) }

    var body: some View {
        List {
            Section {
                // Rebuilt on every edit — the synthesis is exact and costs microseconds.
                VirtualArm(trace: trace, title: motion.name)
                    .padding(.vertical, 6)
            } footer: {
                Text("Play it above to watch the carriage run the edit.")
                    .font(.footnote)
            }

            Section {
                MotionCurveEditor(motion: $motion, ghost: ghost)
                    .padding(.vertical, 4)
            } header: {
                Text("Shape it")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Drag a point **up or down** to change where that leg travels to, **left or right** to change how long it takes — which is its speed.")
                    if ghost != nil {
                        Text("The dashed line is the original recorded movement, for comparison.")
                            .foregroundStyle(Theme.secondary)
                    }
                    Text("A point stops moving sideways at the rail's own 70–143 mm/s limit, so the curve can never show a speed the machine cannot reach.")
                        .foregroundStyle(Theme.secondary)
                    Text(String(format: "%.1fs from home, %.0f–%.0f mm, fastest %.0f mm/s.",
                                motion.duration(from: 0),
                                trace.minMM, trace.maxMM, trace.peakSpeed))
                        .monospacedDigit()
                        .foregroundStyle(Theme.label)
                }
                .font(.footnote)
            }


            Section {
                TextField("Name", text: $motion.name)
            }

            ForEach(Array(motion.waypoints.enumerated()), id: \.offset) { i, _ in
                Section {
                    ValueSlider(title: "Go to",
                                value: binding(i, \.position),
                                range: PLC.positionRange, step: 5,
                                format: { String(format: "%.0f mm", $0) })
                    ValueSlider(title: "Speed",
                                value: binding(i, \.velocity),
                                range: PLC.velocityRange, step: 1,
                                format: { String(format: "%.0f mm/s", $0) })
                    ValueSlider(title: "Then wait",
                                value: binding(i, \.dwell),
                                range: 0...3, step: 0.05,
                                format: { $0 < 0.025 ? "No pause" : String(format: "%.2fs", $0) })

                    if motion.waypoints.count > 1 {
                        Button(role: .destructive) {
                            guard motion.waypoints.indices.contains(i) else { return }
                            motion.waypoints.remove(at: i)
                        } label: {
                            DestructiveLabel("Remove this leg", systemImage: "minus.circle")
                        }
                    }
                } header: {
                    Text("Leg \(i + 1)")
                } footer: {
                    if motion.waypoints.indices.contains(i) {
                        let w = motion.waypoints[i]
                        let from = i == 0 ? 0 : motion.waypoints[i - 1].clampedPosition
                        let seconds = abs(w.clampedPosition - from) / w.clampedVelocity
                        Text(String(format: "%.0f mm of travel, %.1fs.",
                                    abs(w.clampedPosition - from), seconds))
                            .font(.footnote.monospacedDigit())
                    }
                }
            }

            Section {
                Button {
                    let last = motion.waypoints.last
                    motion.waypoints.append(
                        MotionWaypoint(position: (last?.clampedPosition ?? 0) > 300 ? 0 : 600,
                                       velocity: last?.clampedVelocity ?? 85,
                                       dwell: 0))
                } label: {
                    Label("Add a leg", systemImage: "plus.circle")
                }
            } footer: {
                Text("The rail's own clamp is 70–143 mm/s — measured, not documented. The cinematic speed range is still bought afterwards, in the ramp profile.")
                    .font(.footnote)
            }

            Section {
                Button {
                    store.save(motion)
                    dismiss()
                } label: {
                    Label("Save", systemImage: "checkmark.circle.fill")
                        .font(.body.weight(.semibold))
                }
                Button {
                    confirmRun = true
                } label: {
                    Label("Try it on the rail", systemImage: "play.circle")
                }
                .disabled(!canRun)
            } footer: {
                if let reason = blocker {
                    Text(reason).font(.footnote).foregroundStyle(Theme.warn)
                }
            }
        }
        .navigationTitle("Edit movement")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Run this on the rail?", isPresented: $confirmRun,
                            titleVisibility: .visible) {
            Button("Move the rail", role: .destructive) {
                Task { await store.play(motion) }
            }
        } message: {
            Text(String(format: "The carriage moves for about %.0f seconds. Stand clear.",
                        motion.duration(from: 0)))
        }
    }

    /// 🐞 Index-checked on both ends. `ForEach` over `enumerated()` identifies rows by INDEX, and
    /// SwiftUI evaluates a departing row's body once more against the old index before the diff
    /// settles — so an unguarded `waypoints[i]` traps the moment a leg is removed. Same bug that
    /// crashed the ramp-profile editor.
    private func binding(_ i: Int, _ path: WritableKeyPath<MotionWaypoint, Double>) -> Binding<Double> {
        Binding(
            get: { motion.waypoints.indices.contains(i) ? motion.waypoints[i][keyPath: path] : 0 },
            set: { new in
                guard motion.waypoints.indices.contains(i) else { return }
                motion.waypoints[i][keyPath: path] = new
            })
    }

    private var canRun: Bool {
        GlamaticLink.shared.connected && SafetyKernel.shared.armed
            && GlamaticLink.shared.state.isHomed && !store.isPlaying
    }

    private var blocker: String? {
        if store.isPlaying { return "Running…" }
        if !GlamaticLink.shared.connected { return "Not connected — editing and previewing still work." }
        if !SafetyKernel.shared.armed { return "Arm the rail before trying it." }
        if !GlamaticLink.shared.state.isHomed { return "The rail is not referenced. Home it first." }
        return nil
    }
}
