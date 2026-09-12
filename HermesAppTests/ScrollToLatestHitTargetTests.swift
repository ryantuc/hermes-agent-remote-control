import SwiftUI
import UIKit
import XCTest

@testable import HermesMobile

/// BUG-033 — the transcript's "Scroll to latest" overlay was a bare `Button`
/// whose interactive region was the 30 pt glyph itself: ~30 x 30 pt against
/// `Hit.min` = 44, the token whose own comment reads "Never smaller. No
/// exceptions." Every other icon-only control in the app is wrapped in
/// `IconButtonStyle`, which frames the label to 44 x 44 and sets a rectangular
/// `contentShape`; this one overlay opted out, so a thumb aimed at the ring
/// around the arrow hit nothing.
///
/// **Why the ideal size is the hit target here.** The control lives in
/// `.overlay(alignment: .bottomTrailing)`, and an overlay hands its child the
/// child's own ideal size — nothing stretches it. So the size the hosting
/// controller reports for `ScrollToLatestButton` on its own is the size the
/// button gets in `ChatView`, and that is the region a tap can land in. The
/// two paddings live *outside* the control in `ChatView` and are deliberately
/// not measured here: padding around a button is not part of its hit target.
///
/// This is not a scroll test. It never mounts a transcript, never raises the
/// keyboard and never drives the off-tail path — that path is BUG-016's
/// instrument and is documented as per-simulator flaky.
@MainActor
final class ScrollToLatestHitTargetTests: XCTestCase {

    func testOverlayButtonFrameMeetsHitMin() {
        let host = UIHostingController(rootView: AnyView(ScrollToLatestButton {}))
        host.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 400))
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()

        let size = host.sizeThatFits(in: CGSize(width: 390, height: 400))

        XCTAssertGreaterThanOrEqual(
            size.width,
            Hit.min,
            "Scroll to latest is \(size.width) pt wide; Hit.min is \(Hit.min) and the token says never smaller"
        )
        XCTAssertGreaterThanOrEqual(
            size.height,
            Hit.min,
            "Scroll to latest is \(size.height) pt tall; Hit.min is \(Hit.min) and the token says never smaller"
        )

        // The other half of the contract, and the reason the paddings stayed in
        // `ChatView`: the box is the house 44, not 44 plus an inset that drifted
        // inside the style. This one passes on the unfixed code too — it is a
        // guard on the fix, not the red.
        XCTAssertLessThanOrEqual(
            max(size.width, size.height),
            Hit.min + 1,
            "the hit box grew past Hit.min (\(size)) — padding belongs outside IconButtonStyle, not inside its frame"
        )

        _ = window
    }
}
