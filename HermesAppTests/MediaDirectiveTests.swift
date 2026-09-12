import HermesServeKit
import XCTest

@testable import HermesMobile

/// BUG-060, BUG-057 Defect 1 and FEAT-029 — the `MEDIA:` convention, which this client had never heard of.
///
/// The grammar is Desktop's, transcribed from Hermes Desktop at `de25a6971d` rather than invented, so most of what is asserted here is parity — the same tokens Desktop recognises, unquoted the same way, classified by the same extension table. Where the phone diverges it is deliberate and each divergence has its own test saying why.
///
/// The case worth stating up front: a Windows backend emits `C:\Users\you\Downloads\…`, and `AttachmentChips.isResolvablePath` accepts only `/`, `~` and `@image:`, so the feature could have shipped green and still done nothing against such a host.
@MainActor
final class MediaDirectiveTests: XCTestCase {

    // MARK: The token, in the shapes an agent actually writes it

    /// The line form an agent actually emits: a sentence, the directive on its own line, then more prose.
    func testADirectiveOnItsOwnLineBecomesARefAndLeavesTheProse() {
        let source = """
            Updated full review:
            MEDIA:C:\\Users\\you\\Downloads\\report.md
            No codebase or live-data changes were made.
            """
        let result = MediaDirective.extract(from: source)

        XCTAssertEqual(result.refs.count, 1)
        XCTAssertEqual(result.refs.first?.path, #"C:\Users\you\Downloads\report.md"#)
        XCTAssertEqual(result.refs.first?.name, "report.md")
        XCTAssertEqual(result.refs.first?.kind, .markdown)

        XCTAssertFalse(result.text.contains("MEDIA:"), "the directive is still in the prose: \(result.text)")
        XCTAssertTrue(result.text.contains("Updated full review:"))
        XCTAssertTrue(result.text.contains("No codebase or live-data changes were made."))
    }

    /// The inline form — the token inside a sentence rather than alone on a line. Desktop matches both and so does this.
    func testADirectiveInsideASentenceIsExtracted() {
        let result = MediaDirective.extract(from: "audio: MEDIA:/tmp/voice.mp3 done")
        XCTAssertEqual(result.refs.map(\.path), ["/tmp/voice.mp3"])
        XCTAssertEqual(result.refs.first?.kind, .audio)
        XCTAssertFalse(result.text.contains("MEDIA:"))
        XCTAssertTrue(result.text.contains("audio:"))
        XCTAssertTrue(result.text.contains("done"))
    }

    /// A quoted path is how a filename with spaces survives, and Desktop accepts all three quote characters. The quotes come off the path — they are syntax, not part of the name.
    func testAQuotedPathKeepsItsSpacesAndLosesItsQuotes() {
        for quote in ["\"", "'", "`"] {
            let result = MediaDirective.extract(from: "Third render. MEDIA:\(quote)/tmp/generated/demo clip.mp4\(quote)")
            XCTAssertEqual(result.refs.map(\.path), ["/tmp/generated/demo clip.mp4"],
                           "a path quoted with \(quote) did not survive")
            XCTAssertEqual(result.refs.first?.kind, .video)
        }
    }

    /// Desktop allows whitespace after the colon and its own tests cover it (`'Finished rendering. **MEDIA: /tmp/generated/demo.mp4**'`).
    func testWhitespaceAfterTheColonIsAllowed() {
        let result = MediaDirective.extract(from: "Finished rendering. MEDIA: /tmp/generated/demo.mp4")
        XCTAssertEqual(result.refs.map(\.path), ["/tmp/generated/demo.mp4"])
    }

    /// One file, named twice, is one chip. Desktop's line-then-inline ordering makes this shape common: an agent that announces a report in a sentence and then delivers it on its own line has produced one artefact.
    func testTheSameFileNamedTwiceYieldsOneRef() {
        let result = MediaDirective.extract(from: "Here it is MEDIA:/tmp/a.png\nMEDIA:/tmp/a.png")
        XCTAssertEqual(result.refs.count, 1)
    }

    /// Several distinct files keep their order, because an agent that produced three things listed them in the order it made them.
    func testSeveralFilesKeepTheirOrder() {
        let result = MediaDirective.extract(from: "MEDIA:/tmp/one.png\nMEDIA:/tmp/two.md\nMEDIA:/tmp/three.pdf")
        XCTAssertEqual(result.refs.map(\.name), ["one.png", "two.md", "three.pdf"])
        XCTAssertEqual(result.refs.map(\.kind), [.image, .markdown, .file])
    }

    /// A message with no directive is returned untouched — including its whitespace. The tidy-up only exists to close the hole a removed directive leaves, and a message that never had one must not be reflowed.
    func testAMessageWithNoDirectiveIsUntouched() {
        let source = "Just a reply.\n\nWith a second paragraph."
        let result = MediaDirective.extract(from: source)
        XCTAssertEqual(result.text, source)
        XCTAssertTrue(result.refs.isEmpty)
    }

    /// Removing a line leaves a hole. Desktop closes it the same two ways and this transcribes them: trailing spaces before a newline go, three or more newlines collapse to two.
    func testRemovingADirectiveDoesNotLeaveAGapInThePlaceItStood() {
        let result = MediaDirective.extract(from: "Before.\n\nMEDIA:/tmp/a.png\n\nAfter.")
        XCTAssertFalse(result.text.contains("\n\n\n"), "a blank hole survived: \(result.text.debugDescription)")
        XCTAssertEqual(result.text, "Before.\n\nAfter.")
    }

    /// A reply that was **only** a directive leaves no words at all, and the caller must be able to tell — the bubble should draw the chip and no empty text block above it.
    func testAMessageThatIsOnlyADirectiveLeavesNoText() {
        let result = MediaDirective.extract(from: "MEDIA:/tmp/report.md")
        XCTAssertEqual(result.text, "")
        XCTAssertEqual(result.refs.map(\.name), ["report.md"])
    }

    // MARK: Classification

    /// Desktop's extension table, spot-checked across every kind it distinguishes.
    func testTheKindComesFromTheExtensionTheWayDesktopReadsIt() {
        XCTAssertEqual(MediaDirective.kind(of: "/tmp/a.png"), .image)
        XCTAssertEqual(MediaDirective.kind(of: "/tmp/a.WEBP"), .image, "the extension is matched case-insensitively")
        XCTAssertEqual(MediaDirective.kind(of: "/tmp/a.mp3"), .audio)
        XCTAssertEqual(MediaDirective.kind(of: "/tmp/a.mov"), .video)
        XCTAssertEqual(MediaDirective.kind(of: "/tmp/a.md"), .markdown)
        XCTAssertEqual(MediaDirective.kind(of: "/tmp/a.markdown"), .markdown)
        XCTAssertEqual(MediaDirective.kind(of: "/tmp/a.pdf"), .file)
        XCTAssertEqual(MediaDirective.kind(of: "/tmp/README"), .file, "no extension is not a kind")
    }

    /// **The divergence from Desktop, stated as its own test.** Desktop keeps markdown as a separate predicate (`isMarkdownDocumentPath`) beside its four kinds; here it is a fifth kind, because the phone has to route on it — a `.md` opens the in-app renderer and everything else opens Quick Look, which shows markdown as monospaced source.
    func testMarkdownIsItsOwnKindBecauseItRoutesSomewhereElse() {
        XCTAssertEqual(MediaDirective.kind(of: "/tmp/report.md"), .markdown)
        XCTAssertNotEqual(MediaDirective.kind(of: "/tmp/report.md"), .file,
                          "markdown falling through to .file sends a report to Quick Look, which renders it as source")
    }

    /// A query string is not an extension. Desktop splits on `?` and `#` before looking, and a URL-shaped ref is the case where that matters.
    func testAQueryStringDoesNotBecomeTheExtension() {
        XCTAssertEqual(MediaDirective.kind(of: "https://example.com/a.png?v=2"), .image)
        XCTAssertEqual(MediaDirective.name(of: "https://example.com/a.png?v=2"), "a.png")
    }

    // MARK: Paths, and the Windows case that is not an edge case here

    /// The finding that would have made this feature ship dead: against a Windows backend a drive-letter path is the normal case, and the client's existing resolvability check (`/`, `~`, `@image:`) rejects every one of them. Desktop's `isFileMediaPath` has always accepted them; this transcribes it.
    func testAWindowsPathIsResolvableBecauseTheOperatorsBackendIsWindows() {
        XCTAssertTrue(MediaDirective.isResolvableFilePath(#"C:\Users\you\Downloads\report.md"#))
        XCTAssertTrue(MediaDirective.isResolvableFilePath("c:/Users/you/Downloads/report.md"))
        XCTAssertTrue(MediaDirective.isResolvableFilePath(#"\\server\share\report.md"#), "a UNC share")
    }

    func testThePosixShapesAreResolvableToo() {
        XCTAssertTrue(MediaDirective.isResolvableFilePath("/tmp/a.png"))
        XCTAssertTrue(MediaDirective.isResolvableFilePath("~/Downloads/a.png"))
        XCTAssertTrue(MediaDirective.isResolvableFilePath("file:///tmp/a.png"))
    }

    /// Something that is not a path is not a file, and must not be sent to the media route as one.
    func testAWordIsNotAPath() {
        XCTAssertFalse(MediaDirective.isResolvableFilePath("report.md"), "a bare filename has no host to resolve against")
        XCTAssertFalse(MediaDirective.isResolvableFilePath("[screenshot]"))
        XCTAssertFalse(MediaDirective.isResolvableFilePath("https://example.com/a.png"), "a URL is fetchable, not a gateway file")
    }

    /// `http(s)` and `data:` are already fetchable and skip the gateway entirely.
    func testInlineSourcesAreRecognisedSeparately() {
        XCTAssertTrue(MediaDirective.isInlineSource("https://example.com/a.png"))
        XCTAssertTrue(MediaDirective.isInlineSource("data:image/png;base64,AAAA"))
        XCTAssertFalse(MediaDirective.isInlineSource("/tmp/a.png"))
    }

    /// A Windows path's last component is not found by `NSString.lastPathComponent`, which knows one separator. The chip's label depends on this.
    func testTheNameIsTheLastComponentUnderEitherSeparator() {
        XCTAssertEqual(MediaDirective.name(of: #"C:\Users\you\Downloads\report.md"#),
                       "report.md")
        XCTAssertEqual(MediaDirective.name(of: "/tmp/generated/demo clip.mp4"), "demo clip.mp4")
        XCTAssertEqual((#"C:\Users\you\a.md"# as NSString).lastPathComponent, #"C:\Users\you\a.md"#,
                       "recorded because it is the trap: Foundation's own accessor returns the whole path here")
    }

    // MARK: Streaming

    /// **The rule the caller enforces, pinned here so the reason survives.** A partial tail satisfies the end-of-text anchor, so extraction on a half-arrived message yields a truncated path. `AssistantTurn` therefore never calls *this* entry point while `isStreaming` — it calls ``MediaDirective/extractCompleted(from:)``, which is exactly this behaviour minus the end-of-text anchor (BUG-133). Assertion unchanged; only this sentence moved with the caller.
    func testAPartialTailWouldExtractATruncatedPathWhichIsWhyStreamingIsGuarded() {
        let result = MediaDirective.extract(from: "Here it is\nMEDIA:/tmp/rep")
        XCTAssertEqual(result.refs.map(\.path), ["/tmp/rep"], """
            this is the behaviour the streaming guard exists to avoid, not a behaviour to rely on — if this \
            ever returns no refs, the guard in AssistantTurn.media can be reconsidered
            """)
    }

    /// And the completed form of the same message resolves to the real path, which is what the reader ends up with.
    func testTheCompletedFormYieldsTheWholePath() {
        let result = MediaDirective.extract(from: "Here it is\nMEDIA:/tmp/report.md\n")
        XCTAssertEqual(result.refs.map(\.path), ["/tmp/report.md"])
    }

    // MARK: Streaming, BUG-133 — a finished line is safe, only the last one is not

    /// The defect this replaces: skipping extraction for the whole message left the raw line in the prose, the markdown parser linked the bare URL, and a tap opened it in Safari. A line with a newline after it cannot grow, so it comes out during the stream like any other.
    func testAFinishedLineIsExtractedWhileStreaming() {
        let result = MediaDirective.extractCompleted(from: "Here it is\nMEDIA:/tmp/report.md\nMore text arriving")
        XCTAssertEqual(result.refs.map(\.path), ["/tmp/report.md"])
        XCTAssertFalse(result.text.contains("MEDIA:"), "the directive is still in the prose: \(result.text)")
    }

    /// And the case the old guard existed for, which stays guarded: the last line may still be half a path.
    func testAPartialTailIsNotExtractedWhileStreaming() {
        let result = MediaDirective.extractCompleted(from: "Here it is\nMEDIA:/tmp/rep")
        XCTAssertTrue(result.refs.isEmpty, "a truncated path was taken as finished: \(result.refs.map(\.path))")
        XCTAssertTrue(result.text.contains("MEDIA:/tmp/rep"), "the unfinished line must stay in the prose until it ends")
    }

    /// An inline token mid-sentence is left alone until the turn completes. There is no newline to prove it finished, and more characters can still follow it on the same line.
    func testAnInlineTokenIsLeftAloneWhileStreaming() {
        let result = MediaDirective.extractCompleted(from: "audio: MEDIA:/tmp/voice.mp3 done")
        XCTAssertTrue(result.refs.isEmpty)
        XCTAssertEqual(MediaDirective.extract(from: "audio: MEDIA:/tmp/voice.mp3 done").refs.map(\.path),
                       ["/tmp/voice.mp3"],
                       "and it is still taken once the turn completes")
    }

    /// The regression case: a directive followed by a blank line and a half-written tail, which is what a reader sees mid-stream. Nothing tappable may be left in the prose.
    func testTheOperatorsOwnMessageLeavesNoLinkInTheProseMidStream() {
        let arriving = """
            Here's the image — a wide shot of the harbour at first light:

            MEDIA: https://cdn.example.com/files/b/9f2c41a7/Xr7mQ2vKp0LtdN4sYbHc1w.png

            Want me to adjust anyth
            """
        let result = MediaDirective.extractCompleted(from: arriving)
        XCTAssertEqual(result.refs.map(\.path),
                       ["https://cdn.example.com/files/b/9f2c41a7/Xr7mQ2vKp0LtdN4sYbHc1w.png"])
        XCTAssertFalse(result.text.contains("https://"), "the URL is still in the prose, where it renders as a tappable link: \(result.text)")
        XCTAssertEqual(result.refs.first?.kind, .image)
        XCTAssertEqual(result.refs.first?.name, "Xr7mQ2vKp0LtdN4sYbHc1w.png")
    }

    // MARK: Where the bytes come from, BUG-133

    /// **The whole defect in one assertion.** `image_generate` returns a CDN URL; the loader offered it a `data:`-only decoder and then fell through to `/api/media`, which serves the gateway's own media roots and answered 403. A remote link is the phone's to fetch, and nobody else's.
    func testARemoteLinkIsThePhonesToFetch() {
        let url = "https://cdn.example.com/files/b/9f2c41a7/Xr7mQ2vKp0LtdN4sYbHc1w.png"
        XCTAssertEqual(MediaDirective.fetchPlan(for: url), .fetchRemote(URL(string: url)!))
        XCTAssertEqual(MediaDirective.fetchPlan(for: "http://box.local/out/clip.mp4"),
                       .fetchRemote(URL(string: "http://box.local/out/clip.mp4")!))
    }

    /// A `data:` URL carries its own bytes; nothing is fetched at all.
    func testADataURLIsDecodedInPlace() {
        XCTAssertEqual(MediaDirective.fetchPlan(for: "data:image/png;base64,AAAA"), .decodeDataURL)
    }

    /// Every filesystem shape stays the gateway's, including the Windows and UNC forms — this is the half that already worked and must not regress.
    func testAFilesystemPathStaysTheGateways() {
        for path in ["/tmp/a.png", "~/Downloads/a.png", #"C:\Users\you\Downloads\a.png"#, #"\\share\team\a.png"#] {
            XCTAssertEqual(MediaDirective.fetchPlan(for: path), .askGateway, "\(path) was not treated as a gateway path")
        }
    }

    /// A malformed `http(s)` string is handed to the gateway rather than reported as remote: the gateway will refuse it, which is the right answer for a broken ref and keeps the function total.
    func testAMalformedLinkFallsToTheGateway() {
        XCTAssertEqual(MediaDirective.fetchPlan(for: "https://"), .askGateway)
    }
}
