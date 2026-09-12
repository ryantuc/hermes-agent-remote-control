import HermesServeKit
import SwiftUI
import XCTest

@testable import HermesMobile

/// BUG-046, second half: **the decoder mishandles the payload shape the
/// backend actually sends.**
///
/// The contract is written down in the backend's own source
/// (`hermes_cli/skin_engine.py:838-844` at `de25a6971d`): paired palettes are
/// *not* merged over the default skin's blocks, and an empty block means "this
/// skin has no hand-tuned variant for that polarity", so a consumer falls back
/// to `colors` and adapts. Mobile reads `raw[polarityKey] ?? raw["colors"]`,
/// and an empty JSON object is not nil — so the fallback never fires, both
/// polarity seeds come back nil, and `applyBackendSkin` abandons the whole
/// update.
///
/// This is not an edge case. Of the backend's nine built-in skins, exactly one
/// (`default`) carries any paired block at all, and even that one's
/// `dark_colors` is empty. Eight of nine send two empty objects. So "Follow
/// backend skin" is inert for almost every skin that can be picked.
///
/// These tests drive the **real** `AppModel` through `ScriptedBackend`, because
/// the projection bug lives in `AppModel.seedSkin` and the abandonment lives in
/// `AppModel.applyBackendSkin`. Testing `Theme` alone would step over both.
@MainActor
final class BackendSkinProjectionTests: XCTestCase {

    // MARK: 4 — an empty paired block means "no variant", not "no skin"

    /// `mono` — and `ares`, `slate`, `poseidon`, `sisyphus`, `charizard`,
    /// `daylight`, `warm-lightmode` — send `light_colors: {}` and
    /// `dark_colors: {}`. Both polarities must still resolve, from `colors`.
    func testEmptyPairedBlocksFallBackToTheBaseColours() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        harness.theme.followBackendSkin = true

        await harness.backend.emit(
            "skin.changed",
            sessionID: "",
            payload: ScriptedBackend.monoSkinPayload()
        )
        let applied = await waitUntil { harness.theme.backendSkinName == "mono" }
        XCTAssertTrue(applied, "the skin change was dropped entirely — both polarity seeds decoded to nil and the apply was abandoned")

        XCTAssertNotNil(
            harness.theme.backendDark,
            "dark_colors was an empty object, so the decoder should have fallen back to `colors`"
        )
        XCTAssertNotNil(
            harness.theme.backendLight,
            "light_colors was an empty object, so the decoder should have fallen back to `colors` and adapted"
        )
        XCTAssertEqual(harness.theme.backendDark?.bg.hex, 0x0E0E0E)

        await harness.tearDown()
    }

    // MARK: 5 — a partial overlay merges over the base, per key

    /// The blocks are overlays, not replacements. A skin that hand-tunes only
    /// its light accent still gets its base background; taking the block whole
    /// would leave the required keys missing and drop the skin on the floor.
    func testAPartialOverlayMergesOverTheBaseColoursPerKey() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        harness.theme.followBackendSkin = true

        await harness.backend.emit(
            "skin.changed",
            sessionID: "",
            payload: ScriptedBackend.skinPayload(
                name: "partial",
                colors: ["background": "#101010", "ui_text": "#EEEEEE", "ui_accent": "#FF0000"],
                lightColors: ["ui_accent": "#00FF00"]
            )
        )
        let applied = await waitUntil { harness.theme.backendSkinName == "partial" }
        XCTAssertTrue(applied, "the partial-overlay skin never applied")

        XCTAssertEqual(
            harness.theme.backendLight?.accent.hex, 0x00FF00,
            "the light overlay's accent did not win"
        )
        XCTAssertEqual(
            harness.theme.backendLight?.bg.hex, 0x101010,
            "the light overlay omitted `background`, so it must come from the base `colors`; taking the overlay whole loses it"
        )

        await harness.tearDown()
    }

    // MARK: 6 — a skin change replaces both polarities, atomically

    /// `Theme.applyBackendSkin` writes `if let dark { … }` and `if let light
    /// { … }`, so a payload that resolves one polarity leaves the other one
    /// showing the *previous* skin. Two skins on screen at once, depending on
    /// which way the device's appearance is set.
    func testChangingSkinReplacesBothPolaritiesAndKeepsNothingStale() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        harness.theme.followBackendSkin = true

        await harness.backend.emit("skin.changed", sessionID: "", payload: ScriptedBackend.defaultSkinPayload())
        _ = await waitUntil { harness.theme.backendSkinName == "default" }
        let goldLight = harness.theme.backendLight?.bg.hex

        await harness.backend.emit("skin.changed", sessionID: "", payload: ScriptedBackend.monoSkinPayload())
        let switched = await waitUntil { harness.theme.backendSkinName == "mono" }
        XCTAssertTrue(switched, "the second skin change never applied")

        XCTAssertNotEqual(
            harness.theme.backendLight?.bg.hex, goldLight,
            "the light polarity still holds the previous skin's background — the snapshot was merged into stale state instead of replacing it"
        )
        XCTAssertEqual(harness.theme.backendLight?.bg.hex, 0x0E0E0E)
        XCTAssertEqual(harness.theme.backendDark?.bg.hex, 0x0E0E0E)

        await harness.tearDown()
    }

    /// And back the other way, because `default` is the only skin with a
    /// non-empty paired block: going `mono → default` exercises the opposite
    /// merge direction, where the incoming payload has a light variant and the
    /// outgoing state has one derived from `colors`.
    func testChangingBackToDefaultAlsoReplacesBothPolarities() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        harness.theme.followBackendSkin = true

        await harness.backend.emit("skin.changed", sessionID: "", payload: ScriptedBackend.monoSkinPayload())
        _ = await waitUntil { harness.theme.backendSkinName == "mono" }

        await harness.backend.emit("skin.changed", sessionID: "", payload: ScriptedBackend.defaultSkinPayload())
        let switched = await waitUntil { harness.theme.backendSkinName == "default" }
        XCTAssertTrue(switched, "the change back to `default` never applied")

        // Asserted as an equality against `default`'s own background rather
        // than as "not mono's". The inequality form passed on the broken tree
        // for the wrong reason: mono never applied at all there, so `nil` was
        // trivially not mono's background and the test was green while the bug
        // it names was live.
        XCTAssertEqual(
            harness.theme.backendDark?.bg.hex, 0x0B0B0F,
            "dark did not come from `default`'s own `colors`: `default` sends an empty `dark_colors`, so dark must be re-derived from the base rather than left holding mono"
        )
        XCTAssertEqual(
            harness.theme.backendLight?.bg.hex, 0xF5F5F5,
            "light did not take `default`'s light overlay, which is the one non-empty paired block the backend ships"
        )

        await harness.tearDown()
    }

    // MARK: 7 — the first palette is never lost to task ordering

    /// `AppModel.theme` starts nil and is assigned in `HermesMobileApp`'s
    /// `.task`, while `RootView` starts the backend bootstrap in a *separate*
    /// `.task`. Nothing orders them. If `gateway.ready` wins the race,
    /// `applyBackendSkin`'s `guard let theme` drops the palette and nothing
    /// replays it.
    ///
    /// In practice the assignment is the first synchronous statement of its
    /// task body and the handshake needs a round trip, so this will almost
    /// never fire on a real device — which is precisely the argument for closing
    /// it structurally rather than waiting to see it. A hand check cannot find
    /// this and a retry cannot fix it.
    func testAReadySkinArrivingBeforeTheThemeIsAttachedIsReplayed() async throws {
        let harness = await AppHarness.makeWithoutTheme()
        await harness.backend.setReadySkin(ScriptedBackend.monoSkinPayload())

        try await harness.openSocket()

        harness.attachTheme()

        let replayed = await waitUntil { harness.theme.backendSkinName == "mono" }
        XCTAssertTrue(
            replayed,
            "gateway.ready arrived before the theme was attached and the palette was dropped: the app is now painting a default skin while the backend believes it pushed one"
        )
        XCTAssertNotNil(harness.theme.backendDark)

        await harness.tearDown()
    }

    /// The ordinary ordering must keep working, so the replay is not allowed to
    /// become the only path that does.
    func testAReadySkinArrivingAfterTheThemeIsAttachedStillApplies() async throws {
        let harness = await AppHarness.make()
        await harness.backend.setReadySkin(ScriptedBackend.defaultSkinPayload())

        try await harness.openSocket()

        let applied = await waitUntil { harness.theme.backendSkinName == "default" }
        XCTAssertTrue(applied, "the handshake's skin never reached the theme")

        await harness.tearDown()
    }
}
