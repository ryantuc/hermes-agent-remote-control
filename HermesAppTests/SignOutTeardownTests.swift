import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// BUG-119 and BUG-069 — sign out has to actually leave the backend.
///
/// The reported defect was that signing out does nothing observable and the app
/// has to be uninstalled to clear its data, and the cause is this: the action
/// called `auth.logout()` — which genuinely does clear the
/// cookies and every Keychain slot — and then `AppModel.disconnect()`, which is
/// five lines that close the socket and cancel one poll. The client, the REST
/// façade, the nine API objects, the eight pumps, the cached conversations, the
/// thread list, the live sets, the engine's roster, `serverStatus` and the
/// active profile id all survived. Nothing on screen changed, which is
/// indistinguishable from nothing happening — and foregrounding still passed
/// `guard let client` and ran REST work against a stack whose credentials had
/// just been thrown away.
///
/// So this test signs out of a live scripted connection and asserts on
/// *everything the next activation could read*. One assertion per surviving
/// thing the audit named.
@MainActor
final class SignOutTeardownTests: XCTestCase {

    /// A connection with something in every bucket sign-out has to empty: an
    /// open socket, a cached chat, a thread list, a live working set, and an
    /// engine tracking a runtime id.
    private func connectedHarness() async throws -> AppHarness {
        let harness = await AppHarness.make()
        await harness.backend.stub("session.active_list") { _ in
            .object(["sessions": .array([
                .object([
                    "id": .string("rt-live"),
                    "session_key": .string("stored-live"),
                    "title": .string("Desktop run"),
                    "preview": .string("mid turn"),
                    "status": .string("working"),
                    "last_active": .number(Date().timeIntervalSince1970),
                ]),
            ])])
        }
        try await harness.openSocket()
        // A session in the engine's roster, arriving the way one really does:
        // a frame off the socket. `state(for:)` does not create an entry, so a
        // test that only asked would have asserted on an empty roster and
        // passed vacuously.
        await harness.backend.emit("message.start", sessionID: "rt-live")
        let tracked = await waitUntil { !harness.app.engine.trackedSessionIDs.isEmpty }
        XCTAssertTrue(tracked, "the engine never picked up the emitted session")
        return harness
    }

    func testSigningOutLeavesNothingTheNextActivationCouldRead() async throws {
        let harness = try await connectedHarness()
        let app = harness.app
        defer { app.profiles = [] }

        // Populate the state the audit found surviving.
        let chat = harness.chat(storedID: "stored-live", title: "Open conversation")
        await chat.openIfNeeded()
        await app.refreshThreads(force: true)
        let cachedIdentity = ObjectIdentifier(chat)

        XCTAssertTrue(app.connectionState.isOpen, "precondition: the socket is open")
        XCTAssertFalse(app.liveActiveIDs.isEmpty, "precondition: a live working set exists")
        XCTAssertFalse(app.engine.trackedSessionIDs.isEmpty, "precondition: the engine tracks the session")

        await app.signOut()

        // A. The connection and everything built from it.
        XCTAssertNil(app.client, "the socket's client survived sign-out — `disconnect()` never nils it")
        XCTAssertNil(app.auth, "the credential holder survived a sign-out that was supposed to discard credentials")
        XCTAssertNil(app.rest, "the REST façade survived, and `handleForeground` calls straight through it")
        XCTAssertNil(app.sessionAPI)
        XCTAssertNil(app.promptAPI)
        XCTAssertNil(app.approvalAPI)
        XCTAssertNil(app.attachmentAPI)
        XCTAssertNil(app.configAPI)
        XCTAssertNil(app.projectsAPI)
        XCTAssertNil(app.profilesAPI)
        XCTAssertNil(app.gitAPI)
        XCTAssertNil(app.audioAPI)
        XCTAssertNil(app.serverStatus, "the Backend screen draws its 'Connected backend' group off this")
        XCTAssertNil(app.identity, "'Signed in as' must not outlive the sign-out")
        XCTAssertEqual(app.connectionState, .idle)

        // B. The live sets — written only by `refreshLiveActive`'s success
        // path, whose failure path deliberately keeps the last known values.
        XCTAssertTrue(
            app.liveActiveIDs.isEmpty,
            "the next backend would inherit this backend's working ids until its own first successful active_list, and indefinitely if that call kept failing"
        )
        XCTAssertTrue(app.liveStatuses.isEmpty)

        // C. Conversations and the engine roster behind them.
        XCTAssertTrue(app.threads.isEmpty, "the history list belonged to the backend we just left")
        XCTAssertTrue(
            app.engine.trackedSessionIDs.isEmpty,
            "dropping the chats without telling the engine leaves the larger half of the leak — and an engine state is what a Lock Screen card draws from"
        )
        let rebuilt = app.chat(for: .existing(SessionSummary(json: .object([
            "id": .string("stored-live"),
            "title": .string("Open conversation"),
            "last_active": .number(Date().timeIntervalSince1970),
        ]))))
        XCTAssertNotEqual(
            ObjectIdentifier(rebuilt), cachedIdentity,
            "the chat cache still held the signed-out backend's conversation"
        )

        // D. The profile: kept, marked, and no longer active.
        XCTAssertNil(app.activeProfileID, "an active id after sign-out is what makes the next launch reconnect")
        XCTAssertTrue(app.needsBackend, "the first-run predicate must flip — that is the visible half of the fix")
        let row = try XCTUnwrap(app.profiles.first)
        XCTAssertTrue(row.signedOut)
        XCTAssertFalse(row.baseURLString.isEmpty, "'Sign out' keeps the address; 'Remove backend' is the other button")

        app.profiles = []
    }

    /// The half of BUG-069 A that is about what happens *next*: foregrounding
    /// after a sign-out must not fire REST and resume work at a backend whose
    /// credentials are gone. The guard it passes is `client != nil`, so the
    /// test is that the guard now holds.
    func testForegroundingAfterSignOutDoesNoBackendWork() async throws {
        let harness = try await connectedHarness()
        let app = harness.app
        defer { app.profiles = [] }

        await app.signOut()
        let before = await harness.backend.receivedCalls.count

        await app.handleForeground()

        let after = await harness.backend.receivedCalls.count
        XCTAssertEqual(
            before, after,
            "foregrounding after sign-out sent \(after - before) more calls — `handleForeground` used to pass its `guard let client` and run wake / refreshThreads / resumeOpenThreads against a logged-out stack"
        )
        app.profiles = []
    }

    /// Sign-out is idempotent and safe with nothing signed in — the control is
    /// disabled in that state, but a model that trapped on it would be a model
    /// one race away from a crash.
    func testSigningOutTwiceIsHarmless() async throws {
        let harness = try await connectedHarness()
        let app = harness.app
        defer { app.profiles = [] }

        await app.signOut()
        await app.signOut()
        XCTAssertNil(app.activeProfileID)
        XCTAssertTrue(app.needsBackend)
        app.profiles = []
    }

    /// A same-backend rebuild is **not** a departure: BUG-025's preserve policy
    /// has to survive everything BUG-069 added to `teardown`.
    func testARebuildStillPreservesConversations() async throws {
        let harness = await AppHarness.make()
        let app = harness.app
        defer { app.profiles = [] }
        try await harness.openSocket()

        let chat = harness.chat(storedID: "stored-keep", title: "Still mine")
        await chat.openIfNeeded()
        let identity = ObjectIdentifier(chat)

        // The credential-edit path: same profile, same Hermes profile.
        var profile = try XCTUnwrap(app.profiles.first)
        profile.name = "renamed"
        app.update(profile, credentialsChanged: true)
        let reconnected = await waitUntil(timeout: 5) { app.connectionState.isOpen }
        XCTAssertTrue(reconnected, "the rebuild never came back up")

        let same = app.chat(for: .existing(SessionSummary(json: .object([
            "id": .string("stored-keep"),
            "title": .string("Still mine"),
            "last_active": .number(Date().timeIntervalSince1970),
        ]))))
        XCTAssertEqual(
            ObjectIdentifier(same), identity,
            "a rebuild of the connection to the same backend must not evict the conversation — BUG-025's whole subject, and the new engine and card eviction must stay on the discard side of that branch"
        )
        await harness.tearDown()
    }
}
