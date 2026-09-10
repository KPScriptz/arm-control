import Foundation
import Network

/// Finds out whether iOS is letting this app touch the arm network at all — and can re-ask.
///
/// 🔑 **Why guessing was not good enough.** `GlamaticLink` used to fold this into one string:
/// "nothing answering — wrong address, or Local Network permission is off". Those are completely
/// different problems with completely different fixes (re-seat a cable vs. flip a switch in
/// Settings), and an operator standing at the rail cannot tell which one they have.
///
/// ⚠️ **iOS asks ONCE, and a denial is permanent.** There is no way to re-present the system
/// prompt: once "Don't Allow" has been tapped, every local connection fails silently — no error,
/// no dialog, just timeouts that look exactly like an unplugged cable. The only routes back are
/// the Settings toggle (see `settingsURL`) or deleting the app, and until this file existed the
/// app never told anyone that.
///
/// 🔑 **How the detection works.** Apple publishes no API for reading this status, so this uses
/// the one documented side effect: a Bonjour browse fails with the DNS policy-denied error
/// (-65570) when local network access is refused, becomes `.ready` when it is granted, and hangs
/// on the system prompt while the user is still deciding. Browsing also *triggers* the prompt when
/// nothing has been decided yet, which makes this both the check and the ask.
///
/// ⚠️ The browse type must be listed in `NSBonjourServices` in Info.plist or the browse fails for
/// an unrelated reason and this reports a denial that is not real.
enum LocalNetworkPermission {

    enum Status: String {
        /// Traffic is allowed. Anything still failing is the network or the PLC.
        case granted
        /// Refused. Nothing this app does can reach the rail until Settings is changed.
        case denied
        /// Never asked, or the prompt is on screen right now.
        case undetermined

        var isBlocking: Bool { self == .denied }
    }

    /// The browse type. Must match the `NSBonjourServices` entry exactly.
    static let serviceType = "_armcontrol._tcp"

    /// kDNSServiceErr_PolicyDenied — the error the browser reports when the user said no.
    private static let policyDenied: Int32 = -65570

    /// Check, and put the system prompt on screen if it has never been answered.
    ///
    /// Returns `.undetermined` if nothing resolves within `timeout`, which is the honest answer
    /// while the prompt is sitting there waiting for a human.
    static func check(timeout: Double = 4) async -> Status {
        await withCheckedContinuation { (cont: CheckedContinuation<Status, Never>) in
            let params = NWParameters()
            params.includePeerToPeer = true
            let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: params)

            var settled = false
            let lock = NSLock()
            func finish(_ s: Status) {
                lock.lock(); defer { lock.unlock() }
                guard !settled else { return }
                settled = true
                browser.cancel()
                cont.resume(returning: s)
            }

            browser.stateUpdateHandler = { state in
                switch state {
                // A browse that got as far as running means the traffic was permitted. There is
                // nothing to find on the arm LAN — the rail publishes no Bonjour service — and
                // that does not matter: reaching `.ready` is the whole signal.
                case .ready:
                    finish(.granted)
                case .waiting(let error), .failed(let error):
                    if case .dns(let code) = error, code == policyDenied { finish(.denied) }
                    // Any other error is a browse problem, not a permission verdict. Saying
                    // "denied" here would send someone to Settings to fix something that is not
                    // broken, so it stays undetermined.
                    else { finish(.undetermined) }
                default:
                    break
                }
            }
            browser.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(.undetermined) }
        }
    }

    /// Deep link to **this app's own page** in Settings, where the Local Network switch lives.
    /// One tap from the failure to the fix, which matters when the alternative is talking someone
    /// through Settings → Privacy & Security → Local Network → a long alphabetical list.
    static var settingsURL: URL? { URL(string: "app-settings:") }
}
