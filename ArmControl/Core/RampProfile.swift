import Foundation

/// A post-production recipe: how a raw constant-speed rail pass becomes the delivered clip.
///
/// 🔑 WHY THIS FILE EXISTS. The Glamatic's DRIVEN speed range is 70–143 mm/s — a 2.04:1 range,
/// still too narrow to ramp anything cinematically. It does not need to. The rail travels at ONE
/// constant speed and every bit of the ramp is applied here, in post.
///
/// ⚠️ **CORRECTED 2026-09-10.** This said "70–100 mm/s, a 1.43:1 range" for months, taken from the
/// manufacturer's documentation and never tested. Measured on the rail, commanding 150 mm/s moved
/// the same 291 mm in 1.30 s against 2.37 s at 100 — the controller honours speeds well above the
/// documented figure. The ceiling is now 143, the speed the factory's own stored program 14 runs
/// at. **The conclusion of this file is unchanged** — even 2.04:1 is nowhere near a cinematic
/// range, so the ramp still has to be built in post — but the premise it was argued from was
/// wrong, and a wrong premise that happens to reach the right conclusion is still worth fixing.
///
/// 🔑 AND WHY WE SHOOT 120fps. Slowing 120fps footage onto a 30fps timeline gives **4× slow motion
/// with a distinct real frame for every output frame** — no duplication, no blending, no judder.
/// That 4× is what actually widens the range:
///
///     hardware alone      70 → 143 mm/s            2.04 : 1
///     + 4× slow (120fps)  17.5 → 143 mm/s apparent 8.17 : 1
///     + a 2× whip in post 17.5 → 286 mm/s apparent 16.3 : 1
///
/// So the cinematic range is bought in post, and 4× is the hard edge of the clean budget. Ask for
/// more than 4× at 120fps and frames start repeating — shoot 240fps instead, or shorten the pass.
///
/// Measured off the Whalefall premiere reference (1080x1920, 29.97fps, 10.41s):
///   0.0–3.0s   slow pass A      rail travelling out
///   3.0–3.4s   white flash      transition
///   3.4–7.0s   slow pass B      rail travelling back
///   7.0–10.4s  branded end card static
struct RampProfile: Codable, Equatable, Identifiable {
    var id: String { name }
    var name: String

    /// Frame rate the raw pass was shot at. The whole point of the capture setting.
    var sourceFPS: Double = 120

    /// Frame rate of the delivered clip.
    var outputFPS: Double = 30

    /// The take length these timings were authored against.
    ///
    /// 🔑 Every pass below is written in absolute seconds, which quietly assumes the take is this
    /// long. It usually is not: a full 600 mm out-and-back at 85 mm/s is about **14 seconds**, more
    /// than twice the 6s default Traverse, so a profile authored for 6s would sample the first
    /// fifth of the move and call it the whole thing. `fitted(to:)` rescales to whatever was
    /// actually recorded, so changing Traverse can never silently mis-sample the move again.
    var designedSourceDuration: Double = 6.3

    /// Source-time slices to use, in order. Each is retimed to `outputDuration`.
    var passes: [Pass]

    /// White flash inserted between passes. Zero disables it.
    var flashDuration: Double

    /// How long the branded end card holds. Zero disables it.
    var endCardDuration: Double

    /// Fade the end card in over this long. Clamped to endCardDuration.
    var endCardFade: Double

    struct Pass: Codable, Equatable {
        /// Where this pass starts in the SOURCE recording, in real seconds.
        var sourceStart: Double
        /// How much SOURCE footage it consumes, in real seconds.
        var sourceDuration: Double
        /// How long it should run in the OUTPUT. Longer than sourceDuration = slow motion.
        var outputDuration: Double

        /// Playback rate. Below 1 is slow motion; 0.25 is 4× slow.
        var rate: Double { outputDuration > 0 ? sourceDuration / outputDuration : 1 }

        /// How slow this reads on screen. 4.0 means 4× slow motion.
        var slowFactor: Double { rate > 0 ? 1 / rate : 1 }
    }

    // MARK: Frame budget

    /// The slowest a pass can go before output frames start repeating.
    /// 120fps onto a 30fps timeline = 4×.
    var maxCleanSlowFactor: Double { sourceFPS / outputFPS }

    /// True when every output frame of this pass comes from its own source frame.
    func isCleanSlowMotion(_ pass: Pass) -> Bool {
        pass.slowFactor <= maxCleanSlowFactor + 0.001
    }

    /// How many source frames a pass consumes vs how many output frames it must fill.
    func frameBudget(_ pass: Pass) -> (available: Int, needed: Int) {
        (Int((pass.sourceDuration * sourceFPS).rounded()),
         Int((pass.outputDuration * outputFPS).rounded()))
    }

    /// Passes asking for more slow motion than the frame rate can pay for.
    var overBudgetPasses: [Int] {
        passes.enumerated().compactMap { isCleanSlowMotion($1) ? nil : $0 }
    }

    // MARK: Timing

    /// Flashes actually rendered: one BETWEEN each consecutive pair.
    ///
    /// 🐞 This used to be `passes.count > 1 ? flashDuration : 0` — a single flash however many
    /// passes there were. Invisible while every profile had exactly two passes, and wrong the
    /// moment one has three: `RampRenderer` appends a flash after every pass but the last, so a
    /// 3-pass clip ran a flash longer than every screen quoting these numbers claimed.
    var totalFlashDuration: Double {
        Double(max(0, passes.count - 1)) * flashDuration
    }

    var outputDuration: Double {
        passes.reduce(0) { $0 + $1.outputDuration } + totalFlashDuration + endCardDuration
    }

    /// What the clip will actually run to.
    ///
    /// 🐞 `outputDuration` counts `endCardDuration` unconditionally, but `RampRenderer` only
    /// appends a card **if an image is loaded**. So on a booth with no end card chosen — the
    /// default — every screen quoting `outputDuration` overstated the clip by the card's hold:
    /// "7.0s" against a 3.6s delivery. The number then propagated into the one piece of arithmetic
    /// that makes the fit trade legible ("a 7.0s clip at 4× covers 28s of movement"), where being
    /// nearly twice the truth is worse than useless. Ask with the card in hand.
    func deliveredDuration(hasEndCard: Bool) -> Double {
        passes.reduce(0) { $0 + $1.outputDuration } + totalFlashDuration
            + (hasEndCard ? endCardDuration : 0)
    }

    /// How much source footage the profile needs, at its authored scale.
    var requiredSourceDuration: Double {
        passes.map { $0.sourceStart + $0.sourceDuration }.max() ?? 0
    }

    // MARK: Fitting

    /// How to reconcile a profile with a take that is a different length from the one it was
    /// written for.
    ///
    /// 🔑 **There is no correct answer — it is a trade, and it should not be made silently.**
    /// The arithmetic is unforgiving: a clip of a fixed length can only show
    /// `output × slowFactor` seconds of source. Ask for the whole of a 15s move inside a 7s clip
    /// and the most slow motion available is 15/7 ≈ 2×, whatever the profile says. So either the
    /// move gets covered or the slow motion survives; both is not on offer.
    enum Fit: String, Codable, CaseIterable, Identifiable {
        /// Sample the equivalent MOMENTS of the move. The clip covers the whole traverse and the
        /// slow motion divides by however much longer the move turned out to be.
        case coverTheMove
        /// Sample the same amount of FOOTAGE, just further into a longer move. The authored slow
        /// motion survives intact and the clip shows a slice of the traverse rather than all of it.
        case keepTheSlowMotion

        var id: String { rawValue }

        var title: String {
            switch self {
            case .coverTheMove:      return "Cover the whole move"
            case .keepTheSlowMotion: return "Keep the slow motion"
            }
        }

        var blurb: String {
            switch self {
            case .coverTheMove:
                return "The clip spans the entire traverse. On a move longer than the profile was written for, the slow motion thins out in proportion."
            case .keepTheSlowMotion:
                return "Passes keep the slow-motion factor they were authored at and show a slice of a longer move instead of all of it. The look survives; the full travel does not appear."
            }
        }
    }

    /// Optional purely so a Custom profile saved before this existed still decodes — a synthesized
    /// `Decodable` throws on a missing key even when the property has a default, and silently
    /// discarding someone's tuned profile would be a poor price for one enum.
    var fitMode: Fit?

    var fit: Fit { fitMode ?? .coverTheMove }

    /// Seconds at the head of the raw clip in which the carriage has not started moving yet: the
    /// lead-in, plus the program's own trigger latency.
    ///
    /// 🔑 **Every pass timing in every profile is measured from the START OF THE MOVE**, not from
    /// the start of the file — that is what "out-leg roughly 0–3s" in the presets means. Without
    /// this, pass 1 of `whalefall` samples the clip's first 0.75s, which with a 0.3s lead-in and a
    /// 0.4s trigger latency is 93% **motionless rail, played at 4× slow for three seconds.**
    /// Nothing errors; the clip just opens on a still frame and the whole ramp lands late.
    ///
    /// Optional for the same decoding reason as `fitMode`, and injected by `BoothSettings` from the
    /// lead-in and the measured latency rather than stored per profile.
    var sourceOffset: Double?

    /// The same shape, stretched or squeezed onto a take of a different length.
    ///
    /// Output durations are deliberately NOT scaled under either mode — the delivered clip stays
    /// the length you designed. What changes is which part of the move it samples, and how slowly.
    func fitted(to actualSource: Double) -> RampProfile {
        // Only the moving part of the clip is worth sampling, so scale against that and shift every
        // pass past the dead head.
        let offset = max(0, min(sourceOffset ?? 0, max(0, actualSource - 0.1)))
        let usable = actualSource - offset
        guard usable > 0.1, designedSourceDuration > 0.1 else { return self }
        let k = usable / designedSourceDuration
        guard offset > 0.001 || abs(k - 1) > 0.01 else { return self }

        var copy = self
        copy.passes = passes.map {
            var p = $0
            switch fit {
            case .coverTheMove:
                p.sourceStart = offset + $0.sourceStart * k
                p.sourceDuration = $0.sourceDuration * k
            case .keepTheSlowMotion:
                // The pass lands at the same point in the move proportionally, but takes the
                // footage it was authored to take. Clamped so a late pass on a shortened take
                // cannot run off the end of the clip.
                p.sourceDuration = min($0.sourceDuration, usable)
                p.sourceStart = offset + max(0, min($0.sourceStart * k, usable - p.sourceDuration))
            }
            return p
        }
        // The result is already fitted: re-fitting it to the same take must be a no-op, so record
        // the full length and drop the offset rather than applying it twice.
        copy.designedSourceDuration = actualSource
        copy.sourceOffset = nil
        return copy
    }

    /// Apparent rail speed on screen, given the speed the rail was actually driven at.
    func apparentSpeed(railMMs: Double, pass: Pass) -> Double { railMMs * pass.rate }

    // MARK: Presets
    //
    // All assume a ~6s out-and-back traverse shot at 120fps: out-leg roughly 0–3s, turnaround near
    // 3s, back-leg 3–6s. Sampling starts a beat after each leg begins so the PLC's own accel ramp
    // is not in the shot.

    /// Matches the Whalefall reference. Both passes sit exactly on the 4× clean budget.
    static let whalefall = RampProfile(
        name: "Flash split — out & back",
        passes: [
            Pass(sourceStart: 0.40, sourceDuration: 0.75, outputDuration: 3.0),
            Pass(sourceStart: 3.40, sourceDuration: 0.90, outputDuration: 3.6),
        ],
        flashDuration: 0.4,
        endCardDuration: 3.4,
        endCardFade: 0.25
    )

    /// One continuous 4× pass, no flash. The plainest booth look.
    static let singleSlow = RampProfile(
        name: "Single slow pass",
        passes: [Pass(sourceStart: 0.40, sourceDuration: 1.75, outputDuration: 7.0)],
        flashDuration: 0,
        endCardDuration: 3.4,
        endCardFade: 0.25
    )

    /// The GlamBot ramp: 4× slow in, a 2× whip through the middle, 4× slow out.
    /// This is the shape the 120fps budget makes possible — an 8:1 swing inside one shot.
    static let easeWhipEase = RampProfile(
        name: "Slow · whip · slow",
        passes: [
            Pass(sourceStart: 0.40, sourceDuration: 0.55, outputDuration: 2.2),
            Pass(sourceStart: 0.95, sourceDuration: 1.80, outputDuration: 0.9),
            Pass(sourceStart: 2.75, sourceDuration: 0.55, outputDuration: 2.2),
        ],
        flashDuration: 0,
        endCardDuration: 3.4,
        endCardFade: 0.25
    )

    /// **Measured frame-by-frame off the Whalefall premiere reference**
    /// (`video_1780975227.mp4`, 1080×1920, 29.97fps, 312 frames, 10.41s) rather than estimated.
    ///
    /// The structure that measurement found, and the reason this is not the older two-pass
    /// `whalefall` preset:
    /// ```
    ///   frames  seconds
    ///     90     3.000   pass A — long slow drift
    ///      3     0.100   white flash          ┐
    ///      8     0.267   short beat           │ a triple-flash staccato,
    ///      3     0.100   white flash          │ flashes exactly 11 frames apart
    ///      8     0.267   short beat           │
    ///      3     0.100   white flash          ┘
    ///    105     3.500   pass D — long slow drift
    ///     90     3.000   end card, hard cut, no fade
    /// ```
    /// 🔑 **The three flashes fall out of the pass count for free.** `flashDuration` is inserted
    /// *between* passes, so four passes produce exactly three flashes — which is why this is
    /// authored as four passes rather than two with something bolted on.
    ///
    /// 🔑 **Every pass is exactly 4.0× slow**, i.e. precisely on the 120→30fps clean budget, with
    /// one real source frame per output frame and no duplication. That is not a coincidence in the
    /// reference; it is what the whole 120fps decision buys.
    ///
    /// Authored against a **14.1s** move — the round trip `MoveTimer` measured for Program 1
    /// (587 mm) — with the passes placed to sample the early out-leg, either side of the
    /// turnaround, and the early back-leg. `fitted(to:)` rescales all of it to whatever the take
    /// actually turns out to be.
    static let whalefallPremiere = RampProfile(
        name: "Whalefall",
        designedSourceDuration: 14.1,
        passes: [
            Pass(sourceStart: 0.60, sourceDuration: 0.750, outputDuration: 3.000),  // out-leg
            Pass(sourceStart: 6.80, sourceDuration: 0.067, outputDuration: 0.267),  // into the turn
            Pass(sourceStart: 7.05, sourceDuration: 0.067, outputDuration: 0.267),  // at the turn
            Pass(sourceStart: 7.60, sourceDuration: 0.875, outputDuration: 3.500),  // back-leg
        ],
        flashDuration: 0.10,
        endCardDuration: 3.00,
        // The reference cuts to the card on one frame — measured brightness goes 63.9 → 0 → 8.0
        // with nothing in between. A fade here would be a flourish the original does not have.
        endCardFade: 0
    )

    static let builtIn: [RampProfile] = [.whalefallPremiere, .whalefall, .singleSlow, .easeWhipEase]
}

extension RampProfile {
    /// Build a profile **from a recorded movement**, so every pass lands on a leg by construction.
    ///
    /// 🔑 **Why this beats scaling an authored profile.** The presets are written in absolute
    /// seconds against an assumed move, and `fitted(to:)` rescales them onto whatever was actually
    /// recorded. That keeps them roughly in the right place but it is blind — it does not know
    /// where the carriage reverses. Two failures follow, and both were measured, not guessed:
    ///
    ///   - **Over budget.** On Program 1 a 4.0× profile fitted out at **5.1×**, past the clean
    ///     ceiling at 120fps, so output frames repeat.
    ///   - **Straddling a reversal.** Programs 4, 5 and 6 turn around *twice*. A pass sized for a
    ///     two-leg move covers the carriage going out AND coming back, which on screen is a shot
    ///     that changes direction halfway through.
    ///
    /// This works the other way round: take the legs the machine actually produced, and size each
    /// pass to fit inside one of them.
    ///
    /// Placement:
    /// - **one pass per leg**, so a pass never spans a reversal; the white flash between them lands
    ///   on the turnaround, which is what it is for
    /// - each pass is **centred in its leg**, keeping the PLC's own acceleration shoulders out of
    ///   shot
    /// - every pass runs at exactly `maxCleanSlowFactor`, so the result can never repeat frames
    ///
    /// ⚠️ **`targetClip` is a real constraint, not a hint.** Holding 4.0× across the whole of a
    /// long move is arithmetically a long clip — Program 4's full travel comes to **30 seconds**,
    /// which is not a booth clip. Since the slow factor is fixed at the clean ceiling, the only
    /// thing left to give is coverage: each pass samples the middle of its leg and the ends of the
    /// travel do not appear. That is `Fit.keepTheSlowMotion`, made explicit, and the returned
    /// profile says so.
    ///
    /// ⚠️ Timings are relative to the **start of the move**, matching every other preset — the dead
    /// head is applied separately by `BoothSettings.sourceOffset`. Authoring in absolute take-time
    /// here would shift everything twice.
    static func authored(from trace: MotionTrace,
                         named name: String,
                         targetClip: Double = 7.0) -> RampProfile? {
        guard !trace.isEmpty, trace.moveDuration > 0.3 else { return nil }

        let moveStart = trace.latency
        let moveEnd = moveStart + trace.moveDuration

        // Cut the move at every reversal. Four legs is the ceiling: past that the passes are too
        // short to read as shots and the clip is all flash.
        var edges = [moveStart]
        edges += trace.turnarounds.filter { $0 > moveStart + 0.2 && $0 < moveEnd - 0.2 }
        edges.append(moveEnd)
        var legs = zip(edges, edges.dropFirst())
            .map { (start: $0, end: $1) }
            .filter { $0.end - $0.start > 0.3 }
        if legs.isEmpty { legs = [(moveStart, moveEnd)] }
        if legs.count > 4 {
            legs = legs.sorted { ($0.end - $0.start) > ($1.end - $1.start) }
                .prefix(4).sorted { $0.start < $1.start }
                .map { $0 }
        }

        let clean = 120.0 / 30.0
        let flash = legs.count > 1 ? 0.4 : 0.0
        // Whatever the flashes do not take, split between the passes in proportion to how much
        // travel each leg carries — a long sweep earns more screen time than a short correction.
        let forPasses = max(1.0, targetClip - Double(legs.count - 1) * flash)
        let totalLeg = legs.reduce(0.0) { $0 + ($1.end - $1.start) }

        var passes: [Pass] = []
        for leg in legs {
            let available = leg.end - leg.start
            let share = forPasses * (available / max(0.001, totalLeg))
            // Never ask for more footage than the leg actually holds, and keep clear of the
            // acceleration shoulders at each end of it.
            let source = min(available * 0.85, max(0.1, share / clean))
            let inset = (available - source) / 2
            passes.append(Pass(sourceStart: leg.start - moveStart + inset,
                               sourceDuration: source,
                               outputDuration: source * clean))
        }

        return RampProfile(
            name: name,
            designedSourceDuration: trace.moveDuration,
            passes: passes,
            flashDuration: flash,
            endCardDuration: 3.0,
            endCardFade: 0,
            fitMode: .keepTheSlowMotion
        )
    }
}
