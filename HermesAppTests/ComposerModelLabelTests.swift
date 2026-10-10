import XCTest

@testable import HermesMobile

/// The model button showed a lone dash when no model was known yet (a live chat before its `session.info`, a draft before the backend's default loads), which read as a broken control. It names itself instead, and the spoken label is unchanged.
final class ComposerModelLabelTests: XCTestCase {
    func testTheModelButtonNamesItselfWhenNoModelIsKnown() {
        XCTAssertEqual(ComposerModelLabel.text(for: ""), "Model")
        XCTAssertNotEqual(ComposerModelLabel.text(for: ""), "—")
    }

    func testAKnownModelIsShownByItsName() {
        XCTAssertEqual(ComposerModelLabel.text(for: "deepseek/deepseek-v4"), "deepseek/deepseek-v4")
    }
}
