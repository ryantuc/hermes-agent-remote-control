import XCTest

@testable import HermesMobile

/// The collapsed reasoning preview shows the newest words of a trace in two lines.
///
/// What a screenshot of the demo chat showed: the preview laid out a 220-character window, clipped it to the bottom two lines and faded the top one with a gradient mask, so the first visible line was cut through its glyphs, and the window itself began wherever character 220 fell, usually inside a word. The preview now picks, from candidates that start on a word and say they were shortened, the longest one that fits two whole lines, so nothing is clipped and nothing is masked.
final class ReasoningPreviewTests: XCTestCase {

    /// Long enough that the last 220 characters start inside a word ("…ent runs on the person's…").
    private let trace = """
        The user wants a short description of what Hermes Agent is, for someone who has never run it. \
        I should say that the agent runs on the person's own machine, and this app is a client that \
        talks to it. Keep it to a short paragraph.
        """

    func testAShortTraceIsShownWholeAndUnmarked() {
        let short = "Keep it to a short paragraph."
        XCTAssertEqual(ReasoningPreview.candidates(for: short).first, short)
    }

    func testEveryCandidateEndsWithTheNewestText() {
        for candidate in ReasoningPreview.candidates(for: trace) {
            XCTAssertTrue(candidate.hasSuffix("Keep it to a short paragraph."), "\(candidate) lost the newest words")
        }
    }

    /// The defect: a window that starts mid-word, with nothing to say it was shortened.
    func testAShortenedCandidateStartsOnAWordAndSaysItWasShortened() {
        let candidates = ReasoningPreview.candidates(for: trace)
        XCTAssertFalse(candidates.isEmpty)
        for candidate in candidates where candidate != trace {
            XCTAssertTrue(candidate.hasPrefix("…"), "\(candidate) is a shortened trace that does not say so")
            let words = String(candidate.dropFirst())
            XCTAssertTrue(trace.hasSuffix(words), "\(candidate) is not the end of the trace")
            let start = trace.index(trace.endIndex, offsetBy: -words.count)
            XCTAssertNotEqual(words.first.map(\.isWhitespace), true, "\(candidate) starts on a space")
            if start > trace.startIndex {
                XCTAssertTrue(trace[trace.index(before: start)].isWhitespace, "\(candidate) starts in the middle of a word")
            }
        }
    }

    /// There has to be a candidate short enough for two lines on the narrowest phone at the largest default size, or the layout falls back to truncating.
    func testTheCandidatesShrinkToOneThatFitsTwoNarrowLines() {
        let candidates = ReasoningPreview.candidates(for: trace + " " + trace)
        XCTAssertGreaterThan(candidates.count, 1, "one candidate is a clip waiting to happen")
        for (longer, shorter) in zip(candidates, candidates.dropFirst()) {
            XCTAssertGreaterThan(longer.count, shorter.count, "candidates must get shorter")
        }
        XCTAssertLessThanOrEqual(candidates.last?.count ?? .max, 64)
    }

    func testWhitespaceAndLineBreaksAtTheEdgesAreNotShown() {
        let candidates = ReasoningPreview.candidates(for: "\n\n  Thinking about it.\n")
        XCTAssertEqual(candidates.first, "Thinking about it.")
    }
}
