import Foundation
import Network

// MARK: - Glamatic slider (Siemens S7-1200) — link layer
//
// Ported from AuraBooth/Arm/GlamaticClient.swift. Every comment marked FACT below was proven
// against the live PLC; do not "clean up" any of them without re-proving on hardware.
//
// TWO CHANNELS, and choosing the right one per job is the whole design:
//
//   1. RAW TCP :2000  — two ASCII bytes, '1' then the program digit.
//      No session. No login. No cookie. Cannot exhaust the web server.
//      FACT: this is what the original CanonPivotBot used and what AuraBooth's working
//      program buttons call. The old client's failure was the ADDRESS (it pointed at
//      192.168.1.231:18333, the xArm on Modbus), not the protocol.
//      → USE FOR: running the 8 stored presets, and for STOP.
//
//   2. HTTPS /awp/Glamatic/IOServer.htm — the manufacturer's web API.
//      Session-gated (portal ENTER + FormLogin, HttpOnly cookie), tiny connection pool.
//      → USE FOR: telemetry reads, manual position/velocity drive, homing, fault reset.
//
// FACT: everything on channel 2 must be HTTPS. The cookie is issued on the https origin and a
// cookie set there is never returned on an http:// request — mixing them means logging in
// successfully and then reading as an anonymous client.
//
// FACT: an UNAUTHENTICATED write returns HTTP 200 and is silently discarded. ProgramNumber=7 was
// accepted and read back as 0. Never treat 200 as proof a value landed.

/// Accepts the PLC's self-signed certificate — and ONLY the PLC's, scoped by host so this cannot
/// loosen trust anywhere else in the app.
private final class PLCTrustDelegate: NSObject, URLSessionDelegate {
    let host: String
    init(host: String) { self.host = host }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == host,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

/// Machine limits and defaults. Deliberately OUTSIDE the @MainActor class so views can read them
/// from property-wrapper initialisers without an isolation hop.
///
/// The ranges are the manufacturer's own, taken from their web page's input fields. The PLC may
/// fault or ignore anything outside them, and a fault mid-event needs a homing cycle to clear.
enum PLC {
    static let hostKey = "armcontrol.plc.host"
    static let asciiPortKey = "armcontrol.plc.asciiPort"

    static let defaultHost = "192.168.1.2"
    static let defaultASCIIPort: UInt16 = 2000

    static let positionRange: ClosedRange<Double> = 0...600      // mm
    /// Speed limits for a DRIVEN move, in mm/s.
    ///
    /// 🔑 **RAISED 70–100 → 70–143 on 2026-09-10, from measurement, not documentation.**
    ///
    /// 100 mm/s was the manufacturer's figure and it was wrong for this path — believed for months
    /// and never tested. `RampProfile`'s header was built on it: *"a 1.43:1 range, far too narrow to
    /// ramp anything cinematically"*. Measured on the real rail, same 291 mm, twice:
    ///
    ///     commanded 100 → 291 mm in 2.37 s
    ///     commanded 150 → 291 mm in 1.30 s
    ///
    /// The PLC does not merely accept a higher number, it acts on it — 1.8× the speed on identical
    /// geometry, far outside any measurement error.
    ///
    /// ⚠️ **143 is chosen because the FACTORY drives it there, not because 143 is a limit.** Stored
    /// program 14 covers 600 mm in 4.20 s = 143 mm/s, from twenty-odd clean samples — the vendor's
    /// own program, on this machine, as delivered. That makes 143 demonstrably safe for the
    /// mechanism in a way that "the controller accepted 150" does not: a controller allowing a value
    /// and a rail being rated for it are different claims, and only the first was tested. Do not
    /// raise this further without the rail's actual rating.
    ///
    /// ⚠️ The measured figures above are OVERESTIMATES — position is polled about every 260 ms, so
    /// the clock starts up to one sample after the carriage does and the timed distance is short.
    /// The comparison is sound; the absolute numbers are not calibrated. Do not quote them as the
    /// machine's top speed.
    static let velocityRange: ClosedRange<Double> = 70...143     // mm/s
    static let programRange: ClosedRange<Int> = 0...63

    /// The raw channel carries a single digit, so it reaches programs 0–9 only.
    static let rawChannelMax = 9
}

@MainActor
final class GlamaticLink: ObservableObject {
    static let shared = GlamaticLink()

    // MARK: Configuration

    static var host: String {
        let h = UserDefaults.standard.string(forKey: PLC.hostKey) ?? ""
        return h.isEmpty ? PLC.defaultHost : h
    }

    static var asciiPort: UInt16 {
        let p = UserDefaults.standard.integer(forKey: PLC.asciiPortKey)
        return p > 0 && p < 65536 ? UInt16(p) : PLC.defaultASCIIPort
    }

    // MARK: Simulation
    //
    // ⚠️ A simulator that can be mistaken for a real rail is the worst possible bug in this app:
    // the operator would see Connected / Homed / Armed with nothing plugged in and believe the
    // booth works. So it is OFF by default, it lives behind Engineer settings, and every screen
    // that shows status shows a SIMULATED badge while it is on. Do not make it quieter.

    static let simulatedKey = "armcontrol.plc.simulated"

    @Published var simulated: Bool {
        didSet {
            guard simulated != oldValue else { return }
            UserDefaults.standard.set(simulated, forKey: Self.simulatedKey)
            disconnect()
            sim.powerCycle()
            sim.clearInjectedFaults()
            Self.plog(simulated ? "SIMULATED RAIL ON" : "SIMULATED RAIL OFF")
        }
    }

    let sim = RailSimulator()
    private var simTask: Task<Void, Never>?

    private func startSimLoop() {
        simTask?.cancel()
        simTask = Task { [weak self] in
            // 🔑 Integrate against the WALL CLOCK, not against the interval we asked to sleep for.
            // Feeding tick() a hardcoded 0.05 made the simulated rail run ~7% slow — a 14.1s round
            // trip really took 15.2s — because each iteration also pays for the sleep overshoot and
            // a publish. That is invisible until something measures the move with a real stopwatch,
            // at which point the honest measurement gets blamed for the simulator's loose clock.
            var last = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                let now = Date()
                let dt = now.timeIntervalSince(last)
                last = now
                guard let self, self.simulated, self.connected else { continue }
                self.sim.tick(dt)
                self.publishSimState()
            }
        }
    }

    private func publishSimState() {
        var s = State()
        s.currentPosition = String(Int(sim.position.rounded()))
        s.position = s.currentPosition
        s.velocity = String(Int(sim.programVelocity))
        s.homed = sim.homed ? "1" : "0"
        s.statusError = sim.fault ? "1" : "0"
        s.robotError = "0"
        s.programNum = String(sim.programNum)
        state = s
    }

    // MARK: Live state

    struct State: Equatable {
        var statusError = "0"
        var velocity = "0"
        var position = "0"
        var homed = "0"
        var currentPosition = "0"
        var robotError = "0"
        var programNum = "0"

        var hasFault: Bool { statusError != "0" || robotError != "0" }
        var isHomed: Bool { homed == "1" }
        var currentMM: Double { Double(currentPosition) ?? 0 }
    }

    /// Tag names exactly as the PLC expects them. "Velocety" is the manufacturer's spelling and
    /// MUST NOT be corrected — the tag will not resolve otherwise.
    enum Tag: String {
        case programNumber = "\"IOMotor\".ProgramNumber"
        case runProgram    = "\"IOMotor\".RunProgram"
        case position      = "\"IOMotor\".Position"
        case velocity      = "\"IOMotor\".Velocety"
        case execute       = "\"IOMotor\".Execute"
        case enable        = "\"IOMotor\".Enable"
        case manual        = "\"IOMotor\".Manual"
        case executeHoming = "\"IOMotor\".ExecuteHoming"
        case resetError    = "\"IOMotor\".ResetError"
    }

    @Published private(set) var connected = false
    @Published private(set) var state = State()

    /// How many uncommanded position changes have been seen, and when the last one was.
    /// Non-zero means another client is driving this rail — see `checkForForeignMotion`.
    @Published private(set) var foreignMotionCount = 0
    @Published private(set) var foreignMotionAt: Date?
    @Published private(set) var status = "Not connected"
    @Published private(set) var lastRead = "—"          // ok / expired / neterr
    @Published private(set) var reconnecting = false

    // Lifetime telemetry counters. Monotonic on purpose: the soak test snapshots them at the start
    // and subtracts at the end, so it never has to duplicate the polling that is itself the load
    // being tested. They also give the Engineer screen a running answer to "has the link been
    // healthy tonight" without anyone reading the log.
    @Published private(set) var readsOK = 0
    @Published private(set) var readsSilent = 0
    @Published private(set) var readsExpired = 0
    @Published private(set) var reconnects = 0
    @Published private(set) var lastGoodRead: Date?

    /// Mirrors what we last SENT for Manual and Enable. The PLC does not report these back in its
    /// JSON, so this is the only record of the drive gate's state.
    @Published private(set) var manualSent = false
    @Published private(set) var enableSent = false

    private let session: URLSession
    private var poll: Task<Void, Never>?
    /// 🐞 A COUNTER, not a flag. Three different things suspend the background poll — a manual
    /// move, an auto-reconnect, and a `MoveTimer` measurement — and they overlap. As a Bool, the
    /// first one to finish set it back to false while another was still running, which restarted
    /// the 3s poll *underneath* whatever was driving reads at the time: double the request volume
    /// on the exact web server this is all trying not to swamp, and a measurement timed against
    /// samples it did not take.
    private var suspendCount = 0
    private var suspendPoll: Bool { suspendCount > 0 }
    private var readFails = 0
    /// The name of the motion sequence currently talking to the PLC, or nil.
    ///
    /// 🚨 **WHY THIS EXISTS — measured 2026-09-08, and it left two levels stuck HIGH.**
    /// `connect()` has been single-flight for months because overlapping portal handshakes choke
    /// the S7-1200's tiny web server. Motion commands were never given the same protection, and
    /// they are far worse: `sendHome()` is a ~12-write conversation, not one request.
    ///
    /// An operator tapped Home three times in two seconds — the correct instinct, since nothing
    /// appeared to be happening — and the trace shows three full sequences interleaving:
    ///
    ///     18:59:34  send home: target 0 mm
    ///     18:59:35  send home: target 0 mm
    ///     18:59:35  send home: target 0 mm
    ///     18:59:44  write failed: "IOMotor".Manual
    ///     18:59:45  write failed: "IOMotor".RunProgram
    ///
    /// The web server wedged and writes began failing. **The dangerous part is WHICH writes.**
    /// Every trigger on this machine is a level that must be pulsed back to 0, and in the pileup
    /// the pulse-downs were the ones that got lost:
    ///
    ///     "IOMotor".ExecuteHoming = 1     (×3, no matching = 0)
    ///     "IOMotor".Execute = 1           (no matching = 0)
    ///
    /// A level left high is exactly the runaway that survived a power cycle earlier that day. So
    /// this is not about tidiness or a wasted round trip — **concurrent motion sequences can leave
    /// the rail armed and asking to move.** One at a time, always.
    ///
    /// Refuses rather than queues: a second Home tap means "it did not work", not "do it twice".
    private(set) var motionInFlight: String?

    /// What a long motion sequence is doing RIGHT NOW, for the screen.
    ///
    /// 🔑 **Because "I hit Home and I don't know if anything happened" is a real failure.**
    /// `sendHome()` can legitimately run for **up to 90 seconds** — clearing triggers, proving the
    /// carriage is stationary, referencing the axis against the limit switch (up to 60s of that on
    /// its own), driving to the park position, then watching it settle. For every one of those
    /// seconds the old UI showed nothing at all: no spinner, no text, an unchanged button.
    ///
    /// An operator cannot tell a slow sequence from a dead one, so they tap again — and tapping
    /// again is precisely what pile-drove three concurrent sequences into the PLC's web server and
    /// left a trigger latched high. **Silent slow work is what caused the runaway.** Saying what is
    /// happening is a safety feature, not decoration.
    @Published private(set) var motionPhase: String?

    var isMotionBusy: Bool { motionInFlight != nil }

    /// Run a motion sequence only if no other one is running.
    ///
    /// ⚠️ Sequences that call each other (`sendHome` → `referenceRail`) must call the *Core*
    /// variant inside the lock, never the public one, or they deadlock against themselves.
    private func withMotionLock<T>(_ name: String,
                                   refused: T,
                                   _ body: () async -> T) async -> T {
        if let current = motionInFlight {
            Self.plog("REFUSED \(name) — “\(current)” is already talking to the PLC")
            status = "Busy — \(current) is still running."
            return refused
        }
        motionInFlight = name
        motionPhase = "Starting…"
        defer { motionInFlight = nil; motionPhase = nil }
        return await body()
    }

    /// True while the single-flight portal handshake is running.
    ///
    /// Readable so `LinkDoctor` can WAIT for a handshake in flight rather than reading through it —
    /// a read that lands mid-login comes back as the login page and looks exactly like a rejected
    /// password.
    /// True once the portal handshake has a usable session cookie.
    ///
    /// 🐞 **Separate from `connected` because conflating them silently disabled the runaway
    /// protection.** `write()` guarded on `connected`, which is only set by `succeed()` — and
    /// `clearStaleTriggers()` runs BEFORE `succeed()` on purpose, so that nothing can arm the rail
    /// through a stale request. The result: every one of its three writes was discarded, it logged
    /// "cleared stale trigger levels" regardless, and **no latched trigger was ever actually
    /// cleared** — while the log said otherwise on every connect.
    ///
    /// The guard's intent was always "do we have a session?" (this PLC answers HTTP 200 with its
    /// login page when the session has lapsed, so a 200 proves nothing on its own). That is this
    /// flag. `connected` stays what the UI publishes, and keeps its later ordering.
    private var hasSession = false

    private(set) var isConnecting = false
    private var lastAutoReconnect = Date.distantPast
    private var reconnectBackoff: TimeInterval = 3

    private var base: String { "https://\(Self.host)" }

    private init() {
        simulated = UserDefaults.standard.bool(forKey: Self.simulatedKey)
        // Before anything tries to connect. A fresh install on a live rail should just work.
        Self.seedFactoryCredentialsIfEmpty()
        let cfg = URLSessionConfiguration.default
        cfg.httpCookieStorage = HTTPCookieStorage.shared
        cfg.httpShouldSetCookies = true
        cfg.httpCookieAcceptPolicy = .always
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 10
        // FACT: do NOT set httpMaximumConnectionsPerHost = 1. It made the app hang on connect
        // against this exact PLC while Safari connected fine at the same moment — the S7-1200
        // handles keep-alive poorly. Reduce request VOLUME instead, never pin the connection.
        session = URLSession(configuration: cfg,
                             delegate: PLCTrustDelegate(host: GlamaticLink.host),
                             delegateQueue: nil)
    }

    /// One HTTPS request, reporting exactly what came back. For `LinkDoctor` only.
    ///
    /// Deliberately separate from `get(_:_:)` inside `connect()`: that one folds every failure into
    /// a status string, and the whole point of the doctor is to keep the URLError code intact so a
    /// TLS refusal can be told apart from no route.
    enum Probe {
        case code(Int)
        case error(String, Int)
    }

    func probe(path: String) async -> Probe {
        guard let url = URL(string: "\(base)\(path)") else {
            return .error("Bad address “\(Self.host)”", -1)
        }
        do {
            let (_, resp) = try await session.data(from: url)
            return .code((resp as? HTTPURLResponse)?.statusCode ?? 0)
        } catch let e as URLError {
            return .error(e.localizedDescription, e.code.rawValue)
        } catch {
            return .error(error.localizedDescription, -1)
        }
    }

    // MARK: - Channel 1: raw TCP program trigger (no session required)

    /// Fire a stored program over the raw ASCII port. Two bytes: '1' then the digit.
    ///
    /// This is the primary path for the stored presets AND for stop, precisely because it needs
    /// no login: it keeps working when the web session has expired or the S7's web server is
    /// swamped, which is exactly when you most need to stop the rail.
    ///
    /// The wire format carries a single digit, so this channel reaches programs 0–9 only.
    @discardableResult
    func triggerProgramRaw(_ number: Int) async -> Bool {
        Kiosk.shared.noteActivity()      // operating the rail is not idle
        let n = min(PLC.rawChannelMax, max(0, number))
        if simulated {
            let ok = sim.runProgram(n)
            publishSimState()
            Self.plog("sim program \(n) → \(ok ? "running" : "refused")")
            if !ok { status = "Simulated rail refused it — arm and home first." }
            return ok
        }
        let host = Self.host
        let port = Self.asciiPort
        return await withCheckedContinuation { cont in
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                cont.resume(returning: false)
                return
            }
            let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            var finished = false
            func done(_ ok: Bool, _ why: String) {
                guard !finished else { return }
                finished = true
                Self.plog("ascii '1\(n)' → \(why)")
                conn.cancel()
                cont.resume(returning: ok)
            }
            conn.stateUpdateHandler = { st in
                switch st {
                case .ready:
                    conn.send(content: "1\(n)".data(using: .ascii), completion: .contentProcessed { err in
                        done(err == nil, err == nil ? "sent" : "send error: \(err!)")
                    })
                case .failed(let e): done(false, "connect failed: \(e)")
                case .cancelled:     done(false, "cancelled")
                default: break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + 6) { done(false, "timed out") }
        }
    }

    /// Stop the rail. Belt and braces, in the order that matters:
    ///   1. Program 0 over the SESSION-FREE channel. Program 0 is Home / stand-still.
    ///   2. Enable=0 over the web API, if and only if we have a live session.
    ///
    /// Step 1 first is deliberate — it is the path that still works when the web session is dead.
    ///
    /// ⚠️ This is a SOFT stop. Both channels are requests over a network the PLC may not be
    /// answering. A physical E-stop that cuts drive power is not optional on this machine.
    @discardableResult
    func stop() async -> Bool {
        Self.plog("STOP requested")
        if simulated {
            sim.stop()
            sim.enable = false
            enableSent = false
            publishSimState()
            status = "Stopped (simulated)"
            return true
        }
        // 🔑 **ORDER CORRECTED 2026-09-03, and this was a safety bug.** STOP used to fire the raw
        // ASCII channel FIRST and report success or failure based on it, on the reasoning that a
        // session-free path keeps working when the web session is dead. The reasoning was sound;
        // the premise was not. Measured on the live rail: the raw port accepts a connection and
        // takes the bytes (`ascii '12' → sent`) and **the carriage does not move** — the PLC is
        // not listening for that protocol. So STOP's primary path was inert, and it reported
        // "Stopped" on the strength of a socket that had done nothing.
        //
        // `Enable = 0` over the web API is what actually drops the drive. It goes first, it
        // decides the verdict, and the raw trigger stays only as a free second attempt.
        var dropped = false
        if connected {
            dropped = await write(.enable, "0")
            enableSent = false
        }
        _ = await triggerProgramRaw(0)

        // 🚨 **THEN CLEAR THE STANDING REQUESTS — STOP did not, and that is why a stopped rail
        // restarted itself.** Dropping `Enable` de-energises the motor and leaves `RunProgram` /
        // `Execute` / `ExecuteHoming` exactly as they were. The carriage halts, everyone relaxes,
        // and the next thing that energises the drive — an arm, a home, a power cycle — finds a
        // request still asserted and takes off again. Reported from the floor in those words:
        // *"e brake stopped it but then when it booted back up its doing the side to side again."*
        //
        // ⚠️ Deliberately AFTER dropping Enable, not before. Clearing three tags first costs three
        // round trips (~0.5s) before anything de-energises, and when someone hits STOP the motor
        // stopping soonest matters more than the tidiness of the trigger state. This ordering gets
        // both: fastest possible halt, then the latched request removed so re-arming is safe.
        var stuck: [String] = []
        for tag in [Tag.runProgram, .execute, .executeHoming] {
            if !(await write(tag, "0")) { stuck.append(tag.rawValue) }
        }
        // Hand it back in automatic mode, for the same reason as `cancelMotion`.
        _ = await setManual(false)

        if !stuck.isEmpty {
            Self.plog("🚨 STOP: could not clear \(stuck.joined(separator: ", ")) — a standing request may remain. "
                      + "Do NOT re-arm until the link is healthy; power-cycling with one latched restarts the rail.")
            IncidentLog.shared.record(.safety,
                                      "STOP left triggers uncleared: \(stuck.joined(separator: ", "))",
                                      bad: true)
        }

        if dropped {
            status = "Stopped"
        } else {
            // Being loud here is the point: with no session there is nothing left that can stop
            // this machine from the iPad.
            status = connected
                ? "STOP could not reach the rail — use the physical E-stop"
                : "No PLC session — STOP cannot reach the rail. USE THE PHYSICAL E-STOP."
            Self.plog("STOP FAILED to drop Enable (connected=\(connected))")
        }
        return dropped
    }

    // MARK: - Channel 2: web API session

    private static let service = "com.pivotxp.armcontrol.glamatic"

    static var username: String { keychain("user") ?? "" }
    static var password: String { keychain("pass") ?? "" }
    static var hasCredentials: Bool { !username.isEmpty && !password.isEmpty }

    static func setCredentials(user: String, pass: String) {
        keychainSet("user", user)
        keychainSet("pass", pass)
    }

    /// The Glamatic's factory web login, as shipped by the manufacturer on this rail.
    ///
    /// 🔑 **Why this is in here at all.** PivotBooth has driven this same PLC for months, but its
    /// credentials live in **its own** Keychain service (`com.pivotxp.aurabooth.glamatic`). Two
    /// apps, two keychains — so a working PivotBooth on the same iPad carries nothing across, and
    /// ArmControl arrives at a live rail with "PLC login: Not set", no telemetry, and every preset
    /// refusing to fire. That is not a thing to discover at a venue.
    ///
    /// ⚠️ **This is a machine login, not a person's.** It is the vendor default for the Glamatic,
    /// it only means anything to a PLC sitting on an isolated wired LAN with no route to the
    /// internet, and it is already written down in the project notes. It is seeded, never
    /// enforced: the moment an operator types something else it is overwritten and this code is
    /// dead. **If the rail's login is ever changed, change it in Settings — do not edit this.**
    static let factoryUser = "Glamatic"
    static let factoryPass = "Glamatic"

    /// Put the factory login in place on an iPad that has none, once.
    ///
    /// Deliberately only fills a genuinely EMPTY slot. An operator who has typed a different
    /// password must never have it silently reverted on the next launch — that failure mode is far
    /// worse than the one this fixes, because it would look like the PLC intermittently rejecting
    /// a correct login.
    static func seedFactoryCredentialsIfEmpty() {
        guard !hasCredentials else { return }
        setCredentials(user: factoryUser, pass: factoryPass)
        plog("seeded the factory PLC login (none was set)")
    }

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
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    /// Establish a portal session, then confirm we can actually READ.
    ///
    /// FACT: single-flight across ALL callers. The portal login is stateful on one HttpOnly
    /// cookie; overlapping handshakes queue on the tiny web server and choke it (3 concurrent
    /// connects took 78s and wedged it).
    @discardableResult
    func connect() async -> Bool {
        if isConnecting {
            Self.plog("connect() skipped — handshake already in flight")
            return false
        }
        isConnecting = true
        defer { isConnecting = false }

        if simulated {
            connected = true
            hasSession = true
            readFails = 0
            status = "Connected — SIMULATED RAIL, no hardware attached"
            sim.noteReconnected()          // a fresh session restarts the expiry clock
            publishSimState()
            startSimLoop()
            // The 20Hz sim loop only moves the carriage. Telemetry still goes through the SAME 3s
            // poll → refresh() path as the real PLC, so injected link faults land where they would
            // really land instead of on a private simulation-only branch.
            startPolling()
            Self.plog("connected (simulated)")
            // The real path logs this inside succeed(), which this branch returns before reaching.
            IncidentLog.shared.record(.link, "Connected (simulated rail)")
            return true
        }

        status = "Connecting to \(Self.host)…"

        // 🔑 **RETRIED, BECAUSE THIS PLC RUNS OUT OF SESSION SLOTS.** After a busy day the web
        // server stops issuing usable sessions: intro and ENTER return 200, the login POST returns
        // 200, cookies are issued — and **every read still redirects to the login page**. It looks
        // exactly like bad credentials and is not: the slots are held by sessions that have not
        // timed out yet. Proven on this rail, and the recovery below (log a slot out, redo the
        // handshake, try again) took THREE attempts to come good.
        for attempt in 1...3 {
            if attempt > 1 {
                Self.plog("connect: attempt \(attempt) — freeing a stale session slot first")
                await releaseStaleSession()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
            if await handshake() {
                // 🔑 The session exists from here — writes are permitted — but `connected` stays
                // false until `succeed()`, so no UI can offer ARM while the clear is in flight.
                // That split is the whole point: the clear must be able to write, and nothing else
                // must be able to.
                hasSession = true
                await clearStaleTriggers()
                return succeed("Connected")
            }
        }

        connected = false
        hasSession = false
        // 🔑 **NAME THE ACTUAL FAULT.** This signature — intro 200, ENTER 200, every login shape
        // 200, and yet every read still redirects to the login page — is **not** bad credentials
        // and not a network problem. It is the S7-1200's web server refusing to issue a usable
        // session because its slots are all held. Measured on this rail after a day of connecting.
        //
        // ⚠️ And it cannot be fixed from here: the logout form lives INSIDE an authenticated page,
        // so a client that is locked out has no token to log anything out with. Slots are freed by
        // the PLC's own idle timeout (~30 min) or by power-cycling the control box — and a power
        // cycle loses the homing reference, so it is not free either.
        status = reachedServerButNoSession
            ? "The PLC is refusing new sessions — its slots are full. Wait a few minutes, or power-cycle the control box (that loses homing)."
            : "Couldn't reach the slider at \(Self.host)"
        Self.plog("connect FAILED after 3 attempts: \(status)")
        return false
    }

    /// True when the web server answered every step and still would not hand over a session — the
    /// fingerprint of an exhausted session pool rather than a wrong password or a dead network.
    private var reachedServerButNoSession = false

    /// Ask the PLC to drop a session it is still holding.
    ///
    /// Its logout form carries a hidden `Cookie` token that must be echoed back, so this reads the
    /// portal page to scrape it. Best-effort by design — a failure here just means the retry above
    /// tries again with one fewer slot freed.
    private func releaseStaleSession() async {
        guard let url = URL(string: "\(base)/Portal/Portal.mwsl?PriNav=Start"),
              let (data, _) = try? await session.data(from: url),
              let html = String(data: data, encoding: .utf8),
              let range = html.range(of: #"name="Cookie"\s+value="([^"]+)""#, options: .regularExpression)
        else { return }
        let token = String(html[range]).components(separatedBy: "value=\"").last?.dropLast() ?? ""
        guard !token.isEmpty, let out = URL(string: "\(base)/FormLogin?LOGOUT") else { return }
        var req = URLRequest(url: out)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("\(base)/Portal/Portal.mwsl", forHTTPHeaderField: "Referer")
        req.setValue(base, forHTTPHeaderField: "Origin")
        req.httpBody = "Redirection=&Cookie=\(token)".data(using: .utf8)
        _ = try? await session.data(for: req)
        Self.plog("released a PLC session slot")
    }

    /// One full portal handshake: intro → ENTER → read → (login → read).
    private func handshake() async -> Bool {
        // 1. Land on the intro so the server issues whatever it issues.
        guard await get("intro", "\(base)/Portal/Intro.mwsl") >= 0 else {
            connected = false
            hasSession = false
            return false
        }

        // 2. ENTER — a plain GET form, verified against the PLC's own markup.
        _ = await get("enter", "\(base)/Portal/Portal.mwsl?intro_enter_button=ENTER&PriNav=Start&coming_from_intro=true")

        // 🔑 EVERY DECISION FROM HERE GOES IN THE TRACE. This is the stretch where connect used to
        // go silent: intro and enter both logged HTTP 200 and then nothing — no success, no
        // failure — because the read probe and the login only ever went to NSLog, which cannot be
        // pulled off the iPad. The arm LAN has no internet, so `Documents/glamatic.log` is the only
        // way to see this from outside the venue, and it was missing the one step that matters.
        let readAfterEnter = await refresh()
        Self.plog("post-enter read: \(readAfterEnter ? "JSON ok — session already valid" : "no data (\(lastRead)) — logging in")")
        if readAfterEnter { return true }

        // 3. Log in. Reads AND writes are both gated behind a real session.
        guard Self.hasCredentials else {
            Self.plog("no PLC credentials stored — cannot log in")
            status = "PLC login needed — add the username and password in Settings."
            connected = false
            hasSession = false
            return false
        }
        Self.plog("logging in as “\(Self.username)”")
        // FACT: deliberately no "write probe" fallback. An unauthenticated write returns 200 and
        // is discarded, so a 200 proves nothing. That is what made the app report success while
        // the slider never moved.
        return await login()
    }

    /// Their form is `POST /FormLogin` with Redirection / Login / Password. Posting exactly that
    /// returned HTTP 400 on some builds — a rejected REQUEST, not rejected credentials. Embedded
    /// web servers are fussy, so try the plausible shapes and keep the first one accepted.
    /// Credentials are never logged, only the variant name and status code.
    @discardableResult
    func login() async -> Bool {
        guard Self.hasCredentials else {
            status = "PLC login needed — add the username and password in Settings."
            return false
        }

        // Their page sets this marker cookie before submitting.
        if let c = HTTPCookie(properties: [
            .domain: Self.host, .path: "/", .name: "coming_from_login", .value: "true"
        ]) { HTTPCookieStorage.shared.setCookie(c) }

        var sawAcceptedShape = false
        let u = Self.form(Self.username)
        let p = Self.form(Self.password)

        let variants: [(String, String, Bool)] = [
            ("form",               "Redirection=&Login=\(u)&Password=\(p)", true),
            ("no-redirection",     "Login=\(u)&Password=\(p)", true),
            ("redirect-to-portal", "Redirection=%2FPortal%2FPortal.mwsl&Login=\(u)&Password=\(p)", true),
            ("form-no-referer",    "Redirection=&Login=\(u)&Password=\(p)", false),
        ]

        for (name, body, withReferer) in variants {
            guard let url = URL(string: "\(base)/FormLogin") else { return false }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            if withReferer {
                req.setValue("\(base)/Portal/Portal.mwsl", forHTTPHeaderField: "Referer")
                req.setValue(base, forHTTPHeaderField: "Origin")
            }
            req.httpBody = body.data(using: .utf8)

            if let (_, resp) = try? await session.data(for: req) {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                Self.plog("login[\(name)] → HTTP \(code)")
                if (200...399).contains(code) { sawAcceptedShape = true }
                if (200...399).contains(code), await refresh() {
                    Self.plog("login succeeded via '\(name)'")
                    return true
                }
            }
        }

        // If the server answered every shape with a 2xx/3xx and STILL gave no session, the
        // credentials are not the problem — the session pool is.
        reachedServerButNoSession = sawAcceptedShape
        Self.plog("login FAILED — all four request shapes were rejected or returned no session"
                  + (sawAcceptedShape ? " (server accepted the POSTs — session pool looks full)" : ""))
        status = sawAcceptedShape
            ? "The PLC accepted the login but issued no session — its session slots are full."
            : "PLC rejected the login — check the username and password."
        return false
    }

    private static func form(_ v: String) -> String {
        v.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? v
    }

    private func get(_ label: String, _ urlString: String) async -> Int {
        guard let url = URL(string: urlString) else { return -1 }
        do {
            let (_, resp) = try await session.data(from: url)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            Self.plog("\(label) → HTTP \(code)")
            return code
        } catch let e as URLError {
            Self.plog("\(label) FAILED: \(e.localizedDescription) (URLError \(e.code.rawValue))")
            status = "\(label): \(Self.hint(for: e))"
            return -1
        } catch {
            return -1
        }
    }

    /// Write every trigger level back to 0 **before the link reports connected**.
    ///
    /// 🚨 **THIS ORDERING IS THE WHOLE POINT, AND GETTING IT WRONG PUT A RAIL INTO A RUNAWAY.**
    ///
    /// RunProgram, Execute and ExecuteHoming are LEVELS, not pulses: the PLC keeps asking for
    /// movement until each is written back to 0, and a stuck one survives a lost session, a
    /// reconnect and a power cycle. A pileup of concurrent sequences lost the pulse-downs and left
    /// `Execute = 1` standing with nothing anywhere that would ever clear it.
    ///
    /// The first version of this fix cleared them in a detached `Task` fired from `succeed()`.
    /// That was too late and unsynchronised, and the trace shows exactly what it bought:
    ///
    ///     19:03:15  "IOMotor".RunProgram = 0     ← the clear, racing
    ///     19:03:15  "IOMotor".Manual = 1         ← the operator arming
    ///     19:03:16  "IOMotor".Execute = 0        ← the clear
    ///     19:03:16  "IOMotor".Enable = 1         ← the operator arming
    ///     19:03:16  ARMED
    ///
    /// `connected` had already gone true, so the UI let the rail be armed **through** the clear.
    /// Enable went high while `Execute` was still asserted, and the carriage left. Clearing a
    /// standing request concurrently with arming is not a fix — it is a race whose losing side is
    /// a moving machine.
    ///
    /// So this is `await`ed inside the handshake, before `succeed()`, before `connected` is true
    /// and therefore before any UI can offer an ARM button. By the time anything can energise the
    /// drive, the PLC is holding no requests.
    ///
    /// ⚠️ This only ever CLEARS. It never writes Enable, Manual or a position — nothing here can
    /// make the rail move, which is what makes it safe to run automatically on every connect.
    private func clearStaleTriggers() async {
        guard !simulated else { return }

        // 🔑 **CHECK THE WRITES LANDED, do not just issue them.** This routine logged
        // "cleared stale trigger levels" on every connect for a day while all three writes were
        // being discarded — the guard in `write()` tested `connected`, which is set after this
        // runs. A safety mechanism that reports its own success without evidence is worse than no
        // safety mechanism, because it stops anyone looking.
        var cleared = 0
        for tag in [Tag.runProgram, .execute, .executeHoming] {
            if await write(tag, "0") { cleared += 1 }
        }
        guard cleared == 3 else {
            Self.plog("⚠️ connect: trigger clear INCOMPLETE — only \(cleared) of 3 writes landed. "
                      + "A latched level may still be standing; do not arm.")
            status = "Could not clear the rail's triggers — do not arm, power-cycle the control box."
            return
        }
        Self.plog("connect: cleared stale trigger levels before reporting connected")

        // 🔑 **THEN PROVE IT IS STATIONARY.** Clearing a level is a request; a rail that is already
        // running is the thing that actually matters, and no tag reports "moving" — the only
        // evidence available is that `CurrentPosition` stops changing. So watch it.
        //
        // ⚠️ This is deliberately OBSERVED rather than assumed. Twice today a check that could not
        // fail loudly reported success it had not earned: the `Velocety` read-back that called
        // every speed clamped, and the arrival timer that turned a rail which never moved into
        // "29100 mm/s". A connect that says "cold" should have watched the carriage to say it.
        var seen: [Double] = []
        for _ in 0..<6 {
            try? await Task.sleep(nanoseconds: 300_000_000)
            await refresh()
            seen.append(state.currentMM)
        }
        let spread = (seen.max() ?? 0) - (seen.min() ?? 0)
        if spread > 3 {
            Self.plog(String(format: "🚨 connect: THE RAIL IS MOVING — %.1f mm of travel over 1.8s at %.0f mm. Triggers were cleared; use the E-stop.",
                             spread, seen.last ?? 0))
            status = "The rail is moving on its own — use the physical E-stop."
            IncidentLog.shared.record(.safety,
                                      String(format: "Rail moving at connect: %.1f mm drift over 1.8s", spread),
                                      bad: true)
        } else {
            Self.plog(String(format: "connect: rail confirmed stationary at %.0f mm (%.1f mm over 1.8s)",
                             seen.last ?? 0, spread))
        }
    }

    private func succeed(_ msg: String) -> Bool {
        connected = true
        status = msg
        readFails = 0
        IncidentLog.shared.record(.link, simulated ? "Connected (simulated)" : "Connected to \(Self.host)")
        Self.plog("connected (\(msg)) homed=\(state.isHomed) pos=\(state.currentPosition)")
        startPolling()
        return true
    }

    private static func hint(for e: URLError) -> String {
        switch e.code {
        case .notConnectedToInternet, .networkConnectionLost:
            return "no usable route — is the Ethernet adapter configured for this subnet?"
        case .cannotConnectToHost, .cannotFindHost:
            return "nothing answering — wrong address, or Local Network permission is off"
        case .timedOut:
            return "timed out — subnet reachable but no reply"
        default:
            return e.localizedDescription
        }
    }

    func disconnect() {
        poll?.cancel(); poll = nil
        simTask?.cancel(); simTask = nil
        connected = false
        hasSession = false
        manualSent = false
        enableSent = false
        status = "Not connected"
    }

    /// Hand telemetry reads over to a caller that needs them faster than every 3 seconds.
    ///
    /// ⚠️ **The 3s poll rate is a limit on the PLC's web server, not a UI preference** — sustained
    /// fast polling is the prime suspect for wedging it. So this exists only for a measurement that
    /// is bounded in time and started by a human, and it **suspends** the background poll rather
    /// than running alongside it: total request volume rises by the ratio, never by double.
    /// Always pair with `resumePolling()` in a `defer`.
    func suspendPolling() { suspendCount += 1 }
    func resumePolling() { suspendCount = max(0, suspendCount - 1) }

    private func startPolling() {
        poll?.cancel()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                if self?.suspendPoll != true {
                    _ = await self?.refresh()
                    await self?.watchForForeignMotion()
                }
                // FACT: 3s, not 0.5s. Sustained fast polling is itself a prime suspect for wedging
                // the S7-1200's web server. The position readout does not need to be fresher.
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    /// Last position seen by the idle watchdog, and when it last complained.
    private var idleWatchMM: Double?
    private var lastForeignWarning = Date.distantPast

    /// Notice when the rail moves and **this app did not ask it to**.
    ///
    /// 🔑 **WHY: this app is not the only controller on the arm LAN, and an afternoon went into
    /// forgetting that.** PivotBooth drives the same Glamatic — its Follow Me loop moves the
    /// carriage up to once every 0.8 s to track a subject, and it reconnects itself after any
    /// interruption. With it open on a second iPad the rail moved back and forth continuously while
    /// this app's log sat silent, and the silence was read as evidence of a PLC fault rather than
    /// of a second client. Hours went into latched-trigger theories that could not explain a rail
    /// moving with `Enable = 0`.
    ///
    /// So: if the carriage moves while this app believes it is idle and de-energised, say so. The
    /// app cannot see the other client, but it can see the consequence.
    ///
    /// ⚠️ Only complains when BOTH are true — no motion sequence of ours is running, and the drive
    /// is not armed. Anything else is our own movement and must not be reported as foreign.
    /// Rate-limited to once a minute so a live Follow Me session cannot flood the log.
    private func watchForForeignMotion() async {
        guard !simulated, connected else { idleWatchMM = nil; return }
        guard motionInFlight == nil, !enableSent, !SafetyKernel.shared.armed else {
            idleWatchMM = nil
            return
        }
        let now = state.currentMM
        defer { idleWatchMM = now }
        guard let previous = idleWatchMM else { return }
        // 3 mm over one 3 s poll is far beyond readout noise on a stationary rail.
        guard abs(now - previous) > 3 else { return }
        guard Date().timeIntervalSince(lastForeignWarning) > 60 else { return }
        lastForeignWarning = Date()

        Self.plog(String(format: "🚨 FOREIGN MOTION: rail moved %.0f → %.0f mm with nothing commanded here. "
                         + "Another controller is driving this PLC — check PivotBooth on the other iPad.",
                         previous, now))
        status = "Something else is driving this rail — check PivotBooth on the other iPad."
        IncidentLog.shared.record(.safety,
                                  String(format: "Rail moved %.0f → %.0f mm with nothing commanded by this app — another controller is on the LAN",
                                         previous, now),
                                  bad: true)
    }

    /// Single-flight auto-reconnect. Never runs concurrently with connect(), so it cannot corrupt
    /// the PLC's single session cookie — that is what got the old blanket resilience reverted.
    private func autoReestablish() {
        guard !reconnecting, !isConnecting else { return }
        guard Date().timeIntervalSince(lastAutoReconnect) > reconnectBackoff else { return }
        reconnecting = true
        lastAutoReconnect = Date()
        Task { [weak self] in
            guard let self else { return }
            Self.plog("auto-reconnect start (lastRead=\(self.lastRead), backoff=\(Int(self.reconnectBackoff))s)")
            self.suspendPolling()
            let ok = await self.connect()
            self.resumePolling()
            self.reconnecting = false
            if ok { self.reconnects += 1 }
            // 3→6→12→24, cap 30. A struggling PLC gets breathing room; a clean reconnect resets it.
            self.reconnectBackoff = ok ? 3 : min(30, self.reconnectBackoff * 2)
        }
    }

    // MARK: Read

    /// No HTTP reply at all: timeout, network, or the web server wedged. Don't drop `connected` on
    /// one blip; after three in a row the link is genuinely dead.
    private func noteSilentRead() -> Bool {
        lastRead = "neterr"
        readsSilent += 1
        readFails += 1
        if readFails >= 3 && connected {
            connected = false
            status = "Slider stopped responding — reconnecting…"
            Self.plog("session died: \(readFails) silent reads (neterr)")
            IncidentLog.shared.record(.link, "Link dropped — \(readFails) silent reads", bad: true)
        }
        if !connected { autoReestablish() }
        return false
    }

    /// Got a reply but it is the login PAGE, not JSON: the web session expired. The socket stays
    /// up, so `connected` would otherwise stay true forever while every read fails and writes are
    /// silently discarded — the rail just freezes. Unambiguous, so flip now.
    private func noteExpiredSession() -> Bool {
        lastRead = "expired"
        readsExpired += 1
        readFails += 1
        if connected {
            connected = false
            status = "Slider session expired — reconnecting…"
            Self.plog("session died: login page (expired)")
            IncidentLog.shared.record(.link, "PLC session expired", bad: true)
        }
        autoReestablish()
        return false
    }

    private func noteGoodRead() {
        lastRead = "ok"
        readsOK += 1
        readFails = 0
        lastGoodRead = Date()
    }

    @discardableResult
    func refresh() async -> Bool {
        if simulated {
            // The simulated rail can fail the way the LINK fails, not only the way the machine
            // does — and it goes down exactly the same two branches the real PLC does, so the
            // reconnect path being rehearsed is the shipping one.
            switch sim.rollRead() {
            case .silent:  return noteSilentRead()
            case .expired: return noteExpiredSession()
            case .ok:
                publishSimState()
                noteGoodRead()
                return true
            }
        }
        guard let url = URL(string: "\(base)/awp/Glamatic/IOServer.htm?_=\(Int(Date().timeIntervalSince1970 * 1000))") else { return false }
        guard let (data, _) = try? await session.data(from: url),
              let text = String(data: data, encoding: .utf8) else {
            return noteSilentRead()
        }
        guard let start = text.firstIndex(of: "{"),
              let obj = try? JSONSerialization.jsonObject(with: Data(text[start...].utf8)) as? [String: String]
        else {
            return noteExpiredSession()
        }

        noteGoodRead()
        var s = State()
        s.statusError     = obj["StatusError"] ?? "0"
        s.velocity        = obj["Velocety"] ?? "0"
        s.position        = obj["Position"] ?? "0"
        s.homed           = obj["StatusHomed"] ?? "0"
        s.currentPosition = obj["CurrentPosition"] ?? "0"
        s.robotError      = obj["RobotError"] ?? "0"
        s.programNum      = obj["ProgramNum"] ?? "0"
        checkForForeignMotion(previous: state, next: s)
        state = s
        return true
    }

    // MARK: - Is something ELSE driving this rail?
    //
    // 🔑 **THE DIAGNOSIS THAT HAS NOW COST TWO EVENINGS.** On 2026-09-10 a "runaway" was chased
    // through PLC-internal theories for an afternoon; the cause was PivotBooth open on a second iPad,
    // whose Follow Me loop drives this same rail up to once every 0.8s and reconnects itself after
    // any interruption. It happened again tonight. Both times the tell was the same and nobody was
    // watching for it: **the carriage moves while this app's log is silent.**
    //
    // That is a mechanically checkable fact, so check it. If `CurrentPosition` changes while we have
    // no motion outstanding, some other client is writing to the machine. The app cannot stop it —
    // nothing here can reach into another iPad — but it can stop the operator burning an evening on
    // the wrong theory.

    /// Until when motion we asked for could still legitimately be happening.
    private var motionExpectedUntil = Date.distantPast

    /// Set whenever this app commands motion, so the detector does not flag our own moves.
    func expectMotion(seconds: Double) {
        motionExpectedUntil = Date().addingTimeInterval(seconds)
    }

    private func checkForForeignMotion(previous: State, next: State) {
        guard Date() > motionExpectedUntil else { return }
        guard let a = Double(previous.currentPosition),
              let b = Double(next.currentPosition) else { return }
        // 3mm between samples is well past encoder noise on a rail with a 600mm throw.
        guard abs(b - a) > 3 else { return }

        foreignMotionCount += 1
        foreignMotionAt = Date()
        Self.plog(String(format: "⚠️ FOREIGN MOTION: carriage moved %.0f→%.0f mm with nothing commanded here",
                         a, b))
        // Log once per burst rather than four times a second.
        if foreignMotionCount == 1 || foreignMotionCount % 20 == 0 {
            IncidentLog.shared.record(.link,
                                      "Rail moved with no command from this app — another client is connected",
                                      bad: true)
        }
    }

    /// True while uncommanded motion has been seen in the last few seconds.
    var foreignMotionActive: Bool {
        guard let at = foreignMotionAt else { return false }
        return Date().timeIntervalSince(at) < 8
    }

    func clearForeignMotion() {
        foreignMotionCount = 0
        foreignMotionAt = nil
    }

    // MARK: Write

    @discardableResult
    func write(_ tag: Tag, _ value: String) async -> Bool {
        guard let url = URL(string: "\(base)/awp/Glamatic/IOServer.htm") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // Their page URL-encodes the tag name and leaves the value bare.
        let encodedTag = tag.rawValue
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: ".-_"))) ?? tag.rawValue
        req.httpBody = "\(encodedTag)=\(value)".data(using: .utf8)

        guard let (_, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            Self.plog("write failed: \(tag.rawValue)")
            return false
        }
        guard hasSession else {
            Self.plog("write DISCARDED (no PLC session): \(tag.rawValue)")
            status = "Not logged in — the PLC accepts commands and ignores them."
            return false
        }
        Self.plog("\(tag.rawValue) = \(value)")
        // FACT: do NOT refresh() here. Refreshing after every write doubled request volume
        // (one move = 3 writes = 6 requests) and helped swamp the web server. Fire-and-poll.
        return true
    }

    /// Select a program and trigger it over the WEB API — the two writes the manufacturer's
    /// RUN PROGRAM button does. Reaches the full 0–63 range, unlike the raw channel's 0–9.
    /// Confirms the number stuck before triggering: firing RunProgram against a selection that
    /// did not land would run whatever was previously selected.
    @discardableResult
    func runProgramWeb(_ number: Int) async -> Bool {
        let number = min(PLC.programRange.upperBound, max(PLC.programRange.lowerBound, number))
        if simulated {
            let ok = sim.runProgram(number)
            publishSimState()
            return ok
        }
        // 🔑🔑 **MANUAL MUST BE 0. This is why no preset ever moved the rail.**
        //
        // Proven on the live machine 2026-09-03 by trying the candidates and watching
        // CurrentPosition: `Manual=0, Enable=1, ProgramNumber=N, RunProgram=1` moved the carriage
        // 50 mm on the first attempt. `Manual` is a MODE SWITCH, not part of arming — it selects
        // jog control — and a stored program is an automatic-mode action, so with Manual=1 the
        // PLC is entirely within its rights to ignore RunProgram. It does, silently, with an
        // HTTP 200.
        //
        // The app's ARM writes Manual=1 because manual drive and homing genuinely need it, and
        // presets are gated on being armed — so arming was the very thing that guaranteed presets
        // could not work. The manufacturer's own web page never touches Manual when it runs a
        // program; that should have been the clue.
        _ = await setManual(false)
        _ = await setEnable(true)
        try? await Task.sleep(nanoseconds: 150_000_000)

        guard await write(.programNumber, String(number)) else { return false }
        try? await Task.sleep(nanoseconds: 250_000_000)
        await refresh()
        guard state.programNum == String(number) else {
            Self.plog("program \(number) did NOT stick (reads \(state.programNum)) — not triggering")
            status = "Program \(number) wasn't accepted by the PLC — check the login."
            return false
        }
        // 🚨 **PULSE IT. Leaving RunProgram at 1 makes the rail run the program forever.**
        // Observed on the live machine 2026-09-03: after a trigger the carriage kept cycling back
        // and forth with nothing commanding it, because `RunProgram` is a LEVEL this code set and
        // never cleared, and the PLC re-runs the program for as long as it is high. Exactly the
        // same trap as `ResetError` being edge-triggered, pointing the other way — that one needed
        // a rising edge to fire, this one needs a falling edge to stop asking.
        //
        // The manufacturer's own page gets away with writing a bare 1 because a human is watching
        // and clicks once; an app that fires this per take would leave a runaway rail behind.
        let fired = await write(.runProgram, "1")
        try? await Task.sleep(nanoseconds: 200_000_000)
        _ = await write(.runProgram, "0")
        return fired
    }

    /// Everything that can make the rail stop asking for more movement, in the order that matters.
    ///
    /// Separate from `stop()` because it is also what a recovery screen needs: clear the trigger
    /// FIRST, then drop the drive. Dropping Enable while RunProgram is still high stops the motor
    /// but leaves the request standing, so the next time anything energises it takes off again.
    /// Clear every request for movement, then de-energise.
    ///
    /// 🔑 **Returns false if ANY step failed, not just the last one.** This used to be three writes
    /// with the first two discarded and only `Enable`'s result returned — so a failed `RunProgram`
    /// clear reported "cancelled" while the trigger was still latched. Callers act on that:
    /// `TakeRunner` uses it to make a failed take safe, and `sendHome` uses it before proving the
    /// rail is stationary. A cancel that lies is how a camera fault becomes a carriage still
    /// cycling after the app has given up.
    ///
    /// ⚠️ `ExecuteHoming` is cleared here too, and was not before. `referenceRail()` pulses it, and
    /// a pulse that failed to come back down left a standing homing request that nothing in this
    /// path would have touched.
    ///
    /// ⚠️ Order matters and is not tidiable: every trigger goes to 0 BEFORE `Enable` drops.
    /// De-energising first leaves the requests standing, and they detonate on the next arm — which
    /// is precisely the runaway that survived a power cycle.
    @discardableResult
    func cancelMotion() async -> Bool {
        Self.plog("cancelMotion: clearing every trigger, then dropping Enable")
        if simulated { sim.stop(); sim.enable = false; enableSent = false; publishSimState(); return true }

        var failed: [String] = []
        for tag in [Tag.runProgram, .execute, .executeHoming] {
            if !(await write(tag, "0")) { failed.append(tag.rawValue) }
        }
        let dropped = await write(.enable, "0")
        if !dropped { failed.append(Tag.enable.rawValue) }
        enableSent = false

        // 🔑 **BACK TO AUTOMATIC, and nothing did this.** Every path in the app dropped `Enable`
        // and left `Manual` at 1, so the rail was handed back de-energised but still in MANUAL
        // mode with a `Position` setpoint loaded. Whatever energises it next therefore meets a
        // different machine than the one that armed — and this app has been the only thing setting
        // Manual, so nothing was ever putting it back.
        //
        // ⚠️ Ordering: mode LAST, after the drive is already dead. Changing mode on an energised
        // drive is the one sequence nobody has tested on this machine, and de-energised first is
        // the state where a mode change can do the least.
        _ = await setManual(false)

        guard failed.isEmpty else {
            Self.plog("🚨 cancelMotion INCOMPLETE — these did not land: \(failed.joined(separator: ", ")). "
                      + "The rail may still hold a movement request; use the physical E-stop.")
            status = "Could not fully stop the rail — use the physical E-stop."
            IncidentLog.shared.record(.safety,
                                      "Cancel incomplete — \(failed.joined(separator: ", ")) did not clear",
                                      bad: true)
            return false
        }
        return true
    }

    // MARK: - Put it back

    /// Where the carriage should be parked when nothing is happening.
    ///
    /// Defaults to 0 (the home end). Set it to wherever the rig actually lives — a booth whose
    /// neutral is mid-rail should not have to be dragged back from 0 every time.
    static let parkKey = "armcontrol.rail.parkMM"
    static var parkMM: Double {
        min(PLC.positionRange.upperBound,
            max(PLC.positionRange.lowerBound,
                UserDefaults.standard.object(forKey: parkKey) as? Double ?? 0))
    }
    static func rememberPark(_ mm: Double) {
        UserDefaults.standard.set(min(PLC.positionRange.upperBound,
                                      max(PLC.positionRange.lowerBound, mm)), forKey: parkKey)
        plog("park position remembered: \(Int(mm)) mm")
    }

    /// Re-establish where zero physically is, by hunting the limit switch.
    ///
    /// 🔑 **Different from "home", and the difference cost a trip to the rail.** `ExecuteHoming`
    /// references the AXIS; Program 0 is a stored MOVE to the parked pose. When the carriage is
    /// visibly not where it should be while `CurrentPosition` insists on 0, the *reference* is
    /// wrong and only this fixes it.
    ///
    /// ⚠️ **`StatusHomed` must be forced down first, or homing is a no-op.** With the flag already
    /// set the PLC decides it has nothing to do and the carriage never moves — which is exactly
    /// what happened: a homing run that reported success and travelled 0 mm. De-energising drops
    /// the flag; re-energising and pulsing then produces a real reference run (measured: the
    /// carriage backed off to −38 mm and drove back onto the switch).
    ///
    /// ⚠️ `StatusHomed` **flickers for a second or two after de-energising** — two reads 1.5s apart
    /// returned 0 then 1. Never decide anything from a single sample of it.
    @discardableResult
    func referenceRail() async -> Bool {
        await withMotionLock("Referencing", refused: false) { await referenceRailCore() }
    }

    private func referenceRailCore() async -> Bool {
        Self.plog("reference: forcing a real homing run")
        if simulated { return sim.startHoming() }

        for tag in [Tag.runProgram, .execute, .executeHoming] { _ = await write(tag, "0") }
        _ = await setEnable(false)
        _ = await setManual(false)
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        _ = await setManual(true)
        _ = await setEnable(true)
        try? await Task.sleep(nanoseconds: 500_000_000)
        // Pulsed, like every trigger on this machine — a level left high is what caused a runaway.
        _ = await write(.executeHoming, "1")
        try? await Task.sleep(nanoseconds: 400_000_000)
        _ = await write(.executeHoming, "0")

        let ok = await waitHomed(timeout: 60)
        Self.plog("reference finished: homed=\(ok) pos=\(state.currentPosition)")
        return ok
    }

    /// Put the rail back where it belongs, safely, in the order today's runaway taught.
    ///
    /// 🔑 **Clear the trigger → PROVE it is stationary → reference it → move.** Every step exists
    /// because skipping it caused a real failure:
    /// - A standing `RunProgram` survives a power cycle, so **clearing comes first** — homing
    ///   asserts Manual+Enable, and re-energising a PLC that still holds a run request is exactly
    ///   how the carriage takes off again.
    /// - "Stationary" is checked by watching `CurrentPosition`, not by a write returning 200. A
    ///   write this PLC will not act on is indistinguishable from one it obeys.
    /// - Homing is skipped when the rail already reads referenced, because it is slow and the
    ///   reference is what a park actually depends on.
    @discardableResult
    func sendHome() async -> Bool {
        await withMotionLock("Home", refused: false) { await sendHomeCore() }
    }

    private func sendHomeCore() async -> Bool {
        Kiosk.shared.noteActivity()
        let target = Self.parkMM
        Self.plog("send home: target \(Int(target)) mm")

        if simulated {
            _ = await cancelMotion()
            _ = sim.startHoming()
            _ = sim.moveTo(target, velocity: 85)
            publishSimState()
            return true
        }
        guard connected else {
            status = "Not connected — cannot send the rail home."
            return false
        }

        // 1. Nothing may still be asking for movement.
        motionPhase = "Clearing any standing move…"
        _ = await cancelMotion()
        _ = await write(.programNumber, "0")

        // 2. Prove it.
        motionPhase = "Checking the rail is stopped…"
        var seen: [Double] = []
        for _ in 0..<6 {
            try? await Task.sleep(nanoseconds: 400_000_000)
            await refresh()
            seen.append(state.currentMM)
        }
        let spread = (seen.max() ?? 0) - (seen.min() ?? 0)
        guard spread <= 4 else {
            status = "Still moving — not sending it home. Use the physical E-stop."
            Self.plog("send home REFUSED: still moving (\(String(format: "%.1f", spread)) mm spread)")
            return false
        }

        // 3. **PROGRAM 0 IS HOME.** Not `ExecuteHoming` — those are different things and confusing
        //    them wasted a trip to the rail:
        //      • Program 0 is a stored MOVE that returns the carriage to its parked pose. It is
        //        what CanonPivotBot's "RETURN ARM HOME (PROGRAM 0)" button fired, and it is what
        //        an operator means by "put it home".
        //      • `ExecuteHoming` REFERENCES the axis — it hunts the limit switch to re-establish
        //        where zero physically is. See `referenceRail()`.
        //    A stored program is an automatic-mode action, so Manual must be 0.
        var ok = true
        if !state.isHomed {
            // Unreferenced: the PLC refuses to move at all, so reference first.
            // Named with its real cost — this is the slow step, and an operator who is not told
            // that assumes a stall.
            motionPhase = "Referencing the axis — this can take a minute…"
            _ = await referenceRailCore()
        }

        // 3b. **DRIVE IT THERE MANUALLY. Program 0 does NOT bring the rail home.**
        //
        // 🐞 This used to fire `runProgramWeb(0)`, on the belief that "Program 0 is Home". That
        // belief came from a BUTTON LABEL in CanonPivotBot ("RETURN ARM HOME (PROGRAM 0)"), not
        // from this machine, and it was never once verified here. The operator's report was blunt
        // and correct: the Home button did nothing.
        //
        // What the 0–63 sweep actually found: **program 0 has never been observed to move
        // anything.** Its only trial ran from position 0, where a home move and an empty slot are
        // indistinguishable — so the sweep recorded "empty" and the assumption survived untested.
        // Meanwhile the manual path proved itself dozens of times in the same sweep, returning the
        // carriage from 300mm before every single probe.
        //
        // So Home now uses the sequence that is known to work on this rail rather than the one a
        // different app's label implied. Manual mode, explicit target, PULSED Execute.
        motionPhase = String(format: "Driving to %d mm…", Int(target))
        _ = await setManual(true)
        _ = await setEnable(true)
        try? await Task.sleep(nanoseconds: 200_000_000)
        _ = await write(.velocity, "85")
        _ = await write(.position, String(Int(target)))
        try? await Task.sleep(nanoseconds: 200_000_000)
        ok = await write(.execute, "1")
        try? await Task.sleep(nanoseconds: 300_000_000)
        _ = await write(.execute, "0")          // 🚨 PULSE — a level left high is a runaway

        // 4. Watch it settle rather than assuming — a write this PLC will not act on looks
        //    identical to one it obeys.
        var still = 0
        var previous = state.currentMM
        for _ in 0..<100 {
            try? await Task.sleep(nanoseconds: 300_000_000)
            await refresh()
            // Live position, so a slow traverse is visibly a traverse and not a hang.
            motionPhase = String(format: "Moving — %d mm, heading for %d",
                                 Int(state.currentMM), Int(target))
            if abs(state.currentMM - previous) < 1 { still += 1 } else { still = 0 }
            previous = state.currentMM
            if still >= 8 { break }
        }

        // 5. Leave it cold — the UI says disarmed, so the machine must be.
        //
        // ⚠️ **FACT, measured 2026-09-08: dropping Enable CLEARS `StatusHomed`.** The rail parks
        // correctly and then reads "not referenced", which is not a failure — the reference does
        // not survive the drive being de-energised, exactly as it does not survive a power cycle.
        // Leaving Enable on to preserve it would be worse: a hot rail under a screen that says
        // disarmed. So the machine is left cold and the operator is TOLD, rather than discovering
        // it when the next preset refuses.
        // 🔑 **THE SLIDER IS ONLY HALF OF HOME.** There are two machines in this rig, and parking
        // the rail while the jointed arm stays standing is not "home" — it is the failure the
        // operator reported as "slider worked but the arm didn't fold down".
        //
        // The arm folds AFTER the rail has parked, deliberately: the arm sweeps a much larger
        // volume than the carriage, and folding it while the rail is still travelling means two
        // machines moving at once through the same space.
        //
        // ⚠️ A failure here does NOT fail the whole Home — the rail really did park, and saying
        // otherwise would be its own lie. It is reported separately and precisely.
        let armFolded = await XArmLink.shared.foldDown { [weak self] phase in
            Task { @MainActor in self?.motionPhase = phase }
        }

        // ⚠️ **Back to AUTOMATIC before letting go.** Homing above switches the PLC into manual
        // mode, and a stored program will not run while Manual is 1 — it is accepted and silently
        // ignored, which is the exact failure that made the rail look dead this morning. Leaving
        // Manual asserted here would mean Home "worked" and then every preset afterwards did
        // nothing, with no error to explain it.
        _ = await setManual(false)
        _ = await setEnable(false)
        await SafetyKernel.shared.disarm(reason: "Sent home")
        await refresh()
        status = ok
            ? (armFolded
                ? "Parked at \(Int(state.currentMM)) mm and the arm is folded — drive off, home it again before the next take"
                : "Rail parked at \(Int(state.currentMM)) mm, but THE ARM DID NOT FOLD — \(XArmLink.shared.status)")
            : "Could not reach the park position"
        Self.plog("send home finished: pos=\(state.currentPosition) ok=\(ok)")
        IncidentLog.shared.record(.safety,
                                  "Rail sent home to \(Int(state.currentMM)) mm"
                                  + (armFolded ? ", arm folded" : " — ARM NOT FOLDED"),
                                  bad: !armFolded)
        return ok
    }

    /// Run a stored program — **the way PivotBooth does it**, which is the version with years of
    /// event hours behind it.
    ///
    /// 🔑 **Two ASCII bytes to port 2000, and NO `RunProgram` tag.** That distinction is the whole
    /// reason this reverted. PivotBooth's program buttons and its capture trigger both call the
    /// raw path; its web `runProgram` carries the identical never-cleared `RunProgram = 1` that
    /// caused a runaway here, and the only thing that saved it is that nothing in its UI calls it.
    /// A trigger that cannot latch is worth more than one that can be verified.
    ///
    /// 🔑 **`Manual = 0` first** — the one genuine discovery from testing this on the live rail,
    /// and it applies to both channels. A stored program is an automatic-mode action; with
    /// Manual=1 the PLC ignores the trigger, which is why the raw channel looked dead earlier
    /// (`ascii '12' → sent`, carriage motionless) and why I wrongly concluded the PLC did not
    /// speak that protocol at all.
    ///
    /// `Enable` is deliberately NOT touched here: it is the drive gate, presets are already gated
    /// on being armed, and energising the machine stays a human tap.
    @discardableResult
    func runProgram(_ number: Int) async -> Bool {
        // A stored program runs for as long as it runs — the PLC gives no "finished" signal — so
        // claim a generous window. Motion inside it is ours; motion outside it is somebody else's.
        expectMotion(seconds: 30)
        return await withMotionLock("Program \(number)", refused: false) { await runProgramCore(number) }
    }

    private func runProgramCore(_ number: Int) async -> Bool {
        if !simulated {
            _ = await setManual(false)
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        // ⚠️⚠️ **BACK TO THE WEB PATH, AND THIS TIME FOR A SAFETY REASON RATHER THAN A TASTE ONE.**
        //
        // I switched presets to the raw ASCII channel because PivotBooth uses it and it cannot
        // latch a `RunProgram` level. That reasoning was half right and the half it missed is
        // worse: **the raw channel is fire-and-forget.** It opens a socket, sends two bytes and
        // reports success whether or not the PLC acted — there is no read-back, no confirmation
        // the program number landed, and **no way to take the request back**. A take fired
        // `ascii '11'`, the position sat at 0 for the whole watch window, the take failed on the
        // camera — and the carriage started cycling afterwards with nothing left to cancel.
        //
        // The web path is the manufacturer's own sequence, it is the one `MoveDoctor` actually
        // proved moves this rail, it **verifies ProgramNumber stuck before triggering**, and it
        // **pulses RunProgram back to 0** so it cannot leave a standing request. Given a choice
        // between a trigger that cannot latch and one that can be seen and cancelled, the second
        // is worth more — because "cannot latch" turned out not to mean "cannot run away".
        //
        // `triggerProgramRaw` stays for STOP's second attempt only.
        return await runProgramWeb(number)
    }

    /// Move to an absolute position at a given speed, clamped to the manufacturer's limits.
    /// Poll is suspended for the duration so we never open a second concurrent socket.
    @discardableResult
    func move(to position: Double, velocity: Double) async -> Bool {
        // Distance over speed, plus slack for acceleration and the arrival poll.
        let here = Double(state.currentPosition) ?? 0
        expectMotion(seconds: abs(position - here) / max(1, velocity) + 8)
        return await withMotionLock("Move", refused: false) { await moveCore(to: position, velocity: velocity) }
    }

    private func moveCore(to position: Double, velocity: Double) async -> Bool {
        Kiosk.shared.noteActivity()
        let pos = min(PLC.positionRange.upperBound, max(PLC.positionRange.lowerBound, position))
        let vel = min(PLC.velocityRange.upperBound, max(PLC.velocityRange.lowerBound, velocity))
        if simulated {
            let ok = sim.moveTo(pos, velocity: vel)
            publishSimState()
            return ok
        }
        suspendPolling()
        defer { resumePolling() }
        // 🔑 Assert the mode this action needs rather than trusting whatever was set last.
        // Running a stored program now sets Manual=0, so a manual move that followed one would
        // otherwise be issued in automatic mode and quietly ignored — the same class of bug,
        // pointing the other way. Each action owns its mode; neither can strand the other.
        _ = await setManual(true)
        _ = await setEnable(true)
        // ⚠️ **1.5s, and the history here is worth reading before shortening it again.**
        //
        // Manual is a MODE switch and Enable ENERGISES the drive; a Position written before the PLC
        // has taken both is accepted and silently ignored. This was 150 ms, then 400 ms.
        //
        // 🐞 **The 400 ms figure was drawn from a false comparison.** It came from the speed-ceiling
        // test appearing to work at 400 ms while `moveCore` failed at 150 — but PivotBooth was open
        // on a second iPad throughout that period, holding the slider armed (`Manual=1, Enable=1`)
        // for its Follow Me loop. Every app-driven move that "worked" that afternoon ran on a drive
        // something else had already energised. With PivotBooth closed and an identical sequence,
        // the carriage did not move at all — `arrival FAILED: target 600, started 0, furthest 0`.
        //
        // So this app has arguably never energised the drive by itself, and the settle it needs is
        // unmeasured rather than known. 1.5 s is a deliberately generous starting point: slow
        // enough to be unambiguous, and the cost of being wrong is a delay rather than a move that
        // silently does not happen.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        guard await write(.velocity, String(Int(vel))) else { return false }
        guard await write(.position, String(Int(pos))) else { return false }
        try? await Task.sleep(nanoseconds: 200_000_000)

        // 🚨 **PULSE, and this was the one trigger in the app that did not.**
        //
        // This used to be `return await write(.execute, "1")` — the level asserted and never
        // cleared. Every leg of every custom motion left a standing move request on the PLC, which
        // is precisely the condition behind the runaway that survived a power cycle: a latched
        // level is invisible (the trigger tags are write-only) and detonates on the next `Enable`.
        //
        // It is also why the first real "Run on the rail" never completed. `Whalefall` aborted with
        // "never arrived at 600" while the same Position/Velocety/Execute sequence — pulsed —
        // drove 291 mm cleanly in the speed test minutes earlier. The only difference was this.
        let fired = await write(.execute, "1")
        try? await Task.sleep(nanoseconds: 300_000_000)
        _ = await write(.execute, "0")
        return fired
    }

    /// The drive gate. FACT: the PLC requires Manual=1 AND Enable=1 before it executes any move,
    /// and it does not report either back — so these mirror what we sent.
    @discardableResult
    func setManual(_ on: Bool) async -> Bool {
        if simulated { sim.manual = on; manualSent = on; return true }
        let ok = await write(.manual, on ? "1" : "0")
        if ok { manualSent = on }
        return ok
    }

    @discardableResult
    func setEnable(_ on: Bool) async -> Bool {
        if simulated { sim.enable = on; enableSent = on; return true }
        let ok = await write(.enable, on ? "1" : "0")
        if ok { enableSent = on }
        return ok
    }

    @discardableResult
    func home() async -> Bool {
        Kiosk.shared.noteActivity()
        if simulated { return sim.startHoming() }
        // Homing is a manual-mode action and the PLC ignores it otherwise — same rule as `move`.
        // Asserted here so homing still works after a preset has switched the PLC to automatic.
        _ = await setManual(true)
        _ = await setEnable(true)
        try? await Task.sleep(nanoseconds: 150_000_000)
        return await write(.executeHoming, "1")
    }

    /// Wait for homing to complete. FACT: homing is lost on power cycle and the PLC refuses moves
    /// until it is homed, so this gate is not optional.
    @discardableResult
    func waitHomed(timeout: TimeInterval = 35) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            await refresh()
            if state.isHomed { return true }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return false
    }

    /// Reset a latched PLC fault.
    ///
    /// FACT: ResetError is EDGE-triggered — it fires on a 0→1 transition — so this PULSES
    /// 0 → 1 → 0. Writing a bare 1 when it is already 1 creates no rising edge and the fault
    /// never clears. Seen after an E-stop: StatusError=1 stayed latched through repeated clears
    /// that all wrote a bare 1.
    @discardableResult
    func clearFault() async -> Bool {
        if simulated { sim.resetError(); publishSimState(); return true }
        _ = await write(.resetError, "0")                 // clean low before the edge
        try? await Task.sleep(nanoseconds: 150_000_000)
        let ok = await write(.resetError, "1")            // 0→1 rising edge = the actual reset
        try? await Task.sleep(nanoseconds: 250_000_000)
        _ = await write(.resetError, "0")                 // release so a future fault can re-trigger
        return ok
    }

    /// Full recovery from a latched StatusError.
    ///
    /// FACT, learned the hard way: the PLC IGNORES ResetError unless Manual and Enable are on
    /// first, and StatusError=1 is a "not referenced" status rather than a hardware fault — a
    /// successful HOMING is what actually clears it. So home THROUGH the fault, don't abort on it.
    /// A power cycle does not clear it and loses homing.
    @discardableResult
    func recoverFromFault() async -> Bool {
        Self.plog("fault recovery: arm → pulse reset → home")
        guard await setManual(true), await setEnable(true) else { return false }
        try? await Task.sleep(nanoseconds: 200_000_000)
        _ = await clearFault()
        guard await home() else { return false }
        return await waitHomed()
    }

    // MARK: Trace
    //
    // The arm network has no internet, so a cloud logger cannot be reached while debugging here.
    // A local file is the only remote-visibility path. Pull it over USB with:
    //   xcrun devicectl device copy from --device <UDID> --domain-type appDataContainer \
    //     --domain-identifier com.pivotxp.armcontrol --source Documents/glamatic.log

    nonisolated static func plog(_ s: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date()))  \(s)\n"
        NSLog("[Glamatic] %@", s)
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = dir.appendingPathComponent("glamatic.log")
        guard let data = line.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
