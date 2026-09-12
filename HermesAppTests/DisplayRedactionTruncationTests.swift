import Foundation
import XCTest

@testable import HermesMobile

/// **BUG-123's cheapest half: `DisplayRedaction.toolOutput` used to scrub the whole result before throwing almost all of it away.**
///
/// `Redaction.text` runs twelve regular expressions over whatever it is handed, and a tool result is whatever a command printed — megabyte results are ordinary. Projecting a tool-heavy page of a few hundred rows cost seconds, nearly all of it in this call and all of it main-thread time inside the cold-open spinner. Only the first 4,000 characters can ever reach a bubble.
///
/// These pin the ordering, not the patterns — `DisplayRedactionGapTests` owns the patterns. What is asserted here is that the scrubber is not shown more than it needs, and that the visible region is scrubbed exactly as before.
final class DisplayRedactionTruncationTests: XCTestCase {

    /// A megabyte of harmless output with a live-looking key past the margin.
    private func output(secretAt offset: Int, total: Int) -> String {
        let filler = String(repeating: "x", count: offset)
        let secret = "OPENAI_API_KEY=" + "sk-proj-" + "abcdefghijklmnopqrstuvwxyz0123456789"
        let tail = String(repeating: "y", count: max(0, total - offset - secret.count))
        return filler + secret + tail
    }

    /// The claim: nothing past `limit + margin` is scanned at all, so a result of any size costs the same as one of `limit + margin`.
    func testTheScrubberIsNeverShownMoreThanTheLimitPlusItsMargin() {
        let limit = 4_000
        let margin = 1_024
        let huge = output(secretAt: limit + margin + 50, total: 200_000)
        let head = String(huge.prefix(limit + margin))

        XCTAssertEqual(
            DisplayRedaction.toolOutput(huge, limit: limit, margin: margin),
            DisplayRedaction.toolOutput(head, limit: limit, margin: margin),
            """
            a 200,000-character result and its first \(limit + margin) characters produced different \
            output, so the redaction is still reading past the margin — which is the cost this ordering \
            exists to remove
            """
        )
    }

    /// The other half of the same claim: cutting first must not let a secret through. A key that starts inside the visible region is masked exactly as it was when the whole result was scrubbed.
    func testASecretInsideTheVisibleRegionIsStillMasked() {
        let visible = output(secretAt: 100, total: 200_000)
        let shown = DisplayRedaction.toolOutput(visible)
        XCTAssertFalse(shown.contains("abcdefghijklmnop"), "a key in the first 4,000 characters escaped the scrubber")
        XCTAssertTrue(shown.hasPrefix("xxxx"), "the output around it should still read as the command printed it")
    }

    /// A secret straddling the cut is still inside the margin, which is what the margin is for: the longest shape any pattern matches is far shorter than a kilobyte.
    func testASecretStraddlingTheDisplayCutIsStillMasked() {
        let straddling = output(secretAt: 3_990, total: 200_000)
        let shown = DisplayRedaction.toolOutput(straddling)
        XCTAssertFalse(shown.contains("abcdefghijklmnop"), "a key beginning just before the 4,000-character cut escaped the scrubber")
    }

    /// Short output is untouched by any of this: no cut, and the same text out as in.
    func testShortOutputIsUnchanged() {
        let plain = "$ swift build\nBuild complete!"
        XCTAssertEqual(DisplayRedaction.toolOutput(plain), plain)
    }
}
