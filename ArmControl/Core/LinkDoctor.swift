import Foundation
import Network

/// Finds out **which layer** of the rail connection is broken, instead of "Not connected".
///
/// 🔑 **Why this is worth a screen of its own.** There are five independent things between this
/// app and a moving rail, they fail for completely different reasons, and until now every one of
/// them produced the same red pill. Standing at a venue with the rail powered on and the app
/// saying "Not connected", the honest next step was guesswork:
///
///   1. **Route** — is the iPad even on 192.168.1.x? (wrong Ethernet config, adapter unplugged)
///   2. **Raw port 2000** — plain TCP, no TLS, no login. If this works the PLC is alive and the
///      wire is fine, which immediately clears 1 and points at the web stack.
///   3. **TLS / ATS** — the S7-1200's web server speaks old TLS. Without `NSAllowsLocalNetworking`
///      in Info.plist, iOS refuses the connection before the certificate is even examined.
///   4. **Portal session** — the ENTER handshake.
///   5. **Login** — the PLC's own credentials.
///
/// Each runs independently and reports what it found. The point is that **2 succeeding while 3
/// fails is a completely different problem from both failing**, and that distinction is invisible
/// from the Console screen.
@MainActor
final class LinkDoctor: ObservableObject {
    static let shared = LinkDoctor()
    private init() {}

    enum Verdict: String {
        case pass, fail, skip
    }

    struct Step: Identifiable {
        let id = UUID()
        var name: String
        var verdict: Verdict
        var detail: String
        /// What to actually do about it. Nil when the step passed.
        var remedy: String?
        /// Set when the fix is a switch in iOS Settings rather than anything at the rail — the
        /// view turns this into a button, because the alternative is talking someone through
        /// Settings → Privacy & Security → Local Network while a queue waits.
        var settingsLink: URL?
    }

    @Published private(set) var steps: [Step] = []
    @Published private(set) var running = false
    @Published private(set) var finishedAt: Date?

    /// One line for the row that launches this.
    var summary: String {
        guard let finishedAt else { return "Never run" }
        let bad = steps.filter { $0.verdict == .fail }.count
        let when = finishedAt.formatted(date: .omitted, time: .shortened)
        return bad == 0 ? "All clear · \(when)" : "\(bad) failed · \(when)"
    }

    func run() async {
        guard !running else { return }
        running = true
        steps = []
        defer { running = false; finishedAt = Date() }

        let host = GlamaticLink.host
        let port = GlamaticLink.asciiPort
        GlamaticLink.plog("link doctor: start against \(host)")

        // ⚠️ The background poll is the other thing talking to this PLC. Two conversations at once
        // is what wedges the S7-1200's web server, and a diagnostic that caused the fault it is
        // looking for would be worse than useless.
        GlamaticLink.shared.suspendPolling()
        defer { GlamaticLink.shared.resumePolling() }

        if GlamaticLink.shared.simulated {
            add(Step(name: "Simulated rail is ON",
                     verdict: .fail,
                     detail: "The app is talking to the built-in simulator, not to any hardware. Nothing below tests the real rail.",
                     remedy: "Turn off Engineer → Simulated rail, then run this again."))
            return
        }

        await checkLocalNetworkPermission()
        await checkInterface(host: host)
        let rawOK = await checkRawPort(host: host, port: port)
        let tlsOK = await checkTLS(host: host)
        if tlsOK { await checkSessionAndLogin(host: host) }
        else {
            add(Step(name: "Portal session", verdict: .skip,
                     detail: "Not attempted — the HTTPS layer never opened.", remedy: nil))
        }

        // The single most useful sentence, stated once at the end.
        if rawOK && !tlsOK {
            add(Step(name: "What this pattern means",
                     verdict: .fail,
                     detail: "Port 2000 answered but HTTPS did not. The rail is powered, on the network and reachable — so this is not wiring and not the address. It is the web server or the phone's TLS policy.",
                     remedy: "Presets and STOP will still work over the raw port. Telemetry, homing, manual drive and fault reset will not."))
        }
    }

    private func add(_ s: Step) { steps.append(s) }

    // MARK: 0. iOS itself

    /// 🔑 **This runs first because it invalidates everything below it.** If iOS is blocking local
    /// network traffic, port 2000 fails, HTTPS fails and the session fails — with timeouts that
    /// are byte-identical to an unplugged cable. Every step after this one would report a network
    /// fault and send someone to check wiring that is perfectly fine.
    private func checkLocalNetworkPermission() async {
        let status = await LocalNetworkPermission.check()
        switch status {
        case .granted:
            add(Step(name: "iOS local network access",
                     verdict: .pass,
                     detail: "Allowed. iOS is not blocking traffic to the arm network.",
                     remedy: nil))
        case .denied:
            add(Step(name: "iOS local network access",
                     verdict: .fail,
                     detail: "DENIED. iOS is blocking every connection to 192.168.1.x before it leaves the iPad. Nothing below this can pass, and no cable or address change will help.",
                     remedy: "Open Settings and turn Local Network on for Arm Control. iOS only ever asks once, so a “Don’t Allow” tapped weeks ago is permanent until this switch is flipped. If Arm Control is not in the list at all, delete the app and install it again — that is the only way to make iOS ask a second time.",
                     settingsLink: LocalNetworkPermission.settingsURL))
        case .undetermined:
            add(Step(name: "iOS local network access",
                     verdict: .skip,
                     detail: "No answer yet — either the permission prompt is on screen right now, or iOS has never asked.",
                     remedy: "If a prompt appeared, tap Allow and run this again.",
                     settingsLink: LocalNetworkPermission.settingsURL))
        }
    }

    // MARK: 1. Route

    /// Is this iPad actually on the rail's subnet? A `getifaddrs` walk, no traffic.
    private func checkInterface(host: String) async {
        let want = host.split(separator: ".").prefix(3).joined(separator: ".")
        var mine: [String] = []
        // 🔑 **Every interface, including ones with no IPv4 address yet.** Listing only addressed
        // interfaces made "the adapter is not attached" and "the adapter is attached but the cable
        // has no link" produce byte-identical output — and those need completely different fixes.
        // An Ethernet adapter that is present but unlinked shows up here as a name with no address,
        // which is the distinction that matters.
        // Tracked apart, because "attached but unaddressed" and "not attached" need opposite
        // advice and used to produce identical output.
        var upNoAddress: Set<String> = []
        var downNames: Set<String> = []
        /// Interfaces carrying an fe80:: address — i.e. ones with a genuine link.
        var hasLink: Set<String> = []
        var head: UnsafeMutablePointer<ifaddrs>?
        var addressed: Set<String> = []
        if getifaddrs(&head) == 0, let first = head {
            defer { freeifaddrs(head) }
            for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
                let flags = Int32(ptr.pointee.ifa_flags)
                guard flags & IFF_LOOPBACK == 0 else { continue }
                let name = String(cString: ptr.pointee.ifa_name)
                let isUp = flags & IFF_UP == IFF_UP
                if !isUp { downNames.insert(name) }
                // 🔑 **IPv6 link-local is the proof that a link is REAL.** "Up with no IPv4" is
                // two different faults wearing the same face: a live Ethernet link waiting for an
                // address, and a phantom interface iOS keeps around with nothing on the other end.
                // The kernel autoconfigures an `fe80::` address on any interface that actually has
                // a link, and on nothing that does not — so its presence separates "the cable is
                // live, only the IPv4 config is missing" from "this interface is not your adapter".
                // Without this the doctor named three candidate interfaces and could not say which
                // one to configure.
                if isUp, ptr.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET6) {
                    var buf6 = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(ptr.pointee.ifa_addr,
                                   socklen_t(ptr.pointee.ifa_addr.pointee.sa_len),
                                   &buf6, socklen_t(buf6.count), nil, 0, NI_NUMERICHOST) == 0,
                       String(cString: buf6).lowercased().hasPrefix("fe80") {
                        hasLink.insert(name)
                    }
                }
                guard isUp, ptr.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) else {
                    if isUp { upNoAddress.insert(name) }
                    continue
                }
                var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(ptr.pointee.ifa_addr,
                                  socklen_t(ptr.pointee.ifa_addr.pointee.sa_len),
                                  &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
                mine.append("\(name) \(String(cString: buf))")
                addressed.insert(name)
            }
        }
        upNoAddress.subtract(addressed)
        downNames.subtract(addressed)

        // 🔑 **A wired adapter that is UP with no IPv4 is the single most actionable state here**,
        // and the one this check used to hide. It means the cable, the adapter and the hub are all
        // fine — the link came up, iOS enumerated it, it simply has no address. The old remedy
        // ("check the adapter is seated in a powered hub") sent someone to re-seat hardware that
        // was already working, while the actual fix was two taps away in Settings.
        //
        // `enN` names only: `awdl0`, `llw0`, `utunN`, `anpiN` and friends are always up and always
        // unaddressed, and listing them as candidates is noise.
        // A live wired interface: named enN, up, no IPv4, but carrying a link-local v6 address.
        let wiredCandidates = upNoAddress
            .filter { $0.hasPrefix("en") && hasLink.contains($0) }
            .sorted()
        let deadEN = upNoAddress.filter { $0.hasPrefix("en") && !hasLink.contains($0) }.sorted()
        if !wiredCandidates.isEmpty {
            mine.append("LIVE LINK, no IPv4: " + wiredCandidates.joined(separator: ", "))
        }
        if !deadEN.isEmpty {
            mine.append("no link: " + deadEN.joined(separator: ", "))
        }
        if !downNames.isEmpty {
            mine.append("down: " + downNames.sorted().joined(separator: ", "))
        }
        let onSubnet = mine.contains { $0.contains(want + ".") }
        let selfAssigned = mine.contains { $0.contains("169.254.") }

        let remedy: String?
        if onSubnet {
            remedy = nil
        } else if selfAssigned {
            remedy = "An address starting 169.254 means the wired interface got no configuration. Settings → Ethernet → Configure IP → Manual, 192.168.1.50, mask 255.255.255.0, and leave the router field BLANK."
        } else if !wiredCandidates.isEmpty {
            remedy = "\(wiredCandidates.joined(separator: ", ")) has a LIVE LINK but no IPv4 address — the cable, adapter and hub are all working, and only the address is missing. Do not re-seat anything. The arm LAN has no DHCP server, so set it by hand: Settings → Ethernet → Configure IP → Manual, 192.168.1.50, mask 255.255.255.0, router BLANK. If it is already set to Manual, unplug the adapter and plug it back in — iOS applies that config when the interface comes up, so one saved while it was already up may not have taken."
        } else if !deadEN.isEmpty {
            remedy = "Wired interfaces exist (\(deadEN.joined(separator: ", "))) but NONE of them has a link — no IPv4 and no IPv6 link-local, which means nothing is connected on the other end. This is the adapter, the cable or the hub, not the iPad's settings: an adapter iOS can see but cannot link through looks exactly like this. Try a different cable into the switch, and confirm the switch port shows a light."
        } else {
            remedy = "Nothing on \(want).x and no wired interface is up. Check the USB-C adapter is seated in a powered hub, then set the wired interface manually to 192.168.1.50/255.255.255.0 with a blank router."
        }

        add(Step(name: "This iPad's network",
                 verdict: onSubnet ? .pass : .fail,
                 detail: mine.isEmpty ? "No active IPv4 interfaces." : mine.joined(separator: "\n"),
                 remedy: remedy))
    }

    // MARK: 2. Raw port

    private func checkRawPort(host: String, port: UInt16) async -> Bool {
        let (ok, detail) = await withCheckedContinuation { (cont: CheckedContinuation<(Bool, String), Never>) in
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                cont.resume(returning: (false, "Port \(port) is not valid.")); return
            }
            let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            var done = false
            func finish(_ r: (Bool, String)) {
                guard !done else { return }
                done = true
                conn.cancel()
                cont.resume(returning: r)
            }
            conn.stateUpdateHandler = { st in
                switch st {
                case .ready:         finish((true, "Connected to \(host):\(port)."))
                case .failed(let e): finish((false, "\(e)"))
                default: break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { finish((false, "No answer within 5s.")) }
        }
        add(Step(name: "Program trigger port \(port)",
                 verdict: ok ? .pass : .fail,
                 detail: detail,
                 remedy: ok ? nil
                    : "This is plain TCP with no login, so a failure here is the network or the PLC itself — not credentials. Presets and STOP both use this port."))
        return ok
    }

    // MARK: 3. TLS / ATS

    private func checkTLS(host: String) async -> Bool {
        let result = await GlamaticLink.shared.probe(path: "/Portal/Intro.mwsl")
        switch result {
        case .code(let c):
            add(Step(name: "HTTPS to the web server",
                     verdict: .pass,
                     detail: "The PLC's web server answered with HTTP \(c).",
                     remedy: nil))
            return true
        case .error(let message, let code):
            // -1200 / -9800-series are the TLS failures ATS produces. Naming it matters: the fix
            // is a build setting, not anything an operator can do at the venue.
            let looksTLS = code == NSURLErrorSecureConnectionFailed
                || code == NSURLErrorServerCertificateUntrusted
                || code == NSURLErrorCannotLoadFromNetwork
            add(Step(name: "HTTPS to the web server",
                     verdict: .fail,
                     detail: "\(message) (URLError \(code))",
                     remedy: looksTLS
                        ? "This is a TLS refusal. The PLC serves an old TLS version that App Transport Security blocks unless the app carries NSAllowsLocalNetworking — which this build does. If you are seeing this, report the code above."
                        : "The web server did not answer. If port 2000 above passed, the PLC is alive but its web server may be wedged — power-cycle the control box (note that homing is lost)."))
            return false
        }
    }

    // MARK: 4 & 5. Session and login

    private func checkSessionAndLogin(host: String) async {
        let hasCreds = GlamaticLink.hasCredentials
        add(Step(name: "PLC login stored",
                 verdict: hasCreds ? .pass : .fail,
                 detail: hasCreds
                    ? "Username “\(GlamaticLink.username)” is set."
                    : "No username or password saved on this iPad.",
                 remedy: hasCreds ? nil
                    : "Settings → PLC login. The rail's factory login is \(GlamaticLink.factoryUser) / \(GlamaticLink.factoryPass)."))

        // ⚠️ **Do not race the app's own startup handshake.** `connect()` is single-flight — if a
        // handshake is already running it returns false immediately without doing anything, which
        // is not a failure. Reading straight after that lands BEFORE the login completes, and the
        // step then reported "the credentials were rejected" about a login that succeeded one
        // second later. It sent someone to re-check a username that was correct while the rail sat
        // there connected and homed. Wait for the in-flight handshake to finish first.
        var ok = await GlamaticLink.shared.connect()
        if !ok, GlamaticLink.shared.isConnecting {
            for _ in 0..<40 where GlamaticLink.shared.isConnecting {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            ok = GlamaticLink.shared.connected
        }
        let reads = await GlamaticLink.shared.refresh()
        add(Step(name: "Session and telemetry",
                 verdict: reads ? .pass : .fail,
                 detail: reads
                    ? "Reading live tags. Position \(GlamaticLink.shared.state.currentPosition) mm, homed \(GlamaticLink.shared.state.isHomed ? "yes" : "no")."
                    : "Connected: \(ok). Last read: \(GlamaticLink.shared.lastRead). \(GlamaticLink.shared.status)",
                 remedy: reads ? nil
                    : GlamaticLink.shared.lastRead == "expired"
                        ? "The PLC answered with its login page instead of data, which means the credentials were rejected or the session did not take. Check the username and password."
                        : "The handshake completed but no telemetry came back. Try Connect again; if it keeps failing the web server may need a power-cycle."))
    }

    /// Plain text for a message to whoever is not standing at the rail.
    var export: String {
        var out = ["Arm Control — connection check",
                   "\(Date().formatted()) · rail at \(GlamaticLink.host)", ""]
        for s in steps {
            out.append("[\(s.verdict.rawValue.uppercased())] \(s.name)")
            out.append("   \(s.detail.replacingOccurrences(of: "\n", with: "\n   "))")
            if let r = s.remedy { out.append("   → \(r)") }
            out.append("")
        }
        return out.joined(separator: "\n")
    }
}
