import AVFoundation
import UIKit

/// Turns a raw constant-speed rail pass into the delivered clip: retimed passes, a white flash
/// between them, and a branded end card.
///
/// Everything happens on ONE composition video track with per-time-range layer instructions. That
/// matters: the source footage carries a rotation transform and the generated clips (flash, end
/// card) do not, so a single track-wide transform would rotate the generated ones incorrectly.
enum RampRenderer {

    /// Six characters of randomness, enough to make same-second filenames distinct without turning
    /// a directory listing into a wall of UUIDs.
    static func uniqueSuffix() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<6).map { _ in alphabet.randomElement()! })
    }

    enum RenderError: LocalizedError {
        case noVideoTrack
        case sourceTooShort(needs: Double, has: Double)
        case exportFailed(String)
        case stillWriteFailed

        var errorDescription: String? {
            switch self {
            case .noVideoTrack:
                return "That file has no video track."
            case .sourceTooShort(let needs, let has):
                return String(format: "Recording is %.1fs but this profile needs %.1fs. Record longer or shorten the passes.", has, needs)
            case .exportFailed(let m):
                return "Export failed: \(m)"
            case .stillWriteFailed:
                return "Could not build the flash or end card."
            }
        }
    }

    /// Render `source` through `profile`. Returns the URL of the finished .mp4.
    static func render(source: URL,
                       profile: RampProfile,
                       endCard: UIImage?,
                       progress: (@Sendable (String) -> Void)? = nil) async throws -> URL {

        let asset = AVURLAsset(url: source)
        guard let srcVideo = try await asset.loadTracks(withMediaType: .video).first else {
            throw RenderError.noVideoTrack
        }

        let srcDuration = try await asset.load(.duration).seconds
        // Rescale the pass timings onto the take that was actually recorded. Without this, changing
        // Traverse silently makes every profile sample the wrong part of the move.
        let profile = profile.fitted(to: srcDuration)
        guard srcDuration + 0.05 >= profile.requiredSourceDuration else {
            throw RenderError.sourceTooShort(needs: profile.requiredSourceDuration, has: srcDuration)
        }

        let transform = try await srcVideo.load(.preferredTransform)
        let natural = try await srcVideo.load(.naturalSize)
        // Upright frame size after the source's own rotation is applied.
        let upright = natural.applying(transform)
        let renderSize = CGSize(width: abs(upright.width), height: abs(upright.height))

        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .video,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw RenderError.noVideoTrack
        }

        // Audio is deliberately dropped. A booth clip plays on a phone with the ringer off, and the
        // retimed passes would pitch-shift a room's noise into something unpleasant.

        var instructions: [AVMutableVideoCompositionInstruction] = []
        var cursor = CMTime.zero
        let scale: CMTimeScale = 600

        // The flash and end-card clips are written to disk purely to get onto the composition
        // track. Once the export is done they are dead weight, and a busy event generates one or
        // two per take.
        var scratch: [URL] = []
        defer {
            for url in scratch { try? FileManager.default.removeItem(at: url) }
        }

        /// Insert a slice of the SOURCE and retime it, carrying the source rotation.
        func appendPass(_ pass: RampProfile.Pass) throws {
            let range = CMTimeRange(
                start: CMTime(seconds: pass.sourceStart, preferredTimescale: scale),
                duration: CMTime(seconds: pass.sourceDuration, preferredTimescale: scale))
            try track.insertTimeRange(range, of: srcVideo, at: cursor)

            let inserted = CMTimeRange(start: cursor,
                                       duration: CMTime(seconds: pass.sourceDuration, preferredTimescale: scale))
            // scaleTimeRange is the retime. Stretching to a longer output = slow motion.
            track.scaleTimeRange(inserted,
                                 toDuration: CMTime(seconds: pass.outputDuration, preferredTimescale: scale))

            let outRange = CMTimeRange(start: cursor,
                                       duration: CMTime(seconds: pass.outputDuration, preferredTimescale: scale))
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
            layer.setTransform(transform, at: outRange.start)
            let inst = AVMutableVideoCompositionInstruction()
            inst.timeRange = outRange
            inst.layerInstructions = [layer]
            instructions.append(inst)

            cursor = CMTimeAdd(cursor, outRange.duration)
        }

        /// Insert a generated still clip. Already upright, so identity transform.
        func appendStill(_ image: UIImage, seconds: Double, fadeIn: Double) async throws {
            guard seconds > 0 else { return }
            let clip = try await StillClip.make(image: image, size: renderSize, seconds: seconds)
            scratch.append(clip)
            let stillAsset = AVURLAsset(url: clip)
            guard let stillTrack = try await stillAsset.loadTracks(withMediaType: .video).first else {
                throw RenderError.stillWriteFailed
            }
            let dur = CMTime(seconds: seconds, preferredTimescale: scale)
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: stillTrack, at: cursor)

            let outRange = CMTimeRange(start: cursor, duration: dur)
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
            layer.setTransform(.identity, at: outRange.start)
            if fadeIn > 0 {
                layer.setOpacityRamp(fromStartOpacity: 0,
                                     toEndOpacity: 1,
                                     timeRange: CMTimeRange(start: outRange.start,
                                                            duration: CMTime(seconds: min(fadeIn, seconds),
                                                                             preferredTimescale: scale)))
            }
            let inst = AVMutableVideoCompositionInstruction()
            inst.timeRange = outRange
            inst.layerInstructions = [layer]
            instructions.append(inst)

            cursor = CMTimeAdd(cursor, dur)
        }

        // 1. Passes, with the flash between them.
        for (i, pass) in profile.passes.enumerated() {
            progress?("Retiming pass \(i + 1) of \(profile.passes.count) at \(String(format: "%.2f", pass.rate))×")
            try appendPass(pass)
            if i < profile.passes.count - 1, profile.flashDuration > 0 {
                try await appendStill(StillClip.white, seconds: profile.flashDuration, fadeIn: 0)
            }
        }

        // 2. End card.
        if let endCard, profile.endCardDuration > 0 {
            progress?("Adding end card")
            try await appendStill(endCard, seconds: profile.endCardDuration, fadeIn: profile.endCardFade)
        }

        // 3. Export.
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(profile.outputFPS))
        videoComposition.instructions = instructions

        // ⚠️ The timestamp is SECONDS, so two renders finishing inside the same second used to
        // collide — and the collision is silent, because the next line deletes whatever is there.
        // The worst case is not a lost file: `TakeLog` remembers a take by filename, so an earlier
        // entry would start pointing at a later render and a guest could be handed **someone else's
        // clip**. The timestamp stays because it sorts and reads well in a directory listing; the
        // suffix is what makes it unique.
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("ramp-\(Int(Date().timeIntervalSince1970))-\(Self.uniqueSuffix()).mp4")
        try? FileManager.default.removeItem(at: out)

        guard let export = AVAssetExportSession(asset: composition,
                                                presetName: AVAssetExportPresetHighestQuality) else {
            throw RenderError.exportFailed("no export session")
        }
        export.outputURL = out
        export.outputFileType = .mp4
        export.videoComposition = videoComposition
        export.shouldOptimizeForNetworkUse = true

        // `cursor` is the length actually composed. `profile.outputDuration` always counts the end
        // card, so with no card chosen it promised 10.4s and delivered 7.0s.
        progress?("Exporting \(String(format: "%.1f", cursor.seconds))s")
        await export.export()

        guard export.status == .completed else {
            throw RenderError.exportFailed(export.error?.localizedDescription ?? "unknown")
        }

        // 🔑 **Check the OUTPUT, not just the status.** Every other measurement in this app audits
        // an input — the frame rate the camera delivered, the seconds the rail actually moved — and
        // the one thing never checked was the file the guest is handed. `.completed` is a claim
        // about the export session, not about what landed on disk: a truncated or empty result
        // still reports success, and the clip plays for half a second and stops. The composition
        // knows exactly what it built, so compare.
        let expected = cursor.seconds
        guard let report = await ClipInspector.inspect(out), report.frames > 0 else {
            try? FileManager.default.removeItem(at: out)
            throw RenderError.exportFailed("the export produced an unreadable or empty file")
        }
        if report.duration < expected * 0.5 {
            try? FileManager.default.removeItem(at: out)
            throw RenderError.exportFailed(String(format: "the export was cut short — %.1fs of the %.1fs composed", report.duration, expected))
        }
        if abs(report.duration - expected) > 0.25 {
            // Not fatal — a fraction of a second at the tail is normal rounding — but worth a line
            // in the trace when a clip comes out a different length from the timeline that built it.
            GlamaticLink.plog(String(format: "render length %.2fs vs %.2fs composed (%@)",
                                     report.duration, expected, report.summary))
        }
        return out
    }
}

/// Writes a solid image out as a short video clip.
///
/// Both the flash and the end card need to become real video segments so they can live on the same
/// composition track as the footage. AVAssetWriter is the least fragile way to do that — no Core
/// Animation timing to get wrong, and the result is a normal asset the composition understands.
enum StillClip {

    static let white: UIImage = {
        let r = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        return r.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }()

    static func make(image: UIImage, size: CGSize, seconds: Double) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("still-\(UUID().uuidString).mov")

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                                                           sourcePixelBufferAttributes: attrs)
        guard writer.canAdd(input) else { throw RampRenderer.RenderError.stillWriteFailed }
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        guard let pool = adaptor.pixelBufferPool,
              let buffer = makeBuffer(pool: pool, image: image, size: size) else {
            writer.cancelWriting()
            throw RampRenderer.RenderError.stillWriteFailed
        }

        // A still needs only two frames — one at the start and one at the end. The compositor holds
        // the last frame for the gap, so writing 30fps of identical frames would be pure waste.
        let fps: Int32 = 30
        let last = CMTime(seconds: seconds, preferredTimescale: fps)
        for time in [CMTime.zero, last] {
            while !input.isReadyForMoreMediaData {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            adaptor.append(buffer, withPresentationTime: time)
        }

        input.markAsFinished()
        await writer.finishWriting()

        guard writer.status == .completed else { throw RampRenderer.RenderError.stillWriteFailed }
        return url
    }

    private static func makeBuffer(pool: CVPixelBufferPool, image: UIImage, size: CGSize) -> CVPixelBuffer? {
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess,
              let buffer = out else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer),
                                  width: Int(size.width),
                                  height: Int(size.height),
                                  bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue),
              let cg = image.cgImage else { return nil }

        ctx.setFillColor(UIColor.black.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))

        // Aspect-fit so a card authored at a different ratio is letterboxed, never stretched.
        let scale = min(size.width / CGFloat(cg.width), size.height / CGFloat(cg.height))
        let w = CGFloat(cg.width) * scale
        let h = CGFloat(cg.height) * scale
        ctx.draw(cg, in: CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h))

        return buffer
    }
}
