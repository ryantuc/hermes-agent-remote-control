import XCTest

@testable import HermesMobile

/// **BUG-122's second defect: the row promised more than the tap delivered.**
///
/// The label was the whole hidden count while one tap reveals one `TranscriptScroll.Window.size`, so *Show 300 earlier messages* left *Show 100 earlier messages* behind. These pin the words only — what a tap reveals and how big the window is are untouched, and the other coherent answer (the tap honours the label, at whatever a 300-row reveal costs a tool-heavy chat) is an open product decision.
final class TranscriptRevealLabelTests: XCTestCase {

    private typealias Window = TranscriptScroll.Window

    /// Under a window, the label and the tap already agreed and still do.
    func testAHiddenCountInsideOneWindowIsStatedWhole() {
        XCTAssertEqual(Window.revealLabel(hidden: 14), "Show 14 earlier messages")
    }

    /// The reported case, and the one the label lied about: 300 hidden, 200 revealed.
    func testAHiddenCountBeyondOneWindowLeadsWithWhatTheTapDoes() {
        XCTAssertEqual(
            Window.revealLabel(hidden: 300),
            "Show \(Window.size) earlier messages · 300 hidden"
        )
    }

    /// Exactly one window is not a mismatch, so it does not get the second half.
    func testExactlyOneWindowIsStatedWhole() {
        XCTAssertEqual(
            Window.revealLabel(hidden: Window.size),
            "Show \(Window.size) earlier messages"
        )
    }

    /// The singular survives.
    func testOneHiddenMessageReadsAsOne() {
        XCTAssertEqual(Window.revealLabel(hidden: 1), "Show 1 earlier message")
    }
}
