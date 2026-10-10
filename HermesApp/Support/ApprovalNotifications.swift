import UIKit
import UserNotifications

/// The `userInfo` key carrying the runtime session id (BUG-070 C), at file scope because the delegate that reads it is nonisolated and the enum below is `@MainActor`.
private let sessionUserInfoKey = "hermes.session"

/// Local notifications for the prompts a turn stops on, and the routing that makes tapping one worth anything.
/// Every notification here is local and the app declares no background mode, so nothing reaches the phone while Hermes is fully closed or suspended; that would need APNs, which needs a signing key a self-hosted backend cannot ship.
/// Authorisation is asked for at the first successful connect, because iOS cannot present the permission dialog while the app is backgrounded.
@MainActor
enum ApprovalNotifications {
    /// The pending-prompt family, one identifier per session so a clarify arriving after an approval in the same chat replaces the banner.
    /// The string is deliberately unchanged from when only approvals used it: a delivered notification survives an app update, and renaming the prefix would orphan every banner already on a phone.
    private static let pendingPrefix = "hermes.approval.pending."
    /// The BUG-070 B family, separate because it must not be cleared by the pending sweep — it is the record of an answer that did not land.
    private static let refusalPrefix = "hermes.approval.refused."

    private static let presenter = ForegroundPresenter()

    /// Cleared-latch: `schedule` awaits `notificationSettings()` before it can `add` while `clear` is synchronous, so each `schedule` records a generation and re-checks it after every await.
    private static var scheduledGeneration: [String: UInt64] = [:]
    private static var generationCounter: UInt64 = 0

    /// What each session is actually blocked on right now, which is not the same as "has a notification up": the foreground sweep clears every banner while the prompts behind them are still pending.
    private static var pending: [String: PromptKind] = [:]

    /// Sessions whose turn waits on a connector sign-in card (`connection.request`). The card is not a blocking prompt (it is a dock row with the backend's own 300 s deadline, not the approval sheet), but it stops the turn on the person all the same. It shares the session's identifier, so a blocking prompt in the same session takes the banner over.
    private static var pendingSignIns: Set<String> = []

    static let signInTitle = "Hermes needs you to sign in"
    static let signInBody = "An app is waiting for you to connect it."

    /// What kind of answer a turn is stopped on; the body names the kind and nothing else — never the command, never the question, never the value.
    enum PromptKind: String, Sendable {
        case approval
        case clarify
        case sudo
        case secret
        case desktop
        /// A connector sign-in card. Never a blocking prompt and never notified through this kind (sign-ins have their own notice); it marks the chat as waiting on Home and in the other-chat banner.
        case signIn

        var title: String {
            switch self {
            case .approval: return "Hermes needs approval"
            case .clarify: return "Hermes has a question"
            case .sudo: return "Hermes needs a password"
            case .secret: return "Hermes needs a value"
            case .desktop: return "Continue in Desktop"
            case .signIn: return "Hermes needs you to sign in"
            }
        }

        var body: String {
            switch self {
            case .approval: return "A command is waiting for your approval."
            case .clarify: return "A question is waiting for your answer."
            case .sudo: return "An administrator password is waiting to be entered."
            case .secret: return "A value is waiting to be entered."
            case .desktop: return "A request needs a Desktop feature. Open the session in Desktop to complete it."
            case .signIn: return "An app is waiting for you to connect it."
            }
        }
    }

    // MARK: - Install

    /// Install the presentation delegate, the tap handler, and the background re-arm; Apple requires the delegate be assigned before the app finishes launching.
    /// Without a delegate iOS suppresses any notification arriving while the process is foreground, and `.inactive` — app switcher, shade, incoming call — is foreground.
    static func install() {
        UNUserNotificationCenter.current().delegate = presenter
        installBackgroundRearm()
    }

    /// The two observer tokens, kept so `install` is idempotent.
    private static var rearmObservers: [NSObjectProtocol] = []

    /// The re-arm: a prompt that arrives while the user is looking at the chat gets no notification, so at the moment the app leaves the screen every prompt still on `pending` is armed.
    private static func installBackgroundRearm() {
        guard rearmObservers.isEmpty else { return }
        let centre = NotificationCenter.default
        // Both, on purpose: `willResignActive` is the app switcher, the shade and an incoming call; `didEnterBackground` is the Home swipe and the lock button.
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification] {
            let token = centre.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in rearmPending() }
            }
            rearmObservers.append(token)
        }
        // A destination asked for while the app was off screen is delivered the moment the user is back to see it happen.
        let active = centre.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in drainQueuedRoute() }
        }
        rearmObservers.append(active)
    }

    /// Whether the user is looking at the app; behind a property because a test host is always `.active`, which is precisely the state in which `sync` posts nothing.
    private static var appIsActive: Bool {
        #if DEBUG
        if let isActiveOverrideForTesting { return isActiveOverrideForTesting }
        #endif
        return UIApplication.shared.applicationState == .active
    }

    private static func rearmPending() {
        for (sessionID, kind) in pending {
            // `willResignActive` and `didEnterBackground` both fire on the way out of the foreground, and re-posting the same identifier would buzz the phone twice for one prompt.
            guard scheduledGeneration[sessionID] == nil else { continue }
            schedule(sessionID: sessionID, kind: kind)
        }
        for sessionID in pendingSignIns where scheduledGeneration[sessionID] == nil {
            scheduleSignIn(sessionID: sessionID)
        }
    }

    // MARK: - Presentation and tap routing

    private final class ForegroundPresenter: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            willPresent notification: UNNotification
        ) async -> UNNotificationPresentationOptions {
            // While the user is looking at the app the in-app sheet is the surface, and a banner on top of it would be a double alert.
            let state = await MainActor.run { UIApplication.shared.applicationState }
            return state == .active ? [] : [.banner, .sound, .list]
        }

        /// BUG-070 C. A tap is reported only here; without this method an app never responds to a notification's action at all.
        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            didReceive response: UNNotificationResponse
        ) async {
            // The default action is the tap itself; dismissal is not a request to go anywhere.
            guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
            let info = response.notification.request.content.userInfo
            guard let sessionID = info[sessionUserInfoKey] as? String,
                  !sessionID.isEmpty
            else { return }
            await MainActor.run { ApprovalNotifications.requestRoute(sessionID: sessionID) }
        }
    }

    /// Where a tapped notification goes, installed by `LiveActivityController` once it has the `AppModel`.
    static var route: (@MainActor (String) -> Void)? {
        didSet { drainQueuedRoute() }
    }

    /// A tap that landed before the router was installed: the delegate is set in `init` and the router in the root view's `.task`, so a cold-launch tap arrives in between.
    private static var queuedRoute: String?

    /// Ask for a chat, delivered now only if the app is on screen, because a navigation the user did not just ask for has to wait until they are there to see it happen.
    /// One queue slot, deliberately: two pending destinations means the second is the one they meant.
    static func requestRoute(sessionID: String) {
        queuedRoute = sessionID
        drainQueuedRoute()
    }

    /// Deliver a queued destination once a router exists and the app is on screen; called from three places, so whichever arrives last does it.
    private static func drainQueuedRoute() {
        guard let waiting = queuedRoute, let route, appIsActive else { return }
        queuedRoute = nil
        route(waiting)
    }

    // MARK: - Authorisation

    /// Ask for permission if the user has never been asked, on connect while the dialog can actually present; a failed attempt leaves the status `.notDetermined`, so the next connect retries.
    static func requestAuthorizationIfNeeded() {
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .notDetermined else { return }
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
    }

    // MARK: - The pending-prompt roster

    /// Reconcile the armed notifications against what every session is actually blocked on, called on every engine flush from `LiveActivityController.reconcile`.
    /// A prompt whose session drops off the roster has been answered, expired or completed, and its banner goes with it.
    static func sync(prompts: [String: PromptKind], signIns: Set<String> = []) {
        // A blocking prompt outranks a sign-in card in the same session.
        let signInsOnly = signIns.subtracting(prompts.keys)
        // `Array` and not `pending.keys`: `clear` mutates the dictionary these keys are a live view of.
        for sessionID in Array(pending.keys) where prompts[sessionID] == nil {
            clear(sessionID: sessionID)
        }
        for sessionID in Array(pendingSignIns) where !signInsOnly.contains(sessionID) {
            if prompts[sessionID] == nil {
                clear(sessionID: sessionID)
            } else {
                // A prompt took the session over: let its `schedule` replace the banner rather than see a live generation and stand down.
                pendingSignIns.remove(sessionID)
                scheduledGeneration[sessionID] = nil
            }
        }
        for (sessionID, kind) in prompts {
            // Recorded whatever the app state is, because a prompt the user is currently looking at still has to follow them when they put the phone down.
            pending[sessionID] = kind
            // Nothing to post while the user is looking at the app.
            guard !appIsActive else { continue }
            schedule(sessionID: sessionID, kind: kind)
        }
        for sessionID in signInsOnly {
            pendingSignIns.insert(sessionID)
            guard !appIsActive else { continue }
            scheduleSignIn(sessionID: sessionID)
        }
    }

    /// Post the pending-prompt notification if permission has been granted; one identifier per session, so a second question in the same chat replaces the banner rather than stacking.
    static func schedule(sessionID: String, kind: PromptKind = .approval) {
        // The idempotence lives here, not in the callers: there are four call sites, and re-adding a request whose identifier is already delivered re-alerts.
        // A different kind for the same session is news, and so is the same kind with no live generation, which is the state the foreground sweep leaves behind.
        if pending[sessionID] == kind, scheduledGeneration[sessionID] != nil { return }
        pending[sessionID] = kind
        pendingSignIns.remove(sessionID)
        // A new question supersedes any "that request is no longer waiting" notice still sitting in the tray for this chat.
        clearRefusal(sessionID: sessionID)
        #if DEBUG
        armedForTesting.append(Armed(sessionID: sessionID, kind: kind))
        #endif
        post(sessionID: sessionID, title: kind.title, body: kind.body)
    }

    /// Post the sign-in notification for a session whose turn waits on a connector card; idempotent like `schedule`.
    static func scheduleSignIn(sessionID: String) {
        // A live generation with no prompt on the roster is this session's sign-in banner.
        if pending[sessionID] == nil, pendingSignIns.contains(sessionID), scheduledGeneration[sessionID] != nil { return }
        pendingSignIns.insert(sessionID)
        clearRefusal(sessionID: sessionID)
        #if DEBUG
        armedForTesting.append(Armed(sessionID: sessionID, kind: nil))
        #endif
        post(sessionID: sessionID, title: signInTitle, body: signInBody)
    }

    private static func post(sessionID: String, title: String, body: String) {
        generationCounter += 1
        let generation = generationCounter
        scheduledGeneration[sessionID] = generation
        let identifier = pendingPrefix + sessionID
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional else { return }
            // The prompt may have been answered while the settings fetch was in flight.
            guard scheduledGeneration[sessionID] == generation else { return }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            // BUG-070 C. The whole payload: which chat is blocked, and no command, question text or value.
            content.userInfo = [sessionUserInfoKey: sessionID]

            let request = UNNotificationRequest(
                identifier: identifier,
                content: content,
                trigger: nil
            )
            try? await center.add(request)
            if scheduledGeneration[sessionID] != generation {
                // A clear raced the add and lost; finish its job.
                center.removePendingNotificationRequests(withIdentifiers: [identifier])
                center.removeDeliveredNotifications(withIdentifiers: [identifier])
            }
        }
    }

    /// BUG-070 B — what to say when a card's button could not be answered; two notices, because "the queue was consulted and is empty" and "nothing was read at all" are different things to know.
    enum RefusalNotice {
        /// The queue was read. There is nothing at its head to answer.
        case requestGone
        /// The app never finished launching, so nothing was read.
        case appNotReady

        var title: String {
            switch self {
            case .requestGone: return "That request is no longer waiting"
            case .appNotReady: return "Hermes could not open in time"
            }
        }

        var body: String {
            switch self {
            case .requestGone:
                return "Nothing was sent. Open Hermes to see where the conversation got to."
            case .appNotReady:
                return "Nothing was sent, and the request may still be waiting. Open Hermes to answer it."
            }
        }
    }

    /// BUG-070 B. A button on a card whose press could not be answered; Deny does not foreground the app, so without this a silent return is indistinguishable from a button that worked.
    static func scheduleRefusal(sessionID: String, notice: RefusalNotice) {
        let identifier = refusalPrefix + sessionID
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = notice.title
            content.body = notice.body
            content.sound = .default
            content.userInfo = [sessionUserInfoKey: sessionID]
            try? await center.add(
                UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            )
        }
        #if DEBUG
        refusalsForTesting.append(Refused(sessionID: sessionID, notice: notice))
        #endif
    }

    /// The refusal notice is a record of a completed non-event, not a stale prompt, so the foreground sweep leaves it alone and only a new question for the same chat supersedes it.
    private static func clearRefusal(sessionID: String) {
        let center = UNUserNotificationCenter.current()
        let ids = [refusalPrefix + sessionID]
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }
    /// Remove one session's notification once its prompt is answered or its turn completes; other sessions' pending prompts stay up.
    static func clear(sessionID: String) {
        scheduledGeneration[sessionID] = nil
        pending[sessionID] = nil
        pendingSignIns.remove(sessionID)
        let center = UNUserNotificationCenter.current()
        let ids = [pendingPrefix + sessionID]
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    /// Remove every pending-prompt notification, used when the app returns to the foreground and they are all stale.
    /// `pending` and the refusal family deliberately survive: the banners are stale but the prompts behind them are not, and a refusal notice is the only trace a dead-card Deny leaves.
    static func clearAll() {
        scheduledGeneration.removeAll()
        Task {
            let center = UNUserNotificationCenter.current()
            let mine: (String) -> Bool = { $0.hasPrefix(pendingPrefix) }
            let pendingIDs = await center.pendingNotificationRequests()
                .map(\.identifier)
                .filter(mine)
            if !pendingIDs.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: pendingIDs)
            }
            let delivered = await center.deliveredNotifications()
                .map(\.request.identifier)
                .filter(mine)
            if !delivered.isEmpty {
                center.removeDeliveredNotifications(withIdentifiers: delivered)
            }
        }
    }

    // MARK: - Test seams

    #if DEBUG
    struct Armed: Equatable {
        let sessionID: String
        /// Nil for a connector sign-in.
        let kind: PromptKind?
    }

    struct Refused: Equatable {
        let sessionID: String
        let notice: RefusalNotice
    }

    /// Stand in for the app being off screen, since a test host is always `.active` and that is the one state in which `sync` posts nothing.
    static var isActiveOverrideForTesting: Bool?

    /// Every refusal notice, in order, so a test can tell the two apart without reading `UNUserNotificationCenter`.
    private(set) static var refusalsForTesting: [Refused] = []

    /// Every `schedule` call, in order — the only way to tell "the roster knows" apart from "a notification was armed", since authorisation is never granted in a test host.
    private(set) static var armedForTesting: [Armed] = []

    /// What the roster believes is blocked, for a test that cannot read `UNUserNotificationCenter`.
    static var pendingPromptsForTesting: [String: PromptKind] { pending }

    static var pendingSignInsForTesting: Set<String> { pendingSignIns }

    /// Drive the delegate's tap path without a real `UNNotificationResponse`, which cannot be constructed outside the system.
    static func simulateTapForTesting(sessionID: String) {
        requestRoute(sessionID: sessionID)
    }

    /// Deliberately does not clear `route`: this target is hosted in the real app, so nulling it here would leave the app's own controller unrouted for every suite that runs afterwards.
    static func resetForTesting() {
        armedForTesting.removeAll()
        refusalsForTesting.removeAll()
        isActiveOverrideForTesting = nil
        pending.removeAll()
        pendingSignIns.removeAll()
        scheduledGeneration.removeAll()
        queuedRoute = nil
    }
    #endif
}
