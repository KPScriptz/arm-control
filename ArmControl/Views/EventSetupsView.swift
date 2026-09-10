import SwiftUI
import UniformTypeIdentifiers

/// Save the booth you have, switch to another one, or hand it to a second iPad.
struct EventSetupsView: View {
    @StateObject private var booth = BoothSettings.shared
    @StateObject private var store = ProgramStore.shared

    @State private var setups: [EventSetup] = []
    @State private var newName = ""
    @State private var applying: UUID?
    @State private var confirmApply: EventSetup?
    @State private var showImporter = false
    @State private var note: String?

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Name this setup", text: $newName)
                        .autocorrectionDisabled()
                    Button("Save") {
                        let setup = EventSetups.capture(named: newName.trimmingCharacters(in: .whitespaces))
                        EventSetups.save(setup)
                        newName = ""
                        note = "Saved “\(setup.name)”."
                        reload()
                    }
                    .buttonStyle(.bordered)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Save the booth as it is now")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Captures the program and traverse, the ramp profile and end card, the preset names, the measured move timings, the PLC address, delivery and the PIN.")
                    // Said plainly, because the alternative is someone assuming it round-trips.
                    Text("The PLC username and password are NOT included. They stay in the Keychain — a setup file gets AirDropped and emailed, and a machine login has no business travelling inside one. Type those two fields once on the new iPad.")
                        .foregroundStyle(Theme.warn)
                }
            }

            if setups.isEmpty {
                Section {
                    ContentUnavailableView("No saved setups",
                                           systemImage: "square.stack.3d.up.slash",
                                           description: Text("Save one before an event and a replacement iPad is four taps away instead of twenty minutes of retyping."))
                }
            } else {
                Section("Saved") {
                    ForEach(setups) { setup in
                        row(setup)
                            // Swipe to delete and a long-press menu, rather than buttons parked in
                            // the row. This is how a List behaves everywhere else on the system, so
                            // it is where an operator's thumb goes without being told.
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    EventSetups.delete(setup)
                                    reload()
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .contextMenu {
                                if let file = EventSetups.exportFile(for: setup) {
                                    ShareLink(item: file) {
                                        Label("Share", systemImage: "square.and.arrow.up")
                                    }
                                }
                                Button(role: .destructive) {
                                    EventSetups.delete(setup)
                                    reload()
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }
            }

            Section {
                Button {
                    showImporter = true
                } label: {
                    Label("Import a setup file", systemImage: "square.and.arrow.down")
                }
            } footer: {
                if let note {
                    Text(note).foregroundStyle(Theme.good)
                } else {
                    Text("Setups are ordinary files. AirDrop one to a second iPad, or keep one in the case with the rail.")
                }
            }
        }
        .navigationTitle("Event setups")
        .onAppear(perform: reload)
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.data, .json]) { result in
            switch result {
            case .success(let url):
                if let imported = EventSetups.importFile(at: url) {
                    note = "Imported “\(imported.name)”. Apply it to use it."
                    reload()
                } else {
                    note = nil
                }
            case .failure:
                note = nil
            }
        }
        // Applying overwrites everything on this iPad, so it asks — the one time it would be wrong
        // to ask is mid-event, and this screen is not reachable mid-event.
        .confirmationDialog(confirmApply.map { "Switch the booth to “\($0.name)”?" } ?? "",
                            isPresented: Binding(get: { confirmApply != nil },
                                                 set: { if !$0 { confirmApply = nil } }),
                            titleVisibility: .visible) {
            Button("Apply", role: .destructive) {
                if let s = confirmApply { apply(s) }
                confirmApply = nil
            }
            Button("Cancel", role: .cancel) { confirmApply = nil }
        } message: {
            Text("This replaces the program, traverse, ramp profile, end card, preset names, PLC address, delivery settings and PIN currently on this iPad.")
        }
    }

    // MARK: Row

    private func row(_ setup: EventSetup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(setup.name.isEmpty ? "Untitled" : setup.name)
                        .font(.body.weight(.medium))
                    Text(setup.summary)
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                    Text(setup.savedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(Theme.tertiary)
                }
                Spacer(minLength: 8)
                if applying == setup.id {
                    ProgressView()
                } else {
                    Button("Apply") { confirmApply = setup }
                        .buttonStyle(.bordered)
                }
            }

            // Share stays visible: handing a setup to a second iPad is the point of the screen, and
            // hiding the only route to it behind a long press would be clever rather than usable.
            if let file = EventSetups.exportFile(for: setup) {
                ShareLink(item: file) {
                    Label("Share this setup", systemImage: "square.and.arrow.up")
                        .font(.footnote)
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: Actions

    private func reload() { setups = EventSetups.load() }

    private func apply(_ setup: EventSetup) {
        applying = setup.id
        EventSetups.apply(setup)
        applying = nil
        note = "Applied “\(setup.name)”."
    }
}
