import XCTest

@testable import HermesServeKit

/// **BUG-106 — "Back up now" could not succeed, in both directions at once.**
///
/// *Going out.* `CommandCenterView` called `sendJSON("POST", "/api/ops/backup")` with no body, and `sendJSON` sends a zero-length body for `.null` — under `Content-Type: application/json`. The handler is `async def run_backup(body: BackupRequest)` (`hermes_cli/web_server.py`:14508-14509) and `BackupRequest` (`hermes_cli/web_models.py`:507-509) declares one optional field. Every field being optional does not make the body optional: the parameter carries no default, FastAPI treats the model as required, and an empty body is a missing-field validation error. HTTP 422, every time.
///
/// *Coming back.* The success payload is `{"ok", "pid", "name"}` plus `"archive"` when the server chose the path itself (`web_server.py`:14530-14533) — which it does whenever `output` is empty, so for this client always. The call site read `path` and then `file`. The route has never sent either, so even a run that worked reported "Backup finished." with no location.
///
/// Both are asserted here rather than through `RestAPI`, because the kit's tests script a gateway socket and have never needed an HTTP stub for anything, and standing one up to assert two lines of arithmetic would be the more fragile of the two options.
final class BackupCallTests: XCTestCase {

    // MARK: 1 — the body

    /// The defect itself. `.null` is what `sendJSON` turns into a zero-length
    /// body, and a zero-length body is the 422.
    func testAnEmptyOutputStillSendsAnObjectAndNeverNull() {
        let body = BackupCall.body(output: "")
        XCTAssertNotEqual(body, .null, """
            the backup body is `.null` again. `RestAPI.sendJSON` sends *no bytes* for `.null` under a \
            JSON content type, and `run_backup(body: BackupRequest)` answers a bodyless POST with a \
            422 — which is the whole of BUG-106's outbound half
            """)
        XCTAssertEqual(body, .object([:]), """
            the body is \(body) rather than `{}`. The desktop client posts exactly `{}` against this \
            same route, and the dashboard posts `{ output }`, which is the same thing when no path is \
            named
            """)
    }

    /// The one field the model has, when a caller names a path.
    func testANamedOutputPathIsCarriedOnTheBody() {
        XCTAssertEqual(
            BackupCall.body(output: "/Users/you/backups/hermes.zip"),
            .object(["output": .string("/Users/you/backups/hermes.zip")])
        )
    }

    /// The backend does `(body.output or "").strip()` and treats the result as
    /// absent when empty, so whitespace has to mean absent on this side too —
    /// or the two disagree about whether the server picks the path, which is
    /// the same disagreement that decides whether `archive` comes back.
    func testAWhitespaceOnlyOutputIsTreatedAsNoOutput() {
        XCTAssertEqual(BackupCall.body(output: "   \n "), .object([:]))
    }

    func testAnOutputPathIsTrimmedTheWayTheBackendTrimsIt() {
        XCTAssertEqual(
            BackupCall.body(output: "  /tmp/h.zip  "),
            .object(["output": .string("/tmp/h.zip")])
        )
    }

    // MARK: 2 — the envelope

    /// The payload the route actually sends when it chose the path — which is
    /// every call this client makes.
    func testTheArchivePathIsReadFromTheKeyTheRouteSends() {
        let response = JSONValue.object([
            "ok": .bool(true),
            "pid": .number(48213),
            "name": .string("backup"),
            "archive": .string("/Users/you/.hermes/backups/hermes-20260827-011500.zip"),
        ])
        XCTAssertEqual(
            BackupCall.archive(from: response),
            "/Users/you/.hermes/backups/hermes-20260827-011500.zip",
            """
            the archive path did not come back out of the success payload, so the UI would say "Backup \
            finished." with no location on a run that worked
            """
        )
    }

    /// `archive` is absent when the *caller* named the path, because the server
    /// has nothing to tell them they did not already know. Empty is the right
    /// answer there, and the view says "Backup finished." for it.
    func testAResponseWithNoArchiveKeyIsEmptyRatherThanWrong() {
        let response = JSONValue.object([
            "ok": .bool(true),
            "pid": .number(48213),
            "name": .string("backup"),
        ])
        XCTAssertEqual(BackupCall.archive(from: response), "")
    }

    /// The two keys the old call site read. Neither has ever appeared on this
    /// route; pinning that here is what stops someone reinstating them because
    /// the name reads plausibly.
    func testTheKeysTheOldCallSiteReadAreNotTheRoutesKeys() {
        let response = JSONValue.object([
            "ok": .bool(true),
            "path": .string("/wrong/key.zip"),
            "file": .string("/also/wrong.zip"),
        ])
        XCTAssertEqual(BackupCall.archive(from: response), "", """
            `path` / `file` are being read again. `POST /api/ops/backup` sends neither — it sends \
            `archive`, and only when it chose the destination itself
            """)
    }

    func testANonObjectResponseDoesNotCrashOrInventAPath() {
        XCTAssertEqual(BackupCall.archive(from: .null), "")
        XCTAssertEqual(BackupCall.archive(from: .string("ok")), "")
    }
}
