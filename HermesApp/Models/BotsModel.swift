import Foundation
import HermesServeKit
import Observation

/// The Bots roster: a bot is a Hermes profile, and its thread is the one session titled exactly `Bot Chat` in that profile's `state.db`.
///
/// Polling, not events: no gateway event names a session for a client that is not attached to it, so a 5 s poll of `profiles.list` while the roster is on screen is the only honest signal there is.
@MainActor
@Observable
final class BotsModel {

    /// One roster row.
    struct Bot: Identifiable, Hashable, Sendable {
        var id: String { profile }
        /// The backend's profile name — the wire identity, and the only stable one.
        let profile: String
        /// What the roster and the thread header print.
        let displayName: String
        let description: String
        let isDefault: Bool
        let hasAvatar: Bool
        /// One line under the name: the newest message on the bot's Bot Chat, else the profile's stated purpose, else nothing.
        var preview: String
        /// Epoch seconds, 0 when the backend has said nothing.
        var lastActive: Double
        var isWorking: Bool
        var isUnread: Bool

        var threadRef: BotThreadRef { BotThreadRef(profile: profile, displayName: displayName) }
    }

    /// Recency descending; the default profile competes on recency like any other row rather than being pinned to the top.
    private(set) var bots: [Bot] = []
    private(set) var isLoading = false
    private(set) var error: String?
    /// False until the first `refresh()` has settled, successfully or not; the roster's empty state is a different sentence before and after.
    private(set) var hasLoadedOnce = false
    /// `profiles.list`'s `bot_mode_protocol` capability flag; nil until the first successful load, because absent and false are not the same claim.
    private(set) var botModeProtocol: Bool?
    /// Whether the default profile declares desktop groups; drives one footnote row, since there is no group primitive to call.
    private(set) var hasDesktopGroups = false

    /// The bot thread this backend last had open, persisted so a relaunch into Bots mode can restore it.
    var lastOpenedProfile: String? {
        get { store.lastOpened(backend: app.activeProfileID) }
        set { store.setLastOpened(newValue, backend: app.activeProfileID) }
    }

    /// The pin / watermark / last-thread store; `var` so a test can point it at its own `UserDefaults` suite, and the app never reassigns it.
    var store: BotChatPins = .standard

    private unowned let app: AppModel

    init(app: AppModel) {
        self.app = app
    }

    // MARK: - Roster visibility and polling

    /// Called by the roster view's `onAppear` / `onDisappear`; polling runs only while the roster is on screen and the socket is open.
    func setRosterVisible(_ visible: Bool) {
        rosterVisible = visible
        if visible {
            startPolling()
        } else {
            pollTask?.cancel()
            pollTask = nil
        }
    }

    private(set) var rosterVisible = false
    private var pollTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    /// The one session title that names a bot's forever-chat, aliased to the kit's constant because uniqueness per profile is a partial UNIQUE index in `state.db`, not a convention.
    static let canonicalChatTitle = BotChat.title

    /// Does a title the backend reported affirmatively say that a session is not a bot's forever-chat (BUG-053)?
    ///
    /// The asymmetry is the point: a title that is present and different is a refutation, and an absent title is not a claim at all, so silence never re-derives a perfectly good pin.
    static func titleRefutesBotChat(_ title: String) -> Bool {
        !title.isEmpty && title != canonicalChatTitle
    }

    /// The first thing said in a freshly minted Bot Chat; `session.create` alone persists nothing, so without a kickoff there is no DB row to find next time.
    static let kickoffPrompt = "Hey, tell me about yourself!"

    /// Poll cadence, not adaptive: the roster is a foreground surface with a handful of rows, and a slower tick is visible as a stale "working" dot.
    static let pollInterval: Duration = .seconds(5)

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.rosterVisible, self.app.connectionState.isOpen {
                    await self.refresh()
                }
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    // MARK: - Roster load

    /// Reload the roster, single-flighted because the poll, the post-open refresh and a foreground return routinely overlap.
    func refresh() async {
        if let task = refreshTask {
            await task.value
            return
        }
        let task = Task { await self.performRefresh() }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func performRefresh() async {
        guard let profilesAPI = app.profilesAPI else {
            error = "Not connected to a backend."
            hasLoadedOnce = true
            return
        }
        // The spinner is for a roster with nothing to show; a poll over a populated list must not flash one every five seconds.
        isLoading = bots.isEmpty
        defer { isLoading = false }

        let backend = app.activeProfileID
        let result: ProfilesListResult
        do {
            // On an older backend the pins are what make hidden Bot Chats visible at all, because `last_session` is built from a listing that excludes hidden rows; a newer one resolves by title and discards them (BUG-113).
            result = try await profilesAPI.list(preferredSessionIDs: store.pins(backend: backend))
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            hasLoadedOnce = true
            return
        }
        error = nil
        botModeProtocol = result.botModeProtocol

        let now = Date().timeIntervalSince1970
        var rows: [Bot] = []
        var hints: [String: String] = [:]
        var unpinned: [String] = []

        for profile in result.profiles {
            let name = profile.name
            if let hint = profile.botChatPinHint, !hint.isEmpty { hints[name] = hint }

            let preferred: ProfileSessionSummary?
            switch profile.preferredSession {
            case .present(let summary): preferred = summary
            case .absent, .gone: preferred = nil
            }
            // Neither `.gone` nor `.absent` retires the pin here: the resolver's 4007 rung is the one place a pin is retired, on a direct answer rather than a roster side effect.
            let last = profile.lastSession

            let lastActive = max(preferred?.lastActive ?? 0, last?.lastActive ?? 0)
            let preview = firstNonEmpty(preferred?.preview, last?.preview, profile.description)

            if store.pin(backend: backend, profile: name) == nil { unpinned.append(name) }

            rows.append(Bot(
                profile: name,
                displayName: Self.displayName(profile: name, declared: profile.displayName),
                description: profile.description,
                isDefault: profile.isDefault,
                hasAvatar: profile.hasAvatar,
                preview: preview,
                lastActive: lastActive,
                isWorking: isWorking(
                    profile: name,
                    preferred: preferred,
                    worker: profile.workerSession,
                    now: now
                ),
                isUnread: false
            ))

            if profile.isDefault {
                hasDesktopGroups = Self.hasGroups(uiMeta: profile.uiMeta)
            }
        }

        serverPinHints = hints
        bots = rows
            .map { applyUnread($0, backend: backend) }
            .sorted { $0.lastActive > $1.lastActive }
        hasLoadedOnce = true

        // One title lookup per unpinned profile seeds the pin so the next poll carries a `preferred_session`; best-effort, and it must never become the roster's error line.
        await seedPins(for: unpinned, backend: backend)
    }

    /// Three signals, because no event names a session for a client that is not attached to it; only the first is exact, and the two recency windows are generous on purpose.
    private func isWorking(
        profile: String,
        preferred: ProfileSessionSummary?,
        worker: ProfileWorkerSummary?,
        now: Double
    ) -> Bool {
        if let chat = app.botChat(profile: profile), chat.live.isBusy || chat.isSending { return true }
        if let preferred, now - preferred.lastActive < Self.chatActivityWindow { return true }
        if let worker, now - worker.lastActive < Self.workerActivityWindow { return true }
        return false
    }

    /// The worker window is wider because a kanban or tool worker heartbeats less often than a conversation does.
    static let chatActivityWindow: Double = 90
    static let workerActivityWindow: Double = 150

    /// Unread is `lastActive > watermark`; watermarks are seeded on the first sighting, which keeps a backend full of months-old bot chats from opening as a wall of unread dots.
    private func applyUnread(_ bot: Bot, backend: UUID?) -> Bot {
        var bot = bot
        guard let watermark = store.watermark(backend: backend, profile: bot.profile) else {
            store.setWatermark(bot.lastActive, backend: backend, profile: bot.profile)
            bot.isUnread = false
            return bot
        }
        if onScreenProfiles.contains(bot.profile) {
            if bot.lastActive > watermark {
                store.setWatermark(bot.lastActive, backend: backend, profile: bot.profile)
            }
            bot.isUnread = false
            return bot
        }
        bot.isUnread = bot.lastActive > watermark
        return bot
    }

    private func seedPins(for profiles: [String], backend: UUID?) async {
        guard let sessionAPI = app.sessionAPI, !profiles.isEmpty else { return }
        for profile in profiles {
            guard !Task.isCancelled else { return }
            guard store.pin(backend: backend, profile: profile) == nil else { continue }
            let match = try? await sessionAPI.lookupByTitle(
                Self.canonicalChatTitle,
                profile: Self.wireProfile(for: profile)
            )
            guard let match, match.title == Self.canonicalChatTitle, !match.id.isEmpty else { continue }
            store.setPin(match.id, backend: backend, profile: profile)
        }
    }

    private func firstNonEmpty(_ candidates: String?...) -> String {
        for candidate in candidates {
            if let candidate, !candidate.isEmpty { return candidate }
        }
        return ""
    }

    /// Whether `ui_meta['hermes-bots-groups'].rooms` is non-empty; groups are not rendered, so this drives exactly one footnote row.
    static func hasGroups(uiMeta: JSONValue) -> Bool {
        guard let rooms = uiMeta["hermes-bots-groups"]?["rooms"] else { return false }
        if let object = rooms.objectValue { return !object.isEmpty }
        if let array = rooms.arrayValue { return !array.isEmpty }
        return false
    }

    // MARK: - Avatars

    /// The bot's avatar bytes, cached per `(backend, profile)`; a missing asset is `{found: false}` on the wire, not an error, so this never throws to a view.
    func avatarData(for profile: String) async -> Data? {
        let key = BotChatPins.key(backend: app.activeProfileID, profile: profile)
        if let cached = avatarCache[key] { return cached.data }
        guard let profilesAPI = app.profilesAPI else { return nil }
        do {
            // `{found: false}` decodes to nil and is a real answer, so it is cached; a thrown failure is not, and `try?` would flatten the two into the same nil.
            let asset = try await profilesAPI.getAsset(profile: profile)
            avatarCache[key] = CachedAvatar(data: asset?.data)
            return asset?.data
        } catch {
            return nil
        }
    }

    private struct CachedAvatar { let data: Data? }
    private var avatarCache: [String: CachedAvatar] = [:]

    // MARK: - On-screen bot threads

    /// Which bot threads are on the navigation stack, published by `AppModel.releaseChats`, so the roster learns a thread was left without any view having to say so.
    private(set) var onScreenProfiles: Set<String> = []

    func setOnScreenRouteKeys(_ keys: Set<String>) {
        onScreenProfiles = Set(keys.compactMap { key in
            key.hasPrefix("bot:") ? String(key.dropFirst(4)) : nil
        })
    }

    /// A turn finished on a bot chat this phone holds; if its thread is on screen the user is watching it arrive, so the watermark moves with it.
    func noteBotTurnCompleted(profile: String) {
        guard onScreenProfiles.contains(profile) else { return }
        store.setWatermark(Date().timeIntervalSince1970, backend: app.activeProfileID, profile: profile)
        if let index = bots.firstIndex(where: { $0.profile == profile }) {
            bots[index].isUnread = false
        }
    }

    // MARK: - Unread

    /// The thread is on screen: clear its unread dot, advance its watermark, and remember it as this backend's last bot thread.
    func markOpened(_ profile: String) {
        lastOpenedProfile = profile
        let seen = bots.first(where: { $0.profile == profile })?.lastActive ?? 0
        store.setWatermark(max(seen, store.watermark(backend: app.activeProfileID, profile: profile) ?? 0),
                           backend: app.activeProfileID,
                           profile: profile)
        if let index = bots.firstIndex(where: { $0.profile == profile }) {
            bots[index].isUnread = false
        }
    }

    // MARK: - Naming

    /// The label for a profile row: the profile literally named `default` is the user's own Hermes, and "Default" is not a name anyone gave it.
    static func displayName(profile: String, declared: String) -> String {
        if profile == "default" { return "Hermes" }
        let trimmed = declared.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return titleCased(profile)
    }

    /// `code-review` → `Code Review`, `data_ops` → `Data Ops`.
    static func titleCased(_ profile: String) -> String {
        let words = profile
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { word -> String in
                guard let first = word.first else { return "" }
                return String(first).uppercased() + word.dropFirst()
            }
        let joined = words.joined(separator: " ")
        return joined.isEmpty ? profile : joined
    }

    /// What goes on the wire as `profile:` for a bot — a pass-through that exists to hold one finding: sending nothing would silently target a named-profile gateway's launch profile instead.
    static func wireProfile(for profile: String) -> String? {
        profile.isEmpty ? nil : profile
    }

    /// The server-side pin Desktop wrote (`ui_meta['hermes-bots'].chat`), read as a hint only; the phone never writes that object.
    func serverPinHint(_ profile: String) -> String? {
        serverPinHints[profile]
    }

    private(set) var serverPinHints: [String: String] = [:]
}
