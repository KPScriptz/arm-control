import Foundation

/// One playhead for every track in `MovementStudioView`.
///
/// 🔑 **The whole point of the Studio is that these things share a clock.** The rail preview, the
/// position curve, the slow-motion passes and the camera window were four screens with four
/// independent time axes, and every mis-timing today came from that: a dead head measured on one,
/// a ramp authored against another, and no way to see them disagree. Binding them all to this
/// means "pass 2 lands on the return leg" is something you can look at rather than compute.
///
/// ⚠️ **Time comes from a Date anchor, never from a `Timer`.** `VirtualArm` shipped with a
/// `Timer.publish` held in a `let`, and the playhead never moved at all — a `let` initialiser runs
/// on every struct init, so each redraw built a new publisher and tore down the timer before it
/// could fire. Deriving elapsed time from a Date means playback depends on nothing but the clock,
/// and survives any number of redraws.
@MainActor
final class StudioClock: ObservableObject {
    /// Where the playhead is when PAUSED or scrubbed. While playing, the live position comes from
    /// `time(at:)` instead — see below.
    @Published private(set) var currentTime: Double = 0
    /// Length of the movement being studied.
    @Published var duration: Double = 6
    @Published private(set) var isPlaying = false
    /// Playback speed. Slower than 1 is useful for watching a turnaround.
    @Published var rate: Double = 1

    /// Which waypoint the inspector is editing, when the motion is an editable copy.
    @Published var selectedKeyframe: UUID?

    private var anchor: Date?
    private var offset: Double = 0

    /// The playhead position at `now`, as a **pure function** — it publishes nothing.
    ///
    /// 🐞 **THIS IS WHY THE STUDIO FROZE.** The view called a `tick(_:)` that assigned to
    /// `@Published currentTime` from inside `TimelineView`'s body. Mutating observable state during
    /// a view update invalidates the view that is currently being built, so SwiftUI rebuilds it,
    /// which ticks again, which invalidates again — the screen locks up and no control responds,
    /// which is exactly what was reported: "the app froze and no changes were able to be made".
    ///
    /// The fix is that reading the clock must not change it. The body now asks for the time at the
    /// frame's date and publishes nothing; only play, pause and scrub — all of them user actions,
    /// none of them during a view update — mutate anything.
    func time(at now: Date) -> Double {
        guard let anchor else { return min(currentTime, duration) }
        let raw = offset + now.timeIntervalSince(anchor) * rate
        guard duration > 0 else { return 0 }
        // Looping is arithmetic here rather than state, because a movement is watched over and over
        // while it is tuned and a preview that stops at the end means reaching for a button.
        return raw.truncatingRemainder(dividingBy: duration)
    }

    func play() {
        guard !isPlaying else { return }
        anchor = Date()
        isPlaying = true
    }

    func pause() {
        guard isPlaying else { return }
        currentTime = time(at: Date())
        offset = currentTime
        anchor = nil
        isPlaying = false
    }

    func toggle() { isPlaying ? pause() : play() }

    /// Scrubbing always pauses — dragging a playhead that is also running fights the user.
    func scrub(to t: Double) {
        pause()
        currentTime = min(max(0, t), duration)
        offset = currentTime
    }

    func reset(duration: Double) {
        pause()
        self.duration = max(0.1, duration)
        currentTime = 0
        offset = 0
    }
}
