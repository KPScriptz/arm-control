import AVFoundation
import SwiftUI

/// The take: fire a stored program and record the traverse at 120fps, in one action.
///
/// Recording and triggering start together rather than in sequence. The PLC gives no "program
/// finished" signal, so the take is timed from the traverse duration set here — and a recording
/// that starts after the trigger has already lost the first frames of the move.
struct CaptureView: View {
    @StateObject private var recorder = Recorder.shared
    @StateObject private var safety = SafetyKernel.shared
    @StateObject private var store = ProgramStore.shared
    @StateObject private var timer = MoveTimer.shared

    @AppStorage("armcontrol.take.program") private var program = 1
    @AppStorage("armcontrol.take.seconds") private var seconds = 6.0
    @AppStorage("armcontrol.take.leadIn") private var leadIn = 0.3

    @State private var running = false
    @State private var note: String?
    @State private var screenHeight: Double = 0

    /// The preview is what an operator frames the shot in, so it gets the room. A fixed 300pt panel
    /// on a portrait 13-inch iPad left a third of the screen to the picture and half of it to black.
    private var previewHeight: Double {
        screenHeight > 0 ? min(620, max(280, screenHeight * 0.42)) : 300
    }

    private var isHighSpeed: Bool { recorder.activeFPS >= 120 }

    private var traverseFootnote: String {
        guard let m = timer.results[program] else {
            return "How long to record. The rail gives no finished signal, so this is what ends the take — and until the program has been timed under Presets → Time the moves, it is a guess."
        }
        return String(format: "Program %d was measured at %.1fs of movement after a %.1fs start delay, so %.1fs covers it.",
                      program, m.duration, m.latency, m.recommendedTraverse)
    }

    var body: some View {
        Form {
            Section {
                ZStack {
                    if recorder.synthetic {
                        Rectangle()
                            .fill(Theme.card)
                            .frame(height: previewHeight)
                            .overlay {
                                ContentUnavailableView("Simulated camera",
                                                       systemImage: "wrench.and.screwdriver.fill",
                                                       description: Text("Takes are generated as a moving test pattern. No camera on this device."))
                            }
                    } else if recorder.isRunning {
                        CameraPreview(session: recorder.session)
                            .frame(height: previewHeight)
                    } else {
                        Rectangle()
                            .fill(Theme.card)
                            .frame(height: previewHeight)
                            .overlay {
                                ContentUnavailableView(recorder.status,
                                                       systemImage: "video.slash")
                            }
                    }
                    if recorder.isRecording {
                        Rectangle()
                            .strokeBorder(Theme.bad, lineWidth: 5)
                            .frame(height: previewHeight)
                    }
                }
                .listRowInsets(EdgeInsets())
            }

            Section {
                LabeledContent("Frame rate") {
                    HStack(spacing: 6) {
                        Image(systemName: isHighSpeed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(isHighSpeed ? Theme.good : Theme.warn)
                        Text(recorder.activeFPS > 0 ? "\(Int(recorder.activeFPS)) fps" : "Not locked")
                            .monospacedDigit()
                    }
                }

                if !recorder.availableFPS.isEmpty {
                    Picker("Record at", selection: Binding(
                        get: { recorder.desiredFPS },
                        set: { recorder.setDesiredFPS($0) })) {
                        ForEach(recorder.availableFPS.filter { $0 >= 30 }, id: \.self) { f in
                            Text("\(Int(f))").tag(f)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if recorder.activeSize != .zero {
                    LabeledContent("Resolution",
                                   value: "\(Int(recorder.activeSize.width))×\(Int(recorder.activeSize.height))")
                }
            } header: {
                Text("Capture")
            } footer: {
                Text(isHighSpeed
                     ? "120fps onto a 30fps timeline is 4× slow motion with one real frame per output frame — no duplication."
                     : "Below 120fps the ramp has to repeat frames to fill a 4× pass. Shoot 120 if the camera offers it.")
                    .foregroundStyle(isHighSpeed ? Theme.secondary : Theme.warn)
            }

            Section {
                Picker("Program", selection: $program) {
                    ForEach(store.visible) { p in Text(p.display).tag(p.number) }
                }

                ValueSlider(title: "Traverse",
                            value: $seconds,
                            range: 2...20,
                            step: 0.5,
                            format: { String(format: "%.1fs", $0) },
                            footnote: traverseFootnote)

                // Only appears once the program has actually been timed. The measurement is the
                // whole reason this number stops being a guess, so it gets a one-tap apply here as
                // well as in Pre-flight.
                if let m = timer.results[program], abs(seconds - m.recommendedTraverse) > 0.01 {
                    Button {
                        seconds = m.recommendedTraverse
                    } label: {
                        Label(String(format: "Use the measured %.1fs", m.recommendedTraverse),
                              systemImage: "stopwatch")
                    }
                }

                ValueSlider(title: "Lead-in",
                            value: $leadIn,
                            range: 0...1.5,
                            step: 0.05,
                            format: { String(format: "%.2fs", $0) },
                            footnote: "Rolls the camera this long before the trigger, so the first frames of the move are never missed.")
            } header: {
                Text("Take")
            }

            Section {
                Button(action: runTake) {
                    Label(running ? "Recording…" : "Run take",
                          systemImage: running ? "record.circle.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .listRowBackground(Color.clear)
                .disabled(running || !recorder.isRunning || !safety.canTriggerProgram)
            } footer: {
                if !safety.canTriggerProgram, let b = safety.blocker {
                    Text(b.message).foregroundStyle(Theme.warn)
                } else if let note {
                    Text(note)
                }
            }
        }
        .background {
            GeometryReader { geo in
                Color.clear.preference(key: SizeKey.self, value: geo.size)
            }
        }
        .onPreferenceChange(SizeKey.self) { screenHeight = $0.height }
        .task { await recorder.start() }
        .onDisappear { recorder.stop() }
    }

    /// Runs the SAME sequence the attendant screen does — via TakeRunner — but stops at the raw
    /// clip. This tab is where the take gets dialled in; Post is where the ramp is judged.
    private func runTake() {
        running = true
        note = nil
        Task {
            let runner = TakeRunner.shared
            await runner.run(countdownFrom: 0,
                             program: program,
                             traverse: seconds,
                             leadIn: leadIn,
                             render: false)

            switch runner.phase {
            case .done(let url):
                let d = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
                note = String(format: "Take saved · %.2fs at %dfps%@ — open Post to ramp it.",
                              d, Int(recorder.activeFPS),
                              runner.armWarning == nil ? "" : " · \(runner.armWarning!)")
            case .failed(let m):
                note = m
            default:
                note = nil
            }
            runner.reset()
            running = false
        }
    }
}
