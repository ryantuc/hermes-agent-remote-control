import XCTest

@testable import HermesMobile

/// The second delivery form for media: an agent that writes a markdown link or image to a media file instead of a `MEDIA:` line. `MarkdownText` renders links as words and acts on no URL, so the link is lifted out before the words reach it and drawn as the same thumbnail or poster a directive gets.
final class MarkdownMediaLinkTests: XCTestCase {

    // MARK: Edge cases

    /// A link inside a fenced example is the model's text about markdown, not a delivery; cutting it out would change the sample.
    func testALinkInsideAFencedBlockIsLeftInTheCode() {
        let source = "Write it like this:\n```markdown\n![diagram](https://example.com/diagram.png)\n```\nand the image shows."
        let result = MediaDirective.extract(from: source)
        XCTAssertTrue(result.refs.isEmpty, "lifted \(result.refs.map(\.path)) out of a code fence")
        XCTAssertEqual(result.text, source)
    }

    func testALinkInsideInlineCodeIsLeftAlone() {
        let source = "The syntax is `![alt](/tmp/out/plot.png)` on its own line."
        let result = MediaDirective.extract(from: source)
        XCTAssertTrue(result.refs.isEmpty)
        XCTAssertEqual(result.text, source)
    }

    func testALinkAfterAFenceIsStillLifted() {
        let source = "```\ncode\n```\n![plot](/tmp/out/plot.png)"
        let result = MediaDirective.extract(from: source)
        XCTAssertEqual(result.refs.map(\.path), ["/tmp/out/plot.png"])
    }

    func testAMarkdownImageOfAHostPathBecomesAThumbnailAndLeavesNoWords() {
        let result = MediaDirective.extract(from: "Here is the render:\n![the chart](C:\\Users\\you\\Downloads\\chart.png)\nDone.")
        XCTAssertEqual(result.refs.map(\.path), [#"C:\Users\you\Downloads\chart.png"#])
        XCTAssertEqual(result.refs.first?.kind, .image)
        XCTAssertEqual(result.refs.first?.name, "chart.png")
        XCTAssertEqual(result.text, "Here is the render:\n\nDone.")
    }

    func testAMarkdownLinkToAVideoKeepsItsWordsAndAddsAPoster() {
        let result = MediaDirective.extract(from: "Watch [the clip](/tmp/out/clip.mp4) when you can.")
        XCTAssertEqual(result.refs.map(\.path), ["/tmp/out/clip.mp4"])
        XCTAssertEqual(result.refs.first?.kind, .video)
        XCTAssertEqual(result.text, "Watch the clip when you can.")
    }

    func testAPublicImageURLIsLiftedToo() {
        let result = MediaDirective.extract(from: "![](https://fal.media/files/abc/out.jpg)")
        XCTAssertEqual(result.refs.map(\.path), ["https://fal.media/files/abc/out.jpg"])
        XCTAssertEqual(result.text, "")
    }

    func testALinkToADocumentOrAPageIsLeftToTheRenderer() {
        for source in [
            "Read [the review](C:\\Users\\you\\Downloads\\review.md) first.",
            "See [the docs](https://example.com/guide) for more.",
            "Open [the sheet](C:\\Users\\you\\Downloads\\numbers.xlsx).",
        ] {
            let result = MediaDirective.extract(from: source)
            XCTAssertTrue(result.refs.isEmpty, "\(source) produced \(result.refs)")
            XCTAssertEqual(result.text, source)
        }
    }

    func testARelativeTargetIsNotSomethingThePhoneCanFetch() {
        let result = MediaDirective.extract(from: "![plot](plots/out.png)")
        XCTAssertTrue(result.refs.isEmpty)
        XCTAssertEqual(result.text, "![plot](plots/out.png)")
    }

    func testADirectiveAndALinkToTheSameFileAreOneRef() {
        let result = MediaDirective.extract(from: "MEDIA:/tmp/out/clip.mp4\nAlso [here](/tmp/out/clip.mp4).")
        XCTAssertEqual(result.refs.map(\.path), ["/tmp/out/clip.mp4"])
        XCTAssertEqual(result.text, "Also here.")
    }

    func testAStreamingMessageDoesNotLiftLinksYet() {
        let result = MediaDirective.extractCompleted(from: "![plot](/tmp/out/plot.pn")
        XCTAssertTrue(result.refs.isEmpty, "a link still arriving may be half a path")
    }
}
