import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// BUG-117 — the brain icon gave no feedback, and the first question was whether it did anything at all.
///
/// It copied. `MessageActionRow` wrote `UIPasteboard.general.string = entry.reasoning` on every tap and had done since BUG-044 moved the trace's copy out of the assistant bubble's context menu. It also already carried the accessibility label "Copy reasoning". So the defect was never a no-op — it was three silent channels at once: the icon did not change, no words appeared, and the haptic was `UISelectionFeedbackGenerator().selectionChanged()` on a generator that had never been `prepare()`d, which the Taptic Engine can drop outright on a first use. A control with no consequence and no acknowledgement is indistinguishable from a dead one.
///
/// These tests pin the two halves that a photograph cannot see: **which text each button copies** — because a brain that quietly copied the answer would look exactly like a brain that works — and **what each one says back**.
final class CopyConfirmationTests: XCTestCase {

    private let answer = "The suite is green: 348 kit, 555 app, 8 UI."
    private let trace = "Let me check the gate log before answering. The kit target ran first…"

    private var entry: ChatEntry {
        ChatEntry(
            id: "bug117",
            kind: .assistant,
            text: answer,
            reasoning: trace,
            status: "complete"
        )
    }

    // MARK: 1 — the finding: the brain copies the trace, not the answer

    func testTheBrainCopiesTheReasoningTraceAndNotTheAnswer() {
        XCTAssertEqual(CopyConfirmation.Kind.reasoning.payload(entry), trace, """
            the brain put "\(CopyConfirmation.Kind.reasoning.payload(entry))" on the clipboard. It is the \
            reasoning trace's copy — the truncated preview is not selectable and the expanded disclosure \
            has to be opened first, so this control is the only way to that text
            """)
        XCTAssertNotEqual(CopyConfirmation.Kind.reasoning.payload(entry), answer)
    }

    func testThePlainCopyStillCopiesTheAnswerAndNotTheTrace() {
        XCTAssertEqual(CopyConfirmation.Kind.message.payload(entry), answer)
        XCTAssertNotEqual(CopyConfirmation.Kind.message.payload(entry), trace)
    }

    /// The brain is not rendered on a reply with no trace, but the derivation
    /// must not invent one if it ever is.
    func testAReplyWithNoTraceCopiesNothingRatherThanTheAnswer() {
        let plain = ChatEntry(id: "plain", kind: .assistant, text: answer, status: "complete")
        XCTAssertEqual(CopyConfirmation.Kind.reasoning.payload(plain), "")
    }

    // MARK: 2 — the feedback

    func testEveryCopyActionSaysSomethingBack() {
        for kind in CopyConfirmation.Kind.allCases {
            XCTAssertFalse(kind.label.isEmpty, """
                \(kind) writes the clipboard and says nothing, which is the whole of BUG-117
                """)
        }
    }

    /// The two must not share a sentence. A reader who meant to copy the answer
    /// and hit the brain instead is holding a thinking trace, and "Copied"
    /// would tell them nothing is wrong.
    func testTheTwoConfirmationsAreDistinguishable() {
        XCTAssertNotEqual(
            CopyConfirmation.Kind.message.label,
            CopyConfirmation.Kind.reasoning.label
        )
        XCTAssertTrue(
            CopyConfirmation.Kind.reasoning.label.localizedCaseInsensitiveContains("reasoning"),
            """
            the brain's confirmation is "\(CopyConfirmation.Kind.reasoning.label)" and does not name what \
            was copied. This label is the only place the app ever says out loud what that control does
            """
        )
    }

    /// The report asks for roughly 1.2 s. Long enough to be read once the eye
    /// gets back to the row; short enough that it does not start reading as
    /// part of the transcript.
    func testTheConfirmationIsTransientAndNotAFlash() {
        XCTAssertGreaterThanOrEqual(CopyConfirmation.duration, 0.8, """
            \(CopyConfirmation.duration) s is a flash — gone before a reader who was looking at the text \
            they copied has looked back at the row
            """)
        XCTAssertLessThanOrEqual(CopyConfirmation.duration, 2.0, """
            \(CopyConfirmation.duration) s leaves the words on screen long enough to read as part of the \
            conversation rather than as an acknowledgement
            """)
        XCTAssertEqual(
            CopyConfirmation.durationNanoseconds,
            UInt64(CopyConfirmation.duration * 1_000_000_000),
            "the sleep the row actually waits drifted from the duration this test asserts"
        )
    }

    /// A second tap must get a full showing rather than the remainder of the
    /// first one's, which is what the token in the id is for.
    func testTwoConfirmationsOfTheSameKindAreNotTheSameValue() {
        let first = CopyConfirmation(kind: .reasoning)
        let second = CopyConfirmation(kind: .reasoning)
        XCTAssertEqual(first.kind, second.kind)
        XCTAssertNotEqual(first, second, """
            two taps produced an identical confirmation, so `.task(id:)` would not see the id change and \
            the second tap would inherit whatever was left of the first tap's 1.2 s
            """)
        XCTAssertNotEqual(first.token, second.token)
    }
}
