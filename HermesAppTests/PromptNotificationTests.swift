import Foundation
import HermesServeKit
import UIKit
import XCTest

@testable import HermesMobile

/// BUG-116 and BUG-070 — the notification half of the consent surfaces.
///
/// ## What these tests can and cannot see
///
/// They cannot see a notification. `HermesAppTests` is hosted in the app, and a
/// test host is never granted notification authorisation, so `schedule` always
/// returns before `UNUserNotificationCenter.add` — there is nothing delivered to
/// read back. What is assertable is the decision: **which sessions the app
/// believes are blocked, and which of those it armed a notification for.** That
/// is `ApprovalNotifications`' own roster, exposed under `#if DEBUG`.
///
/// ## The app-state seam, and why it had to exist
///
/// A test host is always `.active`, and `.active` is precisely the state in
/// which `sync` arms nothing — the in-app sheet is the surface, so a banner over
/// it would be a double alert. The first version of this file took that as a
/// fact of life and asserted around it, which is how F1 shipped: the one
/// configuration that makes BUG-116's double-arm possible was the one no test
/// could enter. `ApprovalNotifications.isActiveOverrideForTesting` is the fix,
/// and the two tests that use it are the two that could not otherwise be
/// written honestly.
@MainActor
final class PromptNotificationTests: XCTestCase {

    private static let masterKey = "hermes.activity.enabled"
    private static let cronKey = "hermes.activity.cron"
    private static let lockScreenKey = "hermes.activity.lockScreen"
    private static let islandKey = "hermes.activity.island"
    private static let whenKey = "hermes.activity.when"
    private static let allKeys = [masterKey, cronKey, lockScreenKey, islandKey, whenKey]

    private var saved: [String: Any?] = [:]

    override func setUp() {
        super.setUp()
        saved = Dictionary(
            uniqueKeysWithValues: Self.allKeys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        )
        ApprovalNotifications.resetForTesting()
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
        // Puts `isActiveOverrideForTesting` back to nil among everything else —
        // a leaked override would make every later suite in this process think
        // the app is off screen.
        ApprovalNotifications.resetForTesting()
        // The bridge holds its handler weakly and these tests point it at a
        // controller they own. Put the app's own back, or every later island
        // button in this process is a silent no-op.
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

    private func makeRig(
        when: String = "everyTurn",
        foreground: Bool = true,
        enforceForeground: Bool = false
    ) async throws -> Rig {
        UserDefaults.standard.set(true, forKey: Self.masterKey)
        UserDefaults.standard.set(true, forKey: Self.cronKey)
        UserDefaults.standard.set(true, forKey: Self.lockScreenKey)
        UserDefaults.standard.set(true, forKey: Self.islandKey)
        UserDefaults.standard.set(when, forKey: Self.whenKey)

        let harness = await AppHarness.make()
        // Every session on the host reaches this socket, which is what makes a
        // card (and a notification) for a chat nobody opened ordinary.
        await harness.backend.setSessionMirroring(true)

        let fake = FakeLiveActivitySurface()
        fake.enforcesForegroundRequirement = enforceForeground
        fake.isForeground = foreground
        let controller = LiveActivityController(surface: fake)
        harness.app.liveActivities = controller
        controller.install(app: harness.app)

        try await harness.openSocket()
        return Rig(harness: harness, fake: fake, controller: controller)
    }

    /// How many notifications were armed for one session. A count rather than a
    /// membership test, because "was it armed" and "was it armed once" are
    /// different questions and only the second one is the product requirement.
    private func armings(for sessionID: String) -> Int {
        ApprovalNotifications.armedForTesting.filter { $0.sessionID == sessionID }.count
    }

    /// Let the engine go quiet before counting. A count taken the instant the
    /// first arming lands would pass whether or not later flushes add more,
    /// which is the whole failure mode being pinned.
    private func settle() async {
        try? await Task.sleep(nanoseconds: 600_000_000)
    }

    // MARK: - (1) Every blocking prompt, not only approval

    /// BUG-062's oldest complaint, and decision item 2: *"clarify / sudo /
    /// secret: zero notification, zero Live Activity state."* The event pump
    /// notified for `approval.request` and for nothing else, so three of the
    /// four ways a turn can stop for a person went entirely unannounced.
    ///
    /// The roster is driven by `SessionTurnState.hasBlockingPrompt`'s own
    /// members rather than by a case per event, which is what makes this cover
    /// batch clarify too — a batch rides in the same `clarify` slot.
    func testEveryKindOfBlockingPromptReachesTheNotificationRoster() async throws {
        let rig = try await makeRig()

        await rig.harness.backend.emit("clarify.request", sessionID: "prompt-clarify", payload: .object([
            "request_id": .string("q-1"),
            "question": .string("Which branch?"),
        ]))
        await rig.harness.backend.emit("sudo.request", sessionID: "prompt-sudo", payload: .object([
            "request_id": .string("u-1"),
        ]))
        await rig.harness.backend.emit("secret.request", sessionID: "prompt-secret", payload: .object([
            "request_id": .string("s-1"),
            "prompt": .string("API key"),
            "env_var": .string("A_KEY"),
        ]))
        await rig.harness.backend.emit("approval.request", sessionID: "prompt-approval", payload: .object([
            "command": .string("systemctl restart hermes"),
            "description": .string("restart the agent service"),
        ]))

        let armed = await waitUntil {
            ApprovalNotifications.pendingPromptsForTesting.count >= 4
        }
        let roster = ApprovalNotifications.pendingPromptsForTesting
        XCTAssertTrue(
            armed,
            """
            not every blocking prompt reached the notification roster. Only \
            these did: \(roster.map { "\($0.key)=\($0.value.rawValue)" }.sorted().joined(separator: ", ")). \
            A turn stopped on a clarification, a password or a secret is just as \
            blocked as one stopped on an approval, and just as invisible with \
            the phone in a pocket.
            """
        )
        XCTAssertEqual(roster["prompt-clarify"], ApprovalNotifications.PromptKind.clarify)
        XCTAssertEqual(roster["prompt-sudo"], ApprovalNotifications.PromptKind.sudo)
        XCTAssertEqual(roster["prompt-secret"], ApprovalNotifications.PromptKind.secret)
        XCTAssertEqual(roster["prompt-approval"], ApprovalNotifications.PromptKind.approval)

        await rig.tearDown()
    }

    /// The other half of a roster: it has to empty. A notification that outlives
    /// the prompt behind it is the stale "waiting for approval" banner the
    /// generation latch already exists to prevent, arriving by a different
    /// route.
    func testAnsweredPromptsLeaveTheNotificationRoster() async throws {
        let rig = try await makeRig()

        await rig.harness.backend.emit("clarify.request", sessionID: "prompt-settles", payload: .object([
            "request_id": .string("q-1"),
            "question": .string("Which branch?"),
        ]))
        let arrived = await waitUntil {
            ApprovalNotifications.pendingPromptsForTesting["prompt-settles"] == ApprovalNotifications.PromptKind.clarify
        }
        XCTAssertTrue(arrived, "precondition: the clarify never reached the roster, so nothing below proves anything")

        rig.harness.app.engine.clearClarify(sessionID: "prompt-settles")
        rig.harness.app.publish(sessionID: "prompt-settles")

        let cleared = await waitUntil {
            ApprovalNotifications.pendingPromptsForTesting["prompt-settles"] == nil
        }
        XCTAssertTrue(cleared, "the prompt was answered and its notification stayed armed")

        await rig.tearDown()
    }

    // MARK: - (2) BUG-116 — the card iOS will not start

    /// **The seam the whole suite was green over.**
    ///
    /// `Activity.request` throws `ActivityAuthorizationError.visibility` when an
    /// app tries to start a Live Activity from the background — Apple's own
    /// one-line definition — and "Questions" mode moves the request out of the
    /// foreground by construction: there is deliberately no card during the
    /// running turn, so the first request happens whenever the agent gets round
    /// to asking, which is exactly when the phone is locked. `pushType: nil`
    /// means there is no push-to-start route either.
    ///
    /// With the fake's app-state gate on, this is the reported symptom: the
    /// agent asks, and nothing appears. What must happen instead is a
    /// notification, exactly one.
    func testACardRefusedInTheBackgroundFallsBackToANotification() async throws {
        // The host-state override, and the reason this test was blind without
        // it: a test host is always `.active`, which is the one state in which
        // `sync` arms nothing. Without this, only the fallback's arm ever ran
        // and the count below could not fail. Saying the app is off screen puts
        // both arming paths in the same `reconcile`, which is the real
        // configuration the item was filed against.
        ApprovalNotifications.isActiveOverrideForTesting = false
        let rig = try await makeRig(when: "questionsOnly", foreground: false, enforceForeground: true)

        await rig.harness.backend.emit("approval.request", sessionID: "refused-card", payload: .object([
            "command": .string("rm -rf /var/log/hermes"),
            "description": .string("clear the logs"),
        ]))
        let asked = await waitUntil { rig.harness.app.engine.state(for: "refused-card").hasBlockingPrompt }
        XCTAssertTrue(asked, "precondition: the approval never reached the engine")

        let carded = await waitUntil(timeout: 2) { rig.fake.handle(for: "refused-card") != nil }
        XCTAssertFalse(carded, "precondition: the fake's app-state gate did not refuse, so this is not the case under test")

        let armed = await waitUntil { self.armings(for: "refused-card") > 0 }
        XCTAssertTrue(
            armed,
            """
            iOS refused the card because the app is in the background and \
            nothing took its place, so Questions mode shows nothing at \
            all. Armed instead: \
            \(ApprovalNotifications.armedForTesting.map(\.sessionID)).
            """
        )

        // **A count, not a membership test.** One question is one alert. In a
        // single `reconcile` pass the roster arms the notification and then the
        // refused `Activity.request` arms it again, and re-adding a request
        // whose identifier is already delivered re-alerts — two buzzes for one
        // question. Worse, a refused session never enters `activities`, so it
        // comes back in `plan.start` on the next flush and every flush after,
        // at up to thirty a second while another chat streams. `contains` is
        // true for one arming and equally true for a thousand.
        await settle()
        XCTAssertEqual(
            armings(for: "refused-card"),
            1,
            """
            one blocked question armed \(armings(for: "refused-card")) notifications. \
            Every one past the first is another buzz for a question the user has \
            already been told about.
            """
        )

        await rig.tearDown()
    }

    /// The gate is opt-in, and this is the guard that proves it. Every test
    /// written before BUG-116 staged its cards through a fake that never
    /// refused, and turning the gate on by default would have rewritten what
    /// those assertions mean.
    func testTheForegroundGateIsOffUnlessATestAsksForIt() async throws {
        let rig = try await makeRig(foreground: false)

        await rig.harness.backend.emitAssistantText("rotating the logs", sessionID: "gate-off")
        let carded = await waitUntil { rig.fake.handle(for: "gate-off") != nil }
        XCTAssertTrue(
            carded,
            "the fake refused a request with `enforcesForegroundRequirement` off — every pre-existing card test would change meaning"
        )

        await rig.tearDown()
    }

    // MARK: - (2b) The re-arm on background

    /// The behaviour this feature will be judged by.
    ///
    /// A question that arrives while the user is reading the chat gets no
    /// banner — the sheet is the surface. Then the phone goes in a pocket with
    /// the sheet still up and the 300 s budget still running, and nothing says
    /// so. This is the answer, and nothing prevented it being tested:
    /// `rearmPending` does not consult app state at all, and `schedule` records
    /// the arming before any authorisation check.
    func testAQuestionYouWereLookingAtIsArmedWhenTheAppLeavesTheScreen() async throws {
        let rig = try await makeRig()

        await rig.harness.backend.emit("approval.request", sessionID: "rearm-a", payload: .object([
            "command": .string("systemctl restart hermes"),
            "description": .string("restart the agent service"),
        ]))
        let onRoster = await waitUntil {
            ApprovalNotifications.pendingPromptsForTesting["rearm-a"] == ApprovalNotifications.PromptKind.approval
        }
        XCTAssertTrue(onRoster, "precondition: the approval never reached the roster")
        XCTAssertEqual(
            armings(for: "rearm-a"),
            0,
            "a banner was armed while the user was looking at the app, on top of the sheet already showing the question"
        )

        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        let armed = await waitUntil { self.armings(for: "rearm-a") > 0 }
        XCTAssertTrue(armed, "the phone was put away with a question still pending and nothing was armed")

        // `willResignActive` and `didEnterBackground` both fire on
        // the way out of the foreground, and one question is one alert.
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        await settle()
        XCTAssertEqual(
            armings(for: "rearm-a"),
            1,
            "both leaving-the-foreground notifications armed, so the phone buzzes twice for one question"
        )

        await rig.tearDown()
    }

    /// The foreground sweep clears the banners because they are stale, and
    /// deliberately keeps the roster because the questions behind them are not.
    /// So putting the phone down a second time has to arm again.
    func testAStillPendingQuestionArmsAgainAfterTheForegroundSweep() async throws {
        let rig = try await makeRig()

        await rig.harness.backend.emit("approval.request", sessionID: "rearm-b", payload: .object([
            "command": .string("systemctl restart hermes"),
            "description": .string("restart the agent service"),
        ]))
        let onRoster = await waitUntil {
            ApprovalNotifications.pendingPromptsForTesting["rearm-b"] == ApprovalNotifications.PromptKind.approval
        }
        XCTAssertTrue(onRoster, "precondition: the approval never reached the roster")

        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        let first = await waitUntil { self.armings(for: "rearm-b") == 1 }
        XCTAssertTrue(first, "precondition: the first arming never happened")

        // The user opens the app: every banner is now stale.
        ApprovalNotifications.clearAll()
        // And puts it down again with the question still unanswered.
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)

        let second = await waitUntil { self.armings(for: "rearm-b") == 2 }
        XCTAssertTrue(
            second,
            "the question was still waiting and the phone went away again, and nothing was armed — the roster was swept away with the banners"
        )

        await rig.tearDown()
    }

    /// Nothing to say, so say nothing.
    ///
    /// The observers live for the whole process, so the question is not whether
    /// they fire but what they find: `rearmPending` iterates the roster, and the
    /// roster is populated only from a real `hasBlockingPrompt`. A demo session
    /// and a first run both produce none, and this pins the mechanism both of
    /// those rest on — a turn that is merely running leaves the roster empty.
    func testPuttingThePhoneAwayWithNothingBlockedArmsNothing() async throws {
        let rig = try await makeRig()

        await rig.harness.backend.emitAssistantText("rotating the logs", sessionID: "rearm-quiet")
        let busy = await waitUntil { rig.harness.app.engine.state(for: "rearm-quiet").isBusy }
        XCTAssertTrue(busy, "precondition: the turn never reached the engine")

        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        await settle()

        XCTAssertTrue(
            ApprovalNotifications.armedForTesting.isEmpty,
            "a turn that is merely running woke the phone: \(ApprovalNotifications.armedForTesting.map(\.sessionID))"
        )

        await rig.tearDown()
    }

    // MARK: - (3) BUG-070 C — a tap that goes somewhere

    /// The notification used to carry title, body and sound and nothing else,
    /// and no `didReceive` delegate existed anywhere in the repo. Tapping
    /// "Hermes needs approval" foregrounded whatever screen was last shown,
    /// which burns the 300 s window while the user hunts for the right chat.
    func testTappingAPromptNotificationAsksForTheBlockedChat() async throws {
        let rig = try await makeRig()
        let chat = rig.harness.chat(storedID: "20260826_070c_notificationtap")
        await chat.open()
        let runtimeID = try XCTUnwrap(chat.runtimeSessionID)

        await rig.harness.backend.emit("approval.request", sessionID: runtimeID, payload: .object([
            "command": .string("systemctl restart hermes"),
            "description": .string("restart the agent service"),
        ]))
        let asked = await waitUntil { chat.pendingApproval != nil }
        XCTAssertTrue(asked, "precondition: the approval never parked on the chat")

        rig.harness.app.requestedRoute = nil
        ApprovalNotifications.simulateTapForTesting(sessionID: runtimeID)

        let route = try XCTUnwrap(rig.harness.app.route(for: chat), "the chat has no route to ask for")
        XCTAssertEqual(
            rig.harness.app.requestedRoute,
            [AppRoute.thread(route)],
            "tapping the notification did not ask for the chat the prompt is blocking"
        )

        await rig.tearDown()
    }

    /// A tap on a cold launch: the delegate is installed in
    /// `HermesMobileApp.init()` and the router in the root view's `.task`, so
    /// the tap that launched the process arrives in between. Dropping it would
    /// make the tap a no-op exactly when it is most likely to happen — the app
    /// was closed, which is the only reason there was a banner to tap.
    func testATapThatBeatsTheRouterIsNotThrownAway() async throws {
        let rig = try await makeRig()
        let chat = rig.harness.chat(storedID: "20260826_070c_coldlaunchtap")
        await chat.open()
        let runtimeID = try XCTUnwrap(chat.runtimeSessionID)

        let installed = ApprovalNotifications.route
        ApprovalNotifications.route = nil
        ApprovalNotifications.simulateTapForTesting(sessionID: runtimeID)
        rig.harness.app.requestedRoute = nil

        // The root view's `.task` finally runs.
        rig.controller.install(app: rig.harness.app)

        let route = try XCTUnwrap(rig.harness.app.route(for: chat))
        XCTAssertEqual(
            rig.harness.app.requestedRoute,
            [AppRoute.thread(route)],
            "a notification tapped before the router was installed was dropped rather than queued"
        )

        ApprovalNotifications.route = installed
        await rig.tearDown()
    }

    /// F5. A destination asked for by a Live Activity intent — Deny carries
    /// `openAppWhenRun: false` — must not rewrite the navigation stack while
    /// the app is off screen. The user would open Hermes an hour later for
    /// something unrelated and find themselves in another chat, or popped to
    /// Home out of whatever they had open, with nothing to explain it.
    func testARouteAskedForOffScreenWaitsUntilTheUserIsLooking() async throws {
        let rig = try await makeRig()
        let chat = rig.harness.chat(storedID: "20260827_f5_backgroundroute")
        await chat.open()
        let runtimeID = try XCTUnwrap(chat.runtimeSessionID)
        let route = try XCTUnwrap(rig.harness.app.route(for: chat))

        rig.harness.app.requestedRoute = nil
        ApprovalNotifications.isActiveOverrideForTesting = false
        ApprovalNotifications.requestRoute(sessionID: runtimeID)

        XCTAssertNil(
            rig.harness.app.requestedRoute,
            "an intent running with the app off screen rewrote the navigation stack under a user who was not looking"
        )

        // The user opens Hermes.
        ApprovalNotifications.isActiveOverrideForTesting = true
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)

        let delivered = await waitUntil {
            rig.harness.app.requestedRoute == [AppRoute.thread(route)]
        }
        XCTAssertTrue(delivered, "the queued destination was never delivered once the app came forward")

        await rig.tearDown()
    }

    // MARK: - (4) BUG-070 A — the bridge, before there is an app

    /// The island's Deny carries `openAppWhenRun: false`, so a press during a
    /// cold launch has no foreground wait to lose the race against: it reached
    /// `perform()`, found `ApprovalActivityBridge.handler` nil because only the
    /// root view's `.task` ever installed it, and returned silently.
    func testTheIntentBridgeIsInstalledWithoutAnAppModel() async throws {
        let fake = FakeLiveActivitySurface()
        let controller = LiveActivityController(surface: fake)
        ApprovalActivityBridge.handler = nil

        controller.installBridge()

        XCTAssertTrue(
            ApprovalActivityBridge.handler === controller,
            "installing the bridge needs an AppModel, so a button pressed during launch still finds no handler"
        )
    }

    /// And the other half: a handler installed that early has no approval queue
    /// behind it yet, so it waits for one — boundedly — rather than answering
    /// "no" for a request that is about to become answerable. With no model
    /// ever arriving, the answer is still a refusal, and refusing is what fails
    /// closed.
    func testAnIntentWithoutAnAppModelRefusesRatherThanHangs() async throws {
        let fake = FakeLiveActivitySurface()
        let controller = LiveActivityController(surface: fake)
        controller.bridgeWaitTimeout = 0.3
        controller.installBridge()

        let began = Date()
        let answerable = await controller.canAnswerFromActivity(
            token: UUID().uuidString,
            session: "no-model",
            approving: false
        )
        let waited = Date().timeIntervalSince(began)

        XCTAssertFalse(answerable, "an island button answered a queue that does not exist")
        XCTAssertGreaterThanOrEqual(waited, 0.2, "the intent did not wait for the app model at all")
        XCTAssertLessThan(waited, 3, "the intent waited far past its own timeout — a button that never answers")
    }

    /// **F2.** The same refusal, spoken from two very different states.
    ///
    /// When the queue was read and found empty, "that request is no longer
    /// waiting" is a fact. When the app never finished launching, it is a guess
    /// made from our own failure — and the request may have 250 s left on it.
    /// Telling the user it is dead stops them trying, and then it times out and
    /// fails closed. The branch already draws exactly this distinction for a
    /// failed biometric; it has to draw it here too.
    func testAnIntentThatOutranTheAppDoesNotClaimTheRequestIsGone() async throws {
        let fake = FakeLiveActivitySurface()
        // A card on the Lock Screen belonging to some other chat entirely. It
        // is the whole point of the second assertion: with no `AppModel` this
        // process holds no handles, so `adoptOrphans` would consider every card
        // the system is holding an orphan and end all of them.
        let someoneElsesCard = FakeLiveActivityHandle(id: "ghost-1", sessionKey: "another-chat")
        fake.preexisting = [someoneElsesCard]
        let controller = LiveActivityController(surface: fake)
        controller.bridgeWaitTimeout = 0.3
        controller.installBridge()

        _ = await controller.canAnswerFromActivity(
            token: UUID().uuidString,
            session: "no-model-refusal",
            approving: false
        )

        let notices = ApprovalNotifications.refusalsForTesting.filter { $0.sessionID == "no-model-refusal" }
        XCTAssertEqual(notices.count, 1, "the press produced no feedback at all")
        XCTAssertEqual(
            notices.first?.notice,
            ApprovalNotifications.RefusalNotice.appNotReady,
            """
            the app failed to launch in time and the user was told their request \
            "is no longer waiting" — which nothing here knows, and which may be \
            false with most of the 300 s budget left.
            """
        )

        // The second half of F2: `adoptOrphans` would end EVERY card the system
        // holds, because with no `AppModel` this process holds none of them.
        // The whole Lock Screen cleared because the app was slow to start.
        XCTAssertFalse(
            someoneElsesCard.isEnded,
            "a slow launch ended an unrelated chat's Live Activity — the whole Lock Screen cleared because the app was late"
        )
    }
}
