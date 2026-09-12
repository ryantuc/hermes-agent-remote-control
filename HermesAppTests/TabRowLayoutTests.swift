import SwiftUI
import UIKit
import XCTest

@testable import HermesMobile

/// BUG-023 issue 1 — TabRow promised SegmentedRow geometry (equal flexible
/// segments) but hugs content inside a horizontal ScrollView, so the four
/// Command Center tabs cluster left at different widths.
@MainActor
final class TabRowLayoutTests: XCTestCase {

    func testCommandCenterTabsFillEqually() {
        var selection = "Sessions"
        var widths: [String: CGFloat] = [:]
        let tabs = ["Sessions", "System", "Usage", "Maintenance"]
        let host = UIHostingController(rootView: AnyView(
            TabRow(tabs: tabs, selection: Binding(get: { selection }, set: { selection = $0 }))
                .onPreferenceChange(TabSegmentWidthKey.self) { widths = $0 }
                .frame(width: 390, height: 52)
        ))
        host.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 120))
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()

        XCTAssertEqual(
            Set(widths.keys),
            Set(tabs),
            "TabRow must report a width for every tab (saw \(widths))"
        )
        let values = tabs.compactMap { widths[$0] }
        let maxW = values.max() ?? 0
        let minW = values.min() ?? 0
        XCTAssertLessThanOrEqual(
            maxW - minW,
            2,
            "TabRow segments must be equal-fill, not label-hugging (widths=\(widths))"
        )
        XCTAssertGreaterThan(
            values.reduce(0, +),
            280,
            "equal-fill segments must span the pill, not cluster at the leading edge (widths=\(widths))"
        )
        _ = window
    }
}

final class UsageAutoloadTests: XCTestCase {
    func testUsageTabWithEmptyDataShouldLoad() {
        XCTAssertTrue(UsageAutoload.shouldLoad(tab: "Usage", usageIsNull: true))
    }

    func testOtherTabsDoNotLoad() {
        XCTAssertFalse(UsageAutoload.shouldLoad(tab: "Sessions", usageIsNull: true))
        XCTAssertFalse(UsageAutoload.shouldLoad(tab: "Usage", usageIsNull: false))
    }
}
