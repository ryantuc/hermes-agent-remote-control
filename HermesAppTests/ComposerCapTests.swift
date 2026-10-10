import HermesServeKit
import SwiftUI
import UIKit
import XCTest

@testable import HermesMobile

/// **BUG-039 and BUG-040 — the composer's cap, and what it costs the screen.**
///
/// Two defects reported off one measurement and fixed in two places, because
/// they are two defects:
///
/// - **BUG-039** is inside the field. Its cap was computed as
///   `16 * font.lineHeight + insets` while TextKit laid the same font out at a
///   different height per line, so the "16 line" cap was 1.33 pt short of
///   sixteen lines. The field turned scrolling on *at its own cap* and clipped
///   the line the user was looking at.
/// - **BUG-040** is outside it. The cap was a number of lines and never a
///   number of points of screen, so a full draft plus the control row came to
///   more than a portrait viewport has above the keyboard — and the control row
///   carrying the model selector went under it, with no way back but deleting
///   the draft.
///
/// Fixing 039 alone makes 040 one third of a point worse; fixing 040 alone
/// leaves the sliver. They share a file and a number and nothing else.
///
/// **What these tests can and cannot prove.** They measure rendered heights in
/// a real `UIWindow`, which is what `SessionActivityStripLayoutTests` does and
/// the only kind of proof this project has ever had about a layout. No test
/// here raises a keyboard — nothing in this suite has ever typed — so the
/// keyboard's own height is modelled from published portrait figures the way
/// `SessionActivityStripLayoutTests.testThereIsStillAConversationLeftUnder…`
/// models it. The claim that the *viewport measurement itself* shrinks when the
/// keyboard rises is SwiftUI's keyboard safe-area behaviour and is closed on
/// the phone, not here.
@MainActor
final class ComposerCapTests: XCTestCase {

    /// iPhone 17 Pro portrait width.
    private static let width: CGFloat = 402

    /// The composer's own rule, restated here rather than imported, so a change
    /// to the production constant has to come back through this file.
    private static let viewportShare: CGFloat = 2.0 / 3.0

    // MARK: - The field (BUG-039)

    private final class Box {
        var value: String
        init(_ value: String) { self.value = value }
    }

    private final class FocusBox {
        var value = false
    }
    private let focus = FocusBox()

    /// A field holding exactly `lines` hard-wrapped lines, hosted under
    /// `.fixedSize` so it takes the height it asks for.
    private func field(lines: Int) -> GrowingComposerField.ComposerTextView {
        let box = Box(Array(repeating: "A", count: lines).joined(separator: "\n"))
        let host = UIHostingController(rootView: AnyView(VStack(alignment: .leading, spacing: 0) {
            GrowingComposerField(
                text: Binding(get: { box.value }, set: { box.value = $0 }),
                placeholder: "Compose",
                textColor: .gray,
                isFocused: Binding(get: { [focus] in focus.value }, set: { [focus] in focus.value = $0 })
            )
            .fixedSize(horizontal: false, vertical: true)
        }))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 360, height: 800))
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()
        let textView = findTextView(in: host.view)!
        window.isHidden = true
        return textView
    }

    private func height(lines: Int) -> CGFloat { field(lines: lines).frame.height }

    private func findTextView(in view: UIView) -> GrowingComposerField.ComposerTextView? {
        if let textView = view as? GrowingComposerField.ComposerTextView { return textView }
        for subview in view.subviews {
            if let found = findTextView(in: subview) { return found }
        }
        return nil
    }

    /// The full laid-out height of everything the field holds, scrollable or
    /// not — the same call the field's own height policy makes.
    private func contentHeight(of textView: GrowingComposerField.ComposerTextView) -> CGFloat {
        textView.sizeThatFits(
            CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude)
        ).height
    }

    /// **The assertion BUG-039 is actually about.** A draft of exactly sixteen
    /// lines is a draft *inside* a sixteen-line cap: it must not scroll, and it
    /// must be exactly as tall as sixteen lines of the growth this field was
    /// doing a line earlier.
    ///
    /// The expected height is built from fields that are nowhere near the cap —
    /// fifteen lines plus one more line of growth — so it cannot be satisfied by
    /// the cap agreeing with itself.
    ///
    /// What the shipped code did here: the cap was `16 * font.lineHeight +
    /// insets` = 306.41 pt while sixteen rendered lines take 306.67, so
    /// `isScrollEnabled` turned on **at the cap** — a sixteen-line draft in a
    /// sixteen-line field scrolled, and the field then sat at whatever offset
    /// the caret put it at.
    func testNothingIsClippedAtTheCap() {
        let step = height(lines: 3) - height(lines: 2)
        let capped = field(lines: 16)
        let expected = height(lines: 15) + step

        XCTAssertEqual(capped.frame.height, expected, accuracy: 0.05, """
            a sixteen-line draft renders \(capped.frame.height) pt where fifteen lines plus one more \
            line of growth is \(expected). A field that is not a whole number of lines tall is showing \
            a sliver of one (BUG-039)
            """)
        XCTAssertFalse(capped.isScrollEnabled, """
            a sixteen-line draft against a sixteen-line cap must not scroll — scrolling at the cap is \
            the field hiding part of a line it is tall enough to show (BUG-039)
            """)

        // Recorded, not asserted. Past the cap the field is a scroll view and a
        // partial line at the TOP is ordinary scroll behaviour: the caret is on
        // the last line, so the field is scrolled to the bottom, and the top
        // inset (12 pt) is not a whole line (18 pt), so the viewport's top edge
        // lands inside line 1 wherever the cap is put. That is the reported
        // "cut in half line 1" and no cap arithmetic removes it — only a top
        // inset that is a multiple of the line would.
        let past = field(lines: 17)
        let offset = contentHeight(of: past) - past.frame.height
        print("""
            [composer] cap \(capped.frame.height) pt · 16 lines \(contentHeight(of: capped)) pt · \
            17 lines \(contentHeight(of: past)) pt in a \(past.frame.height) pt field → scrolled to \
            the caret the viewport starts \(offset) pt in, against a \(GrowingComposerField.textInsets.top) pt \
            top inset — so \(offset - GrowingComposerField.textInsets.top) pt of line 1 is above the fold
            """)
    }

    /// The cap is a whole number of lines to a fraction of a point, not to the
    /// ±1 pt the older assertion allows.
    func testTheCapIsAWholeNumberOfLinesToAFractionOfAPoint() {
        let step = height(lines: 3) - height(lines: 2)
        XCTAssertEqual(height(lines: 40), height(lines: 1) + step * 15, accuracy: 0.05, """
            the capped field is \(height(lines: 40)) pt where sixteen lines of \(step) pt are \
            \(height(lines: 1) + step * 15) pt. A cap that is not a whole number of lines shows a \
            sliver of one (BUG-039)
            """)
    }

    /// Every height between one line and the cap is a whole number of lines.
    /// The growth was uneven before — 18 pt for the first few lines, 17.67 for
    /// the sixteenth — because the rendered height is rounded to the pixel grid
    /// after the fact rather than the line being quantised first.
    func testEveryHeightOnTheWayToTheCapIsAWholeNumberOfLines() {
        let step = height(lines: 3) - height(lines: 2)
        let one = height(lines: 1)
        for lines in 1...16 {
            XCTAssertEqual(height(lines: lines), one + step * CGFloat(lines - 1), accuracy: 0.05,
                           "\(lines) lines must be \(lines) whole lines tall, not \(height(lines: lines)) pt")
        }
    }

    /// The budget arithmetic BUG-040's cap runs on: ask for a height, get a
    /// whole number of lines that fits inside it.
    func testALineBudgetBuysWholeLines() {
        let scale = UITraitCollection.current.displayScale
        let step = height(lines: 3) - height(lines: 2)
        let one = height(lines: 1)
        for lines in 1...16 {
            let exact = one + step * CGFloat(lines - 1)
            XCTAssertEqual(GrowingComposerField.lineCount(fitting: exact, upTo: 16, displayScale: scale),
                           lines, "\(exact) pt is exactly \(lines) lines")
            XCTAssertEqual(GrowingComposerField.lineCount(fitting: exact + step - 0.5, upTo: 16, displayScale: scale),
                           lines, "half a line of slack must not buy a line")
        }
        XCTAssertEqual(GrowingComposerField.lineCount(fitting: 5, upTo: 16, displayScale: scale), 1,
                       "a budget too small for one line still has to render one")
        XCTAssertEqual(GrowingComposerField.lineCount(fitting: 10_000, upTo: 16, displayScale: scale), 16,
                       "the ceiling is a ceiling")
    }

    // MARK: - The screen (BUG-040)

    /// The three phones this app runs on, with the portrait keyboard each one
    /// raises. Screen and safe-area figures are the published ones; the
    /// keyboard heights are the same figures `SessionActivityStripLayoutTests`
    /// budgets against, and they are the one input here not derived from this
    /// repo.
    private static let phones: [(name: String, screen: CGFloat, top: CGFloat, keyboard: CGFloat)] = [
        ("iPhone SE (3rd gen)", 667, 20, 291),
        ("iPhone 16 Pro", 852, 59, 336),
        ("iPhone 17 Pro", 874, 59, 336),
    ]
    private static let navigationBar: CGFloat = 44
    /// The activity strip's whole resting budget — both groups populated, from
    /// its own test. One group, the ordinary case, is half of it.
    private static let stripBudget: CGFloat = 2 * Hit.min
    /// One line of transcript — the unit `SessionActivityStripLayoutTests`
    /// counts conversation in.
    private static let transcriptLine: CGFloat = 21

    /// A draft far past any cap, so the field is at whatever height the policy
    /// allows it and not at the height of the text.
    private static let longDraft = Array(repeating: "A", count: 40).joined(separator: "\n")

    private func measureComposer(chat: ChatModel, app: AppModel, viewport: CGFloat?) -> CGFloat {
        let host = UIHostingController(rootView: AnyView(
            ComposerView(model: chat, viewportHeight: viewport)
                .environment(app)
                .frame(width: Self.width)
        ))
        // The composer is a sibling in the middle of its host's stack and never
        // sees a safe area of its own — `SessionActivityStripLayoutTests` says
        // why this line is here.
        host.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: Self.width, height: 900))
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()
        // The chrome the cap budgets against is measured through a preference,
        // so the first pass sizes from the seed and the second from the
        // measurement. Let the second one run.
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()
        let size = host.sizeThatFits(in: CGSize(width: Self.width, height: .greatestFiniteMagnitude))
        window.isHidden = true
        return size.height
    }

    /// **The SEV-1.** A draft at the cap must leave the screen room for the
    /// control row it carries and for something of the conversation, on every
    /// phone, with the keyboard up.
    ///
    /// Before the fix the composer measured ~423 pt whatever the viewport was:
    /// more than an iPhone SE has above its keyboard in total, and more than
    /// two thirds of any of them.
    func testAFullDraftLeavesRoomForTheControlsAndTheConversation() async throws {
        let harness = await AppHarness.make()
        let chat = harness.chat(storedID: "20260818_000100_cap")
        chat.draft = Self.longDraft

        for phone in Self.phones {
            let viewport = phone.screen - phone.top - Self.navigationBar - phone.keyboard
            let composer = measureComposer(chat: chat, app: harness.app, viewport: viewport)
            let worstCase = viewport - composer - Self.stripBudget
            let ordinary = viewport - composer - Hit.min
            print("""
                [composer] \(phone.name), keyboard up: viewport \(viewport) pt · composer \(composer) pt \
                · \(ordinary) pt of conversation under one strip group, \(worstCase) pt under two
                """)

            XCTAssertLessThanOrEqual(composer, viewport * Self.viewportShare + 1, """
                \(phone.name): a full draft makes the composer \(composer) pt inside a \(viewport) pt \
                viewport. Two thirds is \(viewport * Self.viewportShare) — past that the control row \
                carrying the model selector is under the keyboard and the draft has to be deleted to \
                reach it (BUG-040)
                """)
            // The reachability floor, and it is the SEV-1: whatever else is on
            // this screen, the composer and the strip at its worst both fit.
            XCTAssertGreaterThanOrEqual(worstCase, 0, """
                \(phone.name): a full draft under a full activity strip is \(-worstCase) pt more than \
                the \(viewport) pt this screen has above its keyboard. Something goes under it, and \
                the thing at the bottom is the control row (BUG-040 / BUG-013 M2)
                """)
            // And with the strip in the state it is usually in — one group —
            // there is still a conversation behind the draft.
            XCTAssertGreaterThan(ordinary, Self.transcriptLine, """
                \(phone.name): a full draft plus one strip group leaves \(ordinary) pt — under a single \
                line of conversation
                """)
        }

        await harness.tearDown()
    }

    /// **The floor, and the bound on the floor.** Two thirds of a small enough
    /// viewport is one line of draft — an iPhone SE with the keyboard up and the
    /// connection banner down is 257 pt — and a one-line composer is a
    /// regression of its own. Three lines is the floor where three lines fit,
    /// and where they do not the field takes what does: a floor that could
    /// overflow would be BUG-040 again with a smaller number.
    func testAShortViewportKeepsThreeLinesWithoutEverOverflowing() async throws {
        let harness = await AppHarness.make()
        let resting = harness.chat(storedID: "20260818_000400_cap")
        let full = harness.chat(storedID: "20260818_000401_cap")
        full.draft = Self.longDraft

        // The composer at rest is its chrome plus one line, which is how this
        // test knows what three lines of composer should measure without
        // restating the production arithmetic.
        let chrome = measureComposer(chat: resting, app: harness.app, viewport: nil) - height(lines: 1)

        // Just enough room for three lines above the chrome; the chrome is one
        // row of controls since the one-row composer, so the viewport is
        // derived rather than fixed at the old two-row 257 pt.
        let tight: CGFloat = chrome + height(lines: 3) + 1
        let atTight = measureComposer(chat: full, app: harness.app, viewport: tight)
        print("[composer] tight viewport \(tight) pt · chrome \(chrome) pt · composer \(atTight) pt")
        XCTAssertEqual(atTight, chrome + height(lines: 3), accuracy: 0.5, """
            a \(tight) pt viewport gave the draft \(atTight - chrome) pt where three lines are \
            \(height(lines: 3)) — two thirds of a small screen is one line, and a one-line composer is \
            not a composer
            """)
        XCTAssertLessThanOrEqual(atTight, tight, "and it still fits the screen it is on")

        // Too short for the floor: it yields rather than overflowing.
        let cramped: CGFloat = chrome + height(lines: 2) - 1
        let atCramped = measureComposer(chat: full, app: harness.app, viewport: cramped)
        print("[composer] cramped viewport \(cramped) pt · composer \(atCramped) pt")
        XCTAssertLessThanOrEqual(atCramped, cramped, """
            a \(cramped) pt viewport got a \(atCramped) pt composer — the three-line floor must be \
            bounded by what the screen holds, or it is the 16-line cap again
            """)
        XCTAssertLessThan(atCramped, atTight, "and it is smaller than the one that had room")

        await harness.tearDown()
    }

    /// An unmeasured host is left exactly as it was: sixteen lines, the feature
    /// as shipped. The fix is a *ceiling that binds sooner*, not a smaller
    /// composer everywhere.
    func testWithoutAViewportTheCapIsStillSixteenLines() async throws {
        let harness = await AppHarness.make()
        let chat = harness.chat(storedID: "20260818_000200_cap")
        chat.draft = Self.longDraft

        let unmeasured = measureComposer(chat: chat, app: harness.app, viewport: nil)
        let roomy = measureComposer(chat: chat, app: harness.app, viewport: 900)
        XCTAssertEqual(unmeasured, roomy, accuracy: 0.5, """
            an unmeasured composer must rest where a composer with room to spare rests — the \
            viewport is a constraint, not a replacement for the 16-line cap
            """)

        // And the posture the user is in most of the time: keyboard down on a
        // 6.3" phone, 874 pt of screen less the top safe area, the navigation
        // bar and the home indicator. Nothing about the composer changes there,
        // which is the point of a ceiling that binds only when the screen is
        // short.
        let keyboardDown = measureComposer(chat: chat, app: harness.app, viewport: 874 - 59 - 44 - 34)
        XCTAssertEqual(keyboardDown, unmeasured, accuracy: 0.5, """
            with the keyboard down the composer measured \(keyboardDown) pt against \(unmeasured) \
            unconstrained — the viewport rule must not take lines away from a screen that has room \
            for sixteen
            """)

        await harness.tearDown()
    }

    /// **The wiring, and the closest a unit test gets to the keyboard.**
    ///
    /// The policy above is worth nothing if the screen never hands the composer
    /// its viewport, so this hosts the shipped `ChatView` in a **portrait-shaped
    /// window** — the size class has to be the real one, or the composer draws
    /// its landscape control row and the whole budget is a different budget —
    /// and takes the navigation bar and the keyboard out of it with
    /// `safeAreaInset`, which is the same mechanism SwiftUI publishes a real
    /// keyboard through. If the inset shrinks what `ComposerViewport` measures,
    /// the keyboard does too.
    ///
    /// The field is the one part of this screen a test can find: it is a
    /// `UIViewRepresentable`, so it is a real `UIView` in the hierarchy, while
    /// every control below it is drawn by SwiftUI and has no view of its own.
    func testTheChatScreenCapsItsComposerToTheScreenItHas() async throws {
        let harness = await AppHarness.make()

        // Screen, then what the navigation bar and the keyboard take out of it.
        let postures: [(name: String, screen: CGFloat, top: CGFloat, keyboard: CGFloat)] = [
            ("iPhone 17 Pro", 874, 59 + 44, 336),
            ("iPhone SE (3rd gen)", 667, 20 + 44, 291),
        ]

        for (index, posture) in postures.enumerated() {
            let chat = harness.chat(storedID: "20260818_00030\(index)_cap")
            chat.draft = Self.longDraft
            let viewport = posture.screen - posture.top - posture.keyboard

            let host = UIHostingController(rootView: AnyView(
                ChatView(model: chat)
                    .environment(harness.app)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        Color.clear.frame(height: posture.top)
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        Color.clear.frame(height: posture.keyboard)
                    }
            ))
            host.safeAreaRegions = []
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: Self.width, height: posture.screen))
            window.rootViewController = host
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
            host.view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            window.layoutIfNeeded()
            host.view.layoutIfNeeded()

            let textView = try XCTUnwrap(findTextView(in: host.view),
                                         "no composer field in the chat screen — nothing below proves anything")
            let inWindow = textView.convert(textView.bounds, to: window)
            let keyboardLine = posture.screen - posture.keyboard
            print("""
                [composer] ChatView on a \(posture.name): \(viewport) pt above the keyboard · \
                field \(textView.frame.height) pt · field bottom \(inWindow.maxY) pt against a \
                keyboard line at \(keyboardLine) pt
                """)

            XCTAssertLessThanOrEqual(textView.frame.height, viewport * Self.viewportShare, """
                \(posture.name): the screen has \(viewport) pt above the keyboard and gave its composer \
                a \(textView.frame.height) pt field. The screen has to pass the room it has down to the \
                composer, or the cap is a cap on the text and not on the screen (BUG-040)
                """)
            XCTAssertLessThanOrEqual(inWindow.maxY, keyboardLine + 0.5, """
                \(posture.name): the field itself ends \(inWindow.maxY) pt down, past the keyboard line \
                at \(keyboardLine) — so everything under it, the model selector included, is behind the \
                keyboard (BUG-040)
                """)
        }

        await harness.tearDown()
    }
}
