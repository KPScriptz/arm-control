import SwiftUI

/// Named moves the app drives itself, waypoint by waypoint.
struct MotionsView: View {
    @StateObject private var store = MotionStore.shared
    @StateObject private var link = GlamaticLink.shared
    @StateObject private var safety = SafetyKernel.shared

    @State private var confirmPlay: CustomMotion?

    private var here: Double { Double(link.state.currentPosition) ?? 0 }

    var body: some View {
        List {
            if store.isPlaying {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        VStack(alignment: .leading, spacing: 2) {
                            Text(store.playing?.name ?? "Running")
                                .font(.body.weight(.medium))
                            Text(store.progressNote)
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(Theme.secondary)
                        }
                    }
                }
            }

            ForEach(store.motions) { motion in
                Section {
                    ForEach(Array(motion.waypoints.enumerated()), id: \.offset) { i, w in
                        LabeledContent {
                            Text(String(format: "%.0f mm/s%@", w.clampedVelocity,
                                        w.dwell > 0 ? String(format: " · hold %.2fs", w.dwell) : ""))
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(Theme.secondary)
                        } label: {
                            Text("Leg \(i + 1) → \(Int(w.clampedPosition)) mm")
                        }
                    }
                    NavigationLink {
                        MotionEditorView(motion: motion)
                    } label: {
                        Label("Edit the trajectory", systemImage: "slider.horizontal.3")
                    }
                    Button {
                        confirmPlay = motion
                    } label: {
                        Label("Run it", systemImage: "play.fill")
                    }
                    .disabled(!canRun)
                    Button(role: .destructive) {
                        store.delete(motion)
                    } label: {
                        DestructiveLabel("Delete", systemImage: "trash")
                    }
                } header: {
                    Text(motion.name)
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(format: "%.1fs from where the carriage is now (%.0f mm), travelling %.0f–%.0f mm.",
                                    motion.duration(from: here), here,
                                    motion.throwRange.min, motion.throwRange.max))
                            .monospacedDigit()
                        if let reason = blocker {
                            Text(reason).foregroundStyle(Theme.warn)
                        }
                    }
                    .font(.footnote)
                }
            }

            Section {
                NavigationLink {
                    MotionEditorView(motion: CustomMotion(
                        name: "New movement",
                        waypoints: [MotionWaypoint(position: 600, velocity: 85, dwell: 0),
                                    MotionWaypoint(position: 0, velocity: 85, dwell: 0)]))
                } label: {
                    Label("New movement", systemImage: "plus.circle")
                }
            }

            Section {
                Text("These are driven by the app over the Position and Velocity tags, not stored in the PLC — so they work whether or not a stored program triggers, and they can be shaped to a reference clip.")
                Text("The rail's own 70–143 mm/s clamp still applies. A motion controls where the carriage is and when; the speed ramp is applied afterwards in Post.")
                    .foregroundStyle(Theme.secondary)
            } footer: {
                Text("Whalefall is a 600 mm out-and-back at 85 mm/s with a 0.25s beat at the far end — 14.1s in total, which is what the Whalefall ramp profile is authored against.")
            }
            .font(.footnote)
        }
        .navigationTitle("Custom motions")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Run this motion?",
                            isPresented: Binding(get: { confirmPlay != nil },
                                                 set: { if !$0 { confirmPlay = nil } }),
                            titleVisibility: .visible) {
            Button("Move the rail", role: .destructive) {
                if let m = confirmPlay { Task { await store.play(m) } }
                confirmPlay = nil
            }
        } message: {
            if let m = confirmPlay {
                Text(String(format: "“%@” moves the carriage for about %.0f seconds. Stand clear.",
                            m.name, m.duration(from: here)))
            }
        }
    }

    private var canRun: Bool {
        link.connected && safety.armed && link.state.isHomed && !store.isPlaying
    }

    /// Never a silent disabled button — the rule this app is built on.
    private var blocker: String? {
        if store.isPlaying { return nil }
        if !link.connected { return "Not connected to the rail." }
        if !safety.armed { return "Arm the rail first — a motion drives it directly." }
        if !link.state.isHomed { return "The rail is not referenced. Home it first." }
        return nil
    }
}
