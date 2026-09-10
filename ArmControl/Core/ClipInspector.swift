import AVFoundation
import CoreGraphics
import Foundation

/// Counts what is actually in a recorded file, rather than what it was asked to be.
///
/// 🔑 **`Recorder.activeFPS` reports what was LOCKED, which is not the same as what was DELIVERED.**
/// The lock is real and worth having, but a hot iPad, a dim venue or a busy encoder can still hand
/// back a file with fewer frames than the duration implies — and nothing in AVFoundation raises so
/// much as a warning. The clip plays fine. It is just no longer one real frame per output frame at
/// 4×, which is the entire reason for shooting 120 in the first place.
///
/// So every take gets counted. It is the same principle as the soak test and the move timer: the
/// thing that decides whether this works is a number, so measure it.
enum ClipInspector {

    /// What is actually in the file. Facts only — the judgement needs a baseline the FILE cannot
    /// supply, so it lives in `shortfall(against:)`.
    ///
    /// ⚠️ The obvious check — frames vs `duration × nominalFrameRate` — is worthless, and it is
    /// worth saying why. A file that dropped frames during capture usually ends up with a nominal
    /// rate the muxer derived from the samples it actually got, so the file agrees with itself and
    /// the check always passes. The only trustworthy baseline is **the rate this app asked for and
    /// believes it locked**, which the app owns and the file cannot contradict.
    struct Report {
        var duration: Double
        var frames: Int
        var nominalFPS: Double

        var deliveredFPS: Double { duration > 0 ? Double(frames) / duration : 0 }

        func expectedFrames(at fps: Double) -> Int { Int((duration * fps).rounded()) }

        /// How much of the requested frame rate never arrived, 0…1.
        func shortfall(against fps: Double) -> Double {
            let expected = expectedFrames(at: fps)
            guard expected > 0 else { return 0 }
            return max(0, Double(expected - frames) / Double(expected))
        }

        /// A couple of frames either way is timing noise at the file boundaries, not a throttle.
        func isClean(against fps: Double) -> Bool { shortfall(against: fps) < 0.02 }

        var summary: String {
            String(format: "%.2fs, %d frames, %.0f fps delivered", duration, frames, deliveredFPS)
        }
    }

    /// Count the frames without decoding any of them.
    ///
    /// `AVAssetReaderSampleReferenceOutput` hands back sample *references* — timing and location,
    /// no pixel data — so counting 1,900 frames costs milliseconds rather than a decode pass. Using
    /// a normal track output here would put a full 120fps decode between the guest and their clip.
    static func inspect(_ url: URL) async -> Report? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let duration = try? await asset.load(.duration).seconds,
              duration > 0 else { return nil }

        let nominal = (try? await track.load(.nominalFrameRate)).map(Double.init) ?? 0

        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderSampleReferenceOutput(track: track)
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        var frames = 0
        while let sample = output.copyNextSampleBuffer() {
            frames += 1
            _ = sample
        }
        reader.cancelReading()

        guard frames > 0 else { return nil }
        // Prefer the file's own nominal rate; fall back to what the frames imply if it is missing.
        let fps = nominal > 1 ? nominal : Double(frames) / duration
        return Report(duration: duration, frames: frames, nominalFPS: fps)
    }
}

// MARK: - Did the camera actually see anything?

/// Checks whether a take contains a PICTURE, not just frames.
///
/// 🔑 **Found the hard way, on the first real take.** The take reported complete: 210 frames,
/// exactly 7.000s, the white flash landing at precisely 3.0s, saved to Photos. Every structural
/// check passed — and the footage was **pure black from end to end**, because the iPad's lens was
/// covered. `ClipInspector` counts frames and `Recorder` reports the locked frame rate, and a
/// black frame is a perfectly valid frame to both of them. At an event that is a black video
/// handed to a guest, with nothing anywhere saying so.
///
/// This samples a handful of frames and asks the only question neither of those answers: is there
/// anything in the picture?
enum ClipVision {

    struct Look {
        /// 0–255 mean luma across the sampled frames.
        var brightness: Double
        /// How much the frames differ from each other. A locked-off shot of a dark room still has
        /// texture; a dead camera has none.
        var detail: Double

        /// Nothing but black. The camera was covered, capped, or never delivered a picture.
        var isBlank: Bool { brightness < 6 && detail < 2 }
        /// Very dark but not empty — a real shot in a badly lit room.
        var isVeryDark: Bool { !isBlank && brightness < 18 }

        var complaint: String? {
            if isBlank {
                return "The camera recorded a black frame for the whole take — check the lens is not covered and the iPad is facing the guest."
            }
            if isVeryDark {
                return "The shot is very dark. It will look worse after the slow motion, which does nothing to help exposure."
            }
            return nil
        }
    }

    /// Sample frames and measure. Uses `AVAssetImageGenerator` at a small size, so this is cheap
    /// enough to run on every take.
    static func look(at url: URL, samples: Int = 6) async -> Look? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds, duration > 0.05 else { return nil }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 64, height: 64)
        gen.requestedTimeToleranceBefore = .positiveInfinity
        gen.requestedTimeToleranceAfter = .positiveInfinity

        var means: [Double] = []
        for i in 0..<samples {
            // Spread across the clip but skip the very ends, which can be black on any cut.
            let t = duration * (0.1 + 0.8 * Double(i) / Double(max(1, samples - 1)))
            guard let cg = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
            else { continue }
            means.append(meanLuma(cg))
        }
        guard !means.isEmpty else { return nil }
        let brightness = means.reduce(0, +) / Double(means.count)
        // Spread between the sampled frames stands in for "is anything happening".
        let detail = (means.max() ?? 0) - (means.min() ?? 0)
        return Look(brightness: brightness, detail: detail)
    }

    private static func meanLuma(_ image: CGImage) -> Double {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &pixels, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return 0 }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard !pixels.isEmpty else { return 0 }
        return Double(pixels.reduce(0) { $0 + Int($1) }) / Double(pixels.count)
    }
}
