import SwiftUI

/// Every track of a movement against **one shared clock**.
///
/// 🔑 **WHY THIS EXISTS, when the pieces already did.** The library previews a movement, the editor
/// reshapes it, `RampOnMotion` draws the slow-motion passes and the take screen owns the camera
/// timing — four screens, four separate time axes, and no way to see that pass 2 lands on the
/// return leg while the carriage is doing 143 mm/s and the camera is still in its lead-in. Every
/// mis-timing today came from exactly that gap: a dead head measured on one screen, a ramp authored
/// on another, and nobody able to see them disagree.
///
/// So this composes rather than replaces. `VirtualArm`, `RampOnMotion` and the trace maths are used
/// as they are; what is new is that **the x-axis is the same in every row**, and one playhead moves
/// through all of them.
///
/// ⚠️ **What this is NOT, and the spec that asked for it was wrong on every one.** The Glamatic is
/// a Siemens S7-1200 driving a SINGLE LINEAR AXIS, 0–600 mm. There are no six joints, no Cartesian
/// wrist rotation, no singularities, no payload envelope and no inverse kinematics — a position on
/// this machine is one number. There is also no way to read a trajectory out of the PLC or write
/// one back: proven exhaustively (Varstate, S7comm PUT/GET, absolute DB addressing, Recipes,
/// DataLogs — all closed), which is why every curve here is an OBSERVED recording rather than a
/// program listing. The 6-axis machine people are thinking of is the xArm 5 — a different robot,
/// on a different protocol, that this app only folds down at park time.
struct MovementStudioView: View {
    @StateObject private var traces = TraceLibrary.shared
    @StateObject private var programs = ProgramStore.shared
    @StateObject private var booth = BoothSettings.shared
    @StateObject private var link = GlamaticLink.shared
    @StateObject private var safety = SafetyKernel.shared
    @StateObject private var motions = MotionStore.shared

    @StateObject private var clock = StudioClock()
    @State private var program: Int = 1
    @State private var showRamp = true
    @State private var showCamera = true

    /// The editable copy, once one has been made. Nil means we are studying the recording as-is.
    ///
    /// 🔑 **This is the only way to "edit a preset".** The eight — now thirty-seven — programs are
    /// compiled logic inside the S7-1200 and cannot be read, written or altered; that was
    /// established exhaustively. What CAN be done is take the curve the machine was observed
    /// producing and rebuild it as waypoints this app drives itself, which then genuinely is
    /// editable. `MotionTrace.synthesised(from:)` turns the result back into a curve, so an edited
    /// motion draws through exactly the same tracks as a recorded one.
    @State private var edited: CustomMotion?
    @State private var saveNote: String?
    /// The waypoint currently under the finger, held for the whole drag.
    @State private var dragging: UUID?
    /// The speed handle under the finger, held for the whole drag.
    @State private var speedDragging: UUID?
    /// The dwell handle under the finger, held for the whole drag.
    @State private var dwellDragging: UUID?

    /// Undo history for the edit.
    ///
    /// 🔑 **An editor without undo is an editor people are afraid to use.** Every control here
    /// mutates the motion in place — a knob, a slider, a drag that grabbed the wrong waypoint —
    /// and until now the only route back from a stray change was Discard, which throws away
    /// everything else you had done. That makes the safe move "don't touch it", which defeats the
    /// screen.
    ///
    /// One entry per *gesture*, not per value change: a drag pushes once at touch-down, so undo
    /// steps back a whole movement of a knob rather than 200 intermediate positions.
    @State private var history: [CustomMotion] = []
    /// States undone, available to redo until the next edit forks the timeline.
    @State private var redoStack: [CustomMotion] = []
    /// Snap drags to a round number of millimetres.
    @AppStorage("armcontrol.studio.snap") private var snap = true
    /// A saved motion awaiting delete confirmation.
    @State private var pendingDelete: CustomMotion?
    /// Show the per-waypoint editor. Off by default — most moves never need it.
    @State private var showAdvanced = false
    @State private var searchOpen = false
    @State private var search = ""
    /// ⚠️ **`armcontrol.take.seconds`, NOT `...take.traverse`.** I wrote the second one from memory
    /// and it compiled, ran, and did nothing — `@AppStorage` happily creates a key nobody reads.
    /// The failure would have been silent and nasty: "Use this for the booth" would appear to work
    /// while the camera kept rolling for the previous move's length, cutting the new one short in
    /// front of a guest. Verified against `EventSetup.Keys.traverse` and the three views that read
    /// it (`MoveTimingView`, `MovementLibraryView`, `RootView`).
    @AppStorage("armcontrol.take.seconds") private var traverseKey: Double = 6

    /// Show the charts. OFF by default.
    ///
    /// 🔑 **Seven cards is not a tool, it is a dashboard.** The Studio grew a picker, a transport,
    /// a rail preview, a four-row timeline with its own toggles, a waypoint inspector, a ramp
    /// panel and a warnings panel — all on screen at once, all the time. Every one of them earns
    /// its place *sometimes*, and together they bury the two things somebody opens this screen to
    /// do: look at a movement, and change it.
    ///
    /// So the default is now: pick a movement, watch it, edit it. The analysis is one tap away and
    /// stays where it was put — an operator who wants the charts gets them for the rest of the
    /// session, and one who does not never sees them again.
    @AppStorage("armcontrol.studio.details") private var showDetails = false

    /// Snapshot before a change. Call at the START of a gesture, not on every update.
    private func checkpoint() {
        guard let edited else { return }
        history.append(edited)
        if history.count > 40 { history.removeFirst() }
        // ⚠️ A new edit forks the timeline, so anything undone is no longer reachable. Keeping it
        // would let Redo jump to a state that never followed from what is on screen.
        redoStack.removeAll()
    }

    /// What the recording says, untouched.
    private var recorded: MotionTrace? {
        guard let t = traces.byProgram[program], !t.isEmpty else { return nil }
        return t
    }

    /// What every track draws: the edit if there is one, otherwise the recording.
    private var trace: MotionTrace? {
        if let edited { return .synthesised(from: edited) }
        return recorded
    }

    /// The full take length this movement would be shot over.
    private var takeLength: Double {
        guard let trace else { return 0 }
        return booth.leadIn + trace.recommendedTraverse
    }

    /// 🐞 **THE SHARED X-AXIS, and the Studio was quietly failing at the one thing it exists for.**
    /// Every row here drew against `trace.duration` while `RampOnMotion` draws against
    /// `max(takeLength, trace.duration)` — a longer span, because a take runs past the end of the
    /// recording. Same pixels, different seconds. The result looked plausible and was a lie: the
    /// slow-motion passes rendered compressed to the left, so pass 1 appeared to fall *before the
    /// carriage started moving*. Reading "does this pass land on the return leg?" off that would
    /// give the wrong answer, which is precisely the mis-timing this screen was built to catch.
    /// Every row now uses this, matching `RampOnMotion`'s own definition exactly.
    private var span: Double {
        guard let trace else { return 1 }
        return max(takeLength, trace.duration, 1)
    }

    var body: some View {
        // One TimelineView drives the whole screen, so every track is drawn from the same instant.
        // 🐞 **Reads the clock, never writes it.** The previous version called `clock.tick(ctx.date)`
        // here, assigning to `@Published` state from inside a view body — SwiftUI invalidated the
        // view it was building, rebuilt, ticked again, and the Studio locked solid with no control
        // responding. `time(at:)` is a pure read; only play/pause/scrub mutate, and all three are
        // user actions outside the update cycle.
        TimelineView(.animation(paused: !clock.isPlaying)) { ctx in
            content(now: ctx.date)
        }
    }

    /// 🔑 **TWO PANES, because this is a 12.9-inch iPad and the old layout was a phone.**
    ///
    /// The Studio was a single scrolling column of seven cards — picker, transport, preview, edit,
    /// timeline, advanced, ramp, warnings — stacked down the middle of a 1366pt-wide screen with
    /// most of that width empty. Everything was technically present and nothing was usable: the
    /// movement you were watching scrolled off before you reached the slider that changed it, so
    /// every edit was blind, then a scroll back up to see what it did.
    ///
    /// The fix is the layout the job actually wants, and the one the original sketch asked for:
    /// **watch it on the left, change it on the right, in view at the same time.** The timeline
    /// spans the full width underneath, because it is the one thing that needs horizontal room.
    ///
    /// ⚠️ Falls back to a single column below 900pt — a Split View slice or an iPhone has no width
    /// to give, and two 300pt panes are worse than one 600pt one.
    @ViewBuilder
    private func content(now: Date) -> some View {
        let head = clock.time(at: now)
        GeometryReader { geo in
            let wide = geo.size.width > 900
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    picker
                    if let trace {
                        if wide {
                            HStack(alignment: .top, spacing: 16) {
                                // The subject of the screen gets the space.
                                stage(trace, head: head)
                                    .frame(maxWidth: .infinity)
                                // Controls sit at a fixed, readable width rather than stretching
                                // sliders across a metre of glass.
                                controls(trace)
                                    .frame(width: 400)
                            }
                        } else {
                            stage(trace, head: head)
                            controls(trace)
                        }

                        detailsToggle
                        if showDetails {
                            tracks(trace, head: head)
                            advanced
                            rampBar(trace)
                            warnings(trace)
                        } else if edited != nil {
                            quietWarnings(trace)
                        }
                    } else {
                        ContentUnavailableView("Not captured yet",
                                               systemImage: "waveform.path.ecg",
                                               description: Text("Run this program once with capture on and its curve appears here."))
                            .frame(height: 220)
                    }
                }
                .padding(20)
            }
        }
        .background(Theme.grouped)
        .navigationTitle("Movement Studio")
        .confirmationDialog("Delete this motion?",
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete \(pendingDelete?.name ?? "")", role: .destructive) {
                if let m = pendingDelete {
                    if edited?.id == m.id { edited = nil; history = []; redoStack = [] }
                    MotionStore.shared.delete(m)
                }
                pendingDelete = nil
            }
            Button("Keep", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This cannot be undone — a saved motion exists only on this iPad.")
        }
    }

    /// LEFT PANE — the movement itself, with its transport attached.
    ///
    /// 🔑 The playhead used to be its own card ABOVE the rail it drove. Two boxes, one idea, and
    /// the readout sat far enough from the carriage that you could not watch both. They are one
    /// thing now: the rail, the numbers, and the controls that move them.
    private func stage(_ trace: MotionTrace, head: Double) -> some View {
        Card(title: edited == nil ? "The movement" : "Your edit",
             systemImage: edited == nil ? "ruler" : "pencil.circle.fill") {
            VStack(alignment: .leading, spacing: 14) {
                VirtualArm(trace: trace,
                           externalTime: head,
                           // Only when editing — a recording has nothing to be compared against.
                           ghost: edited == nil ? nil : recorded,
                           ghostLabel: "before")
                    // 🔑 The movement is the subject of the screen, so it gets the height. The
                    // controls column runs to ~1250pt when editing; a 220pt stage next to it left
                    // the left half mostly empty and made the thing you are looking at the
                    // smallest element on screen.
                    .frame(minHeight: edited == nil ? 300 : 420)

                HStack(spacing: 16) {
                    Button { clock.toggle() } label: {
                        Image(systemName: clock.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2)
                            .frame(width: 62, height: 48)
                    }
                    .buttonStyle(.borderedProminent)

                    // The three numbers that describe where the carriage is, right now.
                    Text(String(format: "%.2fs   %.0f mm   %.0f mm/s",
                                head,
                                trace.position(at: head),
                                abs(trace.velocity(at: head))))
                        .font(.title3.monospacedDigit())
                        .foregroundStyle(Theme.secondary)

                    Spacer()

                    Picker("Speed", selection: $clock.rate) {
                        Text("¼×").tag(0.25)
                        Text("½×").tag(0.5)
                        Text("1×").tag(1.0)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 170)
                }
            }
        }
        .onAppear { clock.reset(duration: span) }
        .onChange(of: program) { _, _ in
            // ⚠️ Switching movement abandons the copy. Carrying it over would leave an edit
            // labelled as one program while holding another's curve.
            edited = nil
            saveNote = nil
            history = []
            redoStack = []
            clock.selectedKeyframe = nil
            clock.reset(duration: span)
        }
    }

    /// RIGHT PANE — everything that changes the movement.
    private func controls(_ trace: MotionTrace) -> some View {
        editBar
    }

    private var detailsToggle: some View {
        Toggle(isOn: $showDetails) {
            Label(showDetails ? "Hide the details" : "Show timing, slow motion and warnings",
                  systemImage: "chart.xyaxis.line")
                .font(.subheadline.weight(.medium))
        }
        .toggleStyle(.button)
        .buttonStyle(.bordered)
    }

    /// Author the slow-motion profile from THIS movement.
    ///
    /// 🔑 The alternative — the app's default — is `fitted(to:)`, which rescales a profile written
    /// in absolute seconds onto whatever was recorded. That is blind to where the carriage
    /// reverses, and it produced two measured failures: passes landing at **5.1×** against a 4.0×
    /// clean ceiling (so frames repeat), and, on the programs that turn around twice, a single pass
    /// spanning a reversal — a shot that changes direction halfway through.
    ///
    /// This builds from the legs the machine actually produced: one pass per leg, centred to keep
    /// the PLC's acceleration shoulders out of frame, every pass pinned to the clean ceiling.
    @ViewBuilder
    private func rampBar(_ trace: MotionTrace) -> some View {
        if let built = RampProfile.authored(from: trace, named: BoothSettings.customName) {
            Card(title: "Slow motion", systemImage: "wand.and.stars",
                 footnote: "Holding a clean 4× across a whole long move is arithmetically a 30-second clip, so each pass samples the middle of its leg. The ends of the travel do not appear.") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(format: "%d pass%@ on the real legs · %.1f× each · %.1fs clip",
                                built.passes.count,
                                built.passes.count == 1 ? "" : "es",
                                built.passes.first?.slowFactor ?? 4,
                                built.deliveredDuration(hasEndCard: booth.endCard != nil)))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(Theme.secondary)

                    Button {
                        booth.customProfile = built
                        booth.profileName = BoothSettings.customName
                        saveNote = "Ramp fitted to this movement."
                    } label: {
                        Label("Fit the ramp to this movement", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    // MARK: Editing

    /// Make / discard / save the editable copy — and edit it in plain language.
    private var editBar: some View {
        Card(title: edited == nil ? "Edit this movement" : "Editing a copy",
             systemImage: edited == nil ? "square.and.pencil" : "pencil.circle.fill",
             footnote: edited == nil
                ? "The PLC's own programs cannot be altered. An editable copy rebuilds the observed curve as waypoints this app drives itself."
                : nil) {
            if edited == nil {
                Button {
                    guard let recorded else { return }
                    var copy = CustomMotion.from(trace: recorded,
                                                 name: (programs.presets.first { $0.number == program }?.display ?? "Program \(program)") + " (copy)")
                    copy.id = UUID()
                    edited = copy
                    history = []
                    redoStack = []
                    clock.selectedKeyframe = copy.waypoints.first?.id
                    clock.reset(duration: span)
                } label: {
                    Label("Edit this movement", systemImage: "slider.horizontal.3")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .disabled(recorded == nil)

                Divider().padding(.vertical, 2)

                // 🔑 A way in that is not "copy something that already exists".
                Menu {
                    ForEach(SimpleMove.templates, id: \.name) { t in
                        Button {
                            var m = t.move.asMotion(named: t.name)
                            m.id = UUID()
                            edited = m
                            history = []
                            redoStack = []
                            clock.selectedKeyframe = m.waypoints.first?.id
                            clock.reset(duration: max(takeLength,
                                                      MotionTrace.synthesised(from: m).duration, 1))
                        } label: {
                            // 🐞 **A `Menu` button renders ONE line.** This was a VStack of name +
                            // description, and SwiftUI silently dropped the description — leaving
                            // six bare names where "Fast whip" and "Full sweep" are impossible to
                            // tell apart without picking one and undoing it. The numbers ARE the
                            // description, so they go in the title.
                            // ⚠️ **The whole sentence, including the hold.** A `Menu` button
                            // renders one line, so an earlier version put name + description in a
                            // VStack and SwiftUI silently dropped the description. Then a shortened
                            // version omitted the pause — which made "Fast whip" and "Out and hold"
                            // read identically ("600 mm there and back at 143 mm/s"), when the beat
                            // at the far end is the entire difference between them.
                            Text("\(t.name)  ·  \(t.move.shortLabel)")
                        }
                    }
                } label: {
                    Label("Start a new movement", systemImage: "plus.circle")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)

                Text("Builds a move from scratch rather than copying a stored program — the app drives its own moves, so it is not limited to the 37 recorded ones.")
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                simpleEditor
            }
        }
    }

    /// The whole move as five plain-language controls.
    ///
    /// 🔑 **This is the answer to "it is too confusing".** The waypoint editor asked an operator to
    /// think in legs, per-leg velocities and dwells; the sentence in their head is "go to the far
    /// end and come back, fairly slowly, with a beat". These are that sentence. The waypoint list
    /// still exists under Advanced for the moves that need it.
    @ViewBuilder
    private var simpleEditor: some View {
        if let motion = edited,
           let simple = SimpleMove.from(motion, startingAt: recorded?.position(at: 0) ?? 0) {
            let binding = Binding<SimpleMove>(
                get: { simple },
                set: { new in
                    checkpoint()
                    var m = new.asMotion(named: edited?.name ?? "Custom")
                    m.id = edited?.id ?? UUID()
                    edited = m
                    clock.duration = max(takeLength, MotionTrace.synthesised(from: m).duration, 1)
                })

            VStack(alignment: .leading, spacing: 18) {
                // What this move IS, in one line, always visible while tuning it.
                Text(simple.sentence)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.accent)
                    .fixedSize(horizontal: false, vertical: true)

                slider("Start at", value: Binding(get: { simple.start },
                                                  set: { binding.wrappedValue.start = $0 }),
                       range: PLC.positionRange, unit: "mm", step: 25)

                slider("Go to", value: Binding(get: { simple.end },
                                               set: { binding.wrappedValue.end = $0 }),
                       range: PLC.positionRange, unit: "mm", step: 25)

                Toggle("Come back to the start", isOn: Binding(get: { simple.comeBack },
                                                               set: { binding.wrappedValue.comeBack = $0 }))
                    .font(.subheadline)

                slider("Speed", value: Binding(get: { simple.speed },
                                               set: { binding.wrappedValue.speed = $0 }),
                       range: PLC.velocityRange, unit: "mm/s", step: 1)

                if simple.comeBack {
                    slider("Pause at the far end",
                           value: Binding(get: { simple.pause },
                                          set: { binding.wrappedValue.pause = $0 }),
                           range: 0...2, unit: "s", step: 0.05)
                }

                editActions
            }
        } else if edited != nil {
            VStack(alignment: .leading, spacing: 12) {
                Label("This move has more detail than the simple controls can show — different speeds per leg, or more than two legs.",
                      systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // 🐞 **The message used to say "Open Advanced" and Advanced was not on screen.** It
                // lived below the timeline, inside the details panel, which is collapsed by
                // default — so the one instruction given to somebody who cannot use the simple
                // controls pointed at a control they could not see. For the 5 of 37 programs that
                // land here (the "Full double" moves and the 3-turn), that was the whole editing
                // path, hidden behind two disclosures.
                //
                // The waypoint editor is now RIGHT HERE when it is the only way to edit this move,
                // rather than being an advanced extra.
                inspector
                editActions
            }
        }
    }

    /// Name, undo, save, discard, reverse, run — shared by both editing modes.
    @ViewBuilder
    private var editActions: some View {
        Divider()

        TextField("Name", text: Binding(get: { edited?.name ?? "" },
                                        set: { edited?.name = $0 }))
            .textFieldStyle(.roundedBorder)
            .font(.headline)

        if let e = edited, let original = recorded {
            let mine = MotionTrace.synthesised(from: e).duration
            let theirs = original.moveDuration
            Text(String(format: "%.1fs against the original's %.1fs%@",
                        mine, theirs,
                        mine > theirs + 0.2
                            ? "  ·  slower, because driven moves cap at \(Int(PLC.velocityRange.upperBound)) mm/s"
                            : ""))
                .font(.caption.monospacedDigit())
                .foregroundStyle(mine > theirs + 0.2 ? Theme.warn : Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        // 🔑 **Adding a stop where the playhead is.** Building a three-leg move used to mean opening
        // Advanced and using a "+" that duplicates the selected waypoint — you then had to work out
        // what position and speed the new one should have. The playhead is already a cursor: scrub
        // to the moment you want the carriage to stop, and put a stop there.
        //
        // ⚠️ Inherits the position the curve ALREADY has at that instant and the speed of the leg
        // it splits, so the move is unchanged the moment it is added. A new waypoint that alters
        // the movement before you have touched it makes the button feel destructive.
        if let motion = edited, let t = trace {
            Button {
                // ⚠️ **Pause first, or the stop lands in the wrong place.** `currentTime` is only
                // written by pause and scrub — deliberately, because publishing it every frame from
                // inside the view body is what froze the Studio. So while playing it holds the
                // moment playback STARTED, not the moment you are looking at. Pausing settles it to
                // the live position before anything reads it.
                clock.pause()
                checkpoint()
                let at = clock.currentTime
                let mm = (t.position(at: at) / 5).rounded() * 5
                var (index, speed) = (motion.waypoints.count, motion.waypoints.last?.velocity ?? 85)
                var walk = 0.0
                var here = t.position(at: 0)
                for (i, w) in motion.waypoints.enumerated() {
                    let leg = abs(w.clampedPosition - here) / max(1, w.clampedVelocity)
                    if at < walk + leg { index = i; speed = w.velocity; break }
                    walk += leg + w.dwell
                    here = w.clampedPosition
                }
                let fresh = MotionWaypoint(position: mm, velocity: speed, dwell: 0)
                edited?.waypoints.insert(fresh, at: index)
                clock.selectedKeyframe = fresh.id
                if let e = edited {
                    clock.duration = max(takeLength, MotionTrace.synthesised(from: e).duration, 1)
                }
            } label: {
                Label(clock.isPlaying
                        ? "Add a stop at the playhead"
                        : String(format: "Add a stop here — %.0f mm at %.2fs",
                                 t.position(at: clock.currentTime), clock.currentTime),
                      systemImage: "plus.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }

        HStack(spacing: 10) {
            Button {
                guard let previous = history.popLast(), let current = edited else { return }
                redoStack.append(current)
                edited = previous
                clock.duration = max(takeLength, MotionTrace.synthesised(from: previous).duration, 1)
            } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
            .disabled(history.isEmpty)

            Button {
                guard let next = redoStack.popLast(), let current = edited else { return }
                history.append(current)
                edited = next
                clock.duration = max(takeLength, MotionTrace.synthesised(from: next).duration, 1)
            } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
            .disabled(redoStack.isEmpty)

            Button {
                checkpoint()
                guard var m = edited else { return }
                let lo = m.waypoints.map(\.clampedPosition).min() ?? 0
                let hi = m.waypoints.map(\.clampedPosition).max() ?? 600
                for i in m.waypoints.indices {
                    m.waypoints[i].position = lo + hi - m.waypoints[i].clampedPosition
                }
                edited = m
                clock.duration = max(takeLength, MotionTrace.synthesised(from: m).duration, 1)
            } label: { Label("Reverse", systemImage: "arrow.left.arrow.right") }
        }
        .buttonStyle(.bordered)

        HStack(spacing: 12) {
            Button {
                if let edited { MotionStore.shared.save(edited) }
                saveNote = "Saved to your motions."
            } label: {
                Label("Save", systemImage: "tray.and.arrow.down").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Button(role: .destructive) {
                edited = nil
                history = []
                redoStack = []
                clock.selectedKeyframe = nil
                clock.reset(duration: span)
            } label: {
                Label("Discard", systemImage: "arrow.uturn.backward")
            }
        }

        if let saveNote {
            Text(saveNote).font(.footnote).foregroundStyle(Theme.good)
        }

        useForBooth
        runShot
    }

    /// The waypoint-level editor, folded away.
    @ViewBuilder
    private var advanced: some View {
        // Only as an "advanced extra" for moves the simple controls DO cover. When they do not,
        // the inspector is already inline above and a second copy would be confusing.
        if let e = edited,
           SimpleMove.from(e, startingAt: recorded?.position(at: 0) ?? 0) != nil {
            DisclosureGroup("Advanced — every waypoint", isExpanded: $showAdvanced) {
                inspector
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 4)
        }
    }

    /// Make the booth shoot this movement.
    ///
    /// 🔑 **This is the step that made the builder real.** Everything up to here produced a saved
    /// motion that nothing could use — the take runner only ever fired one of the 37 stored
    /// programs, so a beautifully tuned move sat in a list and never reached a guest.
    ///
    /// ⚠️ Saving first is required, not a nicety: the booth stores an ID and resolves the motion
    /// live, so pointing it at an unsaved edit would point it at nothing.
    @ViewBuilder
    private var useForBooth: some View {
        if let e = edited {
            let saved = motions.motions.contains { $0.id == e.id }
            let inUse = booth.boothMotionID == e.id.uuidString
            let synth = MotionTrace.synthesised(from: e)

            Divider().padding(.vertical, 4)

            if inUse {
                HStack {
                    Label("The booth is shooting this", systemImage: "checkmark.seal.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.good)
                    Spacer()
                    Button("Stop using") { booth.boothMotionID = nil }
                        .font(.footnote)
                }
            } else {
                Button {
                    // Save first — the booth resolves by id, so an unsaved edit would resolve to
                    // nothing and the take would silently fall back to the stored program.
                    MotionStore.shared.save(e)
                    booth.boothMotionID = e.id.uuidString
                    // The traverse has to cover this move, or the camera stops rolling mid-shot.
                    traverseKey = synth.recommendedTraverse
                    saveNote = "Saved, and the booth will shoot it."
                } label: {
                    Label(saved ? "Use this for the booth" : "Save and use for the booth",
                          systemImage: "camera.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            // ⚠️ Does the clip actually have room for it? A 12s move inside a 7s take at 4× is not
            // a shorter clip — it is a clip that stops partway through the move, and nothing else
            // on this screen would say so.
            let clip = booth.profile.deliveredDuration(hasEndCard: booth.endCard != nil)
            let covered = clip * (booth.profile.passes.first?.slowFactor ?? 4)
            if synth.moveDuration > covered + 0.3 {
                Text(String(format: "⚠️ This move runs %.1fs but the clip only covers %.1fs of it at %.1f×. Shorten the move, or fit the ramp to it.",
                            synth.moveDuration, covered, booth.profile.passes.first?.slowFactor ?? 4))
                    .font(.caption)
                    .foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Drive the edited motion on the real rail.
    ///
    /// 🚨 **THIS MOVES THE MACHINE, and it is the only thing on this screen that does.** Everything
    /// else here is a drawing. So it states what will happen before it happens — the travel, the
    /// duration, the speed — and it is gated on the rail being armed by a human, exactly like a
    /// preset trigger. Arming is never automatic; that rule has not moved all day.
    ///
    /// ⚠️ It plays through `MotionStore`, which walks the waypoints with `Position`/`Velocety`/
    /// `Execute` and POLLS FOR ARRIVAL at each one. It does not fire a stored program — there is no
    /// program to fire, because this motion exists only in the app.
    @ViewBuilder
    private var runShot: some View {
        if let motion = edited {
            let start = motion.waypoints.first.map { _ in recorded?.position(at: 0) ?? 0 } ?? 0
            let seconds = motion.duration(from: start)
            let span = motion.throwRange

            Divider().padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 8) {
                // Say what it will do BEFORE it does it. A button that moves a machine should
                // never be the first place you learn how far it travels.
                Text(String(format: "%.0f–%.0f mm over %.1fs, %d leg%@",
                            span.min, span.max, seconds,
                            motion.waypoints.count, motion.waypoints.count == 1 ? "" : "s"))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(Theme.secondary)

                Button {
                    Task {
                        guard let m = edited else { return }
                        saveNote = "Running on the rail…"
                        let ok = await MotionStore.shared.play(m)
                        saveNote = ok ? "Ran clean." : MotionStore.shared.progressNote
                    }
                } label: {
                    Label(MotionStore.shared.isPlaying ? "Running…" : "Run on the rail",
                          systemImage: "play.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.warn)
                .disabled(!link.connected || !safety.canDrive || MotionStore.shared.isPlaying
                          || link.isMotionBusy)

                if !safety.canDrive, let blocker = safety.blocker {
                    Text(blocker.message).font(.caption).foregroundStyle(Theme.warn)
                }
            }
        }
    }

    /// Numeric fine-tuning of the selected waypoint.
    ///
    /// ⚠️ Every value is clamped to what the machine will actually accept, at the point of entry
    /// rather than at run time. A slider that lets you ask for 300 mm/s and then silently runs at
    /// 100 teaches the wrong thing about the machine.
    @ViewBuilder
    private var inspector: some View {
        if let motion = edited,
           let idx = motion.waypoints.firstIndex(where: { $0.id == clock.selectedKeyframe }) {
            Card(title: "Waypoint \(idx + 1) of \(motion.waypoints.count)", systemImage: "smallcircle.filled.circle") {
                VStack(alignment: .leading, spacing: 14) {
                    slider("Go to",
                           value: Binding(get: { edited?.waypoints[idx].position ?? 0 },
                                          set: { edited?.waypoints[idx].position = $0 }),
                           range: PLC.positionRange, unit: "mm", step: 5)

                    slider("Speed",
                           value: Binding(get: { edited?.waypoints[idx].velocity ?? 85 },
                                          set: { edited?.waypoints[idx].velocity = $0 }),
                           range: PLC.velocityRange, unit: "mm/s", step: 1)

                    slider("Then wait",
                           value: Binding(get: { edited?.waypoints[idx].dwell ?? 0 },
                                          set: { edited?.waypoints[idx].dwell = $0 }),
                           range: 0...3, unit: "s", step: 0.05)

                    HStack {
                        Picker("Waypoint", selection: Binding(get: { clock.selectedKeyframe },
                                                              set: { clock.selectedKeyframe = $0 })) {
                            ForEach(Array(motion.waypoints.enumerated()), id: \.element.id) { i, w in
                                Text("\(i + 1) · \(Int(w.clampedPosition))mm").tag(Optional(w.id))
                            }
                        }
                        .pickerStyle(.segmented)

                        Button {
                            checkpoint()
                            edited?.waypoints.remove(at: idx)
                            clock.selectedKeyframe = edited?.waypoints.first?.id
                        } label: { Image(systemName: "minus.circle") }
                        .disabled(motion.waypoints.count <= 1)

                        Button {
                            checkpoint()
                            let w = motion.waypoints[idx]
                            edited?.waypoints.insert(MotionWaypoint(position: w.position,
                                                                    velocity: w.velocity,
                                                                    dwell: 0),
                                                     at: idx + 1)
                        } label: { Image(systemName: "plus.circle") }

                        Button {
                            guard let previous = history.popLast(), let current = edited else { return }
                            redoStack.append(current)
                            edited = previous
                            clock.duration = max(takeLength,
                                                 MotionTrace.synthesised(from: previous).duration, 1)
                        } label: { Image(systemName: "arrow.uturn.backward.circle") }
                        .disabled(history.isEmpty)

                        Button {
                            guard let next = redoStack.popLast(), let current = edited else { return }
                            history.append(current)
                            edited = next
                            clock.duration = max(takeLength,
                                                 MotionTrace.synthesised(from: next).duration, 1)
                        } label: { Image(systemName: "arrow.uturn.forward.circle") }
                        .disabled(redoStack.isEmpty)
                    }
                }
            }
            .onChange(of: edited) { _, new in
                guard let new else { return }
                clock.duration = max(takeLength, MotionTrace.synthesised(from: new).duration, 1)
            }
        }
    }

    /// A labelled value with a slider AND two nudge knobs.
    ///
    /// 🔑 **The knobs are not redundant with the slider.** A slider is for finding roughly the
    /// right value; it is hopeless for "5 mm further" on a 600 mm range, where one pixel is about
    /// 1.5 mm and a fingertip covers thirty. Once a move is nearly right, every remaining edit is
    /// a small nudge — so the nudge gets its own 44pt target rather than asking for pixel-accurate
    /// dragging on a machine console.
    ///
    /// Both routes clamp to `range`, so neither can ask the rail for something it will refuse.
    private func slider(_ title: String,
                        value: Binding<Double>,
                        range: ClosedRange<Double>,
                        unit: String,
                        step: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text(String(format: step < 1 ? "%.2f %@" : "%.0f %@", value.wrappedValue, unit))
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
            HStack(spacing: 12) {
                nudge("minus", value: value, range: range, by: -step)
                Slider(value: value, in: range, step: step)
                nudge("plus", value: value, range: range, by: step)
            }
        }
    }

    private func nudge(_ icon: String,
                       value: Binding<Double>,
                       range: ClosedRange<Double>,
                       by delta: Double) -> some View {
        Button {
            checkpoint()
            value.wrappedValue = min(range.upperBound, max(range.lowerBound, value.wrappedValue + delta))
        } label: {
            Image(systemName: icon)
                .font(.headline)
                .frame(width: 46, height: 44)
        }
        .buttonStyle(.bordered)
        // Held down, it repeats — nudging 300 mm one 5 mm tap at a time is sixty taps.
        // ⚠️ No checkpoint per repeat: a two-second hold would otherwise bury the undo stack in
        // twenty-four entries and push the state worth returning to off the end of it.
        .repeatOnHold {
            value.wrappedValue = min(range.upperBound, max(range.lowerBound, value.wrappedValue + delta))
        }
    }

    // MARK: Preset selector

    /// 🔑 **A card that cost 300pt to name one thing.** The picker held a menu, a "37 recorded"
    /// count, a row of saved-motion chips and a paragraph of explanation — permanently on screen,
    /// above the movement it was describing. With 37 stored programs plus saved motions, a menu was
    /// also the wrong control: it is a flat list you scroll blind, with no way to find "the 300 mm
    /// one" without opening every entry.
    ///
    /// So it is one line and a magnifying glass. The glass opens a searchable list; the line says
    /// what is loaded. Nothing else needs to be visible while you are working on a move.
    private var picker: some View {
        HStack(spacing: 12) {
            Text(currentName)
                .font(.title3.weight(.semibold))
                .lineLimit(1)

            if edited != nil {
                Text("edited")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Theme.warn.opacity(0.2), in: Capsule())
                    .foregroundStyle(Theme.warn)
            }

            Spacer()

            Button {
                searchOpen = true
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.headline)
                    .frame(width: 46, height: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Choose a movement")
        }
        .padding(.horizontal, 4)
        .sheet(isPresented: $searchOpen) { searchSheet }
    }

    private var currentName: String {
        if let e = edited { return e.name }
        return programs.presets.first { $0.number == program }?.display ?? "Program \(program)"
    }

    /// Every movement, searchable.
    private var searchSheet: some View {
        NavigationStack {
            List {
                if !motions.motions.isEmpty {
                    Section("My motions") {
                        ForEach(filteredMotions) { m in
                            Button {
                                edited = m
                                history = []; redoStack = []; saveNote = nil
                                clock.selectedKeyframe = m.waypoints.first?.id
                                clock.reset(duration: max(takeLength,
                                                          MotionTrace.synthesised(from: m).duration, 1))
                                searchOpen = false
                            } label: {
                                row(m.name,
                                    String(format: "%.1fs · %d leg%@", m.duration(from: 0),
                                           m.waypoints.count, m.waypoints.count == 1 ? "" : "s"),
                                    selected: edited?.id == m.id)
                            }
                            .swipeActions {
                                Button(role: .destructive) { pendingDelete = m } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }

                Section("Recorded from the rail") {
                    ForEach(filteredPresets) { p in
                        Button {
                            program = p.number
                            edited = nil
                            history = []; redoStack = []; saveNote = nil
                            searchOpen = false
                        } label: {
                            row(p.display, "Program \(p.number)",
                                selected: edited == nil && p.number == program)
                        }
                    }
                }
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search movements")
            .navigationTitle("Movements")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { searchOpen = false }
                }
            }
        }
    }

    private func row(_ title: String, _ detail: String, selected: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body)
                Text(detail).font(.caption).foregroundStyle(Theme.secondary)
            }
            Spacer()
            if selected {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.good)
            }
        }
        .contentShape(Rectangle())
    }

    /// ⚠️ Matches the NAME and the number. "Program 14" and "300" both have to find things — the
    /// generated names describe shape ("Half one-way · 2.2s") and the number is what an operator
    /// has written on a run sheet.
    private var filteredPresets: [ProgramStore.Preset] {
        guard !search.isEmpty else { return programs.presets }
        let q = search.lowercased()
        return programs.presets.filter {
            $0.display.lowercased().contains(q) || "program \($0.number)".contains(q) || "\($0.number)" == q
        }
    }

    private var filteredMotions: [CustomMotion] {
        guard !search.isEmpty else { return motions.motions }
        return motions.motions.filter { $0.name.lowercased().contains(search.lowercased()) }
    }

    // MARK: The tracks

    @ViewBuilder
    private func tracks(_ trace: MotionTrace, head: Double) -> some View {
        Card(title: "Timeline", systemImage: "chart.xyaxis.line",
             footnote: "Every row shares the same seconds across the width, so what lines up here lines up on the rail.") {
            VStack(alignment: .leading, spacing: 14) {
                track("Position · 0–600 mm", height: 150) {
                    positionTrack(trace, head: head)
                }
                track("Speed · mm/s", height: 70) {
                    speedTrack(trace, head: head)
                }
                if showRamp {
                    let profile = booth.profile
                    track("Slow-motion passes", height: 90) {
                        RampOnMotion(trace: trace,
                                     profile: profile,
                                     deadHead: booth.deadHeadSeconds(for: program),
                                     takeLength: takeLength)
                    }
                }
                if showCamera {
                    track("Camera", height: 54) {
                        cameraTrack(trace)
                    }
                }
            }
        }
    }

    /// One labelled row of the timeline.
    ///
    /// 🐞 **`.clipped()` is load-bearing, and its absence was visible the moment the screen was
    /// actually looked at.** `RampOnMotion` sizes its drawing to the curve it is given, not to the
    /// frame it is handed, so at 70pt it painted straight through the rows below it — the speed
    /// trace, the pass bands and the camera bar all landed on top of each other in one unreadable
    /// band. Every row is now clipped to its own height, which is also what makes the shared x-axis
    /// legible: rows that bleed into each other cannot be compared vertically, which is the entire
    /// point of stacking them.
    private func track<V: View>(_ title: String, height: CGFloat, @ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.secondary)
            content()
                .frame(height: height)
                .clipped()
        }
    }

    /// Position over time, with the playhead and a drag to scrub.
    private func positionTrack(_ trace: MotionTrace, head: Double) -> some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let span = self.span
            Canvas { ctx, size in
                let x: (Double) -> CGFloat = { CGFloat($0 / span) * size.width }
                // 🐞 **Inset, or the knobs at the ends of the travel are sliced in half.** 0 mm and
                // 600 mm are the two most-used positions on this rail — every full sweep starts and
                // ends on one of them — and mapping them to the exact top and bottom edges put
                // their handles half outside the clipped row. The one waypoint you cannot grab
                // should not be the one you reach for most.
                let pad: CGFloat = 26
                let y: (Double) -> CGFloat = {
                    size.height - pad - CGFloat($0 / 600) * (size.height - pad * 2)
                }

                // The rail's own limits, so an edit that would hit an end stop is visible.
                for mm in stride(from: 0.0, through: 600.0, by: 200) {
                    var line = Path()
                    line.move(to: CGPoint(x: 0, y: y(mm)))
                    line.addLine(to: CGPoint(x: size.width, y: y(mm)))
                    ctx.stroke(line, with: .color(Theme.secondary.opacity(0.15)), lineWidth: 1)
                }

                // 🔑 The original, ghosted underneath, whenever this is an edit. Without it the
                // screen shows a curve with no way to tell what was changed — and "is this better
                // than the stock move?" is the entire question the Studio exists to answer.
                // Drawn on the EDIT's time span, so a copy that runs slower than the original
                // (the velocity clamp guarantees that for the fast programs) still lines up at the
                // start rather than pretending the two durations match.
                if edited != nil, let original = recorded {
                    var ghost = Path()
                    var g = 0.0
                    while g <= min(span, original.duration) {
                        let pt = CGPoint(x: x(g), y: y(original.position(at: g)))
                        if g == 0 { ghost.move(to: pt) } else { ghost.addLine(to: pt) }
                        g += span / 240
                    }
                    ctx.stroke(ghost, with: .color(Theme.secondary.opacity(0.45)),
                               style: StrokeStyle(lineWidth: 2, dash: [4, 4]))
                }

                var path = Path()
                var t = 0.0
                while t <= span {
                    let pt = CGPoint(x: x(t), y: y(trace.position(at: t)))
                    if t == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                    t += span / 240
                }
                ctx.stroke(path, with: .color(Theme.accent), lineWidth: 2)

                // Waypoint handles, when this is an editable copy. Drawn as real targets you can
                // grab rather than as decoration on a read-only chart.
                if let motion = edited {
                    var t = 0.0
                    var here = motion.waypoints.first.map { _ in trace.position(at: 0) } ?? 0
                    for (i, w) in motion.waypoints.enumerated() {
                        let n = i + 1
                        let target = w.clampedPosition
                        t += abs(target - here) / max(1, w.clampedVelocity) + w.dwell
                        here = target
                        let c = CGPoint(x: x(min(t, span)), y: y(target))
                        let selected = w.id == clock.selectedKeyframe
                        // 🔑 Knob-sized, not dot-sized. These are dragged with a fingertip on a
                        // moving-machine console, so they are built to the ~44pt touch target
                        // rather than to what looks tidy in a screenshot. A 6pt dot is findable
                        // with a mouse and invisible under a thumb.
                        let r: CGFloat = selected ? 17 : 14
                        // Halo, so the grabbable area reads as bigger than the knob itself.
                        ctx.fill(Path(ellipseIn: CGRect(x: c.x - r - 7, y: c.y - r - 7,
                                                        width: (r + 7) * 2, height: (r + 7) * 2)),
                                 with: .color((selected ? Theme.good : Theme.accent).opacity(0.18)))
                        ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                                 with: .color(selected ? Theme.good : Theme.accent))
                        ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                                   with: .color(.white.opacity(0.95)), lineWidth: 3)
                        // Numbered, so a knob on the track and a row in the inspector are
                        // recognisably the same waypoint.
                        ctx.draw(Text("\(n)").font(.caption.bold()).foregroundStyle(.black),
                                 at: c)
                        if selected {
                            // 🐞 Was `max(12, c.y - r - 16)`, which pinned the label ON TOP of the
                            // knob whenever the waypoint sat near the top of the rail — the most
                            // common case, since 600 mm is where most sweeps end. Flip below when
                            // there is no room above, and keep clear of the knob either way.
                            let above = c.y - r - 15
                            let ly = above > 12 ? above : c.y + r + 15
                            ctx.draw(Text("\(Int(target)) mm")
                                        .font(.caption2.bold()).foregroundStyle(Theme.good),
                                     at: CGPoint(x: min(max(c.x, 34), size.width - 34), y: ly))
                        }
                    }
                }

                // 🔑 **DWELL HANDLES, in their own lane along the bottom.**
                //
                // Dwell is the one value where a horizontal drag is honest. Position is vertical and
                // speed is vertical because on this machine TIME is a consequence of distance and
                // speed — dragging a waypoint sideways would have to silently rewrite a speed
                // nobody touched. A pause is different: it adds time at a point and changes neither
                // the distance travelled nor the speed of any leg, so sideways is exactly what it
                // means.
                //
                // ⚠️ The handle's X is the real time the hold ENDS (arrival + dwell) — so with no
                // dwell it sits directly under its waypoint, and the gap between them IS the pause,
                // visible at a glance. Only the Y is a lane; putting it in the bottom inset keeps
                // it clear of the position knobs without lying about when it happens.
                if let motion = edited {
                    var dt = 0.0
                    var dHere = trace.position(at: 0)
                    let lane = size.height - 13
                    for (i, w) in motion.waypoints.enumerated() {
                        let target = w.clampedPosition
                        let arrive = dt + abs(target - dHere) / max(1, w.clampedVelocity)
                        let ends = arrive + w.dwell
                        dt = ends
                        dHere = target
                        guard ends <= span else { continue }
                        let selected = w.id == clock.selectedKeyframe
                        // The hold itself, drawn as the bar it is.
                        if w.dwell > 0.01 {
                            var bar = Path()
                            bar.move(to: CGPoint(x: x(arrive), y: lane))
                            bar.addLine(to: CGPoint(x: x(ends), y: lane))
                            ctx.stroke(bar, with: .color(Theme.warn.opacity(0.85)), lineWidth: 5)
                        }
                        let c = CGPoint(x: x(ends), y: lane)
                        let r: CGFloat = selected ? 11 : 9
                        ctx.fill(Path(ellipseIn: CGRect(x: c.x - r - 6, y: c.y - r - 6,
                                                        width: (r + 6) * 2, height: (r + 6) * 2)),
                                 with: .color(Theme.warn.opacity(0.18)))
                        ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                                 with: .color(w.dwell > 0.01 ? Theme.warn : Theme.secondary))
                        ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                                   with: .color(.white.opacity(0.9)), lineWidth: 2)
                        if selected {
                            ctx.draw(Text(String(format: "hold %.2fs", w.dwell))
                                        .font(.caption2.bold()).foregroundStyle(Theme.warn),
                                     at: CGPoint(x: c.x, y: lane - 18))
                        }
                        _ = i
                    }
                }

                // Turnarounds — the moments a ramp pass wants to sit on.
                for turn in trace.turnarounds {
                    var mark = Path()
                    mark.move(to: CGPoint(x: x(turn), y: 0))
                    mark.addLine(to: CGPoint(x: x(turn), y: size.height))
                    ctx.stroke(mark, with: .color(Theme.warn.opacity(0.5)),
                               style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }

                var ph = Path()
                ph.move(to: CGPoint(x: x(head), y: 0))
                ph.addLine(to: CGPoint(x: x(head), y: size.height))
                ctx.stroke(ph, with: .color(Theme.good), lineWidth: 2)
            }
            .frame(height: h)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let t = Double(g.location.x / w) * span
                        // 🔑 The handle is chosen ONCE, at touch-down, and kept for the whole drag.
                        // Re-picking the nearest handle on every change makes a waypoint dragged
                        // past its neighbour hand the gesture over to that neighbour mid-move,
                        // which feels like the curve fighting back.
                        // ⚠️ Dwell is hit-tested FIRST. Its lane sits inside the position track, so
                        // testing position knobs first would win near the bottom of the chart and a
                        // dwell handle would be ungrabbable wherever a waypoint happened to be low
                        // on the rail.
                        if dragging == nil, dwellDragging == nil {
                            dwellDragging = dwellHandle(near: g.startLocation, width: w, height: h,
                                                        span: span, trace: trace)
                            if dwellDragging != nil {
                                clock.selectedKeyframe = dwellDragging
                                checkpoint()
                            }
                        }
                        if let id = dwellDragging,
                           let idx = edited?.waypoints.firstIndex(where: { $0.id == id }) {
                            // Horizontal only: the hold ends where the finger is, and its length is
                            // that moment minus the arrival it already had.
                            let arrive = arrivalTime(ofWaypointAt: idx, trace: trace)
                            let held = min(3, max(0, t - arrive))
                            edited?.waypoints[idx].dwell = (held * 20).rounded() / 20   // 0.05s steps
                            return
                        }

                        if dragging == nil {
                            dragging = handle(near: g.startLocation, width: w, height: h, span: span)
                            if dragging == nil { clock.scrub(to: t) ; return }
                            clock.selectedKeyframe = dragging
                            // One undo entry per drag, taken before the first pixel moves.
                            checkpoint()
                        }
                        guard let id = dragging,
                              let idx = edited?.waypoints.firstIndex(where: { $0.id == id }) else { return }
                        // Vertical is position. Horizontal is left to the sliders: on this machine
                        // time is a CONSEQUENCE of distance and speed, so dragging sideways would
                        // have to silently rewrite a speed the operator did not ask to change.
                        let pad: CGFloat = 26
                        var mm = Double((h - pad - g.location.y) / max(1, h - pad * 2)) * 600
                        // 🔑 Snapping to 25 mm is what makes a dragged move REPEATABLE. Free
                        // dragging lands on 412.7 mm, and the same move built again tomorrow lands
                        // on 409.1 — close enough to look identical on screen and different enough
                        // that two "matching" passes do not match. The ends of travel snap exactly,
                        // because 0 and 600 are the positions a sweep is actually built from.
                        if snap { mm = (mm / 25).rounded() * 25 }
                        edited?.waypoints[idx].position = min(PLC.positionRange.upperBound,
                                                              max(PLC.positionRange.lowerBound, mm))
                    }
                    .onEnded { _ in
                        dragging = nil
                        if let e = edited {
                            clock.duration = max(takeLength, MotionTrace.synthesised(from: e).duration, 1)
                        }
                    }
            )
        }
    }

    /// Speed, with the manual-drive clamp drawn across it.
    private func speedTrack(_ trace: MotionTrace, head: Double) -> some View {
        GeometryReader { geo in
        Canvas { ctx, size in
            let span = self.span
            // 🔑 Scaled to the FASTEST thing actually recorded, not to the clamp. Program 14 runs
            // at 143 mm/s — well past the 70–100 window the manual Position/Velocety path is held
            // to — so a chart topping out at 100 would clip the very fact worth seeing.
            let peak = max(120.0, (0...240).map { abs(trace.velocity(at: Double($0) / 240 * span)) }.max() ?? 120)
            let x: (Double) -> CGFloat = { CGFloat($0 / span) * size.width }
            // 🐞 **Inset, for the same reason the position track needed it.** Without it a handle at
            // the top of the range is drawn half outside the clipped row — and the top of the range
            // is exactly where a speed handle sits once the ceiling is 143 and the move uses it.
            let vpad: CGFloat = 20
            let y: (Double) -> CGFloat = {
                size.height - vpad - CGFloat(min($0, peak) / peak) * (size.height - vpad * 2)
            }

            // The band a DRIVEN move must live inside. A stored program may sit above it, and
            // seeing that is the point: an editable copy cannot go there.
            let band = CGRect(x: 0, y: y(PLC.velocityRange.upperBound),
                              width: size.width,
                              height: y(PLC.velocityRange.lowerBound) - y(PLC.velocityRange.upperBound))
            ctx.fill(Path(band), with: .color(Theme.good.opacity(0.12)))

            var path = Path()
            var t = 0.0
            while t <= span {
                let pt = CGPoint(x: x(t), y: y(abs(trace.velocity(at: t))))
                if t == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                t += span / 240
            }
            ctx.stroke(path, with: .color(Theme.warn), lineWidth: 2)

            // 🔑 **A handle per leg on the SPEED track too.** Position had grabbable knobs and
            // speed did not, so half the movement was direct and half was buried in sliders. Each
            // ball sits at the middle of the leg it governs, drags vertically to set that leg's
            // speed, and is numbered to match the waypoint it belongs to.
            if let motion = edited {
                var lt = 0.0
                var here = trace.position(at: 0)
                for (i, w) in motion.waypoints.enumerated() {
                    let target = w.clampedPosition
                    let legTime = abs(target - here) / max(1, w.clampedVelocity)
                    let mid = lt + legTime / 2
                    lt += legTime + w.dwell
                    here = target
                    guard legTime > 0.05, mid <= span else { continue }
                    let c = CGPoint(x: x(mid), y: y(w.clampedVelocity))
                    let selected = w.id == clock.selectedKeyframe
                    let r: CGFloat = selected ? 15 : 12
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - r - 6, y: c.y - r - 6,
                                                    width: (r + 6) * 2, height: (r + 6) * 2)),
                             with: .color((selected ? Theme.good : Theme.warn).opacity(0.18)))
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                             with: .color(selected ? Theme.good : Theme.warn))
                    ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                               with: .color(.white.opacity(0.95)), lineWidth: 3)
                    ctx.draw(Text("\(i + 1)").font(.caption2.bold()).foregroundStyle(.black), at: c)
                    if selected {
                        let above = c.y - r - 14
                        let ly = above > 11 ? above : c.y + r + 14
                        ctx.draw(Text("\(Int(w.clampedVelocity)) mm/s")
                                    .font(.caption2.bold()).foregroundStyle(Theme.good),
                                 at: CGPoint(x: min(max(c.x, 40), size.width - 40), y: ly))
                    }
                }
            }

            var ph = Path()
            ph.move(to: CGPoint(x: x(head), y: 0))
            ph.addLine(to: CGPoint(x: x(head), y: size.height))
            ctx.stroke(ph, with: .color(Theme.good), lineWidth: 2)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    guard let motion = edited else { return }
                    let peak = max(PLC.velocityRange.upperBound, 120)
                    if speedDragging == nil {
                        speedDragging = speedHandle(near: g.startLocation, in: geo.size,
                                                    trace: trace, peak: peak)
                        guard speedDragging != nil else { return }
                        clock.selectedKeyframe = speedDragging
                        checkpoint()
                    }
                    guard let id = speedDragging,
                          let idx = motion.waypoints.firstIndex(where: { $0.id == id }) else { return }
                    // Up is faster. Clamped at entry, like every other control here.
                    let vpad: CGFloat = 20
                    let v = Double((geo.size.height - vpad - g.location.y) / max(1, geo.size.height - vpad * 2)) * peak
                    edited?.waypoints[idx].velocity = min(PLC.velocityRange.upperBound,
                                                          max(PLC.velocityRange.lowerBound, v))
                }
                .onEnded { _ in
                    speedDragging = nil
                    if let e = edited {
                        clock.duration = max(takeLength, MotionTrace.synthesised(from: e).duration, 1)
                    }
                }
        )
        }
    }

    /// When the carriage ARRIVES at a waypoint, before its own hold.
    private func arrivalTime(ofWaypointAt index: Int, trace: MotionTrace) -> Double {
        guard let motion = edited else { return 0 }
        var t = 0.0
        var here = trace.position(at: 0)
        for (i, w) in motion.waypoints.enumerated() {
            let target = w.clampedPosition
            let arrive = t + abs(target - here) / max(1, w.clampedVelocity)
            if i == index { return arrive }
            t = arrive + w.dwell
            here = target
        }
        return t
    }

    /// Which dwell handle is under a touch.
    private func dwellHandle(near p: CGPoint, width: CGFloat, height: CGFloat,
                             span: Double, trace: MotionTrace) -> UUID? {
        guard let motion = edited else { return nil }
        let lane = height - 13
        // Only worth testing near the lane at all — otherwise a tap anywhere on the chart could
        // capture a dwell handle instead of scrubbing.
        guard abs(p.y - lane) < 30 else { return nil }
        var t = 0.0
        var here = trace.position(at: 0)
        var best: (id: UUID, d: CGFloat)?
        for w in motion.waypoints {
            let target = w.clampedPosition
            let ends = t + abs(target - here) / max(1, w.clampedVelocity) + w.dwell
            t = ends
            here = target
            let cx = CGFloat(min(ends, span) / span) * width
            let d = abs(cx - p.x)
            if d < 30, best == nil || d < best!.d { best = (w.id, d) }
        }
        return best?.id
    }

    /// Which speed handle is under a touch.
    private func speedHandle(near p: CGPoint, in size: CGSize,
                             trace: MotionTrace, peak: Double) -> UUID? {
        guard let motion = edited else { return nil }
        var lt = 0.0
        var here = trace.position(at: 0)
        var best: (id: UUID, d: CGFloat)?
        for w in motion.waypoints {
            let target = w.clampedPosition
            let legTime = abs(target - here) / max(1, w.clampedVelocity)
            let mid = lt + legTime / 2
            lt += legTime + w.dwell
            here = target
            guard legTime > 0.05 else { continue }
            let vpad: CGFloat = 20
            let c = CGPoint(x: CGFloat(min(mid, span) / span) * size.width,
                            y: size.height - vpad - CGFloat(min(w.clampedVelocity, peak) / peak) * (size.height - vpad * 2))
            let d = hypot(c.x - p.x, c.y - p.y)
            if d < 34, best == nil || d < best!.d { best = (w.id, d) }
        }
        return best?.id
    }

    /// Lead-in, the recording window, and where the take stops.
    private func cameraTrack(_ trace: MotionTrace) -> some View {
        Canvas { ctx, size in
            let span = self.span
            let x: (Double) -> CGFloat = { CGFloat($0 / span) * size.width }

            // The rail does nothing for the dead head; the camera is already rolling. Showing them
            // on one axis is how a 0.4s assumption against a 4.0s reality becomes visible.
            let dead = trace.latency
            ctx.fill(Path(CGRect(x: 0, y: 6, width: x(dead), height: size.height - 12)),
                     with: .color(Theme.secondary.opacity(0.25)))
            // ⚠️ Only when the band is wide enough to hold the words. A short dead head drew this
            // centred at a few pixels from the left edge, so it rendered as "ad 0.0s".
            if x(dead) > 90 {
                ctx.draw(Text("dead head \(String(format: "%.1fs", dead))")
                            .font(.caption2).foregroundStyle(Theme.secondary),
                         at: CGPoint(x: x(dead) / 2, y: size.height / 2))
            }

            ctx.fill(Path(CGRect(x: x(dead), y: 6,
                                 width: x(min(span, dead + trace.moveDuration)) - x(dead),
                                 height: size.height - 12)),
                     with: .color(Theme.accent.opacity(0.30)))

            // Where the take actually stops recording.
            let end = takeLength - booth.leadIn
            if end > 0, end < span {
                var mark = Path()
                mark.move(to: CGPoint(x: x(end), y: 0))
                mark.addLine(to: CGPoint(x: x(end), y: size.height))
                ctx.stroke(mark, with: .color(Theme.bad),
                           style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
            }
        }
    }

    /// Which waypoint handle, if any, is under a touch.
    private func handle(near p: CGPoint, width: CGFloat, height: CGFloat, span: Double) -> UUID? {
        guard let motion = edited, let trace else { return nil }
        var t = 0.0
        var here = trace.position(at: 0)
        var best: (id: UUID, d: CGFloat)?
        for w in motion.waypoints {
            let target = w.clampedPosition
            t += abs(target - here) / max(1, w.clampedVelocity) + w.dwell
            here = target
            let pad: CGFloat = 26
            let c = CGPoint(x: CGFloat(min(t, span) / span) * width,
                            y: height - pad - CGFloat(target / 600) * (height - pad * 2))
            let d = hypot(c.x - p.x, c.y - p.y)
            if d < 34, best == nil || d < best!.d { best = (w.id, d) }
        }
        return best?.id
    }

    // MARK: Validation

    /// The real constraints of THIS machine, checked and stated.
    ///
    /// ⚠️ Not reach envelopes, payload or joint singularities — a linear rail has none of those.
    /// What it has is an end stop at each end, a velocity window that only DRIVEN moves must obey,
    /// and a frame budget that decides whether slow motion repeats frames.
    @ViewBuilder
    private func warnings(_ trace: MotionTrace) -> some View {
        let peak = (0...240).map { abs(trace.velocity(at: Double($0) / 240 * trace.duration)) }.max() ?? 0
        let overClamp = peak > PLC.velocityRange.upperBound + 5
        let profile = booth.profile
        let overBudget = profile.overBudgetPasses
        let simulatedHead = booth.deadHeadIsFromSimulation(for: program)

        if overClamp || !overBudget.isEmpty || simulatedHead {
            Card(title: "Worth knowing", systemImage: "exclamationmark.triangle") {
                VStack(alignment: .leading, spacing: 10) {
                    if overClamp {
                        note("This program peaks at \(Int(peak)) mm/s, above the \(Int(PLC.velocityRange.upperBound)) mm/s ceiling on driven moves. An editable copy will be slower than the original — the stored programs are not held to the manual clamp.")
                    }
                    if !overBudget.isEmpty {
                        note("Pass \(overBudget.map { String($0 + 1) }.joined(separator: ", ")) asks for more slow motion than \(Int(profile.sourceFPS))fps can pay for, so output frames will repeat. Shorten the pass or shoot faster.")
                    }
                    if simulatedHead {
                        note("The dead head here comes from a SIMULATED run, not a recorded one. Capture this program on the real rail before trusting the camera timing.")
                    }
                }
            }
        }
    }

    /// The subset of `warnings` that matters even when the charts are hidden.
    @ViewBuilder
    private func quietWarnings(_ trace: MotionTrace) -> some View {
        let over = booth.profile.overBudgetPasses
        if !over.isEmpty {
            note("Pass \(over.map { String($0 + 1) }.joined(separator: ", ")) asks for more slow motion than \(Int(booth.profile.sourceFPS))fps can pay for — frames will repeat.")
        }
    }

    private func note(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.circle")
            .font(.footnote)
            .foregroundStyle(Theme.warn)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private extension View {
    /// Fire `action` repeatedly while the control is held.
    ///
    /// Tuned for nudging a 600 mm axis in 5 mm steps: a beat before it starts so a normal tap is
    /// still a single step, then ~12/second, which walks the full travel in about ten seconds.
    func repeatOnHold(_ action: @escaping () -> Void) -> some View {
        modifier(RepeatOnHold(action: action))
    }
}

private struct RepeatOnHold: ViewModifier {
    let action: () -> Void
    @State private var timer: Timer?

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.35)
                    .onEnded { _ in
                        // ⚠️ Invalidated in onDisappear as well as on release — a repeat left
                        // running after the inspector closes would keep writing to a waypoint that
                        // is no longer on screen.
                        timer?.invalidate()
                        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12, repeats: true) { _ in
                            Task { @MainActor in action() }
                        }
                    }
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { _ in timer?.invalidate(); timer = nil }
            )
            .onDisappear { timer?.invalidate(); timer = nil }
    }
}
