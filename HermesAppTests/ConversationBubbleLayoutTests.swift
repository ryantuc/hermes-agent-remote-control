import HermesServeKit
import SwiftUI
import UIKit
import XCTest

@testable import HermesMobile

/// **The bot bubble, measured.**
///
/// The bot turn gets a left-aligned bubble capped at
/// 86% of the container, mirroring the user turn's right one. Both numbers are
/// worth a real measurement rather than a code read, because the user bubble's
/// cap was silently a no-op for months: `.frame(maxWidth: .infinity * 0.86)`
/// evaluates to `.infinity`, and D4 had to replace it with a
/// `containerRelativeFrame`. A cap expressed in one line of SwiftUI is exactly
/// the kind of thing that can be present in the source and absent on screen.
///
/// This measures the rendered pixels rather than the view tree, for the same
/// reason `HubBackendRowLayoutTests` measures the hosting controller instead of
/// reading `.frame(height: 56)`: the bubble is drawn by a private view inside
/// `AssistantTurn`, and what the reader gets is the ground that lands on the
/// canvas, not the modifier that asked for it.
///
/// How: host one row in a 402 pt scroll view — an iPhone 17 Pro portrait —
/// snapshot it at scale 1, then find the widest
/// horizontal run of pixels that are not the canvas colour. With a single
/// assistant entry on screen, that run *is* the bubble.
@MainActor
final class ConversationBubbleLayoutTests: XCTestCase {

    /// iPhone 17 Pro portrait. `ComposerCapTests` measures at the same width.
    private static let width: CGFloat = 402
    private static let height: CGFloat = 900
    /// `ChatView`'s transcript pads its stack by `Space.s6` on each side, but
    /// `containerRelativeFrame` measures the *scroll view*, not the padded
    /// content — so the cap is 86% of 402, inside a 370 pt content column.
    private static let cap: CGFloat = width * 0.86
    private static let gutter: CGFloat = Space.s6

    private static let prose = """
        A long enough answer to wrap several times on a phone width, because a bubble that never \
        reaches its cap cannot demonstrate the cap. This paragraph keeps going for that reason and \
        for no other, and it is deliberately one paragraph rather than several so the run this \
        test scans is uninterrupted.
        """

    // MARK: Rendering and scanning

    private struct Span {
        let minX: CGFloat
        let maxX: CGFloat
        var width: CGFloat { maxX - minX }
    }

    private func snapshot(_ entry: ChatEntry) -> UIImage {
        let tokens = HermesTokens(skin: .nousDark, polarity: .dark)
        let root = ScrollView {
            LazyVStack(alignment: .leading, spacing: Space.s7) {
                MessageBubbleView(entry: entry)
            }
            .padding(.horizontal, Self.gutter)
            .padding(.vertical, Space.s5)
        }
        .environment(\.hermes, tokens)
        .environment(\.transcriptStyle, .conversation)
        .background(tokens.canvas)
        .frame(width: Self.width, height: Self.height)

        let host = UIHostingController(rootView: AnyView(root))
        host.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: Self.width, height: Self.height))
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let bounds = CGRect(x: 0, y: 0, width: Self.width, height: Self.height)
        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
            host.view.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        window.isHidden = true
        return image
    }

    /// The widest horizontal run of non-canvas pixels in the image. The canvas
    /// colour is sampled from the bottom-right corner, which is below every row
    /// this file draws and outside a bubble capped at 86% besides.
    private func widestSpan(in image: UIImage) -> Span? {
        guard let cgImage = image.cgImage else { return nil }
        let w = cgImage.width
        let h = cgImage.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let context = CGContext(
            data: &pixels,
            width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = (y * w + x) * 4
            return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
        }
        let canvas = rgb(w - 2, h - 2)
        func isCanvas(_ x: Int, _ y: Int) -> Bool {
            let p = rgb(x, y)
            return abs(p.0 - canvas.0) < 4 && abs(p.1 - canvas.1) < 4 && abs(p.2 - canvas.2) < 4
        }

        var best: Span?
        for y in 0..<h {
            var first: Int?
            var last: Int?
            for x in 0..<w where !isCanvas(x, y) {
                if first == nil { first = x }
                last = x
            }
            guard let first, let last else { continue }
            let span = Span(minX: CGFloat(first), maxX: CGFloat(last + 1))
            if span.width > (best?.width ?? 0) { best = span }
        }
        return best
    }

    private func entry(kind: ChatEntry.Kind, text: String = ConversationBubbleLayoutTests.prose) -> ChatEntry {
        ChatEntry(id: "bubble-1", kind: kind, text: text, status: "complete")
    }

    // MARK: 0 — the harness itself

    /// If nothing renders, or the scanner cannot tell one side of the screen
    /// from the other, every number below is noise. The user turn is the
    /// control: it has shipped as a right-aligned 86% bubble since D4, in both
    /// grammars, and it is drawn by a different view than the one under test.
    func testTheScannerFindsTheUserBubbleOnTheTrailingEdge() {
        guard let span = widestSpan(in: snapshot(entry(kind: .user))) else {
            return XCTFail("""
                nothing was drawn, or every pixel matched the canvas. The snapshot harness is not \
                rendering the hosted view and no measurement in this file means anything
                """)
        }
        let leadingSlack = span.minX
        let trailingSlack = Self.width - span.maxX
        XCTAssertGreaterThan(leadingSlack, trailingSlack, """
            the user bubble measured \(span.minX)…\(span.maxX) pt — it is not sitting against the \
            trailing edge, so the scanner is not measuring what it thinks it is
            """)
        XCTAssertLessThanOrEqual(span.width, Self.cap + 1, """
            the user bubble is \(span.width) pt wide against an 86% cap of \(Self.cap) pt (D4)
            """)
    }

    // MARK: 1 — the cap

    func testTheBotBubbleIsNoWiderThanEightySixPercentOfTheContainer() {
        guard let span = widestSpan(in: snapshot(entry(kind: .assistant))) else {
            return XCTFail("the bot bubble did not render")
        }
        print("[conversation] bot bubble: \(span.minX)…\(span.maxX) pt, \(span.width) pt wide, cap \(Self.cap) pt")
        XCTAssertLessThanOrEqual(span.width, Self.cap + 1, """
            the bot bubble is \(span.width) pt wide in a \(Self.width) pt container, past the 86% \
            cap of \(Self.cap) pt. `.frame(maxWidth: .infinity * 0.86)` evaluates to `.infinity` \
            and is how the user turn's cap was silently a no-op (D4) — this has to be a \
            `containerRelativeFrame`
            """)
    }

    /// The cap is 24 pt narrower than the padded content column, so a bubble
    /// that had simply filled the available width would pass a "not wider than
    /// the screen" assertion and fail this one.
    func testTheCapIsNarrowerThanTheContentColumn() {
        guard let span = widestSpan(in: snapshot(entry(kind: .assistant))) else {
            return XCTFail("the bot bubble did not render")
        }
        let contentColumn = Self.width - 2 * Self.gutter
        XCTAssertLessThan(span.width, contentColumn, """
            the bot bubble is \(span.width) pt wide and the transcript's content column is \
            \(contentColumn) pt. The bubble is filling the column rather than capping at 86% of \
            the container, which means the cap is not being applied at all
            """)
    }

    /// A cap is a maximum, not a width. `MarkdownText` ends in
    /// `.frame(maxWidth: .infinity, alignment: .leading)` — right for a session
    /// transcript's full-width rows, and the reason every bot bubble was drawn
    /// at the full 86% no matter what it held, so "Hi!" arrived as a banner with
    /// three words in the corner of it. `hugsContent` drops that fill for the
    /// conversation bubble. Both bubbles are measured here because a hug that
    /// also collapsed the long one would satisfy either assertion alone.
    func testAShortBotReplyHugsItsContentInsteadOfFillingTheCap() {
        guard let short = widestSpan(in: snapshot(entry(kind: .assistant, text: "Hi!"))),
              let long = widestSpan(in: snapshot(entry(kind: .assistant)))
        else { return XCTFail("one of the two bubbles did not render") }

        print("[conversation] short bubble: \(short.width) pt, long bubble: \(long.width) pt, cap \(Self.cap) pt")
        XCTAssertLessThan(short.width, 120, """
            a bot bubble holding "Hi!" measured \(short.width) pt wide in a \(Self.width) pt \
            container. It is being sized by the cap rather than by its content — three characters \
            wrapped in a ground that runs most of the way across the screen reads as a banner, not \
            as a turn in a conversation
            """)
        XCTAssertGreaterThan(long.width, Self.cap - 24, """
            the long bubble measured \(long.width) pt against a cap of \(Self.cap) pt. Making the \
            short bubble hug must not stop a long answer from using the width it is entitled to
            """)
    }

    // MARK: 2 — the side

    func testTheBotBubbleIsLeadingAligned() {
        guard let span = widestSpan(in: snapshot(entry(kind: .assistant))) else {
            return XCTFail("the bot bubble did not render")
        }
        let leadingSlack = span.minX
        let trailingSlack = Self.width - span.maxX
        XCTAssertLessThanOrEqual(leadingSlack, Self.gutter + 2, """
            the bot bubble starts \(leadingSlack) pt from the leading edge, where the transcript's \
            own gutter is \(Self.gutter) pt. A left bubble that is not flush left is not the \
            speaker cue the grammar is built on
            """)
        XCTAssertGreaterThan(trailingSlack, leadingSlack, """
            the bot bubble runs \(span.minX)…\(span.maxX) pt: \(leadingSlack) pt of slack on the \
            left and \(trailingSlack) pt on the right. The bot speaks on the left and the user on \
            the right — that opposition is the whole of how a reader tells them apart without \
            avatars
            """)
    }

    /// The two bubbles are on opposite sides of the same transcript. Asserted
    /// together because either one alone is satisfied by a layout that puts
    /// both speakers on the same edge.
    func testTheTwoSpeakersSitOnOppositeEdges() {
        guard let bot = widestSpan(in: snapshot(entry(kind: .assistant))),
              let user = widestSpan(in: snapshot(entry(kind: .user)))
        else { return XCTFail("one of the two bubbles did not render") }

        XCTAssertLessThan(bot.minX, user.minX, """
            the bot bubble starts at \(bot.minX) pt and the user bubble at \(user.minX) pt — they \
            are on the same side of the transcript
            """)
        XCTAssertLessThan(bot.maxX, user.maxX, """
            the bot bubble ends at \(bot.maxX) pt and the user bubble at \(user.maxX) pt
            """)
    }
}
