import XCTest

@testable import HermesMobile

/// BUG-130 — speech receives the transcript's markdown source, so punctuation
/// such as emphasis markers, URLs, fences and table pipes must not reach TTS.
final class ReadAloudSpeechTextTests: XCTestCase {

    @MainActor
    func testInlineFormattingAndLinksBecomeReadableText() {
        let spoken = ReadAloud.spokenText(from: "# **Fixed** the [tap](https://example.com) in `ReadAloud.swift`.")

        XCTAssertEqual(spoken, "Fixed the tap in ReadAloud.swift.")
        XCTAssertFalse(spoken.contains("**"))
        XCTAssertFalse(spoken.contains("https://"))
    }

    @MainActor
    func testFencedCodeIsReplacedByShortPlaceholder() {
        let spoken = ReadAloud.spokenText(from: "Before.\n```swift\nlet answer = 42\n```\nAfter.")

        XCTAssertEqual(spoken, "Before.\nCode block omitted.\nAfter.")
        XCTAssertFalse(spoken.contains("let answer"))
        XCTAssertFalse(spoken.contains("```"))
    }

    @MainActor
    func testPipeTableIsSpokenAsRowsWithoutPipesOrSeparator() {
        let spoken = ReadAloud.spokenText(from: "| Language | Year |\n| --- | ---: |\n| Swift | 2014 |\n| Rust | 2015 |")

        XCTAssertEqual(spoken, "Language, Year. Swift, 2014. Rust, 2015.")
        XCTAssertFalse(spoken.contains("|"))
        XCTAssertFalse(spoken.contains("---"))
    }
}
