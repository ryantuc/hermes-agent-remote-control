import XCTest

@testable import HermesServeKit

/// The desktop scrape's behavior, held to on iOS (03-WIRE-UP gotcha 9: same
/// regexes, same key hints, same dedupe — the clients must agree on what
/// counts as an artifact).
final class ArtifactScrapeTests: XCTestCase {
    private func collect(_ messages: [ArtifactScrape.Message]) -> [ArtifactScrape.Record] {
        ArtifactScrape.collect(sessionID: "s1", sessionTitle: "Test session", messages: messages)
    }

    func testMarkdownImageAndLinkAndBareURL() {
        let text = """
        Here you go: ![chart](/tmp/out/chart.png)
        The write-up is in [the report](/tmp/out/report.pdf).
        Docs: https://example.com/guide
        """
        let records = collect([.init(role: "assistant", text: text, timestamp: 10)])
        let byValue = Dictionary(uniqueKeysWithValues: records.map { ($0.value, $0) })

        XCTAssertEqual(byValue["/tmp/out/chart.png"]?.kind, .image)
        XCTAssertEqual(byValue["/tmp/out/report.pdf"]?.kind, .file)
        XCTAssertEqual(byValue["https://example.com/guide"]?.kind, .link)
        XCTAssertEqual(byValue["/tmp/out/chart.png"]?.label, "chart.png")
        XCTAssertEqual(records.first?.sessionTitle, "Test session")
    }

    func testBarePathsAndTrailingPunctuationNormalize() {
        let records = collect([
            .init(role: "assistant", text: "Wrote the summary (see /tmp/notes/summary.txt)."),
        ])
        XCTAssertEqual(records.map(\.value), ["/tmp/notes/summary.txt"])
        XCTAssertEqual(records.first?.kind, .file)
    }

    func testUserMessagesAreIgnoredAndDuplicatesCollapse() {
        let records = collect([
            .init(role: "user", text: "look at /tmp/secret.txt please"),
            .init(role: "assistant", text: "Saved to /tmp/a.json"),
            .init(role: "assistant", text: "Again: /tmp/a.json"),
        ])
        XCTAssertEqual(records.map(\.value), ["/tmp/a.json"], "user rows skipped, dedupe on value")
    }

    func testToolCallValuesNeedAKeyHint() {
        let calls: JSONValue = .array([
            .object([
                "name": .string("write_file"),
                "arguments": .object([
                    "path": .string("/tmp/data.csv"),
                    "note": .string("/tmp/ignored-no-hint.csv"),
                ]),
            ]),
        ])
        let records = collect([
            .init(role: "assistant", text: "", toolCalls: calls),
        ])
        // `path` matches the key-hint regex; `note` does not.
        XCTAssertEqual(records.map(\.value), ["/tmp/data.csv"])
    }

    func testToolResultJSONIsWalkedWithHints() {
        let result = #"{"output": "/tmp/render/frame.png", "count": 3}"#
        let records = collect([
            .init(role: "tool", text: result),
        ])
        XCTAssertEqual(records.map(\.value), ["/tmp/render/frame.png"])
        XCTAssertEqual(records.first?.kind, .image)
    }

    func testPlainProseYieldsNothing() {
        let records = collect([
            .init(role: "assistant", text: "All done. The tests pass and nothing was written."),
        ])
        XCTAssertTrue(records.isEmpty)
    }
}
