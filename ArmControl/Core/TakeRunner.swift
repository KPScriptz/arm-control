import AVFoundation
import SwiftUI

/// The booth loop, in one place: count down, roll camera, fire the program, ramp the result.
///
/// Shared by the attendant screen and the engineer's Capture tab on purpose. Two copies of this
/// sequence would drift, and the one that drifts is always the one running at the event.
@MainActor
final class TakeRunner: ObservableObject {
    static let shared = TakeRunner()

    enum Phase: Equatable {
        case idle
        case countdown(Int)
        case recording
        case rendering(String)
        case done(URL)
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .idle, .done, .failed: return false
            case .countdown, .recording, .rendering: return true
            }
        }
    }

    @Published private(set) var phase: Phase = .idle

    /// Set when the program did not reach the rail but the recording still ran. The take is kept —
    /// a clip of a motionless rail is still better than throwing away a guest's turn silently —
    /// but the attendant is told.
    @Published private(set) var armWarning: String?

    /// Where the guest can fetch this take, once it is published to the delivery server.
    @Published private(set) var deliveryURL: URL?

    /// The raw pass from a take whose RENDER failed — still on disk, still usable.
    @Published private(set) var retryableRaw: URL?
    private var lastProgram = 1

    /// Build the clip again from footage already recorded. No countdown, no rail movement, no guest.
    func retryRender() async {
        guard let raw = retryableRaw, !phase.isBusy else { return }
        GlamaticLink.plog("re-rendering the last take")
        await renderAndFinish(raw: raw, program: lastProgram)
    }

    private let recorder = Recorder.shared
    private let link = GlamaticLink.shared
    private let booth = BoothSettings.shared

    private init() {}

    func reset() {
        phase = .idle
        armWarning = nil
        deliveryURL = nil
        retryableRaw = nil
    }

    /// Run one take.
    /// - Parameters:
    ///   - countdownFrom: seconds of 3-2-1 before rolling. Zero skips it.
    ///   - program: which stored PLC program to fire.
    ///   - traverse: how long to record after the lead-in.
    ///   - leadIn: camera rolls this long before the trigger, so no first frames are lost.
    ///   - render: apply the ramp profile afterwards.
    func run(countdownFrom: Int,
             program: Int,
             traverse: Double,
             leadIn: Double,
             render: Bool) async {

        guard !phase.isBusy else { return }
        armWarning = nil

        // Check BEFORE the countdown, not after. Failing halfway through a take means a guest has
        // already posed and the rail has already moved.
        Storage.prune()
        guard !Storage.isLow else {
            IncidentLog.shared.record(.system, "Take refused — only \(Storage.freeDescription) free", bad: true)
            phase = .failed("Storage is nearly full (\(Storage.freeDescription) free). Free space before the next take.")
            return
        }

        if countdownFrom > 0 {
            for n in stride(from: countdownFrom, through: 1, by: -1) {
                phase = .countdown(n)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }

        guard recorder.isRunning else {
            phase = .failed("Camera isn't running.")
            return
        }

        phase = .recording

        // Recording starts FIRST; the lead-in is what guarantees the trigger lands inside the clip.
        async let recording = recorder.record(seconds: leadIn + traverse)
        try? await Task.sleep(nanoseconds: UInt64(leadIn * 1_000_000_000))

        // 🔑 **A booth take can now be a movement the operator BUILT**, not only one of the 37
        // stored programs. `MotionStore.play` walks the waypoints with Position/Velocety/Execute
        // and polls for arrival at each one — the same path the Studio's "Run on the rail" uses —
        // so what was previewed is what gets shot.
        //
        // ⚠️ Falls back to the stored program whenever no motion is chosen, which is the default.
        // The booth's normal behaviour must not change because a feature exists.
        let fired: Bool
        if let motion = booth.boothMotion {
            GlamaticLink.plog("take: driving custom motion “\(motion.name)”")
            fired = await MotionStore.shared.play(motion)
            if !fired { armWarning = "The movement did not run — \(MotionStore.shared.progressNote)" }
        } else {
            fired = await link.runProgram(program)
            if !fired { armWarning = "The program did not reach the rail." }
        }

        guard let raw = await recording else {
            // 🚨 **A FAILED TAKE MUST NOT LEAVE A LIVE TRIGGER BEHIND.** The rail was told to run
            // a program moments ago; bailing out here without clearing it is how a camera fault
            // turns into a carriage still cycling after the app has given up on the take. Learned
            // from exactly that sequence: "Recording failed" followed by a runaway.
            await link.cancelMotion()
            phase = .failed("Recording failed.")
            return
        }

        // Count what actually landed in the file. The camera reports the rate it LOCKED, not the
        // rate it delivered, so a throttled or dropped-frame take looks identical to a good one
        // until someone watches the slow motion stutter. Cheap enough to do on every take.
        let locked = recorder.activeFPS > 0 ? recorder.activeFPS : recorder.desiredFPS
        if let report = await ClipInspector.inspect(raw), !report.isClean(against: locked) {
            let pct = Int((report.shortfall(against: locked) * 100).rounded())
            let note = "Camera delivered \(Int(report.deliveredFPS))fps, not \(Int(locked)) — \(pct)% of frames missing."
            armWarning = [armWarning, note].compactMap { $0 }.joined(separator: " ")
            GlamaticLink.plog("take frame check: \(report.summary) — \(note)")
            IncidentLog.shared.record(.take,
                                      "\(note) \(DeviceHealth.shared.thermal == .nominal ? "" : "iPad is \(DeviceHealth.name(DeviceHealth.shared.thermal).lowercased()).")",
                                      bad: true)
        }

        // 🔑 Frames are not a picture. A covered lens produces a take that passes every structural
        // check — right frame count, right duration, flash in the right place — and is black from
        // end to end. Cheap to check, and the only moment it can be caught is before the guest
        // walks away with it.
        if let look = await ClipVision.look(at: raw), let complaint = look.complaint {
            armWarning = [armWarning, complaint].compactMap { $0 }.joined(separator: " ")
            GlamaticLink.plog(String(format: "take picture check: brightness %.1f detail %.1f — %@",
                                     look.brightness, look.detail, complaint))
            IncidentLog.shared.record(.take, complaint, bad: look.isBlank)
        }

        guard render else {
            phase = .done(raw)
            return
        }

        await renderAndFinish(raw: raw, program: program)
    }

    /// Turn an existing raw pass into the delivered clip.
    ///
    /// 🔑 Split out from `run` so a failed RENDER does not cost a whole retake. The rail has already
    /// moved and the guest has already posed; if the export fell over — a hot iPad, a full disk, a
    /// profile that asks for frames the take does not have — the footage is still sitting there and
    /// the only thing that failed is something this can do again on its own.
    private func renderAndFinish(raw: URL, program: Int) async {
        retryableRaw = nil
        do {
            phase = .rendering("Preparing")
            if booth.failNextRender {
                booth.failNextRender = false
                throw RampRenderer.RenderError.exportFailed("simulated on purpose — Engineer → Fail the next render")
            }
            let url = try await RampRenderer.render(source: raw,
                                                    profile: booth.profile,
                                                    endCard: booth.endCard,
                                                    progress: { s in
                Task { @MainActor in
                    if case .rendering = self.phase { self.phase = .rendering(s) }
                }
            })
            // Publish BEFORE showing the result, so the QR is on screen the moment the guest looks.
            deliveryURL = DeliveryServer.shared.publish(url)
            IncidentLog.shared.record(.take, "Take complete — program \(program)"
                                      + (armWarning == nil ? "" : " (\(armWarning!))"),
                                      bad: armWarning != nil)
            phase = .done(url)
            // Listed so it can be found again. A guest whose scan did not take comes back two
            // minutes later, and the alternative is scrolling a camera roll of near-identical clips
            // while the queue waits.
            let length = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
            TakeLog.shared.record(program: program, url: url, duration: length, warning: armWarning)
            // Saved without being asked. The result screen auto-advances, so a clip nobody tapped
            // Share on used to be lost with the temp directory.
            await MediaLibrary.save(url)
        } catch {
            IncidentLog.shared.record(.take, "Render failed — \(error.localizedDescription)", bad: true)
            // Keep the footage. The attendant screen offers to build the clip again from it, which
            // needs neither the guest nor the rail.
            retryableRaw = FileManager.default.fileExists(atPath: raw.path) ? raw : nil
            lastProgram = program
            phase = .failed(error.localizedDescription)
        }
    }
}
