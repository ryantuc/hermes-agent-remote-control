import SwiftUI
import UIKit
import XCTest

@testable import HermesMobile

/// The Bots roster row, measured against the contract `HubBackendRowLayoutTests` established for the hub's backend row (FEAT-008).
///
/// That contract is worth copying rather than re-deriving, because the roster row is the same shape and carries the same hazard: a leading fixed-size element beside two stacked labels that scale. The backend row was pinned to exactly 56 pt, `.frame(height:)` does not clip, and at accessibility content sizes the labels drew straight through the row and over the control beneath. **56 pt is the resting height and a floor, not a cap.**
///
/// Two properties pulling in opposite directions, on purpose:
///
/// 1. **The default size does not move.** Letting a row grow at accessibility sizes must cost nothing at the size nearly everyone runs.
/// 2. **The row is never shorter than the type inside it.** The floor comes from `UIFontMetrics` — UIKit's own scaling of the two rungs the row declares — so it is an independent number and not a mirror of the code under test. It counts point sizes where the real cost is line heights, which is what makes it safe as a lower bound.
@MainActor
final class BotRosterRowLayoutTests: XCTestCase {

    /// The drawer is 300 pt and the rail is 300 pt; the Bots root is a full phone width. The narrower of the two is the one that can break, so it is the one measured.
    private static let width: CGFloat = 300

    private struct Rung {
        let name: String
        let swiftUI: DynamicTypeSize
        let uiKit: UIContentSizeCategory
    }

    private static let resting = Rung(name: "large", swiftUI: .large, uiKit: .large)

    private static let ordinaryRungs: [Rung] = [
        Rung(name: "small", swiftUI: .small, uiKit: .small),
        Rung(name: "medium", swiftUI: .medium, uiKit: .medium),
        resting,
        Rung(name: "extraLarge", swiftUI: .xLarge, uiKit: .extraLarge),
        Rung(name: "extraExtraLarge", swiftUI: .xxLarge, uiKit: .extraExtraLarge),
    ]

    private static let accessibilityRungs: [Rung] = [
        Rung(name: "accessibilityMedium", swiftUI: .accessibility1, uiKit: .accessibilityMedium),
        Rung(name: "accessibilityLarge", swiftUI: .accessibility2, uiKit: .accessibilityLarge),
        Rung(name: "accessibilityExtraLarge", swiftUI: .accessibility3, uiKit: .accessibilityExtraLarge),
        Rung(name: "accessibilityExtraExtraLarge", swiftUI: .accessibility4, uiKit: .accessibilityExtraExtraLarge),
        Rung(name: "accessibilityExtraExtraExtraLarge", swiftUI: .accessibility5, uiKit: .accessibilityExtraExtraExtraLarge),
    ]

    private static let axExtraLarge = accessibilityRungs[2]

    // MARK: Measuring

    private func measure<V: View>(_ view: V, at rung: Rung) -> CGFloat {
        let host = UIHostingController(rootView: AnyView(
            view
                .environment(\.dynamicTypeSize, rung.swiftUI)
                .frame(width: Self.width)
        ))
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

    /// A row in its loudest state: both dots lit, a real preview, a timestamp.
    private func measureRow(at rung: Rung, preview: String = "The build finished. All checks passed.") -> CGFloat {
        measure(
            BotRosterRow(
                displayName: "Ops Bot",
                preview: preview,
                lastActive: Date().timeIntervalSince1970 - 900,
                isWorking: true,
                isUnread: true
            ),
            at: rung
        )
    }

    /// What the row's two stacked labels need, in points, from UIKit's own scaling of the rungs the row declares (`HermesFont.callout` 15, `HermesFont.subhead` 13.5) plus the `Space.s1` gap. Point sizes, not line heights, so it under-counts — which is what makes it safe as a floor.
    private func contentFloor(at rung: Rung) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: rung.uiKit)
        let name = UIFontMetrics(forTextStyle: .callout)
            .scaledValue(for: HermesFont.callout.size, compatibleWith: traits)
        let preview = UIFontMetrics(forTextStyle: .subheadline)
            .scaledValue(for: HermesFont.subhead.size, compatibleWith: traits)
        return name + Space.s1 + preview
    }

    // MARK: 0 — the harness itself

    /// Without this every number below could be the default size wearing an accessibility label, and the whole file would pass for the wrong reason.
    func testTheHarnessActuallyAppliesTheContentSizeCategory() {
        let line = Text("Ops Bot").font(HermesFont.callout).lineLimit(1)
        let resting = measure(line, at: Self.resting)
        let large = measure(line, at: Self.axExtraLarge)
        XCTAssertGreaterThan(large, resting * 1.5, """
            a callout line measures \(large) pt at accessibilityExtraLarge against \(resting) pt at the \
            default size. The environment override is not reaching the type ladder
            """)
    }

    // MARK: 1 — the default size does not move

    func testTheRowRestsAtFiftySixPointsAtTheDefaultSize() {
        let height = measureRow(at: Self.resting)
        XCTAssertEqual(height, BotRosterRow.restingHeight, accuracy: 0.5, """
            the roster row measures \(height) pt at the default content size, where the design calls for \
            \(BotRosterRow.restingHeight) — the same resting height as the hub's backend row, which is \
            what makes the two lists read as one system
            """)
    }

    func testTheRowDoesNotGrowUntilTheTypeOutgrowsIt() {
        for rung in Self.ordinaryRungs {
            let height = measureRow(at: rung)
            XCTAssertEqual(height, BotRosterRow.restingHeight, accuracy: 0.5, """
                the row is \(height) pt at \(rung.name) — it must rest at \(BotRosterRow.restingHeight) pt \
                everywhere the type still fits inside it
                """)
        }
    }

    /// The 34 pt identity chip is the tallest fixed thing in the row and it must not be what sets the height at the default size — if it were, a row whose avatar failed to load would be a different height from its neighbours.
    func testTheChipDoesNotSetTheRestingHeight() {
        XCTAssertGreaterThan(BotRosterRow.restingHeight, IdentityChip.rosterSize + Space.s5, """
            the \(IdentityChip.rosterSize) pt chip plus its breathing room is at or above the row's \
            \(BotRosterRow.restingHeight) pt resting height, so the chip is setting the geometry
            """)
    }

    /// An empty preview draws "No conversation yet" rather than a blank line, so a never-used bot's row is the same height as everyone else's.
    func testARowWithNoPreviewIsTheSameHeight() {
        let withPreview = measureRow(at: Self.resting)
        let without = measureRow(at: Self.resting, preview: "")
        XCTAssertEqual(without, withPreview, accuracy: 0.5, """
            a bot with no conversation yet measures \(without) pt against \(withPreview) pt for one with \
            a preview. A blank second line reads as a row that failed to load
            """)
    }

    // MARK: 2 — the row is never shorter than the type inside it

    func testTheRowIsNotClampedBelowItsContentAtAccessibilityExtraLarge() {
        let height = measureRow(at: Self.axExtraLarge)
        let floor = contentFloor(at: Self.axExtraLarge)
        print("[bots] roster row at accessibilityExtraLarge: \(height) pt · content floor \(floor) pt")
        XCTAssertGreaterThanOrEqual(height, floor, """
            the roster row reports \(height) pt at accessibilityExtraLarge while the two labels inside it \
            need at least \(floor) pt. A frame does not clip, so the overflow is drawn straight over the \
            next bot in the list — the same defect FEAT-008 fixed in the hub
            """)
    }

    func testTheRowIsNotClampedBelowItsContentAtEveryAccessibilitySize() {
        for rung in Self.accessibilityRungs {
            let height = measureRow(at: rung)
            let floor = contentFloor(at: rung)
            XCTAssertGreaterThanOrEqual(height, floor,
                                        "the row is \(height) pt at \(rung.name), under its \(floor) pt content floor")
        }
    }

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
        XCTAssertGreaterThan(previous, BotRosterRow.restingHeight, """
            the row is still \(previous) pt at the largest accessibility size — the height it has at the \
            default one. It is pinned, and the type is spilling out of it
            """)
    }
}
