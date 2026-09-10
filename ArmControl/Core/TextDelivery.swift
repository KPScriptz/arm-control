import Foundation
import SwiftUI

/// Texts the guest their clip link, for when the QR does not land.
///
/// 🔑 **Why this exists even though the QR works.** A scan fails for reasons nobody at the booth can
/// fix: a cracked lens, an older phone, a screen protector, sun on the display, or a guest who
/// simply walked off and came back. Today the only recovery is `TakeLog` and an attendant holding
/// the iPad up again while the queue waits. A number typed once solves it in five seconds.
///
/// ⚠️⚠️ **THE LINK IS A LAN ADDRESS AND A TEXT DOES NOT CHANGE THAT.** `DeliveryServer` serves the
/// clip off this iPad at `http://192.168.x.x:8787/…`, which resolves **only for a phone on the same
/// Wi-Fi**. That is fine for a QR — you scan it standing at the booth — but a text can be opened in
/// a taxi, and there it is a dead link that looks perfectly normal. So:
///   * the default message says to open it before leaving,
///   * the settings screen says it in amber,
///   * Pre-flight says it,
/// and the real fix, if it ever matters enough, is a cloud upload behind the existing
/// `DeliveryServer.url(for:)` seam — not anything in this file.
///
/// ⚠️ **The guest's number is never stored.** Not in `TakeLog`, not in `IncidentLog`, not in
/// UserDefaults. It exists for the duration of one request and is gone. A booth that quietly
/// accumulates a evening's worth of phone numbers is collecting personal data nobody consented to
/// and nobody is guarding.
@MainActor
final class TextDelivery: ObservableObject {
    static let shared = TextDelivery()

    static let enabledKey = "armcontrol.text.enabled"
    static let templateKey = "armcontrol.text.template"

    /// The default body. `{link}` is substituted; if it is missing the link is appended, because a
    /// message that silently dropped the link would be the worst possible edit.
    static let defaultTemplate =
        "Here's your clip: {link}\n\nOpen it before you leave — the link only works on the venue Wi-Fi."

    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.enabledKey) }
    }

    @Published var template: String {
        didSet { UserDefaults.standard.set(template, forKey: Self.templateKey) }
    }

    /// Bumped on every credential change so SwiftUI redraws the configured/not-configured state —
    /// the values themselves live in the Keychain and are deliberately not `@Published`.
    @Published private(set) var credentialsVersion = 0

    @Published private(set) var sending = false
    @Published private(set) var lastError: String?

    /// Sends since launch. Deliberately a COUNT and nothing else — no numbers, no timestamps per
    /// recipient. Enough for the event report to say the feature was used.
    @Published private(set) var sentCount = 0

    private init() {
        enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        template = UserDefaults.standard.string(forKey: Self.templateKey) ?? Self.defaultTemplate
    }

    // MARK: Account
    //
    // All three live in the Keychain, including the From number which is not itself a secret. One
    // rule — "the texting account never leaves this iPad" — is easier to keep than three, and it
    // means `EventSetup` (which reads UserDefaults) cannot pick any of it up by accident. Same
    // reasoning as the PLC password.

    private static let service = "com.pivotxp.armcontrol.twilio"

    static var accountSID: String { keychain("sid") ?? "" }
    static var authToken: String { keychain("token") ?? "" }
    static var fromNumber: String { keychain("from") ?? "" }

    var isConfigured: Bool {
        !Self.accountSID.isEmpty && !Self.authToken.isEmpty && !Self.fromNumber.isEmpty
    }

    /// True when the result screen should offer the button at all.
    var isReady: Bool { enabled && isConfigured }

    func setAccount(sid: String, token: String, from: String) {
        Self.keychainSet("sid", sid.trimmingCharacters(in: .whitespaces))
        // ⚠️ Never trimmed of anything but whitespace, never logged, never echoed back into a
        // plain TextField.
        Self.keychainSet("token", token.trimmingCharacters(in: .whitespaces))
        Self.keychainSet("from", Self.e164(from) ?? from.trimmingCharacters(in: .whitespaces))
        credentialsVersion &+= 1
    }

    func clearAccount() {
        for a in ["sid", "token", "from"] { Self.keychainDelete(a) }
        credentialsVersion &+= 1
    }

    // MARK: Sending

    enum SendError: LocalizedError {
        case notConfigured
        case badNumber
        case noLink
        case twilio(String)
        case transport(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Texting is not set up. Add the account under Delivery."
            case .badNumber:     return "That does not look like a phone number."
            case .noLink:        return "There is no link to send — the delivery server is not running."
            case .twilio(let m): return m
            case .transport(let m): return "Could not reach the texting service: \(m)"
            }
        }
    }

    /// Send one link. Returns normally on success; throws with something an attendant can act on.
    func send(link: URL, to raw: String) async throws {
        guard isConfigured else { throw SendError.notConfigured }
        guard let to = Self.e164(raw) else { throw SendError.badNumber }

        let sid = Self.accountSID, token = Self.authToken, from = Self.fromNumber
        let body = template.contains("{link}")
            ? template.replacingOccurrences(of: "{link}", with: link.absoluteString)
            : template + "\n" + link.absoluteString

        var req = URLRequest(url: URL(string:
            "https://api.twilio.com/2010-04-01/Accounts/\(sid)/Messages.json")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let auth = Data("\(sid):\(token)".utf8).base64EncodedString()
        req.setValue("Basic \(auth)", forHTTPHeaderField: "Authorization")
        req.httpBody = Self.form(["To": to, "From": from, "Body": body])
        // The venue's internet is the thing most likely to be missing. Fail in seconds so the
        // attendant can fall back to the QR, rather than holding a guest for a minute.
        req.timeoutInterval = 15

        sending = true
        lastError = nil
        defer { sending = false }

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else {
                // Twilio returns a human-readable `message`; use it, because "HTTP 400" tells an
                // attendant nothing and "The 'To' number is not a valid phone number" tells them
                // everything.
                let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                    .flatMap { $0?["message"] as? String }
                throw SendError.twilio(detail ?? "Texting service returned \(code).")
            }
            sentCount += 1
            // 🔑 The number is NOT in this line, and must never be.
            IncidentLog.shared.record(.take, "Texted a clip link to a guest")
        } catch let e as SendError {
            lastError = e.localizedDescription
            throw e
        } catch {
            let e = SendError.transport(error.localizedDescription)
            lastError = e.localizedDescription
            throw e
        }
    }

    // MARK: Numbers

    /// Best-effort E.164. Deliberately conservative: it will refuse rather than guess a country.
    ///
    /// A 10-digit entry becomes +1 because that is the booth's market and typing a country code at
    /// a party is friction nobody needs. Anything already starting with `+` is trusted as typed.
    static func e164(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.filter(\.isNumber)
        if trimmed.hasPrefix("+") {
            return digits.count >= 8 && digits.count <= 15 ? "+" + digits : nil
        }
        switch digits.count {
        case 10: return "+1" + digits
        case 11 where digits.hasPrefix("1"): return "+" + digits
        default: return nil
        }
    }

    /// (123) 456-7890 as it is typed, for the pad's readout. Falls back to the raw digits for
    /// anything that is not a 10-digit US number, so international entry still reads sensibly.
    ///
    /// 🐞 The `+` used to be filtered out here, so pressing it on the pad showed **nothing** — the
    /// readout stayed blank while the field was no longer empty, which reads as a dead key. An
    /// international number then displayed without the prefix it depends on.
    static func pretty(_ digits: String) -> String {
        if digits.hasPrefix("+") { return "+" + digits.filter(\.isNumber) }
        let d = digits.filter(\.isNumber)
        guard d.count <= 10 else { return d }
        var out = ""
        for (i, c) in d.enumerated() {
            if i == 0 { out += "(" }
            if i == 3 { out += ") " }
            if i == 6 { out += "-" }
            out.append(c)
        }
        return out
    }

    private static func form(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return Data(fields.map { k, v in
            "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&").utf8)
    }

    // MARK: Keychain

    private static func keychain(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    private static func keychainSet(_ account: String, _ value: String) {
        keychainDelete(account)
        guard !value.isEmpty else { return }
        var add: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: service,
                                  kSecAttrAccount as String: account]
        add[kSecValueData as String] = Data(value.utf8)
        // AfterFirstUnlock, matching the PLC credentials: the booth must keep working through a
        // screen lock mid-event, but the values stay unreadable on a powered-off, stolen iPad.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    private static func keychainDelete(_ account: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service,
                       kSecAttrAccount as String: account] as CFDictionary)
    }
}
