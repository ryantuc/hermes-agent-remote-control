import HermesServeKit
import XCTest

@testable import HermesMobile

/// BUG-096 defect A and BUG-109 — the settings editor's two silent outcomes.
///
/// They are one class of defect seen from two ends. Save used to consult a
/// function that answered only `JSONValue?`, and a `nil` inside a button action
/// was `guard … else { return }` — nothing written, nothing said, nothing
/// dismissed. So "clear the field to reset this" did nothing on every numeric
/// row without an `unsetLabel`, and a magnitude the app could not render was
/// happily accepted, written to the backend, and then crashed the screen it
/// came from on every subsequent draw.
///
/// `editOutcome` is the answer that can say why, and these tests are its
/// contract. `UnsetSettingValueTests` remains untouched and green: it asserts
/// `editedValue`'s original shape, which is now the thin wrapper, and the two
/// must not disagree.
final class SettingsEditorOutcomeTests: XCTestCase {

    /// The one row in the catalogue that names its unset state (BUG-042).
    private var maxTurns: SettingRowDescriptor {
        SettingsCatalog.advanced.sections
            .flatMap(\.rows)
            .first { $0.key == "agent.max_turns" }!
    }

    /// An ordinary numeric row: absence has no name, so an empty field is not
    /// a value.
    private var timeout: SettingRowDescriptor {
        SettingRowDescriptor("terminal.timeout", "Command timeout", kind: .number(integer: true))
    }

    // MARK: BUG-096 defect A — Save always says something

    func testAnEmptyFieldOnAnOrdinaryRowIsRefusedInWords() {
        let outcome = timeout.editOutcome("", numeric: true)
        XCTAssertEqual(outcome, .empty)
        XCTAssertFalse(outcome.message.isEmpty, "the sheet has to have a sentence to draw")
        XCTAssertEqual(outcome.message, "Enter a value.")
    }

    func testUnparseableTextIsRefusedInWords() {
        XCTAssertEqual(timeout.editOutcome("forty", numeric: true), .notANumber)
        XCTAssertEqual(timeout.editOutcome("12abc", numeric: true), .notANumber)
        XCTAssertEqual(
            timeout.editOutcome("forty", numeric: true).message, "Enter a number."
        )
    }

    /// BUG-042's contract, restated through the new answer: the row that names
    /// its unset state can still be returned to it, and that is a *value*, not
    /// a refusal.
    func testARowThatNamesItsUnsetStateStillWritesZero() {
        XCTAssertEqual(maxTurns.editOutcome("", numeric: true), .value(.number(0)))
        XCTAssertEqual(maxTurns.editOutcome("   ", numeric: true), .value(.number(0)))
    }

    func testAnOrdinaryNumberStillWrites() {
        XCTAssertEqual(timeout.editOutcome("120", numeric: true), .value(.number(120)))
        XCTAssertEqual(timeout.editOutcome(" 0.5 ", numeric: true), .value(.number(0.5)))
    }

    /// A text row trims and writes whatever it was given, including nothing —
    /// clearing a free-text field is how you unset it, and always was.
    func testTextRowsAreUnchanged() {
        let model = SettingRowDescriptor("model", "Default model", kind: .text(placeholder: ""))
        XCTAssertEqual(model.editOutcome("  x/y  ", numeric: false), .value(.string("x/y")))
        XCTAssertEqual(model.editOutcome("", numeric: false), .value(.string("")))
    }

    /// The wrapper and the answer must not drift: every refusal is still a nil
    /// to the old caller, every value still the same value.
    func testEditedValueAgreesWithEditOutcome() {
        for draft in ["", "   ", "forty", "120", "0.5", "1e23", "-1e30"] {
            for row in [maxTurns, timeout] {
                let outcome = row.editOutcome(draft, numeric: true)
                if case .value(let value) = outcome {
                    XCTAssertEqual(row.editedValue(draft, numeric: true), value, draft)
                } else {
                    XCTAssertNil(row.editedValue(draft, numeric: true), draft)
                }
            }
        }
    }

    // MARK: BUG-109 — the magnitude that crashed the screen

    /// The poison value never persists in the first place. This is the half
    /// that matters: the two rendering guards below stop a screen that already
    /// holds one from crashing, but only this stops the phone putting it there.
    func testAnOutOfInt64MagnitudeIsRefusedInWords() {
        for draft in ["99999999999999999999", "1e23", "-1e30", "9.3e18"] {
            XCTAssertEqual(timeout.editOutcome(draft, numeric: true), .tooLarge, draft)
        }
        XCTAssertEqual(timeout.editOutcome("1e23", numeric: true).message, "Too large.")
    }

    func testTheBoundaryIsWhereItSaysItIs() {
        XCTAssertEqual(timeout.editOutcome("9000000000000000000", numeric: true), .value(.number(9e18)))
        XCTAssertEqual(timeout.editOutcome("9200000000000000000", numeric: true), .tooLarge)
    }

    /// The exact repro from the report: paste twenty-three nines, tap Save.
    func testTheFiledReproIsRefused() {
        XCTAssertEqual(timeout.editOutcome("99999999999999999999999", numeric: true), .tooLarge)
    }

    /// `Double("inf")` parses, and an infinity would fail JSON encoding and
    /// roll back — but it must not reach the encoder at all.
    func testInfinityIsRefused() {
        XCTAssertEqual(timeout.editOutcome("inf", numeric: true), .tooLarge)
        XCTAssertEqual(timeout.editOutcome("-inf", numeric: true), .tooLarge)
    }

    // MARK: BUG-109 — the two rendering sites that trapped

    /// `numberDisplay` paints the trailing value of every `.number` row. This
    /// call **traps** on the unfixed tree — `Int(1e23)` is a crash, not a nil —
    /// so reaching the assertion at all is the test.
    func testTheTrailingValueDoesNotTrapOnAHugeNumber() {
        let text = timeout.numberDisplay(.number(1e23), integer: true)
        XCTAssertFalse(text.isEmpty)
        XCTAssertFalse(text.contains("999999"), "scientific, not twenty-three digits: \(text)")
    }

    func testTheEditorSeedDoesNotTrapOnAHugeNumber() {
        XCTAssertFalse(SettingRowDescriptor.draftText(for: 1e23).isEmpty)
        XCTAssertFalse(SettingRowDescriptor.draftText(for: -1e30).isEmpty)
    }

    /// And the ordinary values still read exactly as they did.
    func testOrdinaryNumbersRenderUnchanged() {
        XCTAssertEqual(timeout.numberDisplay(.number(500), integer: true), "500")
        XCTAssertEqual(timeout.numberDisplay(.number(0), integer: true), "0")
        XCTAssertEqual(SettingRowDescriptor.draftText(for: 500), "500")
        XCTAssertEqual(SettingRowDescriptor.draftText(for: 0.5), "0.5")
    }

    /// The number pad has a length now. It is deliberately longer than the
    /// range the backend can hold, so a person can still type the value that
    /// earns the "Too large" they need to read.
    func testTheNumberFieldHasALengthAndItClearsTheRefusableRange() {
        XCTAssertGreaterThanOrEqual(SettingRowDescriptor.numericDraftMaxLength, 20)
        XCTAssertLessThan(SettingRowDescriptor.numericDraftMaxLength, 64)
    }
}
