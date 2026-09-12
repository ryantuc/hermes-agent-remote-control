import SwiftUI

@main
@MainActor
struct HermesMobileApp: App {
    /// The single root model; the gateway connection, the turn engine and the per-thread chat models all hang off it.
    @State private var app = AppModel()

    /// The design-system theme: owns the live skin and the client-local polarity, and hands resolved tokens down through `HermesThemeContainer`.
    @State private var theme = Theme()

    init() {
        ApprovalNotifications.install()
        // BUG-070: installed before the app finishes launching, because the island's Deny carries `openAppWhenRun: false` and would otherwise find no handler during a cold launch.
        LiveActivityController.shared.installBridge()
    }

    var body: some Scene {
        WindowGroup {
            HermesThemeContainer(theme: theme) {
                RootView()
            }
            .environment(app)
            .environment(theme)
            .task {
                app.theme = theme
                // Also adopts and ends any card that outlived a previous launch, since an activity survives the app being killed.
                LiveActivityController.shared.install(app: app)
            }
        }
    }
}
