import AVFoundation
import SwiftUI

/// Records the raw pass at a locked high frame rate.
///
/// 🔑 120fps is not a preference here, it is the thing that makes the ramp work. A 30fps source
/// slowed 4× has to invent three frames out of every four; a 120fps source slowed 4× onto a 30fps
/// timeline has exactly one real frame per output frame. That difference is the whole look.
///
/// So this class REFUSES to quietly fall back. If it cannot find a 120fps format it says so, and
/// `activeFPS` always reports what was actually locked in — never what was asked for.
@MainActor
final class Recorder: NSObject, ObservableObject {
    static let shared = Recorder()

    @Published private(set) var isRunning = false
    @Published private(set) var isRecording = false
    @Published private(set) var activeFPS: Double = 0
    @Published private(set) var activeSize: CGSize = .zero
    @Published private(set) var status = "Camera not started"
    @Published private(set) var lastRecording: URL?

    /// Frame rates this device actually offers on the selected camera, highest first.
    @Published private(set) var availableFPS: [Double] = []

    let session = AVCaptureSession()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var device: AVCaptureDevice?
    private var finishHandler: ((URL?) -> Void)?

    /// The frame rate to lock. 120 unless the operator deliberately changes it.
    @AppStorage("armcontrol.capture.fps") var desiredFPS: Double = 120

    // MARK: Session

    /// True when there is no camera at all and the simulated rail is on, so takes are generated
    /// rather than filmed. NEVER true on a device that has a camera — a rehearsal that quietly
    /// stopped exercising the real capture path would be worth very little.
    @Published private(set) var synthetic = false

    /// Settle the camera permission during setup rather than at the booth.
    ///
    /// ⚠️ Same trap as Photos: asked on first use, the system dialog appears on the attendant
    /// screen in front of a guest, covering the Start button.
    static func prepareAuthorization() async {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined else { return }
        _ = await AVCaptureDevice.requestAccess(for: .video)
    }

    func start() async {
        guard !isRunning else { return }

        let found = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(for: .video)

        if found == nil {
            guard GlamaticLink.shared.simulated else {
                status = "No camera on this device."
                return
            }
            synthetic = true
            isRunning = true
            activeFPS = desiredFPS
            activeSize = CGSize(width: 720, height: 1280)
            status = "Simulated camera — \(Int(desiredFPS))fps test pattern"
            return
        }

        guard await AVCaptureDevice.requestAccess(for: .video) else {
            status = "Camera access denied — enable it in Settings."
            return
        }

        session.beginConfiguration()
        // .inputPriority is required: a preset would override the activeFormat we are about to
        // pick, and the high-frame-rate format would silently revert to 30fps.
        session.sessionPreset = .inputPriority

        guard let cam = found else {
            session.commitConfiguration()
            status = "No camera on this device."
            return
        }
        device = cam

        do {
            let input = try AVCaptureDeviceInput(device: cam)
            session.inputs.forEach { session.removeInput($0) }
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                status = "Could not attach the camera."
                return
            }
            session.addInput(input)
        } catch {
            session.commitConfiguration()
            status = "Camera error: \(error.localizedDescription)"
            return
        }

        if !session.outputs.contains(movieOutput), session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
        }
        session.commitConfiguration()

        availableFPS = Self.supportedRates(for: cam)
        applyFormat()

        let s = session
        await Task.detached { s.startRunning() }.value
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        if synthetic {
            synthetic = false
            isRunning = false
            status = "Camera stopped"
            return
        }
        let s = session
        Task.detached { s.stopRunning() }
        isRunning = false
        status = "Camera stopped"
    }

    /// Every frame rate the camera can sustain on some format, highest first.
    private static func supportedRates(for device: AVCaptureDevice) -> [Double] {
        var rates = Set<Double>()
        for f in device.formats {
            for r in f.videoSupportedFrameRateRanges {
                rates.insert(r.maxFrameRate.rounded())
            }
        }
        return rates.sorted(by: >)
    }

    /// Pick the largest format that sustains `desiredFPS`, and lock the frame duration to it.
    ///
    /// Locking BOTH min and max frame duration is what actually pins the rate — setting only the
    /// max lets the camera drop frames in low light, which quietly ruins the slow-motion budget
    /// exactly when a dim venue makes it hardest to notice.
    private func applyFormat() {
        guard let cam = device else { return }
        let want = desiredFPS

        let candidates = cam.formats.filter { f in
            f.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= want - 0.5 }
        }

        guard let best = candidates.max(by: { a, b in
            let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
            let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
            return Int(da.width) * Int(da.height) < Int(db.width) * Int(db.height)
        }) else {
            let top = availableFPS.first ?? 30
            status = "This camera cannot do \(Int(want))fps. Highest available is \(Int(top))fps — the ramp will duplicate frames."
            activeFPS = 0
            return
        }

        do {
            try cam.lockForConfiguration()
            cam.activeFormat = best
            let duration = CMTime(value: 1, timescale: CMTimeScale(want))
            cam.activeVideoMinFrameDuration = duration
            cam.activeVideoMaxFrameDuration = duration
            cam.unlockForConfiguration()

            let dims = CMVideoFormatDescriptionGetDimensions(best.formatDescription)
            activeSize = CGSize(width: Int(dims.width), height: Int(dims.height))
            activeFPS = want
            status = "Locked \(Int(dims.width))×\(Int(dims.height)) at \(Int(want))fps"
        } catch {
            status = "Could not lock the camera format: \(error.localizedDescription)"
            activeFPS = 0
        }
    }

    func setDesiredFPS(_ fps: Double) {
        desiredFPS = fps
        applyFormat()
    }

    // MARK: Recording

    /// Record for exactly `seconds`, then return the file.
    ///
    /// The duration is driven by the caller rather than a stop button because the take is timed to
    /// the rail traverse — a human tapping stop would clip the end of the pass.
    func record(seconds: Double) async -> URL? {
        guard isRunning, !isRecording else { return nil }

        if synthetic {
            isRecording = true
            status = String(format: "Generating a %.1fs synthetic pass", seconds)
            let url = try? await SyntheticCamera.makeClip(seconds: seconds,
                                                          fps: activeFPS > 0 ? activeFPS : 120)
            isRecording = false
            lastRecording = url
            status = url == nil ? "Synthetic pass failed" : "Synthetic take saved"
            return url
        }

        let url = FileManager.default.temporaryDirectory
            // Uniquified for the same reason the render is — see RampRenderer.
            .appendingPathComponent("pass-\(Int(Date().timeIntervalSince1970))-\(RampRenderer.uniqueSuffix()).mov")
        try? FileManager.default.removeItem(at: url)

        // Portrait, matching how the iPad is mounted at the booth.
        if let conn = movieOutput.connection(with: .video) {
            if conn.isVideoRotationAngleSupported(90) { conn.videoRotationAngle = 90 }
        }

        isRecording = true
        status = "Recording \(String(format: "%.1f", seconds))s at \(Int(activeFPS))fps"

        let result: URL? = await withCheckedContinuation { cont in
            var resumed = false
            func settle(_ out: URL?) {
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: out)
            }
            finishHandler = { settle($0) }
            movieOutput.startRecording(to: url, recordingDelegate: self)

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if self.movieOutput.isRecording { self.movieOutput.stopRecording() }
            }

            // 🔑 A DEADLINE, because this continuation is the booth's single point of freeze.
            // Everything here depends on AVFoundation calling the recording delegate. If it never
            // does — a session interrupted mid-take, a write that fails after `startRecording`
            // returned, a stop that never lands because `isRecording` was already false — the take
            // hangs forever, the attendant screen sits on "Recording · Hold still" with no button
            // on it, and the only way out is the hidden corner tap. A failed take is recoverable;
            // a frozen booth in front of a queue is not.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64((seconds + 10) * 1_000_000_000))
                guard !resumed else { return }
                GlamaticLink.plog("recording timed out after \(String(format: "%.1f", seconds + 10))s — camera never reported finishing")
                IncidentLog.shared.record(.take, "Recording timed out — the camera never reported finishing", bad: true)
                if self.movieOutput.isRecording { self.movieOutput.stopRecording() }
                self.finishHandler = nil
                settle(nil)
            }
        }

        isRecording = false
        lastRecording = result
        status = result == nil ? "Recording failed" : "Take saved"
        return result
    }
}

extension Recorder: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput,
                                didFinishRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection],
                                error: Error?) {
        Task { @MainActor in
            let handler = self.finishHandler
            self.finishHandler = nil
            handler?(error == nil ? outputFileURL : nil)
        }
    }
}

/// Live preview. Plain UIKit because AVCaptureVideoPreviewLayer has no SwiftUI equivalent.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.layer.session = session
        v.layer.videoGravity = .resizeAspectFill
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        override var layer: AVCaptureVideoPreviewLayer { super.layer as! AVCaptureVideoPreviewLayer }
    }
}
