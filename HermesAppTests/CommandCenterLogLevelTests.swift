import XCTest

@testable import HermesMobile

/// BUG-146 (`CommandCenterView.swift` log counts and the log sheet's ink): a line was an error when it contained `" ERROR "` anywhere, with a literal space on both sides.
///
/// The backend decides a line's level with `_LEVEL_RE = \s(DEBUG|INFO|WARNING|ERROR|CRITICAL)\s` and takes the FIRST match (`hermes_cli/logs.py:60`, `_extract_level` at `:86-88`), and its `level=ERROR` filter keeps CRITICAL too (`_LEVEL_ORDER`, `:64`, applied at `:115-118`). Lines arrive from `/api/logs` with their trailing newline (`_read_last_n_lines`, `:246-247` `readlines()`, `:275` `+ "\n"`). So the substring rule disagreed with the backend in four ways: a CRITICAL line was uncounted and drawn as plain text, an INFO line that mentions ERROR in its message was counted as an error, a WARNING line that mentions ERROR was inked as an error, and a level followed by a tab or the line's own newline was missed. The phone now reads each line's level as the backend does, so a line it counts or inks as an error is one the backend's ERROR filter returns (the System tab's counts and the filtered sheet still read different windows, 200 lines unfiltered against 300 matching lines).
final class CommandCenterLogLevelTests: XCTestCase {

    /// The format the backend writes (`hermes_logging.py` `_LOG_FORMAT`): `asctime levelname[session_tag] name: message`, newline-terminated.
    func testOrdinaryLinesReadAtTheirLevel() {
        XCTAssertEqual(LogLineLevel.of("2026-10-02 12:00:01,000 ERROR gateway.run: boom\n"), .error)
        XCTAssertEqual(LogLineLevel.of("2026-10-02 12:00:01,000 WARNING [sess_ab12] tools.terminal_tool: slow\n"), .warning)
        XCTAssertEqual(LogLineLevel.of("2026-10-02 12:00:01,000 INFO gateway.run: ready\n"), .other)
        XCTAssertEqual(LogLineLevel.of("2026-10-02 12:00:01,000 DEBUG agent: tick\n"), .other)
        XCTAssertEqual(LogLineLevel.of("  File \"run.py\", line 3, in <module>\n"), .other, "a traceback frame carries no level")
    }

    /// The backend's ERROR filter returns CRITICAL lines, so the error count and ink must include them.
    func testACriticalLineIsAnError() {
        XCTAssertEqual(LogLineLevel.of("2026-10-02 12:00:01,000 CRITICAL gateway.run: cannot bind\n"), .error)
    }

    /// The first level word is the line's level; a later one is message text.
    func testALevelWordInTheMessageDoesNotChangeTheLevel() {
        XCTAssertEqual(LogLineLevel.of("2026-10-02 12:00:01,000 INFO tools.grep: 3 lines matched ERROR in build.log\n"), .other)
        XCTAssertEqual(LogLineLevel.of("2026-10-02 12:00:01,000 WARNING agent: retrying after ERROR from provider\n"), .warning)
    }

    /// `\s` is any whitespace, including the newline every line arrives with and a tab.
    func testALevelDelimitedByOtherWhitespaceIsRead() {
        XCTAssertEqual(LogLineLevel.of("2026-10-02 12:00:01,000 ERROR\n"), .error, "the level is last on the line, followed only by its newline")
        XCTAssertEqual(LogLineLevel.of("12:00:01\tWARNING\tagent: x"), .warning)
    }

    /// A word that only starts with a level name is not one.
    func testALongerWordIsNotALevel() {
        XCTAssertEqual(LogLineLevel.of("2026-10-02 12:00:01,000 INFO agent: ERRORS cleared\n"), .other)
        XCTAssertEqual(LogLineLevel.of("ERROR at the very start has no whitespace before it\n"), .other, "the backend's pattern needs whitespace on both sides")
    }
}
