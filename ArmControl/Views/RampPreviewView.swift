import AVKit
import SwiftUI

/// The ramp profile, as a diagram and then as a clip you can actually watch.
///
/// Both halves matter and they answer different questions. The diagram says *which moments of the
/// move appear, and how far they are stretched* — it updates the instant a slider moves, so it is
/// the thing to tune against. The render says *what that looks like*, which no amount of reading
/// numbers will tell you, and costs ten seconds to find out.
struct RampPreviewView: View {
    @StateObject private var booth = BoothSettings.shared
    @StateObject private var preview = RampPreview.shared
    @StateObject private var timer = MoveTimer.shared
    @Environment(\.dismiss) private var dismiss

    private var takeLength: Double { Preflight.takeSeconds + Preflight.takeLeadIn }

    /// The profile as it will actually run: fitted to tonight's take, with the dead head applied.
    private var fitted: RampProfile { booth.profile.fitted(to: takeLength) }

    /// Where the carriage reverses, in clip time — but only for a program that has been measured
    /// **and** came back to where it started. Everything else gets no marker.
    private var turnaround: Double? {
        guard let m = timer.results[Preflight.takeProgram], m.returnedToStart else { return nil }
        return Preflight.takeLeadIn + m.latency + m.duration / 2
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Card {
                        RampTimeline(profile: fitted,
                                     sourceLength: takeLength,
                                     hasEndCard: booth.endCard != nil,
                                     deadHead: booth.deadHeadSeconds,
                                     turnaround: turnaround)
                        Divider().padding(.vertical, 4)
                        Text(explanation)
                            .font(.footnote)
                            .foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    stage

                    Text("The stand-in is a test pattern at a quarter of the capture resolution, so the ramp is real and the picture is not. One tick scrolls past per source frame: at clean 4× slow you can count them individually, and where they double up is where the frame budget ran out.")
                        .font(.caption)
                        .foregroundStyle(Theme.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
            }
            .background(Theme.grouped)
            .navigationTitle("Preview the ramp")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            // Order matters: the player has the file open, and `discard` deletes it.
            .onDisappear {
                LoopingPlayers.shared.releaseAll()
                preview.discard()
            }
        }
    }

    private var explanation: String {
        let p = fitted
        let slowest = p.passes.map(\.slowFactor).max() ?? 1
        var text = String(format: "A %.1fs recording becomes a %.1fs clip. ",
                          takeLength, p.deliveredDuration(hasEndCard: booth.endCard != nil))
        text += p.passes.count == 1
            ? String(format: "One pass, at %.1f× slow.", slowest)
            : String(format: "%d passes, the slowest at %.1f×.", p.passes.count, slowest)
        if !p.overBudgetPasses.isEmpty {
            text += " \(p.overBudgetPasses.count == 1 ? "One pass asks" : "Some passes ask")"
                + " for more slow motion than \(Int(p.sourceFPS))fps can pay for, so frames repeat."
        }
        return text
    }

    // MARK: The clip

    @ViewBuilder
    private var stage: some View {
        switch preview.state {
        case .idle:
            Card {
                VStack(spacing: 14) {
                    Image(systemName: "play.rectangle.on.rectangle")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(Theme.accent)
                    Text("Render it and watch")
                        .font(.headline)
                    Text("Builds a stand-in traverse of exactly tonight's length and runs it through this profile. No rail, no camera, about ten seconds.")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondary)
                        .multilineTextAlignment(.center)
                    Button { rebuild() } label: {
                        Label("Render the preview", systemImage: "wand.and.stars")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .foregroundStyle(.black)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

        case .working(let note):
            Card {
                VStack(spacing: 14) {
                    ProgressView()
                    Text(note)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(Theme.secondary)
                        .multilineTextAlignment(.center)
                    Button("Stop") { preview.cancel() }
                        .foregroundStyle(Theme.bad)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }

        case .ready(let url):
            VStack(alignment: .leading, spacing: 12) {
                // ⚠️ Aspect ratio ALONE is not enough here. The clip is portrait, so on an iPad
                // sheet `.aspectRatio(.fit)` takes the full sheet width and returns a height
                // taller than the sheet — the player runs off the bottom and the controls under
                // it are unreachable. Cap the height and let the width follow.
                VideoPlayer(player: looping(url))
                    .aspectRatio(RampPreviewView.previewAspect, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 320)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                if preview.isStale {
                    Label("Settings have changed since this was rendered.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(Theme.warn)
                }
                Button { rebuild() } label: {
                    Label("Render again", systemImage: "arrow.clockwise")
                }
                .font(.subheadline.weight(.medium))
            }

        case .failed(let message):
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Label("The preview did not render", systemImage: "xmark.octagon.fill")
                        .font(.headline)
                        .foregroundStyle(Theme.bad)
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("A profile whose passes reach past the end of the take is the usual cause — shorten a pass, or raise Traverse.")
                        .font(.caption)
                        .foregroundStyle(Theme.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button { rebuild() } label: {
                        Label("Try again", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
    }

    /// Let go of the current player before asking for another render — `RampPreview.build` deletes
    /// the previous output, and a player still pointing at a deleted file is a black rectangle that
    /// never recovers.
    private func rebuild() {
        LoopingPlayers.shared.releaseAll()
        preview.build()
    }

    /// Portrait, matching the stand-in clip. Fixed rather than read from the file: `VideoPlayer`
    /// with no aspect ratio pillarboxes inside its own frame, and a `clipShape` then rounds the
    /// corners of the black box instead of the video.
    private static let previewAspect: CGFloat = 404.0 / 720.0

    /// A player that loops, because judging a two-second ramp from a single playthrough means
    /// tapping replay twenty times.
    ///
    /// ⚠️ Built once per URL and held, not rebuilt on every body evaluation — a fresh `AVPlayer`
    /// each pass restarts playback from zero and leaks the observer.
    private func looping(_ url: URL) -> AVPlayer {
        LoopingPlayers.shared.player(for: url)
    }
}

/// Keeps one looping `AVPlayer` per URL alive for the sheet's lifetime.
@MainActor
final class LoopingPlayers {
    static let shared = LoopingPlayers()
    private var players: [URL: AVPlayer] = [:]
    private var observers: [URL: NSObjectProtocol] = [:]

    func player(for url: URL) -> AVPlayer {
        if let existing = players[url] { return existing }
        let p = AVPlayer(url: url)
        p.isMuted = true
        players[url] = p
        observers[url] = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: p.currentItem,
            queue: .main) { _ in
                Task { @MainActor in
                    p.seek(to: .zero)
                    p.play()
                }
            }
        p.play()
        return p
    }

    /// Called when the sheet goes away. Without this, every render of the evening leaves a paused
    /// player and a notification observer behind.
    func releaseAll() {
        for (url, token) in observers {
            NotificationCenter.default.removeObserver(token)
            players[url]?.pause()
        }
        observers.removeAll()
        players.removeAll()
    }
}
