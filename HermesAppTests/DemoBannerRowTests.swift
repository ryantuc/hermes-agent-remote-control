import Foundation
import SwiftUI
import UIKit
import XCTest

@testable import HermesMobile

/// BUG-118 defect 1 and FEAT-032 — the demo marker as a real row.
///
/// The reported defect is a bar that sits over the elements beneath it,
/// leaving both unreadable, and clips its own Exit label. Two of the four
/// mechanisms behind that live in this file and are assertable here:
/// the row's ground was `t.warnFill`, which is the warn seed at **14 % alpha**
/// — a wash, not a background, so the chat screen's translucent navigation bar
/// read straight through it — and the Exit button carried neither a line limit
/// nor a fixed size against a title that could only shrink to 80 %. The other
/// two are in `RootView` and `HomeView` and are photographed rather than
/// asserted.
@MainActor
final class DemoBannerRowTests: XCTestCase {

    /// The same measurement `DemoModeTests` takes, which is what makes "the
    /// marker displaces the app" a fact rather than an intention.
    private func hostedHeight(isActive: Bool, width: CGFloat = 320) -> CGFloat {
        let probe = Color.clear
            .frame(width: width, height: 200)
            .demoModeMarker(isActive: isActive, onExit: {})
        let host = UIHostingController(rootView: AnyView(probe))
        host.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 1400))
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()
        let size = host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        window.isHidden = true
        return size.height
    }

    /// One hit target tall, and no taller: the row is a permanent tax on every
    /// screen the demo is shown on.
    func testTheRowIsOneHitTargetTall() {
        XCTAssertEqual(DemoModeBanner.height, Hit.min)
        let bare = hostedHeight(isActive: false)
        let marked = hostedHeight(isActive: true)
        XCTAssertGreaterThanOrEqual(
            marked - bare, Hit.min,
            "the row measured \(marked - bare) pt; a marker shorter than a hit target cannot hold a button anyone can press"
        )
        XCTAssertLessThan(
            marked - bare, Hit.min + 20,
            "the row is \(marked - bare) pt tall — it is displacing every screen in the app and it may not grow a second line"
        )
    }

    /// The row's copy, and the middle dot the width came from.
    func testTheRowSaysBothThingsAndSaysThemShort() {
        XCTAssertTrue(DemoModeBanner.title.contains("DEMO"))
        XCTAssertTrue(
            DemoModeBanner.title.lowercased().contains("not connected"),
            "the marker has to say both things: that this is a demo and that nothing is connected"
        )
        XCTAssertFalse(DemoModeBanner.exitLabel.isEmpty, "the marker carries the way out")
        XCTAssertLessThanOrEqual(
            DemoModeBanner.exitLabel.count, 6,
            "the way out is the part of the row that never yields its width; the shorter it is, the more the title can keep"
        )
        XCTAssertFalse(
            DemoModeBanner.title.contains("—"),
            "an em dash is a wide character in a row that has to survive the largest accessibility type sizes"
        )
    }

    /// The row still holds together at the largest accessibility size — the
    /// category the title could not shrink far enough for.
    func testTheRowDoesNotGrowASecondLineAtAccessibilitySizes() {
        let width: CGFloat = 320
        let probe = DemoModeBanner(onExit: {})
            .frame(width: width)
            .environment(\.dynamicTypeSize, .accessibility5)
        let host = UIHostingController(rootView: AnyView(probe))
        host.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 1400))
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()
        let size = host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        window.isHidden = true
        XCTAssertLessThan(
            size.height, 3 * Hit.min,
            "at accessibility5 the row measured \(size.height) pt — the title wrapped, or the Exit button did, which is the clipping that was reported"
        )
    }

    // MARK: FEAT-032 — the capture flag

    /// The flag exists, is off in an ordinary run, and — the part that matters
    /// — cannot be on in a release build at all. The banner is part of the
    /// honest product; only the App Store captures may omit it.
    func testTheCaptureFlagIsOffUnlessItIsPassed() {
        XCTAssertFalse(
            ProcessInfo.processInfo.arguments.contains("-hermesHideDemoBanner"),
            "precondition: the test runner did not pass the capture flag"
        )
        XCTAssertFalse(DemoCaptureFlags.hidesDemoBanner)

        // With the flag off, the marker is attached exactly as before.
        XCTAssertGreaterThan(
            hostedHeight(isActive: true), hostedHeight(isActive: false),
            "an ordinary run must show the marker"
        )
    }
}
