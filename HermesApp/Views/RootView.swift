import HermesServeKit
import SwiftUI
import UIKit

/// One navigation identity for everything the stack can show.
enum AppRoute: Hashable {
    case thread(ThreadRoute)
    case settings
    case settingsBackend
    case settingsDiagnostics
    case settingsAppearance
    /// A settings screen (Chat / Agent / About groups).
    case settingsScreen(SettingsScreenID)
    /// Command Center — the hub's peer of Settings.
    case commandCenter
}

extension AppRoute {
    /// The chat-cache key this route displays, or nil for a route that displays no conversation.
    var threadRouteKey: String? {
        guard case .thread(let route) = self else { return nil }
        return route.key
    }
}

/// App shell: Home as the launch destination, the hub drawer over it, and the scene-phase hooks.
///
/// Per jsonrpc-methods §4.5: events emitted while suspended are replayed as the `inflight` snapshot on the next `session.resume`, so foregrounding does real work and backgrounding does nothing.
@MainActor
struct RootView: View {
    @Environment(\.hermes) private var t
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var path: [AppRoute] = []
    @State private var hubOpen = false

    /// Sessions or Bots; `RootView` state because its three consumers — Home's top bar, the compact drawer and the regular-width rail — are not in one subtree.
    @State private var mode: AppMode = AppMode.launchMode(
        stored: UserDefaults.standard.string(forKey: AppMode.launchModeStorageKey)
    )
    /// The Sessions path, held while Bots mode is on screen.
    @State private var stashedSessionsPath: [AppRoute] = []
    /// The pending release sweep; every path change cancels the last one and arms a fresh one.
    @State private var releaseSweep: Task<Void, Never>?
    /// Home's draft conversation, hoisted out of `HomeView` so a mode switch cannot take the half-typed message with it.
    @State private var draftRoute = ThreadRoute.new(UUID())
    /// Screenshot harness only: one of the activity strip's sheets, presented over the seeded chat because the strip itself is mounted by `ChatView`.
    @State private var harnessStripSheet: HarnessStripSheet?

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                // Regular width: the hub is a persistent 300 pt rail — no scrim, no dismiss.
                HStack(spacing: 0) {
                    NavigationHubView(path: $path, isPresented: .constant(true), mode: $mode)
                        .frame(width: 300)
                        // BUG-118: bare `ignoresSafeArea()` paints through the demo banner's band.
                        .background(t.surface.ignoresSafeArea(edges: [.bottom, .horizontal]))
                    Rectangle()
                        .fill(t.stroke2)
                        .frame(width: 1)
                        .ignoresSafeArea(edges: [.bottom, .horizontal])
                    navigationLayer
                }
            } else {
                ZStack(alignment: .leading) {
                    navigationLayer
                    hubLayer
                }
            }
        }
        // FEAT-020: a top safe-area inset on the shell's root, so the demo marker displaces every screen instead of covering one.
        .demoModeMarker(isActive: app.isDemoActive) {
            Task { await app.exitDemo() }
        }
        .sheet(item: $harnessStripSheet) { sheet in
            switch sheet.kind {
            case .automation: SessionControlSheet(controls: sheet.chat.sessionControls)
            case .processes: BackgroundProcessesSheet(processes: sheet.chat.backgroundProcesses)
            }
        }
        .animation(Motion.layer(reduced: reduceMotion), value: hubOpen)
        // `hermes://chat/<runtime session id>` — the only link this app opens.
        .onOpenURL { url in
            guard let key = HermesActivityLink.sessionKey(from: url) else { return }
            // `route(for:)` and not `.existing(chat.summary)`: a bot chat has no summary until it binds, and `.existing` would push a second identity for a conversation already cached under `bot:<profile>`.
            guard let chat = app.chat(runtimeSessionID: key), let route = app.route(for: chat) else {
                // The session is not open on this phone; Home is the honest landing.
                path = []
                hubOpen = false
                return
            }
            // A link is an absolute jump, so the mode follows the route rather than the other way round.
            switchMode(to: route.isBot ? .bots : .sessions)
            path = [.thread(route)]
            hubOpen = false
        }
        .onChange(of: app.requestedRoute) { _, requested in
            guard let requested else { return }
            app.requestedRoute = nil
            // A requested path that shows a conversation takes that conversation's mode; one carrying no thread leaves the mode alone.
            if let thread = requested.first(where: { $0.threadRouteKey != nil }) {
                switchMode(to: thread.isBotThread ? .bots : .sessions)
            }
            path = requested
            hubOpen = false
        }
        // `NavigationStack` writes this binding back on the back button, the edge swipe and a programmatic pop alike, so a route missing from `path` is one the user has left.
        .onChange(of: path) { _, _ in
            scheduleReleaseSweep()
        }
        .task {
            await bootstrap()
        }
        .onChange(of: scenePhase) { _, phase in
            // Publish the phase so AppModel can decide whether a backgrounded approval warrants a local notification.
            app.scenePhase = phase
            switch phase {
            case .active:
                Task { await app.handleForeground() }
            case .background:
                app.handleBackground()
            default:
                break
            }
        }
    }

    private var navigationLayer: some View {
        NavigationStack(path: $path) {
            homeBody
                .navigationDestination(for: AppRoute.self) { route in
                    destination(for: route)
                }
        }
    }

    /// The stack's root, which is what mode actually swaps; everything below it is keyed on the route and does not read mode.
    @ViewBuilder
    private var homeBody: some View {
        switch mode {
        case .sessions:
            HomeView(
                path: $path,
                hubOpen: $hubOpen,
                mode: $mode,
                onToggleMode: { switchMode(to: HomeModeControl.toggled(mode)) },
                draftRoute: $draftRoute
            )
        case .bots:
            BotsHomeView(
                path: $path,
                hubOpen: $hubOpen,
                mode: $mode,
                onToggleMode: { switchMode(to: HomeModeControl.toggled(mode)) }
            )
        }
    }

    // MARK: Mode

    /// The whole of a mode switch: one stored value, the stash, and the path.
    ///
    /// It touches no model, so a typed draft cannot be lost by switching modes and a running turn keeps running.
    private func switchMode(to target: AppMode) {
        guard target != mode else { return }
        switch target {
        case .bots:
            let transition = BotsRouteMemory.enter(path: path, remembered: rememberedBotThread)
            stashedSessionsPath = transition.stashed
            path = transition.path
        case .sessions:
            path = BotsRouteMemory.leave(path: path, stashed: stashedSessionsPath)
            stashedSessionsPath = []
        }
        mode = target
        hubOpen = false
    }

    /// The bot thread to restore on top of the roster, if there is one.
    ///
    /// Gated on the roster actually knowing the profile: one the backend no longer has would open a thread that cannot resolve.
    private var rememberedBotThread: BotThreadRef? {
        guard let profile = app.bots.lastOpenedProfile,
              let bot = app.bots.bots.first(where: { $0.profile == profile })
        else { return nil }
        return bot.threadRef
    }

    @ViewBuilder
    private func destination(for route: AppRoute) -> some View {
        switch route {
        case .thread(let threadRoute):
            // BUG-141: `path = []` is the hub's own "New conversation" action — the stack's root is the draft composer.
            ChatView(model: app.chat(for: threadRoute), onStartNewChat: { path = [] })
        case .settings:
            SettingsView(path: $path)
        case .settingsBackend:
            ConnectionSettingsView()
        case .settingsDiagnostics:
            DiagnosticsView()
        case .settingsAppearance:
            AppearanceSettingsView()
        case .commandCenter:
            CommandCenterView()
        case .settingsScreen(let id):
            switch id {
            case .transcript:
                TranscriptSettingsView()
            case .about:
                AboutView()
            case .capabilities:
                CapabilitiesView()
            case .artifacts:
                ArtifactsView()
            case .messaging:
                MessagingStatusView()
            case .composerActions:
                ComposerActionsSettingsView()
            case .voice:
                VoiceSettingsView()
            case .notifications:
                NotificationSettingsView()
            case .chat:
                ChatSettingsView()
            default:
                SettingsDetailView(screen: SettingsCatalog.screen(id))
            }
        }
    }

    // MARK: Hub drawer — compact width

    /// 300 pt overlay drawer with a scrim; at regular width the same hub view becomes a persistent rail without forking.
    @ViewBuilder
    private var hubLayer: some View {
        if hubOpen {
            t.scrim
                // The whole screen dims, the status bar included, so the drawer reads as a layer over the app and not a panel pasted below the clock. BUG-118's demo banner is safe because `demoModeMarker` raises it above this whole layer.
                .ignoresSafeArea(.container)
                .onTapGesture { hubOpen = false }
                .transition(.opacity)
                .accessibilityLabel("Close menu")
                .accessibilityAddTraits(.isButton)

            NavigationHubView(path: $path, isPresented: $hubOpen, mode: $mode)
                .frame(width: 300)
                .frame(maxHeight: .infinity)
                .background(t.surface.ignoresSafeArea(.container))
                // The drawer's lift onto the scrim: a gradient past its trailing edge rather than a shadow, so the list is not rendered offscreen on every frame of the slide.
                .background(alignment: .trailing) {
                    LinearGradient(
                        colors: [Color.black.opacity(HubDrawer.liftOpacity), Color.black.opacity(0)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: HubDrawer.liftWidth)
                    .offset(x: HubDrawer.liftWidth)
                    .ignoresSafeArea(.container)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                .transition(.move(edge: .leading))
                .gesture(
                    DragGesture(minimumDistance: 24)
                        .onEnded { value in
                            if value.translation.width < -40 { hubOpen = false }
                        }
                )
        }
    }

    /// How long a route stays retained after it leaves `path`: longer than a `NavigationStack` pop, short enough that the memory bound is still a bound.
    static let releaseSweepDelayNanoseconds: UInt64 = 600_000_000

    /// The release sweep, run after the navigation transition rather than from the `path` handler that notices it.
    ///
    /// BUG-121: `NavigationStack` keeps the popped `ChatView` mounted for the whole pop animation, so sweeping from the handler evicts a model still on screen and `chat(for:)` mints a second one for a route on its way out.
    ///
    /// The keep set is read at fire time, not captured, so a route pushed back within the window is simply kept.
    private func scheduleReleaseSweep() {
        releaseSweep?.cancel()
        releaseSweep = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.releaseSweepDelayNanoseconds)
            guard !Task.isCancelled else { return }
            app.releaseChats(
                keeping: Set(path.compactMap(\.threadRouteKey)),
                alsoKeeping: Set(stashedSessionsPath.compactMap(\.threadRouteKey))
            )
        }
    }

    /// Connect to the saved backend on launch; with nothing signed in, stay on Home in its first-run state.
    @MainActor
    private func bootstrap() async {
        #if DEBUG
        // Screenshot harness: `-hermesScreenshotRoute home|hub|settings` skips the network bootstrap and lands on the named surface.
        await Self.applyScreenshotOrientation()
        // Device voice probe (`-hermesVoiceProbe`): seed the backend so both engines are reachable, run the A/B, stop.
        if ProcessInfo.processInfo.arguments.contains("-hermesVoiceProbe") {
            if let seeded = await app.applySeedArgumentsIfPresent() {
                await app.activate(profileID: seeded, connect: true)
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
            await VoiceProbe.run(audioAPI: app.audioAPI)
            return
        }
        // Consent-gate and roster probe (`-hermesActivityProbe`); needs no backend, and drives the real controller with fabricated sessions.
        if ProcessInfo.processInfo.arguments.contains("-hermesActivityProbe") {
            await LiveActivityProbe.run(app: app)
            return
        }
        // `-hermesActivityProbeLeave [approval]` — start one card and stop, leaving it on screen.
        if ProcessInfo.processInfo.arguments.contains("-hermesActivityProbeLeave") {
            await LiveActivityProbe.leaveOneRunning(
                app: app,
                approval: ProcessInfo.processInfo.arguments.contains("-hermesActivityApproval")
            )
            return
        }
        if let route = Self.screenshotRoute {
            // With a seeded backend every capture shows live values; demo data is only for offline captures.
            var seededLive = false
            if let seeded = await app.applySeedArgumentsIfPresent() {
                await app.activate(profileID: seeded, connect: true)
                seededLive = true
            }
            switch route {
            case "hub":
                if !seededLive { app.seedDemoThreads() }
                hubOpen = true
            // `BotsDemoRoster` stands four demo bots in front of the model; against a seeded backend the real roster loads.
            case "bots":
                if !seededLive { BotsDemoRoster.seed() }
                mode = .bots
            case "bots-hub":
                if !seededLive {
                    app.seedDemoThreads()
                    BotsDemoRoster.seed()
                }
                mode = .bots
                hubOpen = true
            // `home-first-run` clears the profile list in memory, and must never meet the seed arguments above.
            case "home-first-run":
                app.profiles = []
                path = []
            // `-hermesSeedEditorAddress <addr>` pre-fills the address so the as-you-type probe runs against whatever stub is listening.
            case "backend-editor": seedPath([.settings, .settingsBackend])
            // The demo banner, on each of the four surfaces BUG-118 named.
            case "demo-chat", "demo-home", "demo-hub", "demo-settings":
                await app.enterDemo()
                // Let the requested demo transcript land before overriding it.
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                switch route {
                case "demo-home": path = []
                case "demo-hub":
                    path = []
                    hubOpen = true
                case "demo-settings": seedPath([.settings])
                default: break
                }
            case "settings": seedPath([.settings])
            case "appearance": seedPath([.settings, .settingsAppearance])
            case "settings-model": seedPath([.settings, .settingsScreen(.modelReasoning)])
            // The model rows with a stood-in document, and the two editors opened on arrival.
            case "settings-model-demo":
                app.settings.seedDocumentForScreenshots(ModelSettingsDemo.document)
                seedPath([.settings, .settingsScreen(.modelReasoning)])
            case "settings-model-picker":
                app.settings.seedDocumentForScreenshots(ModelSettingsDemo.document)
                ModelSettingsDemo.autoOpenKey = "model"
                seedPath([.settings, .settingsScreen(.modelReasoning)])
            case "settings-fallbacks":
                app.settings.seedDocumentForScreenshots(ModelSettingsDemo.document)
                ModelSettingsDemo.autoOpenKey = "fallback_providers"
                seedPath([.settings, .settingsScreen(.modelReasoning)])
            case "settings-safety": seedPath([.settings, .settingsScreen(.safety)])
            case "settings-memory": seedPath([.settings, .settingsScreen(.memory)])
            case "settings-workspace": seedPath([.settings, .settingsScreen(.workspace)])
            case "settings-advanced": seedPath([.settings, .settingsScreen(.advanced)])
            case "settings-transcript": seedPath([.settings, .settingsScreen(.transcript)])
            case "settings-voice": seedPath([.settings, .settingsScreen(.voice)])
            case "settings-notifications": seedPath([.settings, .settingsScreen(.notifications)])
            case "settings-about": seedPath([.settings, .settingsScreen(.about)])
            case "settings-capabilities": seedPath([.settings, .settingsScreen(.capabilities)])
            case "settings-artifacts": seedPath([.settings, .settingsScreen(.artifacts)])
            case "settings-messaging": seedPath([.settings, .settingsScreen(.messaging)])
            case "settings-chat": seedPath([.settings, .settingsScreen(.chat)])
            case "commandcenter", "commandcenter-live": seedPath([.commandCenter])
            case "transcript":
                let demo = ThreadRoute.new(UUID())
                // The control the other traced routes are read against: eight rows is barely a transcript, so this run prices the launch itself.
                ColdOpenTrace.startStallProbe()
                ColdOpenTrace.begin("transcript")
                app.chat(for: demo).seedDemoTranscript()
                seedPath([.thread(demo)])
                ColdOpenTrace.mark("path.seeded")
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    ColdOpenTrace.report("transcript")
                }
            // BUG-121: the cold-open spinner held on screen, built exactly as `transcript` so the only difference between the two captures is what the transcript draws.
            case "transcript-loading":
                let loading = ThreadRoute.new(UUID())
                app.chat(for: loading).seedLoadingState()
                seedPath([.thread(loading)])
            case "markdown":
                // BUG-124: every prose shape in one reply.
                let showcase = ThreadRoute.new(UUID())
                app.chat(for: showcase).seedMarkdownShowcase()
                seedPath([.thread(showcase)])
            case "transcript-long":
                // BUG-016's repro shape: 60 short rows, most never laid out, which is the state `.defaultScrollAnchor(.bottom)` estimates a content height for.
                let long = ThreadRoute.new(UUID())
                ColdOpenTrace.startStallProbe()
                ColdOpenTrace.begin("transcript-long")
                app.chat(for: long).seedLongDemoTranscript()
                ColdOpenTrace.mark("seeded", "entries=60")
                seedPath([.thread(long)])
                ColdOpenTrace.mark("path.seeded")
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    ColdOpenTrace.report("transcript-long")
                }
            // BUG-123's cost shape: fills the window, carries what a tool-heavy session leaves behind, and arrives through `applyTranscript` so the projection and its redaction are on the clock.
            // `-sync` seeds on the main actor and the plain route seeds off it; run both to read the difference.
            case "transcript-huge", "transcript-huge-sync":
                let huge = ThreadRoute.new(UUID())
                let chat = app.chat(for: huge)
                // Built before the clock starts: assembling a fixture page is not part of what a cold open pays for.
                let page = ChatModel.toolHeavyTranscriptPage()
                ColdOpenTrace.startStallProbe()
                ColdOpenTrace.begin(route)
                ColdOpenTrace.mark("fetch.returned", "rows=\(page.messages.count)")
                if route == "transcript-huge-sync" {
                    chat.seedFixturePageOnMain(page)
                } else {
                    await chat.seedFixturePageOffMain(page)
                }
                seedPath([.thread(huge)])
                ColdOpenTrace.mark("path.seeded")
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    ColdOpenTrace.report(route)
                }
            case "transcript-windowed":
                // BUG-122's repro shape: past two windows, so the `Show N earlier messages` row is on screen at open and one tap still leaves a count behind.
                let windowed = ThreadRoute.new(UUID())
                app.chat(for: windowed).seedWindowedDemoTranscript()
                seedPath([.thread(windowed)])
            // The automation line's fixtures: a goal, a loop and a heartbeat plus two background processes on a demo transcript; `automation-sheet` and `processes-sheet` also open the matching sheet.
            case "automation", "automation-sheet", "processes-sheet":
                let demo = ThreadRoute.new(UUID())
                let chat = app.chat(for: demo)
                chat.seedDemoTranscript()
                chat.seedDemoAutomation()
                seedPath([.thread(demo)])
                if route != "automation" {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        harnessStripSheet = HarnessStripSheet(kind: route == "automation-sheet" ? .automation : .processes, chat: chat)
                    }
                }
            case "media-showcase":
                // A sent photo as the store persists it, a clip the phone plays, and a container it does not.
                let media = ThreadRoute.new(UUID())
                await MediaShowcase.prime()
                app.chat(for: media).seedFixturePageOnMain(MediaShowcase.page())
                seedPath([.thread(media)])
            case "approval", "approval-short":
                // The prompt has to arrive after ChatView is mounted: the sheet is presented by an `onChange`, and a prompt already in place at mount is an initial value, not a change.
                let demo = ThreadRoute.new(UUID())
                let chat = app.chat(for: demo)
                chat.seedDemoTranscript()
                seedPath([.thread(demo)])
                Task { @MainActor in
                    // A sheet presented while the interface-orientation transition is still running is dropped on the floor.
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    chat.seedDemoApproval(gated: route == "approval")
                }
            default: break
            }
            return
        }
        // Connected-state validation: seed a live-gateway profile from launch arguments.
        if let seeded = await app.applySeedArgumentsIfPresent() {
            await app.activate(profileID: seeded, connect: true)
            return
        }
        #endif
        // A persisted active id that no longer names a row is cleared before anything reads it.
        app.reconcileActiveProfile()
        guard let profileID = app.signedInProfile?.id else { return }
        await app.activate(profileID: profileID, connect: true)
    }

    /// A multi-element path assigned in one transaction while the NavigationStack is still mounting is silently dropped; push progressively, one element per transaction.
    private func seedPath(_ newPath: [AppRoute]) {
        guard let first = newPath.first else { return }
        path = [first]
        guard newPath.count > 1 else { return }
        Task { @MainActor in
            for element in newPath.dropFirst() {
                try? await Task.sleep(nanoseconds: 350_000_000)
                path.append(element)
            }
        }
    }

    #if DEBUG
    /// Screenshot harness: `-hermesScreenshotOrientation landscape|landscapeRight|portrait`.
    ///
    /// The scene may not be attached on the first pass of `.task`, so this retries briefly rather than silently shooting portrait.
    @MainActor
    private static func applyScreenshotOrientation() async {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-hermesScreenshotOrientation"),
              index + 1 < arguments.count else { return }
        let orientations: UIInterfaceOrientationMask
        switch arguments[index + 1] {
        case "landscape", "landscapeLeft": orientations = .landscapeLeft
        case "landscapeRight": orientations = .landscapeRight
        case "portrait": orientations = .portrait
        default: return
        }
        for _ in 0..<20 {
            if let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState != .unattached }) {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations))
                // The root controller caches its supported set; without this the request is honoured only until the next layout pass.
                scene.keyWindow?.rootViewController?
                    .setNeedsUpdateOfSupportedInterfaceOrientations()
                // A request issued while the window is still being handed its first geometry is silently dropped; asking twice costs nothing.
                try? await Task.sleep(nanoseconds: 500_000_000)
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations))
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private static var screenshotRoute: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-hermesScreenshotRoute"),
              index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
    #endif
}

/// The compact-width hub drawer's lift: the shade it casts on the scrim past its trailing edge.
enum HubDrawer {
    static let liftWidth: CGFloat = 12
    static let liftOpacity: Double = 0.18
}
