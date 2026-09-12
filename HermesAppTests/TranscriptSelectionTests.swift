import HermesServeKit
import SwiftUI
import UIKit
import XCTest

@testable import HermesMobile

/// BUG-044 — a message could not be part-selected: a long press highlighted the whole bubble and offered one Copy.
///
/// The mechanism is a collision, not a missing feature. `.textSelection(.enabled)` is on every transcript text surface already, but each bubble container also carried a `.contextMenu`, and a context menu installs a `UIContextMenuInteraction` whose long-press recogniser beats the text-selection interaction underneath it. So the fix is a removal — the session grammar's two menus go, `.textSelection` gets the long press it was always asking for, and the one item those menus offered that had no other home ("Copy reasoning") moves into `MessageActionRow`.
///
/// What is asserted here, and what is not: these pin the two halves of the removal that a machine can see — that a session bubble installs no context-menu interaction, and that the action row grows by one control for a turn that has a reasoning trace. Whether the loupe and the drag handles actually come up under a thumb is a hand check on a device; the selection UI is a system surface a unit test cannot observe, and a UI-driver harness is out of scope by standing decision.
///
/// **Measured here, worth knowing elsewhere: SwiftUI publishes no accessibility elements to a unit test.** The first version of this file looked for the string "Copy reasoning" by walking `accessibilityLabel`, `accessibilityElements` and the informal container protocol under the hosted row. It came back empty — `[bug-044] action row labels: []`, on the unfixed tree, for the Copy button the row has always had — because nothing materialises those elements unless an assistive technology is running. The walk was replaced by a measurement of the row's ideal width, which is the kind of evidence `ScrollToLatestHitTargetTests` and `HubBackendRowLayoutTests` already rest on.
///
/// Each probe is paired with a control that must pass on the *unfixed* tree, so a probe that has gone blind fails loudly instead of passing vacuously.
///
/// Extended by FEAT-027, and one control was rewritten. BUG-044 removed the session grammar's menus and deliberately left the conversation grammar's alone, because that menu was the only home Branch and Retry had in a bot thread. FEAT-027 gives bot threads the action row, so the menu could finally go — and the assertions that pinned it as *present* are now assertions that it is *absent*. The interaction probe's positive control moved to a synthetic view this file owns, so the next product decision about which bubbles carry menus cannot silently blind it.
///
/// This file still does not observe an iOS selection callout, and no file here does. What it observes is the obstacle; BUG-058's acceptance is a hand check on a device.
@MainActor
final class TranscriptSelectionTests: XCTestCase {

    private static let tokens = HermesTokens(skin: .nousDark, polarity: .dark)
    /// One `IconButtonStyle` control is `Hit.min` wide and the row separates its
    /// controls by `Space.s2`. The brackets around it below are deliberately
    /// loose: what is asserted is "one more control", not a pixel count.
    private static let oneControl: CGFloat = Hit.min + Space.s2

    override func setUp() {
        super.setUp()
        // `HermesAppTests` is hosted in the app, so these statics are shared
        // across every suite on the simulator and accumulate. Set, never assume.
        TranscriptPreferences.showCopyAction = true
        TranscriptPreferences.showBranchAction = true
        TranscriptPreferences.showReadAloudAction = true
        TranscriptPreferences.showRetryAction = true
    }

    // MARK: Fixtures

    private func entry(reasoning: String = "") -> ChatEntry {
        ChatEntry(
            id: "bug-044-1",
            kind: .assistant,
            text: "The answer, at some length, so there is something to select a part of.",
            reasoning: reasoning,
            status: "complete"
        )
    }

    private func actionRow(reasoning: String) -> some View {
        MessageActionRow(entry: entry(reasoning: reasoning), actions: MessageActions())
    }

    // MARK: Probes

    private func window<V: View>(_ view: V, width: CGFloat) -> (UIWindow, UIHostingController<AnyView>) {
        let root = view.environment(\.hermes, Self.tokens)
        let host = UIHostingController(rootView: AnyView(root))
        host.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 900))
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()
        return (window, host)
    }

    /// The width the row wants when nothing stretches it. `.fixedSize` collapses
    /// the trailing `Spacer(minLength: 0)` to nothing, so this is the timestamp
    /// plus the controls beside it — which is to say, how many controls there are.
    private func idealWidth<V: View>(_ view: V) -> CGFloat {
        let (window, host) = self.window(view.fixedSize(horizontal: true, vertical: false), width: 402)
        defer { window.isHidden = true }
        return host.sizeThatFits(in: CGSize(width: 10_000, height: 10_000)).width
    }

    /// How many `UIContextMenuInteraction`s are installed anywhere under a view.
    /// This is what `.contextMenu` becomes on iOS, and it is the thing that eats
    /// the long press `.textSelection` needs.
    private func contextMenuInteractions(under view: UIView) -> Int {
        // A UITextView carries UIKit's own context-menu interactions (link and
        // text-item previews). They are the selection surface, not a rival for
        // its long press — BUG-058 second pass.
        if view is UITextView { return 0 }
        var count = view.interactions.filter { $0 is UIContextMenuInteraction }.count
        for subview in view.subviews { count += contextMenuInteractions(under: subview) }
        return count
    }

    // MARK: 0 — the probes themselves

    /// **The probe's positive control. Rewritten under FEAT-027, and rewritten to be synthetic.**
    ///
    /// This used to host a **conversation** bubble and assert it installed a menu, because the conversation grammar kept its `.contextMenu` on purpose — it was the only home Branch and Retry had in a bot thread, since a 44 pt toolbar under every bot message is what the message-grouping design forbids.
    ///
    /// FEAT-027 gives bot threads the action row and deletes that menu. So the old control now measures zero, and it measures zero *because the fix worked* — which is precisely the shape of a control that has stopped controlling anything.
    ///
    /// The replacement asserts the same property against a view this file owns. That is strictly better than what it replaces: the probe's sensitivity is now independent of every product decision about which bubbles carry menus, so the next such decision cannot silently blind the three assertions that depend on it. The old version would have had to be rewritten again the next time a menu moved.
    func testTheInteractionProbeSeesAContextMenuWhenThereIsOneToSee() {
        let root = Text("Something to press and hold")
            .contextMenu { Button("Copy") {} }
        let (window, host) = self.window(root.frame(width: 402), width: 402)
        defer { window.isHidden = true }
        let count = contextMenuInteractions(under: host.view)
        print("[feat-027] synthetic control context menu interactions: \(count)")
        XCTAssertGreaterThan(count, 0, """
            no `UIContextMenuInteraction` was found under a view that plainly carries `.contextMenu`. \
            The probe is blind, so every bubble measuring zero below proves nothing
            """)
    }

    /// **FEAT-027's invariant, and the half of BUG-058 that source can settle.**
    ///
    /// The bot bubble's long-press menu is gone, so the text-selection interaction under it finally gets the gesture — the same removal BUG-044 made in the session grammar, applied to the grammar BUG-044 deliberately left alone. Whether iOS then actually raises its callout can only be confirmed by hand on a device and is not asserted anywhere; what is asserted is that the obstacle is no longer installed, which is the thing that was blocking it and the thing a machine can see.
    func testTheConversationAssistantBubbleInstallsNoContextMenu() {
        let root = MessageBubbleView(entry: entry(), actions: MessageActions())
            .environment(\.transcriptStyle, .conversation)
        let (window, host) = self.window(root.frame(width: 402), width: 402)
        defer { window.isHidden = true }
        let count = contextMenuInteractions(under: host.view)
        XCTAssertEqual(count, 0, """
            the conversation assistant bubble installs \(count) `UIContextMenuInteraction`(s). Its \
            long-press recogniser wins over the text-selection interaction underneath, which is why \
            a long press in a bot thread raises a copy/share menu instead of the loupe (BUG-058). \
            FEAT-027 moved those actions onto MessageActionRow so this could be removed
            """)
    }

    /// The user's own turn in a bot thread, which kept a Copy menu **for symmetry with the bot bubble beside it** — the honest call while that bubble had one. With the bot bubble's menu gone, keeping this would leave a thread where a reader can select the assistant's words and not their own, which is the opposite of what was asked for.
    func testTheUserBubbleInstallsNoContextMenuInAConversation() {
        let user = ChatEntry(id: "feat-027-1", kind: .user, text: "A question worth quoting half of.")
        let root = MessageBubbleView(entry: user)
            .environment(\.transcriptStyle, .conversation)
        let (window, host) = self.window(root.frame(width: 402), width: 402)
        defer { window.isHidden = true }
        let count = contextMenuInteractions(under: host.view)
        XCTAssertEqual(count, 0, """
            the user bubble installs \(count) `UIContextMenuInteraction`(s) in a bot thread — the \
            one turn a reader most often wants half of, being their own pasted path or error string
            """)
    }

    /// **The row is actually there, in both grammars.** The three assertions above are about an absence, and an absence is satisfied by rendering nothing at all: a conversation bubble that had lost its menu *and* never gained the row would pass every one of them while being strictly worse than what shipped. This measures the presence.
    ///
    /// Width, for the reason this file already establishes: SwiftUI publishes no accessibility elements to a unit test, so the row is counted rather than read.
    func testTheConversationGrammarRendersTheActionRowAndNotOnlyTheBubble() {
        let withActions = MessageBubbleView(entry: entry(), actions: MessageActions())
            .environment(\.transcriptStyle, .conversation)
        let withoutActions = MessageBubbleView(entry: entry())
            .environment(\.transcriptStyle, .conversation)

        let (windowA, hostA) = self.window(withActions.frame(width: 402), width: 402)
        defer { windowA.isHidden = true }
        let (windowB, hostB) = self.window(withoutActions.frame(width: 402), width: 402)
        defer { windowB.isHidden = true }

        let tall = hostA.sizeThatFits(in: CGSize(width: 402, height: 10_000)).height
        let short = hostB.sizeThatFits(in: CGSize(width: 402, height: 10_000)).height
        print("[feat-027] conversation bubble with row: \(tall) pt, without: \(short) pt")
        XCTAssertGreaterThan(tall - short, Hit.min - 1, """
            a completed bot message with actions is \(tall - short) pt taller than one without, which \
            is less than the 44 pt row FEAT-027 puts under it. The menu was removed and nothing \
            replaced it — Branch, Copy, Read aloud and Retry have no home in a bot thread
            """)
    }

    /// The row is per-message, not per-transcript, so a message still streaming has no row and a completed one keeps its own while a later turn runs. Desktop's action bar is deliberately *not* hidden while a turn is running, because unmounting every message's footer shifts the conversation when the turn resolves — the phone avoids that by a different route, and this pins the route.
    func testAStreamingBotMessageHasNoRowToShift() {
        let streaming = ChatEntry(id: "feat-027-2", kind: .assistant, text: "Half a th", status: "streaming")
        let root = MessageBubbleView(entry: streaming)
            .environment(\.transcriptStyle, .conversation)
        let (window, host) = self.window(root.frame(width: 402), width: 402)
        defer { window.isHidden = true }
        XCTAssertEqual(contextMenuInteractions(under: host.view), 0,
                       "a streaming bot message installs a context menu")
    }

    /// And the width probe reports the row's own width rather than the 10 000 pt
    /// it was offered — the failure mode that would make every width comparison
    /// below trivially equal.
    func testTheWidthProbeMeasuresTheRowAndNotTheOfferedSpace() {
        let width = idealWidth(actionRow(reasoning: ""))
        print("[bug-044] action row ideal width, no trace: \(width) pt")
        XCTAssertGreaterThan(width, Hit.min, "the row measured \(width) pt — narrower than one control")
        XCTAssertLessThan(width, 402, """
            the row measured \(width) pt, which is the space it was offered rather than the space \
            it wants. `.fixedSize` is not collapsing the trailing spacer, and no comparison below \
            can then tell four controls from five
            """)
    }

    // MARK: 1 — the session bubble stops claiming the long press

    func testTheSessionAssistantBubbleInstallsNoContextMenu() {
        let root = MessageBubbleView(entry: entry(reasoning: "First I considered the obvious."))
            .environment(\.transcriptStyle, .session)
        let (window, host) = self.window(root.frame(width: 402), width: 402)
        defer { window.isHidden = true }
        let count = contextMenuInteractions(under: host.view)
        XCTAssertEqual(count, 0, """
            the session assistant bubble installs \(count) `UIContextMenuInteraction`(s). Its \
            long-press recogniser wins over the text-selection interaction underneath, which is \
            why a long press highlighted the whole message and offered one Copy instead of \
            raising the loupe (BUG-044)
            """)
    }

    func testTheUserBubbleInstallsNoContextMenuInASession() {
        let user = ChatEntry(id: "bug-044-2", kind: .user, text: "A question worth quoting half of.")
        let root = MessageBubbleView(entry: user)
            .environment(\.transcriptStyle, .session)
        let (window, host) = self.window(root.frame(width: 402), width: 402)
        defer { window.isHidden = true }
        let count = contextMenuInteractions(under: host.view)
        XCTAssertEqual(count, 0, """
            the user bubble installs \(count) `UIContextMenuInteraction`(s) in a session \
            transcript. A user turn is the one a reader most often wants half of — their own \
            pasted path or error string — and the menu is what stops the selection from starting
            """)
    }

    // MARK: 2 — the trace's copy survives the removal

    /// "Copy reasoning" lived only in the bubble's context menu, so deleting that
    /// menu deletes the only way to copy a trace unless the action row picks it
    /// up. The row is the only place it can go: the truncated preview is not
    /// selectable and the expanded trace sits behind a disclosure.
    func testTheActionRowGainsAControlForATurnThatHasAReasoningTrace() {
        let bare = idealWidth(actionRow(reasoning: ""))
        let withTrace = idealWidth(actionRow(reasoning: "First I considered the obvious, then discarded it."))
        print("[bug-044] action row: \(bare) pt bare, \(withTrace) pt with a trace")

        XCTAssertGreaterThan(withTrace - bare, Self.oneControl - 8, """
            the action row is \(withTrace) pt wide for a turn with a reasoning trace and \
            \(bare) pt without one — it offers the same controls either way, so nothing on screen \
            copies the trace once the bubble's context menu is gone (BUG-044)
            """)
        XCTAssertLessThan(withTrace - bare, Self.oneControl + 20, """
            the row grew by \(withTrace - bare) pt, which is more than the one control a trace \
            should add
            """)
    }

    /// Copying a trace is copying, so it obeys the Copy preference — a reader who
    /// has switched message copying off in Settings must not find one copy button
    /// left behind. A guard on the fix rather than a red: both widths are equal
    /// on the unfixed tree too.
    func testTheReasoningControlObeysTheCopyPreference() {
        TranscriptPreferences.showCopyAction = false
        defer { TranscriptPreferences.showCopyAction = true }

        let bare = idealWidth(actionRow(reasoning: ""))
        let withTrace = idealWidth(actionRow(reasoning: "First I considered the obvious."))
        XCTAssertEqual(withTrace, bare, accuracy: 1, """
            with Copy switched off the row is still \(withTrace - bare) pt wider for a turn with \
            a trace — a copy control is surviving the preference that governs it
            """)
    }
}
