import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// FEAT-019 — the Live Activity control surface: on/off per presentation, and a
/// say in *when* a card is earned.
///
/// ## Why these assertions are written against the literal `UserDefaults` keys
///
/// Two reasons, and both matter. First, the stored key **is** the contract: a
/// preference is a value on a device that survives the app being reinstalled
/// over and updated, so a test that only ever goes through the typed accessor
/// cannot see a key renamed out from under a phone that already has a choice
/// stored in it. Second, this file had to compile against the commit *before*
/// the feature existed in order to be run red — a test that fails to build
/// proves nothing about behaviour, and every accessor these assertions would
/// otherwise name was added by the same change they are meant to be checking.
///
/// The keys, all under the `hermes.activity.` prefix `LiveActivityPreferences`
/// already owned: `enabled` (the master, off by default), `cron`, `lockScreen`,
/// `island`, `when`.
@MainActor
final class LiveActivityControlsTests: XCTestCase {

    // MARK: - Keys

    private static let masterKey = "hermes.activity.enabled"
    private static let cronKey = "hermes.activity.cron"
    private static let lockScreenKey = "hermes.activity.lockScreen"
    private static let islandKey = "hermes.activity.island"
    private static let whenKey = "hermes.activity.when"

    private static let allKeys = [masterKey, cronKey, lockScreenKey, islandKey, whenKey]

    /// `HermesAppTests` is hosted **in the app**, so every one of these keys is
    /// the real one and it is shared with every other test in the target. What
    /// this file sets, it puts back — including putting a key back to *absent*,
    /// which is not the same as putting it back to `false`.
    private var saved: [String: Any?] = [:]

    override func setUp() {
        super.setUp()
        saved = Dictionary(
            uniqueKeysWithValues: Self.allKeys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        )
    }

    override func tearDown() {
        for (key, value) in saved {
            if let value {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        saved = [:]
        // `install(app:)` pointed the island's intent bridge at a test-owned
        // controller. Put the app's own back: the bridge holds its handler
        // weakly, and a nil handler makes every later island button a silent
        // no-op.
        ApprovalActivityBridge.handler = LiveActivityController.shared
        super.tearDown()
    }

    // MARK: - Staging

    @MainActor
    private struct Rig {
        let harness: AppHarness
        let fake: FakeLiveActivitySurface
        let controller: LiveActivityController

        func tearDown() async { await harness.tearDown() }
    }

    /// A harness whose `LiveActivityController` records instead of calling
    /// ActivityKit, with the master on and cron auto-start on — a test about
    /// which turns earn a card has nothing to say if no card can ever start.
    ///
    /// **Every one of the five keys is written here, none of them assumed.**
    /// `HermesAppTests` is hosted in the app, so these are the real defaults and
    /// they accumulate across suites and across runs; a rig that only set what
    /// it cared about would inherit whatever the last interrupted run left
    /// behind. The two the caller varies are parameters rather than a write the
    /// caller makes first, so nothing depends on the order.
    private func makeRig(
        when: String = "everyTurn",
        surfaces: (lockScreen: Bool, island: Bool) = (true, true)
    ) async throws -> Rig {
        UserDefaults.standard.set(true, forKey: Self.masterKey)
        UserDefaults.standard.set(true, forKey: Self.cronKey)
        UserDefaults.standard.set(surfaces.lockScreen, forKey: Self.lockScreenKey)
        UserDefaults.standard.set(surfaces.island, forKey: Self.islandKey)
        UserDefaults.standard.set(when, forKey: Self.whenKey)

        let harness = await AppHarness.make()
        // Session mirroring is what makes a chatless card ordinary rather than
        // exotic: every session on the host reaches this socket.
        await harness.backend.setSessionMirroring(true)

        let fake = FakeLiveActivitySurface()
        let controller = LiveActivityController(surface: fake)
        harness.app.liveActivities = controller
        controller.install(app: harness.app)

        try await harness.openSocket()
        return Rig(harness: harness, fake: fake, controller: controller)
    }

    // MARK: - (1) When a card is earned

    /// RED before FEAT-019. The verdict on the shipped cards is that
    /// they are mostly useless — a plain running turn is not worth the Lock
    /// Screen. With `when` set to questions-only, a turn that is merely running
    /// must not put anything on the glass.
    func testQuestionsOnlyKeepsAPlainRunningTurnOffTheGlass() async throws {
        let rig = try await makeRig(when: "questionsOnly")

        await rig.harness.backend.emitAssistantText("rotating the logs", sessionID: "when-plain")
        let busy = await waitUntil { rig.harness.app.engine.state(for: "when-plain").isBusy }
        XCTAssertTrue(busy, "precondition: the turn never reached the engine, so nothing below proves anything")

        let carded = await waitUntil(timeout: 2) { rig.fake.handle(for: "when-plain") != nil }
        XCTAssertFalse(
            carded,
            """
            a turn that is only running raised a Live Activity even though the \
            when-to-show preference is questions-only. Nothing reads that \
            preference, so every turn still earns a card — which is the state \
            that made the cards mostly useless.
            """
        )

        await rig.tearDown()
    }

    /// The one card that is always worth it: a question the
    /// agent is blocked on. Green before and after — this is the case FEAT-019
    /// must not cost, and the questions-only filter is worthless if it also
    /// suppresses the thing it exists to keep.
    func testQuestionsOnlyStillShowsACardWhenTheAgentAsksSomething() async throws {
        let rig = try await makeRig(when: "questionsOnly")

        await rig.harness.backend.emit("approval.request", sessionID: "when-question", payload: .object([
            "command": .string("systemctl restart hermes"),
            "description": .string("restart the agent service"),
        ]))
        let asked = await waitUntil { rig.harness.app.engine.state(for: "when-question").hasBlockingPrompt }
        XCTAssertTrue(asked, "precondition: the approval never reached the engine")

        let carded = await waitUntil { rig.fake.handle(for: "when-question") != nil }
        XCTAssertTrue(
            carded,
            "the agent is blocked on a question and nothing appeared — questions-only suppressed the one card that is always worth showing"
        )

        await rig.tearDown()
    }

    // MARK: - (2) Off, per surface

    /// RED before FEAT-019. Two switches that both say off must add up to off.
    /// ActivityKit has **one** activity driving both presentations, so the only
    /// honest reading of "neither surface" is "do not request one at all".
    func testTurningBothSurfacesOffTakesEveryCardOffTheGlass() async throws {
        let rig = try await makeRig()

        await rig.harness.backend.emitAssistantText("still working", sessionID: "surfaces-off")
        let carded = await waitUntil { rig.fake.handle(for: "surfaces-off") != nil }
        XCTAssertTrue(carded, "precondition: no card ever started, so there is nothing to take off")

        UserDefaults.standard.set(false, forKey: Self.lockScreenKey)
        UserDefaults.standard.set(false, forKey: Self.islandKey)
        rig.controller.reconcile()

        let handle = try XCTUnwrap(rig.fake.handle(for: "surfaces-off"))
        XCTAssertTrue(
            handle.isEnded,
            """
            both surface switches are off and the card is still on the glass. \
            Nothing reads the per-surface preferences, so the roster cap is \
            still 2 and the activity keeps running: an off switch that leaves \
            the card up is the same lie BUG-003 was about. \
            Card: \(handle.describeContent)
            """
        )

        await rig.tearDown()
    }

    /// Green before and after: the master toggle's own gate. It is the one
    /// control that has always existed, it is what FEAT-019 rebuilds around,
    /// and the cap arithmetic it rides on is exactly what the surface switches
    /// change — so it is asserted here rather than assumed.
    func testTheMasterOffGateStillTakesEveryCardOffTheGlass() async throws {
        let rig = try await makeRig()

        await rig.harness.backend.emitAssistantText("still working", sessionID: "master-off")
        let carded = await waitUntil { rig.fake.handle(for: "master-off") != nil }
        XCTAssertTrue(carded, "precondition: no card ever started, so there is nothing to take off")

        UserDefaults.standard.set(false, forKey: Self.masterKey)
        rig.controller.reconcile()

        let handle = try XCTUnwrap(rig.fake.handle(for: "master-off"))
        XCTAssertTrue(
            handle.isEnded,
            "the master toggle is off and the card is still on the glass. Card: \(handle.describeContent)"
        )

        await rig.tearDown()
    }

    // MARK: - (3) The stored preferences

    /// The three keys FEAT-019 adds all default **on** — every turn, both
    /// surfaces — and the reasoning is the one `autoStartForCron` already
    /// established: they are refinements *inside* a master toggle that is
    /// already off by default, so someone who deliberately switches Live
    /// Activities on gets the card they switched on rather than a crippled one
    /// they never asked for.
    ///
    /// It is also what keeps this change a no-op on shipped behaviour. The
    /// existing `LiveActivityLifecycleTests` force only `enabled` and `cron`
    /// (`LiveActivityLifecycleTests.swift:68-71`) and then assert that a plain
    /// running turn raises a card; a questions-only default would fail them, and
    /// the house rule is that an existing test is never edited to fit a change.
    func testTheNewPreferencesDefaultOnInsideTheMaster() {
        for key in [Self.lockScreenKey, Self.islandKey, Self.whenKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }

        XCTAssertTrue(LiveActivityPreferences.lockScreen, "the Lock Screen presentation defaulted off")
        XCTAssertTrue(LiveActivityPreferences.island, "the Dynamic Island presentation defaulted off")
        XCTAssertEqual(LiveActivityPreferences.showPolicy, .everyTurn, "the when-to-show default changed shipped behaviour")
        XCTAssertEqual(LiveActivityPreferences.surfaces, .both)

        // The master is what is off by default, and it outranks all three.
        UserDefaults.standard.removeObject(forKey: Self.masterKey)
        XCTAssertFalse(LiveActivityPreferences.enabled)
        XCTAssertFalse(
            LiveActivityPreferences.presentationAllowed,
            "a fresh install would put a card up without anyone asking for one"
        )
    }

    func testThePreferencesRoundTripThroughTheirStoredKeys() {
        LiveActivityPreferences.enabled = true
        LiveActivityPreferences.lockScreen = false
        LiveActivityPreferences.island = true
        LiveActivityPreferences.showPolicy = .questionsOnly

        XCTAssertEqual(UserDefaults.standard.object(forKey: Self.lockScreenKey) as? Bool, false)
        XCTAssertEqual(UserDefaults.standard.object(forKey: Self.islandKey) as? Bool, true)
        XCTAssertEqual(UserDefaults.standard.string(forKey: Self.whenKey), "questionsOnly")

        XCTAssertEqual(LiveActivityPreferences.surfaces, LiveActivitySurfaces(lockScreen: false, island: true))
        XCTAssertEqual(LiveActivityPreferences.showPolicy, .questionsOnly)
        XCTAssertTrue(
            LiveActivityPreferences.presentationAllowed,
            "one surface left is still a surface — the activity has to be requested for the island to exist at all"
        )

        LiveActivityPreferences.surfaces = LiveActivitySurfaces(lockScreen: false, island: false)
        XCTAssertFalse(LiveActivityPreferences.lockScreen)
        XCTAssertFalse(LiveActivityPreferences.island)
        XCTAssertFalse(
            LiveActivityPreferences.presentationAllowed,
            "two switches that both say off have to add up to off"
        )
    }

    /// A value written by a later build and then downgraded onto must not read
    /// as "no cards ever". The fallback is the default, not silence.
    func testAnUnrecognisedStoredPolicyFallsBackToTheDefault() {
        UserDefaults.standard.set("onlyWhenTheMoonIsFull", forKey: Self.whenKey)
        XCTAssertEqual(LiveActivityPreferences.showPolicy, .everyTurn)
    }

    // MARK: - (4) The settings actions

    /// The master switch's contract, asserted where it lives rather than
    /// through the view: writing the preference is not the job — taking the
    /// card off the glass *now* is, and BUG-003 is what a control that only
    /// takes effect at the end of the turn looks like from a Lock Screen.
    func testTheMasterActionEndsEveryCardImmediately() async throws {
        let rig = try await makeRig()

        await rig.harness.backend.emitAssistantText("still working", sessionID: "action-master")
        let carded = await waitUntil { rig.fake.handle(for: "action-master") != nil }
        XCTAssertTrue(carded, "precondition: no card ever started")

        LiveActivitySettingsActions.setMaster(false, controller: rig.controller)

        XCTAssertFalse(LiveActivityPreferences.enabled)
        let handle = try XCTUnwrap(rig.fake.handle(for: "action-master"))
        XCTAssertTrue(
            handle.isEnded,
            "the master switch wrote the preference but left the card up. Card: \(handle.describeContent)"
        )
        XCTAssertTrue(rig.fake.liveHandles.isEmpty, "endAll left something on the glass")

        await rig.tearDown()
    }

    /// The second surface going off is the moment the activity stops being
    /// worth requesting, and it must end the card by the same rule the master
    /// does — not leave an empty one up.
    func testTheSecondSurfaceActionEndsEveryCardImmediately() async throws {
        let rig = try await makeRig()

        await rig.harness.backend.emitAssistantText("still working", sessionID: "action-surfaces")
        let carded = await waitUntil { rig.fake.handle(for: "action-surfaces") != nil }
        XCTAssertTrue(carded, "precondition: no card ever started")

        LiveActivitySettingsActions.setLockScreen(false, controller: rig.controller)
        let afterFirst = try XCTUnwrap(rig.fake.handle(for: "action-surfaces"))
        XCTAssertFalse(
            afterFirst.isEnded,
            "the Lock Screen switch ended the card, but the Dynamic Island is still on and it is the same activity"
        )

        LiveActivitySettingsActions.setIsland(false, controller: rig.controller)
        let afterSecond = try XCTUnwrap(rig.fake.handle(for: "action-surfaces"))
        XCTAssertTrue(
            afterSecond.isEnded,
            "both surfaces are off and the card is still up. Card: \(afterSecond.describeContent)"
        )

        await rig.tearDown()
    }

    /// Switching one surface off does not tear the card down and request a new
    /// one — that resets the elapsed timer and loses the island slot — it
    /// repaints the card that is already there, which is why the choice rides
    /// in the content state rather than in the immutable attributes.
    func testASurfaceSwitchRepaintsTheCardRatherThanReplacingIt() async throws {
        let rig = try await makeRig()

        await rig.harness.backend.emitAssistantText("still working", sessionID: "action-repaint")
        let carded = await waitUntil { rig.fake.handle(for: "action-repaint") != nil }
        XCTAssertTrue(carded, "precondition: no card ever started")

        LiveActivitySettingsActions.setIsland(false, controller: rig.controller)

        XCTAssertEqual(
            rig.fake.requestCount(for: "action-repaint"),
            1,
            "the card was torn down and re-requested, which resets the timer and loses the island slot"
        )
        let handle = try XCTUnwrap(rig.fake.handle(for: "action-repaint"))
        XCTAssertFalse(handle.isEnded)
        let repainted = await waitUntil { handle.lastContent?.showsInIsland == false }
        XCTAssertTrue(
            repainted,
            "the card is still telling the widget to fill the Dynamic Island. Pushed: \(handle.describeContent)"
        )
        XCTAssertEqual(
            handle.lastContent?.showsOnLockScreen,
            true,
            "switching the island off also emptied the Lock Screen card"
        )

        await rig.tearDown()
    }

    /// Narrowing the when-to-show row takes the cards that no longer qualify off
    /// the glass on the way out of the row, rather than leaving them up until
    /// their turns happen to end.
    func testNarrowingWhenToShowTakesADisqualifiedCardOffTheGlass() async throws {
        let rig = try await makeRig()

        await rig.harness.backend.emitAssistantText("still working", sessionID: "action-when")
        let carded = await waitUntil { rig.fake.handle(for: "action-when") != nil }
        XCTAssertTrue(carded, "precondition: no card ever started")

        LiveActivitySettingsActions.setShowPolicy(.questionsOnly, controller: rig.controller)

        let handle = try XCTUnwrap(rig.fake.handle(for: "action-when"))
        XCTAssertTrue(
            handle.isEnded,
            "the turn is only running and questions-only was just chosen, but its card is still up. Card: \(handle.describeContent)"
        )

        await rig.tearDown()
    }
}
