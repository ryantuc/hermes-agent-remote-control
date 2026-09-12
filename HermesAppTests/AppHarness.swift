import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// Builds a real `AppModel` — the shipped one, with its real pumps, its real
/// `TurnEngine` and its real `ChatModel`s — wired to a `ScriptedBackend`
/// instead of a socket.
///
/// The only production change this needs is `AppModel.init(clientFactory:)`.
/// Everything else the app does is unchanged, which is the point: a test that
/// stubbed `ChatModel` would prove nothing about the app that ships.
///
/// **REST is not scripted.** `AppModel` builds its own `RestAPI` from the
/// profile, and the profile here points at a closed loopback port, so every
/// REST call (`refreshThreads`, `loadTranscript`) fails immediately with
/// connection-refused. That is deliberate and it is fast: the paths under test
/// are the RPC paths, and a REST call that fails is what the app already
/// handles on a backend that has gone away. If a test needs a transcript, stub
/// the RPC that carries one (`session.resume`'s `messages`), not REST.
@MainActor
final class AppHarness {
    let backend: ScriptedBackend
    let hub: TransportHub
    let app: AppModel
    let profileID: UUID

    /// The app's live `Theme`, attached here the way `HermesMobileApp` attaches
    /// it at launch.
    ///
    /// Without this every scripted `gateway.ready` and `skin.changed` was
    /// dropped on the floor: `AppModel.applyBackendSkin` opens with
    /// `guard let theme`, and nothing in this harness ever set one. A test
    /// could script a skin change, watch it be ignored, and pass. That is a
    /// harness defect, not a product one, and it is the reason BUG-046's
    /// projection failures were never caught here.
    let theme: Theme

    /// Nothing listens on port 9, so REST fails with ECONNREFUSED in
    /// microseconds rather than timing out.
    static let deadRESTHost = "http://127.0.0.1:9"

    /// `Theme` persists every setter to `UserDefaults.standard`, so a test that
    /// picks a skin would otherwise leak that choice into the next test and
    /// into the simulator the screenshot harness photographs. Clearing the
    /// three keys on the way in and the way out keeps each test's appearance
    /// state its own.
    private static let themeDefaultsKeys = [
        "hermes.theme.polarity",
        "hermes.theme.followBackendSkin",
        "hermes.theme.localSkin",
    ]

    private static func clearThemeDefaults() {
        for key in themeDefaultsKeys { UserDefaults.standard.removeObject(forKey: key) }
    }

    private init() {
        Self.clearThemeDefaults()
        let backend = ScriptedBackend()
        let hub = TransportHub(backend: backend)
        let dialer = backend.dialer()
        let app = AppModel(clientFactory: { _, _, log in
            HermesClient(
                dialer: dialer,
                log: log,
                transportFactory: { onFrame, onState in
                    hub.make(onFrame: onFrame, onState: onState)
                }
            )
        })
        let profile = BackendProfile(
            name: "Scripted",
            baseURLString: Self.deadRESTHost,
            authMode: .sessionToken
        )
        let theme = Theme()
        app.theme = theme
        self.backend = backend
        self.hub = hub
        self.app = app
        self.theme = theme
        profileID = profile.id
        // A previous run's profile may still be in the host app's defaults.
        app.profiles = []
        app.addProfile(profile)
    }

    /// The whole setup: model, scripted backend, active profile. The socket is
    /// **not** open yet — open it with `openSocket()` once the test has
    /// registered whatever chats it wants in scope for the post-open sweep.
    static func make() async -> AppHarness {
        let harness = AppHarness()
        await harness.app.activate(profileID: harness.profileID, connect: false)
        return harness
    }

    /// Open the socket and wait until `AppModel` has both seen it and finished
    /// the sweep it runs on seeing it.
    ///
    /// Three waits, and all three matter. `ChatModel` guards on
    /// `app.connectionState.isOpen`, so a test that skips the first wait
    /// silently does nothing.
    ///
    /// The `.open` transition then spawns a five-statement sweep on its own
    /// task (`AppModel.swift:1239-1248`): `publishAll()`,
    /// `refreshThreads(force: true)`, `bots.refresh()`, `resumeOpenThreads()`,
    /// `startPolling()`. Every one of the last three writes state tests assert
    /// on — the roster's single-flight, `chat.live`, `chat.errorMessage` — so
    /// `openSocket()` must not return until the whole sweep is done.
    ///
    /// **BUG-132.** It used to return on `threadsError` alone, and that is
    /// assigned inside the *second* statement: the last three ran alongside the
    /// test body. A test's `bots.refresh()` joined the sweep's in-flight one
    /// and sent none of its pins (`BotsModel.swift:151-155`); the
    /// `publishAll()` closing `resumeOpenThreads` reset a send's `sendPhase`
    /// (`AppModel.swift:2086` into `ChatModel.swift:77-82`); and the sweep's
    /// second transcript load put the dead REST port's refusal into
    /// `errorMessage` after a test had cleared it (`ChatModel.swift:605`,
    /// `:676`). Which test went red depended on where the sweep landed, which
    /// is why the suite failed a different set every run.
    ///
    /// `threadsError` is kept as the middle wait because it names the stage
    /// that stalled when one does. `isPollingThreads` is the real drain:
    /// `startPolling()` is the sweep's last statement and its only caller
    /// (`AppModel.swift:1248`, `:1478`), so `isPollingThreads`
    /// (`AppModel.swift:1476`) is true exactly when the sweep has finished.
    ///
    /// The one exception is a test that has deliberately parked one of the
    /// sweep's own RPCs to stage an interleaving (`AppModelResumeTests` parks
    /// `session.resume`). That sweep cannot finish by design, so a parked frame
    /// releases the wait — everything ahead of the park has still been drained.
    func openSocket(file: StaticString = #filePath, line: UInt = #line) async throws {
        guard let client = app.client else {
            return XCTFail("no client — activate() did not run", file: file, line: line)
        }
        try await client.connect()
        let open = await waitUntil { self.app.connectionState.isOpen }
        XCTAssertTrue(open, "the socket never reached .open at the app layer", file: file, line: line)
        let reached = await waitUntil { self.app.threadsError != nil }
        XCTAssertTrue(reached, "the post-open sweep never reached refreshThreads", file: file, line: line)
        let drained = await waitUntil {
            // A test that has parked one of the sweep's own RPCs is holding the
            // sweep open deliberately — `AppModelResumeTests` parks
            // `session.resume` to stage the two-caller race, and waiting for a
            // sweep that cannot finish would break the interleaving that test
            // exists to stage. The park is the test's own signal that it has
            // taken over. Everything before the parked call is still drained,
            // so those tests get a quieter app than they had.
            let parked = await self.backend.parkedCount
            return parked > 0 || self.app.isPollingThreads
        }
        XCTAssertTrue(drained, "the post-open sweep never finished", file: file, line: line)
    }

    /// Register a chat for an existing history row, exactly as the hub does
    /// when a thread is tapped. Registering it *before* the socket opens is
    /// what puts it in scope for the post-open resume sweep.
    @discardableResult
    func chat(storedID: String, title: String = "Scripted thread") -> ChatModel {
        let summary = SessionSummary(json: .object([
            "id": .string(storedID),
            "title": .string(title),
            "source": .string("ios"),
            "last_active": .number(Date().timeIntervalSince1970),
            "message_count": .number(4),
        ]))
        return app.chat(for: .existing(summary))
    }

    func tearDown() async {
        await app.disconnect()
        app.deleteProfile(id: profileID)
        _ = await waitUntil(timeout: 3) { self.app.client == nil }
        app.profiles = []
        Self.clearThemeDefaults()
    }

    /// Build the harness with no theme attached, so a test can drive the
    /// launch-ordering race BUG-046 describes: `gateway.ready` arriving
    /// before `HermesMobileApp` has assigned `app.theme`. Attach it afterwards
    /// with `attachTheme()`.
    static func makeWithoutTheme() async -> AppHarness {
        let harness = AppHarness()
        harness.app.theme = nil
        await harness.app.activate(profileID: harness.profileID, connect: false)
        return harness
    }

    /// The assignment `HermesMobileApp` performs in its `.task`, run late.
    func attachTheme() {
        app.theme = theme
    }
}

/// Poll until `predicate` holds. The kit's connect tests use the same helper
/// for the same reason: the app is full of tasks that settle on their own
/// schedule, and polling a condition is deterministic where sleeping a fixed
/// interval is a coin flip on a loaded machine.
///
/// Returns false on timeout — assert on the result, never ignore it.
@MainActor
func waitUntil(timeout: TimeInterval = 5, _ predicate: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await predicate() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return await predicate()
}
