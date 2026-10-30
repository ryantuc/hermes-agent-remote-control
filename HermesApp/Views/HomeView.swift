import HermesServeKit
import SwiftUI

/// Home's chrome constants, stated as data so BUG-063's three claims are assertable without hosting a view.
enum HomeChrome {

    /// BUG-063: two `Spacer`s only centre what is between them when the two ends weigh the same.
    static let slotWidth: CGFloat = Hit.min

    /// The live/activity slot and the mode control. The live slot is reserved when nothing is running, so this count does not change with state.
    static let trailingSlots = 2

    /// The hamburger, and since BUG-063 a mirror slot that pays for the second trailing control.
    static let leadingSlots = 2

    static var leadingWidth: CGFloat { CGFloat(leadingSlots) * slotWidth }
    static var trailingWidth: CGFloat { CGFloat(trailingSlots) * slotWidth }

    /// The wordmark, which is Desktop's — the capitals and the letter-spacing are both Desktop's and not an interpretation.
    static let wordmark = "HERMES AGENT"

    /// Desktop's `tracking-[0.08em]`, held as a ratio rather than a constant because this mark is drawn at two sizes.
    static let wordmarkTrackingRatio: CGFloat = 0.08

    /// The wordmark's ink: Desktop's `text-midground dark:text-foreground/90` (`apps/desktop/src/components/chat/wordmark.tsx`), a mid rung in light and nearly the foreground in dark. It was `text1` at 15 %, a ghost that made the empty Home read as a screen that had not loaded.
    static func wordmarkInk(_ t: HermesTokens, scheme: ColorScheme) -> Color {
        scheme == .dark ? t.text1.opacity(0.9) : t.text3
    }

    /// The name on the first screen, which is the app's own and not the agent's.
    static let appMark = "HARC"

    /// One line, under the mark, on the first-run screen only.
    static let appTagline = "Remote control for Hermes Agent"

    /// What the first-run screen says a person needs before Connect can work, since the app is a client and does nothing on its own.
    static let firstRunRequirement = "To start, you need Hermes Agent running on a computer this iPhone can reach, on the same Wi-Fi or over a private network, and that computer's address."

    static let getHermesAgentTitle = "Get Hermes Agent"

    /// The agent's own public project page, which explains how to install and run it.
    static let getHermesAgentURL = URL(string: "https://github.com/NousResearch/hermes-agent")
}

/// The quiet link row on the first-run screen; a `nil` URL draws nothing at all.
enum FirstRunLinkRow: String, CaseIterable, Identifiable {
    case github
    case privacyPolicy
    case support

    var id: String { rawValue }

    var title: String {
        switch self {
        case .github: return "GitHub"
        case .privacyPolicy: return "Privacy"
        case .support: return "Support"
        }
    }

    func url(github: URL?, privacyPolicy: URL?, support: URL?) -> URL? {
        switch self {
        case .github: return github
        case .privacyPolicy: return privacyPolicy
        case .support: return support
        }
    }

    /// The rows with a destination, in order.
    static func visibleRows(
        github: URL? = HermesLinks.github,
        privacyPolicy: URL? = HermesLinks.privacyPolicy,
        support: URL? = HermesLinks.support
    ) -> [FirstRunLinkRow] {
        visibleLinks(github: github, privacyPolicy: privacyPolicy, support: support).map(\.row)
    }

    /// What the first-run screen draws: each row with the URL it is drawn with, from the same values that decided it exists (BUG-146; the view used to decide here and then re-read `HermesLinks` for the URL, so an injected link drew an empty slot).
    static func visibleLinks(
        github: URL? = HermesLinks.github,
        privacyPolicy: URL? = HermesLinks.privacyPolicy,
        support: URL? = HermesLinks.support
    ) -> [FirstRunLink] {
        allCases.compactMap { row in
            row.url(github: github, privacyPolicy: privacyPolicy, support: support).map { FirstRunLink(row: row, url: $0) }
        }
    }
}

/// One drawn first-run link.
struct FirstRunLink: Identifiable, Equatable {
    let row: FirstRunLinkRow
    let url: URL

    var id: String { row.id }
}

/// Home's empty-state mark, drawn once and used at both of its sizes.
///
/// Desktop scales this to fit its column; the phone takes the floor rather than the fit, since a mark that grew would fight the composer for height.
@MainActor
private struct HomeWordmark: View {
    @Environment(\.hermes) private var t
    @Environment(\.colorScheme) private var scheme

    let style: HermesTextStyle

    var body: some View {
        Text(HomeChrome.wordmark)
            .font(style)
            .tracking(style.size * HomeChrome.wordmarkTrackingRatio)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            // The mark is decoration over the composer, not a heading.
            .accessibilityHidden(true)
            .foregroundStyle(HomeChrome.wordmarkInk(t, scheme: scheme))
    }
}

/// The launch destination: a new conversation, not the history.
@MainActor
struct HomeView: View {
    @Environment(\.hermes) private var t
    @Environment(AppModel.self) private var app

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// Landscape on a phone — horizontal size class cannot tell the two postures apart, so compact height is what "the viewport is short" means.
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    @Binding var path: [AppRoute]
    @Binding var hubOpen: Bool
    /// Which top-level surface the shell is on; the switch itself is `RootView`'s.
    @Binding var mode: AppMode
    /// Performed when the mode control is tapped; the route arithmetic lives in `RootView`.
    let onToggleMode: () -> Void

    /// The draft conversation this screen's composer feeds, owned by `RootView` so a mode switch cannot reset it to a fresh empty `ChatModel`.
    @Binding var draftRoute: ThreadRoute

    /// The running-session picker the live dot presents: a sheet, because a sheet cannot dismiss to anywhere but the screen that presented it.
    @State private var livePickerOpen = false
    /// The session the picker chose, held until the sheet is off screen — a navigation performed while the sheet is still up is the one SwiftUI drops.
    @State private var pendingLiveSession: SessionSummary?

    /// The backend editor, presented from the first-run screen.
    @State private var isAddingBackend = false

    #if DEBUG
    /// One shot per process: the seed prompt must not re-fire on reconnect.
    @MainActor private static var seedPromptFired = false
    #endif

    private var draftModel: ChatModel { app.chat(for: draftRoute) }

    var body: some View {
        Group {
            if app.needsBackend {
                firstRunBody
            } else {
                connectedBody
            }
        }
        .background(t.canvas)
        .toolbar(.hidden, for: .navigationBar)
        // The editor sheet opens from here rather than two screens deep: someone with zero backends has no list to choose from.
        .sheet(isPresented: $isAddingBackend) {
            ProfileEditorView(profile: BackendProfile())
        }
        .sheet(isPresented: $livePickerOpen, onDismiss: openPendingLiveSession) {
            LiveSessionPickerSheet { pendingLiveSession = $0 }
        }
        // Promote on the send, not on session creation: waiting for `session.create` would paint the first steps of the send into a transcript nobody can see.
        // FEAT-040: a slash command's Send counts too. Its output and its refusals are written to the thread's transcript and error row, and Home renders neither.
        .onChange(of: draftModel.hasStartedSubmission) { _, sending in
            guard sending else { return }
            let promoted = draftRoute
            path.append(.thread(promoted))
            draftRoute = .new(UUID())
            // `draftModel` reads through `draftRoute`, which was just replaced, so this seeds the new draft and not the promoted one.
            seedDraftProject()
        }
        .onAppear { seedDraftProject() }
        // A backend switch drops the cached chats, so the draft re-seeds from the new profile's key.
        .onChange(of: app.activeProfileID) { _, _ in seedDraftProject() }
        #if DEBUG
        // Validation harness: `-hermesSeedPrompt <text>` sends one real turn once the seeded backend connects; `-hermesSeedPromptDelay <s>` defers the send.
        .task(id: app.connectionState.isOpen) {
            guard app.connectionState.isOpen, !Self.seedPromptFired else { return }
            let arguments = ProcessInfo.processInfo.arguments
            guard let index = arguments.firstIndex(of: "-hermesSeedPrompt"),
                  index + 1 < arguments.count else { return }
            Self.seedPromptFired = true
            if let delayIndex = arguments.firstIndex(of: "-hermesSeedPromptDelay"),
               delayIndex + 1 < arguments.count,
               let seconds = Double(arguments[delayIndex + 1]) {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
            // `-hermesSeedModel <slug>` rides the draft override into `session.create`, so a live test picks a model without rewriting the backend's stored default.
            if let modelIndex = arguments.firstIndex(of: "-hermesSeedModel"),
               modelIndex + 1 < arguments.count {
                draftModel.draftModelSlug = arguments[modelIndex + 1]
            }
            if let providerIndex = arguments.firstIndex(of: "-hermesSeedModelProvider"),
               providerIndex + 1 < arguments.count {
                draftModel.draftProviderSlug = arguments[providerIndex + 1]
            }
            draftModel.draft = arguments[index + 1]
            draftModel.sendTapped()
        }
        #endif
    }

    // MARK: The two bodies

    /// Home: top bar, connection banner, wordmark, resume strip, composer.
    private var connectedBody: some View {
        // BUG-040, the same measurement `ChatView` takes: the draft composer grows on this screen too.
        ComposerViewport { viewport in
            VStack(spacing: 0) {
                topBar

                if !app.connectionState.isOpen {
                    ConnectionBannerView(
                        state: app.connectionState,
                        detail: app.connectionError,
                        onRetry: { Task { await app.connect() } },
                        onOpenSettings: { path.append(contentsOf: [.settings, .settingsBackend]) }
                    )
                }

                // The canvas is the screen's keyboard dismissal gesture: this body is a VStack, so `.scrollDismissesKeyboard` has nothing to attach to.
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    wordmark
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { Keyboard.dismiss() }

                // Landscape: composer and resume strip cap at 640 pt and centre; a no-op at phone widths.
                VStack(spacing: 0) {
                    resumeStrip
                    // A command refused on Home stays on Home (it never raises `hasStartedSubmission`), so its refusal is read here, as in a conversation's dock.
                    if let error = draftModel.errorMessage {
                        HomeErrorRow(
                            message: error,
                            // The keyboard goes first, as Send puts it away on Home before a send carries the draft into its conversation.
                            sendAsText: ComposerSendAsText.isOffered(for: draftModel) ? {
                                Keyboard.dismiss()
                                ComposerSendAsText.send(draftModel)
                            } : nil
                        )
                    }
                    ComposerView(model: draftModel, viewportHeight: viewport)
                    if let reason = app.noBackendSendReason {
                        sendBlockedReason(reason)
                    }
                }
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
        }
        // BUG-118: `ComposerViewport` pins content to the bottom, so overflow escapes off the top, which on Home is the status bar.
        .clipped()
    }

    // MARK: Top bar — 52 pt, no background, no hairline

    private var topBar: some View {
        HStack(spacing: Space.s4) {
            if horizontalSizeClass == .regular {
                // The rail is already open — the button is removed, not disabled; the clear slot keeps the chips centred.
                Color.clear.frame(width: Hit.min, height: Hit.min)
            } else {
                HomeMenuButton { hubOpen = true }
            }

            // BUG-063: the mirror slot that pays for the second trailing control, a sibling of the hamburger rather than a wider frame on it, which would have doubled its hit box.
            Color.clear
                .frame(width: HomeChrome.slotWidth, height: HomeChrome.slotWidth)
                .accessibilityHidden(true)

            Spacer(minLength: 0)
            // The pick lands on the draft and rides `session.create(cwd:)` at first send.
            WorkspaceChips(cwd: draftModel.draftCwd ?? seededCwd) { picked in
                await draftModel.applyCwd(picked)
            }
            Spacer(minLength: 0)

            // The live slot is reserved when nothing is running: without the clear box the chips would jump 52 pt sideways the moment a session started or finished.
            if hasLiveSession {
                liveIndicator
            } else {
                Color.clear.frame(width: Hit.min, height: Hit.min)
            }
            HomeModeControlButton(mode: mode, action: onToggleMode)
        }
        .homeBarRow()
    }

    private var hasLiveSession: Bool {
        app.hasVisibleLiveSession
    }

    /// The dot presents the list of what is running, over Home, and the row that is picked is the only thing that ends up on the stack.
    private var liveIndicator: some View {
        Button {
            HomeLiveIndicator.open(pickerOpen: &livePickerOpen, path: &path)
        } label: {
            PulsingDot(color: t.warn, size: 9)
        }
        .buttonStyle(HomeBarButtonStyle())
        .accessibilityLabel("A session is running")
        .accessibilityHint("Lists the sessions running now")
    }

    /// The jump the picker asked for, made once its sheet is off screen.
    private func openPendingLiveSession() {
        guard let session = pendingLiveSession else { return }
        pendingLiveSession = nil
        LiveSessionPicker.open(session, path: &path)
    }

    // MARK: Wordmark — the empty state

    private var wordmark: some View {
        VStack(spacing: Space.s3) {
            // Landscape: the wordmark steps down to `title` so it yields height to the composer in a short viewport.
            HomeWordmark(style: verticalSizeClass == .compact ? HermesFont.title : HermesFont.display)
            if let name = backendName {
                Text(name)
                    .font(HermesFont.caption)
                    .foregroundStyle(t.text3)
            }
        }
        .accessibilityHidden(true)
    }

    /// One computed name on the model, which says "Demo" for the length of the demo.
    private var backendName: String? { app.backendDisplayName }

    // MARK: First run — the screen a fresh install opens on (FEAT-030 §2)

    /// One calm screen, shown only while `app.needsBackend`; a configured-but-unreachable backend is the connection banner's job.
    private var firstRunBody: some View {
        VStack(spacing: 0) {
            firstRunBar
            // Centred when it fits, scrollable when it does not: a plain `VStack` would put the buttons off the bottom edge at the largest type sizes.
            GeometryReader { proxy in
                ScrollView {
                    firstRunContent
                        .frame(maxWidth: 420)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, Space.s8)
                        .padding(.vertical, Space.s8)
                        .frame(minHeight: proxy.size.height, alignment: .center)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
    }

    private var firstRunContent: some View {
        VStack(spacing: Space.s5) {
            VStack(spacing: Space.s3) {
                Text(HomeChrome.appMark)
                    .font(HermesFont.display)
                    .tracking(HermesFont.display.size * HomeChrome.wordmarkTrackingRatio)
                    .foregroundStyle(t.text1)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(HomeChrome.appTagline)
                    .font(HermesFont.subhead)
                    .foregroundStyle(t.text3)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, Space.s4)

            Text(AppModel.backendExplainer)
                .font(HermesFont.subhead)
                .foregroundStyle(t.text3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text(HomeChrome.firstRunRequirement)
                .font(HermesFont.subhead)
                .foregroundStyle(t.text2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("firstrun.requirement")

            if let url = HomeChrome.getHermesAgentURL {
                Link(destination: url) {
                    HStack(spacing: Space.s2) {
                        Text(HomeChrome.getHermesAgentTitle)
                        Image(systemName: "arrow.up.right")
                            .imageScale(.small)
                            .accessibilityHidden(true)
                    }
                    .font(HermesFont.subhead)
                    .foregroundStyle(t.action)
                }
                .frame(minHeight: Hit.min)
                .accessibilityIdentifier("firstrun.getHermesAgent")
            }

            Button("Connect a backend") {
                isAddingBackend = true
            }
            .buttonStyle(PrimaryButtonStyle())
            .frame(maxWidth: 260)
            .accessibilityIdentifier("firstrun.connect")
            .padding(.top, Space.s4)

            Button("Try the demo") {
                Task { await app.enterDemo() }
            }
            .buttonStyle(SecondaryButtonStyle(height: Hit.commit))
            .frame(maxWidth: 260)
            .accessibilityIdentifier("demo.enter.home")

            Text(AppModel.demoInvitation)
                .font(HermesFont.footnote)
                .foregroundStyle(t.text3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            firstRunLinks
                .padding(.top, Space.s9)
        }
    }

    /// The first-run screen's only chrome: a gear, trailing — no hamburger, since the hub has nothing to say with no backend. It stands on the same glass disc as Home's controls, in the same ink, so the first screen's bar is the bar the rest of the app wears.
    private var firstRunBar: some View {
        HStack(spacing: Space.s4) {
            Spacer(minLength: 0)
            Button {
                path.append(.settings)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: HomeModeControl.glyphSize, weight: .medium))
                    .foregroundStyle(t.text1)
            }
            .buttonStyle(HomeBarButtonStyle())
            .accessibilityLabel("Settings")
            .accessibilityIdentifier("firstrun.settings")
        }
        .homeBarRow()
    }

    /// GitHub · Privacy · Support, rendered only where a URL exists.
    private var firstRunLinks: some View {
        let links = FirstRunLinkRow.visibleLinks()
        return HStack(spacing: Space.s3) {
            ForEach(Array(links.enumerated()), id: \.element.id) { index, link in
                if index > 0 {
                    Text("·")
                        .font(HermesFont.footnote)
                        .foregroundStyle(t.text4)
                        .accessibilityHidden(true)
                }
                Link(destination: link.url) {
                    Text(link.row.title)
                        .font(HermesFont.footnote)
                        .foregroundStyle(t.text3)
                }
                .frame(minHeight: Hit.min)
                .accessibilityIdentifier("firstrun.link.\(link.row.rawValue)")
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// The reason the send is dead, under the composer that carries it rather than only in the banner one row up.
    private func sendBlockedReason(_ reason: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s3) {
            Image(systemName: "exclamationmark.circle")
                .font(HermesFont.footnote)
                .foregroundStyle(t.text3)
                .accessibilityHidden(true)
            Text(reason)
                .font(HermesFont.footnote)
                .foregroundStyle(t.text3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.s6)
        .padding(.bottom, Space.s5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: Resume strip

    /// Up to two rows directly above the composer: the running session, then the most recently touched one.
    @ViewBuilder
    private var resumeStrip: some View {
        let rows = resumeRows
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader("Continue")
                ForEach(rows) { thread in
                    let waiting = waitingKind(for: thread)
                    Button {
                        path.append(.thread(.existing(thread)))
                    } label: {
                        FlatRow {
                            HStack(spacing: Space.s3) {
                                // A parked question is shown whatever `session.active_list` says, because the registry is the authority on it.
                                if waiting != nil || app.isLiveWorking(thread.id) {
                                    PulsingDot(color: t.warn, size: 6)
                                }
                                Text(thread.displayTitle)
                                    .font(HermesFont.callout)
                                    .foregroundStyle(t.text1)
                                    .lineLimit(1)
                            }
                        } trailing: {
                            if let waiting {
                                Text(HomeWaitingMark.label(for: waiting))
                                    .font(HermesFont.footnote)
                                    .foregroundStyle(t.warn)
                                    .lineLimit(1)
                                    .accessibilityIdentifier("home.continue.waiting")
                            } else if app.isLiveWorking(thread.id) {
                                // The fraction comes from the turn engine's own plan and is absent, not `0/0`, until a plan has arrived.
                                Text(liveDetail(for: thread.id))
                                    .font(HermesFont.footnote)
                                    .hermesNumeric()
                                    .foregroundStyle(t.warn)
                            } else {
                                Text(RelativeTime.short(epochSeconds: thread.lastActive))
                                    .font(HermesFont.footnote)
                                    .hermesNumeric()
                                    .foregroundStyle(t.text3)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, Space.s4)
        }
    }

    private var resumeRows: [SessionSummary] {
        app.continueRows()
    }

    /// BUG-062 C. What this row's session is waiting on, from the current-request registry; the `session.active_list` join is read here, at render, because that list moves on its own poll.
    private func waitingKind(for thread: SessionSummary) -> ApprovalNotifications.PromptKind? {
        app.liveActivities.waiting.kind(storedID: thread.id, runtimeID: app.liveStatus(forStoredID: thread.id)?.id)
    }

    /// The live row's trailing text: the gateway's status word, and the step fraction when the session has a plan.
    private func liveDetail(for sessionID: String) -> String {
        let label = app.liveWorkingLabel(for: sessionID)
        guard let fraction = app.liveStepFraction(for: sessionID) else { return label }
        return "\(label) · \(fraction)"
    }

    // MARK: Last-used project (FEAT-001)

    /// What a fresh draft's chip shows before anything is picked: the last project picked on this backend, or the backend's own default when nothing is remembered.
    private var seededCwd: String {
        LastProjectStore.remembered(profileID: app.activeProfileID) ?? app.defaultCwd
    }

    /// Put the remembered project on the draft, not just on the chip: `session.create(cwd:)` reads `ChatModel.draftCwd`, so a seed that stopped at the chip would create the session elsewhere.
    private func seedDraftProject() {
        guard draftModel.draftCwd == nil,
              let remembered = LastProjectStore.remembered(profileID: app.activeProfileID)
        else { return }
        draftModel.draftCwd = remembered
    }
}

/// BUG-062 C, Home's half: the mark a Continue row wears while its session waits on the person holding the phone.
///
/// Keyed off the current-request registry through `WaitingSessions`, not `session.active_list`, whose `waiting` word an approval-blocked session never reports.
enum HomeWaitingMark {
    static func label(for kind: ApprovalNotifications.PromptKind) -> String {
        // A Desktop-only request cannot be answered from this phone, so the row does not ask for an answer.
        switch kind {
        case .desktop: return "Continue in Desktop"
        case .signIn: return "Sign in needed"
        default: return "Needs your answer"
        }
    }
}
