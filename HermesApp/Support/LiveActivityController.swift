import ActivityKit
import CryptoKit
import Foundation
import HermesServeKit
import Observation
import SwiftUI
import UIKit
import os

/// Owns every Live Activity this app has on screen, and is the second place in the app where a person can allow a command to run.
@MainActor
final class LiveActivityController: ApprovalActivityHandling {
    static let shared = LiveActivityController(surface: ActivityKitSurface())

    private let logger = Logger(subsystem: "com.hermes.mobile.app", category: "liveactivity")

    /// The one door to ActivityKit — `ActivityKitSurface` in the app, a recording fake in the tests.
    private let surface: LiveActivitySurface

    private weak var app: AppModel?
    /// Live activities by runtime session id.
    private var activities: [String: LiveActivityHandle] = [:]
    /// The last content state actually pushed, so an unchanged flush is not an ActivityKit update.
    private var lastPushed: [String: LiveActivitySnapshot] = [:]
    private var lastPushAt: [String: Date] = [:]
    /// Turn start per session — the elapsed timer's origin.
    private var startedAt: [String: Date] = [:]
    /// Most recently active first. The roster's eviction order.
    private var recency: [String] = []
    /// Sessions whose card the user took off, cleared when the turn ends so the next turn starts clean.
    private var suppressed: Set<String> = []
    /// Pending turn-ended wind-downs, by session; a session that deserves its card again inside the linger cancels the task and keeps the card.
    private var windDownTasks: [String: Task<Void, Never>] = [:]
    /// Sessions whose `Activity.request` the platform refused, keyed against the state it was refused for.
    /// A refused session stays in `desired`, and reconcile runs on every engine flush, so an unremembered refusal is thirty retries a second.
    private var startRefusals: [String: String] = [:]

    /// BUG-062 C, Home's half: which sessions are waiting on a person right now, for views. Written by `reconcile`, which already sees every tracked session; nothing here depends on whether a card is allowed.
    let waiting = WaitingSessions()

    /// Cosmetic updates coalesce; anything that changes what a person is being asked goes immediately.
    private static let minimumUpdateInterval: TimeInterval = 1.0
    /// How long a finished card lingers showing its ended state before the real ActivityKit end, and the resurrection window.
    var windDownLinger: TimeInterval = 8
    /// How long after its last push a card waiting on a person is pushed again with a fresh stale date: inside the stale window, so the card does not grey out while this app is alive to vouch for the wait.
    var waitingRefreshInterval: TimeInterval = LiveActivityDerivation.staleWindow - 60
    /// The pending re-push of a waiting card, by session. A task sleeps through a suspension, so a card the app can no longer vouch for greys out on time.
    private var refreshTasks: [String: Task<Void, Never>] = [:]

    init(surface: LiveActivitySurface) {
        self.surface = surface
    }

    // MARK: - Wiring

    /// BUG-070 A. The intent bridge, called from `HermesMobileApp.init()` long before there is an `AppModel`; idempotent and safe to call twice.
    func installBridge() {
        ApprovalActivityBridge.handler = self
    }

    func install(app: AppModel) {
        self.app = app
        installBridge()
        // BUG-070 C. The tap router lives here because resolving a runtime session id into a route is `AppModel`'s job.
        ApprovalNotifications.route = { [weak self] session in
            self?.routeToChat(session: session)
        }
        note("installed enabled=\(surface.isAuthorized) master=\(LiveActivityPreferences.enabled) lockScreen=\(LiveActivityPreferences.lockScreen) island=\(LiveActivityPreferences.island) when=\(LiveActivityPreferences.showPolicy.rawValue)")
        // An activity survives the app being killed, so re-requesting one for the same session would put a second card up beside the ghost.
        adoptOrphans()
        // Not redundant: nothing orders `install` against the connection bootstrap, so `sessionDidUpdate` can run before `app` is set here.
        reconcile()
    }

    /// End every card the system is holding that this process has no handle for, filtering on handle identity rather than session-key membership.
    /// Runs on every foreground as well as at `install`: `Activity.activities` is frequently still empty when install asks.
    func adoptOrphans() {
        let existing = surface.existing()
        let orphans = existing.filter { $0.id != activities[$0.sessionKey]?.id }
        guard !orphans.isEmpty else { return }
        note("adopt found=\(existing.count) orphans=\(orphans.count) ids=\(orphans.map(\.sessionKey).joined(separator: ","))")
        for orphan in orphans {
            // A card that cannot be updated will sit at its last count forever, so end it rather than leave a lie on the glass.
            orphan.end(nil, removeAt: nil)
            note("adopt ended stale session=\(orphan.sessionKey) id=\(orphan.id)")
        }
    }

    // MARK: - Reconciliation

    /// Called from `AppModel.publish` on every engine flush for a session, and from settings when the roster or master toggle changes.
    func sessionDidUpdate(sessionID: String) {
        touch(sessionID)
        reconcile()
    }

    private func touch(_ sessionID: String) {
        recency.removeAll { $0 == sessionID }
        recency.insert(sessionID, at: 0)
    }

    /// The whole roster in one pass: decide who deserves a card, start what is missing, end what is not, update the rest.
    func reconcile() {
        guard let app else { return }

        let authorised = surface.isAuthorized
        // FEAT-019: `presentationAllowed` is the master and at least one surface left to draw on, because ActivityKit cannot request half an activity.
        let cap = (LiveActivityPreferences.presentationAllowed && authorised) ? LiveActivityRoster.cap : 0

        // Ordered most-recently-active first, which is what makes the roster's eviction rule "oldest loses".
        let live = app.liveSessions()

        // Deliberately above the cap and the suppression filter: whether a card is allowed has nothing to do with whether a person should be told their agent is blocked.
        // BUG-062: this is the one place that sees every tracked session's turn state, so syncing here covers clarify, sudo and secret as well as approval.
        let prompts = Self.blockingPrompts(in: live)
        let signIns = Self.signInsWaiting(in: live)
        ApprovalNotifications.sync(prompts: prompts, signIns: signIns)
        waiting.update(prompts: Self.waitingPrompts(prompts, signIns: signIns)) { runtimeID in storedIDs(forRuntimeID: runtimeID, app: app) }

        // A dismissal only holds for the turn it was made in.
        suppressed = suppressed.filter { live[$0].map(deserves) ?? false }

        let eligible = live.filter { deserves($0.value) && !suppressed.contains($0.key) }
        let desired = recency.filter { eligible[$0] != nil }
            + eligible.keys.filter { !recency.contains($0) }.sorted()

        let plan = LiveActivityRoster.plan(
            desired: desired,
            current: Array(activities.keys),
            cap: cap
        )

        if !plan.isEmpty {
            note("roster desired=[\(desired.joined(separator: ","))] start=[\(plan.start.joined(separator: ","))] end=[\(plan.end.joined(separator: ","))] keep=[\(plan.keep.joined(separator: ","))] cap=\(cap)")
        }

        for key in plan.end {
            // Split on the TURN, not on eligibility: a session still running lost the cap race and is evicted, while a session whose turn is over winds down, because re-requesting a card resets the elapsed timer and loses the island slot.
            // Deliberately not `eligible[key] != nil`: eligibility folds in the auto-start policy, so flipping it off mid-turn would paint "Done" on a cron turn that is still running.
            if live[key].map({ $0.state.isBusy || $0.state.hasBlockingPrompt }) ?? false {
                end(sessionID: key, reason: "roster cap")
            } else {
                windDown(sessionID: key)
            }
        }
        for key in plan.start { start(sessionID: key) }
        for key in plan.keep { update(sessionID: key) }
    }

    /// Which sessions are blocked on a person, and on what; an approval outranks everything because it is the one with a 300 s fuse on it.
    static func blockingPrompts(in live: [String: LiveActivityContext]) -> [String: ApprovalNotifications.PromptKind] {
        var prompts: [String: ApprovalNotifications.PromptKind] = [:]
        for (sessionID, context) in live {
            let state = context.state
            if state.currentApproval != nil {
                prompts[sessionID] = .approval
            } else if state.sudo != nil {
                prompts[sessionID] = .sudo
            } else if state.secret != nil {
                prompts[sessionID] = state.secret?.requiresDesktop == true ? .desktop : .secret
            } else if state.clarify != nil {
                prompts[sessionID] = .clarify
            }
        }
        return prompts
    }

    /// Which sessions' turns wait on a connector sign-in card. The card is not a blocking prompt (it is a dock row, not the approval sheet), so it is listed apart from them, but the person is needed all the same.
    static func signInsWaiting(in live: [String: LiveActivityContext]) -> Set<String> {
        Set(live.filter { $0.value.state.connection != nil }.map(\.key))
    }

    /// What Home and the other-chat banner mark as waiting: every blocking prompt, plus a sign-in card on a session with no blocking prompt.
    static func waitingPrompts(_ prompts: [String: ApprovalNotifications.PromptKind], signIns: Set<String>) -> [String: ApprovalNotifications.PromptKind] {
        var waiting = prompts
        for sessionID in signIns where waiting[sessionID] == nil { waiting[sessionID] = .signIn }
        return waiting
    }

    /// BUG-062 B. The card's parked line for a blocking prompt; nil for an approval, which has its own copy and the only buttons a card may carry.
    static func parkedQuestion(for kind: ApprovalNotifications.PromptKind?) -> ParkedQuestion? {
        switch kind {
        case .clarify, .sudo, .secret: return .answer
        case .desktop: return .desktop
        case .approval, .signIn, nil: return nil
        }
    }

    /// The durable ids Home's rows are keyed by, for one runtime session: the open chat's stored id, and any `session.active_list` row that names this runtime id.
    private func storedIDs(forRuntimeID runtimeID: String, app: AppModel) -> [String] {
        var ids: [String] = []
        if let stored = app.chat(runtimeSessionID: runtimeID)?.storedSessionID, !stored.isEmpty { ids.append(stored) }
        for (key, status) in app.liveStatuses where status.id == runtimeID { ids.append(key) }
        return ids
    }

    /// A turn is running or someone is being asked something, and FEAT-019's when-to-show row agrees; an unattended session additionally needs the auto-start row.
    private func deserves(_ context: LiveActivityContext) -> Bool {
        guard LiveActivityPreferences.showPolicy.admits(
            isBusy: context.state.isBusy,
            hasBlockingPrompt: context.state.hasBlockingPrompt || context.state.connection != nil
        ) else { return false }
        return context.isAttended || LiveActivityPreferences.autoStartForCron
    }

    // MARK: - Start / update / end

    private func start(sessionID: String) {
        guard let app, let context = app.activityContext(for: sessionID) else { return }
        // Already refused for a state that has not moved since, so asking again cannot produce a different answer.
        let refusalKey = Self.refusalKey(for: context)
        guard startRefusals[sessionID] != refusalKey else { return }
        let started = startedAt[sessionID] ?? Date()
        startedAt[sessionID] = started

        let snapshot = snapshot(for: sessionID, context: context, startedAt: started)
        let attributes = HermesActivityAttributes(
            sessionKey: sessionID,
            backendName: context.backendName,
            skin: context.skin
        )

        do {
            let activity = try surface.request(
                attributes: attributes,
                snapshot: snapshot,
                staleDate: LiveActivityDerivation.staleDate(from: Date())
            )
            activities[sessionID] = activity
            lastPushed[sessionID] = snapshot
            lastPushAt[sessionID] = Date()
            armWaitingRefresh(sessionID: sessionID, snapshot: snapshot)
            startRefusals[sessionID] = nil
            note("start session=\(sessionID) id=\(activity.id) tools=\(snapshot.toolsCompleted)/\(snapshot.toolsTotal)")
            observe(activity, sessionID: sessionID)
        } catch let error as ActivityAuthorizationError {
            // Logged rather than surfaced: a card that could not start is not a failure of the turn.
            note("start REFUSED session=\(sessionID) error=\(error) (\(error.localizedDescription))")
            startRefusals[sessionID] = refusalKey
            fallBackToNotification(sessionID: sessionID, context: context)
        } catch {
            note("start FAILED session=\(sessionID) error=\(error)")
            startRefusals[sessionID] = refusalKey
            fallBackToNotification(sessionID: sessionID, context: context)
        }
    }

    /// What a refusal was refused for — the inputs that could make the same request succeed next time.
    /// BUG-116: the application state is in the key because iOS refuses a start from the background and allows one from the foreground.
    private static func refusalKey(for context: LiveActivityContext) -> String {
        let state = describe(UIApplication.shared.applicationState)
        let prompt = blockingPrompts(in: ["k": context])["k"]?.rawValue ?? "none"
        let token = context.state.currentApproval?.id.uuidString ?? ""
        return "\(state)|\(prompt)|\(token)|\(context.state.isBusy)|\(context.state.connection != nil)"
    }

    /// BUG-116. A card that could not start, on a turn that is blocked on a person.
    /// iOS refuses to start a Live Activity from the background and this app requests no push-to-start token, so under "Questions" the notification is the only surface left.
    private func fallBackToNotification(sessionID: String, context: LiveActivityContext) {
        let prompts = Self.blockingPrompts(in: [sessionID: context])
        guard let kind = prompts[sessionID] else {
            if context.state.connection != nil {
                note("start fallback session=\(sessionID) notification=sign-in")
                ApprovalNotifications.scheduleSignIn(sessionID: sessionID)
            }
            return
        }
        note("start fallback session=\(sessionID) notification=\(kind.rawValue)")
        ApprovalNotifications.schedule(sessionID: sessionID, kind: kind)
    }

    private func update(sessionID: String) {
        guard let app,
              let activity = activities[sessionID],
              let context = app.activityContext(for: sessionID)
        else { return }

        // A wind-down in progress on a session that deserves its card again: cancel the pending end and repaint the same card, with the timer origin moved to now.
        // Above the unchanged-snapshot early return on purpose, or the reset origin is one update stale.
        if let pending = windDownTasks.removeValue(forKey: sessionID) {
            pending.cancel()
            startedAt[sessionID] = Date()
            lastPushed[sessionID] = nil
            lastPushAt[sessionID] = nil
            note("wind-down cancelled session=\(sessionID) — a new turn took the card back")
        }

        let started = startedAt[sessionID] ?? Date()
        let snapshot = snapshot(for: sessionID, context: context, startedAt: started)
        // A session waiting on a person sends nothing until it is answered, so its unchanged card is pushed again before its stale date passes.
        let refreshDue = Self.staleRefreshDue(snapshot, lastPushAt: lastPushAt[sessionID], interval: waitingRefreshInterval, now: Date())
        guard snapshot != lastPushed[sessionID] || refreshDue else { return }

        // An approval appearing or being answered changes what the person is being asked, so it is never coalesced; everything else can wait a second, because ActivityKit budgets updates and silently drops the excess.
        let consentChanged = snapshot.approvalToken != lastPushed[sessionID]?.approvalToken
        // FEAT-019: nor is a surface being switched off, because the next engine flush that would carry it may never come.
        let presentationChanged = snapshot.shownSurfaces != lastPushed[sessionID]?.shownSurfaces
        // BUG-062 B: nor a question arriving or going, because a session parked on one sends nothing more until it is answered.
        let parkedChanged = snapshot.parkedQuestion != lastPushed[sessionID]?.parkedQuestion
        if !consentChanged, !presentationChanged, !parkedChanged, !refreshDue,
           let last = lastPushAt[sessionID],
           Date().timeIntervalSince(last) < Self.minimumUpdateInterval {
            return
        }

        lastPushed[sessionID] = snapshot
        lastPushAt[sessionID] = Date()
        activity.update(snapshot, staleDate: LiveActivityDerivation.staleDate(from: Date()))
        armWaitingRefresh(sessionID: sessionID, snapshot: snapshot)
        if consentChanged {
            note("update session=\(sessionID) approval=\(Self.logFingerprint(snapshot.approvalToken)) fitsIsland=\(snapshot.approvalFitsIsland)")
        }
        if parkedChanged {
            note("update session=\(sessionID) parked=\(snapshot.parkedQuestion?.rawValue ?? "none")")
        }
    }

    /// Whether an unchanged card is due a re-push: it is waiting on a person and its last push is nearly as old as the refresh interval.
    static func staleRefreshDue(_ snapshot: LiveActivitySnapshot, lastPushAt: Date?, interval: TimeInterval, now: Date) -> Bool {
        guard snapshot.isWaitingOnPerson, let lastPushAt else { return false }
        // A sleeping task wakes a little early or late; five percent keeps the timer's own wake-up from missing.
        return now.timeIntervalSince(lastPushAt) >= interval * 0.95
    }

    /// Re-push a waiting card before it goes stale; anything else cancels the pending re-push.
    private func armWaitingRefresh(sessionID: String, snapshot: LiveActivitySnapshot) {
        refreshTasks.removeValue(forKey: sessionID)?.cancel()
        guard snapshot.isWaitingOnPerson else { return }
        let interval = waitingRefreshInterval
        refreshTasks[sessionID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.refreshTasks[sessionID] = nil
            self.update(sessionID: sessionID)
        }
    }

    /// The turn behind this card is over: say so on the glass now and schedule the real end after the linger, in case a queued prompt starts the next turn onto the same card.
    private func windDown(sessionID: String) {
        refreshTasks.removeValue(forKey: sessionID)?.cancel()
        guard activities[sessionID] != nil, windDownTasks[sessionID] == nil else { return }
        guard let base = lastPushed[sessionID] else {
            end(sessionID: sessionID, reason: "turn ended")
            return
        }
        let failed = app?.activityContext(for: sessionID)?.state.lastError != nil
        let final = LiveActivityDerivation.ended(base, at: Date(), failed: failed)
        lastPushed[sessionID] = final
        lastPushAt[sessionID] = Date()
        activities[sessionID]?.update(final, staleDate: nil)
        // The linger is a resurrection window, and a session the engine no longer tracks cannot resurrect: the reconnect re-seed rebinds the chat to a new runtime id and forgets this one.
        let stillTracked = app?.engine.trackedSessionIDs.contains(sessionID) ?? true
        guard stillTracked else {
            note("wind-down session=\(sessionID) failed=\(failed) linger=0s — the engine no longer tracks this session")
            end(sessionID: sessionID, reason: "turn ended, session gone from the engine")
            return
        }
        note("wind-down session=\(sessionID) failed=\(failed) linger=\(windDownLinger)s")
        windDownTasks[sessionID] = Task { [weak self] in
            let linger = self?.windDownLinger ?? 8
            try? await Task.sleep(nanoseconds: UInt64(linger * 1_000_000_000))
            guard !Task.isCancelled, let self, self.windDownTasks[sessionID] != nil else { return }
            self.windDownTasks[sessionID] = nil
            self.end(sessionID: sessionID, reason: "turn ended")
        }
    }

    private func end(sessionID: String, reason: String) {
        windDownTasks.removeValue(forKey: sessionID)?.cancel()
        refreshTasks.removeValue(forKey: sessionID)?.cancel()
        guard let activity = activities.removeValue(forKey: sessionID) else { return }
        let final = lastPushed[sessionID]
        lastPushed[sessionID] = nil
        lastPushAt[sessionID] = nil
        startedAt[sessionID] = nil
        startRefusals[sessionID] = nil
        note("end session=\(sessionID) reason=\(reason)")
        // Never `.default` — that leaves an ended card on the Lock Screen for up to four hours.
        activity.end(final, removeAt: Date().addingTimeInterval(8))
    }

    /// End every card. The master toggle going off, and sign-out.
    func endAll(reason: String) {
        for key in activities.keys { end(sessionID: key, reason: reason) }
    }

    // MARK: - The roster (spec §5.3)

    /// The `n` in `Chats on Lock Screen (n of 2)`.
    var activeCount: Int { activities.count }

    /// Whether this session has a card up right now; AppModel's engine eviction (BUG-004) gates on this, and a card in wind-down deliberately counts.
    func hasCard(sessionID: String) -> Bool {
        activities[sessionID] != nil
    }

    /// BUG-004 housekeeping, called when AppModel forgets an engine session; `recency` in particular grows with every session ever touched and is walked on every reconcile.
    func sessionEvicted(sessionID: String) {
        recency.removeAll { $0 == sessionID }
        refreshTasks.removeValue(forKey: sessionID)?.cancel()
        startRefusals[sessionID] = nil
        suppressed.remove(sessionID)
        startedAt[sessionID] = nil
        lastPushed[sessionID] = nil
        lastPushAt[sessionID] = nil
        waiting.forget(runtimeID: sessionID)
    }

    struct RosterRow: Identifiable {
        /// The runtime session id.
        let id: String
        let title: String
        let detail: String
    }

    func rosterRows() -> [RosterRow] {
        activities.keys.compactMap { key -> RosterRow? in
            guard let snapshot = lastPushed[key] else { return nil }
            let detail: String
            if snapshot.hasEnded {
                detail = snapshot.statusText.isEmpty ? "Finished" : snapshot.statusText
            } else if snapshot.hasApproval {
                detail = "Waiting for your approval"
            } else if let parked = snapshot.parkedQuestion {
                detail = parked.line
            } else if snapshot.toolsTotal > 0 {
                detail = "\(snapshot.toolName.isEmpty ? "Working" : snapshot.toolName) · \(snapshot.toolsCompleted)/\(snapshot.toolsTotal)"
            } else {
                detail = snapshot.statusText.isEmpty ? "Working" : snapshot.statusText
            }
            return RosterRow(id: key, title: snapshot.title, detail: detail)
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Take one chat off the Lock Screen by hand; `suppressed` is why this is not just `end`, since reconciliation runs on every engine flush.
    func dismiss(sessionID: String) {
        suppressed.insert(sessionID)
        end(sessionID: sessionID, reason: "taken off by hand")
    }

    private func observe(_ activity: LiveActivityHandle, sessionID: String) {
        activity.observeState { [weak self] state in
            self?.note("state session=\(sessionID) -> \(state.rawValue)")
            // Without the suppression the next tool event would raise a fresh card in place of the one the user swiped away.
            if state == .dismissed || state == .ended {
                // A wind-down counting down to an end that can no longer happen must not outlive the card.
                self?.windDownTasks.removeValue(forKey: sessionID)?.cancel()
                self?.refreshTasks.removeValue(forKey: sessionID)?.cancel()
                self?.activities.removeValue(forKey: sessionID)
                self?.lastPushed[sessionID] = nil
                if state == .dismissed { self?.suppressed.insert(sessionID) }
            }
        }
    }

    private func snapshot(
        for sessionID: String,
        context: LiveActivityContext,
        startedAt: Date
    ) -> LiveActivitySnapshot {
        let derived = LiveActivityDerivation.snapshot(
            from: context.state,
            title: context.title,
            startedAt: startedAt,
            // The island shows the text the approval sheet shows, or it shows nothing.
            redactCommand: DisplayRedaction.approvalCommand,
            // FEAT-019. In the content state, not the attributes: attributes are immutable for the life of an activity, so a surface switched off mid-turn would never reach a card already up.
            surfaces: LiveActivityPreferences.surfaces
        )
        // BUG-062 B. Keyed off the session's prompt fields, which `TurnEngine` projects from the current-request registry, and not off `isBusy` or the running tool: a turn parked on a question is still "busy" and its running tool is the question.
        let kind = Self.blockingPrompts(in: [sessionID: context])[sessionID]
        // A blocking prompt outranks a sign-in card; an approval keeps its own copy and buttons.
        let parked: ParkedQuestion? = kind == nil && context.state.connection != nil ? .signIn : Self.parkedQuestion(for: kind)
        return ParkedQuestion.applying(parked, to: derived)
    }

    // MARK: - ApprovalActivityHandling

    /// Everything the gate checks except the second factor, run before the app authenticates so a button on a timed-out request does not raise a Face ID sheet for something that is gone.
    func preflight(token: String, session: String, approving: Bool) -> IslandApprovalDecision {
        let head = headApproval(session: session)
        guard approving else {
            return IslandApprovalGate.decideDeny(token: token, headToken: head?.id.uuidString)
        }
        return IslandApprovalGate.decideApprove(
            token: token,
            headToken: head?.id.uuidString,
            headChoices: head?.choices ?? [],
            commandFitsIsland: fitsIsland(head),
            authenticated: true
        )
    }

    func canAnswerFromActivity(token: String, session: String, approving: Bool) async -> Bool {
        // BUG-070 A. The bridge is installed in `HermesMobileApp.init()`, so a button pressed during a cold launch reaches this before the model that owns the approval queue exists.
        let ready = await waitForApp()
        if !ready {
            note("\(approving ? "approve" : "deny") NO-MODEL session=\(session) token=\(Self.logFingerprint(token)) — the app never finished launching")
        }
        let decision = preflight(token: token, session: session, approving: approving)
        if decision != .submit {
            note("\(approving ? "approve" : "deny") PREFLIGHT-REFUSED session=\(session) token=\(Self.logFingerprint(token)) decision=\(decision.rawValue)")
            // With no `AppModel` the gate refuses for want of a queue to read, not because the queue is empty, so the request may still be waiting.
            refuse(session: session, reason: ready ? .requestGone : .appNotReady)
        }
        return decision == .submit
    }

    /// BUG-070 B. A press that could not be answered, made visible: end the ghost card, say so in a notification, and route to the chat if this phone has it.
    private func refuse(session: String, reason: ApprovalNotifications.RefusalNotice) {
        switch reason {
        case .requestGone:
            // The queue was read and there is nothing at its head, so the card whose buttons were just pressed is a ghost.
            adoptOrphans()
        case .appNotReady:
            // Deliberately not `adoptOrphans()`: with no `AppModel`, `activities` is empty, so adopting would end every card the system is holding.
            break
        }
        ApprovalNotifications.scheduleRefusal(sessionID: session, notice: reason)
        // Through the notification's own queue, not straight into the nav stack: Deny does not foreground the app, so a destination asked for here must wait until the user is actually looking.
        ApprovalNotifications.requestRoute(sessionID: session)
    }

    /// How long an intent waits for the `AppModel` before giving up.
    var bridgeWaitTimeout: TimeInterval = 4

    /// BUG-070 A. Bounded, because a wait that never ends is a button that never answers, and the widget's process gets its own copy of this type with no app behind it.
    private func waitForApp() async -> Bool {
        if app != nil { return true }
        let deadline = Date().addingTimeInterval(bridgeWaitTimeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if app != nil { return true }
        }
        return app != nil
    }

    /// The gated path: foreground, biometric, then the gate re-evaluated against the queue as it stands after the prompt, because an approval ages out at 300 s and the next one takes the head slot.
    func approveFromActivity(token: String, session: String) async {
        note("approve BEGIN session=\(session) token=\(Self.logFingerprint(token)) appState=\(Self.describe(UIApplication.shared.applicationState))")

        let foreground = await waitForForeground()
        note("approve foreground=\(foreground)")

        let authenticated = await BiometricConfirmation.confirm(
            reason: "Confirm running this command from the Dynamic Island"
        )
        note("approve authenticated=\(authenticated)")

        let head = headApproval(session: session)
        let decision = IslandApprovalGate.decideApprove(
            token: token,
            headToken: head?.id.uuidString,
            headChoices: head?.choices ?? [],
            commandFitsIsland: fitsIsland(head),
            authenticated: authenticated
        )
        note("approve decision=\(decision.rawValue)")

        guard decision == .submit, let request = head, let chat = chat(session: session) else {
            // BUG-070 B, with one distinction the deny path does not need: a refused biometric is not a dead request.
            if head == nil {
                refuse(session: session, reason: .requestGone)
            } else {
                routeToChat(session: session)
            }
            return
        }
        // `once`, never `session`, never `always`: the island cannot host the read gate or the hold, so it does not get the choices those protect.
        note("approve GATE PASSED session=\(session) — calling respond(choice: once)")
        await chat.respond(to: request, choice: .once)
        // `respond` has its own head-of-queue guard and returns silently without an `approvalAPI`, so the honest line is whether the request is still pending afterwards.
        note("approve DONE session=\(session) stillPending=\(chat.pendingApproval != nil)")
    }

    /// The fail-closed path — no second factor by design, because making deny harder than approve on a lock screen would be the wrong incentive.
    func denyFromActivity(token: String, session: String) async {
        let head = headApproval(session: session)
        let decision = IslandApprovalGate.decideDeny(token: token, headToken: head?.id.uuidString)
        note("deny session=\(session) token=\(Self.logFingerprint(token)) decision=\(decision.rawValue)")
        guard decision == .submit, let request = head, let chat = chat(session: session) else {
            // BUG-070 B. Deny has no second factor, so every way of failing this guard means the request is gone.
            refuse(session: session, reason: .requestGone)
            return
        }
        await chat.respond(to: request, choice: .deny)
        note("deny SUBMITTED session=\(session)")
    }

    // MARK: - Helpers

    private func chat(session: String) -> ChatModel? {
        app?.chat(runtimeSessionID: session)
    }

    private func headApproval(session: String) -> ApprovalRequestEvent? {
        chat(session: session)?.pendingApproval
    }

    private func fitsIsland(_ request: ApprovalRequestEvent?) -> Bool {
        guard let request else { return false }
        return IslandCommandBudget.fits(DisplayRedaction.approvalCommand(request.command))
    }

    /// Put the person where they can answer properly, because a button that does nothing visible is indistinguishable from a button that worked.
    private func routeToChat(session: String) {
        guard let app else { return }
        guard let chat = app.chat(runtimeSessionID: session), let route = app.route(for: chat) else {
            // BUG-070 C. The session is not open on this phone, and home is the same landing the card's own deep link takes; anywhere else would be guessing at which conversation was meant.
            app.requestRoute([])
            return
        }
        app.requestRoute([.thread(route)])
    }

    /// `openAppWhenRun` brings the app forward before `perform()` runs, but the transition is not instantaneous and `LAContext` cannot present its sheet from a process that is not on screen.
    private func waitForForeground(timeout: TimeInterval = 4) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if UIApplication.shared.applicationState == .active { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return UIApplication.shared.applicationState == .active
    }

    /// What a log line may say about an approval token: "none", or a short one-way fingerprint that matches lines about the same approval up. The token is what the island's Approve sends back to answer the request, and `note` reaches the unified log in every build, so neither the token nor a piece of it is written.
    static func logFingerprint(_ token: String) -> String {
        guard !token.isEmpty else { return "none" }
        let digest = SHA256.hash(data: Data(token.utf8))
        return "#" + digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    private static func describe(_ state: UIApplication.State) -> String {
        switch state {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }

    /// Both channels on purpose: only stdout reaches `devicectl process launch --console`, which is the only way to read anything off a tethered phone.
    private func note(_ message: String) {
        logger.info("\(message, privacy: .public)")
        #if DEBUG
        notesForTesting.append(message)
        print("[live-activity] \(message)")
        fflush(stdout)
        #endif
    }

    #if DEBUG
    /// Every line `note` wrote, so a test can read what reached the log.
    private(set) var notesForTesting: [String] = []
    #endif
}

/// What the app knows about a session that the activity needs and the kit cannot derive.
struct LiveActivityContext {
    var state: SessionTurnState
    var title: String
    var backendName: String
    var skin: LiveActivitySkinSeed
    /// This phone has a `ChatModel` for the session; false means a cron or desktop-started run we are only watching on the socket.
    var isAttended: Bool
}

/// BUG-062 C, Home's half. Which sessions the current-request registry says are waiting on a person, observable so a question arriving, or being answered on another client, repaints Home with no turn event behind it.
///
/// Two keys because Home and the registry use two id spaces: Home's rows carry durable ids, the registry and the engine carry runtime ids.
@MainActor
@Observable
final class WaitingSessions {
    private(set) var byRuntimeID: [String: ApprovalNotifications.PromptKind] = [:]
    private(set) var byStoredID: [String: ApprovalNotifications.PromptKind] = [:]

    /// What a Home row's session is waiting on, if anything. `runtimeID` is the row's `session.active_list` join, passed in at render time because that list moves on its own poll.
    func kind(storedID: String, runtimeID: String?) -> ApprovalNotifications.PromptKind? {
        if let kind = byStoredID[storedID] { return kind }
        if let runtimeID, let kind = byRuntimeID[runtimeID] { return kind }
        // A live-only row with no durable key is keyed by its runtime id.
        return byRuntimeID[storedID]
    }

    /// Replace the whole picture from one reconcile pass; `storedIDs` maps a runtime id to the durable ids Home might key it by.
    func update(prompts: [String: ApprovalNotifications.PromptKind], storedIDs: (String) -> [String]) {
        var stored: [String: ApprovalNotifications.PromptKind] = [:]
        for (runtimeID, kind) in prompts {
            for id in storedIDs(runtimeID) where stored[id] == nil || kind == .approval {
                stored[id] = kind
            }
        }
        // Guarded: `@Observable` publishes on every assignment, and this runs on every engine flush.
        if prompts != byRuntimeID { byRuntimeID = prompts }
        if stored != byStoredID { byStoredID = stored }
    }

    /// The engine forgot this session, so nothing can be waiting on it any more.
    func forget(runtimeID: String) {
        if byRuntimeID[runtimeID] != nil { byRuntimeID[runtimeID] = nil }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
