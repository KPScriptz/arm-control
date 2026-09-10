import SwiftUI

/// Which layer of the rail connection is broken — route, raw port, TLS, session, login.
struct LinkDoctorView: View {
    @StateObject private var doctor = LinkDoctor.shared

    var body: some View {
        List {
            Section {
                Button {
                    Task { await doctor.run() }
                } label: {
                    HStack {
                        Label(doctor.steps.isEmpty ? "Check the connection" : "Check again",
                              systemImage: "stethoscope")
                        Spacer()
                        if doctor.running { ProgressView() }
                    }
                }
                .disabled(doctor.running)
            } footer: {
                Text("Tests each layer between this iPad and the rail separately. Nothing here moves the carriage.")
            }

            ForEach(doctor.steps) { step in
                Section {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: symbol(step.verdict))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(tint(step.verdict))
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(step.name)
                                .font(.body.weight(.medium))
                            Text(step.detail)
                                .font(.footnote.monospaced())
                                .foregroundStyle(Theme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let remedy = step.remedy {
                                Text(remedy)
                                    .font(.footnote)
                                    .foregroundStyle(Theme.warn)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            // The fix is in Settings, so put Settings one tap away rather than
                            // describing where it lives.
                            if let link = step.settingsLink {
                                Link(destination: link) {
                                    Label("Open Settings", systemImage: "gear")
                                        .font(.footnote.weight(.medium))
                                }
                                .buttonStyle(.borderedProminent)
                                .padding(.top, 2)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            if !doctor.steps.isEmpty, !doctor.running {
                Section {
                    ShareLink(item: doctor.export) {
                        Label("Send this result", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .navigationTitle("Connection check")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func symbol(_ v: LinkDoctor.Verdict) -> String {
        switch v {
        case .pass: return "checkmark.circle.fill"
        case .fail: return "xmark.octagon.fill"
        case .skip: return "minus.circle"
        }
    }

    private func tint(_ v: LinkDoctor.Verdict) -> Color {
        switch v {
        case .pass: return Theme.good
        case .fail: return Theme.bad
        case .skip: return Theme.secondary
        }
    }
}
