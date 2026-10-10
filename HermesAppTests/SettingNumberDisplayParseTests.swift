import HermesServeKit
import XCTest

@testable import HermesMobile

/// BUG-146 (`SettingsDescriptors.swift` `numberDisplay`): on a row with an `unsetLabel`, anything the numeric coercion could not read rendered as that label.
///
/// Measured against the backend's own reader (`hermes_cli/config.py` `resolve_turn_limit`, upstream source), the filed case is right and one neighbour is not. A string the resolver cannot parse resolves to the caller's `default`, exactly as an absent key does (`:1894-1895`, `:1904-1911`), so drawing it with the label this row uses for absent is the faithful reading, and these tests pin it. But the resolver strips whitespace before it parses (`raw.strip()`, `:1899`), so `" 40 "` is a cap of 40 there, while Swift's `Double(_:)` rejects leading and trailing whitespace and the row read "Unlimited". The display now strips the way the resolver does, for the unlimited spellings as well as for numbers.
final class SettingNumberDisplayParseTests: XCTestCase {

    private var maxTurns: SettingRowDescriptor {
        SettingsCatalog.advanced.sections
            .flatMap(\.rows)
            .first { $0.key == "agent.max_turns" }!
    }

    /// The defect: a padded number is a cap on the backend, not an unset value.
    func testAPaddedNumberReadsAsTheNumberTheBackendParses() {
        XCTAssertEqual(maxTurns.numberDisplay(.string(" 40 "), integer: true), "40")
        XCTAssertEqual(maxTurns.numberDisplay(.string("\t25\n"), integer: true), "25")
        XCTAssertEqual(maxTurns.numberDisplay(.string("120 "), integer: true), "120")
    }

    /// Stripping must not turn a padded spelling of "no limit" into a number: `"\n0\n"` strips to `0`, which the resolver treats as unlimited.
    func testAPaddedSpellingOfUnlimitedStillReadsUnlimited() {
        for raw in ["\n0\n", " -1 ", " none\n", "\tunlimited\t", "\n"] {
            XCTAssertEqual(maxTurns.numberDisplay(.string(raw), integer: true), "Unlimited", "\(raw.debugDescription) is unlimited on the backend")
        }
    }

    /// The filed case, pinned as correct: an unparseable value resolves to the same default as an absent key, so it carries the same label.
    func testAnUnparseableValueReadsAsTheAbsentKeyDoes() {
        let absent = maxTurns.numberDisplay(nil, integer: true)
        for value: JSONValue in [.string("abc"), .string("12 steps"), .array([]), .object([:])] {
            XCTAssertEqual(maxTurns.numberDisplay(value, integer: true), absent, "\(value) resolves to the backend's default, as absence does")
        }
    }

    /// A row with no `unsetLabel` parses the same way, so a padded number is drawn as its number rather than with its padding.
    func testAnOrdinaryRowStripsAPaddedNumberToo() {
        let bytes = SettingRowDescriptor("tool_output.max_bytes", "Output cap (bytes)", kind: .number(integer: true))
        XCTAssertEqual(bytes.numberDisplay(.string(" 65536 "), integer: true), "65536")
        XCTAssertEqual(bytes.numberDisplay(.string("abc"), integer: true), "abc", "an ordinary row still shows what it cannot read")
    }
}
