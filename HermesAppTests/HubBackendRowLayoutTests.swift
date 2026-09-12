import SwiftUI
import UIKit
import XCTest

@testable import HermesMobile

/// FEAT-008 — the hub's backend row was pinned to exactly 56 pt
/// (`NavigationHubView.swift`, `.frame(height: 56)`). Its two labels scale with
/// Dynamic Type; the row did not. `.frame(height:)` does not clip, so at
/// accessibility content sizes the labels drew out through the bottom of the
/// row and over the "New conversation" control below it, which is visible in a
/// screenshot at `accessibilityExtraLarge`.
///
/// This measures the row the way `SessionActivityStripLayoutTests` measures the
/// activity strip: host the shipped view at the hub's real 300 pt width and ask
/// the hosting controller what height it wants. Two properties, pulling in
/// opposite directions on purpose.
///
/// 1. **The default size does not move.** At the default content size the row
///    measures exactly 56 pt, as it always has. Letting it grow at
///    accessibility sizes may not cost a pixel at the size nearly everyone runs.
/// 2. **The row is never shorter than the type inside it.** At
///    `accessibilityExtraLarge` the two labels alone need more than 56 pt, so a
///    row that still reports 56 is reporting a height the renderer then draws
///    straight past.
///
/// The floor in (2) comes from `UIFontMetrics` — UIKit's own scaling of the two
/// rungs the row declares — rather than from re-running the view's layout, so
/// it is an independent number and not a mirror of the code under test. It is a
/// *lower* bound: it adds point sizes, where the real cost is line heights.
@MainActor
final class HubBackendRowLayoutTests: XCTestCase {

    /// The drawer is 300 pt at compact width and the rail is 300 pt at regular
    /// width (`RootView.swift:54`, `:204`). One width covers both containers.
    private static let width: CGFloat = 300

    /// One rung of the Dynamic Type ladder in both currencies: SwiftUI's, which
    /// drives `@ScaledMetric` inside the type ladder, and UIKit's, which drives
    /// the hosting controller's trait override and `UIFontMetrics`.
    private struct Rung {
        let name: String
        let swiftUI: DynamicTypeSize
        let uiKit: UIContentSizeCategory
    }

    private static let resting = Rung(name: "large", swiftUI: .large, uiKit: .large)

    /// Everything from the smallest up to the largest size that is still not an
    /// accessibility size. The row is expected to rest at 56 pt across all of it.
    private static let ordinaryRungs: [Rung] = [
        Rung(name: "small", swiftUI: .small, uiKit: .small),
        Rung(name: "medium", swiftUI: .medium, uiKit: .medium),
        resting,
        Rung(name: "extraLarge", swiftUI: .xLarge, uiKit: .extraLarge),
        Rung(name: "extraExtraLarge", swiftUI: .xxLarge, uiKit: .extraExtraLarge),
    ]

    /// The five accessibility sizes. `accessibilityExtraLarge` is the one in the
    /// photograph.
    private static let accessibilityRungs: [Rung] = [
        Rung(name: "accessibilityMedium", swiftUI: .accessibility1, uiKit: .accessibilityMedium),
        Rung(name: "accessibilityLarge", swiftUI: .accessibility2, uiKit: .accessibilityLarge),
        Rung(name: "accessibilityExtraLarge", swiftUI: .accessibility3, uiKit: .accessibilityExtraLarge),
        Rung(name: "accessibilityExtraExtraLarge", swiftUI: .accessibility4, uiKit: .accessibilityExtraExtraLarge),
        Rung(name: "accessibilityExtraExtraExtraLarge", swiftUI: .accessibility5, uiKit: .accessibilityExtraExtraExtraLarge),
    ]

    private static let axExtraLarge = accessibilityRungs[2]

    // MARK: Measuring

    /// The height the row wants, unconstrained. A test that handed it a fixed
    /// frame would be measuring the frame.
    private func measure<V: View>(_ view: V, at rung: Rung) -> CGFloat {
        let host = UIHostingController(rootView: AnyView(
            view
                .environment(\.dynamicTypeSize, rung.swiftUI)
                .frame(width: Self.width)
        ))
        // The row is a sibling in the middle of the hub's VStack and never sees
        // a safe area of its own; without this the hosting controller adds the
        // screen's insets to every number below.
        host.safeAreaRegions = []
        host.traitOverrides.preferredContentSizeCategory = rung.uiKit
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: Self.width, height: 1400))
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()
        let size = host.sizeThatFits(in: CGSize(width: Self.width, height: .greatestFiniteMagnitude))
        window.isHidden = true
        return size.height
    }

    private func measureRow(at rung: Rung) -> CGFloat {
        measure(
            HubBackendRow(title: "workstation", subtitle: "Connected · v0.20.1", dot: .green, action: {}),
            at: rung
        )
    }

    /// What the row's two stacked labels need, in points, from UIKit's own
    /// Dynamic Type scaling of the rungs the row declares
    /// (`HermesType.swift:52` callout/15, `:56` footnote/12) plus the `Space.s1`
    /// gap between them. Point sizes, not line heights, so this under-counts —
    /// which is exactly what makes it safe as a floor.
    private func contentFloor(at rung: Rung) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: rung.uiKit)
        let title = UIFontMetrics(forTextStyle: .callout)
            .scaledValue(for: HermesFont.calloutStrong.size, compatibleWith: traits)
        let subtitle = UIFontMetrics(forTextStyle: .footnote)
            .scaledValue(for: HermesFont.footnote.size, compatibleWith: traits)
        return title + Space.s1 + subtitle
    }

    // MARK: 0 — the harness itself

    /// If the content size category is not reaching `@ScaledMetric` inside
    /// `ScaledFontModifier`, every number below is the default size wearing an
    /// accessibility label, and this file would pass for the wrong reason.
    func testTheHarnessActuallyAppliesTheContentSizeCategory() {
        let line = Text("Connected").font(HermesFont.calloutStrong).lineLimit(1)
        let resting = measure(line, at: Self.resting)
        let large = measure(line, at: Self.axExtraLarge)
        XCTAssertGreaterThan(large, resting * 1.5, """
            a callout line measures \(large) pt at accessibilityExtraLarge against \(resting) pt at \
            the default size. The environment override is not reaching the type ladder, so nothing \
            else in this file is measuring what it says it is
            """)
    }

    // MARK: 1 — the default size does not move

    func testTheRowStillRestsAtFiftySixPointsAtTheDefaultSize() {
        let height = measureRow(at: Self.resting)
        XCTAssertEqual(height, HubBackendRow.restingHeight, accuracy: 0.5, """
            the backend row measures \(height) pt at the default content size, where it has always \
            measured \(HubBackendRow.restingHeight) pt. Letting the row grow at accessibility sizes \
            must not move the compact layout at the size the hub was designed against
            """)
    }

    /// The row must change height only where the type genuinely outgrows it.
    func testTheRowDoesNotGrowUntilTheTypeOutgrowsIt() {
        for rung in Self.ordinaryRungs {
            let height = measureRow(at: rung)
            XCTAssertEqual(height, HubBackendRow.restingHeight, accuracy: 0.5, """
                the row is \(height) pt at \(rung.name) — it must rest at \
                \(HubBackendRow.restingHeight) pt everywhere the type still fits inside it
                """)
        }
    }

    // MARK: 2 — the row is never shorter than the type inside it

    /// **The assertion FEAT-008 is.** Red against the fixed 56 pt row.
    func testTheRowIsNotClampedBelowItsContentAtAccessibilityExtraLarge() {
        let height = measureRow(at: Self.axExtraLarge)
        let floor = contentFloor(at: Self.axExtraLarge)
        print("[hub] backend row at accessibilityExtraLarge: \(height) pt · content floor \(floor) pt")
        XCTAssertGreaterThanOrEqual(height, floor, """
            the backend row reports \(height) pt at accessibilityExtraLarge while the two labels \
            inside it need at least \(floor) pt. A frame does not clip, so the overflow is drawn \
            straight over the "New conversation" control the hub stacks underneath it. \
            The row has to grow with its content
            """)
    }

    /// The same property across the rest of the accessibility ladder — the
    /// collision is not special to one rung.
    func testTheRowIsNotClampedBelowItsContentAtEveryAccessibilitySize() {
        for rung in Self.accessibilityRungs {
            let height = measureRow(at: rung)
            let floor = contentFloor(at: rung)
            XCTAssertGreaterThanOrEqual(height, floor,
                                        "the row is \(height) pt at \(rung.name), under its \(floor) pt content floor")
        }
    }

    /// And it grows monotonically: a larger type size never buys a shorter row.
    func testTheRowGrowsWithTheTypeAndNeverShrinks() {
        var previous: CGFloat = 0
        var last = ""
        for rung in [Self.resting] + Self.accessibilityRungs {
            let height = measureRow(at: rung)
            XCTAssertGreaterThanOrEqual(height, previous - 0.5,
                                        "the row shrank to \(height) pt at \(rung.name) from \(previous) pt at \(last)")
            previous = height
            last = rung.name
        }
        XCTAssertGreaterThan(previous, HubBackendRow.restingHeight, """
            the row is still \(previous) pt at the largest accessibility size — the height it has at \
            the default one. It is pinned, and the type is spilling out of it
            """)
    }
}
