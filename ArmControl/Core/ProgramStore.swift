import Foundation

/// The presets already programmed on the Glamatic.
///
/// IMPORTANT: these trajectories live INSIDE the S7-1200. The app cannot read, edit, or author
/// them — it can only select a program number and trigger it. So a "preset" here is a label and a
/// number, not a motion profile. Editing the actual moves means the manufacturer's tooling.
///
/// That is also why speed ramping is not something this app synthesises: whatever ease-in and
/// ease-out these programs have was authored on the PLC, and it will be smoother than anything
/// reachable through the manual Position/Velocety tags (whose 70–100 mm/s window is only a 1.43:1
/// dynamic range).
///
/// Slot 0 is reserved. FACT: Program 0 is Home / stand-still, and is what the STOP button fires.
@MainActor
final class ProgramStore: ObservableObject {
    static let shared = ProgramStore()

    struct Preset: Identifiable, Equatable {
        var id: Int { number }
        var number: Int
        var label: String
        var enabled: Bool

        /// What the operator sees on the button.
        var display: String { label.isEmpty ? "Program \(number)" : label }
    }

    @Published private(set) var presets: [Preset] = []

    /// Legacy key from AuraBooth's ArmProgramNamesView, so names already typed on the booth iPad
    /// carry straight over without re-entry.
    private static func legacyNameKey(_ n: Int) -> String { "robobooth.program\(n).name" }
    private static func labelKey(_ n: Int) -> String { "armcontrol.program\(n).label" }
    private static func enabledKey(_ n: Int) -> String { "armcontrol.program\(n).enabled" }

    /// The presets this machine ACTUALLY has, discovered by running every number and watching
    /// whether the carriage moved.
    ///
    /// 🔑 **This was hardcoded to `1...8` and that was simply wrong.** The number eight came from
    /// nowhere in the machine — CanonPivotBot exposed 1–7, PivotBooth named 1–9 while its remote
    /// server capped triggers at 0–7, and its own stepper allowed 0–63. Three of Kyle's apps, three
    /// different answers, none of them derived from asking the PLC. A sweep of 0–63 found real,
    /// distinct moves well past 8 and a genuinely empty slot at 16, so the count is neither 8 nor
    /// "all 64" — it is whatever the recorded traces say, and only the machine knows.
    ///
    /// Falls back to 1–8 when nothing has been captured yet, so a fresh install still shows
    /// something rather than an empty list.
    static var defaultNumbers: [Int] {
        let recorded = TraceLibrary.shared.byProgram
            .filter { !$0.value.isEmpty && !$0.value.simulated }
            .keys
            .filter { $0 > 0 }        // 0 is Home / STOP, never a preset
            .sorted()
        return recorded.isEmpty ? Array(1...8) : recorded
    }

    private init() { reload() }

    func reload() {
        let d = UserDefaults.standard
        presets = Self.defaultNumbers.map { n in
            // Prefer this app's own label; fall back to the AuraBooth name so nothing is lost.
            let label = d.string(forKey: Self.labelKey(n))
                ?? d.string(forKey: Self.legacyNameKey(n))
                ?? ""
            // Absent key means enabled — a fresh install should show all eight, not none.
            let enabled = d.object(forKey: Self.enabledKey(n)) as? Bool ?? true
            return Preset(number: n, label: label, enabled: enabled)
        }
    }

    /// Apply labels discovered by a capture sweep, without overwriting anything an operator typed.
    ///
    /// ⚠️ Operator intent outranks a generated name. A booth attendant who named program 3
    /// "Bride entrance" must not find it relabelled "Full sweep, 14.8s" because a sweep was re-run.
    func seedLabels(_ labels: [Int: String]) {
        let d = UserDefaults.standard
        for (n, label) in labels {
            let existing = d.string(forKey: Self.labelKey(n)) ?? d.string(forKey: Self.legacyNameKey(n))
            guard existing == nil || existing?.isEmpty == true else { continue }
            d.set(label, forKey: Self.labelKey(n))
        }
        reload()
    }

    func setLabel(_ label: String, for number: Int) {
        UserDefaults.standard.set(label, forKey: Self.labelKey(number))
        reload()
    }

    func setEnabled(_ enabled: Bool, for number: Int) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey(number))
        reload()
    }

    /// Only the presets an operator should see on the console.
    var visible: [Preset] { presets.filter(\.enabled) }
}
