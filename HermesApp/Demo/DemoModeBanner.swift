import SwiftUI

/// The demo's persistent marker: a row above every screen for as long as the demo runs, carrying the way out.
@MainActor
struct DemoModeBanner: View {
    @Environment(\.hermes) private var t

    /// Leaves the demo and lands on the real connect flow.
    let onExit: () -> Void

    static let title = "DEMO · not connected"
    static let exitLabel = "Exit"
    /// The identifier the marker test looks for.
    static let accessibilityIdentifier = "demo.banner"
    /// One hit target tall, and no taller: this row is a permanent tax on every screen.
    static let height: CGFloat = Hit.min

    var body: some View {
        HStack(spacing: Space.s4) {
            Image(systemName: "play.rectangle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(t.warn)
                .accessibilityHidden(true)

            Text(Self.title)
                .font(HermesFont.calloutStrong)
                .foregroundStyle(t.text1)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Spacer(minLength: Space.s4)

            Button(Self.exitLabel, action: onExit)
                .font(HermesFont.calloutStrong)
                .foregroundStyle(t.action)
                .buttonStyle(.plain)
                .lineLimit(1)
                // The one thing in the row that never yields; otherwise the title takes the width and the way out truncates.
                .fixedSize(horizontal: true, vertical: false)
                .frame(minHeight: Hit.min)
                .accessibilityIdentifier("demo.exit")
        }
        .padding(.horizontal, Space.s6)
        .frame(maxWidth: .infinity, minHeight: Self.height, alignment: .leading)
        // BUG-118: opaque in two coats, because `warnFill` alone is a 14 % wash the translucent navigation bar reads through.
        .background(t.warnFill.background(t.canvas))
        .hairline()
        .accessibilityIdentifier(Self.accessibilityIdentifier)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Demo mode. Not connected to a backend.")
    }
}

/// The App Store capture flag, which lets screenshots be taken off the demo transcript without the marker row; DEBUG only.
enum DemoCaptureFlags {
    /// `-hermesHideDemoBanner`. Always false outside DEBUG.
    static var hidesDemoBanner: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-hermesHideDemoBanner")
        #else
        return false
        #endif
    }
}

/// The canvas under the demo marker, carried up under the status bar.
private struct DemoMarkerGround: View {
    @Environment(\.hermes) private var t

    var body: some View {
        t.canvas.ignoresSafeArea(.container, edges: .top)
    }
}

extension View {
    /// Attach the demo marker above everything, for as long as the demo runs.
    ///
    /// A `VStack`, not `safeAreaInset(edge: .top)`: a `UINavigationBar` positions itself against the top of the whole screen and would render inside the inset band.
    ///
    /// The hub's scrim, drawer and rail must not `ignoresSafeArea()` on the top edge or they paint back over this row.
    @ViewBuilder
    func demoModeMarker(isActive: Bool, onExit: @escaping () -> Void) -> some View {
        if isActive && !DemoCaptureFlags.hidesDemoBanner {
            VStack(spacing: 0) {
                DemoModeBanner(onExit: onExit)
                    // The conversation draws its transcript past its scroll view's edges so it can pass behind the glass chrome, and a later sibling in a stack draws over an earlier one. Raised, and grounded up under the status bar, so that overflow can reach neither this row nor the clock above it.
                    .background { DemoMarkerGround() }
                    .zIndex(1)
                self
            }
        } else {
            self
        }
    }
}
