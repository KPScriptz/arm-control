import Combine
import Foundation
import SwiftUI
import UIKit

/// The iPad's own condition, which is a booth failure mode nobody watches until it has already
/// ruined an hour.
///
/// 🔑 **Thermal state is the one that matters, and it is invisible.** Sustained 120fps capture plus
/// an AVFoundation render per guest is close to the worst thermal load an iPad can be given, and
/// iOS's response is not an error — it silently reduces performance. At `.serious` the camera
/// starts dropping frames; at `.critical` it can stop delivering altogether. `Recorder.activeFPS`
/// still reads 120 the whole time, because 120 is what was *locked*. The clips just quietly stop
/// being 4× material.
///
/// Battery is the mundane one: the rail runs off the wire, but the iPad runs an event on a hub that
/// people forget to plug in.
@MainActor
final class DeviceHealth: ObservableObject {
    static let shared = DeviceHealth()

    @Published private(set) var thermal: ProcessInfo.ThermalState = .nominal
    @Published private(set) var batteryLevel: Float = -1        // 0…1, -1 unknown
    @Published private(set) var isCharging = false

    private var bag = Set<AnyCancellable>()

    private init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        refresh()

        NotificationCenter.default
            .publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .sink { [weak self] _ in Task { @MainActor in self?.thermalChanged() } }
            .store(in: &bag)

        for name in [UIDevice.batteryLevelDidChangeNotification,
                     UIDevice.batteryStateDidChangeNotification] {
            NotificationCenter.default
                .publisher(for: name)
                .sink { [weak self] _ in Task { @MainActor in self?.refresh() } }
                .store(in: &bag)
        }
    }

    private func refresh() {
        thermal = ProcessInfo.processInfo.thermalState
        batteryLevel = UIDevice.current.batteryLevel
        let state = UIDevice.current.batteryState
        isCharging = state == .charging || state == .full
    }

    /// Logged rather than merely displayed: "it got hot around nine" is exactly the sort of thing
    /// nobody notices live and everybody wants to know afterwards.
    private func thermalChanged() {
        let before = thermal
        refresh()
        guard thermal != before else { return }
        GlamaticLink.plog("thermal state → \(Self.name(thermal))")
        IncidentLog.shared.record(.system,
                                  "iPad thermal state: \(Self.name(thermal))",
                                  bad: thermal == .serious || thermal == .critical)
    }

    // MARK: Reading

    static func name(_ s: ProcessInfo.ThermalState) -> String {
        switch s {
        case .nominal:  return "Normal"
        case .fair:     return "Warm"
        case .serious:  return "Hot"
        case .critical: return "Overheating"
        @unknown default: return "Unknown"
        }
    }

    /// What a hot iPad actually costs this app, in the terms the app cares about.
    var thermalConsequence: String? {
        switch thermal {
        case .nominal, .fair:
            return nil
        case .serious:
            return "iOS is throttling to cool down. The camera can start dropping frames, and a clip that drops frames is no longer clean 4× material even though the frame rate still reads 120."
        case .critical:
            return "Capture may stop entirely. Get the iPad out of the sun, take the case off, and leave a minute between takes."
        @unknown default:
            return nil
        }
    }

    var batteryPercent: Int? {
        batteryLevel < 0 ? nil : Int((batteryLevel * 100).rounded())
    }

    /// The iPad has to be on power for a whole event; a booth that dies at 80% through is worse
    /// than one that never started.
    var batteryConcern: String? {
        guard let pct = batteryPercent else { return nil }
        if !isCharging && pct <= 20 {
            return "\(pct)% and not charging. Plug into the powered hub before the next guest."
        }
        if !isCharging && pct <= 50 {
            return "\(pct)% and not charging — an event will outlast this."
        }
        if !isCharging {
            return "Not charging. The wire to the rail does not power the iPad."
        }
        return nil
    }

    /// True when something is wrong enough to put a pill in the status strip.
    var needsAttention: Bool {
        thermal == .serious || thermal == .critical
            || (!isCharging && (batteryPercent ?? 100) <= 20)
    }
}
