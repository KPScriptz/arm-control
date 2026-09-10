import AVFoundation
import Photos
import SwiftUI
import UIKit

/// The list you walk before the doors open.
///
/// 🔑 **Every failure this catches is one that otherwise surfaces in front of a guest.** The camera
/// silently at 30fps, Photos never authorised so nothing was ever saved, the QR pointing at the arm
/// wire, the rail connected but never homed, four gigabytes of last night's takes still on disk.
/// Each of those has exactly one moment where it is cheap to fix — before anyone is standing there —
/// and no moment where it announces itself.
///
/// Rules this screen keeps:
/// - **It reports; it never quietly repairs.** Every fix is a labelled button the operator taps.
///   That matters most for ARM: the kernel may halt, it may never energise, and a checklist that
///   armed the rail on its own would be exactly the automatic arming that rule exists to forbid.
/// - **Nothing is disabled without its reason next to it.** A grey row with no explanation is what
///   makes someone tap it eleven times.
@MainActor
enum Preflight {

    enum Level: Int, Comparable {
        case pass, warn, fail
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }

        var symbol: String {
            switch self {
            case .pass: return "checkmark.circle.fill"
            case .warn: return "exclamationmark.triangle.fill"
            case .fail: return "xmark.octagon.fill"
            }
        }

        var tint: Color {
            switch self {
            case .pass: return Theme.good
            case .warn: return Theme.warn
            case .fail: return Theme.bad
            }
        }
    }

    struct Fix {
        let label: String
        let run: @MainActor () async -> Void
    }

    struct Check: Identifiable {
        let id: String
        let title: String
        let detail: String
        let level: Level
        var fix: Fix?
    }

    struct CheckGroup: Identifiable {
        let id: String
        let title: String
        let checks: [Check]
        var level: Level { checks.map(\.level).max() ?? .pass }
    }

    // MARK: Entry points

    static var groups: [CheckGroup] {
        [CheckGroup(id: "rail", title: "The rail", checks: railChecks),
         CheckGroup(id: "booth", title: "The booth", checks: boothChecks)]
    }

    static var level: Level { groups.flatMap(\.checks).map(\.level).max() ?? .pass }

    static var summary: String {
        let all = groups.flatMap(\.checks)
        let failing = all.filter { $0.level == .fail }.count
        let warning = all.filter { $0.level == .warn }.count
        if failing > 0 {
            return "\(failing) thing\(failing == 1 ? "" : "s") will stop a take"
        }
        if warning > 0 {
            return "\(warning) thing\(warning == 1 ? "" : "s") worth a look"
        }
        return "Ready to run"
    }

    // MARK: The rail

    private static var railChecks: [Check] {
        let link = GlamaticLink.shared
        let safety = SafetyKernel.shared
        let store = ProgramStore.shared
        var out: [Check] = []

        // Connection ------------------------------------------------------------------
        if link.simulated {
            out.append(Check(id: "link",
                             title: "Simulated rail",
                             detail: "No hardware attached. Takes will show a rail that never moved — turn this off in Engineer before a real event.",
                             level: .warn))
        } else if link.connected {
            out.append(Check(id: "link",
                             title: "Connected",
                             detail: "Talking to \(GlamaticLink.host).",
                             level: .pass))
        } else {
            out.append(Check(id: "link",
                             title: "Not connected",
                             detail: link.status,
                             level: .fail,
                             fix: Fix(label: "Connect") { _ = await link.connect() }))
        }

        // Login ----------------------------------------------------------------------
        if !link.simulated {
            if GlamaticLink.hasCredentials {
                out.append(Check(id: "login",
                                 title: "PLC login saved",
                                 detail: "Telemetry, homing and fault reset are available.",
                                 level: .pass))
            } else {
                out.append(Check(id: "login",
                                 title: "No PLC login",
                                 detail: safety.allowBlindTrigger
                                    ? "Presets will still fire over the trigger port, but there is no homed or fault readout — you are flying blind."
                                    : "Without it there is no telemetry, so the app will refuse to run a program. Add it under PLC login.",
                                 level: safety.allowBlindTrigger ? .warn : .fail))
            }
        }

        // Fault ----------------------------------------------------------------------
        if link.state.hasFault {
            out.append(Check(id: "fault",
                             title: "Rail is faulted",
                             detail: "StatusError \(link.state.statusError), RobotError \(link.state.robotError). A successful homing is what actually clears this.",
                             level: .fail,
                             fix: Fix(label: "Recover") { _ = await link.recoverFromFault() }))
        }

        // Armed ----------------------------------------------------------------------
        //
        // Deliberately BEFORE homed: homing needs Manual and Enable on, so an operator who tries
        // them the other way round just watches Home do nothing.
        if safety.armed {
            out.append(Check(id: "armed",
                             title: "Armed",
                             detail: "The drive gate is energised.",
                             level: .pass))
        } else {
            out.append(Check(id: "armed",
                             title: "Not armed",
                             detail: link.connected
                                ? "The attendant screen cannot arm — a technician has to do it here, before locking to the booth."
                                : "Connect first.",
                             level: .fail,
                             fix: link.connected ? Fix(label: "Arm") { _ = await safety.arm() } : nil))
        }

        // Homed ----------------------------------------------------------------------
        if link.state.isHomed {
            out.append(Check(id: "homed",
                             title: "Homed",
                             detail: "Carriage referenced at \(link.state.currentPosition) mm.",
                             level: .pass))
        } else {
            out.append(Check(id: "homed",
                             title: "Not homed",
                             detail: safety.armed
                                ? "The PLC refuses every move until the carriage is referenced. Homing is lost on a power cycle, so this needs doing again after one."
                                : "Arm first — the PLC ignores homing unless Manual and Enable are on.",
                             level: .fail,
                             fix: safety.armed
                                ? Fix(label: "Home") {
                                    guard await link.home() else { return }
                                    _ = await link.waitHomed()
                                  }
                                : nil))
        }

        // Presets --------------------------------------------------------------------
        let program = takeProgram
        if store.visible.isEmpty {
            out.append(Check(id: "presets",
                             title: "No presets enabled",
                             detail: "Turn at least one on under Presets.",
                             level: .fail))
        } else if !store.visible.contains(where: { $0.number == program }) {
            out.append(Check(id: "presets",
                             title: "Booth program is switched off",
                             detail: "The booth fires program \(program), which is not one of the \(store.visible.count) enabled presets.",
                             level: .warn))
        } else {
            let name = store.visible.first { $0.number == program }?.label ?? ""
            out.append(Check(id: "presets",
                             title: "Booth fires program \(program)",
                             detail: name.isEmpty ? "\(store.visible.count) presets enabled." : "“\(name)” · \(store.visible.count) presets enabled.",
                             level: .pass))
        }

        // Traverse vs the move -------------------------------------------------------
        //
        // The PLC gives no "program finished" signal, so the only honest source for this is a
        // measurement someone actually took. Prefer it over the simulator's round trip, which
        // describes the simulator and not the program stored on the machine.
        if let m = MoveTimer.shared.results[program] {
            let want = m.recommendedTraverse
            if takeSeconds + 0.01 < want {
                out.append(Check(id: "traverse",
                                 title: "The take ends before the move does",
                                 detail: String(format: "Program %d was measured at %.1fs including its %.1fs start delay, but a take records %.1fs — the last %.1fs of the move is never filmed.", program, want, m.latency, takeSeconds, want - takeSeconds),
                                 level: .warn,
                                 fix: Fix(label: String(format: "%.1fs", want)) { setTakeSeconds(want) }))
            } else if takeSeconds > want + 1.5 {
                out.append(Check(id: "traverse",
                                 title: "The take runs on after the move",
                                 detail: String(format: "Program %d finishes after %.1fs but the take records %.1fs, so the last %.1fs is a motionless rail — and the ramp profile spends slow-motion budget on it.", program, want, takeSeconds, takeSeconds - want),
                                 level: .warn,
                                 fix: Fix(label: String(format: "%.1fs", want)) { setTakeSeconds(want) }))
            } else if m.simulated {
                // 🐞 This used to be a plain green pass. A measurement taken against the SIMULATOR
                // describes the simulator's own out-and-back, not the program stored on the
                // machine — and it does not merely sit in a list: it sets the dead head, which
                // shifts every pass in the ramp profile, and it is what the traverse gets matched
                // to. Passing it as "measured" is precisely the mistake this app's simulator is
                // written to make impossible everywhere else.
                out.append(Check(id: "traverse",
                                 title: "Traverse matches a SIMULATED move",
                                 detail: String(format: "Program %d was timed at %.1fs against the simulated rail, not the real one, and that figure is now setting the traverse and the %.1fs dead head the ramp skips. Re-time it once the rail is connected.", program, want, takeLeadIn + m.latency),
                                 level: .warn))
            } else if let age = staleness(m.at) {
                out.append(Check(id: "traverse",
                                 title: "Traverse matches the measured move",
                                 detail: String(format: "Program %d takes %.1fs and the take records %.1fs — but that was measured %@. Worth re-running if the rail or the stored program has been touched since.", program, want, takeSeconds, age),
                                 level: .warn))
            } else {
                out.append(Check(id: "traverse",
                                 title: "Traverse matches the measured move",
                                 detail: String(format: "Program %d takes %.1fs and the take records %.1fs.", program, want, takeSeconds),
                                 level: .pass))
            }
        } else {
            out.append(Check(id: "traverse",
                             title: "Program \(program) has never been timed",
                             detail: link.simulated
                                ? String(format: "The simulated out-and-back is %.1fs against a %.1fs take, but that is the simulator's number, not the program's. Presets → Time the moves measures the real one.", link.sim.roundTripSeconds, takeSeconds)
                                : "Traverse is still a guess, and every ramp-profile timing is scaled from it. Presets → Time the moves runs the program once and measures it.",
                             level: .warn))
        }

        return out
    }

    // MARK: The booth

    private static var boothChecks: [Check] {
        let recorder = Recorder.shared
        let delivery = DeliveryServer.shared
        let kiosk = Kiosk.shared
        let booth = BoothSettings.shared
        var out: [Check] = []

        // Camera ---------------------------------------------------------------------
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .denied, .restricted:
            out.append(Check(id: "camera",
                             title: "Camera access is off",
                             detail: "Nothing can be recorded. Turn it on in iOS Settings → Arm Control.",
                             level: .fail,
                             fix: Fix(label: "Settings") { openSettings() }))
        case .notDetermined:
            out.append(Check(id: "camera",
                             title: "Camera not asked yet",
                             detail: "Settle this now — asked later, the system dialog lands on the booth screen in front of a guest, covering Start.",
                             level: .warn,
                             fix: Fix(label: "Ask") { await Recorder.prepareAuthorization() }))
        default:
            if recorder.synthetic {
                out.append(Check(id: "camera",
                                 title: "Synthetic camera",
                                 detail: "This device has no camera, so takes are a generated test pattern.",
                                 level: .warn))
            } else if !recorder.isRunning {
                out.append(Check(id: "camera",
                                 title: "Camera not started",
                                 detail: "It starts on the Capture tab. Starting it here confirms the frame rate now instead of at the first take.",
                                 level: .warn,
                                 fix: Fix(label: "Start") { await recorder.start() }))
            } else if recorder.activeFPS >= recorder.desiredFPS - 0.5 {
                out.append(Check(id: "camera",
                                 title: "Camera locked at \(Int(recorder.activeFPS))fps",
                                 detail: "\(Int(recorder.activeSize.width))×\(Int(recorder.activeSize.height)). One real source frame per output frame at \(String(format: "%.0f", booth.profile.maxCleanSlowFactor))× slow.",
                                 level: .pass))
            } else {
                out.append(Check(id: "camera",
                                 title: "Camera is not at \(Int(recorder.desiredFPS))fps",
                                 detail: recorder.status,
                                 level: .fail,
                                 fix: Fix(label: "Retry") { recorder.setDesiredFPS(recorder.desiredFPS) }))
            }
        }

        // The iPad itself -------------------------------------------------------------
        //
        // Both of these end the same way — clips that are no longer 4× material, or no clips at
        // all — and neither announces itself.
        let health = DeviceHealth.shared
        if let consequence = health.thermalConsequence {
            out.append(Check(id: "thermal",
                             title: "iPad is \(DeviceHealth.name(health.thermal).lowercased())",
                             detail: consequence,
                             level: health.thermal == .critical ? .fail : .warn))
        }
        if let concern = health.batteryConcern {
            out.append(Check(id: "battery",
                             title: health.isCharging ? "Battery" : "Not on power",
                             detail: concern,
                             level: (health.batteryPercent ?? 100) <= 20 ? .fail : .warn))
        } else if let pct = health.batteryPercent {
            out.append(Check(id: "battery",
                             title: "On power",
                             detail: "\(pct)% and charging.",
                             level: .pass))
        }

        // Photos ---------------------------------------------------------------------
        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized, .limited:
            out.append(Check(id: "photos",
                             title: "Clips save to Photos",
                             detail: "Every finished take is kept even if nobody taps Share.",
                             level: .pass))
        case .notDetermined:
            out.append(Check(id: "photos",
                             title: "Photos not asked yet",
                             detail: "Same trap as the camera: asked at the booth, the dialog covers the Start button.",
                             level: .warn,
                             fix: Fix(label: "Ask") { await MediaLibrary.prepare() }))
        default:
            out.append(Check(id: "photos",
                             title: "Photos access is off",
                             detail: "Renders live in a temporary folder iOS is free to purge. A clip nobody shared in time is simply gone.",
                             level: .warn,
                             fix: Fix(label: "Settings") { openSettings() }))
        }

        // Storage --------------------------------------------------------------------
        let free = Storage.freeBytes
        if Storage.isLow {
            out.append(Check(id: "storage",
                             title: "Storage is nearly full",
                             detail: "\(Storage.freeDescription) free. Takes are refused below \(ByteCountFormatter.string(fromByteCount: Storage.minimumFreeBytes, countStyle: .file)) rather than failing halfway through one.",
                             level: .fail,
                             fix: Fix(label: "Clear") { _ = Storage.prune() }))
        } else if free < 2_000_000_000 {
            out.append(Check(id: "storage",
                             title: "Storage is getting tight",
                             detail: "\(Storage.freeDescription) free — roughly an hour of takes.",
                             level: .warn,
                             fix: Fix(label: "Clear") { _ = Storage.prune() }))
        } else {
            out.append(Check(id: "storage",
                             title: "Storage",
                             detail: "\(Storage.freeDescription) free.",
                             level: .pass))
        }

        // Ramp profile ---------------------------------------------------------------
        let fitted = booth.profile.fitted(to: takeSeconds + takeLeadIn)
        let over = fitted.overBudgetPasses
        let factors = fitted.passes.map(\.slowFactor)
        let slowest = factors.min() ?? 1
        let fastest = factors.max() ?? 1
        /// What the profile's slowest pass was authored to be, before fitting.
        let intended = booth.profile.passes.map(\.slowFactor).min() ?? 0

        if !over.isEmpty {
            let list = over.map { "\($0 + 1)" }.joined(separator: ", ")
            out.append(Check(id: "profile",
                             title: "Profile asks for frames that aren't there",
                             detail: "Pass \(list) needs more than \(Int(fitted.sourceFPS))fps can give at \(String(format: "%.0f", fitted.maxCleanSlowFactor))×, so frames get duplicated and the slow-motion goes soft. Adjust it under Ramp profile.",
                             level: .warn))
        } else if intended > 0, slowest / intended < 0.7 {
            // 🔑 The non-obvious interaction between the two settings that matter most, and the one
            // no absolute threshold catches. Profiles are written in absolute seconds against a
            // designed source length and fitted to whatever was actually recorded — output
            // durations deliberately do NOT scale. So a longer traverse spends the source faster
            // and the slow motion quietly evaporates. Nothing fails, no frames are duplicated, and
            // the clip simply stops looking like the reference. Judge it against what the profile
            // was WRITTEN for, not against a magic number: 1.6× reads fine in isolation and is a
            // disaster for a profile authored at 4×.
            out.append(Check(id: "profile",
                             title: "The slow motion has been stretched thin",
                             detail: String(format: "“%@” was written for a %.1fs move at %.1f× slow. Spread over a %.1fs traverse its slowest pass runs at %.1f× — about %.0f%% of the intended effect%@. Either let the clip show a slice of the move at full speed-ramp, or shorten the traverse.",
                                            booth.profile.name, booth.profile.designedSourceDuration,
                                            intended, takeSeconds, slowest,
                                            (slowest / intended) * 100,
                                            slowest < 2 ? ", and below 2× the 120fps capture is buying almost nothing" : ""),
                             level: .warn,
                             fix: booth.fitMode == .coverTheMove
                                ? Fix(label: "Keep slow-mo") { booth.fitMode = .keepTheSlowMotion }
                                : nil))
        } else {
            out.append(Check(id: "profile",
                             title: "Profile “\(booth.profile.name)”",
                             detail: String(format: "%.1fs out, passes run %.1f×–%.1f× slow, all inside the %.0f× budget.%@",
                                            fitted.deliveredDuration(hasEndCard: booth.endCard != nil),
                                            slowest, fastest, fitted.maxCleanSlowFactor,
                                            booth.deadHeadSeconds > 0.05
                                                ? String(format: " Skips the first %.1fs, before the carriage moves.", booth.deadHeadSeconds)
                                                : ""),
                             level: .pass))
        }

        // End card -------------------------------------------------------------------
        if booth.profile.endCardDuration > 0 && booth.endCard == nil {
            out.append(Check(id: "endcard",
                             title: "No end card loaded",
                             detail: String(format: "The profile allows %.1fs of branded card and there is no image, so clips end %.1fs shorter than designed. That is correct, not a bug — but check it is what you want.",
                                            booth.profile.endCardDuration, booth.profile.endCardDuration),
                             level: .warn))
        }

        // Delivery -------------------------------------------------------------------
        if !delivery.enabled {
            out.append(Check(id: "delivery",
                             title: "Guests get no QR",
                             detail: "Clips still save to Photos, but there is no way to hand one to a guest at the booth.",
                             level: .warn,
                             fix: Fix(label: "Turn on") { delivery.enabled = true }))
        } else if let host = delivery.host, delivery.running {
            if let at = delivery.lastReachedAt {
                out.append(Check(id: "delivery",
                                 title: "Delivery is up and reachable",
                                 detail: "Serving on \(host):\(delivery.port). A phone last reached this iPad at \(at.formatted(date: .omitted, time: .shortened)).",
                                 level: .pass))
            } else {
                // Running is not the same as reachable, and the gap between them is where an
                // evening's clips go missing. See DeliveryServer.lastReachedAt.
                out.append(Check(id: "delivery",
                                 title: "Delivery is up, but untested",
                                 detail: "Serving on \(host):\(delivery.port) — and nothing has ever connected to it. Venue Wi-Fi often blocks devices from reaching each other, which leaves every QR looking perfect and going nowhere. Scan the check code in Delivery settings with a phone.",
                                 level: .warn))
            }
        } else {
            out.append(Check(id: "delivery",
                             title: "Delivery has no address",
                             detail: "There is no Wi-Fi address to put in the QR — the wired arm network is unreachable from a phone, so a code pointing there would look fine and go nowhere. Join a Wi-Fi network.",
                             level: .fail,
                             fix: Fix(label: "Restart") { delivery.start() }))
        }

        // Dead head ---------------------------------------------------------------------
        //
        // The highest-consequence number in the pipeline, and the easiest to be wrong about
        // without noticing — see BoothSettings.deadHeadSeconds.
        let dead = booth.deadHeadSeconds
        if booth.deadHeadIsFromSimulation, dead > 0 {
            out.append(Check(id: "deadhead",
                             title: "The start delay came from the simulator",
                             detail: String(format: "The booth thinks program %d waits %.1fs before moving, but that figure was measured against the simulated rail. Real programs on this machine wait between 4 and 9 seconds. If it is wrong, the clip opens on a motionless rail played at full slow motion. Record the movement in Setup → Movements to replace it with the real number.", takeProgram, dead),
                             level: .warn))
        } else if dead > 1.5 {
            out.append(Check(id: "deadhead",
                             title: String(format: "Skipping %.1fs of still rail", dead),
                             detail: String(format: "Program %d does not move for %.1fs after the trigger. The ramp profile skips that automatically, from a recorded measurement — nothing to do.", takeProgram, dead - takeLeadIn),
                             level: .pass))
        }

        // Text the link ----------------------------------------------------------------
        //
        // Only worth a row once someone has switched it on. An unconfigured optional feature is
        // not a finding, and a checklist that lists everything you have not enabled trains people
        // to skim it.
        let text = TextDelivery.shared
        if text.enabled {
            if !text.isConfigured {
                out.append(Check(id: "text",
                                 title: "Texting is on but has no account",
                                 detail: "The “Text it to me” button stays hidden until the Twilio SID, token and from-number are filled in under Delivery → Text the link.",
                                 level: .warn))
            } else {
                out.append(Check(id: "text",
                                 title: "Texting is set up",
                                 detail: "Guests can be sent the link from \(TextDelivery.fromNumber). Note the link is still a venue-Wi-Fi address — it stops working once they leave, so it recovers a failed scan rather than replacing one. Send a test from Delivery → Text the link if you have not.",
                                 level: .pass))
            }
        }

        // Lock -----------------------------------------------------------------------
        if kiosk.locked {
            out.append(Check(id: "kiosk",
                             title: "Locked to the booth",
                             detail: "One screen, one button.",
                             level: .pass))
        } else {
            out.append(Check(id: "kiosk",
                             title: "Settings are reachable",
                             detail: "Lock before guests arrive. Back in with three taps on the top-left corner, then the PIN.",
                             level: .warn,
                             fix: Fix(label: "Lock") { kiosk.lock() }))
        }

        return out
    }

    // MARK: Shared reads
    //
    // The take settings live in UserDefaults under keys the Capture and Attendant screens own via
    // @AppStorage. Reporting never writes them; only an explicit fix button does.

    /// How long ago a measurement was taken, but only once that is long enough to matter.
    ///
    /// A fortnight is the point where "this rail has not been touched since" stops being a safe
    /// assumption: the machine travels between venues, and the stored programs are edited on the
    /// PLC's own web page by whoever is setting it up. Anything more recent is noise.
    static func staleness(_ at: Date, after days: Double = 14) -> String? {
        let elapsed = Date().timeIntervalSince(at)
        guard elapsed > days * 86400 else { return nil }
        let d = Int(elapsed / 86400)
        return d >= 60 ? "\(d / 30) months ago" : "\(d) days ago"
    }

    static var takeProgram: Int {
        let n = UserDefaults.standard.object(forKey: "armcontrol.take.program") as? Int
        return n ?? 1
    }

    static var takeSeconds: Double {
        let d = UserDefaults.standard.object(forKey: "armcontrol.take.seconds") as? Double
        return d ?? 6.0
    }

    static var takeLeadIn: Double {
        let d = UserDefaults.standard.object(forKey: "armcontrol.take.leadIn") as? Double
        return d ?? 0.3
    }

    private static func setTakeSeconds(_ v: Double) {
        UserDefaults.standard.set(v, forKey: "armcontrol.take.seconds")
    }

    private static func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
