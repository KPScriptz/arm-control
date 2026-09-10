import SwiftUI

/// Drag the movement itself.
///
/// 🔑 **Sliders describe a move; this one *is* the move.** Every waypoint is a handle on a
/// position-over-time curve, and the two axes are the two things an operator actually wants to
/// change:
///   • **drag up / down** → where that leg travels to (0–600 mm)
///   • **drag left / right** → how long that leg takes, which is the speed (clamped 70–100 mm/s)
///
/// The speed clamp is enforced by the drag itself rather than by rejecting it afterwards: pulling a
/// handle further than the rail can physically move in that time simply stops moving. A control
/// that cannot express an impossible value never has to explain one.
///
/// ⚠️ The x-axis is a fixed window rather than the motion's own length. Rescaling live would make
/// every other handle slide out from under the finger while dragging one.
struct MotionCurveEditor: View {
    @Binding var motion: CustomMotion
    /// The recorded original, drawn behind as a ghost so an edit can be compared with what the
    /// machine actually does. Nil when authoring from scratch.
    var ghost: MotionTrace?
    /// Where the carriage starts. Real motions begin from wherever it is parked.
    var start: Double = 0

    @State private var dragging: Int?

    private let range = PLC.positionRange
    private var span: Double { max(25, motion.duration(from: start) * 1.15) }

    /// Cumulative arrival time and position of each waypoint.
    private var handles: [(t: Double, mm: Double)] {
        var out: [(Double, Double)] = []
        var here = start
        var t = 0.0
        for w in motion.waypoints {
            let target = w.clampedPosition
            t += abs(target - here) / w.clampedVelocity
            out.append((t, target))
            t += w.dwell
            here = target
        }
        return out.map { (t: $0.0, mm: $0.1) }
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let x: (Double) -> CGFloat = { CGFloat($0 / span) * w }
            let y: (Double) -> CGFloat = {
                h - CGFloat(($0 - range.lowerBound) / (range.upperBound - range.lowerBound)) * h
            }

            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    draw(ctx, size, x: x, y: y)
                }
                // One transparent surface takes every drag; hit-testing picks the nearest handle.
                // Per-handle views would fight the Canvas for the gesture.
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in handleDrag(g, width: w, height: h) }
                        .onEnded { _ in dragging = nil }
                )
            }
        }
        .frame(height: 200)
        .background(Color.secondary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: Drawing

    private func draw(_ ctx: GraphicsContext, _ size: CGSize,
                      x: (Double) -> CGFloat, y: (Double) -> CGFloat) {
        let w = size.width, h = size.height

        // Rail extremes, so 0 and 600 are readable without a legend.
        for mm in [range.lowerBound, range.upperBound] {
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y(mm)))
            line.addLine(to: CGPoint(x: w, y: y(mm)))
            ctx.stroke(line, with: .color(Color.secondary.opacity(0.25)),
                       style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        ctx.draw(Text("600").font(.system(size: 9)).foregroundStyle(Theme.tertiary),
                 at: CGPoint(x: 16, y: y(range.upperBound) + 8))
        ctx.draw(Text("0").font(.system(size: 9)).foregroundStyle(Theme.tertiary),
                 at: CGPoint(x: 10, y: y(range.lowerBound) - 8))

        // The original, if there is one to compare against.
        if let ghost, !ghost.isEmpty {
            var path = Path()
            var t = 0.0
            var first = true
            while t <= min(ghost.duration, span) {
                let p = CGPoint(x: x(t), y: y(ghost.position(at: t)))
                if first { path.move(to: p); first = false } else { path.addLine(to: p) }
                t += span / 200
            }
            ctx.stroke(path, with: .color(Theme.secondary.opacity(0.5)),
                       style: StrokeStyle(lineWidth: 2, dash: [4, 4]))
        }

        // The motion being edited.
        var path = Path()
        path.move(to: CGPoint(x: x(0), y: y(start)))
        for hnd in handles { path.addLine(to: CGPoint(x: x(hnd.t), y: y(hnd.mm))) }
        ctx.stroke(path, with: .color(Theme.accent), lineWidth: 2.5)

        // Handles, with the one under the finger enlarged.
        for (i, hnd) in handles.enumerated() {
            let r: CGFloat = dragging == i ? 11 : 8
            let rect = CGRect(x: x(hnd.t) - r, y: y(hnd.mm) - r, width: r * 2, height: r * 2)
            ctx.fill(Path(ellipseIn: rect), with: .color(Theme.accent))
            ctx.stroke(Path(ellipseIn: rect), with: .color(.black.opacity(0.5)), lineWidth: 2)
            if dragging == i {
                ctx.draw(Text(String(format: "%.0f mm · %.0f mm/s",
                                     hnd.mm, motion.waypoints[i].clampedVelocity))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.label),
                         at: CGPoint(x: min(w - 60, max(60, x(hnd.t))), y: max(14, y(hnd.mm) - 22)))
            }
        }
    }

    // MARK: Dragging

    private func handleDrag(_ g: DragGesture.Value, width: CGFloat, height: CGFloat) {
        let hs = handles
        guard !hs.isEmpty else { return }

        // Pick the nearest handle once, at the start, and keep it for the whole drag — re-picking
        // mid-drag makes the curve jump between points as they cross.
        if dragging == nil {
            var best = 0
            var bestD = CGFloat.greatestFiniteMagnitude
            for (i, hnd) in hs.enumerated() {
                let p = CGPoint(x: CGFloat(hnd.t / span) * width,
                                y: height - CGFloat((hnd.mm - range.lowerBound)
                                                    / (range.upperBound - range.lowerBound)) * height)
                let d = hypot(p.x - g.startLocation.x, p.y - g.startLocation.y)
                if d < bestD { bestD = d; best = i }
            }
            guard bestD < 44 else { return }        // a miss must not grab the far end of the rail
            dragging = best
        }
        guard let i = dragging, motion.waypoints.indices.contains(i) else { return }

        // Vertical → where it goes.
        let mm = Double((height - g.location.y) / height)
            * (range.upperBound - range.lowerBound) + range.lowerBound
        motion.waypoints[i].position = min(range.upperBound, max(range.lowerBound, (mm / 5).rounded() * 5))

        // Horizontal → how long this leg takes, i.e. its speed. The previous handle's arrival is
        // the leg's start, so only the gap is being edited.
        let from = i == 0 ? start : motion.waypoints[i - 1].clampedPosition
        let distance = abs(motion.waypoints[i].clampedPosition - from)
        if distance > 1 {
            let priorT = i == 0 ? 0 : handles[i - 1].t + motion.waypoints[i - 1].dwell
            let wantT = Double(g.location.x / width) * span
            let legSeconds = max(0.05, wantT - priorT)
            motion.waypoints[i].velocity = min(PLC.velocityRange.upperBound,
                                               max(PLC.velocityRange.lowerBound,
                                                   distance / legSeconds))
        }
    }
}
