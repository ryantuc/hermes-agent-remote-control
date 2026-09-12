import SwiftUI
import WidgetKit

/// The extension's entry point: one Live Activity widget, for the Lock Screen and the Dynamic Island only.
@main
struct HermesLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        HermesLiveActivityWidget()
    }
}
