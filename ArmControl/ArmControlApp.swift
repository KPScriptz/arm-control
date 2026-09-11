import SwiftUI

@main
struct ArmControlApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var safety = SafetyKernel.shared
    @StateObject private var kiosk = Kiosk.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
                // Only does anything when launched with `-armcontrol.diag read|nudge` from devicectl.
                .task { await ArmDiagnostic.runIfRequested() }
        }
        .onChange(of: scenePhase) { _, phase in
            // Nothing is watching the rail when this app is not on screen. Drop the gate.
            safety.handleScenePhase(phase)
            // And an iPad picked up from another app should show the booth, not the settings.
            kiosk.handleScenePhase(phase)
        }
    }
}
