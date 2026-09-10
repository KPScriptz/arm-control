import AVFoundation
import Foundation
import SwiftUI

/// Watch the ramp profile before an event, with no rail and no guest.
///
/// 🔑 **This closes the last loop in the app that needed hardware to check.** Every other
/// subsystem can now be rehearsed indoors — the link through injected faults, the soak through its
/// own counters, a failed export through Engineer → Fail the next render — but the *look of the
/// clip* could only be judged by running a take on a real rail and watching the result. So the
/// profile numbers were tuned by arithmetic and hope, and the first time anyone saw what they did
/// was at a venue with a queue.
///
/// It renders a stand-in traverse of exactly the length tonight's take will be, with exactly the
/// dead head tonight's program has, through exactly the profile and fit mode the booth will use —
/// so what comes out has the real *timing*. What it does not have is the real *picture*: a test
/// pattern is not a guest, and this is deliberately rendered small and fast. Judge the ramp here;
/// judge focus and framing through the camera.
@MainActor
final class RampPreview: ObservableObject {
    static let shared = RampPreview()

    enum State: Equatable {
        case idle
        case working(String)
        case ready(URL)
        case failed(String)

        var isWorking: Bool { if case .working = self { return true }; return false }
    }

    @Published private(set) var state: State = .idle

    /// The clip the preview was built from and the profile it was built with, so the sheet can say
    /// whether what is on screen still matches the settings behind it.
    @Published private(set) var builtFor: String?

    private var job: Task<Void, Never>?
    private var scratch: URL?
    private var output: URL?

    private init() {}

    /// Preview resolution. A quarter of the pixels of a real capture and it makes the difference
    /// between a ten-second wait and a minute of one — the retime is identical either way, and the
    /// retime is the entire question being asked.
    private static let size = CGSize(width: 404, height: 720)

    func cancel() {
        job?.cancel()
        job = nil
        if state.isWorking { state = .idle }
    }

    /// Throw away the rendered clip. Called when the sheet closes, so a 10s h264 file is not left
    /// pinned in the temp directory for the rest of the event.
    func discard() {
        cancel()
        for url in [scratch, output].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
        scratch = nil
        output = nil
        builtFor = nil
        state = .idle
    }

    func build() {
        job?.cancel()
        job = Task { await self.run() }
    }

    private func run() async {
        let booth = BoothSettings.shared
        let profile = booth.profile
        let take = Preflight.takeSeconds + Preflight.takeLeadIn
        let dead = booth.deadHeadSeconds
        let fps = profile.sourceFPS

        // Signature of the inputs, so a stale preview can announce itself rather than quietly
        // being a picture of settings that have since changed.
        let signature = Self.signature()

        // Drop the previous render before making another; two 10s clips is a pointless 20s.
        for url in [scratch, output].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
        scratch = nil
        output = nil

        state = .working(String(format: "Generating a %.1fs stand-in traverse at %d fps", take, Int(fps)))
        do {
            let raw = try await SyntheticCamera.makeClip(seconds: take,
                                                         fps: fps,
                                                         holdAtStart: dead,
                                                         size: Self.size)
            scratch = raw
            guard !Task.isCancelled else { return }

            state = .working("Applying “\(profile.name)”")
            let url = try await RampRenderer.render(source: raw,
                                                    profile: profile,
                                                    endCard: booth.endCard,
                                                    progress: { s in
                Task { @MainActor in
                    if self.state.isWorking { self.state = .working(s) }
                }
            })
            guard !Task.isCancelled else {
                try? FileManager.default.removeItem(at: url)
                return
            }
            // The stand-in source is 120fps and by far the largest file involved. Nothing reads it
            // again once the composition is exported.
            try? FileManager.default.removeItem(at: raw)
            scratch = nil

            output = url
            builtFor = signature
            state = .ready(url)
            GlamaticLink.plog("ramp preview rendered: \(signature)")
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed(error.localizedDescription)
        }
    }

    /// Everything that changes what the render looks like.
    ///
    /// 🐞 This used to key off `profile.name`, which is constant for the one profile that can
    /// actually be edited: **Custom**. So the loop it exists to support — render, watch, move a
    /// slider, render again — was exactly the loop where "settings have changed" never appeared,
    /// and a preview of the previous numbers sat there looking current. Key off the numbers.
    private static func signature() -> String {
        let booth = BoothSettings.shared
        let p = booth.profile
        let passes = p.passes
            .map { String(format: "%.3f/%.3f/%.3f", $0.sourceStart, $0.sourceDuration, $0.outputDuration) }
            .joined(separator: ",")
        return String(format: "%@|%@|%@|%.3f|%.3f|%.3f|%.2f|%.2f|%.0f|%d",
                      p.name, booth.fitMode.rawValue, passes,
                      p.flashDuration, p.endCardDuration, p.endCardFade,
                      Preflight.takeSeconds + Preflight.takeLeadIn,
                      booth.deadHeadSeconds, p.sourceFPS,
                      booth.endCard == nil ? 0 : 1)
    }

    /// True when the settings have moved since this preview was rendered.
    var isStale: Bool {
        guard let builtFor, case .ready = state else { return false }
        return Self.signature() != builtFor
    }
}
