import AVKit
import SwiftUI

/// What the booth attendant sees. One screen, one action, no settings anywhere on it.
///
/// Rules, and they are the point:
/// - Nothing here can move the rail except the start button, and it runs a preset chosen behind
///   the PIN. No jog, no position field, no program picker.
/// - When the rail is faulted or not homed it says so in plain words and refuses. A disabled grey
///   button with no reason is what makes an attendant tap it eleven times.
/// - The way out is three taps on an unmarked corner, then the PIN. Unmarked because a visible
///   lock button is a thing guests press.
struct AttendantView: View {
    @StateObject private var runner = TakeRunner.shared
    @StateObject private var recorder = Recorder.shared
    @StateObject private var safety = SafetyKernel.shared
    @StateObject private var link = GlamaticLink.shared
    @StateObject private var store = ProgramStore.shared
    @StateObject private var kiosk = Kiosk.shared
    @StateObject private var text = TextDelivery.shared

    @AppStorage("armcontrol.take.program") private var program = 1
    @AppStorage("armcontrol.take.seconds") private var seconds = 6.0
    @AppStorage("armcontrol.take.leadIn") private var leadIn = 0.3
    @AppStorage("armcontrol.booth.countdown") private var countdown = 3
    @AppStorage("armcontrol.booth.holdResult") private var holdResult = 8.0

    @State private var showPIN = false
    @State private var player: AVPlayer?
    @State private var cornerTaps = 0
    @State private var cornerResetTask: Task<Void, Never>?
    @State private var holdRemaining = 0
    @State private var holdPaused = false
    /// Non-nil while the guest is typing their number. Carries the link rather than a Bool so the
    /// pad can never be presented without one.
    ///
    /// Wrapped because `fullScreenCover(item:)` needs `Identifiable` and `URL` is not — and a
    /// retroactive conformance on a stdlib type to save four lines is not worth the conflict it
    /// invites later.
    private struct TextTarget: Identifiable {
        let id = UUID()
        let url: URL
    }
    @State private var textingLink: TextTarget?
    /// Landscape only. The booth iPad is mounted portrait, so this is the exception, not the rule.
    @State private var isWide = false
    @State private var clipAspect: Double = 9.0 / 16.0

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            Group {
                switch runner.phase {
                case .idle:             idle
                case .countdown(let n): countdownView(n)
                case .recording:        recording
                case .rendering(let s): rendering(s)
                case .done(let url):    result(url)
                case .failed(let m):    failure(m)
                }
            }
            .transition(.opacity)
            // Scoped to the phase content ONLY. Applied to the whole ZStack it also animates the
            // badge and the hotspot, and mid-transition SwiftUI renders two copies of the badge.
            .animation(.smooth(duration: 0.35), value: runner.phase)

            cornerHotspot

            // Even the guest-facing screen says so. Someone must never walk up to this booth
            // believing it is driving a rail when it is driving nothing.
        }
        .fullScreenCover(isPresented: $showPIN) {
            PINPad(onSuccess: { showPIN = false }, onCancel: { showPIN = false })
        }
        // Full screen rather than a sheet: a guest is typing this at arm's length on a mounted
        // iPad, and a form sheet puts a 380pt keypad in the middle of a 13-inch screen with the
        // booth showing round the edges.
        .fullScreenCover(item: $textingLink) { target in
            PhonePad(link: target.url) { textingLink = nil }
        }
        .background {
            GeometryReader { geo in
                Color.clear.preference(key: SizeKey.self, value: geo.size)
            }
        }
        .onPreferenceChange(SizeKey.self) { isWide = $0.width > $0.height }
        // Haptics on the moments that matter. An attendant is looking at the guest, not the iPad,
        // and a booth is loud — the tap that starts a take and the beat when the clip is ready are
        // exactly the things Apple's own apps confirm through the hand rather than the eye.
        .sensoryFeedback(trigger: runner.phase) { _, phase in
            switch phase {
            case .countdown:  return .selection
            case .recording:  return .impact(weight: .heavy)
            case .done:       return .success
            case .failed:     return .error
            default:          return nil
            }
        }
        .task { await recorder.start() }
        .statusBarHidden()
    }

    // MARK: Idle

    private var idle: some View {
        VStack(spacing: 24) {
            programCaption

            // 🔑 A guest walking up to a booth should see themselves. Without this the screen asked
            // people to pose at a black rectangle and hope — every photo booth ever built shows the
            // subject a live view, because framing is the guest's job and they cannot do it blind.
            previewPane

            Button(action: start) {
                Label(blocker == nil ? "Start" : "Not ready",
                      systemImage: blocker == nil ? "play.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 42, weight: .semibold, design: .rounded))
                    .labelStyle(.titleAndIcon)
                    // Mint LABEL on neutral glass — not a mint-tinted glass with a mint label,
                    // which over a dark background renders as mint on mint and is unreadable.
                    // Liquid Glass is a neutral material; the colour belongs to the content.
                    .foregroundStyle(blocker == nil ? Theme.accent : Theme.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 140)
                    .pivotGlass(in: RoundedRectangle(cornerRadius: Theme.heroRadius, style: .continuous),
                                interactive: blocker == nil)
            }
            .buttonStyle(.plain)
            .disabled(blocker != nil)

            // The reason, always. Never a silent disabled button.
            Text(blocker ?? "Tap when the guest is in position")
                .font(.title3)
                .foregroundStyle(blocker == nil ? Theme.secondary : Theme.warn)
                .multilineTextAlignment(.center)

            if !kiosk.hasEverUnlocked { firstRunHint }
        }
        .padding(32)
    }

    /// Shown once, on an iPad nobody has ever unlocked, then never again.
    ///
    /// It names the PIN only while the PIN is still the factory one — by definition nobody has been
    /// inside to change it, and the person holding a freshly installed iPad is the person setting it
    /// up. The moment someone unlocks, this disappears for good and the corner goes back to being
    /// unmarked, which is what it has to be in front of guests.
    private var firstRunHint: some View {
        VStack(spacing: 6) {
            Label("First run", systemImage: "hand.tap")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent)
            Text(kiosk.pin == Kiosk.defaultPIN
                 ? "Tap the top-left corner three times, then enter \(Kiosk.defaultPIN) to set the booth up."
                 : "Tap the top-left corner three times, then enter your PIN to set the booth up.")
                .font(.footnote)
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 22)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
    }

    /// The line that names the preset — and, quietly, the fact that no hardware is attached.
    ///
    /// The loud SIMULATED banner is gone from the guest screen. But removing it outright would
    /// leave NOTHING indicating that a booth is driving no rail: a locked iPad in simulated mode
    /// looks entirely normal and hands out clips of a machine that never moved.
    private var programCaption: some View {
        HStack(spacing: 8) {
            Text(store.presets.first { $0.number == program }?.display ?? "Ready")
            if link.simulated {
                Text("· Simulated")
                    .foregroundStyle(Theme.warn)
            }
        }
        .font(.title3)
        .foregroundStyle(Theme.secondary)
    }

    /// The live view, or an honest explanation of why there isn't one.
    ///
    /// Built as phase CONTENT rather than as an overlay on the outer ZStack — an overlay there is
    /// what got drawn twice and produced the duplicate badge that was never explained.
    private var previewPane: some View {
        ZStack {
            if recorder.isRunning && !recorder.synthetic {
                CameraPreview(session: recorder.session)
            } else {
                Rectangle()
                    .fill(Theme.card)
                    .overlay {
                        VStack(spacing: 10) {
                            Image(systemName: recorder.synthetic ? "wrench.and.screwdriver.fill" : "video.slash")
                                .font(.system(size: 44))
                                .symbolRenderingMode(.hierarchical)
                            Text(recorder.synthetic ? "Simulated camera" : "No camera")
                                .font(.title3.weight(.medium))
                        }
                        .foregroundStyle(Theme.tertiary)
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    // MARK: Phases

    /// Counting down OVER the live view. A guest spends these three seconds checking they are in
    /// shot, which they cannot do on a screen that has replaced the picture with a number.
    private func countdownView(_ n: Int) -> some View {
        VStack(spacing: 24) {
            programCaption
            previewPane
                .overlay {
                    ZStack {
                        Color.black.opacity(0.35)
                        VStack(spacing: 4) {
                            Text("\(n)")
                                .font(.system(size: 200, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(.white)
                                .contentTransition(.numericText(countsDown: true))
                                .id(n)
                            Text("Get ready")
                                .font(.title)
                                .foregroundStyle(.white.opacity(0.85))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                }
            Color.clear.frame(height: 140)
        }
        .padding(32)
    }

    private var recording: some View {
        VStack(spacing: 24) {
            programCaption
            previewPane
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(Theme.bad, lineWidth: 6)
                }
                .overlay(alignment: .top) {
                    Label("Recording", systemImage: "record.circle.fill")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                        .symbolEffect(.pulse)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 12)
                        .background(Theme.bad, in: Capsule())
                        .padding(.top, 22)
                }

            Text("Hold still")
                .font(.system(size: 40, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.label)
                .frame(height: 140)
        }
        .padding(32)
    }

    private func rendering(_ stage: String) -> some View {
        VStack(spacing: 18) {
            Spacer()
            ProgressView()
                .controlSize(.extraLarge)
            Text("Making your clip")
                .font(.system(size: 38, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.label)
                .padding(.top, 12)
            Text(stage)
                .font(.body)
                .foregroundStyle(Theme.secondary)
                .contentTransition(.opacity)
            Spacer()
        }
    }

    /// 🔑 **The QR must be on screen at the same time as the clip.** A guest watching their video is
    /// already looking at this screen; making them wait for a second screen to scan is how a queue
    /// backs up. In landscape that means beside it. In PORTRAIT — which is how the booth iPad is
    /// actually mounted — putting them side by side squeezed a 9:16 clip into half the width and
    /// pushed it off the top of the screen, so the QR moves underneath instead. Same rule, and the
    /// clip gets the room it needs.
    private func result(_ url: URL) -> some View {
        VStack(spacing: 18) {
            if isWide {
                HStack(spacing: 28) {
                    clipPlayer
                    if let code = qrImage {
                        VStack(spacing: 12) {
                            qrCard(code, size: 220)
                            Text("Scan to keep it")
                                .font(.headline)
                                .foregroundStyle(Theme.label)
                            Text("On the venue Wi-Fi")
                                .font(.caption)
                                .foregroundStyle(Theme.secondary)
                        }
                    }
                }
            } else {
                clipPlayer
                if let code = qrImage {
                    HStack(spacing: 18) {
                        qrCard(code, size: 132)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Scan to keep it")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(Theme.label)
                            Text("On the venue Wi-Fi")
                                .font(.subheadline)
                                .foregroundStyle(Theme.secondary)
                        }
                    }
                }
            }

            if let warning = runner.armWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.warn)
            }

            HStack(spacing: 14) {
                // Offered only when texting is actually set up AND there is a link to send.
                // A dead button on the guest screen is worse than no button.
                if text.isReady, let deliveryLink = runner.deliveryURL {
                    Button {
                        holdPaused = true          // typing a number takes longer than the hold
                        textingLink = TextTarget(url: deliveryLink)
                    } label: {
                        Label("Text it to me", systemImage: "message.fill")
                            .font(.title3.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 62)
                    }
                    .buttonStyle(.bordered)
                }

                ShareLink(item: url) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 62)
                }
                .buttonStyle(.bordered)

                Button(action: finish) {
                    Label(holdPaused || holdRemaining == 0 ? "Next guest" : "Next guest · \(holdRemaining)",
                          systemImage: "arrow.right")
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .frame(maxWidth: .infinity)
                        .frame(height: 62)
                }
                .buttonStyle(.borderedProminent)
            }
            .buttonBorderShape(.roundedRectangle(radius: Theme.controlRadius))
        }
        .padding(32)
        // Tapping anywhere on the result holds it. Getting a phone out, opening the camera and
        // lining up a QR takes longer than a guest expects, and having it vanish mid-scan is the
        // most annoying thing this screen could do. The attendant taps once and it waits.
        .contentShape(Rectangle())
        .onTapGesture { holdPaused = true }
        .onAppear {
            let p = AVPlayer(url: url)
            p.play()
            player = p
            loadAspect(of: url)
            holdPaused = false
            holdRemaining = max(1, Int(holdResult))
            // Auto-advance so a queue never stalls on a clip nobody dismissed — but visibly, and
            // pausable. A FAILED take never auto-advances; that one needs someone to look at it.
            // 🐞 The hold used to run on regardless of what the guest was doing, and typing a
            // phone number takes far longer than the 8s default. The countdown expired mid-entry,
            // `finish()` reset the runner underneath the keypad, and the guest was left typing
            // into a pad floating over the idle screen. Entering a number is exactly as much a
            // reason to wait as tapping the screen is.
            Task {
                while holdRemaining > 0 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard case .done = runner.phase else { return }
                    if !holdPaused, textingLink == nil { holdRemaining -= 1 }
                }
                if case .done = runner.phase, textingLink == nil { finish() }
            }
        }
    }

    /// The clip, with its frame constrained to the clip's own shape.
    ///
    /// Without the aspect ratio the player fills the full width, pillarboxes a 9:16 clip inside
    /// itself, and the rounded corners land on the **invisible black frame** rather than on the
    /// picture — so the video reads as a hard-edged rectangle bleeding off the top of the screen.
    @ViewBuilder
    private var clipPlayer: some View {
        if let player {
            VideoPlayer(player: player)
                .aspectRatio(clipAspect, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Read from the file rather than assumed — a take is portrait, but Post can hand this screen
    /// anything.
    private func loadAspect(of url: URL) {
        Task {
            guard let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
                  let size = try? await track.load(.naturalSize),
                  let transform = try? await track.load(.preferredTransform) else { return }
            let r = size.applying(transform)
            let w = abs(r.width), h = abs(r.height)
            guard w > 1, h > 1 else { return }
            clipAspect = w / h
        }
    }

    private var qrImage: UIImage? {
        guard let link = runner.deliveryURL else { return nil }
        return DeliveryServer.qr(for: link)
    }

    /// White card behind the code, at integer scale with no interpolation — a smoothed QR scans
    /// badly, and a dark one does not scan at all.
    private func qrCard(_ code: UIImage, size: Double) -> some View {
        Image(uiImage: code)
            .interpolation(.none)
            .resizable()
            .frame(width: size, height: size)
            .padding(12)
            .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 72))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Theme.warn)
            Text("That take didn't work")
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.label)
            Text(message)
                .font(.body)
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 72)
            // The footage survived; only the export failed. Rebuilding it needs neither the guest
            // nor the rail, so offer that first — asking somebody to pose again for a problem that
            // happened after they had already finished is the worst option on this screen.
            if runner.retryableRaw != nil {
                Button {
                    Task { await runner.retryRender() }
                } label: {
                    Label("Make the clip again", systemImage: "arrow.clockwise")
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: 420)
                        .frame(height: 62)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: Theme.controlRadius))
                .padding(.top, 8)

                Text("The rail already moved and the shot is saved — this only rebuilds the clip.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondary)

                Button("Start over", action: finish)
                    .buttonStyle(.plain)
                    .font(.body)
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 2)
            } else {
                Button("Try again", action: finish)
                    .buttonStyle(.bordered)
                    .controlSize(.extraLarge)
                    .padding(.top, 8)
            }
            Spacer()
        }
    }

    // MARK: Escape hatch

    private var cornerHotspot: some View {
        VStack {
            HStack {
                ZStack(alignment: .topLeading) {
                    Color.clear
                        .frame(width: 110, height: 110)
                        .contentShape(Rectangle())
                        .onTapGesture { cornerTapped() }

                    // Nothing at all until the first tap lands, then one dot per tap. Invisible to
                    // a guest who never touches the corner, and proof to the operator that the
                    // hotspot is alive — the alternative is tapping a dead corner with no feedback
                    // and concluding you are locked out of your own iPad.
                    if cornerTaps > 0 {
                        HStack(spacing: 6) {
                            ForEach(0..<3, id: \.self) { i in
                                Circle()
                                    .fill(i < cornerTaps ? Theme.accent : Theme.separator)
                                    .frame(width: 8, height: 8)
                            }
                        }
                        .padding(.leading, 24)
                        .padding(.top, 28)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                    }
                }
                Spacer()
            }
            Spacer()
        }
        // Deliberately NOT .ignoresSafeArea(). A safe-area-ignoring child makes SwiftUI lay the
        // parent ZStack out twice, and the SIMULATED overlay attached to that stack was drawn in
        // both passes — which is why the badge kept appearing at the top AND the bottom. The corner
        // is comfortably inside the safe area anyway.
    }

    /// Three taps inside a rolling 3s window. The window restarts on every tap rather than running
    /// from the first, so a hesitant operator is never punished for pausing.
    private func cornerTapped() {
        cornerResetTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { cornerTaps += 1 }
        if cornerTaps >= 3 {
            cornerTaps = 0
            showPIN = true
            return
        }
        cornerResetTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation { cornerTaps = 0 }
        }
    }

    // MARK: Logic

    /// Plain-language reason the button is refusing, or nil when it will run.
    private var blocker: String? {
        if !recorder.isRunning       { return "Camera isn't ready" }
        if !link.connected           { return "No connection to the rail" }
        if link.state.hasFault       { return "The rail has a fault — fetch a technician" }
        if !link.state.isHomed       { return "The rail needs homing — fetch a technician" }
        if !safety.armed             { return "The rail isn't armed — fetch a technician" }
        return nil
    }

    private func start() {
        Task {
            await runner.run(countdownFrom: countdown,
                             program: program,
                             traverse: seconds,
                             leadIn: leadIn,
                             render: true)
        }
    }

    private func finish() {
        player?.pause()
        player = nil
        runner.reset()
    }
}
