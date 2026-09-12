import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// Wire payloads for the pin rung. Free-standing rather than statics on the test class, for the reason `BotChatResolverTests` gives: `ScriptedBackend.stub` takes a `@Sendable` closure that runs off the main actor, and a helper on a `@MainActor` class cannot be called from inside one.
private enum PinWire {
    /// The title of an ordinary, non-hidden conversation — the kind of session a stale pin can point at, which is the whole of BUG-053.
    static let unrelatedTitle = "Configure Hermes agent bug workflow"

    /// A `session.resume` answer whose `info.title` is whatever the backend would report for the id that was asked for.
    static func resume(_ call: ScriptedBackend.Call, titles: [String: String]) -> JSONValue {
        .object([
            "session_id": .string("rt-\(call.sessionID)"),
            "session_key": .string(call.sessionID),
            "resumed": .string(call.sessionID),
            "messages": .array([]),
            "info": ScriptedBackend.info(title: titles[call.sessionID] ?? ""),
            "running": .bool(false),
            "status": .string("idle"),
        ])
    }

    static func titleRow(id: String) -> JSONValue {
        .object(["sessions": .array([
            .object([
                "id": .string(id),
                "resolved_id": .string(id),
                "title": .string("Bot Chat"),
                "message_count": .number(2),
                "started_at": .number(1_700_000_000),
                "source": .string("desktop"),
            ]),
        ])])
    }

    static let noTitleMatch: JSONValue = .object(["sessions": .array([])])

    /// One `profiles.list` row carrying Desktop's `ui_meta['hermes-bots'].chat` pin.
    static func profileRow(name: String, hint: String) -> JSONValue {
        .object([
            "name": .string(name),
            "path": .string("/home/\(name)"),
            "is_default": .bool(true),
            "description": .string(""),
            "display_name": .string("Hermes"),
            "skill_count": .number(0),
            "has_avatar": .bool(false),
            "ui_meta": .object(["hermes-bots": .object(["chat": .string(hint)])]),
        ])
    }
}

/// BUG-053(a) — the pin rung adopted a session that is not a Bot Chat.
///
/// A bot opened an ordinary long-running conversation instead of its own thread. The binding came from `ui_meta['hermes-bots'].chat`, a pin Desktop wrote, which `ProfilesAPI` documents as a hint and never authority — "nothing in the backend reads or writes it, this client never writes it, and it is stale the moment Desktop moves". The resolver's pin rung resumed that id and, worse, wrote it into the phone's own durable pin store, so the mis-binding outlived the hint that caused it. The rung immediately below it carries a title check and a comment saying in terms that adopting an unrelated session "would bind this bot's thread to an unrelated session"; the pin rung had no such check.
///
/// The rule these tests hold the resolver to has two halves, and they pull in opposite directions on purpose:
///
/// 1. **A title the backend affirmatively reports, that is not the Bot Chat's, refutes the pin.** The pin is dropped, nothing is adopted, and the ladder falls through to the title rungs and — only after two affirmative absences — the mint.
/// 2. **Silence refutes nothing.** A resume that reports no title at all (an older gateway, or the reduced info shape a lazy session answers with) is still adopted. A check that treated "did not say" as "not a Bot Chat" would re-derive a perfectly good pin on every open, and on a backend whose title rungs also came up empty it would mint a second forever-chat — the exact fork the whole ladder exists to prevent.
@MainActor
final class BotChatPinVerificationTests: XCTestCase {

    private func hermes() -> BotThreadRef {
        BotThreadRef(profile: "default", displayName: "Hermes")
    }

    // MARK: 1 — the durable local pin self-heals

    /// A device that already carries the bad pin, written by the very rung under test: a fix that only vets the server hint would leave it bound to the wrong conversation forever. A pin that resolves to a session the backend names as something other than a Bot Chat is retired and re-derived.
    func testALocalPinThatResolvesToAnUnrelatedSessionIsRetiredAndRederived() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        harness.app.bots.store.setPin("regular-69", backend: harness.profileID, profile: "default")

        await harness.backend.stub("session.resume") { call in
            PinWire.resume(call, titles: [
                "regular-69": PinWire.unrelatedTitle,
                "botchat-1": "Bot Chat",
            ])
        }
        await harness.backend.stub("session.list") { _ in PinWire.titleRow(id: "botchat-1") }

        let chat = harness.app.chat(for: .bot(hermes()))
        await chat.open()

        let resumed = await harness.backend.calls(to: "session.resume").map(\.sessionID)
        XCTAssertEqual(
            resumed,
            ["regular-69", "botchat-1"],
            "the pin resolved to \"\(PinWire.unrelatedTitle)\" — a regular conversation, not this bot's forever-chat — and the resolver opened it anyway instead of falling through to the title lookup"
        )
        XCTAssertEqual(
            chat.storedSessionID,
            "botchat-1",
            "the thread bound the wrong session: tapping the bot opens somebody else's conversation, and the next message the user sends goes into it"
        )
        XCTAssertEqual(
            harness.app.bots.store.pin(backend: harness.profileID, profile: "default"),
            "botchat-1",
            "a pin that has been proven wrong must not survive the open that disproved it, or every future open repeats the mis-binding"
        )
        let creates = await harness.backend.callCount("session.create")
        XCTAssertEqual(creates, 0, "the bot's real Bot Chat was there to be found; nothing may be minted over it")

        await harness.tearDown()
    }

    // MARK: 2 — the server hint is never promoted unverified

    /// Desktop's `ui_meta` pin, exactly as a profile carries it. The hint may be adopted; it may not be *believed*. An unverified hint that is written into the durable pin store turns one stale value on the server into a permanent mis-binding on the phone.
    func testAServerPinHintThatNamesAnUnrelatedSessionIsNeverAdoptedOrPinned() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()

        await harness.backend.stub("profiles.list") { _ in
            .object([
                "profiles": .array([PinWire.profileRow(name: "default", hint: "regular-69")]),
                "bot_mode_protocol": .bool(true),
            ])
        }
        // The roster's own first-load pin seeding runs a title lookup for every unpinned profile; answer it with nothing so this phone genuinely starts with no local pin.
        await harness.backend.stub("session.list") { _ in PinWire.noTitleMatch }
        // Twice, deliberately: opening the socket already started a roster load, `refresh()` is single-flighted, and joining that earlier load would return before this test's stubs were ever asked for. The second call is the one that reads them.
        await harness.app.bots.refresh()
        await harness.app.bots.refresh()

        XCTAssertEqual(
            harness.app.bots.serverPinHint("default"),
            "regular-69",
            "precondition: the roster must have carried Desktop's ui_meta pin back"
        )
        XCTAssertNil(
            harness.app.bots.store.pin(backend: harness.profileID, profile: "default"),
            "precondition: this phone has no pin of its own, which is what makes the hint the only candidate"
        )

        await harness.backend.stub("session.resume") { call in
            PinWire.resume(call, titles: [
                "regular-69": PinWire.unrelatedTitle,
                "botchat-1": "Bot Chat",
            ])
        }
        await harness.backend.stub("session.list") { _ in PinWire.titleRow(id: "botchat-1") }

        let chat = harness.app.chat(for: .bot(hermes()))
        await chat.open()

        XCTAssertEqual(
            chat.storedSessionID,
            "botchat-1",
            "the bot opened the session Desktop's stale hint named — \"\(PinWire.unrelatedTitle)\" — instead of its own Bot Chat"
        )
        XCTAssertEqual(
            harness.app.bots.store.pin(backend: harness.profileID, profile: "default"),
            "botchat-1",
            "the hint was promoted into this phone's durable pin without ever being checked; ProfilesAPI documents that value as a hint and never authority"
        )

        await harness.tearDown()
    }

    // MARK: 3 — silence refutes nothing

    /// The guard against over-correcting. A backend that answers a resume without a title has said nothing about what the session is, and a pin must not be thrown away on nothing.
    func testAResumeThatReportsNoTitleIsStillAdopted() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        harness.app.bots.store.setPin("pin-quiet", backend: harness.profileID, profile: "default")

        await harness.backend.stub("session.resume") { call in
            PinWire.resume(call, titles: [:])
        }
        await harness.backend.stub("session.list") { _ in PinWire.titleRow(id: "botchat-1") }

        let chat = harness.app.chat(for: .bot(hermes()))
        await chat.open()

        let resumed = await harness.backend.calls(to: "session.resume").map(\.sessionID)
        XCTAssertEqual(
            resumed,
            ["pin-quiet"],
            "the backend reported no title, which is not a claim that the session is the wrong one — re-deriving the pin here costs a lookup on every open and, on a backend whose title rungs also come up empty, mints a second forever-chat"
        )
        XCTAssertEqual(
            harness.app.bots.store.pin(backend: harness.profileID, profile: "default"),
            "pin-quiet",
            "a silent backend must not cost the user their pin"
        )
        let lookups = await harness.backend.callCount("session.list")
        XCTAssertEqual(lookups, 0, "a resolving pin needs no re-derivation")

        await harness.tearDown()
    }

    /// And the ordinary case, stated so a regression in the check itself is visible: a pin whose session the backend names "Bot Chat" is adopted on the spot.
    func testAPinThatResolvesToTheBotChatIsAdoptedWithoutALookup() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        harness.app.bots.store.setPin("botchat-1", backend: harness.profileID, profile: "default")

        await harness.backend.stub("session.resume") { call in
            PinWire.resume(call, titles: ["botchat-1": "Bot Chat"])
        }

        let chat = harness.app.chat(for: .bot(hermes()))
        await chat.open()

        XCTAssertEqual(chat.storedSessionID, "botchat-1")
        XCTAssertEqual(
            harness.app.bots.store.pin(backend: harness.profileID, profile: "default"),
            "botchat-1"
        )
        let lookups = await harness.backend.callCount("session.list")
        XCTAssertEqual(lookups, 0)
        let creates = await harness.backend.callCount("session.create")
        XCTAssertEqual(creates, 0)

        await harness.tearDown()
    }
}
