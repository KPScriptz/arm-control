import SwiftUI

/// The one screen a technician opens before the doors open.
///
/// It is a report, not an installer: every repair is a labelled button someone taps. The verdict at
/// the top is the only thing most people will read, so it says what to do rather than a score.
struct PreflightView: View {
    @StateObject private var link = GlamaticLink.shared
    @StateObject private var safety = SafetyKernel.shared
    @StateObject private var recorder = Recorder.shared
    @StateObject private var delivery = DeliveryServer.shared
    @StateObject private var kiosk = Kiosk.shared
    @StateObject private var store = ProgramStore.shared
    @StateObject private var booth = BoothSettings.shared
    @StateObject private var timer = MoveTimer.shared
    @StateObject private var health = DeviceHealth.shared

    /// Bumped after a fix. Most of the checks hang off observed objects and refresh themselves, but
    /// free disk space and the two permission statuses are plain system reads with nothing to
    /// observe — without this they would still show the old answer right after being fixed.
    @State private var nonce = 0
    @State private var working: String?

    var body: some View {
        // Reading `nonce` here is what ties the plain system reads (disk space, the two permission
        // statuses) to the re-check button — they have no publisher to observe.
        let _ = nonce
        List {
            verdict

            ForEach(Preflight.groups) { group in
                Section(group.title) {
                    ForEach(group.checks) { check in
                        row(check)
                    }
                }
            }
        }
        .navigationTitle("Pre-flight")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    nonce += 1
                } label: {
                    Label("Re-check", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    // MARK: Verdict

    private var verdict: some View {
        let level = Preflight.level
        return Section {
            HStack(spacing: 14) {
                Image(systemName: level.symbol)
                    .font(.system(size: 34))
                    .foregroundStyle(level.tint)
                    .symbolRenderingMode(.hierarchical)

                VStack(alignment: .leading, spacing: 3) {
                    Text(Preflight.summary)
                        .font(.title3.weight(.semibold))
                    Text(level == .pass
                         ? "Everything the booth needs is in place."
                         : "Work down the list. Anything red stops a take.")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
        }
    }

    // MARK: Row

    private func row(_ check: Preflight.Check) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: check.level.symbol)
                .font(.body)
                .foregroundStyle(check.level.tint)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 22)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(check.title)
                    .font(.body.weight(check.level == .pass ? .regular : .semibold))
                // Always present. A row that says only "Not homed" tells an operator nothing they
                // can act on, and a grey button with no reason beside it is what gets tapped
                // eleven times.
                Text(check.detail)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if let fix = check.fix {
                Button {
                    working = check.id
                    Task {
                        await fix.run()
                        working = nil
                        nonce += 1
                    }
                } label: {
                    if working == check.id {
                        ProgressView()
                    } else {
                        Text(fix.label)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(working != nil)
                .frame(minWidth: 64)
            }
        }
        .padding(.vertical, 2)
    }
}
