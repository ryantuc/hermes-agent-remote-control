import HermesServeKit
import SwiftUI
import UIKit
import XCTest

@testable import HermesMobile

/// BUG-058, second pass — the words of a reply and of a user turn sit on a read-only `UITextView`, so iOS's own selection owns the long press.
///
/// What this file can and cannot see. It can see that the view under every line of prose is a `UITextView` that is selectable, not editable and not scrolling; that the view is as tall as its wrapped lines; that inline emphasis survived the trip from `AttributedString` to UIKit; and that the text view is hidden from accessibility. It cannot see the SwiftUI element that re-states the words: the hosting view does not expose SwiftUI's synthetic elements through `accessibilityElements`, so a probe written here found nothing at all. The guard for that property is the UI suites themselves — `TranscriptBlankingUITests` and the tail suites count rows as `staticTexts` labelled with the row's words, and go blank the day the re-statement stops working. It cannot see the loupe, the drag handles or the Copy / Select All / Look Up callout — those are system UI, and no app-hosted test has ever observed them. The acceptance is a hand check on a device: drag across part of a reply and iOS's callout appears. Green here is the obstacle removed and the mechanism in place, not the callout.
@MainActor
final class SelectableTextTests: XCTestCase {
    private static let tokens = HermesTokens(skin: .nousDark, polarity: .dark)

    // MARK: Probes

    private func window<V: View>(_ view: V, width: CGFloat) -> (UIWindow, UIHostingController<AnyView>) {
        let root = view.environment(\.hermes, Self.tokens)
        let host = UIHostingController(rootView: AnyView(root))
        host.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 1200))
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()
        return (window, host)
    }

    private func textViews(under view: UIView) -> [UITextView] {
        var found: [UITextView] = []
        if let textView = view as? UITextView { found.append(textView) }
        for subview in view.subviews { found += textViews(under: subview) }
        return found
    }

    private func assertReadOnlySelectable(_ textView: UITextView, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(textView.isSelectable, "\(what): the text view is not selectable, so a long press has nothing to start", file: file, line: line)
        XCTAssertFalse(textView.isEditable, "\(what): the text view is editable, so a long press would raise the keyboard", file: file, line: line)
        XCTAssertFalse(textView.isScrollEnabled, "\(what): the text view scrolls, so it would fight the transcript for the pan and report the viewport, not the text", file: file, line: line)
        XCTAssertTrue(textView.accessibilityElementsHidden, "\(what): the text view is visible to accessibility, so it reports as a text view — the UI suites would lose the row from `staticTexts` and could take it for the composer in `textViews.firstMatch`", file: file, line: line)
        XCTAssertFalse(textView.isAccessibilityElement, "\(what): the text view is its own accessibility element", file: file, line: line)
    }

    // MARK: 1 — every line of prose

    /// Five line kinds carry a reply's words, and every one of them is on a read-only selectable text view — the same five `MarkdownTextSelectionTests` pins by count.
    ///
    /// The count moved from five to three, and that is the fix rather than a regression. A drag on a device stopped at every blank line and at every heading, which is exactly what five separate views for this fixture means — its kinds are separated by blank lines. A span is one text view, so the heading, the bullet and the numbered step share one; the quotation keeps its own because its rule is a `Rectangle` beside the words (`ProseSpan.Content.quote`); the closing paragraph follows it. The per-kind check moves from set membership to containment. Nothing asserted is weaker: every kind still has to be present, still on a read-only selectable view, and the drawn markers are still checked character for character.
    func testEveryProseLineKindIsAReadOnlySelectableTextView() {
        let source = """
        ## A heading

        - a bullet

        1. a numbered step

        > a quotation

        A paragraph with **strong** words.
        """
        let (window, host) = self.window(MarkdownText(text: source).frame(width: 402), width: 402)
        defer { window.isHidden = true }

        let views = textViews(under: host.view)
        XCTAssertEqual(views.count, 3, "the five kinds are three spans — the heading, the bullet and the step in one, the quotation in its own, the paragraph after it — and should be three text views; found \(views.count)")
        for view in views {
            assertReadOnlySelectable(view, "prose span '\(view.text ?? "")'")
        }
        let drawn = views.map { $0.text ?? "" }.joined(separator: "\n")
        for expected in ["A heading", "•\ta bullet", "1.\ta numbered step", "a quotation", "A paragraph with strong words."] {
            XCTAssertTrue(drawn.contains(expected), "no text view carries '\(expected)' — got '\(drawn)'")
        }
    }

    /// BUG-124 inverted what this asserted, deliberately.
    ///
    /// It used to say no marker is ever on the text view, which is what made a list selectable one item at a time and for ever: a marker drawn beside a merged run cannot be positioned without asking the layout manager for each paragraph's first line-fragment rect on every re-wrap. So a list's markers are real characters now — and the objection the old rule existed to prevent ("a paste would contain a character the reply never contained") is answered where it belongs, on the clipboard: `SelectableTextView.copy(_:)` substitutes the source marker, so a selection across two bullets pastes `- a\n- b`, which is exactly what the Copy button under the message already produces.
    ///
    /// The quote half is unchanged and stays here: `>` was never in the words, the bar is a `Rectangle`, and nothing about BUG-124 changes that.
    func testTheListMarkersAreOnTheTextViewAndCopyYieldsTheSourceMarkers() {
        let (window, host) = self.window(MarkdownText(text: "- a bullet\n- another bullet\n\n> a quotation").frame(width: 402), width: 402)
        defer { window.isHidden = true }
        let views = textViews(under: host.view)

        guard let list = views.first(where: { ($0.text ?? "").contains("a bullet") }) else {
            return XCTFail("no text view carries the bullet run — got \(views.map { $0.text ?? "" })")
        }
        XCTAssertTrue((list.text ?? "").hasPrefix("•"),
                      "the dot is not on the text view, so a drag cannot begin on it: '\(list.text ?? "")'")
        XCTAssertTrue((list.text ?? "").contains("another bullet"),
                      "the two bullets are not in one text view, so a drag still cannot cross them: '\(list.text ?? "")'")

        UIPasteboard.general.string = ""
        let drawn = (list.text ?? "") as NSString
        list.selectedRange = NSRange(location: 0, length: drawn.length)
        list.copy(nil)
        XCTAssertEqual(UIPasteboard.general.string, "- a bullet\n- another bullet",
                       "the clipboard carries the drawn dot instead of the marker the reply contained")

        for view in views where (view.text ?? "").contains("a quotation") {
            XCTAssertFalse((view.text ?? "").hasPrefix(">"),
                           "the quote's marker is decoration and must stay off the text")
        }
    }

    // MARK: 2 — the user's own turn

    func testTheUserBubbleIsAReadOnlySelectableTextView() {
        let user = ChatEntry(id: "bug-058-user", kind: .user, text: "A question worth quoting half of.")
        let root = MessageBubbleView(entry: user).environment(\.transcriptStyle, .session)
        let (window, host) = self.window(root.frame(width: 402), width: 402)
        defer { window.isHidden = true }

        let views = textViews(under: host.view)
        XCTAssertEqual(views.count, 1, "the user turn should be one text view; found \(views.count)")
        guard let view = views.first else { return }
        assertReadOnlySelectable(view, "user bubble")
        XCTAssertEqual(view.text, user.text)
        // A short turn hugs its bubble: the text view is not stretched to the
        // offer, or "Hi!" would ride in a full-width banner.
        XCTAssertLessThan(view.bounds.width, 300, "the user turn's text view took the whole offer (\(view.bounds.width) pt) instead of hugging its words")
    }

    // MARK: 3 — height and wrapping

    /// Narrow and it wraps; wide and it is one line of the rung's height. A text view that reported the viewport rather than the text would fail the first, and one that sized to the offer would fail the second.
    func testTheTextViewIsAsTallAsItsWrappedLines() {
        let words = "The answer, at some length, so there is something to select a part of, and then some more so it wraps."
        let view = SelectableText(words, style: HermesFont.body, color: .white)

        let (wideWindow, wideHost) = self.window(view.frame(width: 1000), width: 1000)
        defer { wideWindow.isHidden = true }
        let (narrowWindow, narrowHost) = self.window(view.frame(width: 200), width: 200)
        defer { narrowWindow.isHidden = true }

        let wide = try? XCTUnwrap(textViews(under: wideHost.view).first)
        let narrow = try? XCTUnwrap(textViews(under: narrowHost.view).first)
        guard let wide, let narrow else { return XCTFail("no text view hosted") }

        let lineHeight = HermesFont.body.uiFont.lineHeight
        XCTAssertLessThan(wide.bounds.height, lineHeight * 2, "one line at 1000 pt came out \(wide.bounds.height) pt tall against a line height of \(lineHeight)")
        XCTAssertGreaterThan(narrow.bounds.height, lineHeight * 2.5, "the same words at 200 pt did not wrap: \(narrow.bounds.height) pt tall")
        XCTAssertGreaterThan(narrow.bounds.height, wide.bounds.height)
    }

    // MARK: 4 — inline markdown survives the trip to UIKit

    func testInlineEmphasisAndCodeReachTheTextView() throws {
        let (window, host) = self.window(MarkdownText(text: "plain **strong** and _soft_ and `code`").frame(width: 402), width: 402)
        defer { window.isHidden = true }
        let view = try XCTUnwrap(textViews(under: host.view).first)
        let rendered = try XCTUnwrap(view.attributedText)
        let text = rendered.string
        XCTAssertEqual(text, "plain strong and soft and code", "the markdown syntax survived into the drawn text")

        func font(at word: String) throws -> UIFont {
            let range = try XCTUnwrap(text.range(of: word))
            let location = text.distance(from: text.startIndex, to: range.lowerBound)
            return try XCTUnwrap(rendered.attribute(.font, at: location, effectiveRange: nil) as? UIFont)
        }
        XCTAssertTrue(try font(at: "strong").fontDescriptor.symbolicTraits.contains(.traitBold), "**strong** lost its bold")
        XCTAssertTrue(try font(at: "soft").fontDescriptor.symbolicTraits.contains(.traitItalic), "_soft_ lost its italic")
        XCTAssertTrue(try font(at: "code").fontDescriptor.symbolicTraits.contains(.traitMonoSpace), "`code` lost its monospace")
        XCTAssertFalse(try font(at: "plain").fontDescriptor.symbolicTraits.contains(.traitBold), "plain words came out bold")
    }
}
