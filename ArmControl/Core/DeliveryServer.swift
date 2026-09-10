import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Network
import UIKit

/// Hands the finished clip to the guest's phone over the venue Wi-Fi.
///
/// 🔑 **Why a local server and not a cloud upload.** The booth has to work at venues with no usable
/// internet, and a cloud path adds an account, a bill, an upload wait and a failure mode in front of
/// a guest. This serves the file straight off the iPad: scan, and the video opens on the phone. A
/// cloud backend can slot in later behind the same `DeliveryServer.url(for:)` seam — this is the
/// version that works today with nothing else switched on.
///
/// ⚠️ **The QR must carry the Wi-Fi address, never the arm LAN.** Since the rail moved to wired
/// Ethernet the iPad has two interfaces, and `192.168.1.x` is a private wire a guest's phone cannot
/// reach — a QR pointing there is a dead link that looks perfectly fine on screen.
@MainActor
final class DeliveryServer: ObservableObject {
    static let shared = DeliveryServer()

    static let enabledKey = "armcontrol.delivery.enabled"
    static let portKey = "armcontrol.delivery.port"

    @Published private(set) var running = false
    @Published private(set) var status = "Off"
    /// The address a phone should use. Nil when there is no usable Wi-Fi interface.
    @Published private(set) var host: String?

    @Published var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            enabled ? start() : stop()
        }
    }

    var port: UInt16 {
        let p = UserDefaults.standard.integer(forKey: Self.portKey)
        return p > 1024 && p < 65535 ? UInt16(p) : 8787
    }

    private var listener: NWListener?
    /// token → file. Capped, because a day of takes would otherwise pin every render on disk.
    private var clips: [String: URL] = [:]
    private var order: [String] = []
    private let keepLast = 40

    // MARK: Did a phone ever actually get here?
    //
    // 🔑 **The delivery failure this cannot otherwise see is CLIENT ISOLATION.** Venue and guest
    // Wi-Fi routinely block device-to-device traffic, and when it does the QR is perfect, the
    // server is running, the address is right — and every phone that scans it hangs. Nothing on the
    // iPad can detect that by looking at itself: the only proof is a request actually arriving.
    //
    // So the app counts them, and the setup screen offers a code to scan before the doors open.
    // Ten seconds of somebody's own phone is the difference between knowing and hoping.

    @Published private(set) var lastReachedAt: Date?
    @Published private(set) var reachedCount = 0

    /// The address to scan during setup: a plain page that just says it worked.
    var checkURL: URL? {
        guard let host else { return nil }
        return URL(string: "http://\(host):\(port)/check")
    }

    private func noteReached() {
        lastReachedAt = Date()
        reachedCount += 1
    }

    private var watch: Task<Void, Never>?

    private init() {
        enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        if enabled { start() }
        startWatch()
    }

    /// Keep the served address honest.
    ///
    /// 🐞 `host` was read ONCE, in `start()`, which runs at launch. An iPad that boots before the
    /// venue Wi-Fi is up — the normal order of events when someone powers up a booth — got
    /// `host == nil`, printed "No Wi-Fi address", and **never tried again all night**. The QR was
    /// simply absent and nothing said why unless somebody opened Pre-flight. The same read also
    /// went stale on a DHCP renew or a network switch, at which point every code pointed at an
    /// address that was no longer this iPad.
    ///
    /// Cheap: `wifiAddress()` is a local `getifaddrs` walk, not a network call.
    private func startWatch() {
        watch?.cancel()
        watch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let self, self.enabled else { continue }
                let current = Self.wifiAddress()
                if !self.running || current != self.host {
                    guard current != nil else { continue }
                    GlamaticLink.plog("delivery address \(self.host ?? "none") → \(current!), restarting")
                    self.start()
                }
            }
        }
    }

    // MARK: Publishing a clip

    /// Register a finished clip and get the URL to put in a QR code.
    func publish(_ file: URL) -> URL? {
        let token = Self.makeToken()
        clips[token] = file
        order.append(token)
        while order.count > keepLast {
            clips.removeValue(forKey: order.removeFirst())
        }
        return url(for: token)
    }

    func url(for token: String) -> URL? {
        guard let host else { return nil }
        return URL(string: "http://\(host):\(port)/t/\(token)")
    }

    /// Short, unambiguous, and not sequential — a guest should not be able to guess the next one.
    private static func makeToken() -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return String((0..<10).map { _ in alphabet.randomElement()! })
    }

    // MARK: Server

    func start() {
        stop()
        host = Self.wifiAddress()
        guard host != nil else {
            status = "No Wi-Fi address — join the venue network"
            running = false
            return
        }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                status = "Bad port \(port)"
                return
            }
            let l = try NWListener(using: params, on: nwPort)
            l.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in self?.handle(conn) }
            }
            l.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self?.running = true
                        self?.status = "Serving on \(self?.host ?? "?"):\(self?.port ?? 0)"
                    case .failed(let e):
                        self?.running = false
                        self?.status = "Failed: \(e.localizedDescription)"
                    default: break
                    }
                }
            }
            l.start(queue: .global(qos: .userInitiated))
            listener = l
        } catch {
            status = "Could not start: \(error.localizedDescription)"
            running = false
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        running = false
        status = "Off"
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .userInitiated))
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let data, let text = String(data: data, encoding: .utf8),
                  let line = text.split(separator: "\r\n").first else {
                conn.cancel(); return
            }
            let parts = line.split(separator: " ")
            let path = parts.count > 1 ? String(parts[1]) : "/"
            Task { @MainActor in
                self?.respond(to: path, on: conn)
            }
        }
    }

    private func respond(to path: String, on conn: NWConnection) {
        // Any request at all is proof a phone reached this iPad. That is worth recording on its own
        // — see `lastReachedAt`.
        noteReached()

        // /check → the setup self-test. Answered before the token lookup, because it has no token.
        if path.hasPrefix("/check") {
            send(conn, status: "200 OK", type: "text/html; charset=utf-8",
                 body: Data(Self.checkPage().utf8))
            return
        }

        // /t/<token>  → the landing page.  /f/<token> → the file itself.
        let token = path.split(separator: "/").last.map(String.init) ?? ""
        guard let file = clips[token] else {
            send(conn, status: "404 Not Found", type: "text/plain; charset=utf-8",
                 body: Data("That link has expired. Ask the booth for a new one.".utf8))
            return
        }

        if path.hasPrefix("/f/") {
            guard let data = try? Data(contentsOf: file) else {
                send(conn, status: "500 Internal Server Error", type: "text/plain",
                     body: Data("Could not read the clip.".utf8))
                return
            }
            // `inline` rather than `attachment`: iOS Safari plays it, and Share → Save Video is one
            // tap. An attachment download lands in Files, which is where clips go to be forgotten.
            send(conn, status: "200 OK", type: "video/mp4", body: data,
                 extraHeaders: ["Content-Disposition": "inline; filename=\"pivot.mp4\""])
            return
        }

        send(conn, status: "200 OK", type: "text/html; charset=utf-8",
             body: Data(Self.page(token: token).utf8))
    }

    private func send(_ conn: NWConnection, status: String, type: String, body: Data,
                      extraHeaders: [String: String] = [:]) {
        var head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\nConnection: close\r\n"
        for (k, v) in extraHeaders { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    /// Deliberately one self-contained file — no external CSS or fonts. A venue phone may be on a
    /// Wi-Fi with no internet at all, and anything fetched from outside would just hang.
    /// The self-test page. Deliberately says nothing about the booth — whoever scans this is crew,
    /// and the only question is whether the bytes arrived.
    private static func checkPage() -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>Delivery check</title>
        <style>
          body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;
               background:#0b0b0c;color:#f2f2f7;font:-apple-system-body,system-ui,sans-serif;
               text-align:center;padding:24px}
          .tick{font-size:72px;line-height:1}
          h1{font-size:26px;margin:18px 0 8px}
          p{color:#9a9aa0;margin:0;font-size:15px;line-height:1.45}
        </style></head><body><div>
          <div class="tick">✅</div>
          <h1>This phone can reach the booth</h1>
          <p>Guests on this Wi-Fi will be able to open their clips.</p>
        </div></body></html>
        """
    }

    private static func page(token: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>Your clip</title>
        <style>
          :root { color-scheme: dark; }
          body { margin:0; background:#0b0d0f; color:#fff; font:16px/1.5 -apple-system,system-ui,sans-serif;
                 display:flex; flex-direction:column; align-items:center; justify-content:center;
                 min-height:100vh; padding:24px; box-sizing:border-box; }
          video { width:100%; max-width:420px; border-radius:16px; background:#000; }
          a { display:block; margin-top:22px; padding:16px 28px; background:#48F4AD; color:#0b0d0f;
              font-weight:600; border-radius:14px; text-decoration:none; }
          p { color:#8b9298; font-size:14px; margin-top:18px; text-align:center; max-width:420px; }
        </style></head><body>
        <video src="/f/\(token)" controls autoplay muted playsinline></video>
        <a href="/f/\(token)">Save the video</a>
        <p>Tap and hold the video, or use Share &rarr; Save Video.</p>
        </body></html>
        """
    }

    // MARK: Address

    /// The Wi-Fi address, explicitly skipping the wired arm LAN.
    ///
    /// `en0` is Wi-Fi on iPad; a USB-C Ethernet adapter shows up as a separate interface. Choosing
    /// by name alone is fragile, so anything on the arm's subnet is rejected outright — that wire
    /// is not reachable from a guest's phone and must never end up in a QR code.
    static func wifiAddress() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        let armSubnet = GlamaticLink.host.split(separator: ".").prefix(3).joined(separator: ".")
        var fallback: String?

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & IFF_UP == IFF_UP, flags & IFF_LOOPBACK == 0,
                  ptr.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(ptr.pointee.ifa_addr, socklen_t(ptr.pointee.ifa_addr.pointee.sa_len),
                              &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: buf)
            guard !ip.isEmpty, !ip.hasPrefix("169.254") else { continue }

            // Never hand out the arm wire.
            if ip.split(separator: ".").prefix(3).joined(separator: ".") == armSubnet { continue }

            let name = String(cString: ptr.pointee.ifa_name)
            if name == "en0" { return ip }
            if fallback == nil { fallback = ip }
        }
        return fallback
    }

    // MARK: QR

    static func qr(for url: URL) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        // Integer scale with no interpolation — a smoothed QR is a QR that scans badly.
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
