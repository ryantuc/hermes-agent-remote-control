import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// Wire payloads for the resolver's rungs.
///
/// Free-standing rather than statics on the test class: `ScriptedBackend.stub`
/// takes a `@Sendable` closure that runs off the main actor, and a helper on a
/// `@MainActor` test class cannot be called from inside one.
private enum Wire {
    /// A `session.resume` answer with a caller-chosen key, so a test can prove
    /// *which* id the resolver opened.
    static func resumeResult(runtime: String, key: String, title: String = "") -> JSONValue {
        .object([
            "session_id": .string(runtime),
            "session_key": .string(key),
            "resumed": .string(key),
            "messages": .array([]),
            "info": ScriptedBackend.info(title: title),
            "running": .bool(false),
            "status": .string("idle"),
        ])
    }

    static func titleRow(id: String, resolvedID: String) -> JSONValue {
        .object(["sessions": .array([
            .object([
                "id": .string(id),
                "resolved_id": .string(resolvedID),
                "title": .string("Bot Chat"),
                "message_count": .number(12),
                "started_at": .number(1_700_000_000),
                "source": .string("desktop"),
            ]),
        ])])
    }

    static let noTitleMatch: JSONValue = .object(["sessions": .array([])])
}

/// The Bot Chat resolver.
///
/// Every test here is about the same defect: minting a second session titled
/// `Bot Chat` for a bot that already has one. That is not a cosmetic duplicate.
/// The chat is the bot's entire memory of the user, the title is protected by a
/// partial UNIQUE index so the second one cannot even be created under the same
/// name, and the user's history simply stops being where they left it. So the
/// assertions are deliberately blunt: **how many `session.create` calls did the
/// backend see.**
@MainActor
final class BotChatResolverTests: XCTestCase {

    private func ref(_ profile: String = "scout", _ name: String = "Scout") -> BotThreadRef {
        BotThreadRef(profile: profile, displayName: name)
    }

    // MARK: Single flight

    /// Two `open()` calls in flight at once. The second must join the first,
    /// not race it.
    ///
    /// Staged with the mint itself parked, which is what makes this
    /// non-vacuous: while the create is unanswered nothing has been stored, so
    /// a second pass down the ladder has no shortcut to take and would dial its
    /// own `session.create`. The second call then gets a full second of real
    /// time to do exactly that before anything is asserted.
    func testTwoConcurrentOpensIssueOneSessionCreate() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()

        await harness.backend.stub("session.list") { _ in Wire.noTitleMatch }
        await harness.backend.failRPC("session.resume", code: 4007, message: "no such session")
        await harness.backend.gate("session.create")

        let chat = harness.app.chat(for: .bot(ref()))
        let first = Task { @MainActor in await chat.open() }
        let reached = await waitUntil { await harness.backend.callCount("session.create") == 1 }
        XCTAssertTrue(reached, "precondition: the first open never reached the mint")

        let second = Task { @MainActor in await chat.open() }
        let forked = await waitUntil(timeout: 1) {
            await harness.backend.callCount("session.create") > 1
        }
        XCTAssertFalse(
            forked,
            "ChatModel.resolveBotChat is not single-flighting: a second open() dialed its own "
                + "session.create while the first was still in flight. Two forever-chats for one "
                + "bot, and the user's history is in whichever one loses."
        )

        await harness.backend.ungate("session.create")
        await harness.backend.releaseParked()
        await first.value
        await second.value

        let creates = await harness.backend.callCount("session.create")
        XCTAssertEqual(creates, 1, "exactly one Bot Chat may be minted per bot")

        await harness.tearDown()
    }

    // MARK: Adopt before mint

    /// A chat Desktop already minted. This phone has no pin, finds the row by
    /// title, and opens the compression **tip** while pinning the row that
    /// carries the title.
    func testTitleLookupAdoptsAnExistingChatAndNeverMints() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()

        await harness.backend.stub("session.list") { _ in
            Wire.titleRow(id: "root-1", resolvedID: "tip-9")
        }
        await harness.backend.stub("session.resume") { call in
            Wire.resumeResult(runtime: "rt-adopted", key: call.sessionID)
        }

        let chat = harness.app.chat(for: .bot(ref()))
        await chat.open()

        let creates = await harness.backend.callCount("session.create")
        XCTAssertEqual(
            creates,
            0,
            "the bot already had a Bot Chat and the resolver minted another one anyway — "
                + "everything the user said to this bot is now in a session the app will not open"
        )
        let resumed = await harness.backend.calls(to: "session.resume").map(\.sessionID)
        XCTAssertEqual(
            resumed,
            ["tip-9"],
            "session.list's `resolved_id` is the live compression tip; resuming the root id "
                + "would open the archived head of the lineage"
        )
        XCTAssertEqual(
            harness.app.bots.store.pin(backend: harness.profileID, profile: "scout"),
            "root-1",
            "the pin is the row that CARRIES the title, not the tip — the tip moves on every "
                + "compression and a pin that chases it is re-derived forever"
        )
        XCTAssertEqual(chat.storedSessionID, "tip-9")

        await harness.tearDown()
    }

    /// The title branch is scoped by which database the gateway opens, so the
    /// bot's profile has to ride every call. Sending nothing would silently
    /// operate on the gateway's own launch profile.
    func testEveryResolverCallCarriesTheBotsProfile() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()

        await harness.backend.stub("session.list") { _ in
            Wire.titleRow(id: "root-1", resolvedID: "root-1")
        }

        let chat = harness.app.chat(for: .bot(ref("code-review", "Code Review")))
        await chat.open()

        let list = await harness.backend.calls(to: "session.list").first
        XCTAssertEqual(list?.params["profile"]?.coercedString, "code-review")
        XCTAssertEqual(list?.params["title"]?.coercedString, "Bot Chat")
        XCTAssertEqual(list?.params["include_hidden"]?.coercedBool, true)
        let resume = await harness.backend.calls(to: "session.resume").first
        XCTAssertEqual(
            resume?.params["profile"]?.coercedString,
            "code-review",
            "an unscoped resume binds a session out of the WRONG profile's state.db"
        )

        await harness.tearDown()
    }

    // MARK: The pin

    /// A pin that still resolves is the fast path: one resume, no lookup.
    func testALivePinResumesWithoutATitleLookup() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        harness.app.bots.store.setPin("pin-1", backend: harness.profileID, profile: "scout")

        await harness.backend.stub("session.resume") { call in
            Wire.resumeResult(runtime: "rt-pinned", key: call.sessionID)
        }

        let chat = harness.app.chat(for: .bot(ref()))
        await chat.open()

        let resumed = await harness.backend.calls(to: "session.resume").map(\.sessionID)
        XCTAssertEqual(resumed, ["pin-1"])
        let lookups = await harness.backend.callCount("session.list")
        XCTAssertEqual(lookups, 0, "a resolving pin needs no re-derivation")
        let creates = await harness.backend.callCount("session.create")
        XCTAssertEqual(creates, 0)

        await harness.tearDown()
    }

    /// A stale pin: 4007 retires it, the title lookup finds the real chat, and
    /// nothing is minted.
    func testStalePinIsRetiredAndTheTitleLookupTakesOver() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        harness.app.bots.store.setPin("stale-1", backend: harness.profileID, profile: "scout")

        await harness.backend.failNextRPC("session.resume", code: 4007, message: "session not found")
        await harness.backend.stub("session.list") { _ in
            Wire.titleRow(id: "found-1", resolvedID: "found-1")
        }
        await harness.backend.stub("session.resume") { call in
            Wire.resumeResult(runtime: "rt-found", key: call.sessionID)
        }

        let chat = harness.app.chat(for: .bot(ref()))
        await chat.open()

        let resumed = await harness.backend.calls(to: "session.resume").map(\.sessionID)
        XCTAssertEqual(resumed, ["stale-1", "found-1"], "the pin is tried first, then the found row")
        let creates = await harness.backend.callCount("session.create")
        XCTAssertEqual(
            creates,
            0,
            "a stale pin is a pin that needs re-deriving, not a bot that needs a new chat"
        )
        XCTAssertEqual(
            harness.app.bots.store.pin(backend: harness.profileID, profile: "scout"),
            "found-1",
            "the stale pin must be replaced, or every open pays for the same dead resume"
        )

        await harness.tearDown()
    }

    /// **The one that protects the data.** A resume that fails for any reason
    /// other than 4007 is a backend that did not answer, not a chat that is
    /// gone. Minting here forks the bot's history on a bad network.
    func testATransientResumeFailureNeverMintsAndKeepsThePin() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        harness.app.bots.store.setPin("pin-1", backend: harness.profileID, profile: "scout")

        await harness.backend.failRPC("session.resume", code: 5031, message: "gateway is restarting")

        let chat = harness.app.chat(for: .bot(ref()))
        await chat.open()

        let creates = await harness.backend.callCount("session.create")
        XCTAssertEqual(
            creates,
            0,
            "a transient resume failure minted a replacement Bot Chat — one bad reconnect and "
                + "the bot's whole history is orphaned behind a session the app no longer opens"
        )
        let lookups = await harness.backend.callCount("session.list")
        XCTAssertEqual(lookups, 0, "the ladder must stop, not fall through, on a failure")
        XCTAssertEqual(
            harness.app.bots.store.pin(backend: harness.profileID, profile: "scout"),
            "pin-1",
            "the pin still names a real session; discarding it on a transient error throws it away"
        )
        XCTAssertEqual(
            chat.errorMessage,
            "gateway is restarting",
            "the user gets the backend's own words and a thread they can retry"
        )

        await harness.tearDown()
    }

    /// 4001 is the *live* session id miss, not the durable one. Treating it as
    /// "gone" would retire a pin on the strength of the wrong error, so it is
    /// deliberately transient here.
    func testOnly4007RetiresAPin() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        harness.app.bots.store.setPin("pin-1", backend: harness.profileID, profile: "scout")

        await harness.backend.failRPC("session.resume", code: 4001, message: "session not found")

        let chat = harness.app.chat(for: .bot(ref()))
        await chat.open()

        XCTAssertEqual(
            harness.app.bots.store.pin(backend: harness.profileID, profile: "scout"),
            "pin-1",
            "HermesError.isSessionNotFound also matches the words \"session not found\" in any "
                + "message; a predicate that decides whether to DELETE the user's pin cannot be "
                + "keyed on prose"
        )
        let creates = await harness.backend.callCount("session.create")
        XCTAssertEqual(creates, 0)

        await harness.tearDown()
    }

    // MARK: Resume-by-title

    /// The gateway resolves a title passed as an id. Kept beside the title
    /// lookup because each degrades silently on a gateway that lacks the other.
    func testResumeByTitleRungPinsTheReturnedSessionKey() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()

        await harness.backend.stub("session.list") { _ in Wire.noTitleMatch }
        await harness.backend.stub("session.resume") { call in
            Wire.resumeResult(runtime: "rt-by-title", key: "stored-by-title")
        }

        let chat = harness.app.chat(for: .bot(ref()))
        await chat.open()

        let resumed = await harness.backend.calls(to: "session.resume").map(\.sessionID)
        XCTAssertEqual(resumed, ["Bot Chat"], "the title itself is passed as the session id")
        XCTAssertEqual(
            harness.app.bots.store.pin(backend: harness.profileID, profile: "scout"),
            "stored-by-title",
            "the resume's own session_key is the durable id to pin"
        )
        let creates = await harness.backend.callCount("session.create")
        XCTAssertEqual(creates, 0)
        XCTAssertEqual(chat.runtimeSessionID, "rt-by-title")

        await harness.tearDown()
    }

    // MARK: The mint

    /// The last rung, reached only after two affirmative absences. The create
    /// is hidden and titled, and the kickoff goes out through the ordinary send
    /// pipeline once the runtime id is bound.
    func testMintCreatesHiddenTitledChatThenSendsTheKickoff() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()

        await harness.backend.stub("session.list") { _ in Wire.noTitleMatch }
        await harness.backend.failRPC("session.resume", code: 4007, message: "no such session")

        let chat = harness.app.chat(for: .bot(ref()))
        await chat.open()

        let creates = await harness.backend.calls(to: "session.create")
        XCTAssertEqual(creates.count, 1)
        XCTAssertEqual(creates.first?.params["title"]?.coercedString, "Bot Chat")
        XCTAssertEqual(
            creates.first?.params["hidden"]?.coercedBool,
            true,
            "a Bot Chat that is not born hidden shows up in Sessions mode's thread list"
        )
        XCTAssertEqual(creates.first?.params["profile"]?.coercedString, "scout")

        let submitted = await waitUntil { await harness.backend.callCount("prompt.submit") == 1 }
        XCTAssertTrue(
            submitted,
            "session.create alone persists no DB row (methods_session.py:114-119), so a mint "
                + "without a kickoff leaves nothing for the next open to find — and the next open "
                + "mints again"
        )
        let submit = await harness.backend.calls(to: "prompt.submit").first
        XCTAssertEqual(submit?.text, BotsModel.kickoffPrompt)
        XCTAssertEqual(
            submit?.sessionID,
            chat.runtimeSessionID,
            "the kickoff must ride the runtime id the create bound, not a stale one"
        )
        XCTAssertTrue(
            chat.entries.contains { $0.kind == .user && $0.text == BotsModel.kickoffPrompt },
            "the kickoff goes through the ordinary send pipeline, so it renders as the user's "
                + "own bubble — a silently injected prompt would read as the bot talking to itself"
        )
        XCTAssertEqual(
            harness.app.bots.store.pin(backend: harness.profileID, profile: "scout"),
            "stored-1",
            "the create's stored_session_id is the pin"
        )

        await harness.tearDown()
    }

    // MARK: Header title

    /// `applyResume` writes `info.title` over `title`, and `info.title` is
    /// "Bot Chat" for every bot on the backend.
    func testBotDisplayNameSurvivesApplyResume() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        harness.app.bots.store.setPin("pin-1", backend: harness.profileID, profile: "scout")

        await harness.backend.stub("session.resume") { call in
            Wire.resumeResult(runtime: "rt-1", key: call.sessionID, title: "Bot Chat")
        }

        let chat = harness.app.chat(for: .bot(ref()))
        XCTAssertEqual(chat.title, "Scout", "the header has a name before the resolver has run")
        await chat.open()

        XCTAssertEqual(
            chat.title,
            "Scout",
            "the resume renamed the thread to \"Bot Chat\" — which is what EVERY bot's session is "
                + "called, so the header stops naming the bot the user is talking to"
        )
        XCTAssertEqual(chat.botProfile, "scout")
        XCTAssertEqual(chat.botDisplayName, "Scout")

        await harness.tearDown()
    }

    // MARK: Route identity

    /// The deep link and the Live Activity both find a chat by runtime id and
    /// then need a route for it. A bot chat must route back to the bot.
    func testRouteForBotChatIsTheBotRoute() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        harness.app.bots.store.setPin("pin-1", backend: harness.profileID, profile: "scout")

        let chat = harness.app.chat(for: .bot(ref()))
        await chat.open()

        guard case .bot(let found)? = harness.app.route(for: chat) else {
            return XCTFail("a bot chat routed to something other than .bot — the Lock Screen card "
                + "would push a second navigation identity for the same conversation")
        }
        XCTAssertEqual(found.profile, "scout")
        XCTAssertEqual(found.displayName, "Scout")
        XCTAssertEqual(ThreadRoute.bot(found).key, "bot:scout")

        await harness.tearDown()
    }
}
