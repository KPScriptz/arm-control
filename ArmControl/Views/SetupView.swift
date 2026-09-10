import SwiftUI

/// Setup is a menu, not a wall. Each area is one row with its current state on the right, the way
/// Settings shows you the Wi-Fi network without making you open Wi-Fi.
struct SetupView: View {
    @StateObject private var link = GlamaticLink.shared
    @StateObject private var store = ProgramStore.shared
    @StateObject private var kiosk = Kiosk.shared
    @StateObject private var delivery = DeliveryServer.shared
    @StateObject private var log = IncidentLog.shared
    // Observed only so the pre-flight summary on the menu row stays live rather than going stale
    // the moment something is armed or the camera starts.
    @StateObject private var safety = SafetyKernel.shared
    @StateObject private var recorder = Recorder.shared
    @StateObject private var takes = TakeLog.shared
    @State private var confirmLock = false
    @State private var setupCount = 0

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }

    var body: some View {
        List {
            // First thing on the screen, not buried at the bottom of Booth flow. Whoever came in
            // here came in to change one setting and then get back to running the booth.
            Section {
                Button {
                    confirmLock = true
                } label: {
                    HStack {
                        Label("Back to booth", systemImage: "arrow.uturn.backward")
                            .font(.body.weight(.semibold))
                        Spacer()
                        Image(systemName: "lock.fill")
                            .foregroundStyle(Theme.secondary)
                    }
                }
            } footer: {
                Text("Locks the app to the one-button attendant screen.")
            }

            // Above the individual settings on purpose: the question before an event is "is this
            // ready", not "what is the trigger port". One row answers it.
            Section {
                NavigationLink {
                    PreflightView()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: Preflight.level.symbol)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(Preflight.level.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Pre-flight").font(.body)
                            Text(Preflight.summary)
                                .font(.footnote)
                                .foregroundStyle(Theme.secondary)
                        }
                    }
                }
            } footer: {
                Text("Walk this before the doors open. Camera, storage, permissions, delivery and the rail, each with what to do about it.")
            }

            // The bookend to Pre-flight, and it lives next to it for that reason: one answers
            // "is this ready", the other answers "how did it go" — and the second question is
            // currently answered from memory the next morning.
            Section {
                NavigationLink {
                    EventReportView()
                } label: {
                    HStack {
                        Label("Event report", systemImage: "doc.text")
                        Spacer()
                        Text(EventReport.summary)
                            .font(.footnote)
                            .foregroundStyle(Theme.secondary)
                    }
                }
            } footer: {
                Text("Takes, problems, whether phones actually reached the delivery server, how hot the iPad got, and the settings it all ran with. Shareable as plain text.")
            }

            // Putting the rig back is the last thing anybody does before packing up, so it lives
            // where it can be found in a hurry rather than three screens down.
            Section {
                Button {
                    Task { await GlamaticLink.shared.sendHome() }
                } label: {
                    HStack {
                        Label("Send the rail home", systemImage: "house.fill")
                            .font(.body.weight(.semibold))
                        Spacer()
                        Text("\(Int(GlamaticLink.parkMM)) mm")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(Theme.secondary)
                    }
                }
                .disabled(!link.connected && !link.simulated)

                Button {
                    Task { await GlamaticLink.shared.referenceRail() }
                } label: {
                    Label("Re-reference the rail", systemImage: "scope")
                }
                .disabled(!link.connected && !link.simulated)

                Button {
                    GlamaticLink.rememberPark(link.state.currentMM)
                    setupCount &+= 1
                } label: {
                    Label("Remember this spot as home", systemImage: "mappin.and.ellipse")
                }
                .disabled(!link.connected)
            } footer: {
                Text("“Send the rail home” clears any standing trigger, waits until the carriage has actually stopped, then runs the PLC's own Program 0 — the same home move the old CanonPivotBot fired. Use “Re-reference” instead when the carriage is visibly in the wrong place while the readout insists it is at 0: that hunts the limit switch and re-establishes where zero physically is.")
            }

            // 🚨 Above everything else, because a rail that will not stop is the only thing that
            // matters while it is happening.
            if !link.simulated {
                Section {
                    Button(role: .destructive) {
                        Task { await GlamaticLink.shared.cancelMotion() }
                    } label: {
                        DestructiveLabel("Clear a runaway trigger", systemImage: "hand.raised.fill")
                    }
                } footer: {
                    Text("Writes RunProgram=0 and Execute=0, then drops Enable. Use this when the carriage keeps moving on its own, or starts moving again after a power cycle — that means the PLC is still holding a run request, and arming or homing will only set it off again. This does NOT home the rail: clear the trigger first, then home it deliberately.")
                }
            }

            // Connected but the carriage will not move — a completely different problem from no
            // link, and the one that is live right now.
            if link.connected, !link.simulated {
                Section {
                    NavigationLink {
                        MoveDoctorView()
                    } label: {
                        Label("Why won't it move?", systemImage: "arrow.left.arrow.right.circle")
                            .foregroundStyle(Theme.warn)
                    }
                } footer: {
                    Text("Connected but nothing happens when you fire a preset. Tries each trigger sequence and watches the position to see which one the PLC actually acts on.")
                }
            }

            // Directly under Network, because "No link" is the moment you need it.
            if !link.connected, !link.simulated {
                Section {
                    NavigationLink {
                        LinkDoctorView()
                    } label: {
                        HStack {
                            Label("Why won't it connect?", systemImage: "stethoscope")
                                .foregroundStyle(Theme.warn)
                            Spacer()
                            Text(LinkDoctor.shared.summary)
                                .font(.footnote)
                                .foregroundStyle(Theme.secondary)
                        }
                    }
                } footer: {
                    Text("Tests the route, the trigger port, TLS, the session and the login one at a time, and says which one failed.")
                }
            }

            Section {
                row("Network", "network", detail: link.connected ? "Connected" : "No link",
                    tint: link.connected ? Theme.good : Theme.bad) { NetworkSettings() }
                row("PLC login", "key.fill",
                    detail: GlamaticLink.hasCredentials ? "Saved" : "Not set",
                    tint: GlamaticLink.hasCredentials ? Theme.secondary : Theme.warn) { LoginSettings() }
            }

            Section {
                row("Presets", "square.grid.2x2.fill",
                    detail: "\(store.visible.count) of \(store.presets.count)") { PresetSettings() }
                row("Movements", "film.stack",
                    detail: "\(TraceLibrary.shared.capturedCount) captured") { MovementLibraryView() }
                row("Custom motions", "arrow.left.and.right.righttriangle.left.righttriangle.right",
                    detail: "\(MotionStore.shared.motions.count)") { MotionsView() }
                row("Booth flow", "person.crop.square.filled.and.at.rectangle",
                    detail: kiosk.locked ? "Locked" : "Unlocked",
                    tint: kiosk.locked ? Theme.good : Theme.warn) { AttendantSettings() }
                row("Delivery", "qrcode",
                    detail: delivery.running ? "On" : "Off",
                    tint: delivery.running ? Theme.good : Theme.secondary) { DeliverySettings() }
                row("Event setups", "square.stack.3d.up.fill",
                    detail: setupCount == 0 ? "None saved" : "\(setupCount) saved",
                    tint: setupCount == 0 ? Theme.warn : Theme.secondary) { EventSetupsView() }
            }

            Section {
                row("Takes", "film.stack",
                    detail: takes.todaySummary,
                    tint: takes.todayWithWarnings > 0 ? Theme.warn : Theme.secondary) { TakesView() }
                row("History", "list.bullet.rectangle",
                    detail: log.faultCountToday > 0
                        ? "\(log.faultCountToday) today"
                        : (log.entries.isEmpty ? nil : "Clear today"),
                    tint: log.faultCountToday > 0 ? Theme.bad : Theme.good) { IncidentLogView() }
                row("Engineer", "wrench.and.screwdriver.fill") { EngineerSettings() }
            }

            Section {
                EmptyView()
            } footer: {
                // The quiet identifying line a tool is expected to carry: which build is on this
                // iPad, and which machine it is pointed at. Both are the first questions asked when
                // someone reports something odd from a venue.
                VStack(alignment: .leading, spacing: 3) {
                    Text("Arm Control \(Self.version)")
                    Text("Glamatic slider at \(GlamaticLink.host) · Pivot XP")
                }
                .font(.footnote)
                .foregroundStyle(Theme.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 8)
            }
        }
        .onAppear { setupCount = EventSetups.load().count }
        .confirmationDialog("Back to the booth screen?",
                            isPresented: $confirmLock,
                            titleVisibility: .visible) {
            Button("Lock to booth", role: .destructive) { kiosk.lock() }
            Button("Stay in settings", role: .cancel) {}
        } message: {
            Text("To get back into settings: tap the top-left corner three times, then enter \(kiosk.pin == Kiosk.defaultPIN ? "0485" : "your PIN").")
        }
    }

    private func row<D: View>(_ title: String,
                              _ icon: String,
                              detail: String? = nil,
                              tint: Color = Theme.secondary,
                              @ViewBuilder destination: @escaping () -> D) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack {
                Label(title, systemImage: icon)
                Spacer()
                if let detail {
                    Text(detail).foregroundStyle(tint)
                }
            }
        }
    }
}

// MARK: - Network

struct NetworkSettings: View {
    @StateObject private var link = GlamaticLink.shared
    @AppStorage(PLC.hostKey) private var host = PLC.defaultHost
    @AppStorage(PLC.asciiPortKey) private var asciiPort = 2000

    var body: some View {
        Form {
            Section {
                LabeledContent("PLC address") {
                    TextField(PLC.defaultHost, text: $host)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                LabeledContent("Trigger port") {
                    TextField("2000", value: $asciiPort, format: .number.grouping(.never))
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
            } footer: {
                Text("Wire the iPad to the arm LAN with a USB-C Ethernet adapter. Give it a static address on this subnet and leave the router field blank, so Wi-Fi stays the default route. Wi-Fi must not also be on 192.168.1.x.")
            }

            Section {
                Button {
                    Task { await link.connect() }
                } label: {
                    Label(link.connected ? "Reconnect" : "Connect", systemImage: "cable.connector")
                }
                Button(role: .destructive) {
                    link.disconnect()
                } label: {
                    DestructiveLabel("Disconnect", systemImage: "cable.connector.slash")
                }
                .disabled(!link.connected)
            } footer: {
                Text(link.status)
                    .foregroundStyle(link.connected ? Theme.good : Theme.secondary)
            }
        }
        .navigationTitle("Network")
    }
}

// MARK: - Login

struct LoginSettings: View {
    @StateObject private var link = GlamaticLink.shared
    @State private var user = ""
    @State private var pass = ""
    @State private var saved = GlamaticLink.hasCredentials

    var body: some View {
        Form {
            Section {
                LabeledContent("Username") {
                    TextField(saved ? "Saved" : "", text: $user)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                LabeledContent("Password") {
                    SecureField(saved ? "Saved" : "", text: $pass)
                        .multilineTextAlignment(.trailing)
                }
                Button {
                    GlamaticLink.setCredentials(user: user, pass: pass)
                    saved = GlamaticLink.hasCredentials
                    user = ""; pass = ""
                    Task { await link.connect() }
                } label: {
                    Label("Save login", systemImage: "key.fill")
                }
                .disabled(user.isEmpty || pass.isEmpty)
            } footer: {
                Text("Needed for telemetry, manual drive, homing and fault reset. Preset buttons do not use it. Kept in the Keychain, never logged.")
            }
        }
        .navigationTitle("PLC login")
    }
}

// MARK: - Presets

struct PresetSettings: View {
    @StateObject private var store = ProgramStore.shared
    @StateObject private var timer = MoveTimer.shared

    private var timedLabel: String {
        let n = timer.results.count
        return n == 0 ? "None timed" : "\(n) timed"
    }

    var body: some View {
        Form {
            Section {
                ForEach(store.presets) { preset in
                    HStack(spacing: 12) {
                        Text("\(preset.number)")
                            .font(.body.weight(.semibold).monospacedDigit())
                            .foregroundStyle(Theme.secondary)
                            .frame(width: 22, alignment: .leading)

                        TextField("Program \(preset.number)",
                                  text: Binding(get: { preset.label },
                                                set: { store.setLabel($0, for: preset.number) }))
                            .autocorrectionDisabled()

                        Toggle("", isOn: Binding(get: { preset.enabled },
                                                 set: { store.setEnabled($0, for: preset.number) }))
                            .labelsHidden()
                    }
                }
            } footer: {
                Text("These moves live inside the PLC — the app selects and triggers them, it cannot edit them. Naming one makes the console read “Push-in pan” instead of “Program 2”.")
            }

            Section {
                NavigationLink {
                    MoveTimingView()
                } label: {
                    HStack {
                        Label("Time the moves", systemImage: "stopwatch")
                        Spacer()
                        Text(timedLabel)
                            .foregroundStyle(MoveTimer.shared.results.isEmpty ? Theme.warn : Theme.secondary)
                    }
                }
            } footer: {
                Text("The app cannot read a program's trajectory, so how long each one takes is a guess until it has been run and watched. This measures it and sets the Traverse from the answer.")
            }
        }
        .navigationTitle("Presets")
    }
}

// MARK: - Attendant mode

struct AttendantSettings: View {
    @StateObject private var kiosk = Kiosk.shared
    @AppStorage("armcontrol.booth.countdown") private var countdown = 3
    @AppStorage("armcontrol.booth.holdResult") private var holdResult = 8.0

    @State private var newPIN = ""
    @State private var pinSaved = false
    @State private var confirmLock = false

    var body: some View {
        Form {
            Section {
                Picker("Countdown", selection: $countdown) {
                    Text("Off").tag(0)
                    ForEach(1...5, id: \.self) { Text("\($0)s").tag($0) }
                }
                ValueSlider(title: "Hold the result",
                            value: $holdResult,
                            range: 3...30,
                            format: { "\(Int($0))s" })
            } header: {
                Text("Guest flow")
            } footer: {
                Text("A failed take never auto-advances — that one needs someone to look at it.")
            }

            Section {
                Toggle("When backgrounded", isOn: $kiosk.relockOnBackground)
                Picker("When idle", selection: $kiosk.idleRelockMinutes) {
                    Text("Never").tag(0)
                    ForEach([2, 5, 10, 30], id: \.self) { Text("\($0) min").tag($0) }
                }
            } header: {
                Text("Re-lock automatically")
            } footer: {
                Text("The app starts locked on a fresh install, so settings are never left open by forgetting. “Booth” in the status bar re-locks from any tab.")
            }

            Section {
                LabeledContent("PIN") {
                    HStack {
                        TextField(kiosk.pin == Kiosk.defaultPIN ? "0485" : "••••", text: $newPIN)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 110)
                        Button("Set") {
                            kiosk.setPIN(newPIN)
                            newPIN = ""
                            pinSaved = true
                        }
                        .buttonStyle(.bordered)
                        .disabled(newPIN.filter(\.isNumber).count < 4)
                    }
                }
            } footer: {
                Text(pinSaved
                     ? "PIN updated."
                     : "Currently \(kiosk.pin == Kiosk.defaultPIN ? "0485, the same as PivotBooth" : "custom"). Four digits or more.")
                    .foregroundStyle(pinSaved ? Theme.good : Theme.secondary)
            }

            Section {
                Button {
                    confirmLock = true
                } label: {
                    Label("Lock to attendant mode", systemImage: "lock.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(Theme.warn)
                .listRowBackground(Color.clear)
            } footer: {
                Text("One screen, one button. No tabs, no jog, no PLC login.")
            }
        }
        .navigationTitle("Booth flow")
        .confirmationDialog("Lock to attendant mode?",
                            isPresented: $confirmLock,
                            titleVisibility: .visible) {
            Button("Lock", role: .destructive) { kiosk.lock() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("To get back out: tap the top-left corner three times, then enter \(kiosk.pin == Kiosk.defaultPIN ? "0485" : "your PIN").")
        }
    }
}

// MARK: - Delivery

struct DeliverySettings: View {
    @StateObject private var delivery = DeliveryServer.shared
    @StateObject private var text = TextDelivery.shared
    @AppStorage(DeliveryServer.portKey) private var port = 8787

    private var textStatus: String {
        if !text.isConfigured { return "Not set up" }
        return text.enabled ? "On" : "Off"
    }

    var body: some View {
        Form {
            Section {
                Toggle("Hand clips to guests", isOn: $delivery.enabled)
                if delivery.enabled {
                    LabeledContent("Port") {
                        TextField("8787", value: $port, format: .number.grouping(.never))
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Address", value: delivery.host ?? "none")
                    Button {
                        delivery.start()
                    } label: {
                        Label("Restart", systemImage: "arrow.clockwise")
                    }
                }
            } header: {
                Text("Delivery")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("After each take the guest screen shows a QR code. Scanning it opens the clip on their phone, served straight off this iPad — no internet, no account, nothing to upload.")
                    Text(delivery.status)
                        .foregroundStyle(delivery.running ? Theme.good : Theme.secondary)
                }
            }

            Section {
                NavigationLink {
                    TextLinkSettings()
                } label: {
                    HStack {
                        Label("Text the link", systemImage: "message")
                        Spacer()
                        Text(textStatus)
                            .font(.footnote)
                            .foregroundStyle(text.isReady ? Theme.good : Theme.secondary)
                    }
                }
            } footer: {
                Text("A second way onto the guest's phone, for when the QR will not scan — a cracked lens, a screen protector, sun on the display, or someone who walked off and came back.")
            }

            if delivery.enabled, let check = delivery.checkURL, let code = DeliveryServer.qr(for: check) {
                Section {
                    VStack(spacing: 14) {
                        Image(uiImage: code)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 200, height: 200)
                            .padding(12)
                            .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                        if let at = delivery.lastReachedAt {
                            Label("A phone reached this iPad \(at.formatted(date: .omitted, time: .standard))",
                                  systemImage: "checkmark.circle.fill")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Theme.good)
                                .multilineTextAlignment(.center)
                        } else {
                            Label("Nothing has reached this iPad yet", systemImage: "questionmark.circle")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Theme.warn)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                } header: {
                    Text("Check it before the doors open")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Scan this with a phone on the venue Wi-Fi. It takes ten seconds and it is the only way to know delivery actually works.")
                        // The reason this screen exists at all.
                        Text("Venue and guest Wi-Fi often block devices from talking to each other. When they do, the QR is perfect, the server is running, the address is right — and every phone that scans it hangs. Nothing on this iPad can see that by looking at itself; a request arriving is the only proof.")
                        Text("The code always uses the Wi-Fi address, never the wired arm network — that wire is unreachable from a phone, and a QR pointing at it would look fine and go nowhere.")
                    }
                    .font(.footnote)
                }
            }
        }
        .navigationTitle("Delivery")
    }
}

// MARK: - Engineer

struct EngineerSettings: View {
    @State private var speedResult: String?
    @State private var speedRunning = false
    @StateObject private var safety = SafetyKernel.shared
    @StateObject private var booth = BoothSettings.shared
    @StateObject private var link = GlamaticLink.shared
    @ObservedObject private var sim = GlamaticLink.shared.sim
    @State private var pruned = -1

    /// Find out whether this machine really is limited to 100 mm/s.
    ///
    /// 🔑 **The whole app is designed around a number nobody has tested.** `RampProfile` states it
    /// outright — "the Glamatic clamps velocity to 70–100 mm/s, a 1.43:1 range, far too narrow to
    /// ramp anything cinematically" — and the stored programs plainly do not obey it: program 14
    /// was measured covering 600 mm in 4.20 s, which is **143 mm/s**, from twenty-odd clean
    /// samples. So an editable copy of a stored move is stuck ~40% slower than the move it copies,
    /// and every ramp decision has been made against a ceiling that may not exist.
    ///
    /// ⚠️ This lives as a BUTTON rather than a launch argument on purpose: remote launches need the
    /// iPad unlocked at that exact instant, and it re-locks between commands. A control someone can
    /// tap works whenever they are standing there.
    private var speedCeilingSection: some View {
        Section {
            Button {
                Task { await runSpeedTest() }
            } label: {
                Label(speedRunning ? "Testing…" : "Test the speed ceiling",
                      systemImage: "speedometer")
            }
            .disabled(speedRunning || !link.connected || link.simulated)

            if let speedResult {
                Text(speedResult)
                    .font(.footnote.monospaced())
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Speed ceiling")
        } footer: {
            Text("Writes a range of speeds and reads each back. Nothing moves unless a value above 100 mm/s is accepted — then it drives 0 → 300 mm once and times the carriage.")
        }
    }

    /// ⚠️ Phase 1 moves nothing. Phase 2 moves the rail, and only when phase 1 found headroom.
    private func runSpeedTest() async {
        speedRunning = true
        defer { speedRunning = false }
        let link = GlamaticLink.shared
        link.suspendPolling()
        defer { link.resumePolling() }

        var lines: [String] = []
        var accepted: [Double] = []
        for v in [85.0, 100, 110, 120, 150, 200, 250] {
            _ = await link.write(.velocity, String(Int(v)))
            try? await Task.sleep(nanoseconds: 400_000_000)
            await link.refresh()
            let back = Double(link.state.velocity) ?? -1
            let ok = abs(back - v) < 1.5
            if ok { accepted.append(v) }
            lines.append(String(format: "%.0f → reads %.0f  %@", v, back, ok ? "OK" : "clamped"))
            GlamaticLink.plog("SPEED TEST: wrote \(Int(v)), reads \(Int(back)) — \(ok ? "ACCEPTED" : "clamped")")
        }
        _ = await link.write(.velocity, "85")

        let headroom = accepted.filter { $0 > 100 }.max()
        if let headroom, link.state.isHomed {
            lines.append("")
            lines.append("Driving 0 → 300 mm at \(Int(headroom)) mm/s…")
            speedResult = lines.joined(separator: "\n")

            _ = await link.write(.manual, "1")
            _ = await link.write(.enable, "1")
            _ = await link.write(.velocity, String(Int(headroom)))
            _ = await link.write(.position, "0")
            try? await Task.sleep(nanoseconds: 200_000_000)
            _ = await link.write(.execute, "1")
            try? await Task.sleep(nanoseconds: 300_000_000)
            _ = await link.write(.execute, "0")            // 🚨 PULSE
            for _ in 0..<40 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                await link.refresh()
                if link.state.currentMM < 3 { break }
            }

            _ = await link.write(.position, "300")
            try? await Task.sleep(nanoseconds: 200_000_000)
            _ = await link.write(.execute, "1")
            try? await Task.sleep(nanoseconds: 300_000_000)
            _ = await link.write(.execute, "0")            // 🚨 PULSE
            var started: Date?
            var arrived: Date?
            for _ in 0..<120 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                await link.refresh()
                let mm = link.state.currentMM
                if started == nil, mm > 5 { started = Date() }
                if mm >= 297 { arrived = Date(); break }
            }
            if let started, let arrived {
                let secs = arrived.timeIntervalSince(started)
                lines.append(String(format: "MEASURED %.0f mm/s (295 mm in %.2fs)", 295 / max(0.01, secs), secs))
                GlamaticLink.plog(String(format: "SPEED TEST: measured %.0f mm/s", 295 / max(0.01, secs)))
            } else {
                lines.append("Never reached 300 mm — inconclusive.")
            }
        } else if headroom != nil {
            lines.append("")
            lines.append("Accepted above 100, but the rail is not referenced — home it, then run again to measure.")
        } else {
            lines.append("")
            lines.append("Nothing above 100 mm/s was accepted. The clamp is real.")
        }

        // 🚨 Always cold.
        for tag in [GlamaticLink.Tag.execute, .executeHoming, .runProgram] {
            _ = await link.write(tag, "0")
        }
        _ = await link.write(.velocity, "85")
        _ = await link.write(.manual, "0")
        _ = await link.write(.enable, "0")
        speedResult = lines.joined(separator: "\n")
    }

    var body: some View {
        Form {
            simulatorSection
            speedCeilingSection

            Section {
                Button {
                    booth.failNextRender = true
                } label: {
                    Label(booth.failNextRender ? "The next take will fail to render" : "Fail the next render",
                          systemImage: booth.failNextRender ? "checkmark.circle.fill" : "exclamationmark.arrow.triangle.2.circlepath")
                        .foregroundStyle(booth.failNextRender ? Theme.warn : Theme.accent)
                }
                .disabled(booth.failNextRender)
            } footer: {
                // A button rather than a toggle on purpose: it is a one-shot, and a switch left on
                // is exactly the kind of thing that gets forgotten before an event.
                Text("Runs the take normally, then fails the export. Use it to see what an attendant sees when a render falls over — the footage is kept and the failure screen offers to build the clip again without re-posing the guest. Clears itself after one take.")
            }

            Section {
                Toggle("Allow presets without telemetry", isOn: $safety.allowBlindTrigger)
            } footer: {
                Text("Preset triggers need no login, so they still work when the web session is down. Off by default: with no telemetry there is no homed or fault readout, so the operator is flying blind.")
            }

            if let halt = safety.lastHalt {
                Section("Last halt") {
                    Text(halt).foregroundStyle(Theme.warn)
                }
            }

            Section {
                LabeledContent("Free space") {
                    Text(Storage.freeDescription)
                        .foregroundStyle(Storage.isLow ? Theme.bad : Theme.secondary)
                }
                Button {
                    pruned = Storage.prune()
                } label: {
                    Label("Clear old take files", systemImage: "trash")
                }
            } header: {
                Text("Storage")
            } footer: {
                Text(pruned >= 0
                     ? "Removed \(pruned) file\(pruned == 1 ? "" : "s")."
                     : "Each take writes a raw pass and a finished clip. The newest \(Storage.keepFiles) are kept automatically after every take; this clears them now. A take is refused below \(ByteCountFormatter.string(fromByteCount: Storage.minimumFreeBytes, countStyle: .file)) free rather than failing halfway through.")
            }

            Section {
                NavigationLink {
                    SoakView()
                } label: {
                    HStack {
                        Label("Link soak", systemImage: "timer")
                        Spacer()
                        if let r = LinkSoak.shared.last {
                            Text(r.shortLabel)
                                .foregroundStyle(r.clean ? Theme.good : Theme.warn)
                        } else {
                            Text("Never run").foregroundStyle(Theme.warn)
                        }
                    }
                }
            } header: {
                Text("Endurance")
            } footer: {
                Text("The link surviving a whole evening is the one thing about this app that hardware alone can prove. This measures it instead of leaving it to be noticed.")
            }

            Section {
                LabeledContent("Trace", value: "Documents/glamatic.log")
            } footer: {
                Text("Pull it over USB with devicectl. The arm network has no internet, so the local file is the only visibility path.")
            }
        }
        .navigationTitle("Engineer")
    }

    // MARK: Simulated rail

    private var simulatorSection: some View {
        Section {
            Toggle("Simulated rail", isOn: $link.simulated)

            if link.simulated {
                ValueSlider(title: "Program throw",
                            value: $sim.throwMM,
                            range: 50...600, step: 10,
                            format: { "\(Int($0)) mm" })

                ValueSlider(title: "Program speed",
                            value: $sim.programVelocity,
                            range: PLC.velocityRange, step: 1,
                            format: { "\(Int($0)) mm/s" })

                LabeledContent("Out and back") {
                    Text(String(format: "%.1fs", sim.roundTripSeconds))
                        .monospacedDigit()
                        .foregroundStyle(Theme.accent)
                }

                Button {
                    sim.injectFault()
                } label: {
                    Label("Inject a fault", systemImage: "exclamationmark.triangle.fill")
                }
                .tint(Theme.warn)

                Button(role: .destructive) {
                    sim.powerCycle()
                } label: {
                    DestructiveLabel("Simulate a power cycle", systemImage: "powerplug.fill")
                }
            }
        } header: {
            Text("Simulated rail")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Runs the whole booth loop with no hardware: connect, home, trigger, move. It refuses commands for the same reasons the PLC does — not homed, not armed, faulted — and a power cycle loses homing, exactly like the real one.")
                if link.simulated {
                    Text("A badge reads SIMULATED on every screen, including the guest-facing one, while this is on.")
                        .foregroundStyle(Theme.warn)
                    Text(String(format: "Note the round trip is %.1fs at these settings. If that is longer than your Traverse in Capture, a take only records part of the move — and the ramp profile timings assume the whole thing.", sim.roundTripSeconds))
                        .foregroundStyle(Theme.warn)
                }
            }
        }
    }
}
