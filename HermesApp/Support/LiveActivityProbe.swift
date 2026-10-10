#if DEBUG
import ActivityKit
import Foundation
import HermesServeKit
import UIKit

/// Band 7e's device/simulator probe (`-hermesActivityProbe`): the Lock Screen
/// card and the Dynamic Island cannot be inspected in a view hierarchy, so this
/// drives the real controller call path and prints every decision.
@MainActor
enum LiveActivityProbe {
    /// `-hermesActivityProbeLeave` — start one card and stop, leaving it up; the
    /// card and the island only draw while the app is not frontmost.
    static func leaveOneRunning(app: AppModel, approval: Bool) async {
        LiveActivityPreferences.enabled = true
        let chat = app.chat(for: .new(UUID()))
        chat.title = "Band 7e — live turn"
        // `-hermesActivityLongCommand` seeds a command past `IslandCommandBudget`,
        // the branch that must show no Approve at all.
        let long = ProcessInfo.processInfo.arguments.contains("-hermesActivityLongCommand")
        let command = long
            ? ([
                "sudo rm -rf /var/lib/hermes/cache/* \\",
                "  && git -C ~/Developer/myproject clean -fdx \\",
                "  && git -C ~/Developer/myproject reset --hard origin/main \\",
                "  && defaults delete com.hermes.mobile.app \\",
                "  && xcrun simctl erase all",
              ].joined(separator: "\n"))
            : "rm -rf ~/Developer/myproject/build"
        chat.seedProbeSession(
            runtimeID: "probe-leave",
            command: approval ? command : nil,
            choices: ["once", "session", "always", "deny"]
        )
        log("seeded busy=\(chat.live.isBusy) approvals=\(chat.live.pendingApprovals.count) entries=\(chat.live.entries.count) runtime=\(chat.runtimeSessionID ?? "nil") areActivitiesEnabled=\(ActivityAuthorizationInfo().areActivitiesEnabled)")
        LiveActivityController.shared.sessionDidUpdate(sessionID: "probe-leave")
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let running = Activity<HermesActivityAttributes>.activities
        log("left running count=\(running.count) ids=\(running.map(\.attributes.sessionKey).joined(separator: ",")) approval=\(approval)")
        for activity in running {
            log("  state=\(activity.activityState) tools=\(activity.content.state.toolsCompleted)/\(activity.content.state.toolsTotal) fitsIsland=\(activity.content.state.approvalFitsIsland)")
        }

        // `-hermesActivityStale` re-pushes with a stale date fifteen seconds out;
        // the real window is 300 s, which nobody waits out twice.
        if ProcessInfo.processInfo.arguments.contains("-hermesActivityStale"), let activity = running.first {
            await activity.update(
                ActivityContent(state: activity.content.state, staleDate: Date().addingTimeInterval(15))
            )
            log("stale date pushed at now+15s — background the app and look again after ~30s")
        }
    }

    static func run(app: AppModel) async {
        log("── environment ──")
        log("areActivitiesEnabled=\(ActivityAuthorizationInfo().areActivitiesEnabled)")
        log("masterToggle=\(LiveActivityPreferences.enabled) cronAutoStart=\(LiveActivityPreferences.autoStartForCron)")
        log("existingActivities=\(Activity<HermesActivityAttributes>.activities.count)")
        log("biometry=\(BiometricConfirmation.availability().isAvailable) name=\(BiometricConfirmation.availability().displayName)")

        // The probe needs the master toggle on; it is off by default. Restored at the end.
        let wasEnabled = LiveActivityPreferences.enabled
        LiveActivityPreferences.enabled = true

        // MARK: Fixtures
        let shortCommand = "rm -rf ~/Developer/myproject/build"
        let longCommand = (1...9).map { "  && rm -rf /Users/you/Library/Developer/Xcode/DerivedData/Hermes-\($0) \\" }
            .joined(separator: "\n")

        let alpha = app.chat(for: .new(UUID()))
        alpha.title = "Build check"
        alpha.seedProbeSession(runtimeID: "probe-a", command: shortCommand, choices: ["once", "session", "always", "deny"])

        let bravo = app.chat(for: .new(UUID()))
        bravo.title = "Workspace reset"
        bravo.seedProbeSession(runtimeID: "probe-b", command: longCommand, choices: ["once", "deny"])

        let charlie = app.chat(for: .new(UUID()))
        charlie.title = "Smart-denied"
        charlie.seedProbeSession(runtimeID: "probe-c", command: shortCommand, choices: ["deny"])

        let tokenA = alpha.pendingApproval?.id.uuidString ?? ""
        let tokenB = bravo.pendingApproval?.id.uuidString ?? ""
        let tokenC = charlie.pendingApproval?.id.uuidString ?? ""
        log("tokens a=\(LiveActivityController.logFingerprint(tokenA)) b=\(LiveActivityController.logFingerprint(tokenB)) c=\(LiveActivityController.logFingerprint(tokenC))")

        log("── derivation ──")
        for (key, chat) in [("probe-a", alpha), ("probe-b", bravo)] {
            let snapshot = LiveActivityDerivation.snapshot(
                from: chat.live,
                title: chat.title,
                startedAt: Date(),
                redactCommand: DisplayRedaction.approvalCommand
            )
            log("\(key) title=\(snapshot.title) tools=\(snapshot.toolsCompleted)/\(snapshot.toolsTotal) tool=\(snapshot.toolName) busy=\(snapshot.isBusy) approval=\(snapshot.hasApproval) fitsIsland=\(snapshot.approvalFitsIsland) commandChars=\(snapshot.approvalCommand.count)")
        }

        // MARK: The roster and the cap
        log("── roster (cap \(LiveActivityRoster.cap)) ──")
        let controller = LiveActivityController.shared
        controller.sessionDidUpdate(sessionID: "probe-a")
        await settle()
        controller.sessionDidUpdate(sessionID: "probe-b")
        await settle()
        log("after two: count=\(controller.activeCount) system=\(Activity<HermesActivityAttributes>.activities.map(\.attributes.sessionKey).joined(separator: ","))")
        controller.sessionDidUpdate(sessionID: "probe-c")
        await settle()
        log("after three: count=\(controller.activeCount) system=\(Activity<HermesActivityAttributes>.activities.map(\.attributes.sessionKey).joined(separator: ","))")
        for row in controller.rosterRows() { log("roster row id=\(row.id) title=\(row.title) detail=\(row.detail)") }

        // MARK: The consent gate
        log("── consent gate: pre-flight ──")
        report("no request at all", controller.preflight(token: tokenA, session: "probe-nonexistent", approving: true))
        report("token from another chat", controller.preflight(token: tokenB, session: "probe-a", approving: true))
        report("empty token", controller.preflight(token: "", session: "probe-a", approving: true))
        report("command too long to read", controller.preflight(token: tokenB, session: "probe-b", approving: true))
        report("backend offered deny only", controller.preflight(token: tokenC, session: "probe-c", approving: true))
        report("everything but authentication", controller.preflight(token: tokenA, session: "probe-a", approving: true))
        report("deny, right token", controller.preflight(token: tokenA, session: "probe-a", approving: false))
        report("deny, wrong token", controller.preflight(token: tokenB, session: "probe-a", approving: false))
        report("deny, no request", controller.preflight(token: tokenA, session: "probe-nonexistent", approving: false))

        // MARK: Staleness
        log("── staleness ──")
        log("staleWindow=\(LiveActivityDerivation.staleWindow)s; every push carries staleDate=now+\(Int(LiveActivityDerivation.staleWindow))s")
        await probeStaleness()

        // MARK: Dismissal
        log("── dismissal ──")
        if let first = controller.rosterRows().first {
            controller.dismiss(sessionID: first.id)
            await settle()
            log("after taking one off: count=\(controller.activeCount)")
            // Suppression has to hold against the very next engine flush, or the card comes back.
            controller.sessionDidUpdate(sessionID: first.id)
            await settle()
            log("after a further update on the same session: count=\(controller.activeCount) (must not have come back)")
        }

        log("── teardown ──")
        controller.endAll(reason: "probe finished")
        await settle()
        log("final count=\(controller.activeCount) system=\(Activity<HermesActivityAttributes>.activities.count)")
        LiveActivityPreferences.enabled = wasEnabled

        // MARK: The second factor
        //
        // Last, and on purpose: this raises a real authentication sheet, so
        // everything above must finish before we block on it. Raced against a
        // timeout rather than awaited, because a simulator's passcode sheet can
        // never be satisfied. Opt in with `-hermesActivityAuth`, person present.
        if ProcessInfo.processInfo.arguments.contains("-hermesActivityAuth") {
            await probeSecondFactor(controller: controller, token: tokenA, chat: alpha)
        } else {
            log("── consent gate: second factor SKIPPED (pass -hermesActivityAuth with a person at the device) ──")
        }
        log("── probe complete ──")
    }

    private static func probeSecondFactor(
        controller: LiveActivityController,
        token: String,
        chat: ChatModel
    ) async {
        log("── consent gate: the real second factor ──")
        log("expect submit only on a successful Face ID / passcode; refuseUnauthenticated on failure, cancel, or a policy that cannot be evaluated")
        log("pending-before=\(chat.pendingApproval != nil)")

        let answered = await withTaskGroup(of: Bool.self) { group in
            group.addTask { @MainActor in
                await controller.approveFromActivity(token: token, session: "probe-a")
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }

        if answered {
            log("second factor answered; pending-after=\(chat.pendingApproval != nil) (true means nothing was submitted)")
        } else {
            log("second factor UNANSWERED after 25s — the gate is up and nothing has been submitted. pending-after=\(chat.pendingApproval != nil)")
        }
    }

    /// Requests a card with a five-second stale date and reads the state back.
    private static func probeStaleness() async {
        let attributes = HermesActivityAttributes(
            sessionKey: "probe-stale",
            backendName: "probe",
            skin: LiveActivitySkinSeed(fg: 0xFFE6CB, accent: 0xFFE6CB, bg: 0x0D2F86, card: 0x12378F, isDark: true)
        )
        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(
                    state: LiveActivitySnapshot(title: "Staleness probe", isBusy: true, startedAt: Date()),
                    staleDate: Date().addingTimeInterval(5)
                ),
                pushType: nil
            )
            log("stale probe requested state=\(activity.activityState)")
            try? await Task.sleep(nanoseconds: 9_000_000_000)
            log("stale probe after 9s state=\(activity.activityState) (expect stale)")
            await activity.end(nil, dismissalPolicy: .immediate)
        } catch {
            log("stale probe FAILED error=\(error)")
        }
    }

    private static func report(_ name: String, _ decision: IslandApprovalDecision) {
        let padded = name.count >= 34 ? name : name + String(repeating: " ", count: 34 - name.count)
        log("\(padded) -> \(decision.rawValue)")
    }

    /// `Activity.request` and `end` are async work kicked off from a
    /// synchronous reconcile; give them a beat before reading the system back.
    private static func settle() async {
        try? await Task.sleep(nanoseconds: 1_200_000_000)
    }

    private static func log(_ message: String) {
        // `print`, not `NSLog`: only stdout reaches `devicectl process launch --console`.
        print("[activity-probe] \(message)")
        fflush(stdout)
    }
}
#endif
