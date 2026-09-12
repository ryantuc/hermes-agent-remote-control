import SwiftUI
import UIKit
import XCTest

@testable import HermesMobile

/// `IdentityChip` is the first identity component in this design system, so both halves of it are pinned here: the letter it derives when a bot has no avatar, and the fact that the circle is a fixed well rather than something that grows with the type beside it.
///
/// The derivation is a pure function and is asserted directly. The size is measured the way `HubBackendRowLayoutTests` measures the hub's backend row — host the shipped view and ask the hosting controller what it wants — because the property under test is that the answer does **not** move with Dynamic Type, and only a real layout pass can say that.
@MainActor
final class IdentityChipLayoutTests: XCTestCase {

    // MARK: The initial

    func testTheInitialIsTheFirstLetterOfTheDisplayName() {
        XCTAssertEqual(IdentityChip.initial(for: "ops-bot"), "O")
        XCTAssertEqual(IdentityChip.initial(for: "Hermes"), "H")
        XCTAssertEqual(IdentityChip.initial(for: "research"), "R")
    }

    /// The backend's profile names are lowercase slugs (`ops-bot`, `default`), and `BotsModel` title-cases them for display — but the chip must not depend on that having happened.
    func testTheInitialIsUppercasedWhateverTheNameCase() {
        XCTAssertEqual(IdentityChip.initial(for: "default"), "D")
        XCTAssertEqual(IdentityChip.initial(for: "éclair"), "É")
    }

    /// An empty chip reads as a rendering failure, not as an unnamed bot.
    func testAnEmptyOrBlankNameFallsBackToAQuestionMark() {
        XCTAssertEqual(IdentityChip.initial(for: ""), "?")
        XCTAssertEqual(IdentityChip.initial(for: "   "), "?")
        XCTAssertEqual(IdentityChip.initial(for: "\n\t"), "?")
    }

    /// Leading whitespace is trimmed before the letter is taken, so a name the
    /// backend padded does not draw a blank chip.
    func testLeadingWhitespaceIsTrimmedBeforeTheLetterIsTaken() {
        XCTAssertEqual(IdentityChip.initial(for: "  ops-bot"), "O")
    }

    // MARK: Measured size

    private struct Rung {
        let name: String
        let swiftUI: DynamicTypeSize
        let uiKit: UIContentSizeCategory
    }

    private static let resting = Rung(name: "large", swiftUI: .large, uiKit: .large)
    private static let axExtraLarge = Rung(
        name: "accessibilityExtraLarge",
        swiftUI: .accessibility3,
        uiKit: .accessibilityExtraLarge
    )

    private func measure<V: View>(_ view: V, at rung: Rung) -> CGSize {
        let host = UIHostingController(rootView: AnyView(
            view.environment(\.dynamicTypeSize, rung.swiftUI)
        ))
        host.safeAreaRegions = []
        host.traitOverrides.preferredContentSizeCategory = rung.uiKit
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()
        let size = host.sizeThatFits(in: CGSize(width: 300, height: 300))
        window.isHidden = true
        return size
    }

    func testTheChipMeasuresItsDeclaredDiameterAtTheDefaultSize() {
        for diameter in [IdentityChip.headerSize, IdentityChip.rosterSize] {
            let size = measure(IdentityChip(displayName: "ops-bot", size: diameter), at: Self.resting)
            XCTAssertEqual(size.width, diameter, accuracy: 0.5,
                           "a \(diameter) pt chip measured \(size.width) pt wide")
            XCTAssertEqual(size.height, diameter, accuracy: 0.5,
                           "a \(diameter) pt chip measured \(size.height) pt tall")
        }
    }

    /// **The property that keeps the roster's rows aligned.** The chip is an image well: if it grew with the type, every row's leading edge would move by a different amount depending on whether that bot's avatar had loaded yet.
    func testTheChipDoesNotGrowWithDynamicType() {
        let resting = measure(IdentityChip(displayName: "Hermes"), at: Self.resting)
        let large = measure(IdentityChip(displayName: "Hermes"), at: Self.axExtraLarge)
        XCTAssertEqual(large.width, resting.width, accuracy: 0.5, """
            the chip is \(large.width) pt wide at accessibilityExtraLarge against \(resting.width) pt \
            at the default size. The letter inside it scales; the well it sits in must not, or the \
            roster's name column starts at a different x on every row
            """)
        XCTAssertEqual(large.height, resting.height, accuracy: 0.5,
                       "the chip is \(large.height) pt tall at accessibilityExtraLarge against \(resting.height) pt")
    }

    /// An avatar that fails to decode falls back to the letter rather than to a hole, and either way the chip is the same size.
    func testUndecodableImageDataStillMeasuresTheDeclaredDiameter() {
        let junk = Data([0x00, 0x01, 0x02, 0x03])
        let size = measure(IdentityChip(displayName: "ops-bot", imageData: junk), at: Self.resting)
        XCTAssertEqual(size.width, IdentityChip.rosterSize, accuracy: 0.5)
        XCTAssertEqual(size.height, IdentityChip.rosterSize, accuracy: 0.5)
    }
}
