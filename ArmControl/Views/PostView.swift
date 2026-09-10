import AVKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Post-production: turn a raw constant-speed rail pass into the delivered clip.
///
/// Kept to four decisions — what to ramp, which profile, what card, go. The profile's internals
/// live one level down; they matter when you are tuning and are noise the rest of the time.
struct PostView: View {
    @StateObject private var booth = BoothSettings.shared

    @State private var sourceURL: URL?
    @State private var sourceDuration: Double = 0
    @State private var output: URL?
    @State private var stage: String?
    @State private var error: String?
    @State private var rendering = false

    /// True only when the loaded clip came from a take this app just recorded — which is the only
    /// case where the profile's dead-head skip describes the footage.
    @State private var sourceIsTake = false
    @State private var clipReport: ClipInspector.Report?
    @State private var showVideoPicker = false
    @State private var showCardPicker = false
    @State private var photoItem: PhotosPickerItem?

    /// What will actually be rendered: the chosen profile rescaled onto the take that was loaded.
    /// Showing the authored numbers instead would mean the screen disagrees with the output.
    private var profile: RampProfile {
        var base = booth.profile
        // ⚠️ The dead-head skip describes a clip THIS APP recorded — the lead-in it rolled plus the
        // program's measured trigger latency. An imported file has neither, so applying it would
        // quietly cut most of a second off someone's reference footage and shift the whole ramp.
        if !sourceIsTake { base.sourceOffset = nil }
        return sourceDuration > 0.1 ? base.fitted(to: sourceDuration) : base
    }
    private var tooShort: Bool {
        sourceURL != nil && sourceDuration + 0.05 < profile.requiredSourceDuration
    }

    var body: some View {
        Form {
            sourceSection
            profileSection
            endCardSection
            renderSection
            if let output { resultSection(output) }
        }
        .fileImporter(isPresented: $showVideoPicker,
                      allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie]) { handleVideoPick($0) }
        .fileImporter(isPresented: $showCardPicker,
                      allowedContentTypes: [.image]) { handleCardPick($0) }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await loadFromPhotos(item) }
        }
    }

    // MARK: Source

    private var sourceSection: some View {
        Section {
            if let sourceURL {
                LabeledContent {
                    Text(String(format: "%.2fs", sourceDuration))
                        .monospacedDigit()
                        .foregroundStyle(tooShort ? Theme.bad : Theme.secondary)
                } label: {
                    Label(sourceURL.lastPathComponent, systemImage: "film")
                        .lineLimit(1)
                }
            }

            if Recorder.shared.lastRecording != nil {
                Button { useLastTake() } label: {
                    Label("Use last take", systemImage: "clock.arrow.circlepath")
                }
            }
            PhotosPicker(selection: $photoItem, matching: .videos) {
                Label("Choose from Photos", systemImage: "photo.on.rectangle")
            }
            Button { showVideoPicker = true } label: {
                Label("Choose from Files", systemImage: "folder")
            }
        } header: {
            Text("Raw pass")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if tooShort {
                    Text(String(format: "Too short — this profile needs %.2fs.", profile.requiredSourceDuration))
                        .foregroundStyle(Theme.bad)
                } else {
                    Text("The rail travels at one constant speed. The ramp happens here.")
                }
                if let r = clipReport { frameVerdict(r) }
            }
        }
    }

    /// What the file actually contains, counted rather than assumed.
    ///
    /// The frame rate a camera reports is the rate it LOCKED. This is the rate it delivered — and
    /// the gap between them is a clip that still plays fine and is no longer clean slow-motion
    /// material. Worth knowing before spending a render on it.
    @ViewBuilder
    private func frameVerdict(_ r: ClipInspector.Report) -> some View {
        let want = Recorder.shared.desiredFPS
        let clean = r.isClean(against: want)
        let ceiling = max(1, r.deliveredFPS / 30)
        Text(clean
             ? String(format: "%d frames · %.0f fps delivered — every frame the ramp needs is real.",
                      r.frames, r.deliveredFPS)
             // A shortfall on OUR take is a fault worth naming. On an imported clip it is simply
             // what that footage is, and calling it "missing" would be an accusation about someone
             // else's file.
             : sourceIsTake
               ? String(format: "%d frames · only %.0f fps of the %.0f asked for. %d%% never arrived, so slowing past %.1f× has to repeat frames.",
                        r.frames, r.deliveredFPS, want,
                        Int((r.shortfall(against: want) * 100).rounded()), ceiling)
               : String(format: "%d frames · %.0f fps material. Slowing past %.1f× has to repeat frames.",
                        r.frames, r.deliveredFPS, ceiling))
            .foregroundStyle(clean ? Theme.secondary : Theme.warn)
    }

    // MARK: Profile

    private var profileSection: some View {
        Section {
            NavigationLink {
                RampProfileSettings()
            } label: {
                LabeledContent {
                    // The delivered length, not the authored one: with no end card loaded the
                    // profile's own total counts a card that never gets appended.
                    Text(String(format: "%.1fs",
                                profile.deliveredDuration(hasEndCard: booth.endCard != nil)))
                        .monospacedDigit()
                } label: {
                    Label(profile.name, systemImage: "wand.and.rays")
                }
            }
        } header: {
            Text("Ramp profile")
        } footer: {
            if !profile.overBudgetPasses.isEmpty {
                Text("A pass asks for more slow motion than \(Int(profile.sourceFPS))fps can pay for.")
                    .foregroundStyle(Theme.bad)
            }
        }
    }

    // MARK: End card

    private var endCardSection: some View {
        Section {
            HStack(spacing: 14) {
                if let card = booth.endCard {
                    Image(uiImage: card)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                Button { showCardPicker = true } label: {
                    Label(booth.endCard == nil ? "Choose end card" : "Replace", systemImage: "photo")
                }
                if booth.endCard != nil {
                    Spacer()
                    Button(role: .destructive) { booth.setEndCard(nil) } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.bad)
                }
            }
        } header: {
            Text("End card")
        } footer: {
            Text(booth.endCard == nil
                 ? "Optional. Without one the clip ends on the last pass."
                 : String(format: "Holds %.1fs, aspect-fit.", profile.endCardDuration))
        }
    }

    // MARK: Render

    private var renderSection: some View {
        Section {
            Button(action: render) {
                Label(rendering ? (stage ?? "Rendering…") : "Render",
                      systemImage: rendering ? "hourglass" : "wand.and.rays")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .listRowBackground(Color.clear)
            .disabled(sourceURL == nil || rendering || tooShort)
        } footer: {
            if let error {
                Text(error).foregroundStyle(Theme.bad)
            }
        }
    }

    private func resultSection(_ url: URL) -> some View {
        Section {
            VideoPlayer(player: AVPlayer(url: url))
                .frame(height: 420)
                .listRowInsets(EdgeInsets())
            ShareLink(item: url) {
                Label("Share or save", systemImage: "square.and.arrow.up")
            }
        } header: {
            Text("Result")
        }
    }

    // MARK: Loading

    private func loadFromPhotos(_ item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                error = "Could not read that video from Photos."
                return
            }
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("source-\(UUID().uuidString).mp4")
            try data.write(to: dest)
            await adopt(dest)
        } catch {
            self.error = "Could not read that video: \(error.localizedDescription)"
        }
    }

    private func handleVideoPick(_ result: Result<URL, Error>) {
        switch result {
        case .success(let picked):
            // A security-scoped file can go out of scope mid-render, so copy it in first.
            let needsStop = picked.startAccessingSecurityScopedResource()
            defer { if needsStop { picked.stopAccessingSecurityScopedResource() } }
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("source-\(UUID().uuidString).\(picked.pathExtension)")
            do {
                try FileManager.default.copyItem(at: picked, to: dest)
                Task { await adopt(dest) }
            } catch {
                self.error = "Could not read that clip: \(error.localizedDescription)"
            }
        case .failure(let e):
            error = e.localizedDescription
        }
    }

    private func handleCardPick(_ result: Result<URL, Error>) {
        switch result {
        case .success(let picked):
            let needsStop = picked.startAccessingSecurityScopedResource()
            defer { if needsStop { picked.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: picked), let img = UIImage(data: data) {
                booth.setEndCard(img)
            } else {
                error = "Could not read that image."
            }
        case .failure(let e):
            error = e.localizedDescription
        }
    }

    private func useLastTake() {
        guard let url = Recorder.shared.lastRecording else { return }
        Task { await adopt(url, isTake: true) }
    }

    private func adopt(_ url: URL, isTake: Bool = false) async {
        sourceURL = url
        sourceIsTake = isTake
        output = nil
        error = nil
        clipReport = nil
        sourceDuration = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
        clipReport = await ClipInspector.inspect(url)
    }

    private func render() {
        guard let sourceURL else { return }
        rendering = true
        error = nil
        output = nil
        let p = profile
        let card = booth.endCard
        Task {
            do {
                output = try await RampRenderer.render(source: sourceURL,
                                                       profile: p,
                                                       endCard: card,
                                                       progress: { s in
                    Task { @MainActor in stage = s }
                })
            } catch {
                self.error = error.localizedDescription
            }
            stage = nil
            rendering = false
        }
    }
}
