import SwiftUI

/// Try every candidate trigger sequence and watch the position to see which one moves the rail.
struct MoveDoctorView: View {
    @StateObject private var doctor = MoveDoctor.shared
    @StateObject private var link = GlamaticLink.shared
    @AppStorage("armcontrol.take.program") private var program = 1

    @State private var confirm = false

    var body: some View {
        List {
            Section {
                Stepper("Program \(program)", value: $program, in: 0...9)
                Button {
                    confirm = true
                } label: {
                    HStack {
                        Label(doctor.steps.isEmpty ? "Run the move test" : "Run it again",
                              systemImage: "play.circle")
                        Spacer()
                        if doctor.running { ProgressView() }
                    }
                }
                .disabled(doctor.running || !link.connected)
            } header: {
                Text("Move test")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Label("This moves the carriage. Stand clear and keep the physical E-stop in reach.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.bad)
                        .font(.footnote.weight(.medium))
                    Text("Every command the app sends is a write, and this PLC answers a write it will not act on with HTTP 200 and silence — so a command that does nothing looks exactly like one that worked. The only ground truth is the position readout. This tries each candidate sequence in turn and watches it.")
                    if !link.connected {
                        Text("Not connected — nothing to test.").foregroundStyle(Theme.warn)
                    }
                }
                .font(.footnote)
            }

            ForEach(doctor.steps) { step in
                Section {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: symbol(step))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(tint(step))
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(step.name).font(.body.weight(.medium))
                            Text(step.detail)
                                .font(.footnote)
                                .foregroundStyle(step.moved == true ? Theme.good : Theme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            if let conclusion = doctor.conclusion {
                Section {
                    Text(conclusion)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.label)
                        .fixedSize(horizontal: false, vertical: true)
                    ShareLink(item: doctor.export) {
                        Label("Send this result", systemImage: "square.and.arrow.up")
                    }
                } header: {
                    Text("What this means")
                }
            }
        }
        .navigationTitle("Why won't it move?")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Run the move test?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Move the rail", role: .destructive) {
                Task { await doctor.run(program: program) }
            }
        } message: {
            Text("The carriage will move. It tries up to six sequences, each with eight seconds of watching, so this takes about a minute.")
        }
    }

    private func symbol(_ s: MoveDoctor.Step) -> String {
        guard let moved = s.moved else { return "info.circle.fill" }
        return moved ? "checkmark.circle.fill" : "circle.dashed"
    }

    private func tint(_ s: MoveDoctor.Step) -> Color {
        guard let moved = s.moved else { return Theme.secondary }
        return moved ? Theme.good : Theme.warn
    }
}
