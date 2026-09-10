import SwiftUI

/// Every movement in one place, with a preview that needs no rail.
///
/// 🔑 **The job this does.** Choosing a move used to mean connecting, arming, homing, running one
/// program, watching it, and repeating — minutes each, only possible next to the machine, and with
/// nothing to compare against afterwards because the last one had already finished. Here the eight
/// stored programs and every custom motion sit in one dropdown, and picking one replays it on a
/// virtual rail at real speed.
///
/// ⚠️ **A stored program's curve has to be captured once.** The PLC has no tag that returns a
/// trajectory — established exhaustively: Varstate reads only the nine documented `"IOMotor"`
/// members, S7comm refuses block reads because PUT/GET is disabled, every DB is optimised so
/// absolute addressing fails, and the Recipes and DataLogs folders are empty. The moves are
/// compiled logic, not data. So the app watches one instead: `TraceRecorder` runs a program while
/// sampling `CurrentPosition`, and after that single pass it previews forever.
///
/// Custom motions need no capture at all — their waypoints define the curve exactly.
struct MovementLibraryView: View {
    @StateObject private var programs = ProgramStore.shared
    @StateObject private var motions = MotionStore.shared
    @StateObject private var library = TraceLibrary.shared
    @StateObject private var recorder = TraceRecorder.shared
    @StateObject private var link = GlamaticLink.shared
    @StateObject private var safety = SafetyKernel.shared
    @StateObject private var timer = MoveTimer.shared

    @AppStorage("armcontrol.take.program") private var boothProgram = 1
    @AppStorage("armcontrol.take.seconds") private var traverse = 6.0

    @State private var selection: MovementID = .program(1)
    @State private var confirmCapture = false
    @State private var confirmCaptureAll = false
    @State private var confirmRun = false

    /// Which movement is on screen. Programs live in the PLC; motions are driven by the app.
    enum MovementID: Hashable {
        case program(Int)
        case motion(UUID)
    }

    // MARK: The unified list

    private struct Entry: Identifiable {
        var id: MovementID
        var name: String
        var subtitle: String
        var trace: MotionTrace?
        var isProgram: Bool
        var programNumber: Int?
        var motion: CustomMotion?
    }

    private var entries: [Entry] {
        var out: [Entry] = programs.presets.map { p in
            let trace = library.best(for: p.number)
            return Entry(id: .program(p.number),
                         name: p.display,
                         subtitle: trace?.summary ?? "Not captured yet",
                         trace: trace,
                         isProgram: true,
                         programNumber: p.number,
                         motion: nil)
        }
        out += motions.motions.map { m in
            let t = MotionTrace.synthesised(from: m)
            return Entry(id: .motion(m.id),
                         name: m.name,
                         subtitle: t.summary,
                         trace: t,
                         isProgram: false,
                         programNumber: nil,
                         motion: m)
        }
        return out
    }

    private var current: Entry? { entries.first { $0.id == selection } }

    var body: some View {
        List {
            picker
            preview
            rampOverlay
            facts
            actions
            captureAllSection
        }
        .navigationTitle("Movements")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if current == nil { selection = .program(boothProgram) } }
        .confirmationDialog("Capture this movement?", isPresented: $confirmCapture,
                            titleVisibility: .visible) {
            Button("Run it and record", role: .destructive) {
                if let n = current?.programNumber {
                    Task { await recorder.capture(program: n) }
                }
            }
        } message: {
            Text("The rail runs the program once while the app records where the carriage goes. Stand clear.")
        }
        .confirmationDialog("Capture every program?", isPresented: $confirmCaptureAll,
                            titleVisibility: .visible) {
            Button("Run all \(programs.visible.count) and record", role: .destructive) {
                Task { await recorder.captureAll(programs.visible.map(\.number)) }
            }
        } message: {
            Text("Each enabled program runs once, in order, with a pause between. This is the session that makes every preview work offline afterwards — plan for a few minutes and stand clear.")
        }
        .confirmationDialog("Run this on the real rail?", isPresented: $confirmRun,
                            titleVisibility: .visible) {
            Button("Move the rail", role: .destructive) { runOnRail() }
        } message: {
            Text("The carriage will move.")
        }
    }

    // MARK: Dropdown

    private var picker: some View {
        Section {
            Picker("Movement", selection: $selection) {
                if !programs.presets.isEmpty {
                    Section("On the rail") {
                        ForEach(programs.presets) { p in
                            Label {
                                Text(p.display)
                            } icon: {
                                Image(systemName: library.byProgram[p.number] != nil
                                      ? "checkmark.circle.fill" : "circle.dotted")
                            }
                            .tag(MovementID.program(p.number))
                        }
                    }
                }
                if !motions.motions.isEmpty {
                    Section("Driven by the app") {
                        ForEach(motions.motions) { m in
                            Label(m.name, systemImage: "function")
                                .tag(MovementID.motion(m.id))
                        }
                    }
                }
            }
            .pickerStyle(.menu)
        } footer: {
            Text("A tick means the movement has been recorded off the rail and previews exactly. Everything under “Driven by the app” is computed from its own waypoints and needs no capture.")
                .font(.footnote)
        }
    }

    // MARK: Preview

    @ViewBuilder
    private var preview: some View {
        Section {
            if let entry = current, let trace = entry.trace, !trace.isEmpty {
                VirtualArm(trace: trace, title: entry.name)
                    .padding(.vertical, 6)
            } else if let entry = current {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Nothing to show yet", systemImage: "eye.slash")
                        .font(.headline)
                        .foregroundStyle(Theme.warn)
                    Text("“\(entry.name)” has never been recorded, and it has not been timed either — so there is nothing to draw. The moves live inside the PLC as code and cannot be read out; the app has to watch one to know what it does.")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondary)
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("Preview")
        } footer: {
            if let t = current?.trace, t.source == .predicted {
                Text("This shape is inferred from a timing measurement — only the length, the travel and whether it returns are real. Capture it to see what the rail actually does.")
                    .font(.footnote)
                    .foregroundStyle(Theme.warn)
            }
        }
    }

    /// Where the ramp profile takes its footage from, drawn on this movement.
    @ViewBuilder
    private var rampOverlay: some View {
        if let t = current?.trace, !t.isEmpty, current?.isProgram == true {
            let take = Preflight.takeLeadIn + Preflight.takeSeconds
            let fitted = BoothSettings.shared.profile.fitted(to: take)
            Section {
                RampOnMotion(trace: t,
                             profile: fitted,
                             deadHead: BoothSettings.shared.deadHeadSeconds,
                             takeLength: take)
                    .padding(.vertical, 6)
            } header: {
                Text("What the clip will sample")
            } footer: {
                VStack(alignment: .leading, spacing: 5) {
                    Text("The shaded bands are the slices “\(BoothSettings.shared.profile.name)” takes out of this movement. A band sitting over the grey “still” region is slow motion spent on a rail that has not moved yet.")
                    if take < t.duration - 0.05 {
                        Text(String(format: "The take stops at %.1fs but this movement runs %.1fs — the last %.1fs is never filmed. Set Traverse to %.1fs.",
                                    take, t.duration, t.duration - take, t.recommendedTraverse))
                            .foregroundStyle(Theme.bad)
                    }
                }
                .font(.footnote)
            }
        }
    }

    // MARK: Numbers

    @ViewBuilder
    private var facts: some View {
        if let t = current?.trace, !t.isEmpty {
            Section {
                LabeledContent("Runs for", value: String(format: "%.1fs", t.duration))
                LabeledContent("Travels", value: String(format: "%.0f mm  (%.0f → %.0f)",
                                                        t.throwMM, t.minMM, t.maxMM))
                LabeledContent("Fastest", value: String(format: "%.0f mm/s", t.peakSpeed))
                LabeledContent("Shape", value: t.returnsToStart ? "Out and back" : "One way")
                if !t.turnarounds.isEmpty {
                    LabeledContent("Reverses at",
                                   value: t.turnarounds.map { String(format: "%.1fs", $0) }
                                            .joined(separator: ", "))
                }
                // The single most consequential number on this screen — see BoothSettings.
                LabeledContent("Waits before moving") {
                    Text(String(format: "%.1fs", t.latency))
                        .monospacedDigit()
                        .foregroundStyle(t.latency > 1.5 ? Theme.warn : Theme.secondary)
                }
                LabeledContent("Suggested traverse",
                               value: String(format: "%.1fs", t.recommendedTraverse))
                if let at = t.capturedAt {
                    // "Captured" would be a lie on a predicted curve — that date is when the
                    // TIMING was taken, not when the shape was recorded.
                    LabeledContent(t.source == .recorded ? "Captured" : "Measured",
                                   value: at.formatted(date: .abbreviated, time: .shortened))
                }
            } header: {
                Text("What it does")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if t.latency > 1.5 {
                        Text(String(format: "This program sits still for %.1fs after the trigger before it moves. The ramp profile skips that automatically — but only because the movement was recorded; a guessed figure here puts several seconds of a motionless rail into the clip at full slow motion.", t.latency))
                            .foregroundStyle(Theme.warn)
                    }
                    Text("A clip can only show its own length multiplied by the slow-motion factor, so a \(String(format: "%.1f", t.moveDuration))s movement at 4× needs a \(String(format: "%.1f", t.moveDuration / 4))s clip to cover all of it.")
                }
                .font(.footnote)
            }
        }
    }

    // MARK: Actions

    private var actions: some View {
        Section {
            if let entry = current, entry.isProgram, let n = entry.programNumber {
                Button {
                    confirmCapture = true
                } label: {
                    HStack {
                        Label(library.byProgram[n] == nil ? "Capture it from the rail" : "Capture it again",
                              systemImage: "record.circle")
                        Spacer()
                        if recorder.capturing == n { ProgressView() }
                    }
                }
                .disabled(!canTouchRail || recorder.isCapturing)

                if library.byProgram[n] != nil {
                    Button(role: .destructive) {
                        library.forget(n)
                    } label: {
                        DestructiveLabel("Forget the recording", systemImage: "trash")
                    }
                }
            }

            Button {
                confirmRun = true
            } label: {
                Label("Run it on the rail", systemImage: "play.circle")
            }
            .disabled(!canTouchRail || motions.isPlaying)

            // Author a profile from what the machine actually does, rather than scaling a guess.
            if let entry = current, let t = entry.trace, t.source == .recorded, !t.isEmpty,
               let built = RampProfile.authored(from: t, named: BoothSettings.customName) {
                Button {
                    BoothSettings.shared.customProfile = built
                    BoothSettings.shared.profileName = BoothSettings.customName
                    if entry.isProgram, let n = entry.programNumber {
                        boothProgram = n
                        traverse = t.recommendedTraverse
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Label("Fit the ramp to this movement", systemImage: "wand.and.stars")
                        Text(String(format: "%d passes on the real legs, each at a clean %.1f× — writes the Custom profile and selects it.",
                                    built.passes.count, built.passes.first?.slowFactor ?? 4))
                            .font(.caption)
                            .foregroundStyle(Theme.secondary)
                    }
                }
            }

            // 🔑 The only way to "edit a preset". The PLC's programs are compiled logic and cannot
            // be altered — but the curve the machine was OBSERVED producing can be rebuilt as
            // waypoints the app drives, and those are editable.
            if let entry = current, let t = entry.trace, t.source == .recorded, !t.isEmpty {
                NavigationLink {
                    MotionEditorView(motion: .from(trace: t, name: "\(entry.name) (edited)"), ghost: t)
                } label: {
                    Label("Make an editable copy", systemImage: "slider.horizontal.3")
                }
            }

            if let entry = current, entry.isProgram, let n = entry.programNumber {
                Button {
                    boothProgram = n
                    // 🔑 From the RECORDING, not the trace's raw length: a capture includes the
                    // settle at the end, and what the take must cover is latency + movement. The
                    // dead head follows automatically, because `BoothSettings` reads the same
                    // recorded trace.
                    if let t = entry.trace, t.source == .recorded, !t.isEmpty {
                        traverse = t.recommendedTraverse
                    } else if let d = entry.trace?.duration, d > 0.5 {
                        traverse = (d + 0.8).rounded(.up)
                    }
                } label: {
                    Label("Use this for the booth", systemImage: "checkmark.circle")
                }
            }

            if !recorder.progress.isEmpty {
                Text(recorder.progress)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(Theme.secondary)
            }
            if let e = recorder.lastError {
                Text(e).font(.footnote).foregroundStyle(Theme.bad)
            }
        } footer: {
            // Never a silent disabled control.
            if let reason = railBlocker {
                Text(reason).font(.footnote).foregroundStyle(Theme.warn)
            } else {
                Text("“Use this for the booth” also sets Traverse long enough to cover the move, which is the number every ramp timing is scaled against.")
                    .font(.footnote)
            }
        }
    }

    @ViewBuilder
    private var captureAllSection: some View {
        Section {
            Button {
                confirmCaptureAll = true
            } label: {
                HStack {
                    Label("Capture every program", systemImage: "square.stack.3d.down.right")
                    Spacer()
                    Text("\(library.capturedCount) of \(programs.presets.count)")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(Theme.secondary)
                }
            }
            .disabled(!canTouchRail || recorder.isCapturing)
        } footer: {
            Text("Do this once, at the rail, and every movement previews offline from then on. It is the only thing here that needs the hardware.")
                .font(.footnote)
        }
    }

    // MARK: Gates

    private var canTouchRail: Bool {
        link.connected && safety.armed && link.state.isHomed
    }

    private var railBlocker: String? {
        if !link.connected { return "Not connected to the rail — previews still work, capturing does not." }
        if !safety.armed { return "Arm the rail before capturing or running." }
        if !link.state.isHomed { return "The rail is not referenced. Home it first." }
        return nil
    }

    private func runOnRail() {
        guard let entry = current else { return }
        if let n = entry.programNumber {
            Task { await link.runProgram(n) }
        } else if let m = entry.motion {
            Task { await motions.play(m) }
        }
    }
}
