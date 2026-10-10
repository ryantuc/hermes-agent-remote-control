import XCTest

@testable import HermesServeKit

/// The two `SessionAPI` calls a Bot thread resolves through, asserted on both
/// sides of the wire: what goes out (nothing else in the kit checks outbound
/// params, and both of these are compatibility-sensitive) and what comes back.
final class SessionAPITests: XCTestCase {

    // MARK: - session.list title=

    func testLookupByTitleSendsTheTitleAndTheOlderGatewayInsurance() async throws {
        let (client, socket) = try await ScriptedGateway.connected(replies: [
            "session.list": [
                try Fixtures.result("response-session-list-title"),
                try Fixtures.result("response-session-list-title"),
            ]
        ])
        let sessions = SessionAPI(client: client)

        _ = try await sessions.lookupByTitle(BotChat.title, profile: "work")
        let sentScoped = await socket.sentParams("session.list")
        let scoped = try XCTUnwrap(sentScoped)
        XCTAssertEqual(scoped["title"]?.coercedString, "Bot Chat")
        XCTAssertEqual(scoped["profile"]?.coercedString, "work")
        // Both of these are for a gateway WITHOUT the title branch: it ignores
        // `title` and answers with its ordinary windowed listing, which is
        // hidden-filtered and limited. The title branch itself reads neither.
        XCTAssertEqual(scoped["include_hidden"]?.coercedBool, true)
        XCTAssertEqual(scoped["limit"]?.coercedInt, 200)

        // `profile` names which state.db is opened, so an empty one must be
        // omitted rather than sent as "" — the lookup is unscoped SQL and the
        // enclosing _profile_db is the only scoping there is.
        _ = try await sessions.lookupByTitle(BotChat.title, profile: "", limit: 50)
        let sentUnscoped = await socket.sentParams("session.list")
        let unscoped = try XCTUnwrap(sentUnscoped)
        XCTAssertNil(unscoped["profile"])
        XCTAssertEqual(unscoped["limit"]?.coercedInt, 50)

        await client.disconnect()
    }

    /// The pin and the id to open are two different columns, and after a
    /// compression they are two different rows.
    func testLookupByTitleReturnsTheTitleRowAndItsTipSeparately() async throws {
        let (client, _) = try await ScriptedGateway.connected(replies: [
            "session.list": [try Fixtures.result("response-session-list-title")]
        ])
        let match = try await SessionAPI(client: client).lookupByTitle(BotChat.title, profile: "work")

        let row = try XCTUnwrap(match)
        XCTAssertEqual(row.id, "20260820_101010_abc123", "pin the row that holds the title")
        XCTAssertEqual(row.resolvedID, "20260822_143000_tip999", "open the live tip")
        XCTAssertEqual(row.title, "Bot Chat")
        XCTAssertEqual(row.messageCount, 214)
        XCTAssertEqual(row.source, "desktop")
        XCTAssertEqual(row.startedAt, 1755684610.0, accuracy: 0.001)
        XCTAssertTrue(row.preview.isEmpty, "the title branch's tip row has no preview column")

        await client.disconnect()
    }

    /// The compatibility rung. An older gateway does not know `title`, ignores
    /// it, and answers with its recency window — so the first row is some
    /// unrelated conversation. Adopting it would make that conversation the
    /// bot's forever chat.
    func testLookupByTitleReturnsNilWhenAnOlderGatewayIgnoredTheParam() async throws {
        let (client, _) = try await ScriptedGateway.connected(replies: [
            "session.list": [
                try Fixtures.result("response-session-list-title", frame: 1),
                .object(["sessions": .array([])]),
            ]
        ])
        let sessions = SessionAPI(client: client)

        let windowed = try await sessions.lookupByTitle(BotChat.title, profile: "work")
        XCTAssertNil(windowed, "no row is titled exactly \"Bot Chat\"; near misses do not count")

        // The title branch's own no-match answer is an empty success, not an
        // error (archived rows and kanban/tool sources land here too).
        let empty = try await sessions.lookupByTitle(BotChat.title, profile: "work")
        XCTAssertNil(empty)

        await client.disconnect()
    }

    // MARK: - session.create hidden=

    func testCreateSendsHiddenOnlyWhenItIsTrue() async throws {
        let (client, socket) = try await ScriptedGateway.connected(replies: [
            "session.create": [
                try Fixtures.result("response-session-create-hidden"),
                try Fixtures.result("response-session-create"),
            ]
        ])
        let sessions = SessionAPI(client: client)

        let created = try await sessions.create(
            profile: "work", title: BotChat.title, hidden: true
        )
        let sentHiddenParams = await socket.sentParams("session.create")
        let hiddenParams = try XCTUnwrap(sentHiddenParams)
        XCTAssertEqual(hiddenParams["hidden"]?.coercedBool, true)
        XCTAssertEqual(hiddenParams["title"]?.coercedString, "Bot Chat")
        XCTAssertEqual(hiddenParams["profile"]?.coercedString, "work")
        // `cols`, not `columns` — the backend reads params["cols"].
        XCTAssertEqual(hiddenParams["cols"]?.coercedInt, SessionAPI.defaultColumns)
        XCTAssertEqual(hiddenParams["source"]?.coercedString, SessionAPI.sourceTag)

        // The durable key is what gets pinned; the runtime id is what
        // prompt.submit takes, and the create result is the only place both
        // appear together.
        XCTAssertEqual(created.storedSessionID, "20260823_101500_bot001")
        XCTAssertEqual(created.sessionID, "9f8e7d6c")

        _ = try await sessions.create(profile: "work")
        let sentPlainParams = await socket.sentParams("session.create")
        let plainParams = try XCTUnwrap(sentPlainParams)
        XCTAssertNil(plainParams["hidden"], "an ordinary create's wire bytes must not change")

        await client.disconnect()
    }

    // MARK: - session.create cwd_explicit=

    /// The backend's 4000 text for a key its contract does not declare: `contracts/registry.py:94-109`, `:100-115` on an older backend.
    ///
    private static func undeclared(_ key: String) -> String {
        "invalid params for session.create: \(key): Extra inputs are not permitted — the client and the "
            + "Hermes backend are out of sync (different versions); run `hermes update` and restart both"
    }

    /// On current upstream a named profile's configured folder beats the request's `cwd`
    /// unless `cwd_explicit` is true (`tui_gateway/session_workdir.py:43-45`), so the
    /// folder the phone sends must carry the flag or the chat runs somewhere else.
    func testCreateMarksTheFolderItSendsExplicit() async throws {
        let (client, socket) = try await ScriptedGateway.connected(replies: [
            "session.create": [
                try Fixtures.result("response-session-create"),
                try Fixtures.result("response-session-create"),
            ]
        ])
        let sessions = SessionAPI(client: client)

        _ = try await sessions.create(cwd: "/Users/you/projects/alpha", profile: "writer")
        let sentWithFolder = await socket.sentParams("session.create")
        let withFolder = try XCTUnwrap(sentWithFolder)
        XCTAssertEqual(withFolder["cwd"]?.coercedString, "/Users/you/projects/alpha")
        XCTAssertEqual(
            withFolder["cwd_explicit"]?.coercedBool, true,
            "without the flag a named profile's own folder silently replaces the one picked on the phone"
        )
        XCTAssertEqual(withFolder["profile"]?.coercedString, "writer")

        _ = try await sessions.create(profile: "writer")
        let sentWithout = await socket.sentParams("session.create")
        let without = try XCTUnwrap(sentWithout)
        XCTAssertNil(without["cwd"])
        XCTAssertNil(without["cwd_explicit"], "no folder, no flag: the profile's own folder is the right default")

        await client.disconnect()
    }

    /// An older backend does not declare `cwd_explicit` and answers 4000 before any
    /// handler runs (`tui_gateway/rpc_dispatch.py:27-31`), so nothing was created and the same create
    /// goes once more without the flag; that backend lets the request's `cwd` win on its own
    /// (`session_workdir.py:23-35` on an older backend).
    func testCreateRetriesOnceWithoutTheFlagWhenTheBackendRejectsIt() async throws {
        let (client, socket) = try await ScriptedGateway.connected(replies: [
            "session.create": [
                ScriptedGateway.rpcError(code: 4000, message: Self.undeclared("cwd_explicit")),
                try Fixtures.result("response-session-create"),
            ]
        ])

        let created = try await SessionAPI(client: client).create(
            cwd: "/Users/you/projects/alpha", profile: "writer"
        )

        let sends = await socket.sentCount("session.create")
        XCTAssertEqual(sends, 2, "exactly one retry")
        let sentRetry = await socket.sentParams("session.create")
        let retry = try XCTUnwrap(sentRetry)
        XCTAssertNil(retry["cwd_explicit"])
        XCTAssertEqual(retry["cwd"]?.coercedString, "/Users/you/projects/alpha", "the folder itself still rides")
        XCTAssertEqual(retry["profile"]?.coercedString, "writer")
        XCTAssertEqual(created.sessionID, "a1b2c3d4")

        await client.disconnect()
    }

    /// Only the flag this client added may be dropped; a 4000 naming any other key is the caller's
    /// error and is neither retried nor masked.
    func testCreateDoesNotRetryARejectionOfAnyOtherKey() async throws {
        let (client, socket) = try await ScriptedGateway.connected(replies: [
            "session.create": [
                ScriptedGateway.rpcError(code: 4000, message: Self.undeclared("reasoning_effort")),
                try Fixtures.result("response-session-create"),
            ]
        ])

        do {
            _ = try await SessionAPI(client: client).create(
                cwd: "/Users/you/projects/alpha", profile: "writer", reasoningEffort: "high"
            )
            XCTFail("a rejection of another key must reach the caller")
        } catch HermesError.rpc(let code, let message, _) {
            XCTAssertEqual(code, 4000)
            XCTAssertTrue(message.contains("reasoning_effort"))
        }
        let sends = await socket.sentCount("session.create")
        XCTAssertEqual(sends, 1)

        await client.disconnect()
    }
}
