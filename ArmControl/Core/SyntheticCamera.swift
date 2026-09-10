import AVFoundation
import CoreGraphics
import Foundation
import UIKit

/// Generates a stand-in "raw pass" clip so the whole booth loop can be rehearsed on a machine with
/// no camera at all.
///
/// ⚠️ This is ONLY used when the simulated rail is on AND the device genuinely has no camera. On a
/// real iPad the real camera is always used, even in simulated-rail mode — a rehearsal that quietly
/// stopped exercising the capture path would be worth very little.
///
/// The content is deliberately a moving test pattern rather than anything photographic: it is
/// obviously not a guest, and the horizontal travel plus the tick strip make the retime legible —
/// at 4× slow you can watch individual ticks crawl past, which is the whole thing the ramp is
/// supposed to do.
enum SyntheticCamera {

    /// Writes an out-and-back pan at the given frame rate. Matches a rail traverse: out for the
    /// first half of the take, back for the second.
    ///
    /// - Parameter holdAtStart: seconds at the head in which nothing moves. A real take opens on a
    ///   motionless rail — the camera's lead-in plus the program's own trigger latency — and that
    ///   dead head is exactly what `RampProfile.sourceOffset` exists to skip. A stand-in clip that
    ///   started moving on frame zero would make the offset invisible, which makes it the one part
    ///   of the profile a rehearsal could not check.
    static func makeClip(seconds: Double,
                         fps: Double,
                         holdAtStart: Double = 0,
                         size: CGSize = CGSize(width: 720, height: 1280)) async throws -> URL {

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("synthetic-\(UUID().uuidString).mov")
        try? FileManager.default.removeItem(at: url)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ])
        input.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
            ])

        guard writer.canAdd(input) else { throw RampRenderer.RenderError.stillWriteFailed }
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let total = max(1, Int((seconds * fps).rounded()))
        let timescale = CMTimeScale(fps.rounded())
        // Never let the hold swallow the whole clip: a preview of a motionless rail is not a
        // preview, and the clamp costs nothing.
        let hold = min(max(0, Int((holdAtStart * fps).rounded())), max(0, total - 2))

        for frame in 0..<total {
            while !input.isReadyForMoreMediaData {
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
            guard let pool = adaptor.pixelBufferPool,
                  let buffer = render(frame: frame, of: total, hold: hold, pool: pool, size: size) else {
                writer.cancelWriting()
                throw RampRenderer.RenderError.stillWriteFailed
            }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame),
                                                               timescale: timescale))
        }

        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw RampRenderer.RenderError.stillWriteFailed }
        return url
    }

    // MARK: Frame

    private static func render(frame: Int, of total: Int, hold: Int,
                               pool: CVPixelBufferPool, size: CGSize) -> CVPixelBuffer? {
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess,
              let buffer = out else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer),
                                  width: Int(size.width), height: Int(size.height),
                                  bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }

        // Out for the first half, back for the second — one rail traverse, starting only once the
        // dead head is over. Everything below reads `moved`, so during the hold the whole frame is
        // static: carriage parked, stripes still, ticks stopped. That is what the head of a real
        // take looks like, and a profile that samples it shows a frozen frame at 4× slow.
        let moved = max(0, frame - hold)
        let movingFrames = max(1, total - hold)
        let t = Double(moved) / Double(max(1, movingFrames - 1))
        let travel = t < 0.5 ? t * 2 : (1 - t) * 2          // 0→1→0

        ctx.setFillColor(UIColor(red: 0.04, green: 0.07, blue: 0.11, alpha: 1).cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))

        // Background stripes move at a different rate to the foreground bar, so the pan reads as
        // parallax rather than a sliding texture — the same cue that made the reference clip
        // obviously a lateral track.
        ctx.setFillColor(UIColor(white: 1, alpha: 0.05).cgColor)
        let stripeW = size.width / 6
        for i in -2...8 {
            let x = CGFloat(i) * stripeW * 1.6 - CGFloat(travel) * size.width * 0.5
            ctx.fill(CGRect(x: x, y: 0, width: stripeW, height: size.height))
        }

        // The carriage.
        let barW = size.width * 0.28
        let barH = size.height * 0.30
        let barX = CGFloat(travel) * (size.width - barW)
        ctx.setFillColor(UIColor(red: 0.30, green: 0.78, blue: 0.92, alpha: 1).cgColor)
        ctx.addPath(CGPath(roundedRect: CGRect(x: barX, y: (size.height - barH) / 2,
                                               width: barW, height: barH),
                           cornerWidth: 28, cornerHeight: 28, transform: nil))
        ctx.fillPath()

        // Tick strip: one tick per frame scrolls past. At 4× slow you can count them individually,
        // which is exactly how you tell real slow motion from repeated frames.
        ctx.setFillColor(UIColor.white.cgColor)
        let tickSpacing: CGFloat = 40
        let offset = CGFloat(moved % 1000) * 4
        var x = -offset.truncatingRemainder(dividingBy: tickSpacing)
        while x < size.width {
            ctx.fill(CGRect(x: x, y: size.height * 0.08, width: 3, height: 34))
            x += tickSpacing
        }

        return buffer
    }
}
