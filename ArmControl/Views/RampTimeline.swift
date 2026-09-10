import SwiftUI

/// The ramp profile, drawn.
///
/// 🔑 **Why a picture and not more numbers.** The profile is the app's actual product — it is the
/// difference between a phone video of a rail and a clip somebody posts — and it is the one part
/// of the pipeline that cannot be checked by reading its settings. Six numbers per pass, an
/// authored length, a fit mode and a dead-head offset interact to decide *which moments of the
/// move appear and how slowly*, and the failure mode is not an error: it is a clip that opens on a
/// still frame, or covers the first third of a traverse, or spends its slow motion on the
/// turnaround. Every one of those reads as plausible in a Form and is obvious in one glance here.
///
/// ⚠️ **Both bars are drawn to the SAME seconds-per-pixel scale.** That is the whole point: a
/// 0.75s slice of source widening into a 3.0s block of output *is* 4× slow motion, and drawing
/// each bar normalised to its own length would hide exactly the quantity being tuned.
struct RampTimeline: View {

    /// ⚠️ Must already be `fitted(to:)` the take that will actually be recorded. Pass timings then
    /// include the dead-head shift, and `designedSourceDuration` is the real take length — which is
    /// what makes this a picture of tonight's clip rather than of the profile's authored ideal.
    let profile: RampProfile

    /// Length of the raw recording: lead-in plus traverse.
    let sourceLength: Double

    /// Whether an end card is actually loaded. `RampRenderer` only appends one if there is an
    /// image, so a profile with `endCardDuration` set but no card must not draw the block.
    let hasEndCard: Bool

    /// Seconds at the head in which the carriage has not moved yet. Shaded, because footage in
    /// there is a still frame and sampling it is almost always a mistake.
    let deadHead: Double

    /// Where the carriage reverses, when that is actually known. Nil for a program that has not
    /// been timed, or one that does not return to its start — guessing at it would put a confident
    /// marker on a diagram in the wrong place, which is worse than no marker.
    var turnaround: Double?

    private static let palette: [Color] = [Pivot.mint, Pivot.blue, Pivot.purple]

    private let barHeight: CGFloat = 30
    private let fanHeight: CGFloat = 48

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            caption("Recorded",
                    String(format: "%.1fs · %d fps", sourceLength, Int(profile.sourceFPS)))

            Canvas { ctx, size in draw(ctx, size) }
                .frame(height: barHeight * 2 + fanHeight)
                .accessibilityHidden(true)

            caption("Delivered",
                    String(format: "%.1fs · %d fps", outLength, Int(profile.outputFPS)))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Ramp timeline")
        .accessibilityValue(spokenSummary)
    }

    private func caption(_ lead: String, _ trail: String) -> some View {
        HStack {
            Text(lead)
            Spacer()
            Text(trail).monospacedDigit()
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(Theme.secondary)
    }

    // MARK: What the output is made of

    private struct Block {
        var start: Double
        var length: Double
        var color: Color
        var label: String?
        /// Asking for more slow motion than the frame rate can pay for.
        var over = false
        /// Index into `profile.passes`, or nil for the flash and the end card.
        var pass: Int?
        /// The flash is drawn at full strength because it *is* a white frame; the end card is
        /// muted because it is branding, not footage. Sharing one opacity made the flash read as
        /// a grey gap — which is what an unfilled hole in the timeline would look like.
        var opacity: Double = 0.9
    }

    private var blocks: [Block] {
        var out: [Block] = []
        var t = 0.0
        for (i, p) in profile.passes.enumerated() {
            out.append(Block(start: t,
                             length: p.outputDuration,
                             color: Self.palette[i % Self.palette.count],
                             label: p.rate < 1
                                ? String(format: "%.1f×", p.slowFactor)
                                : String(format: "%.1f× fast", p.rate),
                             over: !profile.isCleanSlowMotion(p),
                             pass: i))
            t += p.outputDuration
            if i < profile.passes.count - 1, profile.flashDuration > 0 {
                out.append(Block(start: t, length: profile.flashDuration,
                                 color: .white, opacity: 1))
                t += profile.flashDuration
            }
        }
        if hasEndCard, profile.endCardDuration > 0 {
            out.append(Block(start: t,
                             length: profile.endCardDuration,
                             color: Color.secondary,
                             label: "end card",
                             opacity: 0.5))
            t += profile.endCardDuration
        }
        return out
    }

    private var outLength: Double { blocks.last.map { $0.start + $0.length } ?? 0 }

    /// Shared scale, so a widening block reads as slow motion.
    private var span: Double { max(sourceLength, outLength, 0.1) }

    // MARK: Drawing

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        let w = size.width
        func x(_ t: Double) -> CGFloat { CGFloat(t / span) * w }

        let srcRect = CGRect(x: 0, y: 0, width: x(sourceLength), height: barHeight)
        let outY = barHeight + fanHeight
        let outRect = CGRect(x: 0, y: outY, width: x(outLength), height: barHeight)
        let r: CGFloat = 5

        // 1. The two troughs. Drawn full-length first so the unused tail of the shorter bar is
        //    visibly *unused* rather than simply absent.
        for rect in [srcRect, outRect] {
            ctx.fill(Path(roundedRect: rect, cornerRadius: r),
                     with: .color(Color.secondary.opacity(0.12)))
        }

        // 2. Dead head: footage in which nothing has moved yet.
        if deadHead > 0.02 {
            let dead = CGRect(x: 0, y: 0, width: x(min(deadHead, sourceLength)), height: barHeight)
            ctx.fill(Path(roundedRect: dead, cornerRadius: r),
                     with: .color(Color.secondary.opacity(0.22)))
            if dead.width > 34 {
                ctx.draw(Text("still").font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.secondary),
                         at: CGPoint(x: dead.midX, y: dead.midY))
            }
        }

        // 3. The fans, under the blocks so the block edges stay crisp.
        for b in blocks {
            guard let i = b.pass, profile.passes.indices.contains(i) else { continue }
            let p = profile.passes[i]
            let s0 = x(p.sourceStart), s1 = x(p.sourceStart + p.sourceDuration)
            let o0 = x(b.start), o1 = x(b.start + b.length)
            var fan = Path()
            fan.move(to: CGPoint(x: s0, y: barHeight))
            fan.addLine(to: CGPoint(x: s1, y: barHeight))
            fan.addLine(to: CGPoint(x: o1, y: outY))
            fan.addLine(to: CGPoint(x: o0, y: outY))
            fan.closeSubpath()
            ctx.fill(fan, with: .color(b.color.opacity(0.13)))
            for (a, z) in [(s0, o0), (s1, o1)] {
                var edge = Path()
                edge.move(to: CGPoint(x: a, y: barHeight))
                edge.addLine(to: CGPoint(x: z, y: outY))
                ctx.stroke(edge, with: .color(b.color.opacity(0.45)), lineWidth: 1)
            }
        }

        // 4. Source slices.
        for b in blocks {
            guard let i = b.pass, profile.passes.indices.contains(i) else { continue }
            let p = profile.passes[i]
            let rect = CGRect(x: x(p.sourceStart), y: 0,
                              width: max(1.5, x(p.sourceDuration)), height: barHeight)
            ctx.fill(Path(roundedRect: rect, cornerRadius: min(r, rect.width / 2)),
                     with: .color(b.color.opacity(0.9)))
        }

        // 5. Output blocks.
        for b in blocks {
            let rect = CGRect(x: x(b.start), y: outY,
                              width: max(1.5, x(b.length)), height: barHeight)
            let path = Path(roundedRect: rect, cornerRadius: min(r, rect.width / 2))
            ctx.fill(path, with: .color(b.color.opacity(b.opacity)))
            if b.over {
                // A pass over the frame budget is the one thing here that is actually wrong.
                ctx.stroke(path, with: .color(Theme.bad), lineWidth: 2)
            }
            if let label = b.label, rect.width > CGFloat(label.count) * 6.5 + 10 {
                ctx.draw(Text(label).font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.black.opacity(0.75)),
                         at: CGPoint(x: rect.midX, y: rect.midY))
            }
        }

        // 6. The turnaround, when it has been measured.
        if let turnaround, turnaround > 0, turnaround < sourceLength {
            var line = Path()
            line.move(to: CGPoint(x: x(turnaround), y: -1))
            line.addLine(to: CGPoint(x: x(turnaround), y: barHeight + 1))
            ctx.stroke(line, with: .color(Theme.label.opacity(0.55)),
                       style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            ctx.draw(Text("turn").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.secondary),
                     at: CGPoint(x: x(turnaround), y: barHeight + 10))
        }
    }

    // MARK: VoiceOver
    //
    // The diagram is the only place some of this is stated, so it has to survive not being looked
    // at. Canvas contributes nothing to the accessibility tree on its own.

    private var spokenSummary: String {
        var parts: [String] = [String(format: "%.1f second recording becomes a %.1f second clip.",
                                      sourceLength, outLength)]
        for (i, p) in profile.passes.enumerated() {
            parts.append(String(format: "Pass %d takes %.2f to %.2f seconds at %.1f times slow%@.",
                                i + 1, p.sourceStart, p.sourceStart + p.sourceDuration,
                                p.slowFactor,
                                profile.isCleanSlowMotion(p) ? "" : ", over the frame budget"))
        }
        if deadHead > 0.02 {
            parts.append(String(format: "The first %.1f seconds are a motionless rail and are skipped.", deadHead))
        }
        return parts.joined(separator: " ")
    }
}
