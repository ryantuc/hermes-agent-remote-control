import SwiftUI
import XCTest

@testable import HermesMobile

/// Portrait's control row chooses with `ViewThatFits` by ideal width, and the pill's ideal width was the constant floor 110 (with the effort) or 72 (model alone), while every other control is a fixed 44 pt box. So the choice depended on screen width alone: at accessibility type sizes the one-row pill was still chosen, the model name collapsed to "…", and from about AX3 the fixed-size effort label overflowed the capsule onto the dictate button. The two-row fallback the doc comment promised "at the largest type sizes" could never win on an iPhone in portrait.
///
/// The floors now scale with the type size the way the pill's own text does (`subheadline`), so the one-row layouts stop fitting when their text would not.
@MainActor
final class ComposerTypeSizeFloorTests: XCTestCase {

    /// The control row's width on an iPhone 17 Pro in portrait: 402 pt less the composer's `Space.s6` margins and the row's own `Space.s3` insets (`ComposerView.body`).
    private static let phoneWidth: CGFloat = 402 - 2 * Space.s6 - 2 * Space.s3
    /// What the one-row layouts spend besides the pill: the 34 pt plus button, dictate, voice chat and Send at `Hit.min`, and the four gaps between five controls.
    private static let otherControls: CGFloat = 34 + 3 * Hit.min + 4 * Space.s3

    func testTheFloorsAreUnchangedAtTheDefaultSize() {
        XCTAssertEqual(ComposerView.pillFloor(showsEffort: true, at: .large), 110, accuracy: 0.5)
        XCTAssertEqual(ComposerView.pillFloor(showsEffort: false, at: .large), 72, accuracy: 0.5)
    }

    func testTheFloorsGrowWithTheTypeSize() {
        for showsEffort in [true, false] {
            let sizes: [DynamicTypeSize] = [.large, .xxxLarge, .accessibility1, .accessibility3, .accessibility5]
            let floors = sizes.map { ComposerView.pillFloor(showsEffort: showsEffort, at: $0) }
            for (smaller, larger) in zip(floors, floors.dropFirst()) {
                XCTAssertLessThan(smaller, larger, "showsEffort=\(showsEffort): the pill's floor does not grow with its text (\(floors))")
            }
        }
    }

    /// From AX3 the effort label no longer fits beside a readable model name, so the row that carries both must not be offered.
    func testFromAX3TheModelAndEffortRowNoLongerFitsAPhone() {
        for size: DynamicTypeSize in [.accessibility3, .accessibility4, .accessibility5] {
            let row = ComposerView.pillFloor(showsEffort: true, at: size) + Self.otherControls
            XCTAssertGreaterThan(row, Self.phoneWidth, "\(size): the one-row model-and-effort layout still fits, so its fixed-size effort label overflows onto the dictate button")
        }
    }

    /// At the largest size neither one-row layout fits, which is when the two-row fallback takes over.
    func testAtTheLargestSizeOnlyTheTwoRowLayoutFits() {
        let row = ComposerView.pillFloor(showsEffort: false, at: .accessibility5) + Self.otherControls
        XCTAssertGreaterThan(row, Self.phoneWidth, "at AX5 the model-alone row still fits, so the two-row fallback never wins")
    }
}
