import SwiftUI

/// The profile's internals: which slices of the raw pass play, how slowly, and whether the frame
/// rate can actually pay for it.
///
/// Lives one level down from Post because it matters while you are tuning and is noise afterwards.
struct RampProfileSettings: View {
    @StateObject private var booth = BoothSettings.shared
    @StateObject private var timer = MoveTimer.shared
    @State private var showPreview = false

    private var profile: RampProfile { booth.profile }

    private var takeLength: Double { Preflight.takeSeconds + Preflight.takeLeadIn }

    /// What will actually run tonight, not what the profile was authored as. Everything above the
    /// editor reads the authored numbers; this is the only place the two are reconciled, and the
    /// difference between them is routinely the whole story.
    private var fitted: RampProfile { profile.fitted(to: takeLength) }

    private var delivered: Double { fitted.deliveredDuration(hasEndCard: booth.endCard != nil) }

    /// True when the take is a different length from the one the profile was authored against, so
    /// the fitted numbers differ from the ones the sliders hold.
    private var isRescaled: Bool {
        abs(profile.designedSourceDuration - takeLength) > 0.05 || booth.deadHeadSeconds > 0.05
    }

    private var turnaround: Double? {
        guard let m = timer.results[Preflight.takeProgram], m.returnedToStart else { return nil }
        return Preflight.takeLeadIn + m.latency + m.duration / 2
    }

    var body: some View {
        Form {
            // The picture first. Reading nine numbers and inferring the shape of the clip is the
            // work this replaces, and it redraws the instant a slider moves.
            Section {
                RampTimeline(profile: fitted,
                             sourceLength: takeLength,
                             hasEndCard: booth.endCard != nil,
                             deadHead: booth.deadHeadSeconds,
                             turnaround: turnaround)
                    .padding(.vertical, 8)

                Button {
                    showPreview = true
                } label: {
                    Label("Preview the ramp", systemImage: "play.rectangle.on.rectangle")
                }
            } footer: {
                Text("Drawn against the \(String(format: "%.1f", takeLength))s take this booth records, both bars to the same scale — a narrow slice of source widening into a wide block of clip is the slow motion. Preview renders it as a clip you can watch, with no rail and no guest.")
            }

            Section {
                Picker("Profile", selection: $booth.profileName) {
                    ForEach(booth.selectableProfiles) { Text($0.name).tag($0.name) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            Section {
                ForEach(Array(fitted.passes.enumerated()), id: \.offset) { i, pass in
                    passSummary(index: i, pass: pass,
                                authored: profile.passes.indices.contains(i) ? profile.passes[i] : nil)
                }
                if fitted.flashDuration > 0 {
                    LabeledContent("White flash",
                                   value: String(format: "%.2fs", fitted.flashDuration))
                }
                if booth.deadHeadSeconds > 0.05 {
                    LabeledContent("Skips at the head") {
                        Text(String(format: "%.1fs", booth.deadHeadSeconds))
                            .monospacedDigit()
                            .foregroundStyle(Theme.accent)
                    }
                }
                LabeledContent("Total", value: String(format: "%.1fs", delivered))
                if fitted.endCardDuration > 0.05, booth.endCard == nil {
                    LabeledContent("End card") {
                        Text("None chosen")
                            .foregroundStyle(Theme.warn)
                    }
                }
                LabeledContent("Needs source",
                               value: String(format: "%.2fs", fitted.requiredSourceDuration))
            } header: {
                Text("Timeline")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Shot at \(Int(profile.sourceFPS)) fps, delivered at \(Int(profile.outputFPS)). Slowing further than \(Int(profile.maxCleanSlowFactor))× would start repeating frames.")
                    // 🐞 These rows used to quote the AUTHORED numbers while the diagram above
                    // quoted the fitted ones, so the same screen read "4.0× slow" and drew 1.8×.
                    // The authored figures are what the sliders edit and are worth showing, but
                    // the headline number has to be the one that will actually happen.
                    if isRescaled {
                        Text(String(format: "These are the timings as they will run against a %.1fs take — the profile was written for %.1fs, and the authored figures are shown after each one.",
                                    takeLength, profile.designedSourceDuration))
                    }
                    if fitted.endCardDuration > 0.05, booth.endCard == nil {
                        Text("The profile holds an end card for \(String(format: "%.1f", fitted.endCardDuration))s, but no card is loaded — so the clip ends on the last pass and Total excludes it.")
                    }
                    if booth.deadHeadSeconds > 0.05 {
                        Text("Pass timings are measured from the moment the carriage starts moving, so the lead-in and the program's trigger delay are skipped. Without that the clip would open on a still rail played at full slow motion.")
                    }
                }
            }

            Section {
                Picker("When the move is longer", selection: $booth.fitMode) {
                    ForEach(RampProfile.Fit.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("When the move is a different length")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(booth.fitMode.blurb)
                    // The arithmetic behind the choice, stated once. It is the thing that makes the
                    // trade obvious, and it is not obvious without it.
                    Text("A clip can only show its own length multiplied by the slow-motion factor. A \(String(format: "%.1f", delivered))s clip at \(Int(profile.maxCleanSlowFactor))× covers \(String(format: "%.1f", delivered * profile.maxCleanSlowFactor))s of movement — no setting makes it cover more.")
                        .foregroundStyle(Theme.secondary)
                }
            }

            if booth.isEditingCustom {
                editorSections
            } else {
                Section {
                    Button {
                        booth.duplicateSelectedToCustom()
                    } label: {
                        Label("Duplicate to Custom and edit", systemImage: "slider.horizontal.3")
                    }
                } footer: {
                    Text("Built-in profiles are fixed. Every timing in them is a guess until it has run against footage from a real rail — copy one to Custom to move the numbers here instead of in a rebuild.")
                }
            }
        }
        .navigationTitle("Ramp profile")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPreview) { RampPreviewView() }
    }

    // MARK: Read-only summary

    /// - Parameters:
    ///   - pass: the pass **as it will run** — fitted to tonight's take.
    ///   - authored: the same pass as the profile stores it, shown alongside when the two differ.
    ///     That difference is the fit mode doing its job, and hiding it is how someone tunes a
    ///     slider to 4× and gets 1.8×.
    private func passSummary(index i: Int,
                             pass: RampProfile.Pass,
                             authored: RampProfile.Pass?) -> some View {
        let budget = fitted.frameBudget(pass)
        let clean = fitted.isCleanSlowMotion(pass)
        let drifted = authored.map { abs($0.slowFactor - pass.slowFactor) > 0.05 } ?? false
        return LabeledContent {
            VStack(alignment: .trailing, spacing: 1) {
                Text(pass.rate < 1
                     ? String(format: "%.1f× slow", pass.slowFactor)
                     : String(format: "%.1f× fast", pass.rate))
                    .font(.body.weight(.medium).monospacedDigit())
                    .foregroundStyle(pass.rate < 1 ? Theme.accent : Theme.warn)
                if drifted, let authored {
                    Text(String(format: "written as %.1f×", authored.slowFactor))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Theme.tertiary)
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Pass \(i + 1)")
                Text(String(format: "%.2f–%.2fs → %.1fs · %d→%d frames",
                            pass.sourceStart,
                            pass.sourceStart + pass.sourceDuration,
                            pass.outputDuration,
                            budget.available, budget.needed))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(clean ? Theme.secondary : Theme.bad)
            }
        }
    }

    // MARK: Editor

    /// 🐞 **This section used to crash when a pass was removed.**
    ///
    /// `ForEach(Array(...enumerated()), id: \.offset)` identifies rows by INDEX. Removing a pass
    /// shrinks the array, and SwiftUI evaluates the departing row's body once more against the old
    /// index before the diff settles — so `passes[i]` in the footer, and every `$…passes[i]` binding,
    /// read one past the end and trapped. It needed two passes and one tap to reproduce, in the
    /// editor Kyle would be using at a venue to fix a profile between guests.
    ///
    /// Reads now use the value the `ForEach` handed us, and every binding checks the index.
    private func passBinding(_ i: Int,
                             _ keyPath: WritableKeyPath<RampProfile.Pass, Double>) -> Binding<Double> {
        Binding(
            get: {
                let passes = booth.customProfile.passes
                return passes.indices.contains(i) ? passes[i][keyPath: keyPath] : 0
            },
            set: { new in
                guard booth.customProfile.passes.indices.contains(i) else { return }
                booth.customProfile.passes[i][keyPath: keyPath] = new
            })
    }

    @ViewBuilder
    private var editorSections: some View {
        ForEach(Array(booth.customProfile.passes.enumerated()), id: \.offset) { i, pass in
            Section {
                ValueSlider(title: "Starts at",
                            value: passBinding(i, \.sourceStart),
                            range: 0...20, step: 0.05,
                            format: { String(format: "%.2fs", $0) })
                ValueSlider(title: "Uses",
                            value: passBinding(i, \.sourceDuration),
                            range: 0.1...10, step: 0.05,
                            format: { String(format: "%.2fs", $0) })
                ValueSlider(title: "Plays for",
                            value: passBinding(i, \.outputDuration),
                            range: 0.2...15, step: 0.1,
                            format: { String(format: "%.1fs", $0) })

                if booth.customProfile.passes.count > 1 {
                    Button(role: .destructive) {
                        guard booth.customProfile.passes.indices.contains(i) else { return }
                        booth.customProfile.passes.remove(at: i)
                    } label: {
                        DestructiveLabel("Remove pass", systemImage: "minus.circle")
                    }
                }
            } header: {
                Text("Pass \(i + 1)")
            } footer: {
                let clean = booth.customProfile.isCleanSlowMotion(pass)
                Label(pass.rate < 1
                      ? String(format: "%.1f× slow", pass.slowFactor)
                      : String(format: "%.1f× fast", pass.rate),
                      systemImage: clean ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(clean ? Theme.good : Theme.bad)
            }
        }

        Section {
            Button {
                let last = booth.customProfile.passes.last
                let start = (last?.sourceStart ?? 0) + (last?.sourceDuration ?? 0)
                booth.customProfile.passes.append(
                    .init(sourceStart: start, sourceDuration: 0.75, outputDuration: 3.0))
            } label: {
                Label("Add a pass", systemImage: "plus.circle")
            }

            ValueSlider(title: "White flash",
                        value: $booth.customProfile.flashDuration,
                        range: 0...1.5, step: 0.05,
                        format: { $0 < 0.025 ? "Off" : String(format: "%.2fs", $0) })

            ValueSlider(title: "End card holds",
                        value: $booth.customProfile.endCardDuration,
                        range: 0...10, step: 0.1,
                        format: { $0 < 0.05 ? "Off" : String(format: "%.1fs", $0) })
        } footer: {
            Text("The flash only appears between passes.")
        }

        Section {
            Button(role: .destructive) {
                var reset = RampProfile.whalefall
                reset.name = BoothSettings.customName
                booth.customProfile = reset
            } label: {
                Label("Reset to the reference timings", systemImage: "arrow.counterclockwise")
            }
        }
    }
}
