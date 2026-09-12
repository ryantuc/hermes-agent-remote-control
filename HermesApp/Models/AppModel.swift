import Foundation
import HermesServeKit
import Observation
import SwiftUI

/// Root observable: owns the backend profiles, the one live gateway connection, the shared turn engine, the thread list, and the per-thread chat models.
@MainActor
@Observable
final class AppModel {
    // MARK: Profiles

    // `@Observable` rewrites tracked stored properties into computed ones, so a stored property here cannot carry a `didSet` — the persistence side effect lives in the setter instead.
    private var storedProfiles: [BackendProfile]

    var profiles: [BackendProfile] {
        get { storedProfiles }
        set {
            storedProfiles = newValue
            BackendProfileStore.save(newValue)
        }
    }

    private var storedActiveProfileID: UUID?

    private(set) var activeProfileID: UUID? {
        get { storedActiveProfileID }
        set {
            storedActiveProfileID = newValue
            BackendProfileStore.saveActiveID(newValue)
        }
    }

    var activeProfile: BackendProfile? {
        guard let activeProfileID = activeProfileID else { return nil }
        return profiles.first { $0.id == activeProfileID }
    }

    /// The active profile when there is one the app can actually open, nil otherwise; one predicate answers "is there a backend" for the launch route, the first-run screen and the sign-out routing alike (FEAT-030).
    var signedInProfile: BackendProfile? {
        guard let profile = activeProfile, profile.isSignedIn else { return nil }
        return profile
    }

    /// Drop an `activeProfileID` that resolves to nothing, adopting the first remaining profile if there is one; the id is persisted separately from the list, so a dangling one survives a relaunch.
    func reconcileActiveProfile() {
        guard activeProfileID != nil, activeProfile == nil else { return }
        activeProfileID = profiles.first?.id
    }

    // MARK: First run — no backend configured

    /// The one sentence this app leads with when it has nothing to talk to, said on two screens and therefore held in one place.
    static let backendExplainer =
        "Hermes runs on your own computer or server. HARC connects directly to it and adds no service of its own — your backend decides which AI providers and tools see your requests."

    /// One sentence, said on both screens that offer the demo, for the same reason `backendExplainer` is one string.
    static let demoInvitation =
        "No backend yet? The demo replays a short canned conversation — real screens, scripted content, no connection."

    /// No backend the app can open, which is deliberately not "not connected" — an unreachable backend is the connection banner's problem and has a Retry that can succeed.
    var needsBackend: Bool { signedInProfile == nil && demo == nil }

    /// Why the send is dead, said where the dead control is; nil the moment a backend exists, because every other reason is already narrated by the banner and the placeholder.
    var noBackendSendReason: String? {
        needsBackend ? "Send needs a backend — connect one to start." : nil
    }

    /// Mirror of the scene phase, published from `RootView`; a backgrounded-approval notification is only worth firing when the app is not on screen.
    var scenePhase: ScenePhase = .active

    /// A navigation request from somewhere that does not own the path; RootView applies it and clears it.
    var requestedRoute: [AppRoute]?

    func requestRoute(_ route: [AppRoute]) {
        requestedRoute = route
    }

    // MARK: Connection

    private(set) var connectionState: GatewayConnectionState = .idle
    private(set) var serverStatus: ServerStatus?
    /// `terminal.cwd` — the working directory a new conversation starts in, read once per connect.
    private(set) var defaultCwd: String = ""
    /// The backend's global default model and effort, read once per connect; a draft conversation's pill shows these until the user overrides them.
    private(set) var defaultModel: String = ""
    private(set) var defaultEffort: String = ""
    private(set) var identity: AuthIdentity?
    private(set) var connectionError: String?
    /// Set when the backend reports a contract older than this client needs (BUG-111).
    var contractWarning: String? { contractNotice.message }

    /// The notice's own memory of what has been raised and what has been waved away.
    private var contractNotice = ContractNotice()

    /// The reader dismissed the contract notice; it does not come back for the same backend, and it does come back if the answer changes.
    func dismissContractWarning() {
        contractNotice.dismiss()
    }

    let log = ConnectionLog()
    let engine = TurnEngine()

    /// The Lock Screen / Dynamic Island roster; `@ObservationIgnored` because no view reads it through this reference, and a `var` because the app test target substitutes a fake.
    @ObservationIgnored var liveActivities: LiveActivityController = .shared

    private(set) var auth: AuthenticationClient?
    private(set) var rest: RestAPI?
    private(set) var client: HermesClient?
    private(set) var sessionAPI: SessionAPI?
    private(set) var promptAPI: PromptAPI?
    private(set) var approvalAPI: ApprovalAPI?
    private(set) var attachmentAPI: AttachmentAPI?
    private(set) var configAPI: ConfigAPI?
    private(set) var projectsAPI: ProjectsAPI?
    /// `profiles.list` / `profiles.get_asset` — the Bots roster's only backend surface.
    private(set) var profilesAPI: ProfilesAPI?
    private(set) var gitAPI: GitAPI?
    private(set) var audioAPI: AudioAPI?

    /// The design-system theme, attached at launch by `HermesMobileApp`; AppModel maps backend skin seeds into it.
    private var storedTheme: Theme?
    var theme: Theme? {
        get { storedTheme }
        set {
            storedTheme = newValue
            replayBackendSkin()
        }
    }

    /// The most recent backend skin snapshot, kept so it can be replayed onto a theme attached after it arrived.
    private var lastBackendSkin: BackendSkinSnapshot?

    /// The desktop refuses to drive a backend below its required contract version (jsonrpc-methods §6.1); this client warns instead of refusing.
    static let minimumDesktopContract = 4

    // MARK: Threads

    private(set) var threads: [SessionSummary] = []
    private(set) var isLoadingThreads = false
    private(set) var threadsError: String?
    /// Durable session ids the gateway reports as genuinely running, not the wire `is_active`, which is a recency heuristic that never clears on normal turn completion (BUG-001).
    private(set) var liveActiveIDs: Set<String> = []
    /// The whole `session.active_list` row per durable id; kept separate from `liveActiveIDs` because `lastActive` and `preview` move on every poll and would invalidate the hub list each pass.
    private(set) var liveStatuses: [String: LiveSessionStatus] = [:]
    var searchText: String = ""

    var filteredThreads: [SessionSummary] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return hubSessions }
        return hubSessions.filter {
            $0.displayTitle.lowercased().contains(query)
                || $0.preview.lowercased().contains(query)
                || $0.model.lowercased().contains(query)
        }
    }

    /// The honest "is an agent running right now" answer for a history row (BUG-001).
    func isLiveWorking(_ sessionID: String) -> Bool {
        liveActiveIDs.contains(sessionID)
    }

    /// The word the hub prints for a live row — `waiting`, `starting` or `working`, never hardcoded.
    func liveWorkingLabel(for sessionID: String) -> String {
        liveStatus(forStoredID: sessionID)?.status ?? "working"
    }

    /// Home's live dot: liveness is `session.active_list`, not the `minMessages: 1` thread list (BUG-028).
    var hasVisibleLiveSession: Bool {
        !liveActiveIDs.isEmpty
    }

    /// Home's Continue strip: live working sessions first, including ones the REST list has not persisted yet, then the most recent thread.
    func continueRows() -> [SessionSummary] {
        var rows: [SessionSummary] = []
        let liveOnly = liveStatuses.values
            .filter(\.isWorking)
            .map(SessionSummary.init(fromLive:))
            .filter { live in !threads.contains(where: { $0.id == live.id }) }
            .filter { !isBotPlumbing($0) }
        if let running = liveOnly.first ?? threads.first(where: { isLiveWorking($0.id) }) {
            rows.append(running)
        }
        if let recent = threads.first(where: { thread in !rows.contains(where: { $0.id == thread.id }) }) {
            rows.append(recent)
        }
        return rows
    }

    /// The hub drawer list: persisted threads plus working sessions the REST `minMessages: 1` query has not persisted yet.
    var hubSessions: [SessionSummary] {
        let extras = liveStatuses.values
            .filter(\.isWorking)
            .map(SessionSummary.init(fromLive:))
            .filter { live in !threads.contains(where: { $0.id == live.id }) }
            .filter { !isBotPlumbing($0) }
        return extras + threads
    }

    /// A synthesised live row that belongs to a bot's forever-chat rather than to Sessions mode: `session.active_list` applies no hidden filter, so a running Bot Chat arrives here even though the REST list cannot leak one.
    ///
    /// Two keys, because each covers what the other cannot: the pin catches a chat this phone resolved after compression moved the title, and the title catches a chat another client minted.
    func isBotPlumbing(_ session: SessionSummary) -> Bool {
        if session.title == BotsModel.canonicalChatTitle { return true }
        return bots.store.pins(backend: activeProfileID).values.contains(session.id)
    }

    /// The gateway's live row for a durable session id; optional because every caller holds `ChatModel.storedSessionID`, which is nil until the first prompt writes the DB row.
    func liveStatus(forStoredID id: String?) -> LiveSessionStatus? {
        guard let id, !id.isEmpty else { return nil }
        return liveStatuses[id]
    }

    /// The Home resume row's step fraction (FEAT-012), routed through the same `StripProgress.todos` formatter the activity strip wears rather than recomputed.
    ///
    /// Two id spaces, and the join is the whole of this method: Home's rows are keyed by the durable id, the engine's roster by the gateway's in-memory id, and `session.active_list` is the only place both appear on one row.
    func liveStepFraction(for sessionID: String) -> String? {
        guard let runtimeID = liveStatus(forStoredID: sessionID)?.id, !runtimeID.isEmpty else { return nil }
        let todos = engine.state(for: runtimeID).activity.todos
        guard !todos.isEmpty else { return nil }
        return StripProgress.todos(todos)
    }

    // MARK: Private

    private var chats: [String: ChatModel] = [:]
    private var eventPump: Task<Void, Never>?
    private var statePump: Task<Void, Never>?
    private var flushLoop: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var threadRefreshTask: Task<Void, Never>?
    private var lastThreadRefresh = Date.distantPast
    private var transcriptRefreshTask: Task<Void, Never>?
    private var lastTranscriptRefresh = Date.distantPast
    private var changeEventsSupported = false
    /// `gateway.ready.session_mirroring`: this backend fans a session's events out to every connected client and accepts `session.resume(watch:)`.
    private(set) var sessionMirroring = false
    /// Single-flight for `resumeOpenThreads`: three callers fire it around the same socket-open, and each would re-read `runtimeBoundAt` before the first's await updates it.
    private var resumeOpenThreadsTask: Task<Void, Never>?

    /// The once-per-socket-open ceremony (BUG-024); cancel-and-replace, because a newly opened socket supersedes a pass whose remaining RPCs are aimed at a dead one.
    private var postOpenTask: Task<Void, Never>?

    /// `sessions.changed` demotes polling to a backstop, it does not replace it (reference §4.2).
    private var pollInterval: TimeInterval { changeEventsSupported ? 30 : 10 }
    /// Trailing-edge throttle on `sessions.changed` bursts.
    private static let refreshThrottle: TimeInterval = 10
    /// The same, for the open conversation's transcript; shorter because it repaints what the user is looking at, and still a throttle because `sessions.changed` fires on any cross-process session write on the host.
    private static let transcriptRefreshThrottle: TimeInterval = 5

    /// BUG-004 — how many engine-tracked sessions may accumulate before a non-terminal event forces an eviction sweep, for sessions that never hand the sweep a terminal frame.
    static let engineRosterHighWater = 24
    /// The valve's own throttle, so a roster that sits above the mark because its sessions are genuinely live does not pay an O(roster) sweep per event.
    private static let highWaterSweepInterval: TimeInterval = 5
    private var lastHighWaterSweep = Date.distantPast

    /// The settings tree's document store; one instance for the whole app so root-row summaries and detail screens share a load.
    private(set) var settings: SettingsStore!

    /// The Bots roster and the pins that name each bot's forever-chat; the pins outlive any screen, and `ChatModel`'s resolver reads them from a path that has no view at all.
    private(set) var bots: BotsModel!

    /// How the one gateway client is built: the client is constructed inside `activate(profileID:connect:)`, so without this seam a test could never give an `AppModel` a fake backend.
    typealias GatewayClientFactory = (AuthenticationClient, RestAPI, ConnectionLog) -> HermesClient

    private let makeClient: GatewayClientFactory

    init(
        clientFactory: @escaping GatewayClientFactory = { auth, rest, log in
            HermesClient(auth: auth, rest: rest, log: log)
        }
    ) {
        makeClient = clientFactory
        // Assign the backing storage directly: writing through the setters here would immediately persist what was just loaded.
        storedProfiles = BackendProfileStore.load()
        storedActiveProfileID = BackendProfileStore.loadActiveID()
        // BUG-119: a signed-out profile must not be adopted here, because sign-out clears the active id precisely so the next launch lands on first-run Home.
        if storedActiveProfileID == nil {
            storedActiveProfileID = storedProfiles.first(where: { $0.isSignedIn })?.id
        }
        settings = SettingsStore(app: self)
        bots = BotsModel(app: self)
    }

    // MARK: - Profile lifecycle

    func addProfile(_ profile: BackendProfile) {
        profiles.append(profile)
        // `activeProfile == nil` rather than `activeProfileID == nil`: a persisted id that no longer resolves to a row would otherwise swallow the first backend a user adds.
        if activeProfile == nil { activeProfileID = profile.id }
    }

    /// Whether an edit to the active profile is worth rebuilding the connection for, which costs every open chat and every unsent draft.
    ///
    /// Do not simplify this into a field-by-field comparison: `BackendConfiguration` is exactly what the connection is built from, so its exhaustiveness is the safety property.
    ///
    /// `credentialsChanged` cannot be inferred from either profile — secrets are Keychain items keyed by profile id, so a token edit leaves both rows byte-identical.
    static func requiresReconnect(
        from previous: BackendProfile,
        to updated: BackendProfile,
        credentialsChanged: Bool
    ) -> Bool {
        if credentialsChanged { return true }
        // An unusable new address still goes through `activate`, which is what surfaces the message to the user.
        guard let new = try? updated.makeConfiguration() else { return true }
        return new != (try? previous.makeConfiguration())
    }

    func update(_ profile: BackendProfile, credentialsChanged: Bool = false) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        let previous = profiles[index]
        // Unconditional: the edit is persisted whether or not it is worth a reconnect.
        profiles[index] = profile
        guard profile.id == activeProfileID else { return }
        guard Self.requiresReconnect(from: previous, to: profile, credentialsChanged: credentialsChanged)
        else { return }
        // Computed here because `profiles[index]` has already been overwritten above, so `activate` can no longer see the old value.
        let sameSessionNamespace = previous.hermesProfile == profile.hermesProfile
        Task {
            await activate(
                profileID: profile.id,
                connect: true,
                preservingConversations: sameSessionNamespace
            )
        }
    }

    func deleteProfile(id: UUID) {
        let removed = profiles.first { $0.id == id }
        profiles.removeAll { $0.id == id }
        // Keychain slots are namespaced by profile id, so dropping the row alone would orphan them past any reach.
        AuthenticationClient.clearSecrets(profileID: id.uuidString)
        // Cookies are per-host, so this also signs out any other profile on the same host — the safe default when deleting that host's credentials.
        if let removed, let configuration = try? removed.makeConfiguration() {
            AuthenticationClient.clearCookies(for: configuration.baseURL)
        }
        if activeProfileID == id {
            // Only a profile that can actually be opened is worth adopting: stepping onto a signed-out row would connect to a backend the user had signed out of.
            activeProfileID = profiles.first(where: { $0.isSignedIn })?.id
            Task {
                await teardown()
                // The live client may have re-written a secret between the wipe above and the teardown; wipe again now that nothing can write to this namespace.
                AuthenticationClient.clearSecrets(profileID: id.uuidString)
                if let next = activeProfileID {
                    await activate(profileID: next, connect: true)
                } else {
                    // Nothing signed in remains — same landing as sign-out, rather than a Backend screen listing backends none of which is connected.
                    requestRoute([])
                }
            }
        }
    }

    /// Point the app at one backend and optionally open the socket; `preservingConversations` is the caller's assertion that the open chats belong to the backend being activated.
    func activate(
        profileID: UUID,
        connect: Bool,
        preservingConversations: Bool = false
    ) async {
        guard let profile = profiles.first(where: { $0.id == profileID }),
              let configuration = try? profile.makeConfiguration()
        else {
            connectionError = "That backend's address is not usable."
            return
        }
        // Preserving across a switch to a different profile row would resume this backend's session ids against another machine's state.db.
        let keep = preservingConversations && profileID == activeProfileID
        await teardown(discardingConversations: !keep)
        activeProfileID = profileID

        let auth = AuthenticationClient(
            configuration: configuration,
            profileID: profileID.uuidString,
            log: log
        )
        let rest = RestAPI(auth: auth)
        let client = makeClient(auth, rest, log)

        self.auth = auth
        self.rest = rest
        self.client = client
        sessionAPI = SessionAPI(client: client)
        promptAPI = PromptAPI(client: client)
        approvalAPI = ApprovalAPI(client: client)
        attachmentAPI = AttachmentAPI(client: client)
        configAPI = ConfigAPI(client: client)
        projectsAPI = ProjectsAPI(client: client)
        profilesAPI = ProfilesAPI(client: client)
        gitAPI = GitAPI(rest: rest)
        audioAPI = AudioAPI(rest: rest)

        startPumps(client: client)
        if connect { await self.connect() }
    }

    func connect() async {
        guard let client = client else { return }
        connectionError = nil
        do {
            try await client.connect()
            // Ask here, not on the first approval: approvals that warrant a notification arrive while the app is off screen, where iOS will not present the dialog at all.
            #if DEBUG
            // The seeded validation harness must not park a system permission alert over every screenshot.
            if !ProcessInfo.processInfo.arguments.contains("-hermesSeedBackend") {
                ApprovalNotifications.requestAuthorizationIfNeeded()
            }
            #else
            ApprovalNotifications.requestAuthorizationIfNeeded()
            #endif
            // The rest of the ceremony runs from the `.open` transition (BUG-024); only the permission request belongs to an explicit connect, because it presents a system dialog.
        } catch {
            connectionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func disconnect() async {
        await client?.disconnect()
        pollTask?.cancel()
        pollTask = nil
    }

    /// - Parameter discardingConversations: true for a genuine backend switch or a profile delete, false when the connection to the same backend is merely rebuilt, where discarding would throw away a running turn or a typed draft (BUG-025).
    private func teardown(discardingConversations: Bool = true) async {
        eventPump?.cancel(); eventPump = nil
        statePump?.cancel(); statePump = nil
        flushLoop?.cancel(); flushLoop = nil
        pollTask?.cancel(); pollTask = nil
        threadRefreshTask?.cancel(); threadRefreshTask = nil
        transcriptRefreshTask?.cancel(); transcriptRefreshTask = nil
        resumeOpenThreadsTask?.cancel(); resumeOpenThreadsTask = nil
        postOpenTask?.cancel(); postOpenTask = nil
        await client?.disconnect()
        // Cookies are the one credential outside the Keychain, and a torn-down backend must not leave a live session behind.
        if let auth {
            AuthenticationClient.clearCookies(for: await auth.configuration.baseURL)
        }
        client = nil
        auth = nil
        rest = nil
        sessionAPI = nil
        promptAPI = nil
        approvalAPI = nil
        attachmentAPI = nil
        configAPI = nil
        projectsAPI = nil
        profilesAPI = nil
        gitAPI = nil
        audioAPI = nil
        if discardingConversations {
            chats.removeAll()
            // Rows belonging to a backend this app is no longer on (BUG-052).
            branchSeeds.removeAll()
            // `threads` rides with `chats` deliberately: on a same-backend rebuild the list is still accurate.
            threads.removeAll()
            // BUG-069: end the cards before forgetting the sessions, or an old backend's Lock Screen card relabels itself with the new backend's name on the next push.
            liveActivities.endAll(reason: "left this backend")
            for sessionID in engine.trackedSessionIDs {
                engine.forget(sessionID: sessionID)
                liveActivities.sessionEvicted(sessionID: sessionID)
            }
        }
        // BUG-069: cleared on every teardown, rebuild included, or the next backend inherits the previous one's "working" ids until its first successful `active_list`.
        liveActiveIDs = []
        liveStatuses = [:]
        // Both are answers the gateway gave on a socket that is now closed, and a stale `changeEventsSupported` would poll the next backend at the wrong interval.
        changeEventsSupported = false
        sessionMirroring = false
        serverStatus = nil
        identity = nil
        connectionState = .idle
    }

    // MARK: - Sign out

    /// Revoke and erase the active backend's credential, tear the connection down completely, mark the profile signed out keeping its address and name, and drop it from `activeProfileID` so the app returns to first-run Home (BUG-119).
    func signOut() async {
        guard let profileID = activeProfileID else { return }
        // Before the teardown, while `auth` still exists.
        await auth?.logout()
        await teardown()
        // A 401 can provoke a silent re-login between the wipe and the teardown, so wipe again now that nothing holds a writer for this namespace.
        AuthenticationClient.clearSecrets(profileID: profileID.uuidString)
        if let index = profiles.firstIndex(where: { $0.id == profileID }) {
            var profile = profiles[index]
            profile.signedOut = true
            // The version was read from a connection and a credential that no longer exist.
            profile.lastConnected = nil
            profiles[index] = profile
            if let configuration = try? profile.makeConfiguration() {
                AuthenticationClient.clearCookies(for: configuration.baseURL)
            }
        }
        activeProfileID = nil
        // Nothing signed in remains, so the honest landing is the screen that offers to connect one.
        requestRoute([])
    }

    // MARK: - Demo mode

    /// The canned backend, or nil when the app is doing the real thing; this is the whole of "is the demo on".
    private(set) var demo: DemoBackend?
    /// Plays the two scripted turns once the socket is open.
    private var demoDriver: Task<Void, Never>?

    /// One navigation identity for the life of the process, so the demo never stacks a second one; the conversation under it is fresh on every entry (BUG-104).
    private let demoRoute = ThreadRoute.new(UUID())
    /// See `enterDemo(playbackSpeed:)`.
    private var demoPlaybackSpeed: Double = 1

    /// The profile the demo is standing in front of, parked in memory only so a process killed mid-demo comes back to the real backend (BUG-118).
    private(set) var parkedProfileID: UUID?
    /// The real backend's history rows, held while the demo shows its own.
    private var parkedThreads: [SessionSummary] = []

    var isDemoActive: Bool { demo != nil }

    /// What the surfaces that name the backend should say; computed in one place so no surface can draw the real backend's name over a demo that is not connected to it.
    var backendDisplayName: String? {
        if isDemoActive { return "Demo" }
        guard let name = activeProfile?.displayName, !name.isEmpty else { return nil }
        return name
    }

    /// Where a "Try the demo" tap lands.
    var demoThreadRoute: ThreadRoute { demoRoute }

    /// Enter the demo. Nothing here is persisted, and `auth` and `rest` stay nil, which is what makes "the demo needs no network" structural rather than a promise.
    /// - Parameter playbackSpeed: divides every pause in the script and in the autoplay's own waits, changing only the gaps and never what is replayed.
    /// - Parameter autoplay: false is for a test measuring one turn, since Stop cannot be measured while a driver queues the next question behind it.
    func enterDemo(playbackSpeed: Double = 1, autoplay: Bool = true) async {
        guard demo == nil else { return }
        // BUG-101: park, do not discard — the demo is a parenthesis, not a backend switch, and a bare teardown would wipe a running turn and a typed draft.
        parkedProfileID = activeProfileID
        parkedThreads = threads
        await teardown(discardingConversations: false)
        // In memory only, and clearing it is what makes the two states exclusive: while the demo runs there is no active profile for any surface to draw.
        storedActiveProfileID = nil
        let speed = max(1, playbackSpeed)
        demoPlaybackSpeed = speed
        let backend = DemoBackend(playbackSpeed: speed)
        demo = backend
        let client = HermesClient(
            dialer: backend.dialer(),
            log: log,
            transportFactory: backend.transportFactory()
        )
        self.client = client
        sessionAPI = SessionAPI(client: client)
        promptAPI = PromptAPI(client: client)
        approvalAPI = ApprovalAPI(client: client)
        attachmentAPI = AttachmentAPI(client: client)
        configAPI = ConfigAPI(client: client)
        projectsAPI = ProjectsAPI(client: client)
        profilesAPI = ProfilesAPI(client: client)
        startPumps(client: client)
        // The hub's history list is REST-fed and REST is nil here, so `refreshThreads` is inert and these rows survive the post-open sweep.
        threads = DemoScript.historyRows()
        connectionError = nil
        // Dialed here rather than through `connect()`: the shared one asks for notification permission, and a system alert over the demo's first screen is what a reviewer would see.
        do {
            try await client.connect()
        } catch {
            connectionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        requestRoute([.thread(demoRoute)])
        guard autoplay else { return }
        demoDriver = Task { [weak self] in await self?.playDemo() }
    }

    /// Leave the demo and put back whatever it was standing in front of, re-activating the parked profile through the same path `bootstrap` uses (BUG-118).
    func exitDemo() async {
        guard let backend = demo else { return }
        demoDriver?.cancel()
        demoDriver = nil
        await backend.shutdown()
        demo = nil
        // The demo's own conversation goes, and only it: `teardown` is asked to preserve, so the real backend's chats survive the exit as they survived the entry.
        releaseDemoChat()
        await teardown(discardingConversations: false)
        threads = parkedThreads
        parkedThreads = []
        connectionError = nil
        guard let parked = parkedProfileID, profiles.contains(where: { $0.id == parked }) else {
            parkedProfileID = nil
            // Nothing to go back to, so the honest landing is the screen that offers to connect a backend.
            requestRoute([])
            return
        }
        parkedProfileID = nil
        // Restored before `activate`, not by it: `activate` only honours `preservingConversations` when the id it is given is already the active one.
        storedActiveProfileID = parked
        requestRoute([])
        await activate(profileID: parked, connect: true, preservingConversations: true)
    }

    /// Drop the demo's `ChatModel` and the engine state behind it; `releaseChats` cannot, and leaving it behind would hand the next entry a half-played script under the same route key (BUG-104).
    private func releaseDemoChat() {
        let key = demoRoute.key
        if let chat = chats.removeValue(forKey: key), let runtimeID = chat.runtimeSessionID {
            engine.forget(sessionID: runtimeID)
            liveActivities.sessionEvicted(sessionID: runtimeID)
        }
        // The demo also binds its chat under `existing:<stored id>` once the first prompt lands, and a key left pointing at a released model is a route nobody can refresh.
        let demoStoredKey = ThreadRoute.Key.existing(DemoBackend.storedSessionID).rawValue
        chats.removeValue(forKey: demoStoredKey)
        engine.forget(sessionID: DemoBackend.runtimeSessionID)
    }

    /// The two scripted turns, sent through the real composer path — deliberately `sendTapped()` rather than a hand-built transcript, because the send contract is what the demo is meant to show.
    private func playDemo() async {
        guard let backend = demo else { return }
        let chat = chat(for: demoRoute)
        await chat.openIfNeeded()
        for index in 0..<DemoScript.autoplayTurnCount {
            guard !Task.isCancelled, demo != nil else { return }
            // A beat before the first prompt so the reviewer sees the empty conversation, and a longer one between turns so the first answer can be read.
            let pause = (index == 0 ? 0.8 : 2.4) / demoPlaybackSpeed
            try? await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000))
            guard !Task.isCancelled, demo != nil else { return }
            let turn = DemoScript.autoplayTurn(index)
            chat.draft = turn.prompt
            chat.sendTapped()
            // BUG-103: the wait is on THIS turn finishing, not a process-wide count a reviewer's own message would satisfy early.
            await backend.waitForPrompt(turn.prompt)
        }
    }

    #if DEBUG
    /// The profile a seeded run creates, derived from that run's launch arguments; pure and static so what the harness writes can be asserted without launching the app.
    ///
    /// BUG-055: the harness does not name the profile, because `displayName` prefers `name` over the host and a harness label would become the backend's name on five surfaces.
    static func seedProfile(from arguments: [String]) -> BackendProfile? {
        guard let urlIndex = arguments.firstIndex(of: "-hermesSeedBackend"),
              urlIndex + 1 < arguments.count else { return nil }
        let urlString = arguments[urlIndex + 1]

        func argument(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        let username = argument("-hermesSeedUsername")

        return BackendProfile(
            name: argument("-hermesSeedName") ?? "",
            baseURLString: urlString,
            authMode: username == nil ? .sessionToken : .password,
            providerName: username == nil ? "" : (argument("-hermesSeedProvider") ?? "basic"),
            username: username ?? ""
        )
    }

    /// Connected-state validation harness: `-hermesSeedBackend <url> -hermesSeedToken <token>` creates or reuses a session-token profile pointing at a live gateway, so simulator runs need no hand-typed credentials.
    func applySeedArgumentsIfPresent() async -> UUID? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let seeded = Self.seedProfile(from: arguments) else { return nil }
        let urlString = seeded.baseURLString

        func argument(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }

        let profile: BackendProfile
        if let existing = profiles.first(where: { $0.baseURLString == urlString }) {
            profile = existing
        } else {
            profiles.append(seeded)
            profile = seeded
        }
        if let configuration = try? profile.makeConfiguration() {
            let auth = AuthenticationClient(
                configuration: configuration,
                profileID: profile.id.uuidString,
                log: log
            )
            if let token = argument("-hermesSeedToken") {
                try? await auth.setSecret(token, kind: .sessionToken)
            }
            if let password = argument("-hermesSeedPassword") {
                try? await auth.setSecret(password, kind: .password)
            }
        }
        activeProfileID = profile.id
        return profile.id
    }
    #endif

    private func loadIdentity() async {
        guard let auth = auth, let serverStatus = serverStatus, serverStatus.authRequired else {
            identity = nil
            return
        }
        identity = try? await auth.identity()
    }

    // MARK: - Pumps

    private func startPumps(client: HermesClient) {
        statePump = Task { [weak self] in
            for await state in client.states() {
                guard let self else { return }
                self.apply(connectionState: state)
            }
        }
        eventPump = Task { [weak self] in
            for await event in client.events() {
                guard let self else { return }
                self.handle(event: event)
            }
        }
        startFlushLoop()
    }

    /// When the current socket opened; a chat that bound its runtime id after this moment must not be re-resumed, because a redundant `session.resume` rebuilds a mid-turn agent and drops its model override.
    private(set) var socketOpenedAt = Date.distantPast

    private func apply(connectionState state: GatewayConnectionState) {
        let wasOpen = connectionState.isOpen
        connectionState = state
        switch state {
        case .open:
            connectionError = nil
            if !wasOpen {
                socketOpenedAt = Date()
                // The stamp above must stay ABOVE this spawn: `SettingsStore.loadIfNeeded()` keys its once-per-connection guard on it.
                postOpenTask?.cancel()
                postOpenTask = Task { [weak self] in
                    await self?.performPostOpenWork()
                }
            }
        case .unauthorized(let reason):
            connectionError = reason
        case .offline(let reason):
            connectionError = reason
        case .idle, .connecting, .reconnecting:
            break
        }
    }

    /// Everything that has to happen once per open socket, driven by the `.open` transition and nowhere else so every reconnect, wake and backoff success gets it (BUG-024, reference §7.2 step 5).
    ///
    /// Calling this from `connect()` as well is a trap: `socketOpenedAt` is stamped on the state pump's task, so a second pass can read a stale stamp and re-resume every chat the first pass bound.
    ///
    /// Two parts of the order are load-bearing: the caller stamps `socketOpenedAt` before this is spawned, and `publishAll()` sits after `settings.loadIfNeeded()` as the SEC-006 re-arm.
    private func performPostOpenWork() async {
        guard let client else { return }
        serverStatus = await client.serverStatus
        // Also carried by `gateway.ready` through the event pump; read here as well so the values do not depend on which pump wins.
        changeEventsSupported = await client.changeEventsSupported
        sessionMirroring = await client.sessionMirroringSupported
        engine.setLocalOrigin(await client.transportOrigin)
        // Written straight into `profiles`, not through `update(_:)`, which can reconnect — every successful connect would provoke the next one.
        if var profile = activeProfile {
            profile.lastKnownVersion = serverStatus?.version ?? profile.lastKnownVersion
            profile.lastConnected = Date()
            if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
                profiles[index] = profile
            }
        }
        guard !Task.isCancelled else { return }
        await loadIdentity()
        await refreshDefaultCwd()
        // The config document is the only place the clarify and approval countdowns can learn their timeouts, and a reconnect can land on a different `hermes serve` process.
        await settings.loadIfNeeded()
        // Re-arm anything that needed the document: an approval arriving before it landed drew no countdown, and a session blocked on an approval emits no further events (SEC-006).
        publishAll()
        guard !Task.isCancelled else { return }
        // A respawned backend recycles runtime ids, so every open thread has to re-resume (reference §7.2 step 5).
        await refreshThreads(force: true)
        // The roster has no event to listen to, so a socket open is one of the three moments it can learn anything at all.
        await bots.refresh()
        await resumeOpenThreads()
        startPolling()
    }

    /// Timer-driven render flush with the desktop's adaptive floor: yield 3× the measured flush cost, with a 33 ms floor and a 250 ms ceiling (reference §3.3), never per-delta.
    private func startFlushLoop() {
        flushLoop = Task { [weak self] in
            var lastCost: TimeInterval = 0
            while !Task.isCancelled {
                let delay = min(
                    max(TurnEngine.flushFloor, lastCost * 3),
                    TurnEngine.flushCeiling
                )
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                let started = Date()
                let touched = self.engine.flush()
                for sessionID in touched { self.publish(sessionID: sessionID) }
                lastCost = Date().timeIntervalSince(started)
            }
        }
    }

    private func handle(event: GatewayEvent) {
        let projected = HermesEvent.project(event)

        switch projected {
        case .gatewayReady(let ready):
            changeEventsSupported = ready.changeEvents
            sessionMirroring = ready.sessionMirroring
            // The engine compares this against each mirrored frame's `origin` to tell its own turns from another client's.
            engine.setLocalOrigin(ready.origin)
            applyBackendSkin(name: ready.skinName, raw: ready.skin)

        case .skinChanged(let name, let skin):
            applyBackendSkin(name: name, raw: skin)

        case .sessionsChanged:
            scheduleThreadRefresh()
            // On a backend that does not mirror session events, this broadcast is the only notice this device gets that another client moved the conversation it has open.
            scheduleOpenTranscriptRefresh()

        case .sessionTitle(let title):
            applyTitle(storedSessionID: title.storedSessionID, title: title.title)

        case .approvalRequest(let request):
            HapticFeedback.approvalRequested()
            // `.inactive` counts as off screen: the app switcher, the shade and an incoming call all cover the sheet.
            if scenePhase != .active {
                ApprovalNotifications.schedule(sessionID: request.sessionID)
            }

        case .terminalReadRequest(let request):
            // A phone has no terminal buffer to serialize, so answer immediately rather than letting the tool stall for the full 30 s.
            Task { [weak self] in
                _ = try? await self?.approvalAPI?.respondTerminalRead(requestID: request.id)
                self?.engine.clearTerminalRead(sessionID: request.sessionID)
            }

        case .messageComplete(let completion):
            if completion.isError { HapticFeedback.turnFailed() } else { HapticFeedback.turnCompleted() }
            ApprovalNotifications.clear(sessionID: completion.sessionID)
            applyUsage(completion.usage, sessionID: completion.sessionID)
            // A bot's reply landing while its thread is on screen has been read by definition, so advance the watermark before the next roster poll calls it unread.
            if let profile = chat(runtimeSessionID: completion.sessionID)?.botProfile {
                bots.noteBotTurnCompleted(profile: profile)
            }
            scheduleThreadRefresh()

        case .sessionInfo(let info):
            checkContract(info.info)

        default:
            break
        }

        if let sessionID = engine.apply(event) {
            publish(sessionID: sessionID)
            // After publish on purpose: publish runs the Live Activity reconcile, which ends a finished card before the card gate below is consulted.
            sweepEngineRoster(after: projected)
        }
    }

    /// The guard is not a nil check in disguise: a backend old enough to omit the key decodes as 0, which means "did not say" rather than "older than v4".
    private func checkContract(_ info: SessionInfo) {
        guard info.desktopContract > 0 else { return }
        contractNotice.update(
            backendContract: info.desktopContract,
            minimum: Self.minimumDesktopContract
        )
    }

    // MARK: - Agent control

    /// Project the raw `resolve_skin()` dict into both polarities and hand the snapshot to the theme; typography is ignored outright and polarity is never taken from the skin.
    ///
    /// The snapshot is retained whether or not a theme is attached yet, because `theme` is assigned by a `.task` that nothing orders against the bootstrap, and a `gateway.ready` that wins that race has nothing to replay it.
    private func applyBackendSkin(name: String, raw: JSONValue) {
        guard let snapshot = BackendSkinProjection.snapshot(name: name, raw: raw) else { return }
        lastBackendSkin = snapshot
        theme?.applyBackendSkin(snapshot)
    }

    /// Replay the retained snapshot onto a theme that has just been attached; a no-op when nothing has arrived yet.
    private func replayBackendSkin() {
        guard let lastBackendSkin, let theme else { return }
        theme.applyBackendSkin(lastBackendSkin)
    }

    /// End-of-turn usage carried on `message.complete`, stored on the session's chat so the context ring can read it — end of turn, never on a timer.
    private func applyUsage(_ raw: JSONValue, sessionID: String) {
        guard case .object = raw else { return }
        chats.values.first { $0.runtimeSessionID == sessionID }?.usage = SessionUsage(json: raw)
    }

    // BUG-017 (C): `thinking_mode` is deliberately never read here — it is a terminal-UI preference the desktop ignores too, the phone owns its own reasoning presentation, and no phone UI could escape the value a backend happened to hold.

    /// Re-read the backend's global defaults that feed Home's draft pill and new-chat cwd; called on connect and again after a settings write so the pill does not stay stale until the next reconnect.
    func refreshDefaultCwd() async {
        guard let configAPI else { return }
        // `config.get project` answers `{cwd, branch}` on every contract in the field; the bare `terminal.cwd` key is gone on 0.19.1.
        let value = (try? await configAPI.get("project"))?["cwd"]?.coercedString ?? ""
        if !value.isEmpty { defaultCwd = value }
        // `config.get` has no "model" branch — the global model rides on the "provider" payload's `model` field instead.
        defaultModel = (try? await configAPI.get("provider"))?["model"]?.coercedString ?? ""
        defaultEffort = (try? await configAPI.getValue("reasoning")) ?? ""
    }

    /// The one funnel between engine state and everything that renders it; a bare `chat.live = engine.state(for:)` tells the Live Activity roster nothing, so its card outlives the turn it was drawn for (BUG-003).
    func publish(sessionID: String) {
        if let chat = chats.values.first(where: { $0.runtimeSessionID == sessionID }) {
            chat.live = engine.state(for: sessionID)
        }
        // Deliberately outside the guard: a cron run has no open chat on this phone but its events still arrive on this socket.
        liveActivities.sessionDidUpdate(sessionID: sessionID)
    }

    /// Push the latest engine state for every open chat after a bulk change; through `publish` per session so the roster reconciles too and a stranded card is told its turn is over (BUG-003).
    func publishAll() {
        for chat in chats.values {
            guard let runtimeID = chat.runtimeSessionID else { continue }
            publish(sessionID: runtimeID)
        }
    }

    // MARK: - Threads

    /// Whether the list poll is armed; internal rather than private because a poll that never started is otherwise invisible until the first interval elapses (BUG-024).
    var isPollingThreads: Bool { pollTask != nil }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.pollInterval else { return }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.refreshThreads(force: false)
            }
        }
    }

    /// `sessions.changed` fires on any cross-process session write, so the refresh it triggers is trailing-edge throttled.
    private func scheduleThreadRefresh() {
        guard threadRefreshTask == nil else { return }
        let elapsed = Date().timeIntervalSince(lastThreadRefresh)
        let wait = max(0, Self.refreshThrottle - elapsed)
        threadRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.threadRefreshTask = nil
            await self?.refreshThreads(force: true)
        }
    }

    /// The open-conversation twin of `scheduleThreadRefresh`, throttled for the same reason: a burst of change events must collapse into one repaint.
    private func scheduleOpenTranscriptRefresh() {
        guard transcriptRefreshTask == nil else { return }
        let elapsed = Date().timeIntervalSince(lastTranscriptRefresh)
        let wait = max(0, Self.transcriptRefreshThrottle - elapsed)
        transcriptRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.transcriptRefreshTask = nil
            await self?.refreshOpenTranscripts()
        }
    }

    /// Ask every open chat to repaint from the persisted transcript, each deciding for itself whether it is quiet enough; deduped by identity because one model can hold two keys.
    private func refreshOpenTranscripts() async {
        lastTranscriptRefresh = Date()
        var seen = Set<ObjectIdentifier>()
        for chat in chats.values {
            guard seen.insert(ObjectIdentifier(chat)).inserted else { continue }
            await chat.refreshTranscriptIfQuiet()
        }
    }

    func refreshThreads(force: Bool) async {
        guard let rest = rest else { return }
        if !force, Date().timeIntervalSince(lastThreadRefresh) < 2 { return }
        isLoadingThreads = threads.isEmpty
        defer { isLoadingThreads = false }
        let scope = activeProfile?.hermesProfile ?? ""
        do {
            // Archived rows ride along because the hub's grouped history renders an Archived group; the grouping keeps them out of the main sections.
            let page = try await rest.listSessions(
                limit: 60,
                minMessages: 1,
                order: "recent",
                archived: "include",
                profile: scope.isEmpty ? nil : scope
            )
            threads = page.sessions.sorted { $0.lastActive > $1.lastActive }
            threadsError = nil
            lastThreadRefresh = Date()
        } catch {
            threadsError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        await refreshLiveActive()
    }

    /// Refresh which sessions the gateway reports as genuinely running; on failure keep the last-known set, because a liveness RPC hiccup must not blank the hub.
    private func refreshLiveActive() async {
        guard let sessionAPI else { return }
        do {
            // Asked in the form that can tell "nothing is running" from "no answer": the sweep below acts on a session's absence from this list.
            let answered = try await sessionAPI.activeListIfAnswered()
            let live = answered ?? []
            var byKey: [String: LiveSessionStatus] = [:]
            for row in live {
                let key = row.sessionKey.isEmpty ? row.id : row.sessionKey
                guard !key.isEmpty else { continue }
                byKey[key] = row
            }
            let ids = Set(live.filter(\.isWorking).compactMap { row -> String? in
                let key = row.sessionKey.isEmpty ? row.id : row.sessionKey
                return key.isEmpty ? nil : key
            })
            // Both assignments stay guarded by an inequality: `@Observable` publishes on every write, and this runs on a timer.
            if ids != liveActiveIDs { liveActiveIDs = ids }
            if byKey != liveStatuses { liveStatuses = byKey }
            // Two id spaces on adjacent lines: the hub joins on `sessionKey`, the sweep below on `id`, and they must not be harmonised.
            if let answered {
                settleAbsentUnattendedSessions(stillRunning: Set(answered.filter(\.isWorking).map(\.id)))
            }
        } catch {
            // Keep the last-known working set.
        }
    }

    /// `session.active_list` is authoritative in both directions (§4.6): a session the engine holds busy that the gateway does not report finished while this client could not hear it, and no terminal frame is coming (BUG-003).
    ///
    /// Unattended only, on purpose: an attended chat mid-send sets `isBusy` before `prompt.submit` returns, and a poll snapshot from a beat earlier would settle the user's own turn.
    ///
    /// A blocking prompt is swept too, safely: the backend reports an approval-blocked session as working, so a live consent prompt never reaches the settle.
    private func settleAbsentUnattendedSessions(stillRunning: Set<String>) {
        for sessionID in engine.trackedSessionIDs {
            guard chat(runtimeSessionID: sessionID) == nil else { continue }
            let state = engine.state(for: sessionID)
            guard state.isBusy || state.hasBlockingPrompt, !stillRunning.contains(sessionID) else { continue }
            engine.settleFromStatus(sessionID: sessionID)
            publish(sessionID: sessionID)
        }
    }

    private func applyTitle(storedSessionID: String, title: String) {
        guard !storedSessionID.isEmpty, !title.isEmpty else { return }
        if let index = threads.firstIndex(where: { $0.id == storedSessionID }) {
            threads[index] = threads[index].withTitle(title)
        }
        chats.values.first { $0.storedSessionID == storedSessionID }?.title = title
    }

    func renameThread(_ summary: SessionSummary, to title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Prefer the RPC when a live runtime id exists: a freshly created session lives only in the gateway's memory and the PATCH would 404 (reference §4.4).
        if let chat = chats.values.first(where: { $0.storedSessionID == summary.id }),
           let runtimeID = chat.runtimeSessionID,
           let sessionAPI {
            if (try? await sessionAPI.setTitle(sessionID: runtimeID, title: trimmed)) != nil {
                applyTitle(storedSessionID: summary.id, title: trimmed)
                return
            }
        }
        do {
            _ = try await rest?.patchSession(
                sessionID: summary.id,
                title: trimmed,
                profile: summary.profile.isEmpty ? nil : summary.profile
            )
            applyTitle(storedSessionID: summary.id, title: trimmed)
        } catch {
            threadsError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Pin/unpin — `PATCH /api/sessions/{id}`, painted locally first and rolled back by the refresh if the write fails.
    func setPinned(_ summary: SessionSummary, pinned: Bool) async {
        do {
            _ = try await rest?.patchSession(
                sessionID: summary.id,
                pinned: pinned,
                profile: summary.profile.isEmpty ? nil : summary.profile
            )
            await refreshThreads(force: true)
        } catch {
            threadsError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func setArchived(_ summary: SessionSummary, archived: Bool) async {
        do {
            _ = try await rest?.patchSession(
                sessionID: summary.id,
                archived: archived,
                profile: summary.profile.isEmpty ? nil : summary.profile
            )
            await refreshThreads(force: true)
        } catch {
            threadsError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func deleteThread(_ summary: SessionSummary) async {
        // Close the live runtime first so the gateway is not left holding an agent for a row that no longer exists.
        if let chat = chats.values.first(where: { $0.storedSessionID == summary.id }),
           let runtimeID = chat.runtimeSessionID {
            _ = try? await sessionAPI?.close(sessionID: runtimeID)
            engine.forget(sessionID: runtimeID)
        }
        threads.removeAll { $0.id == summary.id }
        chats = chats.filter { $0.value.storedSessionID != summary.id }
        do {
            try await rest?.deleteSession(
                sessionID: summary.id,
                profile: summary.profile.isEmpty ? nil : summary.profile
            )
        } catch {
            threadsError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await refreshThreads(force: true)
        }
    }

    #if DEBUG
    /// Screenshot harness: canned summaries exercising every history group.
    func seedDemoThreads() {
        let now = Date().timeIntervalSince1970
        func row(_ id: String, _ title: String, source: String, ago: Double,
                 active: Bool = false, pinned: Bool = false, archived: Bool = false) -> SessionSummary {
            SessionSummary(json: .object([
                "id": .string(id), "title": .string(title), "source": .string(source),
                "last_active": .number(now - ago), "is_active": .bool(active),
                "pinned": .bool(pinned), "archived": .bool(archived),
                "model": .string("hermes-4"), "message_count": .number(12),
            ]))
        }
        threads = [
            row("d1", "Composer pill measurements", source: "cli", ago: 300, pinned: true),
            row("d2", "Refactor the connect machine", source: "desktop", ago: 60, active: true),
            row("d3", "Landscape audit", source: "cli", ago: 3_600),
            row("d4", "Fix the flaky reconnect test", source: "tui", ago: 7_200),
            row("d5", "Grocery list triage", source: "telegram", ago: 1_800),
            row("d6", "Nightly digest", source: "cron", ago: 43_200),
            row("d7", "Old spike — WKWebView", source: "cli", ago: 860_000, archived: true),
        ]
    }
    #endif

    // MARK: - Chats

    func chat(for route: ThreadRoute) -> ChatModel {
        if let existing = chats[route.key] { return existing }
        let model: ChatModel
        switch route {
        case .existing(let summary):
            model = ChatModel(app: self, summary: summary)
        case .new:
            model = ChatModel(app: self, summary: nil)
        case .bot(let ref):
            // No summary and no stored id, so `open()` runs the Bot Chat resolver; the `bot:<profile>` cache key is what makes rapid taps hit this instance rather than the network.
            model = ChatModel(app: self, summary: nil, bot: ref)
        }
        chats[route.key] = model
        // BUG-052: claim the branch seed here, where every route into a conversation passes exactly once and the child's model has just been minted.
        if case .existing(let summary) = route,
           let seed = branchSeeds.removeValue(forKey: summary.id) {
            model.seedHistory(entries: seed.entries, ordinals: seed.ordinals)
        }
        return model
    }

    /// Transcript rows a just-created branch already knows, held until something opens it (BUG-052); a dictionary rather than a direct write because the child's model is minted a frame later by the navigation.
    private var branchSeeds: [String: (entries: [ChatEntry], ordinals: [String: Int])] = [:]

    func seedBranchedTranscript(storedSessionID: String, entries: [ChatEntry], ordinals: [String: Int]) {
        guard !storedSessionID.isEmpty, !entries.isEmpty else { return }
        if let open = chats[ThreadRoute.Key.existing(storedSessionID).rawValue] {
            open.seedHistory(entries: entries, ordinals: ordinals)
        } else {
            branchSeeds[storedSessionID] = (entries, ordinals)
        }
    }

    /// The route that displays a given chat — what a deep link resolves to; a bot chat returns `.bot(ref)`, because `.existing(summary)` would push a second navigation identity and lose the bot's header.
    func route(for chat: ChatModel) -> ThreadRoute? {
        if let profile = chat.botProfile {
            return .bot(BotThreadRef(profile: profile, displayName: chat.botDisplayName ?? profile))
        }
        if let summary = chat.summary { return .existing(summary) }
        return nil
    }

    /// The path element a conversation is currently showing under, which for a draft is only recorded in the cache key (BUG-100); `route(for:)` answers the different question of how a deep link would reach it.
    func openRoute(for chat: ChatModel) -> ThreadRoute? {
        if let route = route(for: chat) { return route }
        for (key, cached) in chats where cached === chat {
            if case .new(let id)? = ThreadRoute.Key(rawValue: key) { return .new(id) }
        }
        return nil
    }

    /// The cached chat for a bot's forever-chat, keyed on the route rather than the session id so it answers before the resolver has bound anything.
    func botChat(profile: String) -> ChatModel? {
        chats[ThreadRoute.Key.bot(profile).rawValue]
    }

    /// The chat holding a given runtime session id; nil for a cron or desktop-started session whose events this device is only watching.
    func chat(runtimeSessionID: String) -> ChatModel? {
        chats.values.first { $0.runtimeSessionID == runtimeSessionID }
    }

    /// Release every cached chat whose route has left the navigation stack, returning how many models went so a caller can log it.
    ///
    /// `alsoKeeping` is a second set rather than a wider first one (BUG-099): entering Bots mode stashes the Sessions stack rather than popping it, and a stashed route is retained but not visible, which is what `bots.setOnScreenRouteKeys` below means.
    @discardableResult
    func releaseChats(keeping openRouteKeys: Set<String>, alsoKeeping stashedRouteKeys: Set<String> = []) -> Int {
        // Nothing is evicted while the demo runs: entering it assigns the path, and this sweep would release every real conversation `enterDemo` deliberately preserved.
        guard demo == nil else { return 0 }
        // `RootView` calls this with exactly the routes still on screen, which makes it the one honest "the user left this thread" signal in the app.
        bots.setOnScreenRouteKeys(openRouteKeys)
        // Retention is per model, not per key: one chat can be registered under two keys at once, so a single key still on the stack keeps every key pointing at that model.
        let retainedKeys = openRouteKeys.union(stashedRouteKeys)
        let onScreen = Set(
            chats.filter { retainedKeys.contains($0.key) }.values.map(ObjectIdentifier.init)
        )

        var releasing = Set<ObjectIdentifier>()
        var releasedRuntimeIDs: [String] = []
        for chat in chats.values {
            let identity = ObjectIdentifier(chat)
            guard !onScreen.contains(identity), !releasing.contains(identity) else { continue }
            guard chat.isReleasable else { continue }
            releasing.insert(identity)
            if let runtimeID = chat.runtimeSessionID { releasedRuntimeIDs.append(runtimeID) }
        }
        guard !releasing.isEmpty else { return 0 }

        chats = chats.filter { !releasing.contains(ObjectIdentifier($0.value)) }

        // The engine keys turn state by runtime id, so it is told too; the re-check confirms no other surviving chat is still listening on that id.
        // The session itself is left running server-side: this is a memory eviction, not a close, and re-entry resumes it.
        for runtimeID in releasedRuntimeIDs where chat(runtimeSessionID: runtimeID) == nil {
            engine.forget(sessionID: runtimeID)
        }
        return releasing.count
    }

    // MARK: - Engine roster eviction

    /// The chatless half of the memory story (BUG-004): a session with no chat at all — a cron run, a fan-out turn — would otherwise grow the engine's roster for the life of the process.
    ///
    /// Terminal frames sweep because that is the moment a session goes idle, and the high-water valve covers sessions that never send one; an evicted session's next event rebuilds a fresh state.
    private func sweepEngineRoster(after event: HermesEvent) {
        switch event {
        case .messageComplete, .errorEvent:
            evictIdleEngineSessions()
        default:
            guard engine.trackedSessionCount > Self.engineRosterHighWater,
                  Date().timeIntervalSince(lastHighWaterSweep) > Self.highWaterSweepInterval
            else { return }
            lastHighWaterSweep = Date()
            evictIdleEngineSessions()
        }
    }

    /// One session's verdict, split from the sweep so the card gate is testable — ActivityKit cannot start a real activity in a test host.
    func engineSessionIsEvictable(_ sessionID: String, hasCard: Bool) -> Bool {
        chat(runtimeSessionID: sessionID) == nil
            && !hasCard
            && engine.isQuiescent(sessionID: sessionID)
    }

    /// Forget every tracked session that no chat is watching, no Live Activity card is drawing from, and the engine calls quiescent; returns how many went.
    @discardableResult
    func evictIdleEngineSessions() -> Int {
        var evicted = 0
        for sessionID in engine.trackedSessionIDs {
            guard engineSessionIsEvictable(
                sessionID,
                hasCard: liveActivities.hasCard(sessionID: sessionID)
            ) else { continue }
            engine.forget(sessionID: sessionID)
            liveActivities.sessionEvicted(sessionID: sessionID)
            evicted += 1
        }
        return evicted
    }

    // MARK: - Live Activities

    /// Every session the turn engine is tracking, keyed off the engine rather than off open chats, because a cron run has no `ChatModel` and is the case a Lock Screen card is most useful for.
    func liveSessions() -> [String: LiveActivityContext] {
        var contexts: [String: LiveActivityContext] = [:]
        for sessionID in engine.trackedSessionIDs {
            if let context = activityContext(for: sessionID) { contexts[sessionID] = context }
        }
        return contexts
    }

    func activityContext(for sessionID: String) -> LiveActivityContext? {
        let state = engine.state(for: sessionID)
        let chat = chat(runtimeSessionID: sessionID)
        // Title ladder: the live `session.title` event, then the open chat's own resolved title, then the kit's fallback — never a session id.
        let title = state.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? chat?.title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? ""
        // Always the dark seeds whatever the app's polarity: the Dynamic Island is drawn on black unconditionally, so a light skin's near-black foreground lands as black-on-black.
        let polarity: ColorScheme = .dark
        let skin = theme?.skin(for: polarity) ?? .default(for: polarity)
        return LiveActivityContext(
            state: state,
            title: title,
            backendName: activeProfile?.name ?? "",
            skin: LiveActivitySkinSeed(
                fg: skin.fg.hex,
                accent: skin.accent.hex,
                bg: skin.bg.hex,
                card: skin.card.hex,
                isDark: polarity == .dark
            ),
            // "Attended" means this phone has the chat open; an unattended session is a cron or desktop-started run.
            isAttended: chat != nil
        )
    }

    /// Called by a chat once it owns a runtime session id, so the event pump can find it.
    func chatDidBind(_ chat: ChatModel, storedSessionID: String?) {
        guard let storedSessionID, !storedSessionID.isEmpty else { return }
        let key = ThreadRoute.Key.existing(storedSessionID).rawValue
        if chats[key] == nil { chats[key] = chat }
        Task { await refreshThreads(force: true) }
    }

    private func resumeOpenThreads() async {
        // Join an in-flight pass rather than start a second one: the three callers overlap across the `resumeAfterReconnect` await, and the guard they check is only stamped after it.
        if let task = resumeOpenThreadsTask {
            await task.value
            return
        }
        let task = Task { await self.performResumeOpenThreads() }
        resumeOpenThreadsTask = task
        await task.value
        resumeOpenThreadsTask = nil
    }

    private func performResumeOpenThreads() async {
        // One model can be registered under two keys, so resume it only once; and a chat that bound during THIS connection is already live, where a re-resume would rebuild the agent and discard the create's model override.
        var seen = Set<ObjectIdentifier>()
        for chat in chats.values where chat.storedSessionID != nil {
            guard seen.insert(ObjectIdentifier(chat)).inserted else { continue }
            guard chat.runtimeBoundAt < socketOpenedAt else { continue }
            await chat.resumeAfterReconnect()
        }
        publishAll()
    }

    // MARK: - Lifecycle

    /// iOS suspends the app while the backend keeps working, so on return nudge the socket, refresh the list, and re-resume every open thread.
    func handleForeground() async {
        // Back on screen: every pending-approval notification is now stale.
        ApprovalNotifications.clearAll()
        // A card the last process left behind often surfaces after `install` asked for it, so the adoption pass runs again every time the app comes forward or the ghost is never counted against the cap.
        liveActivities.adoptOrphans()
        guard let client = client else { return }
        await client.wake()
        await refreshThreads(force: true)
        await bots.refresh()
        await resumeOpenThreads()
    }

    func handleBackground() {
        // Chat turns continue server-side and are never reaped here; audio is different, because the voice surface must not come back claiming to listen after a background gap.
        AudioSession.shared.endAll()
    }
}

/// The navigation identity of one bot's forever-chat: the route is the bot, not the session, because the session id underneath can move without changing what the user is looking at.
struct BotThreadRef: Hashable, Sendable {
    let profile: String
    let displayName: String

    init(profile: String, displayName: String) {
        self.profile = profile
        self.displayName = displayName
    }
}

/// Navigation identity for a thread; a draft chat has no stored id until its first prompt writes the DB row.
enum ThreadRoute: Hashable {
    case existing(SessionSummary)
    case new(UUID)
    /// A bot's forever-chat, keyed by the bot rather than by the session.
    case bot(BotThreadRef)

    enum Key: Hashable {
        case existing(String)
        case new(UUID)
        case bot(String)

        var rawValue: String {
            switch self {
            case .existing(let id): return "existing:\(id)"
            case .new(let id): return "new:\(id.uuidString)"
            case .bot(let profile): return "bot:\(profile)"
            }
        }

        /// The reverse direction, sitting next to the forward one so the two spellings cannot drift (BUG-100).
        init?(rawValue: String) {
            let parts = rawValue.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            let body = String(parts[1])
            switch parts[0] {
            case "existing":
                self = .existing(body)
            case "new":
                guard let id = UUID(uuidString: body) else { return nil }
                self = .new(id)
            case "bot":
                self = .bot(body)
            default:
                return nil
            }
        }
    }

    var key: String {
        switch self {
        case .existing(let summary): return Key.existing(summary.id).rawValue
        case .new(let id): return Key.new(id).rawValue
        case .bot(let ref): return Key.bot(ref.profile).rawValue
        }
    }
}
