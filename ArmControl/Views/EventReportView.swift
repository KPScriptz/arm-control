import SwiftUI

/// The night, on one page, ready to send.
struct EventReportView: View {
    @StateObject private var takes = TakeLog.shared
    @StateObject private var incidents = IncidentLog.shared

    /// Rebuilt on appear rather than on every body evaluation — it walks four logs, and a
    /// `ScrollView` asks for its content more often than anyone expects.
    @State private var body_ = ""
    @State private var file: URL?

    var body: some View {
        ScrollView {
            Text(body_)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
        }
        .background(Theme.grouped)
        .navigationTitle("Event report")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if let file {
                    ShareLink(item: file) { Image(systemName: "square.and.arrow.up") }
                }
            }
        }
        .onAppear(perform: rebuild)
        // The report is a snapshot of a live event: a take finishing while it is open should show
        // up, not require backing out and coming in again.
        .onChange(of: takes.entries.count) { rebuild() }
        .onChange(of: incidents.entries.count) { rebuild() }
    }

    private func rebuild() {
        body_ = EventReport.text()
        file = try? EventReport.file()
    }
}
