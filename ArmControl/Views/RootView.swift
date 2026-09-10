import SwiftUI

struct RootView: View {
    @StateObject private var kiosk = Kiosk.shared

    var body: some View {
        Group {
            if kiosk.locked {
                // Locked: ONE screen. No tabs, no ARM button, no route to the PLC login.
                // The way back is the triple tap inside AttendantView.
                AttendantView()
            } else {
                OperatorInterface()
            }
        }
        // One tint for the whole app. Without this, every chevron, toggle, picker and plain button
        // renders in the system blue — which is the single loudest "this is not branded" tell,
        // regardless of how many individual views set a mint foreground.
        .tint(Pivot.mint)
        // Open the telemetry session on launch, in BOTH modes — the attendant screen needs the
        // link just as much as the operator one, and without this the booth reads "No connection
        // to the rail" forever. Connecting only starts telemetry: it does not arm, does not home,
        // and moves nothing.
        .task {
            // 🐞 **THIS RUNS FIRST, AND IT USED TO RUN AFTER `connect()` — which is why an import
            // silently never happened.** `connect()` can take the better part of a minute when the
            // rail is not reachable (intro, ENTER, then four login shapes, each with a 10s
            // timeout), and an app opened and closed inside that window never reached the line
            // below. Nothing here touches the network, so nothing here should wait on it.
            //
            // It matters most in exactly the situation this feature exists for: previewing
            // movements with the hardware unplugged, where `connect()` is guaranteed to be slow.
            await Self.importTracesIfPresent()

            // 🐞 **A FAILED FIRST CONNECT USED TO BE FINAL.** `connect()` ran once here; the
            // auto-reconnect that heals a dropped link is driven by the telemetry poll, and the
            // poll only starts *after* a connect succeeds — so if the very first attempt failed
            // the app sat there forever with "Couldn't reach the slider" and never tried again.
            //
            // That is exactly the ordinary case: an iPad powered up before the rail, a control box
            // still booting (an S7-1200 takes 30–60s to bring its web server up), or a cable
            // reseated mid-session. Observed for real — the rail came back and the app never
            // noticed, because nothing was asking.
            //
            // Keep trying, with a widening gap so a genuinely absent rail is not hammered.
            // 🐞 **AND IT RUNS DETACHED, because the first version blocked everything below it.**
            // An unreachable rail made this loop spin forever inside the startup task, so the
            // trace import, the diagnostics and every debug hatch were never reached — the app
            // looked frozen at "Couldn't reach the slider" with no way to find out why, which is
            // precisely when the diagnostics matter. Retrying must never gate startup.
            if !GlamaticLink.shared.connected {
                Task { @MainActor in
                    var wait: UInt64 = 5
                    while !Task.isCancelled, !GlamaticLink.shared.connected {
                        if await GlamaticLink.shared.connect() { break }
                        try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
                        wait = min(30, wait * 2)
                    }
                }
            }
            // Simulation only — see SafetyKernel.prepareSimulatedRail. A real rail is never
            // armed or homed without someone deciding to.
            await SafetyKernel.shared.prepareSimulatedRail()


            #if DEBUG
            // 🔧 **Bench hatch: run the move test straight after connecting.**
            //
            // It exists because the move test can only be started by tapping the iPad, and the
            // iPad is at the rail while whoever is debugging is not. Launch with:
            //
            //     xcrun devicectl device process launch --device <udid> com.pivotxp.armcontrol \
            //       -armcontrol.debug.runMoveDoctor YES
            //
            // ⚠️ **THIS MOVES THE RAIL, so it is fenced three ways:** DEBUG builds only, so it
            // cannot exist in anything shipped through TestFlight; it reads the **argument
            // domain**, which lives only for the launch that passes it, so opening the app by
            // hand can never trigger it; and it is never written to UserDefaults, so it cannot
            // lie in wait. Tapping the icon tomorrow does nothing.
            if UserDefaults.standard.bool(forKey: "armcontrol.debug.runMoveDoctor"),
               GlamaticLink.shared.connected, !GlamaticLink.shared.simulated {
                GlamaticLink.plog("debug launch argument: running the move test")
                let program = UserDefaults.standard.object(forKey: "armcontrol.take.program") as? Int ?? 1
                await MoveDoctor.shared.run(program: program)
                GlamaticLink.plog("debug move test finished: \(MoveDoctor.shared.conclusion ?? "no conclusion")")
            }

            // 🩺 Run the connection check and put every step in the trace, so a rail that will not
            // answer can be diagnosed from a pulled log rather than by asking someone to read a
            // screen.  … -- -armcontrol.debug.linkDoctor YES
            //
            // Moves nothing. Most valuable line it prints is the iPad's OWN interfaces: a
            // self-assigned 169.254 address after a cable was reseated looks identical, from the
            // error code alone, to a PLC that is switched off.
            if UserDefaults.standard.bool(forKey: "armcontrol.debug.linkDoctor") {
                await LinkDoctor.shared.run()
                for step in LinkDoctor.shared.steps {
                    GlamaticLink.plog("doctor [\(step.verdict.rawValue.uppercased())] \(step.name): "
                                      + step.detail.replacingOccurrences(of: "\n", with: " | "))
                    if let r = step.remedy { GlamaticLink.plog("doctor    → \(r)") }
                }
            }

            // 🎬 Run one complete take — rail, camera and render — without needing the iPad tapped.
            //     … com.pivotxp.armcontrol -- -armcontrol.debug.runTake YES
            //
            // ⚠️ **THIS ARMS THE RAIL, WHICH NOTHING ELSE IN THE APP DOES ON ITS OWN.** The kernel
            // rule is that arming is always a human tap; this is DEBUG-only and reads the argument
            // domain, so it cannot exist in a shipped build and cannot survive a launch. It also
            // disarms again the moment the take finishes, so it never leaves the rail hot.
            if UserDefaults.standard.bool(forKey: "armcontrol.debug.runTake"),
               GlamaticLink.shared.connected, !GlamaticLink.shared.simulated {
                let link = GlamaticLink.shared
                let program = UserDefaults.standard.object(forKey: "armcontrol.take.program") as? Int ?? 1

                guard link.state.isHomed else {
                    GlamaticLink.plog("debug take: REFUSED — rail is not referenced")
                    return
                }
                // Traverse from the RECORDED movement, so the take actually covers the latency and
                // the movement rather than a guessed length.
                if let t = TraceLibrary.shared.byProgram[program], t.source == .recorded, !t.isEmpty {
                    UserDefaults.standard.set(t.recommendedTraverse, forKey: "armcontrol.take.seconds")
                    GlamaticLink.plog(String(format: "debug take: traverse %.1fs from the recording (latency %.1fs + movement %.1fs)",
                                             t.recommendedTraverse, t.latency, t.moveDuration))
                }
                let traverse = UserDefaults.standard.object(forKey: "armcontrol.take.seconds") as? Double ?? 9
                let leadIn = UserDefaults.standard.object(forKey: "armcontrol.take.leadIn") as? Double ?? 0.3

                // Give the camera a moment to actually be running before committing to a take.
                for _ in 0..<20 where !Recorder.shared.isRunning {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                guard Recorder.shared.isRunning else {
                    GlamaticLink.plog("debug take: REFUSED — camera never started")
                    return
                }

                GlamaticLink.plog("debug take: ARMING (debug hatch — disarms afterwards)")
                guard await SafetyKernel.shared.arm() else {
                    GlamaticLink.plog("debug take: REFUSED — arm failed")
                    return
                }
                GlamaticLink.plog(String(format: "debug take: program %d, traverse %.1fs, lead-in %.2fs, dead head %.1fs",
                                         program, traverse, leadIn, BoothSettings.shared.deadHeadSeconds))

                // 🔑 **Watch the position WHILE the take runs.** Black footage cannot tell us
                // whether the carriage moved, and the raw ASCII trigger gives no feedback at all —
                // it opens a socket, sends two bytes and reports success either way. This is the
                // only way to know the take filmed a moving rail rather than a still one.
                let watcher = Task { @MainActor in
                    var lo = link.state.currentMM, hi = lo
                    let end = Date().addingTimeInterval(leadIn + traverse + 2)
                    while Date() < end, !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        await link.refresh()
                        lo = min(lo, link.state.currentMM); hi = max(hi, link.state.currentMM)
                    }
                    return (lo, hi)
                }

                await TakeRunner.shared.run(countdownFrom: 0, program: program,
                                            traverse: traverse, leadIn: leadIn, render: true)
                let (lo, hi) = await watcher.value
                GlamaticLink.plog(String(format: "debug take: carriage travelled %.0f..%.0f mm (%.0f mm) during the take — %@",
                                         lo, hi, hi - lo,
                                         hi - lo > 20 ? "THE RAIL MOVED" : "THE RAIL DID NOT MOVE"))
                switch TakeRunner.shared.phase {
                case .done(let url):
                    GlamaticLink.plog("debug take: DONE → \(url.lastPathComponent)")
                case .failed(let why):
                    GlamaticLink.plog("debug take: FAILED — \(why)")
                default:
                    GlamaticLink.plog("debug take: ended in \(TakeRunner.shared.phase)")
                }
                await SafetyKernel.shared.disarm(reason: "debug take finished")
                GlamaticLink.plog("debug take: disarmed")
            }

            // 🔬 **Does this machine accept a speed above the documented 100 mm/s?**
            //     … com.pivotxp.armcontrol -- -armcontrol.debug.speedTest YES
            //
            // 🔑 **Why this matters more than it sounds.** Everything in this app is designed around
            // "the Glamatic clamps velocity to 70–100 mm/s — a 1.43:1 range, far too narrow to ramp
            // anything cinematically" (see `RampProfile`). That is true of the manual `Velocety`
            // tag, and the stored programs plainly ignore it: program 14 was measured travelling
            // 600 mm in 4.20 s = **143 mm/s**, from 20+ clean samples, not an artefact. So an
            // editable copy of a stored move runs ~40% slower than the move it copies, and the
            // editor cannot express what the machine can already do.
            //
            // ⚠️ **PHASE 1 MOVES NOTHING.** `Velocety` is one of the eight READABLE tags, so a
            // write followed by a read says whether the PLC clamped the value — no motion, no risk,
            // and it answers most of the question on its own. Only if a value above 100 actually
            // sticks is a movement worth making.
            if UserDefaults.standard.bool(forKey: "armcontrol.debug.speedTest"),
               !GlamaticLink.shared.simulated {
                let link = GlamaticLink.shared
                // ⚠️ **WAIT for the link, do not merely CHECK it.** This originally read
                // `GlamaticLink.shared.connected` in the guard, which is false at startup because
                // the handshake is still in flight — so the whole test silently did not run, three
                // times, while the log showed a healthy `connected (Connected) homed=true` a few
                // seconds later. That is precisely the race that made `LinkDoctor` report "the
                // credentials were rejected" about a login that succeeded one second afterwards,
                // and I wrote it again in new code.
                if !link.connected {
                    _ = await link.connect()
                    for _ in 0..<40 where link.isConnecting {
                        try? await Task.sleep(nanoseconds: 250_000_000)
                    }
                }
                guard link.connected else {
                    GlamaticLink.plog("SPEED TEST: skipped — no link to the rail")
                    return
                }
                GlamaticLink.plog("SPEED TEST: measuring real moves at 100 and 150 mm/s — THE RAIL WILL MOVE")
                link.suspendPolling()

                // 🐞 **THE READ-BACK TEST WAS INVALID AND ITS ANSWER MEANT NOTHING.**
                //
                // The first version wrote a speed and read `Velocety` back, treating a mismatch as
                // "the PLC clamped it". It reported every value clamped — including 85 and 100,
                // which the app uses for every manual move and which demonstrably work. That is the
                // tell: when a test fails a known-good input, the test is broken.
                //
                // `Velocety` in the READ payload is the carriage's CURRENT speed, not an echo of
                // the setpoint. On a stationary rail it is 0, always, whatever was just written —
                // the Mac's own state dump showed `"Velocety": "0"` on an idle rail. There is no
                // setpoint echo among the eight readable tags, so the question cannot be answered
                // by reading at all.
                //
                // ⚠️ So this MEASURES instead. Drive the same 300 mm at 100 and at 150 mm/s and
                // time the carriage. If both take the same time, the clamp is real. If the second
                // is faster, it is not. This moves the rail — there is no longer a "phase 1 moves
                // nothing", because the no-movement version could not tell the truth.
                // 🐞 **THE TEST DESTROYED ITS OWN PRECONDITION.** Cleanup drops `Enable` to leave
                // the rail cold — and dropping Enable CLEARS `StatusHomed`, which was measured and
                // written down on 2026-09-08. So the first run consumed the reference and every run
                // afterwards commanded a move at an unreferenced axis, which the PLC accepts and
                // silently ignores. From the outside that is indistinguishable from a speed clamp,
                // a dead drive or a broken cable, and it wasted three attempts.
                //
                // So reference it here rather than demanding someone else did. `referenceRail()`
                // holds the motion lock and pulses ExecuteHoming, exactly as the Home button does.
                if !link.state.isHomed {
                    GlamaticLink.plog("SPEED TEST: not referenced — homing first")
                    guard await link.referenceRail() else {
                        GlamaticLink.plog("SPEED TEST: could not home — aborting rather than measuring an axis that will not move")
                        link.resumePolling()
                        return
                    }
                }

                var measured: [(Double, Double)] = []
                for commanded in [100.0, 150.0] {
                    // ⚠️ Re-checked per attempt: the previous iteration may have dropped the
                    // reference, and a second measurement against an unreferenced axis would
                    // silently read as "same speed" and manufacture a verdict.
                    await link.refresh()
                    if !link.state.isHomed {
                        GlamaticLink.plog("SPEED TEST: reference lost — re-homing before \(Int(commanded))")
                        guard await link.referenceRail() else {
                            GlamaticLink.plog("SPEED TEST: re-home failed — aborting")
                            break
                        }
                    }
                    _ = await link.write(.manual, "1")
                    _ = await link.write(.enable, "1")
                    // A settle beat: Manual is a MODE switch, and the drive commands that follow are
                    // ignored outright if the PLC has not taken the mode yet.
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    _ = await link.write(.velocity, "85")
                    _ = await link.write(.position, "0")
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    _ = await link.write(.execute, "1")
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    _ = await link.write(.execute, "0")
                    var returned = false
                    for _ in 0..<60 {
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        await link.refresh()
                        if link.state.currentMM < 3 { returned = true; break }
                    }
                    // 🐞 **This loop used to fall through without checking it had arrived.** If the
                    // carriage was still near 300, the timing run that followed satisfied "started"
                    // (>5 mm) and "arrived" (≥296 mm) on its FIRST poll — 0.00 s elapsed — and the
                    // divide-by-floor guard turned that into a confident "29100 mm/s". A failed
                    // setup must abort the measurement, not feed it garbage.
                    guard returned else {
                        GlamaticLink.plog(String(format: "SPEED TEST: aborted at %.0f — carriage never returned to 0 (sat at %.0f mm)",
                                                 commanded, link.state.currentMM))
                        break
                    }

                    _ = await link.write(.velocity, String(Int(commanded)))
                    _ = await link.write(.position, "300")
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    _ = await link.write(.execute, "1")
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    _ = await link.write(.execute, "0")          // 🚨 PULSE

                    var started: Date?
                    var arrived: Date?
                    for _ in 0..<220 {
                        try? await Task.sleep(nanoseconds: 80_000_000)
                        await link.refresh()
                        let mm = link.state.currentMM
                        if started == nil, mm > 5 { started = Date() }
                        if mm >= 296 { arrived = Date(); break }
                    }
                    if let started, let arrived {
                        let secs = arrived.timeIntervalSince(started)
                        // ⚠️ **Reject, do not floor.** 291 mm cannot be crossed in under a second on
                        // a machine whose fastest observed program managed 143 mm/s — a reading that
                        // short means the run never really happened, and dividing by a floor value
                        // dresses that up as a measurement.
                        if secs < 1.0 {
                            GlamaticLink.plog(String(format: "SPEED TEST: commanded %.0f → INVALID (%.2fs for 291 mm is impossible; the move did not run)",
                                                     commanded, secs))
                        } else {
                            let actual = 291 / secs
                            measured.append((commanded, actual))
                            GlamaticLink.plog(String(format: "SPEED TEST: commanded %.0f → MEASURED %.0f mm/s (291 mm in %.2fs)",
                                                     commanded, actual, secs))
                        }
                    } else {
                        GlamaticLink.plog(String(format: "SPEED TEST: commanded %.0f → never arrived", commanded))
                    }
                }

                if measured.count == 2 {
                    let slow = measured[0].1, fast = measured[1].1
                    GlamaticLink.plog(fast > slow * 1.15
                        ? String(format: "SPEED TEST: VERDICT — headroom exists. 150 gave %.0f mm/s vs %.0f at 100.", fast, slow)
                        : String(format: "SPEED TEST: VERDICT — the clamp is REAL. 150 gave %.0f mm/s, 100 gave %.0f.", fast, slow))
                }

                // 🚨 Always leave it cold.
                for tag in [GlamaticLink.Tag.execute, .executeHoming, .runProgram] {
                    _ = await link.write(tag, "0")
                }
                _ = await link.write(.velocity, "85")
                _ = await link.write(.manual, "0")
                _ = await link.write(.enable, "0")
                link.resumePolling()
                GlamaticLink.plog("SPEED TEST: finished, rail left cold")
            }

            // 🚨 Emergency hatch: stop a runaway rail and reference it, without needing the iPad
            // to be tapped.  … com.pivotxp.armcontrol -- -armcontrol.debug.stopAndHome YES
            if UserDefaults.standard.bool(forKey: "armcontrol.debug.stopAndHome"),
               GlamaticLink.shared.connected, !GlamaticLink.shared.simulated {
                let link = GlamaticLink.shared
                GlamaticLink.plog("debug: STOP AND HOME")
                // Clear the standing trigger BEFORE dropping the drive — otherwise the request is
                // still high and the rail leaves again the moment anything re-energises.
                // ⚠️⚠️ **DELIBERATELY DOES NOT HOME, and the first version of this did.**
                // Homing asserts Manual=1 + Enable=1, and re-energising a PLC that still holds a
                // standing RunProgram is precisely what sends the carriage off again. Clearing
                // the trigger and referencing the rail are two separate decisions and the second
                // one waits for a human who can see the machine.
                //
                // Retried, because the web server goes intermittent exactly when it is being
                // hammered — and one silently-dropped write here means a rail still running.
                var cleared = false
                for attempt in 1...6 {
                    if !link.connected { _ = await link.connect() }
                    let ok = await link.cancelMotion()
                    await link.refresh()
                    GlamaticLink.plog("debug: clear attempt \(attempt) ok=\(ok) pos=\(link.state.currentPosition) prog=\(link.state.programNum) err=\(link.state.statusError)")
                    if ok { cleared = true; break }
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                }
                // Park the selection too. A retained ProgramNumber is what the next rising edge
                // would run, so leaving it pointing at a traverse is leaving the gun loaded.
                _ = await link.write(.programNumber, "0")
                GlamaticLink.plog("debug: trigger clear finished cleared=\(cleared) — NOT homing, Enable left down")
            }

            // 🏠 Clear → PROVE it is stationary → home. The proof step is the important one:
            // homing re-energises, so doing it while anything is still commanding movement is how
            // a runaway comes back.  … -- -armcontrol.debug.homeNow YES
            if UserDefaults.standard.bool(forKey: "armcontrol.debug.homeNow"),
               GlamaticLink.shared.connected, !GlamaticLink.shared.simulated {
                let link = GlamaticLink.shared
                GlamaticLink.plog("debug: HOME NOW — clearing first")
                _ = await link.cancelMotion()
                _ = await link.write(.programNumber, "0")

                // Watch the position for three seconds. Stationary means stationary, not "the
                // write returned 200".
                var samples: [Double] = []
                for _ in 0..<6 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    await link.refresh()
                    samples.append(Double(link.state.currentPosition) ?? -1)
                }
                let spread = (samples.max() ?? 0) - (samples.min() ?? 0)
                GlamaticLink.plog("debug: settle check spread=\(String(format: "%.1f", spread))mm samples=\(samples.map { Int($0) })")

                if spread > 4 {
                    GlamaticLink.plog("debug: STILL MOVING after clear (\(String(format: "%.1f", spread))mm) — refusing to home. Use the physical E-stop.")
                } else {
                    GlamaticLink.plog("debug: stationary at \(link.state.currentPosition)mm — homing")
                    _ = await link.home()
                    let homed = await link.waitHomed(timeout: 45)
                    await link.refresh()
                    GlamaticLink.plog("debug: homed=\(homed) pos=\(link.state.currentPosition) err=\(link.state.statusError)")
                    // Leave it cold and with nothing selected.
                    _ = await link.write(.runProgram, "0")
                    _ = await link.setEnable(false)
                    _ = await link.setManual(false)
                    GlamaticLink.plog("debug: home finished, Enable dropped")
                }
            }

            // Same hatch, for a named custom motion:
            //   … com.pivotxp.armcontrol -- -armcontrol.debug.runMotion Whalefall
            if let wanted = UserDefaults.standard.string(forKey: "armcontrol.debug.runMotion"),
               !wanted.isEmpty, !GlamaticLink.shared.simulated {
                let store = MotionStore.shared
                // ⚠️ Same two preconditions the speed test needed, and for the same reasons:
                // `connected` is false at startup while the handshake is still in flight, and an
                // UNREFERENCED rail accepts a drive command and silently does nothing. Checking
                // rather than waiting, and assuming rather than homing, is how three earlier runs
                // produced no motion and no explanation.
                if !GlamaticLink.shared.connected {
                    _ = await GlamaticLink.shared.connect()
                    for _ in 0..<40 where GlamaticLink.shared.isConnecting {
                        try? await Task.sleep(nanoseconds: 250_000_000)
                    }
                }
                guard GlamaticLink.shared.connected else {
                    GlamaticLink.plog("debug motion: no link to the rail")
                    return
                }
                await GlamaticLink.shared.refresh()
                if !GlamaticLink.shared.state.isHomed {
                    GlamaticLink.plog("debug motion: not referenced — homing first")
                    guard await GlamaticLink.shared.referenceRail() else {
                        GlamaticLink.plog("debug motion: could not home — not attempting the move")
                        return
                    }
                }
                if let motion = store.motions.first(where: {
                    $0.name.compare(wanted, options: .caseInsensitive) == .orderedSame
                }) {
                    GlamaticLink.plog("debug launch argument: running motion “\(motion.name)”")
                    let ok = await store.play(motion)
                    GlamaticLink.plog("debug motion finished: ok=\(ok) — \(store.progressNote)")
                    // ⚠️ Leave the machine in the state the UI claims. `move()` asserts
                    // Manual+Enable for itself, so without this the drive stays ENERGISED while
                    // the status strip still reads "not armed" — a rail that is hot while the
                    // screen says it is cold is the worst possible disagreement to walk away from.
                    _ = await GlamaticLink.shared.setEnable(false)
                    // Automatic mode, so the rail is not left in manual with a setpoint loaded.
                    _ = await GlamaticLink.shared.setManual(false)
                    GlamaticLink.plog("debug motion: Enable dropped, rail de-energised")
                } else {
                    GlamaticLink.plog("debug motion “\(wanted)” not found — have: \(store.motions.map(\.name).joined(separator: ", "))")
                }
            }
            #endif
        }
    }

    /// Load `Documents/traces-import.json` into `TraceLibrary`, then consume the file.
    ///
    /// The JSON is exactly what `TraceLibrary` persists — `[program: MotionTrace]` — so a capture
    /// driven from anywhere (including a laptop on the arm LAN) drops straight in.
    static func importTracesIfPresent() async {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("traces-import.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Int: MotionTrace].self, from: data),
              !decoded.isEmpty else {
            GlamaticLink.plog("trace import FAILED — traces-import.json is unreadable")
            return
        }
        await MainActor.run {
            TraceLibrary.shared.replaceAll(decoded)
            // 🔑 `ProgramStore.defaultNumbers` is derived from the traces, so the preset list is
            // stale until it is rebuilt — without this the app imports 30 movements and still shows
            // the old eight.
            ProgramStore.shared.reload()
        }

        // Names discovered by the same sweep, if it shipped any. Optional on purpose: traces are
        // the data, names are a convenience, and a missing names file must not fail the import.
        let namesURL = docs.appendingPathComponent("program-names.json")
        if let nameData = try? Data(contentsOf: namesURL),
           let names = try? JSONDecoder().decode([Int: String].self, from: nameData) {
            await MainActor.run { ProgramStore.shared.seedLabels(names) }
            try? FileManager.default.removeItem(at: docs.appendingPathComponent("program-names-imported.json"))
            try? FileManager.default.moveItem(at: namesURL,
                                              to: docs.appendingPathComponent("program-names-imported.json"))
            GlamaticLink.plog("imported \(names.count) program names")
        }
        // Renamed rather than deleted: if an import ever looks wrong, the source is still there.
        try? FileManager.default.removeItem(at: docs.appendingPathComponent("traces-imported.json"))
        try? FileManager.default.moveItem(at: url, to: docs.appendingPathComponent("traces-imported.json"))
        GlamaticLink.plog("imported \(decoded.count) movement traces: \(decoded.keys.sorted())")
        await MainActor.run {
            IncidentLog.shared.record(.system, "Imported \(decoded.count) recorded movements")
        }
    }
}

/// The engineer / operator side: a standard tab bar, a navigation title per section, live status in
/// its own strip, and STOP pinned to the bottom of every screen.
///
/// Everything here is behind the PIN. The touch gesture feeds the idle timer so a station left open
/// on the Setup screen re-locks itself rather than sitting there inviting a poke.
struct OperatorInterface: View {
    @StateObject private var kiosk = Kiosk.shared
    @State private var tab = 0

    var body: some View {
        tabs
            // Settle the Photos permission while an operator is holding the iPad. Asked lazily, the
            // system dialog turned up on the booth screen in front of a guest.
            .task {
                await Recorder.prepareAuthorization()
                await MediaLibrary.prepare()
            }
            // Feeds the idle re-lock timer.
            //
            // ⚠️ Do NOT go back to observing raw touches for this. Two attempts broke real
            // interaction: `.simultaneousGesture(DragGesture(minimumDistance: 0))` swallowed every
            // NavigationLink in Setup, and a window-level UIPanGestureRecognizer stopped every
            // Toggle from flipping (it competes with UISwitch's own recognizers). Idle is fed by
            // MEANINGFUL events instead — switching tabs, and any command sent to the rail. Reading
            // one screen for five minutes without touching anything counts as idle, which is the
            // behaviour you want anyway.
            .onChange(of: tab) { _, _ in kiosk.noteActivity() }
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            section(ConsoleView(), "Console", "square.grid.2x2.fill", 0)
            section(CaptureView(), "Capture", "camera.fill", 1)
            section(PostView(), "Post", "wand.and.rays", 2)
            section(MovementStudioView(), "Rail", "chart.xyaxis.line", 3)
            // 🔑 **Its own tab, named for the machine it drives.** "Studio" used to mean the rail
            // curve editor, and the arm had no screen at all. Two tools for two machines, each
            // labelled, beats one screen trying to be both — the rail has one axis and recorded
            // curves, the arm has five joints and none.
            section(JointStudioView(), "Arm", "point.3.connected.trianglepath.dotted", 4)
            section(ManualDriveView(), "Manual", "slider.horizontal.3", 5)
            section(SetupView(), "Setup", "gearshape.fill", 6)
        }
        // Both bars hang off the TabView, not off each screen.
        //
        // Inside a NavigationStack they belong to the root screen and vanish the moment you push a
        // settings detail — which took STOP off screen. Above the stack they cover the navigation
        // bar and swallow its back button. At the bottom of the TabView they persist across every
        // push AND every tab, and overlay nothing.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // ONE bar, not two stacked ones. The old status strip + STOP bar cost ~120pt of a
            // landscape iPad on every screen and read as two unrelated toolbars; merged, the state
            // and the controls that act on it sit on the same line, which is also how a machine
            // console is normally laid out.
            VStack(spacing: 0) {
                Divider()
                ControlBar()
            }
            .background(.bar)
        }
    }

    private func section<V: View>(_ content: V, _ title: String, _ icon: String, _ index: Int) -> some View {
        NavigationStack {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .background(Theme.grouped)
        }
        .tabItem { Label(title, systemImage: icon) }
        .tag(index)
    }
}

// MARK: - Control bar

/// The one always-on bar: what the rail is doing on the left, what you can do about it on the right.
///
/// STOP is never gated on the link being healthy — the whole point is that it works when things have
/// gone wrong — and it keeps a 52pt target that can be hit without looking.
struct ControlBar: View {
    @StateObject private var link = GlamaticLink.shared
    @StateObject private var safety = SafetyKernel.shared
    @StateObject private var health = DeviceHealth.shared
    @State private var busy = false

    var body: some View {
        HStack(spacing: 10) {
            pills

            Spacer(minLength: 16)

            Text("\(Int(link.state.currentMM)) mm")
                .font(.headline.monospacedDigit())
                .foregroundStyle(Theme.secondary)
                .contentTransition(.numericText())
                .animation(.snappy, value: Int(link.state.currentMM))

            Button {
                busy = true
                Task {
                    if safety.armed { await safety.disarm(reason: "Operator disarm") }
                    else { _ = await safety.arm() }
                    busy = false
                }
            } label: {
                Label(safety.armed ? "Disarm" : "Arm",
                      systemImage: safety.armed ? "bolt.slash.fill" : "bolt.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 116, height: 44)
            }
            .buttonStyle(.bordered)
            .tint(safety.armed ? Theme.warn : Theme.accent)
            .disabled(!link.connected || busy)

            // 🔑 **HOME LIVES HERE, next to STOP, on every screen.**
            //
            // It used to be a card inside Console and a row inside Manual Drive — two copies, both
            // of them somewhere you had to navigate TO. Parking the rail is a console-level action
            // in the same family as Arm and STOP, and it is wanted most at exactly the moments you
            // are not on the screen that happened to own it.
            //
            // The label carries the live phase because `sendHome()` can run for most of a minute,
            // and a button that looks identical while working is a button an operator taps twice.
            Button {
                Task { _ = await link.sendHome() }
            } label: {
                Label(link.isMotionBusy ? (link.motionPhase ?? "Working…") : "Home",
                      systemImage: link.isMotionBusy ? "hourglass" : "house.fill")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .frame(minWidth: 116, maxWidth: link.isMotionBusy ? 300 : 116, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .tint(Theme.accent)
            // Disabled while a sequence runs — a second tap is what wedged the PLC and left a
            // trigger latched high.
            .disabled(!link.connected || link.isMotionBusy)
            .animation(.snappy, value: link.isMotionBusy)

            Button(role: .destructive) {
                busy = true
                Task { await safety.emergencyStop(); busy = false }
            } label: {
                Label(busy ? "Stopping…" : "STOP", systemImage: "hand.raised.fill")
                    .font(.headline.weight(.bold))
                    .frame(width: 190, height: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.bad)

            // One tap back to the booth screen, from any tab. Without this the only way to re-lock
            // is to remember it lives at the top of Setup.
            Button {
                Kiosk.shared.lock()
            } label: {
                Image(systemName: "lock.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.bordered)
            .tint(Theme.accent)
            .accessibilityLabel("Lock to the booth screen")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        // STOP is pressed without looking, often in a hurry. A confirming thump is the difference
        // between "did that register" and knowing it did.
        .sensoryFeedback(.impact(weight: .heavy), trigger: safety.lastHalt)
        .sensoryFeedback(.selection, trigger: safety.armed)
    }

    @ViewBuilder
    private var pills: some View {
        HStack(spacing: 8) {
            // Loudest thing in the strip while it is on, on purpose. See GlamaticLink.simulated.
            if link.simulated {
                StatusPill(text: "SIMULATED", systemImage: "wrench.and.screwdriver.fill", tint: Theme.warn)
            }

            if link.connected {
                StatusPill(text: "Link", systemImage: "cable.connector", tint: Theme.good)
            } else {
                StatusPill(text: link.reconnecting ? "Reconnecting" : "No link",
                           systemImage: "cable.connector.slash",
                           tint: link.reconnecting ? Theme.warn : Theme.bad)
            }

            if link.state.hasFault {
                StatusPill(text: "Fault", systemImage: "exclamationmark.triangle.fill", tint: Theme.bad)
            } else if !link.state.isHomed {
                StatusPill(text: "Not homed", systemImage: "house.slash", tint: Theme.warn)
            }

            if safety.armed {
                StatusPill(text: "Armed", systemImage: "bolt.fill", tint: Theme.warn)
            }

            // Only appears when it is already costing something. A hot iPad drops frames without
            // saying so, and the frame rate keeps reading 120 the whole time.
            if health.thermal == .serious || health.thermal == .critical {
                StatusPill(text: DeviceHealth.name(health.thermal),
                           systemImage: "thermometer.high",
                           tint: health.thermal == .critical ? Theme.bad : Theme.warn)
            }
            if !health.isCharging, let pct = health.batteryPercent, pct <= 20 {
                StatusPill(text: "\(pct)%", systemImage: "battery.25", tint: Theme.bad)
            }
        }
    }
}
