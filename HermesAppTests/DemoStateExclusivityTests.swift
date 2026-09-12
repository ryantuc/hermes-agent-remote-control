import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// BUG-118 defect 2, BUG-101 and BUG-104 — the demo and a real backend are two
/// states, not one mixed one.
///
/// The reported defect is that entering the demo wrecks the state of a user
/// who is already signed in, and there are three separate mechanisms behind
/// it. `enterDemo` tore down with the default `discardingConversations: true`,
/// so one tap of a button labelled "Try the demo" wiped every cached
/// conversation *bypassing* `ChatModel.isReleasable` — the guard every other
/// departure honours. It left `profiles` and `activeProfileID` untouched, so
/// Home went on naming the real backend and the Backend screen went on drawing
/// its green active dot while nothing at all was connected. And `exitDemo`
/// never called `activate`, so the app came back holding an active id, no
/// client and no conversations — a state in which Retry, wake and foreground
/// all fail their `guard let client` and the only way back to a live connection
/// is to kill the app.
///
/// These tests drive the real `AppModel` through enter and exit with a scripted
/// backend behind it, and assert on all three.
@MainActor
final class DemoStateExclusivityTests: XCTestCase {

    /// Fast enough to finish inside a test, slow enough that the engine's flush
    /// loop still runs between beats. Same value `DemoModeTests` uses.
    private static let testSpeed: Double = 25

    private func summary(_ id: String, _ title: String) -> SessionSummary {
        SessionSummary(json: .object([
            "id": .string(id),
            "title": .string(title),
            "source": .string("ios"),
            "last_active": .number(Date().timeIntervalSince1970),
            "message_count": .number(4),
        ]))
    }

    // MARK: BUG-101 — the conversations are parked, not discarded

    func testEnteringTheDemoWithABackendKeepsTheConversations() async throws {
        let harness = await AppHarness.make()
        let app = harness.app
        defer { app.profiles = [] }
        try await harness.openSocket()

        let chat = harness.chat(storedID: "stored-keep", title: "Half-typed")
        await chat.openIfNeeded()
        chat.draft = "a message the user has not sent yet"
        let identity = ObjectIdentifier(chat)
        let realProfileID = try XCTUnwrap(app.activeProfileID)

        await app.enterDemo(playbackSpeed: Self.testSpeed)

        XCTAssertTrue(app.isDemoActive, "precondition: the demo is running")
        let same = app.chat(for: .existing(summary("stored-keep", "Half-typed")))
        XCTAssertEqual(
            ObjectIdentifier(same), identity,
            "entering the demo discarded the open conversation — `enterDemo` tore down with the discarding default, which is a dictionary wipe that consults neither `isReleasable` nor the draft in it"
        )
        XCTAssertEqual(same.draft, "a message the user has not sent yet", "the unsent draft went with it")

        // The two states are exclusive: no active profile while the demo runs,
        // so nothing on screen can name the real backend.
        XCTAssertNil(
            app.activeProfileID,
            "the real profile stayed active through the demo, which is what let Home draw its name and the Backend screen draw its green dot over a demo"
        )
        XCTAssertEqual(app.parkedProfileID, realProfileID, "the profile is parked, not forgotten")
        XCTAssertEqual(app.backendDisplayName, "Demo", "every surface that names a backend says Demo for the length of the demo")
        XCTAssertTrue(app.profiles.contains { $0.id == realProfileID }, "the profile row itself is untouched")

        await app.exitDemo()
        app.profiles = []
    }

    /// The park is in memory. A process killed mid-demo comes back to the real
    /// backend rather than to a first-run screen.
    func testParkingTheProfileIsNotPersisted() async throws {
        let harness = await AppHarness.make()
        let app = harness.app
        defer { app.profiles = [] }
        try await harness.openSocket()
        let realProfileID = try XCTUnwrap(app.activeProfileID)

        await app.enterDemo(playbackSpeed: Self.testSpeed)
        XCTAssertNil(app.activeProfileID)
        XCTAssertEqual(
            BackendProfileStore.loadActiveID(), realProfileID,
            "parking wrote through to UserDefaults — a crash during the demo would have signed the user out of a backend they never left"
        )

        await app.exitDemo()
        app.profiles = []
    }

    // MARK: BUG-118 defect 2 — exit puts it back, and the app works afterwards

    func testExitingTheDemoReconnectsTheParkedBackend() async throws {
        let harness = await AppHarness.make()
        let app = harness.app
        defer { app.profiles = [] }
        try await harness.openSocket()
        let realProfileID = try XCTUnwrap(app.activeProfileID)

        await app.enterDemo(playbackSpeed: Self.testSpeed)
        await app.exitDemo()

        XCTAssertFalse(app.isDemoActive)
        XCTAssertEqual(app.activeProfileID, realProfileID, "the parked profile must come back active")
        XCTAssertNotNil(
            app.client,
            "`exitDemo` never called `activate`, so the app came back with no client at all — and every recovery control in the app opens with `guard let client`"
        )
        let reopened = await waitUntil(timeout: 5) { app.connectionState.isOpen }
        XCTAssertTrue(reopened, "the socket never came back; the inventory's 'only recovery is killing the app' is exactly this")
        XCTAssertFalse(app.needsBackend, "a backend is signed in again, so the first-run screen must not be showing")
        XCTAssertTrue(
            app.requestedRoute?.isEmpty == true,
            "the exit lands on Home, not on the demo's transcript"
        )

        await harness.tearDown()
    }

    /// The recovery control the inventory proved inert. After an exit, Retry
    /// has to be able to do something — it opens with `guard let client`.
    func testRetryWorksAfterLeavingTheDemo() async throws {
        let harness = await AppHarness.make()
        let app = harness.app
        defer { app.profiles = [] }
        try await harness.openSocket()

        await app.enterDemo(playbackSpeed: Self.testSpeed)
        await app.exitDemo()
        _ = await waitUntil(timeout: 5) { app.connectionState.isOpen }

        await app.connect()
        XCTAssertNotNil(app.client, "Retry routes to `connect()`, whose first line is `guard let client = client else { return }`")
        let open = await waitUntil(timeout: 5) { app.connectionState.isOpen }
        XCTAssertTrue(open, "a turn must be possible after the demo without relaunching the app")

        await harness.tearDown()
    }

    /// With nothing parked — the reviewer's path — the exit lands on the screen
    /// that offers to connect a backend.
    func testExitingWithNoParkedProfileLandsOnFirstRunHome() async throws {
        UserDefaults.standard.removeObject(forKey: "hermes.activeBackendProfile.v1")
        let app = AppModel()
        app.profiles = []
        defer { app.profiles = [] }

        await app.enterDemo(playbackSpeed: Self.testSpeed)
        await app.exitDemo()

        XCTAssertNil(app.parkedProfileID)
        XCTAssertNil(app.client)
        XCTAssertTrue(app.needsBackend)
        XCTAssertTrue(
            app.requestedRoute?.isEmpty == true,
            "an empty path is Home. The old exit routed to Settings → Backend, which was the right answer only while a cold launch could not reach Home at all"
        )
    }

    // MARK: BUG-104 — the demo starts clean, and says so

    func testReEnteringTheDemoStartsFromAnEmptyTranscript() async throws {
        UserDefaults.standard.removeObject(forKey: "hermes.activeBackendProfile.v1")
        let app = AppModel()
        app.profiles = []
        defer { app.profiles = [] }

        await app.enterDemo(playbackSpeed: Self.testSpeed)
        let backend = try XCTUnwrap(app.demo)
        let played = await waitUntil(timeout: 25) {
            let finishedTurns = await backend.completedTurns
            return finishedTurns >= DemoScript.autoplayTurnCount
        }
        XCTAssertTrue(played, "precondition: the script played")
        let first = app.chat(for: app.demoThreadRoute)
        let firstIdentity = ObjectIdentifier(first)
        XCTAssertTrue(
            first.entries.contains { $0.text.contains("Hermes Agent — what it is") },
            "precondition: the first run reached its written report"
        )

        await app.exitDemo()
        await app.enterDemo(playbackSpeed: Self.testSpeed)
        defer { Task { await app.exitDemo() } }

        let second = app.chat(for: app.demoThreadRoute)
        XCTAssertNotEqual(
            ObjectIdentifier(second), firstIdentity,
            "the route key is stable so the demo cannot stack a second navigation identity — but the conversation under it is not, and `exitDemo` drops it deliberately"
        )
        XCTAssertFalse(
            second.entries.contains { $0.text.contains("Hermes Agent — what it is") },
            "re-entering the demo replayed on top of the previous run's finished transcript"
        )
    }

    /// Nothing is evicted while the demo runs — the sweep that fires on the
    /// path change would otherwise release the very conversations `enterDemo`
    /// just preserved.
    func testNothingIsReleasedWhileTheDemoRuns() async throws {
        let harness = await AppHarness.make()
        let app = harness.app
        defer { app.profiles = [] }
        try await harness.openSocket()

        let chat = harness.chat(storedID: "stored-quiet", title: "Quiet and idle")
        await chat.openIfNeeded()
        let identity = ObjectIdentifier(chat)

        await app.enterDemo(playbackSpeed: Self.testSpeed)
        // Exactly what `RootView.onChange(of: path)` does when the demo assigns
        // its route: sweep with only the demo's key in the keep set.
        XCTAssertEqual(
            app.releaseChats(keeping: [app.demoThreadRoute.key]), 0,
            "the path change that enters the demo swept the real conversations away a frame after the entry deliberately kept them"
        )
        let same = app.chat(for: .existing(summary("stored-quiet", "Quiet and idle")))
        XCTAssertEqual(ObjectIdentifier(same), identity)

        await app.exitDemo()
        app.profiles = []
    }
}
