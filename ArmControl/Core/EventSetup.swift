import Foundation
import UIKit

/// Everything that makes this iPad *this* booth, in one saveable, switchable, shareable object.
///
/// 🔑 **Two problems, one answer.**
/// 1. **Nothing survived an iPad swap.** The whole configuration lived in UserDefaults, the Keychain
///    and a loose PNG. A second booth, or a replacement for one that died mid-event, meant retyping
///    the PLC address, the preset names, the traverse, the ramp timings and re-picking the end card
///    — at a venue, under time pressure, from memory.
/// 2. **Activations differ.** A Cricket booth and a film premiere want different programs, different
///    ramp profiles, different end cards. Switching used to mean editing six screens in order.
///
/// A named setup is both: save the booth you have, apply it later, or hand the file to another iPad.
///
/// ⚠️ **The PLC PASSWORD IS DELIBERATELY NOT IN HERE.** It lives in the Keychain and it stays there.
/// A config file gets AirDropped, emailed and left in Downloads; a machine credential travelling in
/// plaintext inside one is exactly the mistake that looks convenient right up until it isn't. The
/// username is not included either. Whoever sets up the second iPad types those two fields once.
struct EventSetup: Codable, Identifiable, Equatable {

    // MARK: Identity

    var id = UUID()
    var name: String
    var savedAt = Date()
    /// Bumped if the shape ever changes, so an old file can be recognised rather than mis-read.
    var version = 1

    // MARK: The take

    var program: Int
    var traverse: Double
    var leadIn: Double
    var captureFPS: Double

    // MARK: Guest flow

    var countdown: Int
    var holdResult: Double
    var pin: String

    // MARK: The ramp

    var profileName: String
    var customProfile: RampProfile?
    var fitMode: RampProfile.Fit
    /// PNG bytes. Big, but a setup without the branding is not the setup.
    var endCardPNG: Data?

    // MARK: The machine

    var plcHost: String
    var asciiPort: Int
    /// Preset labels and visibility, by program number.
    var presetLabels: [Int: String]
    var presetEnabled: [Int: Bool]
    /// Measured move timings. These describe the RAIL, not the event, so a second iPad pointed at
    /// the same machine should inherit them rather than re-run every program to find out.
    var moveTimings: [Int: MoveTimer.Measurement]

    // MARK: Delivery

    var deliveryEnabled: Bool
    var deliveryPort: Int

    // MARK: Description

    var summary: String {
        var bits = ["Program \(program)", String(format: "%.1fs", traverse), profileName]
        if endCardPNG != nil { bits.append("end card") }
        return bits.joined(separator: " · ")
    }
}

// MARK: - Capture and apply

@MainActor
enum EventSetups {

    private static let d = UserDefaults.standard

    // The keys the Capture, Attendant and Setup screens own via @AppStorage. Named here once so a
    // setup can never drift out of step with them silently.
    enum Key {
        static let program = "armcontrol.take.program"
        static let traverse = "armcontrol.take.seconds"
        static let leadIn = "armcontrol.take.leadIn"
        static let fps = "armcontrol.capture.fps"
        static let countdown = "armcontrol.booth.countdown"
        static let holdResult = "armcontrol.booth.holdResult"
        static let pin = "armcontrol.kiosk.pin"
    }

    /// Snapshot the booth as it stands.
    static func capture(named name: String) -> EventSetup {
        let booth = BoothSettings.shared
        let store = ProgramStore.shared

        var labels: [Int: String] = [:]
        var enabled: [Int: Bool] = [:]
        for p in store.presets {
            labels[p.number] = p.label
            enabled[p.number] = p.enabled
        }

        return EventSetup(
            name: name,
            program: d.object(forKey: Key.program) as? Int ?? 1,
            traverse: d.object(forKey: Key.traverse) as? Double ?? 6.0,
            leadIn: d.object(forKey: Key.leadIn) as? Double ?? 0.3,
            captureFPS: d.object(forKey: Key.fps) as? Double ?? 120,
            countdown: d.object(forKey: Key.countdown) as? Int ?? 3,
            holdResult: d.object(forKey: Key.holdResult) as? Double ?? 8,
            pin: Kiosk.shared.pin,
            profileName: booth.profileName,
            customProfile: booth.customProfile,
            fitMode: booth.fitMode,
            endCardPNG: booth.endCard?.pngData(),
            plcHost: GlamaticLink.host,
            asciiPort: Int(GlamaticLink.asciiPort),
            presetLabels: labels,
            presetEnabled: enabled,
            moveTimings: MoveTimer.shared.results,
            deliveryEnabled: DeliveryServer.shared.enabled,
            deliveryPort: Int(DeliveryServer.shared.port)
        )
    }

    /// Make this iPad be that booth.
    ///
    /// Writes the plain defaults first, then tells each singleton to re-read — `@AppStorage` picks
    /// changes up on its own, but an `ObservableObject` that read UserDefaults once in `init` will
    /// happily keep showing the old value forever.
    static func apply(_ s: EventSetup) {
        d.set(s.program, forKey: Key.program)
        d.set(s.traverse, forKey: Key.traverse)
        d.set(s.leadIn, forKey: Key.leadIn)
        d.set(s.captureFPS, forKey: Key.fps)
        d.set(s.countdown, forKey: Key.countdown)
        d.set(s.holdResult, forKey: Key.holdResult)
        d.set(s.plcHost, forKey: PLC.hostKey)
        d.set(s.asciiPort, forKey: PLC.asciiPortKey)

        Kiosk.shared.setPIN(s.pin)

        for (number, label) in s.presetLabels { ProgramStore.shared.setLabel(label, for: number) }
        for (number, on) in s.presetEnabled { ProgramStore.shared.setEnabled(on, for: number) }

        MoveTimer.shared.replaceAll(s.moveTimings)

        let booth = BoothSettings.shared
        if let custom = s.customProfile { booth.customProfile = custom }
        booth.fitMode = s.fitMode
        booth.profileName = s.profileName
        booth.setEndCard(s.endCardPNG.flatMap(UIImage.init(data:)))

        DeliveryServer.shared.enabled = s.deliveryEnabled
        d.set(s.deliveryPort, forKey: DeliveryServer.portKey)
        if s.deliveryEnabled { DeliveryServer.shared.start() }

        GlamaticLink.plog("applied event setup “\(s.name)”")
        IncidentLog.shared.record(.system, "Applied setup “\(s.name)”")
    }

    // MARK: Storage
    //
    // Files in Documents rather than rows in UserDefaults: a setup carries a full-resolution end
    // card, and a multi-megabyte PNG has no business in a plist that is read on every launch.

    private static var folder: URL {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Setups", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static let fileExtension = "armsetup"

    static func load() -> [EventSetup] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil) else { return [] }
        return files
            .filter { $0.pathExtension == fileExtension }
            .compactMap { try? JSONDecoder().decode(EventSetup.self, from: Data(contentsOf: $0)) }
            .sorted { $0.savedAt > $1.savedAt }
    }

    @discardableResult
    static func save(_ setup: EventSetup) -> Bool {
        guard let data = try? JSONEncoder().encode(setup) else { return false }
        let url = folder.appendingPathComponent("\(setup.id.uuidString).\(fileExtension)")
        return (try? data.write(to: url)) != nil
    }

    static func delete(_ setup: EventSetup) {
        let url = folder.appendingPathComponent("\(setup.id.uuidString).\(fileExtension)")
        try? FileManager.default.removeItem(at: url)
    }

    /// A copy in the temp directory for sharing, named after the setup so the receiving end sees
    /// "Cricket Activation.armsetup" rather than a UUID.
    static func exportFile(for setup: EventSetup) -> URL? {
        guard let data = try? JSONEncoder().encode(setup) else { return nil }
        let safe = setup.name.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safe.isEmpty ? "Booth" : safe).\(fileExtension)")
        return (try? data.write(to: url)) == nil ? nil : url
    }

    /// Import a file, giving it a fresh id so it never overwrites a setup already on this iPad.
    static func importFile(at url: URL) -> EventSetup? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              var setup = try? JSONDecoder().decode(EventSetup.self, from: data) else { return nil }
        setup.id = UUID()
        setup.savedAt = Date()
        guard save(setup) else { return nil }
        return setup
    }
}
