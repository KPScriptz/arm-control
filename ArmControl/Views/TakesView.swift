import SwiftUI

/// Tonight's takes, newest first, so a guest whose scan failed can be handed their clip again.
struct TakesView: View {
    @StateObject private var log = TakeLog.shared
    @StateObject private var thumbs = ThumbnailCache.shared
    @State private var confirmClear = false

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        Group {
            if log.entries.isEmpty {
                ContentUnavailableView("No takes yet",
                                       systemImage: "film.stack",
                                       description: Text("Finished takes are listed here so one can be found again when a guest's scan doesn't take."))
            } else {
                List {
                    Section {
                        LabeledContent("Tonight", value: log.todaySummary)
                        if log.todayWithWarnings > 0 {
                            Label("\(log.todayWithWarnings) had something wrong — open one to see what.",
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(Theme.warn)
                        }
                    }

                    Section {
                        ForEach(log.entries) { entry in
                            // A push, not a sheet: every other detail in this app is a drill-down,
                            // and the back button is where an operator already looks for it.
                            NavigationLink { TakeDetail(entry: entry) } label: { row(entry) }
                                .contextMenu {
                                    if entry.isAvailable {
                                        ShareLink(item: entry.url) {
                                            Label("Share the clip", systemImage: "square.and.arrow.up")
                                        }
                                    }
                                }
                        }
                    } header: {
                        Text("All takes")
                    } footer: {
                        Text("The newest \(Storage.keepFiles) clips are kept on this iPad. Older ones are pruned to keep space for the next take, but every finished take was also saved to Photos.")
                    }
                }
            }
        }
        .navigationTitle("Takes")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) { confirmClear = true } label: {
                    // Toolbar buttons keep the app tint even with a destructive role, so a bin
                    // renders MINT — the colour this app uses for GO. Same trap as DestructiveLabel.
                    Image(systemName: "trash").foregroundStyle(Theme.bad)
                }
                .disabled(log.entries.isEmpty)
            }
        }
        .confirmationDialog("Clear the take list?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { log.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This only clears the list. The clips themselves stay in Photos.")
        }
    }

    private func row(_ entry: TakeLog.Entry) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.fill)
                if let image = thumbs.image(for: entry) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else if !entry.isAvailable {
                    Image(systemName: "icloud.slash")
                        .font(.caption)
                        .foregroundStyle(Theme.tertiary)
                }
            }
            .frame(width: 48, height: 74)

            VStack(alignment: .leading, spacing: 3) {
                Text(Self.time.string(from: entry.at))
                    .font(.body.weight(.medium).monospacedDigit())
                Text(entry.programName)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondary)
                if let warning = entry.warning {
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(Theme.warn)
                        .lineLimit(2)
                } else if !entry.isAvailable {
                    Text("No longer on this iPad — it's in Photos")
                        .font(.caption)
                        .foregroundStyle(Theme.tertiary)
                }
            }

            Spacer(minLength: 8)

            Text(String(format: "%.1fs", entry.duration))
                .font(.footnote.monospacedDigit())
                .foregroundStyle(Theme.tertiary)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.tertiary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Detail

/// One take, big enough to hand back to a guest: the QR at scanning size, and Share for everything
/// else.
private struct TakeDetail: View {
    let entry: TakeLog.Entry
    @State private var link: URL?

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                    if entry.isAvailable {
                        if let link, let code = DeliveryServer.qr(for: link) {
                            Image(uiImage: code)
                                .interpolation(.none)
                                .resizable()
                                .frame(width: 260, height: 260)
                                .padding(16)
                                .background(.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))

                            Text("Scan to keep it")
                                .font(.title3.weight(.semibold))
                            Text("The guest's phone must be on the same Wi-Fi as this iPad.")
                                .font(.footnote)
                                .foregroundStyle(Theme.secondary)
                                .multilineTextAlignment(.center)
                        } else {
                            // Honest about why there is no code, rather than an empty white square.
                            ContentUnavailableView("No QR for this one",
                                                   systemImage: "wifi.slash",
                                                   description: Text("Delivery is off, or this iPad has no Wi-Fi address to put in the code. Share it instead."))
                        }

                        ShareLink(item: entry.url) {
                            Label("Share the clip", systemImage: "square.and.arrow.up")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .frame(height: 54)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.roundedRectangle(radius: Theme.controlRadius))
                    } else {
                        ContentUnavailableView("This clip has been pruned",
                                               systemImage: "externaldrive.badge.xmark",
                                               description: Text("Only the newest \(Storage.keepFiles) takes stay on the iPad. It was saved to Photos when it finished — find it there by time."))
                    }

                    if let warning = entry.warning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(Theme.warn)
                            .multilineTextAlignment(.leading)
                    }
            }
            .padding(24)
        }
        .navigationTitle(entry.at.formatted(date: .omitted, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Re-published rather than storing the original token: tokens are capped at 40 and a
            // busy evening rolls straight past that, so a stored link would 404 exactly when
            // somebody needed it.
            guard entry.isAvailable else { return }
            link = DeliveryServer.shared.publish(entry.url)
        }
    }
}
