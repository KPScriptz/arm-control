import SwiftUI

/// The event console: the presets already stored on the Glamatic, as one card each.
///
/// Every one fires over the RAW TCP channel — no login, no session, no cookie — so the console
/// keeps working when the web telemetry session has expired, and triggering can never contribute
/// to swamping the S7-1200's web server.
struct ConsoleView: View {
    @StateObject private var link = GlamaticLink.shared
    @StateObject private var safety = SafetyKernel.shared
    @StateObject private var store = ProgramStore.shared
    @StateObject private var timer = MoveTimer.shared

    @State private var running: Int?
    @State private var fired = 0
    @State private var lastResult: String?

    private let columns = [GridItem(.adaptive(minimum: 240), spacing: 16)]

    /// Side by side is a landscape idea. The booth iPad is mounted PORTRAIT (that is why takes are
    /// recorded portrait), so at 1032pt wide it stacks and spends the height on the buttons instead.
    private static let twoColumnWidth: Double = 1100

    /// Below this there is not enough room to lay the screen out without scrolling.
    private static let roomyHeight: Double = 700

    /// ⚠️ Measured with a background reader rather than by wrapping the screen in a GeometryReader.
    /// A GeometryReader reports the frame INCLUDING the safe-area region the control bar sits in,
    /// so anything sized from it lays out under the bar — which clipped the last row of presets.
    /// Observing the width and letting the normal layout system place the content keeps the safe
    /// area honest.
    @State private var width: Double = 0
    @State private var compact = false

    var body: some View {
        layout
            .background {
                GeometryReader { geo in
                    Color.clear
                        .preference(key: SizeKey.self, value: geo.size)
                }
            }
            .onPreferenceChange(SizeKey.self) { size in
                width = size.width
                compact = size.height < Self.roomyHeight
            }
    }

    /// 🔑 **Always inside a ScrollView, with a definite card height.**
    ///
    /// Two earlier attempts tried to make the grid *fill* the remaining height — first by computing
    /// a per-card height from a GeometryReader, then by letting `Grid` divide the space it was
    /// given. Both looked right on an empty console and clipped the last row behind the control bar
    /// the moment a fault or not-homed card appeared and pushed everything down. Chasing the exact
    /// available height against a safe-area inset is a fight not worth having: give the cards a
    /// fixed, generous height and let overflow scroll. When it fits — the normal case —
    /// `.basedOnSize` means there is no scrolling and it looks identical.
    @ViewBuilder
    private var layout: some View {
        ScrollView {
            if compact {
                VStack(spacing: 16) {
                    stateColumn
                    presets(cardHeight: 92)
                }
                .padding(20)
            } else if width >= Self.twoColumnWidth {
                // Landscape: state on the left, actions on the right — how a machine console is
                // normally laid out.
                HStack(alignment: .top, spacing: 20) {
                    VStack(spacing: 16) { stateColumn }
                        .frame(width: 420)
                    presets(cardHeight: 150)
                }
                .padding(20)
            } else {
                VStack(spacing: 16) {
                    stateColumn
                    presets(cardHeight: 180)
                }
                .padding(20)
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        // Triggered on a counter, not on `running` — that goes back to nil when the send indicator
        // clears, which would buzz a second time about a second after the tap for no reason.
        .sensoryFeedback(.impact, trigger: fired)
    }

    // MARK: Columns

    @ViewBuilder
    private var stateColumn: some View {
        // The subject of the whole app, at the top of its own screen.
        RailGauge()

        if link.state.hasFault {
            faultCard
        } else if link.connected && !link.state.isHomed {
            homeCard
        } else if let blocker = safety.blocker, !safety.canTriggerProgram {
            // Same rule as the attendant screen: never a row of dimmed buttons with no reason.
            // But only ONE reason — a fault or a not-homed rail already has a card above that
            // explains it and offers the fix, and repeating it here read as nagging.
            Label(blocker.message, systemImage: "exclamationmark.circle.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.warn)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Theme.warn.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
        }

        if let lastResult {
            Text(lastResult)
                .font(.footnote)
                .foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
        }
    }

    /// The presets, at a size an operator can hit in a dark venue without looking straight at the
    /// iPad. The space is free, so it is spent on the targets.
    @ViewBuilder
    private func presets(cardHeight: Double) -> some View {
        if store.visible.isEmpty {
            ContentUnavailableView(
                "No presets shown",
                systemImage: "square.dashed",
                description: Text("All programs are hidden. Turn them back on in Setup.")
            )
            .padding(.top, 40)
        } else {
            LazyVGrid(columns: cardHeight > 100
                        ? Array(repeating: GridItem(.flexible(), spacing: 16), count: 2)
                        : columns,
                      spacing: 16) {
                ForEach(store.visible) { preset in
                    presetCard(preset, height: cardHeight)
                }
            }
            .pivotGlassGroup()
        }
    }

    /// `height: nil` lets the card fill whatever row the grid hands it.
    private func presetCard(_ preset: ProgramStore.Preset, height: Double?) -> some View {
        let isRunning = running == preset.number
        let ready = safety.canTriggerProgram
        return Button {
            run(preset)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: isRunning ? "arrow.triangle.2.circlepath" : "play.circle.fill")
                    .font(.system(size: 34))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isRunning ? Theme.accent : (ready ? Theme.accent : Theme.tertiary))
                    .symbolEffect(.pulse, isActive: isRunning)

                VStack(alignment: .leading, spacing: 3) {
                    Text(preset.display)
                        .font(.headline)
                        .foregroundStyle(ready ? Theme.label : Theme.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    // Only when the operator gave it a name — otherwise `display` already reads
                    // "Program 3" and this would print it twice.
                    if !preset.label.isEmpty {
                        Text("Program \(preset.number)")
                            .font(.caption)
                            .foregroundStyle(Theme.tertiary)
                    }

                    // What this move actually does, once someone has timed it. The card is large
                    // enough to say something useful, and this is the only place the throw and the
                    // duration of a stored program are knowable at all.
                    if let m = timer.results[preset.number] {
                        Text(String(format: "%.0f mm · %.1fs", m.throwMM, m.duration))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(ready ? Theme.accent : Theme.tertiary)
                            .padding(.top, 2)
                    }
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: height.map { CGFloat($0) })
            .frame(maxHeight: height == nil ? .infinity : nil)
            .padding(.horizontal, 22)
            // Neutral glass, accent in the CONTENT. Tinting the glass mint and then drawing a mint
            // label on it renders mint on mint over a dark background — unreadable.
            .pivotGlass(in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous),
                        interactive: ready)
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(Theme.accent, lineWidth: isRunning ? 2.5 : 0)
            }
        }
        .buttonStyle(.plain)
        .disabled(!ready || running != nil)
        .animation(.snappy, value: isRunning)
    }

    private func run(_ preset: ProgramStore.Preset) {
        running = preset.number
        fired += 1
        Task {
            let ok = await link.runProgram(preset.number)
            lastResult = ok
                ? "Sent “\(preset.display)” — program \(preset.number)."
                : "Program \(preset.number) did not reach the rail. Check the link."
            // The PLC reports no "program finished", so this is a SEND indicator only. Holding it
            // briefly and then clearing is honest; a progress bar would be a lie.
            try? await Task.sleep(nanoseconds: 900_000_000)
            running = nil
        }
    }

    // MARK: Recovery

    private var faultCard: some View {
        Card(title: "Fault latched", systemImage: "exclamationmark.triangle.fill",
             footnote: "Usually a “not referenced” status after an E-stop, not a hardware fault. The reset only takes with Manual and Enable on, and a successful homing is what actually clears it — so recovery arms, pulses the reset, then homes through it.") {
            Text("StatusError \(link.state.statusError) · RobotError \(link.state.robotError)")
                .font(.body.weight(.medium))
                .foregroundStyle(Theme.bad)

            Button {
                Task {
                    let ok = await link.recoverFromFault()
                    lastResult = ok ? "Fault cleared and homed."
                                    : "Recovery failed — hardware reset at the control box."
                }
            } label: {
                Label("Recover — arm, reset, home", systemImage: "wrench.adjustable.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(Theme.warn)
        }
    }

    private var homeCard: some View {
        // Titled as the action, not as the state. The gauge above and the pill below both already
        // say "not homed"; a third repeat of the same two words is nagging, and what the operator
        // actually needs from this card is the next step.
        Card(title: "Reference the rail", systemImage: "house.slash",
             footnote: "Homing is lost on every power cycle, and the PLC refuses moves until the rail is referenced.") {
            Button {
                Task {
                    guard await safety.arm() else {
                        lastResult = "Could not arm — check the PLC login."
                        return
                    }
                    _ = await link.home()
                    lastResult = await link.waitHomed() ? "Homed." : "Homing timed out after 35s."
                }
            } label: {
                // 🔑 The label reports the WORK, not just the intent. Homing can run for most of a
                // minute; a button that still says "Home the rail" the whole time reads as a
                // button that did not register the tap.
                HStack(spacing: 8) {
                    if link.isMotionBusy {
                        ProgressView().controlSize(.small)
                        Text(link.motionPhase ?? "Working…")
                    } else {
                        Label("Home the rail", systemImage: "house.fill")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            // ⚠️ Disabled, not merely ignored. A second tap used to start a SECOND full sequence;
            // three of those at once wedged the PLC's web server and left a trigger latched high.
            // The tap that causes a runaway must be impossible, not just unhelpful.
            .disabled(link.isMotionBusy)

            if link.isMotionBusy {
                Text("This can take up to a minute. Referencing hunts for the limit switch, so the rail may sit still before it moves.")
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
