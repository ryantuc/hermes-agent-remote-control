import Foundation
import UIKit
import XCTest

@testable import HermesMobile

/// **BUG-123 — the remembered height under `SelectableText`.**
///
/// A memo that answers when it should not is a transcript that jumps, so the rules it has to obey are worth pinning: it answers only for the exact width it measured, and it forgets whenever the words change.
final class SelectableTextSizeMemoTests: XCTestCase {

    func testItAnswersOnlyForTheWidthItMeasured() {
        var memo = SelectableTextSizeMemo()
        memo.record(width: 320, size: CGSize(width: 320, height: 44))

        XCTAssertEqual(memo.size(forWidth: 320), CGSize(width: 320, height: 44))
        XCTAssertNil(memo.size(forWidth: 321), "a different width is a different layout and must be measured again")
        XCTAssertNil(memo.size(forWidth: 0))
    }

    func testItForgetsWhenTheWordsChange() {
        var memo = SelectableTextSizeMemo()
        memo.record(width: 320, size: CGSize(width: 320, height: 44))
        memo.invalidate()

        XCTAssertNil(
            memo.size(forWidth: 320),
            "a memo that survives new text would report the old height for the new words, which is a row that lies about its size"
        )
    }

    func testAFreshMemoAnswersNothing() {
        let memo = SelectableTextSizeMemo()
        XCTAssertNil(memo.size(forWidth: 320))
    }

    func testARecordedSizeReplacesTheOneBeforeIt() {
        var memo = SelectableTextSizeMemo()
        memo.record(width: 320, size: CGSize(width: 320, height: 44))
        memo.record(width: 280, size: CGSize(width: 280, height: 66))

        XCTAssertEqual(memo.size(forWidth: 280), CGSize(width: 280, height: 66))
        XCTAssertNil(memo.size(forWidth: 320), "only the last width is remembered, deliberately")
    }
}
