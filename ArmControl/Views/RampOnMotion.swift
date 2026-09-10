import SwiftUI

/// The ramp profile drawn **on the movement it will sample**.
///
/// 🔑 **This is the join the app was missing.** `RampTimeline` shows a profile against an abstract
/// length, and `VirtualArm` shows what the rail does — but the question that decides whether a clip
/// works is neither of those. It is *which part of the movement does each slow-motion pass land
/// on*, and until now that had to be held in someone's head as two pictures and some arithmetic.
///
/// Here the passes are shaded onto the real recorded curve, so a pass that samples the dead head, or
/// misses the turnaround, or runs off the end of the move, is visible rather than deduced.
struct RampOnMotion: View {
    /// The movement, as recorded or synthesised.
    let trace: MotionTrace
    /// Already `fitted(to:)` the take that will actually be recorded.
    let profile: RampProfile
    /// Seconds of motionless rail at the head — lead-in plus trigger latency.
    let deadHead: Double
    /// Length of the raw recording: lead-in plus traverse.
    let takeLength: Double

    private static let palette: [Color] = [Pivot.mint, Pivot.blue, Pivot.purple]
    private let range = PLC.positionRange

    /// The take's clock starts at the trigger; the trace's clock starts there too, so they align
    /// directly. The span is whichever runs longer, so nothing is drawn off the end.
    private var span: Double { max(takeLength, trace.duration, 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                Canvas { ctx, size in draw(ctx, size) }
            }
            .frame(height: 150)
            .background(Color.secondary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            // Legend, because a colour on a curve means nothing on its own.
            HStack(spacing: 12) {
                ForEach(Array(profile.passes.enumerated()), id: \.offset) { i, p in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Self.palette[i % Self.palette.count].opacity(0.85))
                            .frame(width: 10, height: 10)
                        Text(String(format: "Pass %d · %.1f×", i + 1, p.slowFactor))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(Theme.secondary)
                    }
                }
            }
        }
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        let w = size.width, h = size.height
        let x: (Double) -> CGFloat = { CGFloat($0 / span) * w }
        let y: (Double) -> CGFloat = {
            h - CGFloat(($0 - range.lowerBound) / (range.upperBound - range.lowerBound)) * (h - 20) - 10
        }

        // Dead head — footage in which nothing has moved yet.
        if deadHead > 0.02 {
            ctx.fill(Path(CGRect(x: 0, y: 0, width: x(deadHead), height: h)),
                     with: .color(Color.secondary.opacity(0.18)))
            if x(deadHead) > 46 {
                ctx.draw(Text("still").font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.secondary),
                         at: CGPoint(x: x(deadHead) / 2, y: 12))
            }
        }

        // Where each pass takes its footage from.
        for (i, p) in profile.passes.enumerated() {
            let colour = Self.palette[i % Self.palette.count]
            let rect = CGRect(x: x(p.sourceStart), y: 0,
                              width: max(2, x(p.sourceDuration)), height: h)
            ctx.fill(Path(rect), with: .color(colour.opacity(0.22)))
            for edge in [rect.minX, rect.maxX] {
                var line = Path()
                line.move(to: CGPoint(x: edge, y: 0))
                line.addLine(to: CGPoint(x: edge, y: h))
                ctx.stroke(line, with: .color(colour.opacity(0.7)), lineWidth: 1)
            }
            if rect.width > 26 {
                ctx.draw(Text("\(i + 1)").font(.system(size: 10, weight: .bold))
                            .foregroundStyle(colour),
                         at: CGPoint(x: rect.midX, y: h - 10))
            }
        }

        // Where the take stops recording. Anything past this is never filmed.
        if takeLength < trace.duration - 0.05 {
            var cut = Path()
            cut.move(to: CGPoint(x: x(takeLength), y: 0))
            cut.addLine(to: CGPoint(x: x(takeLength), y: h))
            ctx.stroke(cut, with: .color(Theme.bad),
                       style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
            ctx.draw(Text("take ends").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.bad),
                     at: CGPoint(x: min(w - 30, x(takeLength) + 30), y: 12))
        }

        // The movement itself, over the top so the shading never hides it.
        var path = Path()
        var t = 0.0
        var first = true
        while t <= min(trace.duration, span) {
            let pt = CGPoint(x: x(t), y: y(trace.position(at: t)))
            if first { path.move(to: pt); first = false } else { path.addLine(to: pt) }
            t += span / 240
        }
        ctx.stroke(path, with: .color(Theme.accent), lineWidth: 2.5)
    }
}
