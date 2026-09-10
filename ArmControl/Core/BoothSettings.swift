import SwiftUI
import UIKit

/// What the attendant screen runs with. Set once behind the PIN, then used by every take.
///
/// This exists so the locked screen needs no configuration of its own: whatever was chosen in
/// Post and Capture before locking is exactly what the one button does.
@MainActor
final class BoothSettings: ObservableObject {
    static let shared = BoothSettings()

    private static let profileKey = "armcontrol.booth.profile"
    private static let customKey = "armcontrol.booth.customProfile"
    private static let cardName = "endcard.png"

    /// The name reserved for the one profile the operator can edit on the iPad.
    static let customName = "Custom"

    @Published var profileName: String {
        didSet { UserDefaults.standard.set(profileName, forKey: Self.profileKey) }
    }

    /// A profile the operator can tune on site, without a rebuild. Every timing in the built-in
    /// presets is a guess until it has been run against real footage from a real rail, so there
    /// has to be a way to move them at the venue.
    @Published var customProfile: RampProfile {
        didSet { persistCustom() }
    }

    @Published private(set) var endCard: UIImage?

    /// One-shot: make the next render fail on purpose.
    ///
    /// 🔑 Same reasoning as the simulated rail's injected link faults. The recovery path for a
    /// failed export — keep the footage, offer to rebuild the clip without re-posing the guest — is
    /// code that otherwise runs for the first time at an event, on the one take somebody actually
    /// cared about. This is how it gets exercised on purpose, including on real hardware.
    ///
    /// Deliberately NOT persisted: a rehearsal switch that survived a relaunch would be a trap.
    @Published var failNextRender = false

    /// How a profile is reconciled with a take that is a different length from the one it was
    /// written for. Deliberately global rather than stored per profile: it is a decision about
    /// **this booth's move**, not about a profile's authored shape — and it has to be changeable
    /// for the built-in profiles too, which are `let` constants.
    @Published var fitMode: RampProfile.Fit {
        didSet { UserDefaults.standard.set(fitMode.rawValue, forKey: Self.fitKey) }
    }

    private static let fitKey = "armcontrol.booth.fitMode"

    private init() {
        fitMode = RampProfile.Fit(rawValue: UserDefaults.standard.string(forKey: Self.fitKey) ?? "")
            ?? .coverTheMove
        profileName = UserDefaults.standard.string(forKey: Self.profileKey)
            ?? RampProfile.whalefall.name
        if let data = UserDefaults.standard.data(forKey: Self.customKey),
           let decoded = try? JSONDecoder().decode(RampProfile.self, from: data) {
            customProfile = decoded
        } else {
            var seed = RampProfile.whalefall
            seed.name = Self.customName
            customProfile = seed
        }
        endCard = Self.loadCard()
    }

    private func persistCustom() {
        guard let data = try? JSONEncoder().encode(customProfile) else { return }
        UserDefaults.standard.set(data, forKey: Self.customKey)
    }

    var profile: RampProfile {
        var p = profileName == Self.customName
            ? customProfile
            : (RampProfile.builtIn.first { $0.name == profileName } ?? .whalefall)
        p.fitMode = fitMode
        p.sourceOffset = deadHeadSeconds
        return p
    }

    /// How long the raw clip runs before the carriage moves: the lead-in the camera rolls for, plus
    /// the trigger latency measured for whichever program the booth fires.
    ///
    /// Zero until that program has been timed — guessing at it would move everyone's ramp for no
    /// reason, and the measurement is cheap to take.
    /// ⚠️⚠️ **A RECORDED TRACE OUTRANKS A TIMING MEASUREMENT, and the difference is not small.**
    /// `MoveTimer`'s figure for this rail was **0.4s — taken against the SIMULATOR.** The real
    /// machine, captured program by program, waits **3.9s to 9.4s** before the carriage moves.
    ///
    /// With the simulated number the booth computed a 0.7s dead head, so the ramp profile sampled
    /// from 0.7s onward and spent its opening pass on **more than three seconds of a motionless
    /// rail, played at 4× slow**. Nothing errors; the clip just opens on a still frame and every
    /// beat of the ramp lands late. That is precisely the failure `RampProfile.sourceOffset`
    /// exists to prevent, so it has to be fed the real number.
    /// Seconds the camera rolls before the trigger fires.
    var leadIn: Double {
        UserDefaults.standard.object(forKey: "armcontrol.take.leadIn") as? Double ?? 0.3
    }

    /// A saved custom motion the booth should shoot INSTEAD of a stored program, by id.
    ///
    /// 🔑 **Without this the Movement Studio is decorative.** You could build a move, tune it,
    /// preview it and save it — and nothing would ever shoot it, because `TakeRunner` only ever
    /// fired a stored PLC program number. The builder produced things the booth could not use,
    /// which is the same as producing nothing.
    ///
    /// ⚠️ Stored as a STRING id rather than the motion itself, so a motion edited later is picked
    /// up by the booth automatically instead of the booth holding a stale copy of it. Nil means
    /// shoot `selectedProgram`, which stays the default.
    var boothMotionID: String? {
        get { UserDefaults.standard.string(forKey: "armcontrol.take.motionID") }
        set {
            UserDefaults.standard.set(newValue, forKey: "armcontrol.take.motionID")
            objectWillChange.send()
        }
    }

    /// The motion the booth will shoot, if one is chosen and still exists.
    ///
    /// ⚠️ Resolved live, so deleting a motion the booth was set to shoot falls back to the stored
    /// program rather than leaving the booth pointed at nothing.
    @MainActor
    var boothMotion: CustomMotion? {
        guard let id = boothMotionID, let uuid = UUID(uuidString: id) else { return nil }
        return MotionStore.shared.motions.first { $0.id == uuid }
    }

    /// The program the booth is set to shoot.
    var selectedProgram: Int {
        UserDefaults.standard.object(forKey: "armcontrol.take.program") as? Int ?? 1
    }

    var deadHeadSeconds: Double { deadHeadSeconds(for: selectedProgram) }

    /// The same calculation for ANY program, so the Studio can browse a movement the booth is not
    /// currently set to shoot without silently reporting the selected one's timing instead.
    func deadHeadSeconds(for program: Int) -> Double {
        let leadIn = self.leadIn

        // Prefer what the machine actually did. Only a `.recorded` trace counts — a `.predicted`
        // one is derived from the very measurement being distrusted here.
        if let trace = TraceLibrary.shared.byProgram[program],
           trace.source == .recorded, !trace.isEmpty, !trace.simulated {
            return leadIn + trace.latency
        }
        guard let m = MoveTimer.shared.results[program] else { return 0 }
        return leadIn + m.latency
    }

    /// True when the booth is running on a figure that came from the simulator rather than the
    /// rail — worth saying out loud, because it silently mis-times every clip.
    var deadHeadIsFromSimulation: Bool { deadHeadIsFromSimulation(for: selectedProgram) }

    func deadHeadIsFromSimulation(for program: Int) -> Bool {
        if let t = TraceLibrary.shared.byProgram[program], t.source == .recorded, !t.simulated {
            return false
        }
        return MoveTimer.shared.results[program]?.simulated ?? false
    }

    var isEditingCustom: Bool { profileName == Self.customName }

    /// Copy the selected preset into Custom and switch to it, so tuning always starts from
    /// something that already works rather than from nothing.
    func duplicateSelectedToCustom() {
        var copy = profile
        copy.name = Self.customName
        customProfile = copy
        profileName = Self.customName
    }

    /// All profiles offered in the picker: the built-ins, plus the editable one.
    var selectableProfiles: [RampProfile] { RampProfile.builtIn + [customProfile] }

    // MARK: End card
    //
    // Stored as a file rather than in UserDefaults — a full-resolution portrait PNG has no business
    // in a plist, and the booth must survive a relaunch mid-event with its branding intact.

    private static var cardURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(cardName)
    }

    private static func loadCard() -> UIImage? {
        guard let data = try? Data(contentsOf: cardURL) else { return nil }
        return UIImage(data: data)
    }

    func setEndCard(_ image: UIImage?) {
        guard let image else {
            try? FileManager.default.removeItem(at: Self.cardURL)
            endCard = nil
            return
        }
        if let data = image.pngData() {
            try? data.write(to: Self.cardURL)
        }
        endCard = image
    }
}
