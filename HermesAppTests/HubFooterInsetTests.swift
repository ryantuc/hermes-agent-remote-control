import HermesServeKit
import SwiftUI
import UIKit
import XCTest

@testable import HermesMobile

/// BUG-043 — the hub's session list runs under the pinned Command Center / Settings footer.
///
/// This file is the measurement that answered the report, and it passed on the tree the report was filed against. BUG-043 says the history's last rows are drawn behind the two pinned rows and cannot be scrolled clear of them. Measured against the shipped hub, with thirty rows of history in a 300 × 800 pt drawer: the scroller's frame is `(0, 108, 300, 592)`, its bottom content inset is `0`, and the pinned footer is the 100 pt from 700 to 800. The list's content region therefore ends at exactly 700 pt — flush with the top of the footer, not under it — and its 1510 pt of content scrolls fully clear. Nothing is hidden at any offset. What the report's screenshots show is a scroll view clipping at its own bottom edge, which is what scroll views do; the sliced row at rest is reachable by scrolling.
///
/// So the tests below never went red, and they are kept as a standing invariant rather than as the receipt for a fix: the bottom of the list's scrollable content region must sit at or above the top of the pinned footer. A scroll view can only ever expose content down to `frame.maxY - adjustedContentInset.bottom`; anything below that line is behind whatever is drawn there, at every scroll offset there is. If a later change to the hub's column — a floating footer, an overlay, a nested scroller in the Bots roster — pushes that line under the footer, this is what says so.
///
/// It is deliberately **not** an assertion that the scroll view's frame stops short of the footer. Both correct layouts pass: a footer laid out below the scroller (inset 0, frame ends where the footer starts, which is what ships) and a footer floating over it (frame runs to the bottom, inset equal to the footer's height). What no layout may do is leave a content region reaching under the footer.
@MainActor
final class HubFooterInsetTests: XCTestCase {

    /// The drawer is 300 pt at compact width and the rail is 300 pt at regular width (`RootView.swift`). One width covers both containers.
    private static let width: CGFloat = 300
    /// A phone-sized drawer: an iPhone 16 Pro is 874 pt tall, less the status bar and the home indicator. The exact number does not matter as long as the seeded history overflows it, which the precondition below proves.
    private static let height: CGFloat = 800

    /// The two pinned rows, from the view's own constant rather than a literal.
    private static var footerHeight: CGFloat { NavigationHubView.pinnedRowHeight * 2 }

    private var window: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window = nil
        super.tearDown()
    }

    // MARK: Harness

    /// Enough live rows to overflow the drawer several times over.
    ///
    /// They arrive through `session.active_list` rather than REST because REST is dead in this harness by design (`AppHarness`), and `AppModel.hubSessions` synthesises a row for every working live session — the same path `HubGhostSessionTests` uses.
    private func seedOverflowingHistory(_ harness: AppHarness, count: Int = 30) async {
        let now = Date().timeIntervalSince1970
        await harness.backend.stub("session.active_list") { _ in
            .object(["sessions": .array((0..<count).map { index in
                .object([
                    "id": .string("rt-\(index)"),
                    "session_key": .string("stored-\(index)"),
                    "title": .string("Session number \(index)"),
                    "preview": .string("a preview line for row \(index)"),
                    "status": .string("working"),
                    "last_active": .number(now - Double(index)),
                ])
            })])
        }
        await harness.app.refreshThreads(force: true)
    }

    /// Host the shipped hub and hand back its scroller.
    private func hostHub(_ harness: AppHarness) -> UIScrollView? {
        // `HermesAppTests` is hosted in the app, so both of these keys carry whatever the last suite left on the simulator. The history's group expansion and the Sessions/Projects segment both decide whether any rows are drawn at all.
        UserDefaults.standard.removeObject(forKey: "hermes.history.expansion")
        UserDefaults.standard.set("Sessions", forKey: "hermes.hub.mode")

        let hub = NavigationHubView(
            path: .constant([]),
            isPresented: .constant(true),
            mode: .constant(.sessions)
        )
        .environment(harness.app)
        .frame(width: Self.width, height: Self.height)

        let host = UIHostingController(rootView: AnyView(hub))
        // The drawer is an overlay inside the app's own window; a hosting controller left to itself would add the screen's insets to every number below.
        host.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: Self.width, height: Self.height))
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()
        self.window = window
        return Self.firstScrollView(in: host.view)
    }

    private static func firstScrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        for subview in view.subviews {
            if let found = firstScrollView(in: subview) { return found }
        }
        return nil
    }

    // MARK: The invariant BUG-043 asserted was broken

    func testTheHistoryCanBeScrolledClearOfThePinnedFooter() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        await seedOverflowingHistory(harness)

        guard let scroll = hostHub(harness) else {
            await harness.tearDown()
            return XCTFail("the hub rendered no scroll view at all — the history is what this file measures")
        }
        let frame = scroll.convert(scroll.bounds, to: window)
        let inset = scroll.adjustedContentInset.bottom
        let contentBottom = frame.maxY - inset
        let footerTop = Self.height - Self.footerHeight

        // Everything in one line: the summary keeps only the first line of a failure, and this is the diagnosis.
        print("[bug043] rows=\(harness.app.hubSessions.count) scrollFrame=\(frame) contentSize=\(scroll.contentSize) "
            + "adjustedInset=\(scroll.adjustedContentInset) contentInset=\(scroll.contentInset) "
            + "contentBottom=\(contentBottom) footerTop=\(footerTop) footerHeight=\(Self.footerHeight)")

        XCTAssertGreaterThan(
            scroll.contentSize.height,
            frame.height,
            "precondition: the seeded history (\(harness.app.hubSessions.count) rows) does not overflow the drawer, so nothing here is measuring an overlap"
        )
        XCTAssertLessThanOrEqual(
            contentBottom,
            footerTop + 0.5,
            "the hub's list can expose content down to \(contentBottom) pt while the pinned footer starts at \(footerTop) pt — the last \(contentBottom - footerTop) pt of the list is behind the Command Center / Settings rows at every scroll offset, so the final row is cut in half by the footer's hairline and no amount of scrolling frees it (BUG-043)"
        )

        await harness.tearDown()
    }

    /// The same property with nothing seeded. A short list must not be given a scroll region under the footer either — and this is the case that would go quietly wrong if a fix inset the content only when the list happened to be long.
    func testTheContentRegionStopsAboveTheFooterWithAShortList() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        await seedOverflowingHistory(harness, count: 2)

        guard let scroll = hostHub(harness) else {
            await harness.tearDown()
            return XCTFail("the hub rendered no scroll view at all")
        }
        let frame = scroll.convert(scroll.bounds, to: window)
        let contentBottom = frame.maxY - scroll.adjustedContentInset.bottom
        let footerTop = Self.height - Self.footerHeight
        print("[bug043] short list: scrollFrame=\(frame) adjustedInset=\(scroll.adjustedContentInset) contentBottom=\(contentBottom) footerTop=\(footerTop)")

        XCTAssertLessThanOrEqual(
            contentBottom,
            footerTop + 0.5,
            "the list's content region reaches \(contentBottom) pt, under a footer that starts at \(footerTop) pt"
        )

        await harness.tearDown()
    }
}
