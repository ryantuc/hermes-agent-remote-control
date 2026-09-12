import SwiftUI
import XCTest

@testable import HermesMobile

/// The ladder, pinned.
///
/// FEAT-017 §5 asked for the four conversation rungs to move up one step to the
/// iOS semantic sizes. That was done, measured, and reverted: it hangs the
/// composer, deterministically, and `HermesType.swift` carries the mechanism.
/// These tests pin what actually ships, so the next attempt starts from a red
/// test rather than from a guess about what the sizes used to be.
///
/// The font *family* was never the problem — `Font.system` is SF Pro on iOS,
/// which is what Nous asks for on Apple platforms, and bundling Segoe or
/// pulling a web font would have been the wrong fix. Dynamic Type was never the
/// problem either; `relativeTo:` was correct throughout, and the last test here
/// is what says so.
final class TypeLadderTests: XCTestCase {

    /// One step under the system's 17. Raising it is what hung the composer;
    /// see `HermesType.swift`.
    func testBodyIsSixteen() {
        XCTAssertEqual(HermesFont.body.size, 16)
        XCTAssertEqual(HermesFont.bodyStrong.size, 16, "emphasis inside a message must not change its size")
    }

    func testCalloutIsFifteen() {
        XCTAssertEqual(HermesFont.callout.size, 15)
        XCTAssertEqual(HermesFont.calloutStrong.size, 15)
    }

    func testSubheadIsThirteenAndAHalf() {
        XCTAssertEqual(HermesFont.subhead.size, 13.5)
    }

    func testFootnoteIsTwelve() {
        XCTAssertEqual(HermesFont.footnote.size, 12)
    }

    /// The floor does not move. 11 pt is the smallest text the system defines.
    func testTheCaptionFloorIsUnchanged() {
        XCTAssertEqual(HermesFont.caption.size, 11)
        XCTAssertEqual(HermesFont.floor, 11)
    }

    /// Code keeps its sizes deliberately. A monospaced rung that grows reflows
    /// every diff, argument list and terminal line it carries, and code that
    /// wraps is harder to read than code that is small. It stayed put through
    /// the reverted experiment and should stay put through the next one.
    func testTheMonospacedRungsDidNotMove() {
        XCTAssertEqual(HermesFont.code.size, 13)
        XCTAssertEqual(HermesFont.codeStrong.size, 13)
        XCTAssertEqual(HermesFont.codeSmall.size, 12)
    }

    /// The ladder still descends. Any rung landing at or above the one above it
    /// has flattened the hierarchy, whatever its absolute value.
    func testTheConversationLadderStillDescends() {
        let rungs: [(String, CGFloat)] = [
            ("display", HermesFont.display.size),
            ("title", HermesFont.title.size),
            ("body", HermesFont.body.size),
            ("callout", HermesFont.callout.size),
            ("subhead", HermesFont.subhead.size),
            ("footnote", HermesFont.footnote.size),
            ("caption", HermesFont.caption.size),
        ]
        for (above, below) in zip(rungs, rungs.dropFirst()) {
            XCTAssertGreaterThan(
                above.1, below.1,
                "\(above.0) (\(above.1)) is no longer larger than \(below.0) (\(below.1))"
            )
        }
    }

    /// Every rung stays at or above the floor.
    ///
    /// Renamed from a claim it did not support: it used to be called
    /// `testEveryRungScalesAgainstASystemTextStyle` while only asserting
    /// `size >= floor`, which says nothing about Dynamic Type. A test whose
    /// name overstates it is worse than no test, because it makes the next
    /// reader think the ground is covered.
    func testNoRungFallsBelowTheFloor() {
        let rungs = [
            HermesFont.display, HermesFont.title, HermesFont.heading,
            HermesFont.body, HermesFont.bodyStrong,
            HermesFont.callout, HermesFont.calloutStrong,
            HermesFont.subhead, HermesFont.footnote, HermesFont.caption,
            HermesFont.code, HermesFont.codeStrong, HermesFont.codeSmall,
        ]
        for rung in rungs {
            XCTAssertGreaterThanOrEqual(rung.size, HermesFont.floor, "a rung fell below the 11 pt floor")
        }
    }

    /// And this is the Dynamic Type assertion the one above pretended to be:
    /// every rung names a system text style to scale against, so nothing in the
    /// ladder is a fixed point size.
    func testEveryRungNamesASystemTextStyleToScaleAgainst() {
        let rungs: [(String, Font.TextStyle)] = [
            ("display", HermesFont.display.relativeTo),
            ("title", HermesFont.title.relativeTo),
            ("heading", HermesFont.heading.relativeTo),
            ("body", HermesFont.body.relativeTo),
            ("bodyStrong", HermesFont.bodyStrong.relativeTo),
            ("callout", HermesFont.callout.relativeTo),
            ("calloutStrong", HermesFont.calloutStrong.relativeTo),
            ("subhead", HermesFont.subhead.relativeTo),
            ("footnote", HermesFont.footnote.relativeTo),
            ("caption", HermesFont.caption.relativeTo),
            ("code", HermesFont.code.relativeTo),
            ("codeStrong", HermesFont.codeStrong.relativeTo),
            ("codeSmall", HermesFont.codeSmall.relativeTo),
        ]
        // The four conversation rungs scale against the system style of the
        // same name. This is the part FEAT-017 §5 got wrong about the app: the
        // wiring was always right, and only the base sizes sit low.
        XCTAssertEqual(HermesFont.body.relativeTo, .body)
        XCTAssertEqual(HermesFont.callout.relativeTo, .callout)
        XCTAssertEqual(HermesFont.subhead.relativeTo, .subheadline)
        XCTAssertEqual(HermesFont.footnote.relativeTo, .footnote)
        XCTAssertEqual(rungs.count, 13, "a rung was added or removed without being listed here")
    }
}
