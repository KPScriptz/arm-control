import SwiftUI

/// The rail itself, drawn to scale.
///
/// The console used to be a grid of buttons above a large empty rectangle, which is both a waste of
/// a 13-inch screen and a missed opportunity: the one thing an operator wants at a glance is where
/// the carriage is and whether it is moving. A number in the status strip answers that in the
/// abstract; a position on a track answers it instantly.
///
/// Everything drawn here is measured, not decorative — the scale is the PLC's real 0–600 mm travel,
/// the ghost band is the throw actually recorded by `MoveTimer`, and the carriage sits where
/// `CurrentPosition` says it does.
struct RailGauge: View {
    @StateObject private var link = GlamaticLink.shared
    @StateObject private var safety = SafetyKernel.shared
    @StateObject private var timer = MoveTimer.shared

    @AppStorage("armcontrol.take.program") private var program = 1

    /// Last few positions, for a motion trail. Cheap and it makes "is it moving" answerable without
    /// staring at a number.
    @State private var previous: Double?
    @State private var movingUntil = Date.distantPast

    private let range = PLC.positionRange

    private var position: Double { link.state.currentMM }
    private var isMoving: Bool { Date() < movingUntil }

    /// Mint when the rail will accept a command, amber when it will not, red when it is faulted.
    /// The carriage is the one place colour carries state — the glass around it stays neutral.
    private var carriageTint: Color {
        if link.state.hasFault { return Theme.bad }
        if safety.canTriggerProgram { return Theme.accent }
        return Theme.warn
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            GeometryReader { geo in
                VStack(spacing: 8) {
                    track(width: geo.size.width)
                        .frame(height: 48)
                    // Band first, then the numbers: the two bars belong together and the scale
                    // reads as a caption under both.
                    if let measured = timer.results[program]?.throwMM, measured > 1 {
                        throwBand(measured, width: geo.size.width)
                    }
                    scale
                }
            }
            .frame(height: timer.results[program] == nil ? 78 : 116)
        }
        .padding(20)
        .pivotGlass(in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .onChange(of: link.state.currentPosition) { _, _ in
            if let previous, abs(previous - position) > 0.5 {
                movingUntil = Date().addingTimeInterval(1.2)
            }
            previous = position
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(Int(position))")
                .font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(Theme.label)
                .contentTransition(.numericText())
                .animation(.snappy, value: Int(position))

            Text("mm")
                .font(.title3.weight(.medium))
                .foregroundStyle(Theme.tertiary)

            Spacer(minLength: 12)

            if isMoving {
                Label("Moving", systemImage: "arrow.left.and.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .transition(.opacity)
            } else if link.state.hasFault {
                Label("Faulted", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.bad)
            } else if !link.state.isHomed {
                Label("Not referenced", systemImage: "house.slash")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.warn)
            } else {
                Label("At rest", systemImage: "pause.circle")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.tertiary)
            }
        }
        .animation(.snappy, value: isMoving)
    }

    // MARK: Track

    private static let inset: Double = 11            // half the carriage width, so it never clips

    private func x(_ mm: Double, width: Double) -> Double {
        let usable = max(1, width - Self.inset * 2)
        let span = range.upperBound - range.lowerBound
        return Self.inset
            + (min(max(mm, range.lowerBound), range.upperBound) - range.lowerBound) / span * usable
    }

    private func track(width: Double) -> some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Theme.fill)
                .frame(height: 8)

            // Home, as a tick through the rail rather than a ring the carriage parks on top of.
            Capsule()
                .fill(Theme.separator)
                .frame(width: 2, height: 20)
                .offset(x: x(0, width: width) - 1)

            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(carriageTint)
                .frame(width: 22, height: 40)
                .shadow(color: carriageTint.opacity(isMoving ? 0.55 : 0), radius: 10)
                .offset(x: x(position, width: width) - Self.inset)
                .animation(.snappy(duration: 0.28), value: position)
        }
        .frame(maxHeight: .infinity)
    }

    /// The throw actually recorded for this program, on its own line rather than tinting the rail.
    ///
    /// Overlaid on the track it read as a muddy stripe the length of the whole rail and told you
    /// nothing; underneath it with its own number, it says what the stored move covers — which is
    /// something the app cannot otherwise know, since it cannot read a trajectory.
    private func throwBand(_ measured: Double, width: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.fill).frame(height: 4)
                Capsule()
                    .fill(Theme.accent.opacity(0.7))
                    .frame(width: max(2, x(measured, width: width) - x(0, width: width)), height: 4)
                    .offset(x: x(0, width: width) - Self.inset)
            }
            Text("Program \(program) travels \(Int(measured)) mm")
                .font(.caption2)
                .foregroundStyle(Theme.tertiary)
        }
    }

    // MARK: Scale

    private var scale: some View {
        HStack(spacing: 0) {
            ForEach(Array(stride(from: range.lowerBound, through: range.upperBound, by: 100)), id: \.self) { mm in
                Text("\(Int(mm))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.tertiary)
                    .frame(maxWidth: .infinity,
                           alignment: mm == range.lowerBound ? .leading
                                    : (mm == range.upperBound ? .trailing : .center))
            }
        }
    }
}
