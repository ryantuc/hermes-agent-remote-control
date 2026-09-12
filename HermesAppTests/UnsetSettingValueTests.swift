import HermesServeKit
import XCTest

@testable import HermesMobile

/// BUG-042 — the two Settings rows that started misrendering when upstream
/// removed their seeded defaults.
///
/// Both are the same mistake in two places: the phone treated "the backend did
/// not report this key" as "there is nothing to say". For these two keys there
/// is something to say, and it is not the same thing for both — an absent
/// `agent.max_turns` means *unlimited*, an absent `stt.provider` means *the
/// backend will pick one*. Rendering either as blank, or dropping its row, tells
/// the user something false rather than nothing.
///
/// Checked against a real backend's own `config.yaml` while writing this:
/// `agent.max_turns: null` at line 60, so A reproduces on that install; `stt.provider: nous` is set explicitly,
/// so B does not reproduce here and needs a config without it.
final class UnsetSettingValueTests: XCTestCase {

    // MARK: - A. agent.max_turns

    private var maxTurns: SettingRowDescriptor {
        SettingsCatalog.advanced.sections
            .flatMap(\.rows)
            .first { $0.key == "agent.max_turns" }!
    }

    /// The defect exactly as filed: `null` fails `coercedDouble` and used to
    /// fall through to an empty trailing value.
    func testANullTurnCapReadsUnlimited() {
        XCTAssertEqual(maxTurns.numberDisplay(.null, integer: true), "Unlimited")
    }

    /// The other shape the same removal can produce — a backend whose merged
    /// document omits the key rather than nulling it. The row must still be
    /// there to say so, which is what `unsetLabel` also licenses.
    func testAnAbsentTurnCapReadsUnlimited() {
        XCTAssertEqual(maxTurns.numberDisplay(nil, integer: true), "Unlimited")
        XCTAssertEqual(maxTurns.unsetLabel, "Unlimited")
    }

    /// A real cap still reads as a number.
    func testAnExplicitCapReadsAsItsNumber() {
        XCTAssertEqual(maxTurns.numberDisplay(.number(500), integer: true), "500")
        XCTAssertEqual(maxTurns.numberDisplay(.string("120"), integer: true), "120")
    }

    /// The backend takes five other spellings of "no limit"
    /// (`hermes_cli.config.resolve_turn_limit`). A row that printed `0` or
    /// `none` where the agent runs uncapped is the same lie as a blank one.
    func testEverySpellingOfUnlimitedReadsUnlimited() {
        for value: JSONValue in [
            .number(0), .number(-1), .string("none"), .string("null"),
            .string("unlimited"), .string("infinite"), .string("infinity"),
            .string("inf"), .string("∞"), .string("  None  "), .string(""),
        ] {
            XCTAssertEqual(
                maxTurns.numberDisplay(value, integer: true), "Unlimited",
                "\(value) is a spelling of unlimited on the backend"
            )
        }
    }

    /// Bools are rejected by the backend's resolver on purpose (a Python bool
    /// is an int, and `True` must not become a cap of 1), so they are not
    /// unlimited here either.
    func testABoolIsNotUnlimited() {
        XCTAssertNotEqual(maxTurns.numberDisplay(.bool(true), integer: true), "Unlimited")
    }

    /// A numeric row with no `unsetLabel` keeps the old behaviour exactly: no
    /// name for absence, and `0` is a genuine zero.
    func testAnOrdinaryNumericRowIsUnchanged() {
        let bytes = SettingRowDescriptor(
            "tool_output.max_bytes", "Output cap (bytes)", kind: .number(integer: true)
        )
        XCTAssertEqual(bytes.numberDisplay(nil, integer: true), "")
        XCTAssertEqual(bytes.numberDisplay(.null, integer: true), "")
        XCTAssertEqual(bytes.numberDisplay(.number(0), integer: true), "0")
        XCTAssertEqual(bytes.numberDisplay(.number(65_536), integer: true), "65536")
    }

    /// The editor half. Clearing the field used to parse as nothing and Save
    /// did nothing at all, so a cap could be set and never removed.
    func testClearingTheFieldWritesAnUnlimitedTheBackendAccepts() {
        let written = maxTurns.editedValue("", numeric: true)
        XCTAssertEqual(written, .number(0), "0 is a first-class spelling of no limit")
        XCTAssertEqual(
            maxTurns.numberDisplay(written, integer: true), "Unlimited",
            "and it must read back as the word, not as zero"
        )
    }

    func testClearingAnOrdinaryNumericFieldStillWritesNothing() {
        let bytes = SettingRowDescriptor(
            "tool_output.max_bytes", "Output cap (bytes)", kind: .number(integer: true)
        )
        XCTAssertNil(bytes.editedValue("", numeric: true))
        XCTAssertNil(bytes.editedValue("   ", numeric: true))
    }

    func testTypingACapStillWritesTheNumber() {
        XCTAssertEqual(maxTurns.editedValue("40", numeric: true), .number(40))
        XCTAssertNil(maxTurns.editedValue("forty", numeric: true))
    }

    /// The row says what an empty field will do before the user does it — the
    /// follow-on the report flagged: capping a now-unlimited agent by accident.
    func testTheRowExplainsWhatUnsetMeans() throws {
        let description = try XCTUnwrap(maxTurns.description)
        XCTAssertTrue(description.lowercased().contains("unlimited"))
    }

    // MARK: - B. stt.provider

    func testAnUnsetProviderReadsAuto() {
        let document: JSONValue = .object([
            "stt": .object(["enabled": .bool(true), "language": .string("en")]),
            "tts": .object(["provider": .string("elevenlabs")]),
        ])

        XCTAssertEqual(BackendProviderLabel.text(at: "stt.provider", in: document), "Auto")
        XCTAssertEqual(BackendProviderLabel.text(at: "tts.provider", in: document), "elevenlabs")
    }

    func testAnExplicitProviderReadsItself() {
        let document: JSONValue = .object([
            "stt": .object(["provider": .string("nous")]),
        ])
        XCTAssertEqual(BackendProviderLabel.text(at: "stt.provider", in: document), "nous")
    }

    /// The shapes that are "unset" without being absent.
    func testEmptyAndNullProvidersReadAuto() {
        XCTAssertEqual(
            BackendProviderLabel.text(at: "stt.provider", in: .object(["stt": .object(["provider": .string("")])])),
            "Auto"
        )
        XCTAssertEqual(
            BackendProviderLabel.text(at: "stt.provider", in: .object(["stt": .object(["provider": .string("  ")])])),
            "Auto"
        )
        XCTAssertEqual(
            BackendProviderLabel.text(at: "stt.provider", in: .object(["stt": .object(["provider": .null])])),
            "Auto"
        )
        XCTAssertEqual(
            BackendProviderLabel.text(at: "stt.provider", in: .object([:])),
            "Auto"
        )
    }
}
