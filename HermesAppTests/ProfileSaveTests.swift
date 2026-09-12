import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// BUG-025 — saving any profile change tore the connection down and evicted
/// every open chat.
///
/// `update(_:)` compared nothing. It called `activate(connect: true)` for ANY
/// save, and `activate` opened with an unconditional `teardown()`, which
/// disconnects the socket, discards the session cookie a `.password` profile
/// depends on, blanks the Backend screen, and calls `chats.removeAll()` —
/// taking the running turn, the blocking prompt, the typed draft and the picked
/// photo with it.
///
/// That last part is a policy contradiction, not an oversight.
/// `ChatModel.isReleasable` states the rule emphatically ("when in doubt, keep
/// the chat") and `releaseChats(keeping:)` honours every clause of it.
/// `teardown()` honoured none. The app already knew the rule; one path did not
/// apply it.
@MainActor
final class ProfileSaveTests: XCTestCase {

    // MARK: RED-1 — the policy, as a table

    /// Pins the policy rather than its effect. Weak as a red on its own (it is
    /// red only because the symbol does not exist yet), which is why RED-2,
    /// RED-3 and RED-4 are the behavioural reds.
    func testWhatIsAndIsNotWorthAReconnect() {
        let base = BackendProfile(
            name: "workstation",
            baseURLString: "https://hermes.example.com",
            authMode: .sessionToken
        )
        func changed(_ mutate: (inout BackendProfile) -> Void) -> BackendProfile {
            var copy = base
            mutate(&copy)
            return copy
        }
        func requires(_ updated: BackendProfile, credentials: Bool = false) -> Bool {
            AppModel.requiresReconnect(from: base, to: updated, credentialsChanged: credentials)
        }

        // Cosmetic — must NOT reconnect.
        XCTAssertFalse(
            requires(changed { $0.name = "the mac mini" }),
            "a display-only rename cost the user their connection and every open chat"
        )
        XCTAssertFalse(
            requires(changed { $0.lastKnownVersion = "0.20.1" }),
            "the post-open ceremony writes this back on every open — if it were material, every connect would provoke the next"
        )
        XCTAssertFalse(
            requires(changed { $0.lastConnected = Date() }),
            "same: a connect side effect must never be a reason to reconnect"
        )
        XCTAssertFalse(requires(base), "an unedited save is not a change")
        XCTAssertFalse(
            requires(changed { $0.baseURLString = "https://hermes.example.com/" }),
            "a trailing slash normalizes to the same URL and is not an edit"
        )

        // Connection-relevant — must reconnect.
        XCTAssertTrue(
            requires(changed { $0.baseURLString = "http://100.64.0.10:9119" }),
            "the address changed and the client kept talking to the old one"
        )
        XCTAssertTrue(
            requires(changed { $0.authMode = .bearer }),
            "the auth mode changed and the client kept the old credential shape"
        )
        XCTAssertTrue(
            requires(changed { $0.hermesProfile = "work" }),
            "the Hermes profile scopes a different HERMES_HOME and state.db"
        )
        XCTAssertTrue(
            requires(changed { $0.username = "you" }),
            "the password-login identity changed"
        )
        XCTAssertTrue(
            requires(changed { $0.providerName = "basic" }),
            "the auth provider changed"
        )

        // The one edit no comparison of the rows can see.
        XCTAssertTrue(
            requires(base, credentials: true),
            "a new session token was written to the Keychain and both profile rows are byte-identical, so nothing in BackendProfile records it — without this the app keeps dialing with the credential the user just replaced"
        )
    }

    // MARK: RED-2 — a rename does not disturb the connection

    func testRenamingTheActiveBackendKeepsTheConnection() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let clientBefore = try XCTUnwrap(harness.app.client, "precondition: no client")

        var renamed = try XCTUnwrap(harness.app.activeProfile, "precondition: no active profile")
        renamed.name = "the mac mini"
        harness.app.update(renamed)

        // Give an unwanted teardown time to land.
        _ = await waitUntil(timeout: 2) { harness.app.client !== clientBefore }

        XCTAssertTrue(
            harness.app.client === clientBefore,
            "renaming the active backend tore the whole connection down and built a new one — the user changed a label"
        )
        XCTAssertTrue(harness.app.connectionState.isOpen, "the socket dropped for a rename")
        XCTAssertEqual(harness.app.activeProfile?.name, "the mac mini", "the rename must still be saved")

        await harness.tearDown()
    }

    // MARK: RED-3 — a rename does not evict the open chat or its draft

    func testRenamingTheActiveBackendKeepsOpenChatsAndTheirDrafts() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()

        let chat = harness.chat(storedID: "20260819_090000_draft01")
        await chat.open()
        let runtimeID = try XCTUnwrap(chat.runtimeSessionID, "precondition: the chat never bound")
        chat.draft = "ship the reconnect fix before the profile expires"

        var renamed = try XCTUnwrap(harness.app.activeProfile)
        renamed.name = "the mac mini"
        harness.app.update(renamed)

        // `chat(runtimeSessionID:)` is a non-mutating probe — do NOT re-ask
        // `harness.chat(storedID:)`, which would re-register a model and destroy
        // the observation.
        let evicted = await waitUntil(timeout: 2) {
            harness.app.chat(runtimeSessionID: runtimeID) == nil
        }
        XCTAssertFalse(
            evicted,
            "the rename evicted the open conversation — teardown() calls chats.removeAll(), which takes the running turn, the blocking prompt and the typed draft with it, every one of which ChatModel.isReleasable explicitly refuses to release"
        )
        XCTAssertEqual(
            chat.draft,
            "ship the reconnect fix before the profile expires",
            "the composer text the user had typed is gone"
        )
        XCTAssertTrue(
            harness.app.chat(runtimeSessionID: runtimeID) === chat,
            "the event pump can no longer reach the chat the user is looking at"
        )

        await harness.tearDown()
    }

    // MARK: RED-4 — a legitimate rebuild keeps them too (leg 2 on its own)

    /// Leg 1 cannot make this pass: the rebuild here is correct and does happen.
    func testARebuildForANewCredentialKeepsOpenChatsAndTheirDrafts() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()

        let chat = harness.chat(storedID: "20260819_091500_draft02")
        await chat.open()
        let runtimeID = try XCTUnwrap(chat.runtimeSessionID, "precondition: the chat never bound")
        chat.draft = "the token rotated, the draft did not"
        let clientBefore = try XCTUnwrap(harness.app.client)

        // Unchanged row, new secret in the Keychain: the one edit that MUST
        // rebuild.
        let profile = try XCTUnwrap(harness.app.activeProfile)
        harness.app.update(profile, credentialsChanged: true)

        let rebuilt = await waitUntil(timeout: 5) { harness.app.client !== clientBefore }
        XCTAssertTrue(rebuilt, "precondition: a credential change must rebuild the connection")

        XCTAssertEqual(
            chat.draft,
            "the token rotated, the draft did not",
            "the rebuild was correct and it still destroyed the user's unsent work — the reconnect path exists precisely to re-bind open conversations, and teardown deleted the things it was about to re-bind"
        )
        let reopened = await waitUntil(timeout: 10) { harness.app.connectionState.isOpen }
        XCTAssertTrue(reopened, "the rebuilt connection never opened")
        let rebound = await waitUntil(timeout: 5) { chat.runtimeSessionID != runtimeID }
        XCTAssertTrue(rebound, "the preserved chat was never re-resumed on the new socket")
        let current = try XCTUnwrap(chat.runtimeSessionID)
        XCTAssertTrue(
            harness.app.chat(runtimeSessionID: current) === chat,
            "the re-resumed chat is not the one the event pump can find"
        )

        await harness.tearDown()
    }

    // MARK: CONTROL-1 — switching backends still discards

    func testSwitchingToADifferentBackendStillDiscardsItsChats() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let chat = harness.chat(storedID: "20260819_092000_other")
        await chat.open()
        let runtimeID = try XCTUnwrap(chat.runtimeSessionID)

        let other = BackendProfile(
            name: "somewhere else",
            baseURLString: AppHarness.deadRESTHost,
            authMode: .sessionToken
        )
        harness.app.addProfile(other)
        await harness.app.activate(profileID: other.id, connect: true)

        XCTAssertNil(
            harness.app.chat(runtimeSessionID: runtimeID),
            "a conversation from the previous backend survived a switch to a different one — its stored session id belongs to another machine's state.db"
        )

        harness.app.deleteProfile(id: other.id)
        await harness.tearDown()
    }

    // MARK: CONTROL-2 — a Hermes-profile scope change still discards

    func testChangingTheHermesProfileScopeStillDiscardsTheOldScopesChats() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let chat = harness.chat(storedID: "20260819_092500_scope")
        await chat.open()
        let runtimeID = try XCTUnwrap(chat.runtimeSessionID)

        var rescoped = try XCTUnwrap(harness.app.activeProfile)
        rescoped.hermesProfile = "work"
        harness.app.update(rescoped)

        let discarded = await waitUntil(timeout: 5) {
            harness.app.chat(runtimeSessionID: runtimeID) == nil
        }
        XCTAssertTrue(
            discarded,
            "a Hermes profile is a separate HERMES_HOME and a separate state.db — carrying the old scope's conversations into the new one shows a hub scoped to work with a chat from the default scope open over it"
        )

        await harness.tearDown()
    }
}
