import XCTest

@testable import HermesServeKit

/// The Bots roster's read surface. Two of these tests defend an invariant
/// rather than a shape: the tri-state `preferred_session` (absent is not null)
/// and `isCanonicalBotChat` (the title moves off the root at the first
/// compression). Collapsing either one re-derives a pin that is already fine,
/// and a re-derivation is how a second forever-chat gets minted.
final class ProfilesAPITests: XCTestCase {

    // MARK: - profiles.list decode

    func testListDecodesTheRosterAndTheCapabilityFlag() throws {
        let listed = ProfilesListResult(json: try Fixtures.result("response-profiles-list"))

        XCTAssertTrue(listed.botModeProtocol)
        XCTAssertEqual(listed.profiles.map(\.name), ["default", "work", "research"])
        XCTAssertEqual(listed.profiles.map(\.id), ["default", "work", "research"])

        let first = listed.profiles[0]
        XCTAssertTrue(first.isDefault)
        XCTAssertEqual(first.model, "hermes-4-405b")
        XCTAssertEqual(first.provider, "nous")
        XCTAssertEqual(first.skillCount, 12)
        XCTAssertTrue(first.hasAvatar)
        XCTAssertEqual(first.path, "/Users/you/.hermes")

        // `last_session` sends neither resolved_id nor root_title, so both must
        // fall back rather than blank the row.
        let last = try XCTUnwrap(first.lastSession)
        XCTAssertEqual(last.id, "20260821_090000_visible")
        XCTAssertEqual(last.resolvedID, last.id, "no resolved_id key ⇒ the row is its own tip")
        XCTAssertTrue(last.rootTitle.isEmpty)
        XCTAssertEqual(last.messageCount, 18)

        let worker = try XCTUnwrap(first.workerSession)
        XCTAssertEqual(worker.source, "kanban")
        XCTAssertEqual(worker.lastActive, 1755767100.0, accuracy: 0.001)

        // A profile with no configured model sends null, which must stay nil —
        // an empty string would read as "the model is called nothing".
        let work = listed.profiles[1]
        XCTAssertNil(work.model)
        XCTAssertNil(work.provider)
        XCTAssertEqual(work.displayName, "Work")
        XCTAssertNil(work.lastSession)
        XCTAssertNil(work.workerSession)
    }

    /// The whole reason `PreferredSession` is an enum. One fixture, three rows,
    /// three different answers — and `.absent` must never compare equal to
    /// `.gone`, because only `.gone` licenses re-deriving the pin.
    func testPreferredSessionKeepsAbsentAndNullApart() throws {
        let listed = ProfilesListResult(json: try Fixtures.result("response-profiles-list"))

        guard case .present(let pinned) = listed.profiles[0].preferredSession else {
            return XCTFail("`default` supplied a pin that resolved; expected .present")
        }
        XCTAssertEqual(pinned.id, "20260820_101010_abc123", "the pin comes back verbatim")
        XCTAssertEqual(pinned.resolvedID, "20260822_143000_tip999", "resolved_id is the live tip")
        XCTAssertNotEqual(pinned.id, pinned.resolvedID)
        XCTAssertEqual(pinned.messageCount, 214)
        XCTAssertEqual(pinned.preview, "Sure — I pulled the numbers you asked for.")

        XCTAssertEqual(listed.profiles[1].preferredSession, .gone, "an explicit null is an answer")
        XCTAssertEqual(listed.profiles[2].preferredSession, .absent, "no key is not an answer")
        XCTAssertNotEqual(listed.profiles[1].preferredSession, listed.profiles[2].preferredSession)

        XCTAssertTrue(listed.profiles[1].preferredSession.isResolvedMissing)
        XCTAssertFalse(listed.profiles[2].preferredSession.isResolvedMissing)
        XCTAssertNil(listed.profiles[1].preferredSession.summary)
        XCTAssertEqual(listed.profiles[0].preferredSession.summary?.id, "20260820_101010_abc123")
    }

    func testBotChatPinHintIsReadWhenPresentAndNilOtherwise() throws {
        let listed = ProfilesListResult(json: try Fixtures.result("response-profiles-list"))

        XCTAssertEqual(listed.profiles[0].botChatPinHint, "20260820_101010_abc123")
        XCTAssertNil(listed.profiles[1].botChatPinHint, "no ui_meta key at all")
        XCTAssertNil(listed.profiles[2].botChatPinHint)
        XCTAssertTrue(listed.profiles[1].uiMeta.isNull)

        // Present-but-empty is the same as absent: an empty pin resolves to
        // nothing and must not be tried.
        let blank = HermesProfile(json: .object([
            "name": .string("blank"),
            "ui_meta": .object(["hermes-bots": .object(["chat": .string("")])]),
        ]))
        XCTAssertNil(blank.botChatPinHint)

        // A namespace with no `chat` key is the ordinary Bot Mode shape before
        // the first chat exists.
        let unpinned = HermesProfile(json: .object([
            "name": .string("unpinned"),
            "ui_meta": .object(["hermes-bots": .object(["title": .string("Ops")])]),
        ]))
        XCTAssertNil(unpinned.botChatPinHint)
    }

    /// Desktop's `isCanonicalBotChatHistory`. The middle case is the one that
    /// matters: after a compression the root's title is NULL and only the tip
    /// still reads "Bot Chat", so a root-title-only test would stop recognising
    /// the bot's own conversation.
    func testIsCanonicalBotChatAcceptsRootTitleOrTipTitleAloneAndNothingElse() {
        let beforeCompression = ProfileSessionSummary(
            id: "root", resolvedID: "root", rootTitle: "Bot Chat", title: "Bot Chat"
        )
        XCTAssertTrue(beforeCompression.isCanonicalBotChat)

        let afterCompression = ProfileSessionSummary(
            id: "root", resolvedID: "tip", rootTitle: "", title: "Bot Chat"
        )
        XCTAssertTrue(afterCompression.isCanonicalBotChat)

        let ordinary = ProfileSessionSummary(
            id: "row", resolvedID: "row", rootTitle: "", title: "Fix the roster poll"
        )
        XCTAssertFalse(ordinary.isCanonicalBotChat)

        // A row whose root is some other conversation is NOT the canonical
        // chat even if its tip happens to be titled "Bot Chat".
        let misleading = ProfileSessionSummary(
            id: "row", resolvedID: "tip", rootTitle: "Fix the roster poll", title: "Bot Chat"
        )
        XCTAssertFalse(misleading.isCanonicalBotChat)

        let untitled = ProfileSessionSummary(id: "row", resolvedID: "row")
        XCTAssertFalse(untitled.isCanonicalBotChat)
    }

    // MARK: - profiles.list request

    func testListSendsIncludeSessionsAndOnlyANonEmptyPinMap() async throws {
        let (client, socket) = try await ScriptedGateway.connected(replies: [
            "profiles.list": [
                try Fixtures.result("response-profiles-list"),
                try Fixtures.result("response-profiles-list"),
            ]
        ])
        let profiles = ProfilesAPI(client: client)

        _ = try await profiles.list()
        let sentBare = await socket.sentParams("profiles.list")
        let bare = try XCTUnwrap(sentBare)
        XCTAssertEqual(bare["include_sessions"]?.coercedBool, true)
        XCTAssertNil(
            bare["preferred_session_ids"],
            "an empty pin map costs a per-profile database open and buys nothing"
        )

        _ = try await profiles.list(preferredSessionIDs: [
            "default": "20260820_101010_abc123",
            "work": "20260821_120000_work22",
        ])
        let sentPinned = await socket.sentParams("profiles.list")
        let pinned = try XCTUnwrap(sentPinned)
        XCTAssertEqual(
            pinned["preferred_session_ids"],
            .object([
                "default": .string("20260820_101010_abc123"),
                "work": .string("20260821_120000_work22"),
            ]),
            "the pin map is an object keyed by profile name; anything else is discarded"
        )

        await client.disconnect()
    }

    // MARK: - profiles.get_asset

    func testGetAssetDecodesTheDataURLIntoBytes() async throws {
        let (client, socket) = try await ScriptedGateway.connected(replies: [
            "profiles.get_asset": [try Fixtures.result("response-profiles-get-asset")]
        ])
        let asset = try await ProfilesAPI(client: client).getAsset(profile: "default")

        let unwrapped = try XCTUnwrap(asset)
        XCTAssertEqual(unwrapped.mime, "image/png")
        XCTAssertEqual(unwrapped.data.count, 70, "the fixture's payload is a real 1x1 PNG")
        XCTAssertEqual(Array(unwrapped.data.prefix(4)), [0x89, 0x50, 0x4E, 0x47], "PNG magic")

        let sentParams = await socket.sentParams("profiles.get_asset")

        let params = try XCTUnwrap(sentParams)
        XCTAssertEqual(params["name"]?.coercedString, "default")
        XCTAssertEqual(params["asset"]?.coercedString, "avatar")

        await client.disconnect()
    }

    /// `{found: false}` is a success, not an error — that is what makes the
    /// roster's per-row probe cheap, and it must not throw.
    func testGetAssetReturnsNilWhenTheAssetIsMissing() async throws {
        let (client, _) = try await ScriptedGateway.connected(replies: [
            "profiles.get_asset": [try Fixtures.result("response-profiles-get-asset", frame: 1)]
        ])
        let asset = try await ProfilesAPI(client: client).getAsset(profile: "work")
        XCTAssertNil(asset)
        await client.disconnect()
    }

    /// A payload that does not decode is an absent avatar, not a crash and not
    /// an empty image handed to the image decoder.
    func testGetAssetReturnsNilOnAMalformedPayload() async throws {
        let malformed: [JSONValue] = [
            .object([
                "found": .bool(true),
                "mime": .string("image/png"),
                "data": .string("data:image/png;base64,%%%not-a-png%%%"),
            ]),
            .object([
                "found": .bool(true),
                "mime": .string("image/png"),
                "data": .string("iVBORw0KGgo="),
            ]),
            .object(["found": .bool(true), "mime": .string("image/png")]),
        ]
        let (client, _) = try await ScriptedGateway.connected(
            replies: ["profiles.get_asset": malformed]
        )
        let profiles = ProfilesAPI(client: client)

        for label in ["undecodable base64", "no data: prefix", "no data key"] {
            let asset = try await profiles.getAsset(profile: "default")
            XCTAssertNil(asset, "\(label) must read as no asset")
        }
        await client.disconnect()
    }

    func testDataURLSplitRejectsEverythingButBase64DataURLs() {
        XCTAssertNil(ProfilesAPI.decodeDataURL(""))
        XCTAssertNil(ProfilesAPI.decodeDataURL("https://example.test/avatar.png"))
        XCTAssertNil(ProfilesAPI.decodeDataURL("data:image/png,notbase64"))
        XCTAssertNil(ProfilesAPI.decodeDataURL("data:image/png;base64,"))

        let decoded = ProfilesAPI.decodeDataURL("data:image/webp;base64,aGVsbG8=")
        XCTAssertEqual(decoded?.mime, "image/webp")
        XCTAssertEqual(decoded.map { String(decoding: $0.data, as: UTF8.self) }, "hello")
    }

    // MARK: - canonical_session (BUG-113)

    /// Since a backend catch-up the gateway resolves the forever-chat by
    /// title itself and answers on `canonical_session`; `preferred_session` is
    /// gone from the response entirely. Reading only the old key made every row
    /// `.absent`, which blanks the roster's preview, recency and working dot.
    func testCanonicalSessionIsReadWhenTheBackendSendsIt() {
        let row = JSONValue.object([
            "canonical_session": .object([
                "id": .string("20260820_101010_root"),
                "resolved_id": .string("20260826_120000_tip"),
                "root_title": .string("Bot Chat"),
                "title": .string("Bot Chat"),
                "preview": .string("Picked up where we left off."),
                "started_at": .number(1755000000),
                "last_active": .number(1756200000),
                "message_count": .number(214),
            ])
        ])

        guard case .present(let summary) = PreferredSession(row: row) else {
            return XCTFail("a non-null canonical_session must resolve to .present")
        }
        // Same eight-field shape as the old key, so the summary decodes whole:
        // the durable registry row stays `id` and the live tip is `resolved_id`.
        XCTAssertEqual(summary.id, "20260820_101010_root")
        XCTAssertEqual(summary.resolvedID, "20260826_120000_tip")
        XCTAssertNotEqual(summary.id, summary.resolvedID)
        XCTAssertEqual(summary.messageCount, 214)
        XCTAssertEqual(summary.preview, "Picked up where we left off.")
    }

    /// The new key is written on every row when `include_sessions` is on, so a
    /// null is the server saying it looked by title and found nothing — an
    /// answer, exactly like the old null. Absent stays reserved for a gateway
    /// that cannot answer at all.
    func testCanonicalSessionKeepsNullAndAbsentApart() {
        let nulled = JSONValue.object(["canonical_session": .null])
        XCTAssertEqual(PreferredSession(row: nulled), .gone)
        XCTAssertTrue(PreferredSession(row: nulled).isResolvedMissing)

        let neither = JSONValue.object(["name": .string("work")])
        XCTAssertEqual(PreferredSession(row: neither), .absent)
        XCTAssertFalse(PreferredSession(row: neither).isResolvedMissing)
        XCTAssertNotEqual(PreferredSession(row: nulled), PreferredSession(row: neither))
    }

    /// An older gateway still answers on `preferred_session` and never sends the
    /// new key, so the fallback has to stay live. This is the regression guard
    /// on backward compatibility, not a shape test.
    func testPreferredSessionStillReadWhenCanonicalIsAbsent() {
        let legacy = JSONValue.object([
            "preferred_session": .object([
                "id": .string("20260820_101010_abc123"),
                "resolved_id": .string("20260822_143000_tip999"),
                "title": .string("Bot Chat"),
                "preview": .string("legacy pin echo"),
                "last_active": .number(1755767100),
                "message_count": .number(12),
            ])
        ])
        XCTAssertEqual(PreferredSession(row: legacy).summary?.id, "20260820_101010_abc123")
        XCTAssertEqual(PreferredSession(row: legacy).summary?.resolvedID, "20260822_143000_tip999")

        XCTAssertEqual(PreferredSession(row: .object(["preferred_session": .null])), .gone)
    }

    /// If some intermediate build ever sends both, the server's own title lookup
    /// outranks an echo of a pointer we supplied.
    func testCanonicalSessionOutranksThePinEchoWhenBothArePresent() {
        let both = JSONValue.object([
            "canonical_session": .object(["id": .string("resolved-by-title")]),
            "preferred_session": .object(["id": .string("echoed-pin")]),
        ])
        XCTAssertEqual(PreferredSession(row: both).summary?.id, "resolved-by-title")
    }
}
