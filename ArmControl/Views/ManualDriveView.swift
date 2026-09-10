import SwiftUI

/// Manual position and velocity drive, clamped to the PLC's own limits.
///
/// On speed ramping, so nobody rebuilds this expecting more than it can give: the PLC owns its
/// motion profile. The only levers exposed are an absolute Position and a Velocety clamped to
/// 70–100 mm/s — a 1.43:1 range. Cinematic slow-in/slow-out is bought in post, not here. This
/// screen is for setup, framing and recovery.
struct ManualDriveView: View {
    @StateObject private var link = GlamaticLink.shared
    @StateObject private var safety = SafetyKernel.shared

    @State private var target: Double = 300
    @State private var velocity: Double = 85
    @State private var note: String?

    var body: some View {
        Form {
            Section {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(Int(target))")
                        .font(.system(size: 46, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("mm")
                        .font(.title3)
                        .foregroundStyle(Theme.secondary)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Live")
                            .font(.caption)
                            .foregroundStyle(Theme.tertiary)
                        Text("\(Int(link.state.currentMM)) mm")
                            .font(.title3.weight(.medium).monospacedDigit())
                            .foregroundStyle(Theme.secondary)
                    }
                }
                Slider(value: $target, in: PLC.positionRange, step: 5) {
                    Text("Position")
                } minimumValueLabel: {
                    Text("0").font(.caption2).foregroundStyle(Theme.tertiary)
                } maximumValueLabel: {
                    Text("600").font(.caption2).foregroundStyle(Theme.tertiary)
                }
            } header: {
                Text("Position")
            }

            Section {
                ValueSlider(title: "Speed",
                            value: $velocity,
                            range: PLC.velocityRange,
                            format: { "\(Int($0)) mm/s" },
                            footnote: "The PLC clamps this to 70–143 mm/s. Values outside are refused or faulted.")
            } header: {
                Text("Speed")
            }

            Section {
                Button {
                    Task {
                        let ok = await link.move(to: target, velocity: velocity)
                        note = ok ? "Move sent." : "Move rejected — check Arm and the PLC login."
                    }
                } label: {
                    Label("Go to \(Int(target)) mm", systemImage: "arrow.right.to.line")
                }
                .disabled(!safety.canDrive)

            } footer: {
                if !safety.canDrive, let b = safety.blocker {
                    Text(b.message).foregroundStyle(Theme.warn)
                } else if let note {
                    Text(note)
                }
            }
        }
        .onAppear { target = min(600, max(0, link.state.currentMM)) }
    }
}
