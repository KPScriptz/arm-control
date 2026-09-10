import Foundation
import UIKit

/// One page describing how an event went, assembled from everything the app already recorded.
///
/// 🔑 **The question after a night is always the same and nobody has the answer.** How many guests
/// went through, did anything break, did the clips actually reach phones, was the iPad struggling.
/// Every piece of that is already on this device — in `TakeLog`, `IncidentLog`, `DeliveryServer`,
/// `MoveTimer`, `LinkSoak` — and all of it is in a different screen, so the answer in practice is
/// a guess typed into a message the next morning.
///
/// It is also the thing to send when something *did* go wrong: "the link dropped" is a complaint,
/// and this is the version with times and counts attached.
///
/// ⚠️ Deliberately plain text. It gets pasted into a message or an email far more often than it
/// gets opened as a file, and a PDF that has to be opened is a PDF that does not get read.
@MainActor
enum EventReport {

    /// Everything since midnight. An event is an evening, and a lifetime total answers nothing.
    static func text() -> String {
        var out: [String] = []

        let stamp = DateFormatter()
        stamp.dateFormat = "EEEE d MMMM yyyy"
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm"

        out.append("ARM CONTROL — EVENT REPORT")
        out.append(stamp.string(from: Date()))
        out.append("\(UIDevice.current.name) · \(version())")
        out.append("")

        // MARK: Takes
        let takes = TakeLog.shared.today
        out.append("TAKES")
        if takes.isEmpty {
            out.append("  None today.")
        } else {
            let first = takes.map(\.at).min()!
            let last = takes.map(\.at).max()!
            let span = last.timeIntervalSince(first)
            out.append("  \(takes.count) take\(takes.count == 1 ? "" : "s"), \(clock.string(from: first))–\(clock.string(from: last))")
            if span > 600 {
                let perHour = Double(takes.count) / (span / 3600)
                out.append(String(format: "  %.0f an hour over %@", perHour, duration(span)))
            }
            let flagged = takes.filter { $0.warning != nil }
            if flagged.isEmpty {
                out.append("  Nothing flagged.")
            } else {
                out.append("  \(flagged.count) flagged:")
                for t in flagged.prefix(10) {
                    out.append("    \(clock.string(from: t.at))  \(t.warning ?? "")")
                }
                if flagged.count > 10 { out.append("    …and \(flagged.count - 10) more.") }
            }
        }
        out.append("")

        // MARK: Delivery
        //
        // The count is the only proof that phones could reach the iPad. Zero after a busy night
        // means client isolation, and it is worth stating rather than leaving to be inferred.
        let delivery = DeliveryServer.shared
        out.append("DELIVERY")
        if !delivery.enabled {
            out.append("  Off — clips were not served to phones.")
        } else if delivery.reachedCount == 0 {
            out.append("  Server ran, but NO phone ever reached it.")
            out.append("  That is the signature of client isolation on the venue Wi-Fi:")
            out.append("  the QR is correct and the request never arrives.")
        } else {
            out.append("  \(delivery.reachedCount) request\(delivery.reachedCount == 1 ? "" : "s") arrived from phones.")
            if let at = delivery.lastReachedAt {
                out.append("  Last at \(clock.string(from: at)).")
            }
            if !takes.isEmpty {
                // Two requests per opened clip is normal — the page, then the video.
                out.append(String(format: "  About %.1f per take.",
                                  Double(delivery.reachedCount) / Double(takes.count)))
            }
        }
        // Counts only — never who was texted. See the note in `TextDelivery`.
        let text = TextDelivery.shared
        if text.enabled {
            out.append(text.isConfigured
                       ? "  \(text.sentCount) link\(text.sentCount == 1 ? "" : "s") texted to guests since launch."
                       : "  Texting was ON but had no account, so the button never appeared.")
        }
        out.append("")

        // MARK: What went wrong
        let start = Calendar.current.startOfDay(for: Date())
        let bad = IncidentLog.shared.entries.filter { $0.bad && $0.at >= start }
        out.append("PROBLEMS")
        if bad.isEmpty {
            out.append("  None logged.")
        } else {
            let total = bad.reduce(0) { $0 + $1.occurrences }
            out.append("  \(total) event\(total == 1 ? "" : "s") across \(bad.count) kind\(bad.count == 1 ? "" : "s"):")
            for e in bad.prefix(20) {
                out.append("    \(clock.string(from: e.at))  [\(e.kind.rawValue)] \(e.display)")
            }
            if bad.count > 20 { out.append("    …and \(bad.count - 20) more — see the incident log.") }
        }
        out.append("")

        // MARK: The iPad
        let health = DeviceHealth.shared
        out.append("THE IPAD")
        let thermalEvents = IncidentLog.shared.entries.filter {
            $0.at >= start && $0.text.hasPrefix("iPad thermal state:")
        }
        if thermalEvents.isEmpty {
            out.append("  Thermal state never changed — \(DeviceHealth.name(health.thermal)) throughout.")
        } else {
            out.append("  Thermal state changed \(thermalEvents.count) time\(thermalEvents.count == 1 ? "" : "s"):")
            for e in thermalEvents.prefix(8) {
                out.append("    \(clock.string(from: e.at))  \(e.text.replacingOccurrences(of: "iPad thermal state: ", with: ""))")
            }
        }
        if let pct = health.batteryPercent {
            out.append("  Battery now \(pct)%\(health.isCharging ? ", charging" : ", NOT charging")")
        }
        out.append("  Storage free: \(Storage.freeDescription)")
        out.append("")

        // MARK: How it was set up
        //
        // The settings matter as much as the outcome: a report saying "clips looked flat" is only
        // actionable next to the traverse and profile that produced them.
        let booth = BoothSettings.shared
        let profile = booth.profile
        let take = Preflight.takeSeconds + Preflight.takeLeadIn
        let fitted = profile.fitted(to: take)
        out.append("SET UP AS")
        out.append("  Program \(Preflight.takeProgram) · traverse \(fmt(Preflight.takeSeconds))s · lead-in \(fmt(Preflight.takeLeadIn))s")
        out.append("  Profile “\(profile.name)” · \(booth.fitMode.title.lowercased())")
        out.append(String(format: "  %@s recorded at %d fps → %@s clip at %d fps",
                          fmt(take), Int(profile.sourceFPS),
                          fmt(fitted.deliveredDuration(hasEndCard: booth.endCard != nil)),
                          Int(profile.outputFPS)))
        let factors = fitted.passes.map { String(format: "%.1f×", $0.slowFactor) }.joined(separator: ", ")
        out.append("  Passes ran at \(factors)")
        if booth.deadHeadSeconds > 0.05 {
            out.append(String(format: "  Skipped the first %.1fs, before the carriage moves", booth.deadHeadSeconds))
        }
        if booth.endCard == nil, profile.endCardDuration > 0.05 {
            out.append("  No end card loaded — clips ended on the last pass")
        }
        out.append(GlamaticLink.shared.simulated
                   ? "  RAIL WAS SIMULATED — no hardware was driven"
                   : "  Rail at \(GlamaticLink.host):\(GlamaticLink.asciiPort)")
        out.append("")

        // MARK: Measurements
        let timings = MoveTimer.shared.results.sorted { $0.key < $1.key }
        if !timings.isEmpty {
            out.append("MEASURED PROGRAMS")
            for (n, m) in timings {
                out.append("  Program \(n): \(m.summary)\(m.simulated ? "  (simulated)" : "")")
            }
            out.append("")
        }

        if let soak = LinkSoak.shared.last {
            out.append("LAST LINK SOAK")
            out.append("  \(soak.verdict)")
            out.append("")
        }

        return out.joined(separator: "\n")
    }

    // MARK: Sharing

    /// Written to a real file rather than shared as a String, so the share sheet offers Mail and
    /// Files as well as Messages — and so the name carries the date into whoever's inbox.
    static func file() throws -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArmControl event \(f.string(from: Date())).txt")
        try text().write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: Bits

    private static func fmt(_ v: Double) -> String { String(format: "%.1f", v) }

    private static func duration(_ seconds: TimeInterval) -> String {
        let m = Int(seconds / 60)
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
    }

    static func version() -> String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "Arm Control \(v) (\(b))"
    }

    /// One line for the Setup row, so the report is worth opening before it is opened.
    static var summary: String {
        let takes = TakeLog.shared.today.count
        let faults = IncidentLog.shared.faultCountToday
        if takes == 0 && faults == 0 { return "Nothing yet today" }
        var parts = ["\(takes) take\(takes == 1 ? "" : "s")"]
        if faults > 0 { parts.append("\(faults) problem\(faults == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}
