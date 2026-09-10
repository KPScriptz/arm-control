import SwiftUI

/// The rail, moving, without the rail.
///
/// 🔑 **The problem this solves.** Choosing a movement meant connecting to the machine, arming it,
/// homing it, running one program, watching, then repeating — minutes per candidate, and only
/// possible while standing next to the hardware. This replays a `MotionTrace` instead: the same
/// carriage on the same 0–600 mm scale, at real speed, on a laptop.
///
/// Everything drawn is from the trace. The travelled band is its real extent, the turnaround
/// markers are where the velocity actually reverses, and the speed readout is differentiated from
/// the samples rather than assumed — so a **recorded** trace shows what the machine did, and a
/// **predicted** one is visibly labelled as the guess it is.
struct VirtualArm: View {
    let trace: MotionTrace
    /// Shown above the rail. Usually the movement's name.
    var title: String = ""

    /// Drive the preview from someone else's clock instead of its own.
    ///
    /// 🔑 Set by `MovementStudioView` so the arm, the position track, the ramp and the camera row
    /// all show the SAME instant. When this is non-nil the internal transport is hidden and the
    /// internal anchor is ignored — two clocks driving one picture is how a preview drifts out of
    /// step with the timeline under it.
    var externalTime: Double? = nil

    /// A second curve drawn faintly behind the main one — the original, when this is an edit.
    ///
    /// 🔑 **"What did I just change?" is the question the editor could not answer.** Sliders move
    /// numbers; only the shape says whether the move got better. Without the original on the same
    /// axes you are comparing a curve on screen against a curve in your memory, which is exactly
    /// the comparison people get wrong — and the difference that matters here is often subtle
    /// (a slightly shallower ramp because the copy is speed-clamped) rather than obvious.
    var ghost: MotionTrace? = nil

    /// How the ghost is labelled, when there is one.
    var ghostLabel = "original"

    /// When playback started, and where it started from. Nil means paused.
    ///
    /// 🐞 **This used to be a `Timer.publish` held in a `let` property, and the playhead never
    /// moved.** A `let` initialiser runs on every struct init, so each redraw built a *new*
    /// publisher, `onReceive` resubscribed to it, and a 1/60 s timer was torn down before it could
    /// ever fire — every tick would have caused the redraw that destroyed its own timer. Deriving
    /// the time from a Date instead means playback depends on nothing but the clock.
    @State private var anchor: Date?
    @State private var offset: Double = 0
    @State private var rate: Double = 1

    private let range = PLC.positionRange

    private func time(at now: Date) -> Double {
        if let externalTime { return min(max(0, externalTime), trace.duration) }
        guard let anchor else { return min(offset, trace.duration) }
        return min(offset + now.timeIntervalSince(anchor) * rate, trace.duration)
    }

    private var playing: Bool { anchor != nil }

    var body: some View {
        // `paused:` stops the redraw entirely while nothing is moving, so a parked preview costs
        // nothing.
        TimelineView(.animation(paused: anchor == nil || externalTime != nil)) { ctx in
            let t = time(at: ctx.date)
            VStack(alignment: .leading, spacing: 14) {
                header(t)
                railTrack(t)
                graph(t)
                if externalTime == nil { transport(t) }
            }
        }
        .onChange(of: trace) { _, _ in anchor = nil; offset = 0 }
    }

    private func toggle(_ t: Double) {
        if anchor != nil {
            offset = t                      // freeze where it is
            anchor = nil
        } else {
            offset = t >= trace.duration ? 0 : t   // replay from the top once finished
            anchor = Date()
        }
    }

    // MARK: Header

    private func header(_ t: Double) -> some View {
        let mm = trace.position(at: t)
        let speed = trace.velocity(at: t)
        return
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                if !title.isEmpty {
                    Text(title).font(.headline).foregroundStyle(Theme.label)
                }
                HStack(spacing: 6) {
                    Image(systemName: trace.source.shapeIsReal ? "checkmark.seal.fill" : "questionmark.circle.fill")
                    Text(trace.source.label)
                    if trace.simulated { Text("· simulated").foregroundStyle(Theme.warn) }
                }
                .font(.caption)
                .foregroundStyle(trace.source.shapeIsReal ? Theme.good : Theme.warn)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                Text("\(Int(mm.rounded())) mm")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(abs(speed) < 2
                     ? "at rest"
                     : String(format: "%@ %.0f mm/s", speed > 0 ? "out" : "back", abs(speed)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.secondary)
            }
        }
    }

    // MARK: The rail

    private func railTrack(_ t: Double) -> some View {
        let mm = trace.position(at: t)
        let speed = trace.velocity(at: t)
        return
        GeometryReader { geo in
            // A `func` cannot live in a ViewBuilder closure, so the mapping is a plain closure.
            let w = geo.size.width
            let span = range.upperBound - range.lowerBound
            let inset: CGFloat = 16                      // room for the end stops
            let usable = w - inset * 2
            let x: (Double) -> CGFloat = { inset + CGFloat(($0 - range.lowerBound) / span) * usable }

            ZStack(alignment: .topLeading) {
                // 🔑 **This has to read as a MACHINE, not a progress bar.** The first version was a
                // thin capsule with a small square on it and the honest reaction was "where is the
                // mini arm?" — so: a proper beam with end stops, 100 mm ticks, and a carriage with
                // enough presence to find at a glance.

                // The beam
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(LinearGradient(colors: [Color.secondary.opacity(0.30),
                                                  Color.secondary.opacity(0.16)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(height: 10)
                    .offset(x: inset, y: 34)
                    .frame(width: usable, alignment: .leading)

                // End stops — the physical limits of travel, so 0 and 600 are visibly walls.
                ForEach([range.lowerBound, range.upperBound], id: \.self) { edge in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.secondary.opacity(0.55))
                        .frame(width: 5, height: 26)
                        .offset(x: x(edge) - 2.5, y: 26)
                }

                // 100 mm ticks
                ForEach(Array(stride(from: 100.0, to: range.upperBound, by: 100)), id: \.self) { p in
                    Rectangle()
                        .fill(Color.secondary.opacity(0.35))
                        .frame(width: 1, height: 6)
                        .offset(x: x(p), y: 46)
                }

                // The stretch this movement actually uses.
                Capsule()
                    .fill(Theme.accent.opacity(0.28))
                    .frame(width: max(3, x(trace.maxMM) - x(trace.minMM)), height: 10)
                    .offset(x: x(trace.minMM), y: 34)

                // Where it reverses.
                ForEach(Array(trace.turnarounds.enumerated()), id: \.offset) { _, ts in
                    Rectangle()
                        .fill(Theme.label.opacity(0.5))
                        .frame(width: 1.5, height: 22)
                        .offset(x: x(trace.position(at: ts)), y: 28)
                }

                // The carriage — a block on the beam, tinted while it is moving.
                VStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(abs(speed) < 2
                              ? AnyShapeStyle(Color.secondary.opacity(0.85))
                              : AnyShapeStyle(LinearGradient(colors: [Theme.accent,
                                                                      Theme.accent.opacity(0.75)],
                                                             startPoint: .top, endPoint: .bottom)))
                        .frame(width: 34, height: 26)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(.black.opacity(0.45), lineWidth: 1.5))
                        .shadow(color: Theme.accent.opacity(abs(speed) < 2 ? 0 : 0.55), radius: 7)
                    // The mount point, so it reads as a camera on a carriage.
                    Circle()
                        .fill(abs(speed) < 2 ? Color.secondary : Theme.accent)
                        .frame(width: 5, height: 5)
                }
                .offset(x: x(mm) - 17, y: 22)

                // Scale
                HStack {
                    Text("0 mm").font(.caption2).foregroundStyle(Theme.tertiary)
                    Spacer()
                    Text("\(Int(range.upperBound)) mm").font(.caption2).foregroundStyle(Theme.tertiary)
                }
                .offset(y: 60)
            }
        }
        .frame(height: 82)
    }

    // MARK: Position over time

    private func graph(_ t: Double) -> some View {
        let mm = trace.position(at: t)
        return
        GeometryReader { geo in
            Canvas { ctx, size in
                guard trace.duration > 0 else { return }
                let w = size.width, h = size.height
                let lo = range.lowerBound, hi = range.upperBound
                func px(_ time: Double) -> CGFloat { CGFloat(time / trace.duration) * w }
                func py(_ p: Double) -> CGFloat { h - CGFloat((p - lo) / (hi - lo)) * h }

                // Baseline
                ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: h)); $0.addLine(to: CGPoint(x: w, y: h)) },
                           with: .color(Color.secondary.opacity(0.25)), lineWidth: 1)

                // The original, behind. Drawn on THIS trace's time span rather than its own, so
                // the two start together — a speed-clamped copy runs longer than the move it
                // copies, and stretching the ghost to match would hide precisely that.
                if let ghost, ghost.duration > 0 {
                    var gp = Path()
                    var gfirst = true
                    var gt = 0.0
                    while gt <= min(trace.duration, ghost.duration) {
                        let pt = CGPoint(x: px(gt), y: py(ghost.position(at: gt)))
                        if gfirst { gp.move(to: pt); gfirst = false } else { gp.addLine(to: pt) }
                        gt += trace.duration / 120
                    }
                    ctx.stroke(gp, with: .color(Theme.secondary.opacity(0.55)),
                               style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                    ctx.draw(Text(ghostLabel).font(.caption2).foregroundStyle(Theme.secondary),
                             at: CGPoint(x: 34, y: 12))
                }

                // The curve
                var path = Path()
                var first = true
                var time = 0.0
                while time <= trace.duration {
                    let pt = CGPoint(x: px(time), y: py(trace.position(at: time)))
                    if first { path.move(to: pt); first = false } else { path.addLine(to: pt) }
                    time += trace.duration / max(120, 120)
                }
                ctx.stroke(path, with: .color(Theme.accent), lineWidth: 2)

                // Playhead
                let phx = px(min(t, trace.duration))
                ctx.stroke(Path { $0.move(to: CGPoint(x: phx, y: 0)); $0.addLine(to: CGPoint(x: phx, y: h)) },
                           with: .color(Theme.label.opacity(0.6)), lineWidth: 1)
                ctx.fill(Path(ellipseIn: CGRect(x: phx - 4, y: py(mm) - 4, width: 8, height: 8)),
                         with: .color(Theme.label))
            }
        }
        .frame(minHeight: 96, maxHeight: .infinity)
        .background(Color.secondary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: Transport

    private func transport(_ t: Double) -> some View {
        return
        VStack(spacing: 8) {
            HStack(spacing: 14) {
                Button {
                    toggle(t)
                } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 44, height: 36)
                }
                .buttonStyle(.bordered)
                .disabled(trace.isEmpty)

                Button {
                    anchor = nil; offset = 0
                } label: {
                    Image(systemName: "gobackward").font(.title3).frame(width: 44, height: 36)
                }
                .buttonStyle(.bordered)

                Picker("Speed", selection: $rate) {
                    Text("0.25×").tag(0.25)
                    Text("0.5×").tag(0.5)
                    Text("1×").tag(1.0)
                    Text("2×").tag(2.0)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 240)

                Spacer()

                Text(String(format: "%.2f / %.2fs", t, trace.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.secondary)
            }

            Slider(value: Binding(get: { min(t, trace.duration) },
                                  set: { anchor = nil; offset = $0 }),
                   in: 0...max(0.01, trace.duration))
        }
        .buttonBorderShape(.roundedRectangle(radius: Theme.controlRadius))
    }
}
