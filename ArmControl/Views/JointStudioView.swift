import SwiftUI

// MARK: - Authoring a move by posing the arm
//
// 🔑 **WHAT THIS REPLACES, AND WHY IT IS A NEW SCREEN RATHER THAN AN EDIT.** The existing Studio is
// 2,000 lines built around a single idea: take a RAIL recording and reshape its curve. That is the
// right tool for the Glamatic, which has one axis and whose stored programs cannot be read. It is
// the wrong tool for the arm, which has five, and it could not be stretched to cover them — a
// position/velocity/dwell row has nowhere to put four more joints.
//
// So this screen does the thing that screen cannot: **put every joint where you want it, keep the
// pose, and string poses into a movement.** No curve editing, no timeline, no ramp panel. Those
// still live next door for the rail.
//
// 🔑 **NO `TimelineView` HERE, DELIBERATELY.** The Studio drives its entire body from
// `TimelineView(.animation)`, re-rendering every track on every frame — and "laggy, freezes"
// is exactly what it was reported as. Live joint angles arrive on `XArmLink`'s 4 Hz poll through
// `@Published`, so SwiftUI redraws four times a second when something actually changed. A rail
// curve needs per-frame animation; five numbers do not.
//
// ⚠️ **THE ARM IS A REAL MACHINE WITH FIVE JOINTS AND NO VERIFIED LIMIT TABLE.** Nothing here
// enables, moves or homes anything without a tap. Jogs are small relative steps from the measured
// pose, so the controller is the authority on what is reachable — see `XArmLink`'s note on why
// there are no invented limit numbers.
struct JointStudioView: View {
    @StateObject private var arm = XArmLink.shared
    @StateObject private var store = ArmMotionStore.shared
    @StateObject private var safety = SafetyKernel.shared
    @StateObject private var link = GlamaticLink.shared

    /// Degrees per jog tap. Coarse gets you across the range; fine places the shot.
    @AppStorage("armcontrol.joint.step") private var step: Double = 5
    @State private var saveName = ""
    @State private var showSave = false
    @State private var pendingDelete: ArmMotion?
    @State private var busy: Int?
    @State private var editingPose: ArmPose?
    @State private var editingIndex = 1
    @StateObject private var recorder = RigRecorder.shared
    @AppStorage("armcontrol.record.program") private var recordProgram = 14
    @AppStorage("armcontrol.record.runsProgram") private var recordRunsProgram = true
    @State private var openTrace: RigTrace?
    @State private var confirmNeutral = false
    @State private var confirmHandGuide = false

    /// "20°/s · hold 0.30s · rail 300 mm" — everything about the pose that is not a joint angle.
    private func poseDetail(_ p: ArmPose) -> String {
        var s = String(format: "%.0f°/s · hold %.2fs", p.speed, p.dwell)
        if let mm = p.clampedRail { s += String(format: " · rail %.0f mm", mm) }
        return s
    }

    private static let steps: [Double] = [1, 5, 15]

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                handGuideBanner
                foreignMotionBanner
                linkCard
                if arm.connected {
                    jointsCard
                    sequenceCard
                }
                recordCard
                libraryCard
            }
            .padding()
            .frame(maxWidth: 760)          // a form this narrow reads better than a 1366pt sprawl
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .navigationTitle("Pose Studio")
        // Telemetry only while the screen is open — a 4 Hz poll against a link that serialises
        // every request is not something to leave running behind the booth screen.
        .task {
            arm.startPolling()
        }
        .onDisappear { arm.stopPolling() }
        .sheet(item: $editingPose) { p in
            PoseEditorView(pose: p, index: editingIndex)
        }
        .sheet(item: $openTrace) { t in
            TimelineEditorView(trace: t)
        }
        // ⚠️ Confirmed, never automatic. From an over-limit joint the path to neutral can sweep most
        // of the arm's range through whatever is in front of it.
        .confirmationDialog("Move the arm to neutral?",
                            isPresented: $confirmNeutral, titleVisibility: .visible) {
            Button("Move to neutral") {
                Task {
                    if arm.errorCode != 0 { await arm.recoverAndGoNeutral() }
                    else { await arm.goNeutral() }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The arm travels to \(arm.neutralLabel) at 10°/s. It can sweep a long way — make sure the path is clear.")
        }
        // ⚠️ The warning IS the feature. Releasing the brakes on an arm held up by its servos means
        // it comes down, and the person tapping this is standing next to it.
        .confirmationDialog("Release the joints?",
                            isPresented: $confirmHandGuide, titleVisibility: .visible) {
            Button("I'm holding the arm — release it", role: .destructive) {
                Task { await arm.startHandGuiding() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("TAKE THE WEIGHT OF THE ARM FIRST. Its servos are what hold it up, and this switches them off — it will sag or drop under its own weight. Once released you can move it by hand, then tap Lock the joints.")
        }
        .alert("Name this movement", isPresented: $showSave) {
            TextField("Name", text: $saveName)
            Button("Save") { _ = store.saveRecording(as: saveName); saveName = "" }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("\(store.recording.count) pose\(store.recording.count == 1 ? "" : "s") will be saved.")
        }
        .confirmationDialog("Delete this movement?",
                            isPresented: .init(get: { pendingDelete != nil },
                                               set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let m = pendingDelete { store.delete(m) }
                pendingDelete = nil
            }
        }
    }

    // MARK: Hands on the arm

    /// ⚠️ **Loud, top of screen, and impossible to lose.** An arm with its brakes off looks exactly
    /// like an arm with its brakes on until you let go of it. Leaving this state by accident is how
    /// something gets dropped.
    @ViewBuilder
    private var handGuideBanner: some View {
        if arm.handGuiding {
            VStack(alignment: .leading, spacing: 10) {
                Label("JOINTS RELEASED — the arm is not holding itself up",
                      systemImage: "hand.raised.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Pivot.danger)
                Text("Move it clear of whatever it hit, then lock the joints before letting go.")
                    .font(.footnote)
                Button {
                    Task { await arm.stopHandGuiding() }
                } label: {
                    Label("Lock the joints", systemImage: "lock.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Pivot.danger)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Pivot.danger.opacity(0.15),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Pivot.danger, lineWidth: 2)
            )
        }
    }

    // MARK: Someone else is driving

    /// 🔑 **The banner that would have saved two evenings.** Twice now a "runaway"/"glitch" has been
    /// chased through PLC theories when the cause was a second app — PivotBooth's Follow Me loop —
    /// driving the same rail from another iPad. The signature is mechanical and checkable: the
    /// carriage moves while this app commanded nothing. So say it, in the place the operator is
    /// already looking, instead of leaving it to be re-derived.
    @ViewBuilder
    private var foreignMotionBanner: some View {
        if link.foreignMotionCount > 0 {
            VStack(alignment: .leading, spacing: 8) {
                Label(link.foreignMotionActive
                      ? "Something else is driving this rail RIGHT NOW"
                      : "Something else was driving this rail",
                      systemImage: "person.2.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Pivot.danger)
                Text("The carriage moved \(link.foreignMotionCount) time\(link.foreignMotionCount == 1 ? "" : "s") without a command from this app. The usual cause is **PivotBooth open on another iPad** — its Follow Me loop drives this same rail continuously and reconnects itself after any interruption.")
                    .font(.footnote)
                Text("Force-quit PivotBooth on the other iPad. Nothing in this app can stop it.")
                    .font(.footnote.weight(.semibold))
                Button("Dismiss") { link.clearForeignMotion() }
                    .font(.footnote)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Pivot.danger.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Pivot.danger.opacity(0.5), lineWidth: 1)
            )
        }
    }

    // MARK: The link

    private var linkCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("The arm", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.headline)
                Spacer()
                // 🔑 A recovery that takes 30s and looks idle is what makes someone tap it again —
                // which used to start a SECOND sequence. Show the work.
                if arm.motionBusy { ProgressView().controlSize(.small) }
                Text(arm.status)
                    .font(.subheadline)
                    .foregroundStyle(arm.motionBusy ? Pivot.caution : .secondary)
                    .multilineTextAlignment(.trailing)
            }

            if arm.motionBusy {
                Button {
                    Task { await arm.eStop() }
                } label: {
                    DestructiveLabel("Stop the arm", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Pivot.danger)
            }

            // ⚠️ Never a disabled control without its reason beside it — a silent grey button is
            // what makes someone tap it eleven times.
            if !arm.connected {
                Text("Not connected. The arm is on the wired LAN at \(XArmLink.host) — the iPad needs its Ethernet adapter and a 192.168.1.x address.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if arm.errorCode != 0 {
                VStack(alignment: .leading, spacing: 8) {
                    Label(arm.faultText, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Pivot.danger)
                    if arm.faultNeedsHardware {
                        // Do not offer a software fix for a physical cause — that just teaches
                        // someone to tap a button eleven times instead of walking to the machine.
                        Text("This one has a physical cause. Release the e-stop or check the joint, then clear it.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    // 🔑 **Collision first, because the right recovery is the opposite one.** Walking
                    // to neutral from a collided pose can drive the arm further into what it hit;
                    // the path it just came along is the only one known to be clear.
                    if arm.errorCode == 22 {
                        Text("Self-collision. Backing out the way it came is safer than heading for neutral — a path to neutral can push it further into whatever it hit.")
                            .font(.caption).foregroundStyle(Pivot.caution)
                    }

                    Button {
                        Task { await arm.backOut() }
                    } label: {
                        Label("Back out the way it came", systemImage: "arrow.uturn.backward")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(arm.errorCode == 22 ? Pivot.caution : Pivot.blue)
                    .disabled(!arm.hasBackOutPath)

                    if !arm.hasBackOutPath {
                        Text("No recent path recorded — this only works if the arm moved under the app's control just before it stuck.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    // The answer to "it won't fix the part that collided": stop trying to be clever
                    // and hand control back to the person who can see the arm.
                    Button {
                        Task { await arm.clearAndEnableForJogging() }
                    } label: {
                        Label("Clear it and let me jog it myself", systemImage: "hand.point.up.left")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    // 🔑 The last resort, and for an arm folded onto itself the FIRST thing that
                    // actually works. Software cannot plan out of a pose the controller calls
                    // invalid; hands can.
                    Button {
                        confirmHandGuide = true
                    } label: {
                        Label("Release the joints — move it by hand", systemImage: "hand.raised.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(Pivot.danger)

                    Text("Clears the fault and leaves the arm live, so you can jog the exact joint that hit something using the controls below.")
                        .font(.caption).foregroundStyle(.secondary)

                    Button {
                        confirmNeutral = true
                    } label: {
                        Label("Walk it to neutral", systemImage: "figure.walk")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        Task { await arm.recoverFromFault() }
                    } label: {
                        Label("Just clear the fault", systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            } else if !arm.motionEnabled {
                Text("Connected but not energised. Enable puts the servos under power — it moves nothing on its own.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button {
                    Task { await arm.connect() }
                } label: {
                    Label(arm.connected ? "Reconnect" : "Connect", systemImage: "cable.connector")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                if arm.motionEnabled {
                    Button {
                        Task { await arm.disable() }
                    } label: {
                        DestructiveLabel("Disable", systemImage: "bolt.slash.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        Task { await arm.enable() }
                    } label: {
                        Label("Enable", systemImage: "bolt.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!arm.connected)
                }
            }

            if arm.motionEnabled {
                // The one genuinely loud thing on the screen. An energised five-joint arm that
                // looks identical to an idle one is the state you do not want to misread.
                Label(arm.simulated ? "SIMULATED — no arm is moving" : "LIVE — the arm will move",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(arm.simulated ? Pivot.purple : Pivot.caution)

                // Start every session from a known place rather than from wherever it was left.
                HStack(spacing: 10) {
                    Button {
                        confirmNeutral = true
                    } label: {
                        Label("Go to neutral", systemImage: "figure.stand")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        arm.neutralPose = Array(arm.joints.prefix(XArmLink.jointCount))
                    } label: {
                        Label("Set as neutral", systemImage: "pin")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(arm.joints.isEmpty)
                }
                Text("Neutral: \(arm.neutralLabel)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }

            // Reachable without a fault code too — an arm can be physically stuck while the
            // controller reports nothing wrong at all.
            if arm.connected, !arm.handGuiding, arm.errorCode == 0 {
                Button {
                    confirmHandGuide = true
                } label: {
                    Label("Release the joints — move it by hand", systemImage: "hand.raised")
                        .font(.footnote)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Pivot.danger)
            }

            Divider()

            // 🔑 Authoring needs to happen the night before, on a sofa, with no arm and no adapter.
            // Kept here rather than buried in Engineer settings because this is the screen where
            // the distinction between a real arm and a pretend one matters most.
            Toggle(isOn: $arm.simulated) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Simulated arm").font(.subheadline)
                    Text("Build movements with no hardware connected. Poses save and play exactly the same on the real arm.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .pivotGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: The joints

    private var jointsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Joints", systemImage: "slider.horizontal.3").font(.headline)
                Spacer()
                Picker("Step", selection: $step) {
                    ForEach(Self.steps, id: \.self) { Text("\(Int($0))°").tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 170)
            }

            ForEach(0..<XArmLink.jointCount, id: \.self) { i in
                jointRow(i)
                if i < XArmLink.jointCount - 1 { Divider() }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Speed").font(.subheadline)
                    Spacer()
                    Text("\(Int(arm.jointSpeed))°/s")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $arm.jointSpeed, in: 5...FactoryPrograms.maxSpeed, step: 1)
            }
        }
        .padding()
        .pivotGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func jointRow(_ i: Int) -> some View {
        let angle = i < arm.joints.count ? arm.joints[i] : 0
        return HStack(spacing: 12) {
            Text("J\(i + 1)")
                .font(.subheadline.weight(.semibold))
                .frame(width: 34, alignment: .leading)

            // tabular-nums so a jogging joint does not make the row twitch sideways
            Text("\(Int(angle.rounded()))°")
                .font(.title3.monospacedDigit())
                .frame(width: 64, alignment: .trailing)
                .foregroundStyle(arm.motionEnabled ? .primary : .secondary)

            Spacer()

            jogButton(i, -step, "minus")
            jogButton(i, step, "plus")
        }
        .opacity(busy == i ? 0.55 : 1)
    }

    private func jogButton(_ i: Int, _ delta: Double, _ symbol: String) -> some View {
        Button {
            busy = i
            Task {
                await arm.jogJoint(i, delta)
                busy = nil
            }
        } label: {
            Image(systemName: symbol)
                .font(.headline)
                .frame(width: 52, height: 42)
        }
        .buttonStyle(.bordered)
        .disabled(!arm.motionEnabled || busy != nil)
    }

    // MARK: Building a movement

    private var sequenceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(store.editingName.map { "Editing “\($0)”" } ?? "This movement",
                      systemImage: "list.number").font(.headline)
                Spacer()
                if !store.recording.isEmpty {
                    Text("\(store.recording.count) pose\(store.recording.count == 1 ? "" : "s")")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }

            if store.recording.isEmpty {
                Text("Jog the joints until the shot looks right, then keep the pose. Repeat for each beat of the move.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("Tap a pose to change its angles, speed or hold.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(Array(store.recording.enumerated()), id: \.element.id) { idx, pose in
                    HStack(spacing: 10) {
                        Text("\(idx + 1)")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 18, alignment: .trailing)

                        // The whole row opens the editor — a pose you can see and cannot change is
                        // the complaint that produced this.
                        Button {
                            editingPose = pose
                            editingIndex = idx + 1
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pose.jointLabel)
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(.primary)
                                Text(poseDetail(pose))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Image(systemName: "chevron.right")
                            .font(.caption).foregroundStyle(.tertiary)

                        Button { store.movePose(pose, by: -1) } label: {
                            Image(systemName: "arrow.up")
                        }
                        .buttonStyle(.bordered)
                        .disabled(idx == 0)

                        Button { store.movePose(pose, by: 1) } label: {
                            Image(systemName: "arrow.down")
                        }
                        .buttonStyle(.bordered)
                        .disabled(idx == store.recording.count - 1)

                        Button {
                            store.removePose(pose)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(Pivot.danger)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 2)
                }
            }

            HStack(spacing: 10) {
                Button {
                    _ = store.capturePose()
                } label: {
                    Label("Keep this pose", systemImage: "plus.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!arm.motionEnabled || arm.joints.isEmpty)

                Button {
                    // Pre-fill with the name being edited, so updating a movement does not require
                    // retyping it exactly (and a typo does not quietly create a second one).
                    saveName = store.editingName ?? ""
                    showSave = true
                } label: {
                    Label(store.editingID == nil ? "Save" : "Update",
                          systemImage: "tray.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(store.recording.isEmpty)
            }

            if !store.recording.isEmpty {
                Button {
                    store.clearRecording()
                } label: {
                    DestructiveLabel("Discard these poses", systemImage: "trash")
                }
                .buttonStyle(.plain)
                .font(.footnote)
            }
        }
        .padding()
        .pivotGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: Recording the rig

    /// 🔑 **Records the rail AND all five joints on one shared clock.** Which tracks come back with
    /// data is a MEASUREMENT, not an assumption — run a stored program with this on and the timeline
    /// says exactly what that program drives. That is the honest way to answer "does 14 move the
    /// arm", and it beats reasoning from a tag list.
    private var recordCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Record a movement", systemImage: "record.circle").font(.headline)
                Spacer()
                if recorder.recording {
                    Text(String(format: "%.1fs", recorder.elapsed))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(Pivot.danger)
                }
            }

            Text("Captures the carriage and every joint together, then opens them as tracks you can drag.")
                .font(.footnote).foregroundStyle(.secondary)

            HStack(spacing: 16) {
                Toggle("Rail", isOn: $recorder.includeRail).fixedSize()
                Toggle("Arm", isOn: $recorder.includeArm).fixedSize()
                Spacer()
            }
            .font(.subheadline)

            HStack {
                Text("Run program").font(.subheadline)
                Spacer()
                Stepper("\(recordProgram)", value: $recordProgram, in: 0...63)
                    .fixedSize()
                Toggle("", isOn: $recordRunsProgram).labelsHidden()
            }

            if recorder.recording {
                Button {
                    recorder.stop()
                } label: {
                    DestructiveLabel("Stop recording", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Pivot.danger)
            } else {
                Button {
                    recorder.start(name: recordRunsProgram ? "Program \(recordProgram)" : "Free record",
                                   program: recordRunsProgram ? recordProgram : nil,
                                   seconds: 25)
                } label: {
                    Label(recordRunsProgram ? "Run \(recordProgram) and record" : "Record",
                          systemImage: "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(recordRunsProgram && !safety.canTriggerProgram)
            }

            if recordRunsProgram, !safety.canTriggerProgram {
                Text(safety.blocker?.message ?? "The rail will not accept a program right now.")
                    .font(.caption).foregroundStyle(Pivot.caution)
            }

            if !recorder.note.isEmpty {
                Text(recorder.note)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(recorder.note.contains("NOTHING") ? Pivot.caution : .secondary)
            }

            ForEach(recorder.traces.reversed()) { t in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.name).font(.subheadline.weight(.semibold))
                        Text(traceSummary(t)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        openTrace = t
                    } label: {
                        Label("Timeline", systemImage: "chart.xyaxis.line")
                    }
                    .buttonStyle(.bordered)
                    Button { recorder.delete(t) } label: {
                        Image(systemName: "trash").foregroundStyle(Pivot.danger)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 2)
            }
        }
        .padding()
        .pivotGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// Name the channels that actually moved — the one line that turns a recording into an answer.
    private func traceSummary(_ t: RigTrace) -> String {
        var moved: [String] = []
        if t.moved(-1) { moved.append("rail") }
        for j in 0..<XArmLink.jointCount where t.moved(j) { moved.append("J\(j + 1)") }
        let what = moved.isEmpty ? "nothing moved" : moved.joined(separator: ", ")
        return String(format: "%.1fs · %d samples · %@", t.duration, t.samples.count, what)
    }

    // MARK: Saved movements

    private var libraryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Saved movements", systemImage: "square.stack.3d.up").font(.headline)
                Spacer()
                if store.isPlaying {
                    Button {
                        store.stop()
                    } label: {
                        Label("STOP", systemImage: "stop.fill")
                            .font(.subheadline.weight(.bold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Pivot.danger)
                }
            }

            if store.isPlaying, !store.note.isEmpty {
                Text(store.note)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(Pivot.caution)
            }

            if store.motions.isEmpty {
                Text("Nothing saved yet. Build a movement above and it lands here.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            // Factory programs first, by number; authored movements after. The factory ones are
            // what the PLC triggers today, so they are the natural starting point for an edit.
            ForEach(store.motions.sorted {
                switch ($0.program, $1.program) {
                case let (a?, b?): return a < b
                case (_?, nil):    return true
                case (nil, _?):    return false
                default:           return $0.name < $1.name
                }
            }) { m in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(m.name).font(.subheadline.weight(.semibold))
                            if m.program != nil {
                                Text("FACTORY")
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Pivot.blue.opacity(0.2),
                                                in: Capsule())
                                    .foregroundStyle(Pivot.blue)
                            }
                        }
                        Text(String(format: "%d poses · %.1fs%@",
                                    m.poses.count, m.duration(),
                                    m.usesRail ? " · drives the rail" : ""))
                            .font(.caption).foregroundStyle(.secondary)
                        if !m.caveats.isEmpty {
                            // Say what the import could NOT carry, rather than presenting the
                            // joint-space part as the whole program.
                            Text("Partial — the original also uses \(m.caveats.joined(separator: ", "))")
                                .font(.caption).foregroundStyle(Pivot.caution)
                        }
                    }
                    Spacer()
                    if let n = m.program {
                        Button {
                            store.restoreFactory(n)
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                        }
                        .buttonStyle(.bordered)
                        .help("Restore the factory version")
                    }
                    Button {
                        // Remembers where it came from, so Save replaces this movement instead of
                        // appending a second one with the same name.
                        store.loadForEditing(m)
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.bordered)
                    .disabled(store.isPlaying)

                    Button {
                        store.start(m)
                    } label: {
                        Image(systemName: "play.fill")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!arm.motionEnabled || store.isPlaying)

                    Button { pendingDelete = m } label: {
                        Image(systemName: "trash").foregroundStyle(Pivot.danger)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 2)
            }

            if !arm.motionEnabled, !store.motions.isEmpty {
                Text("Enable the arm to play a movement.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
        .pivotGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
