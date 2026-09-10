import SwiftUI

/// The endurance test, and the only place in the app that answers "will the link hold all night"
/// with a number instead of a shrug.
struct SoakView: View {
    @StateObject private var soak = LinkSoak.shared
    @StateObject private var link = GlamaticLink.shared
    @ObservedObject private var sim = GlamaticLink.shared.sim

    var body: some View {
        Form {
            if soak.running {
                runningSection
            } else {
                setupSection
            }

            if let report = soak.last, !soak.running {
                resultSection(report)
            }

            if link.simulated {
                faultInjectionSection
            }

            Section {
                LabeledContent("Reads OK", value: "\(link.readsOK)")
                LabeledContent("Silent") {
                    Text("\(link.readsSilent)")
                        .foregroundStyle(link.readsSilent > 0 ? Theme.warn : Theme.secondary)
                }
                LabeledContent("Expired sessions") {
                    Text("\(link.readsExpired)")
                        .foregroundStyle(link.readsExpired > 0 ? Theme.warn : Theme.secondary)
                }
                LabeledContent("Reconnects") {
                    Text("\(link.reconnects)")
                        .foregroundStyle(link.reconnects > 0 ? Theme.warn : Theme.secondary)
                }
            } header: {
                Text("Since launch")
            } footer: {
                Text("Running totals for the whole session, not just the last test. A healthy evening is all reads and no reconnects.")
            }
        }
        .navigationTitle("Link soak")
    }

    // MARK: Setup

    private var setupSection: some View {
        Section {
            Picker("Run for", selection: $soak.minutes) {
                ForEach([5, 10, 30, 60, 180], id: \.self) { m in
                    Text(m >= 60 ? "\(m / 60) hr" : "\(m) min").tag(m)
                }
            }

            Picker("Fire a program", selection: $soak.triggerEvery) {
                Text("Never").tag(0)
                ForEach([30, 60, 120, 300], id: \.self) { s in
                    Text(s >= 60 ? "every \(s / 60) min" : "every \(s)s").tag(s)
                }
            }

            Button {
                soak.start()
            } label: {
                Label("Start the soak", systemImage: "timer")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .listRowBackground(Color.clear)
            .disabled(!link.connected)
        } header: {
            Text("Endurance test")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Watches the link for the whole run and counts every telemetry read, every silent one, every expired session and every recovery. It adds no traffic of its own — the 3-second poll is the load being tested, and doubling it would measure a machine under stress it will never actually see.")
                if soak.triggerEvery > 0 {
                    Text("⚠️ THE RAIL WILL MOVE. It fires the booth's program \(soak.triggerEvery >= 60 ? "every \(soak.triggerEvery / 60) min" : "every \(soak.triggerEvery)s") for the whole run — keep the throw clear.")
                        .foregroundStyle(Theme.warn)
                }
                if !link.connected {
                    Text("Connect to the rail first.")
                        .foregroundStyle(Theme.bad)
                }
            }
        }
    }

    // MARK: Running

    private var runningSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(clock(soak.elapsed))
                        .font(.system(size: 40, weight: .semibold, design: .rounded).monospacedDigit())
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(clock(soak.remaining) + " left")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(Theme.secondary)
                        Text(link.connected ? "Link up" : "LINK DOWN")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(link.connected ? Theme.good : Theme.bad)
                    }
                }
                ProgressView(value: soak.progress)
                    .tint(soak.live.clean ? Theme.good : Theme.warn)
            }
            .padding(.vertical, 4)

            counters(soak.live)

            Button(role: .destructive) {
                soak.stop()
            } label: {
                DestructiveLabel("Stop and report", systemImage: "stop.fill")
            }
        } header: {
            Text("Running")
        } footer: {
            Text("Leave the app in the foreground — nothing polls the rail when it is off screen. The result is kept and written to History, so it is still there tomorrow.")
        }
    }

    private func counters(_ r: LinkSoak.Report) -> some View {
        Group {
            LabeledContent("Reads", value: "\(r.reads)")
            LabeledContent("Faults") {
                Text("\(r.faults)")
                    .foregroundStyle(r.faults > 0 ? Theme.warn : Theme.secondary)
            }
            LabeledContent("Reconnects") {
                Text("\(r.reconnects)")
                    .foregroundStyle(r.reconnects > 0 ? Theme.warn : Theme.secondary)
            }
            LabeledContent("Longest gap") {
                Text(String(format: "%.1fs", r.longestGap))
                    .monospacedDigit()
                    .foregroundStyle(r.longestGap > 15 ? Theme.warn : Theme.secondary)
            }
            if r.triggers > 0 || r.triggerFailures > 0 {
                LabeledContent("Programs fired") {
                    Text(r.triggerFailures > 0 ? "\(r.triggers) · \(r.triggerFailures) failed" : "\(r.triggers)")
                        .foregroundStyle(r.triggerFailures > 0 ? Theme.bad : Theme.secondary)
                }
            }
        }
    }

    // MARK: Result

    private func resultSection(_ r: LinkSoak.Report) -> some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: r.clean ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.title)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(r.clean ? Theme.good : Theme.warn)
                VStack(alignment: .leading, spacing: 3) {
                    Text(r.verdict)
                        .font(.subheadline.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(Int(r.duration))s run\(r.simulated ? " · simulated rail" : "") · \(r.startedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                }
            }
            .padding(.vertical, 2)

            counters(r)

            ShareLink(item: r.export) {
                Label("Export the report", systemImage: "square.and.arrow.up")
            }
        } header: {
            Text("Last run")
        } footer: {
            Text(r.simulated
                 ? "This one ran against the simulator, so it proves the app's recovery path — not the PLC's web server. Only a wired run against the real rail does that."
                 : "Kept across relaunches, so the result is still here tomorrow.")
                .foregroundStyle(r.simulated ? Theme.warn : Theme.secondary)
        }
    }

    // MARK: Fault injection

    private var faultInjectionSection: some View {
        Section {
            ValueSlider(title: "Drop reads",
                        value: $sim.dropRate,
                        range: 0...0.5, step: 0.05,
                        format: { $0 <= 0 ? "Never" : "\(Int($0 * 100))%" })

            ValueSlider(title: "Session expires",
                        value: $sim.expireAfter,
                        range: 0...300, step: 15,
                        format: { $0 <= 0 ? "Never" : "after \(Int($0))s" })
        } header: {
            Text("Inject link faults")
        } footer: {
            Text("The rail's mechanics are not what killed the old client — the S7-1200's web server was. These make the simulator fail the way the LINK fails, so the silent-read counter, the expired-session branch and the whole auto-reconnect path get exercised indoors instead of being code nobody has ever run. Three silent reads in a row drop the link; an expired session drops it immediately.")
        }
    }

    private func clock(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
