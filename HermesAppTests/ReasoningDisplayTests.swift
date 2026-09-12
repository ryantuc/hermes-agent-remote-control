import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// BUG-017 (C) — the phone imported a TERMINAL-UI preference and let it decide
/// whether its reasoning disclosure had a body at all.
///
/// `AppModel.syncThinkingMode()` read `config.get thinking_mode` on every
/// connect and wrote the answer into the `@AppStorage` key `ReasoningBlock`
/// renders from. That key's effective default on an unconfigured backend is
/// `collapsed`, `ReasoningBlock` had no `collapsed` branch, and the phone has
/// no UI to change it — so the stock experience through a five-minute think was
/// a chevron, a timer, and nothing else.
///
/// `ReasoningBlock` is a `private struct` in a target with no UI tests, so the
/// render branch itself cannot be asserted here. What IS assertable, and what
/// these pin, is that a backend holding `thinking_mode: collapsed` no longer
/// reaches the phone's rendering at all.
final class ReasoningDisplayTests: XCTestCase {

    /// A backend that answers `thinking_mode` the way an unconfigured one does.
    /// Every other key keeps `ScriptedBackend`'s default `config.get` answer,
    /// so `refreshDefaultCwd` behaves exactly as it does in every other test.
    private static func stubThinkingMode(_ backend: ScriptedBackend) async {
        await backend.stub("config.get") { call in
            if call.params["key"]?.coercedString == "thinking_mode" {
                return .object(["value": .string("collapsed")])
            }
            return .object(["cwd": .string("/scripted"), "model": .string("scripted-model")])
        }
    }

    /// Run the app's REAL connect path and return the `config.get` keys it
    /// asked for.
    ///
    /// **`AppHarness.openSocket()` is deliberately not used here.** It dials
    /// `client.connect()` directly, so `AppModel.connect()`'s body — the only
    /// place `syncThinkingMode()` was ever called from — never runs, and a test
    /// built on it would assert the absence of a call that was never going to
    /// be made either way. `app.connect()` is the path the app takes when a
    /// profile is activated.
    ///
    /// Since BUG-024 the post-open ceremony runs on the state pump's task off
    /// the `.open` transition, so `connect()` returning no longer means the
    /// config reads have landed — hence the wait below rather than a bare
    /// await. Two reads is the right bar: `syncThinkingMode()` sat immediately
    /// BEFORE `refreshDefaultCwd()` in that sequence, so by the time `project`
    /// and `provider` are in the log, a `thinking_mode` read would already be
    /// in it too. The absence these tests assert is a real absence, not an
    /// early look.
    @MainActor
    private func connectAndCollectConfigKeys(_ harness: AppHarness) async -> [String] {
        await harness.app.connect()
        _ = await waitUntil { await harness.backend.callCount("config.get") >= 2 }
        XCTAssertNil(harness.app.connectionError, "the connect path itself failed")
        return await harness.backend.calls(to: "config.get")
            .map { $0.params["key"]?.coercedString ?? "" }
    }

    /// The regression guard: connect must issue the config reads the phone
    /// genuinely uses and **must not** issue this one.
    @MainActor
    func testConnectDoesNotImportTheTerminalThinkingMode() async throws {
        let harness = await AppHarness.make()
        await Self.stubThinkingMode(harness.backend)

        let keys = await connectAndCollectConfigKeys(harness)
        XCTAssertTrue(
            keys.contains("project") && keys.contains("provider"),
            "the reads the phone actually uses are untouched — this is not a silence"
        )
        XCTAssertFalse(
            keys.contains("thinking_mode"),
            "a terminal-UI preference must not decide how the phone renders reasoning"
        )

        await harness.tearDown()
    }

    /// The consequence, at the surface that matters: whatever the backend holds
    /// for `thinking_mode`, the defaults key `ReasoningBlock` reads is never
    /// written by the app. Before the fix this test's stubbed `collapsed` would
    /// have landed in `UserDefaults` on connect and put the disclosure into the
    /// one mode that rendered nothing.
    ///
    /// The stale-value case is deliberately NOT claimed here: a device that
    /// connected under an older build still has `collapsed` in its defaults and
    /// deleting the import cannot erase it. That is handled at the other end —
    /// `ReasoningBlock`'s new `else` branch renders the preview in every mode —
    /// and it is a view behaviour this target cannot reach.
    @MainActor
    func testAConnectNeverWritesTheReasoningModeDefault() async throws {
        let key = "hermes.reasoning.mode"
        let original = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        defer {
            if let original {
                UserDefaults.standard.set(original, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        let harness = await AppHarness.make()
        await Self.stubThinkingMode(harness.backend)
        let keys = await connectAndCollectConfigKeys(harness)
        XCTAssertFalse(keys.isEmpty, "the connect path's config reads ran")

        XCTAssertNil(
            UserDefaults.standard.string(forKey: key),
            "a backend holding `collapsed` must not be able to write the phone's render mode"
        )

        await harness.tearDown()
    }
}
