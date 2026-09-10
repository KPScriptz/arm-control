import SwiftUI

/// Times each stored program against the real carriage, and turns the answer into the Traverse.
///
/// The whole screen exists to replace one guess. Until now "how long is the move" was a slider
/// somebody set by eye, and every ramp-profile timing downstream inherited that guess.
struct MoveTimingView: View {
    @StateObject private var timer = MoveTimer.shared
    @StateObject private var store = ProgramStore.shared
    @StateObject private var safety = SafetyKernel.shared
    @StateObject private var link = GlamaticLink.shared

    @AppStorage("armcontrol.take.program") private var boothProgram = 1
    @AppStorage("armcontrol.take.seconds") private var traverse = 6.0

    @State private var confirming: Int?
    @State private var applied: Int?

    var body: some View {
        Form {
            if let blocker = safety.blocker {
                Section {
                    Label(blocker.message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.warn)
                } footer: {
                    Text("Timing a move triggers it. The rail has to be connected, homed and armed first.")
                }
            }

            Section {
                ForEach(store.presets) { preset in
                    row(preset)
                }
            } header: {
                Text("The eight programs")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("⚠️ THE RAIL MOVES. Timing a program runs it, at full throw, from wherever the carriage is now. Keep the rail clear.")
                        .foregroundStyle(Theme.warn)
                    Text("The PLC gives no “finished” signal, so this watches CurrentPosition instead: it fires the program, waits for the carriage to start, and times it until it stays put. \(MoveTimer.accuracyNote)")
                }
            }

            if !timer.results.isEmpty {
                Section {
                    Button(role: .destructive) {
                        timer.forgetAll()
                        applied = nil
                    } label: {
                        DestructiveLabel("Forget every measurement", systemImage: "trash")
                    }
                } footer: {
                    Text("Measurements are per program and survive a relaunch. Re-time a program after anyone edits it on the PLC — the app cannot tell that it changed.")
                }
            }

            Section {
                LabeledContent("Traverse in Capture") {
                    Text(String(format: "%.1fs", traverse)).monospacedDigit()
                }
                LabeledContent("Booth fires") {
                    Text("Program \(boothProgram)").foregroundStyle(Theme.secondary)
                }
            } header: {
                Text("Currently")
            } footer: {
                Text(currentFooter)
                    .foregroundStyle(currentFooterTint)
            }
        }
        .navigationTitle("Time the moves")
        .confirmationDialog(confirming.map { "Run program \($0) now?" } ?? "",
                            isPresented: Binding(get: { confirming != nil },
                                                 set: { if !$0 { confirming = nil } }),
                            titleVisibility: .visible) {
            Button("Run it", role: .destructive) {
                if let n = confirming { Task { await timer.measure(program: n) } }
                confirming = nil
            }
            Button("Cancel", role: .cancel) { confirming = nil }
        } message: {
            Text("The carriage will move through this program's full throw. Make sure nobody is near the rail.")
        }
    }

    // MARK: Row

    @ViewBuilder
    private func row(_ preset: ProgramStore.Preset) -> some View {
        let m = timer.results[preset.number]
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(preset.number)")
                    .font(.body.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 20, alignment: .leading)

                Text(preset.display)
                    .font(.body)

                Spacer(minLength: 8)

                if timer.measuring == preset.number {
                    ProgressView()
                } else {
                    Button("Time it") { confirming = preset.number }
                        .buttonStyle(.bordered)
                        .disabled(timer.measuring != nil || !safety.canTriggerProgram)
                }
            }

            if timer.measuring == preset.number, !timer.progress.isEmpty {
                Text(timer.progress)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(Theme.accent)
            } else if let m {
                measurementDetail(m)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func measurementDetail(_ m: MoveTimer.Measurement) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                stat("Move", String(format: "%.1fs", m.duration))
                stat("To start", String(format: "%.1fs", m.latency))
                stat("Throw", String(format: "%.0f mm", m.throwMM))
            }

            if !m.returnedToStart {
                Text("Ends away from where it started — the next take begins from there, not from home.")
                    .font(.caption)
                    .foregroundStyle(Theme.warn)
            }
            if m.simulated {
                Text("Measured against the simulator, not the rail.")
                    .font(.caption)
                    .foregroundStyle(Theme.warn)
            }

            HStack(spacing: 10) {
                Button {
                    traverse = m.recommendedTraverse
                    applied = m.program
                } label: {
                    Text(String(format: "Set Traverse to %.1fs", m.recommendedTraverse))
                        .font(.footnote.weight(.medium))
                }
                .buttonStyle(.bordered)
                .disabled(abs(traverse - m.recommendedTraverse) < 0.01)

                if applied == m.program {
                    Label("Applied", systemImage: "checkmark")
                        .font(.caption)
                        .foregroundStyle(Theme.good)
                }
            }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(Theme.tertiary)
            Text(value)
                .font(.footnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(Theme.label)
        }
    }

    // MARK: Footer

    private var currentFooter: String {
        guard let m = timer.results[boothProgram] else {
            return "Program \(boothProgram) has not been timed, so the Traverse above is still a guess."
        }
        let want = m.recommendedTraverse
        if traverse + 0.01 < want {
            return String(format: "Program %d needs %.1fs and the take records %.1fs — the clip ends %.1fs before the carriage stops.",
                          boothProgram, want, traverse, want - traverse)
        }
        if traverse > want + 1.5 {
            return String(format: "The take records %.1fs but the move is over after %.1fs, so the last %.1fs is a still rail — and the ramp profile spends slow-motion budget on it.",
                          traverse, want, traverse - want)
        }
        return String(format: "Matched: program %d takes %.1fs and the take records %.1fs.",
                      boothProgram, want, traverse)
    }

    private var currentFooterTint: Color {
        guard let m = timer.results[boothProgram] else { return Theme.warn }
        let want = m.recommendedTraverse
        return (traverse + 0.01 < want || traverse > want + 1.5) ? Theme.warn : Theme.good
    }
}
