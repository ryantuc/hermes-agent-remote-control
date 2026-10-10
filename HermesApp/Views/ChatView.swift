import HermesServeKit
import SwiftUI
import UIKit

/// One conversation.
@MainActor
struct ChatView: View {
    @Environment(\.hermes) private var t
    @Environment(AppModel.self) private var app
    let model: ChatModel
    /// A grammar the caller pinned; nil in every shipping call site, where the thread decides.
    let style: TranscriptStyle?
    /// BUG-141: how a refused-because-owned-elsewhere bubble starts a fresh conversation. Nil outside `RootView`.
    let onStartNewChat: (() -> Void)?

    init(model: ChatModel, style: TranscriptStyle? = nil, onStartNewChat: (() -> Void)? = nil) {
        self.model = model
        self.style = style
        self.onStartNewChat = onStartNewChat
    }

    /// Set by the sheet's Minimise action; minimising does not answer, the request stays queued.
    @State private var isPromptMinimised = false
    /// BUG-076: a blocking prompt waits until the presentation host reports that every sibling has left the hierarchy.
    @State private var blockingPromptPresentationReady = false
    @State private var showingSessionSheet = false
    // The popover dismisses first and the sheet or alert is raised afterwards, because a presentation started while another is still dismissing is dropped.
    @State private var showingOverflow = false
    @State private var showingRecoveryInfo = false
    @State private var queuedOverflowAction: ChatOverflowAction?
    @State private var showingRename = false
    @State private var renameText = ""
    @State private var showingProjectPicker = false
    @State private var showingTimeline = false
    /// A prompt the person chose in the timeline sheet; the transcript's own modifiers carry it out, because the scroll proxy lives there.
    @State private var jumpTarget: TranscriptJump?
    /// The header's second line: one `projects.for_cwd` per working directory.
    @State private var projectSubtitle = ChatProjectSubtitleModel()
    /// Whether the bottom sentinel is on screen, within `TranscriptScroll.Geometry.slack`; the scroll-to-latest disc shows while it is not. The follow decision reads `isFollowing`, which also keeps a reader the content carried past the slack.
    @State private var isNearBottom = true
    /// The trailing scroll a burst of content growth earns.
    @State private var followSettle = TranscriptScroll.FollowSettle()
    /// The sentinel's bottom edge in the scroll view's own coordinate space; zero until it has reported once.
    @State private var sentinel = TranscriptScroll.SentinelReading()
    /// Starts `true` so a body built before `onAppear` ever runs paints normally.
    @State private var hadRowsOnAppear = true
    @State private var pushTransitionEnded = false
    @State private var hasArmedPushGate = false
    @State private var transcriptViewportHeight: CGFloat = 0
    /// How many entries beyond `TranscriptScroll.Window.size` the reader has asked to see, keyed to the chat so a re-bound `ChatView` does not inherit another conversation's reveal.
    @State private var revealedEarlier = 0
    @State private var revealedEarlierFor: ObjectIdentifier?
    /// BUG-007: the initial-placement latch, keyed to the chat because SwiftUI may re-bind this struct to a different `ChatModel` while keeping this `@State` storage, and latched on the outcome rather than on the decision to scroll.
    @State private var placement = TranscriptScroll.Placement<ObjectIdentifier>()
    /// BUG-050: the coalescer that turns a burst of chrome transitions into one tail reassertion.
    @State private var chromeReassert = TranscriptScroll.ChromeReassert()
    /// The transcript container's own height, debounced so one keyboard animation's intermediate heights become a single re-placement.
    @State private var containerHeight = TranscriptScroll.ContainerHeight()
    /// Whether the reader took themselves off the tail; a re-placement must never yank somebody who scrolled back and then tapped the composer.
    @State private var tailLatch = TranscriptScroll.TailLatch()
    /// BUG-051: the transcript's `UIScrollView`, so a deliberate one-shot tap can stop a flick instead of losing to it. Nil until the transcript has been in a window, and harmless nil.
    @State private var momentum = TranscriptMomentum()
    /// The header chip's avatar bytes.
    @State private var headerAvatar: Data?
    @State private var branchTarget: ChatEntry?
    @State private var branchName = ""
    @State private var retryTarget: ChatEntry?

    private let bottomAnchor = "hermes.transcript.bottom"
    /// The scroll view's own coordinate space, which the bottom sentinel measures its edge against.
    private static let transcriptSpace = "hermes.transcript.viewport"

    // MARK: Which grammar this thread speaks

    /// Who this thread belongs to, when it belongs to a bot; set at construction so the grammar is decided on the first frame.
    private var botIdentity: BotThreadIdentity {
        BotThreadIdentity(profile: model.botProfile, displayName: model.botDisplayName)
    }

    private var resolvedStyle: TranscriptStyle {
        #if DEBUG
        if let override = Self.screenshotStyleOverride { return override }
        #endif
        return TranscriptStyle.resolve(explicit: style, botProfile: botIdentity.profile)
    }

    /// The header's identity in `.conversation`; `model.title` would read "Bot Chat" for every bot, because a session's title is the registry key.
    private var conversationTitle: String {
        let name = botIdentity.displayName ?? ""
        return name.isEmpty ? model.title : name
    }

    var body: some View {
        // BUG-040: the composer is capped against the room this screen actually has, and the stack is pinned to that room bottom-first, so nothing below the transcript can be pushed under the keyboard.
        // These rows are the transcript's siblings and not a bottom `safeAreaInset` on it: a scroll view's content offset does not follow a growing bottom inset, so the composer would rise over the conversation instead of the conversation rising ahead of it (BUG-014).
        ComposerViewport { viewport in
            VStack(spacing: 0) {
                // BUG-016: the transcript's width comes from outside its scroll view, because a vertical scroll view lets its content set the width on the cross axis.
                GeometryReader { geometry in
                    transcript(width: geometry.size.width)
                }
                bottomChromeStack(viewport: viewport)
            }
        }
        // One writer, one read: everything below reads this key and nothing else ever sets it.
        .environment(\.transcriptStyle, resolvedStyle)
        .environment(\.mediaProfile, model.mediaProfile)
        // BUG-120: paint the home-indicator well and only that well; a bare `.ignoresSafeArea()` would put this surface into the keyboard's inset negotiation.
        // The top edge too, so the frost under the bar blurs the theme's canvas and not the system background behind the hosting view. A background, so it moves no layout.
        .background {
            t.canvas
            .ignoresSafeArea(ChatChrome.homeIndicatorEscape, edges: [.top, .bottom])
        }
        .navigationBarTitleDisplayMode(.inline)
        .chatGlassNavigationBar()
        .toolbar {
            ToolbarItem(placement: .principal) { conversationHeader }
            ToolbarItem(placement: .topBarTrailing) {
                if let notice = model.historyRecoveryNotice {
                    recoveryInfoButton(notice: notice)
                }
            }
            ToolbarItem(placement: .topBarTrailing) { overflowButton }
        }
        // iOS 26 treats a `.topBarLeading` title as an action and wraps it in Liquid Glass; the editor role gives principal titles the native leading alignment without converting this label into a button.
        .toolbarRole(.editor)
        .safeAreaInset(edge: .top, spacing: 0) {
            topBanners
        }
        // After the banner's inset, so the frost fills the bar and ends where the bar ends.
        .chatGlassTopPlane()
        // BUG-121: sample whether there is anything to draw at the instant the push starts, once per view identity, because `onAppear` fires again when a sheet is dismissed.
        .onAppear {
            guard !hasArmedPushGate else { return }
            hasArmedPushGate = true
            hadRowsOnAppear = !model.entries.isEmpty
            guard !hadRowsOnAppear else { return }
            Task { @MainActor in
                try? await Task.sleep(
                    nanoseconds: UInt64(TranscriptScroll.PushGate.settleDelay * 1_000_000_000)
                )
                pushTransitionEnded = true
            }
        }
        // Keyed on the chat because SwiftUI re-binds this struct to a different `ChatModel` while keeping the view's identity; a bare `.task` would never open the second chat.
        .task(id: ObjectIdentifier(model)) {
            showingRecoveryInfo = false
            ColdOpenTrace.mark("chatview.task")
            await model.openIfNeeded()
            ColdOpenTrace.mark("chatview.task.returned")
        }
        // Keyed on the profile because this view's `@State` survives a swap to a different `ChatModel`; an unkeyed `.task` would leave the previous bot's face in the header.
        .task(id: botIdentity.profile) {
            guard let profile = botIdentity.profile, let bots = app.bots else {
                headerAvatar = nil
                return
            }
            headerAvatar = await bots.avatarData(for: profile)
        }
        // Keyed on the socket as well as the path: a header mounted before the connection opens must resolve when it does, or it latches on the empty answer forever.
        .task(id: subtitleResolveKey) {
            await projectSubtitle.resolve(
                cwd: subtitleCwd,
                isConnected: app.connectionState.isOpen,
                forCwd: projectResolver
            )
        }
        .onChange(of: model.historyRecoveryNotice) { _, notice in
            if notice == nil { showingRecoveryInfo = false }
        }
        .sheet(isPresented: $showingSessionSheet) {
            SessionSheetView(model: model)
        }
        .alert("Rename conversation", isPresented: $showingRename) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) { }
            Button("Save") {
                let title = renameText
                if let target = renameTarget {
                    Task { await app.renameThread(target, to: title) }
                }
            }
        } message: {
            Text("Titles are stored on the backend and sync to every Hermes client.")
        }
        // Hermes has no `session.project` field: a session is in a project because its cwd sits inside that project's path, so moving one is a cwd write.
        .sheet(isPresented: $showingProjectPicker) {
            ProjectPickerSheet(currentPath: subtitleCwd) { path in
                await model.applyCwd(path)
            }
        }
        .sheet(isPresented: $showingTimeline) {
            PromptTimelineSheet(model: model) { target in jumpTarget = target }
        }
        .sheet(item: $branchTarget) { entry in
            branchSheet(entry)
        }
        .sheet(item: $retryTarget) { entry in
            retryConfirmSheet(entry)
        }
        .modifier(BlockingPromptPresentationModifier(
            model: model,
            serverIdentity: serverIdentity,
            isPromptMinimised: $isPromptMinimised,
            presentationReady: $blockingPromptPresentationReady,
            dismissSiblingPresentations: dismissSiblingPresentationsForBlockingPrompt
        ))
        // BUG-036: the status slot is one combined accessibility element and never re-announces, so the rungs are spoken here instead.
        .onChange(of: model.statusLineText) { old, new in
            TranscriptScrollLog.statusTransition(from: old, to: new)
            if let message = StatusAnnouncement.announcement(from: old, to: new) {
                StatusAnnouncement.post(message)
            }
        }
        // The 8 s honesty threshold is its own row rather than part of `statusLineText`, so it gets its own edge.
        .onChange(of: model.isSendStalled) { _, stalled in
            if stalled { StatusAnnouncement.post("No acknowledgement from \(hostName)") }
        }
    }

    // MARK: Chrome (FEAT-024)

    /// The rows under the bar: the connection banner while the socket is not open, then a question waiting in another conversation.
    private var topBanners: some View {
        VStack(spacing: 0) {
            if !app.connectionState.isOpen {
                ConnectionBannerView(
                    state: app.connectionState,
                    detail: app.connectionError,
                    onRetry: { Task { await app.connect() } },
                    onOpenSettings: nil
                )
            }
            // BUG-062 C: read from the same registry as Home's "Needs your answer".
            if let elsewhere = elsewherePrompt {
                ElsewherePromptBanner(prompt: elsewhere) { openElsewhere(elsewhere) }
                    .disabled(model.hasBlockingPrompt)
            }
        }
    }

    /// Everything between the transcript and the bottom of the screen, on one glass plane; a frost per row would stack blurs the moment a notice or a blocking prompt appeared.
    @ViewBuilder
    private func bottomChromeStack(viewport: CGFloat) -> some View {
        VStack(spacing: 0) {
            SessionActivityStrip(
                activity: model.live.activity,
                controls: model.sessionControls,
                processes: model.backgroundProcesses,
                hasBlockingPrompt: model.hasBlockingPrompt
            )

            if let notice = model.live.notice {
                NoticeSlot(notice: notice)
            }


            if let error = model.errorMessage {
                // FEAT-040: a command refused with the draft kept (`/tmp is unavailable…`) offers the way out right where the refusal is read.
                SessionErrorRow(
                    message: error,
                    sendAsText: ComposerSendAsText.isOffered(for: model) ? { ComposerSendAsText.send(model) } : nil
                )
            }

            // Desktop parity: the connection the agent is blocked on.
            if let connection = model.pendingConnection {
                ConnectionRequestCard(model: model, request: connection)
            }

            if model.hasBlockingPrompt {
                blockingPromptBar
            }

            // Desktop parity: the composer is replacing an earlier message.
            if model.editingEntryID != nil {
                EditingMessageBanner(model: model)
            }

            ComposerView(model: model, viewportHeight: viewport, chrome: .glass)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
        }
        .chatGlassChrome()
    }

    /// Two lines: who this thread is, and which project it is in. The subtitle is display only; the folder icon in the overflow is the write.
    private var conversationHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.s3) {
                if resolvedStyle == .conversation {
                    IdentityChip(
                        displayName: conversationTitle,
                        imageData: headerAvatar,
                        size: IdentityChip.headerSize
                    )
                }
                Text(resolvedStyle == .conversation ? conversationTitle : model.title)
                    .font(HermesFont.calloutStrong)
                    .foregroundStyle(t.text1)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            // Laid out in every state and never a spinner, so the bar cannot change height when the answer lands.
            Text(projectSubtitle.subtitle.headerText ?? projectSubtitle.subtitle.text)
                .font(HermesFont.caption)
                .foregroundStyle(t.text3)
                .lineLimit(1)
                .truncationMode(.tail)
                .opacity(projectSubtitle.subtitle.headerText == nil ? 0 : 1)
                .accessibilityHidden(projectSubtitle.subtitle.headerText == nil)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// Recovery details stay available without taking space from the composer.
    private func recoveryInfoButton(notice: String) -> some View {
        Button {
            showingRecoveryInfo = true
        } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(t.text3)
        }
        .accessibilityLabel("Earlier activity may be incomplete")
        .accessibilityHint("Shows conversation recovery details")
        .popover(isPresented: $showingRecoveryInfo) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Conversation history")
                    .font(.headline)
                Text(notice)
                    .font(.callout)
            }
            .padding(16)
            .frame(idealWidth: 300, maxWidth: 340, alignment: .leading)
            .presentationCompactAdaptation(.popover)
        }
        .disabled(model.hasBlockingPrompt)
    }

    /// The `⋯`, as a popover of icons rather than a `Menu`, because a SwiftUI `Menu` always renders a labelled list.
    private var overflowButton: some View {
        Button {
            showingOverflow = true
        } label: {
            Image(systemName: "ellipsis")
                .foregroundStyle(t.text1)
        }
        .accessibilityLabel("Conversation actions")
        .popover(isPresented: $showingOverflow) {
            ChatOverflowMenu(entries: overflowEntries) { action in
                // Dismiss, then present.
                queuedOverflowAction = action
                showingOverflow = false
            }
            // A sheet or an alert raised while the popover is still on screen is dropped on the floor.
            .onDisappear { fireQueuedOverflowAction() }
        }
        .disabled(model.hasBlockingPrompt)
    }

    /// Entries rather than actions: a draft's Rename is drawn disabled rather than omitted.
    private var overflowEntries: [ChatOverflowEntry] {
        ChatChrome.overflowEntries(
            isBotThread: botIdentity.profile != nil,
            isDraft: model.isDraft,
            offersTimeline: model.offersPromptTimeline
        )
    }

    private func fireQueuedOverflowAction() {
        guard let action = queuedOverflowAction else { return }
        queuedOverflowAction = nil
        switch action {
        case .details:
            showingSessionSheet = true
        case .rename:
            renameText = model.title
            showingRename = true
        case .project:
            showingProjectPicker = true
        case .timeline:
            showingTimeline = true
        }
    }

    /// Chat-owned presentations; composer and activity-strip presentations dismiss themselves from the same prompt edge.
    private func dismissSiblingPresentationsForBlockingPrompt() {
        showingRecoveryInfo = false
        showingSessionSheet = false
        showingProjectPicker = false
        showingRename = false
        showingOverflow = false
        queuedOverflowAction = nil
        branchTarget = nil
        retryTarget = nil
    }

    /// The row `AppModel.renameThread` writes against, synthesised from the stored id when the hub's list has not caught up.
    private var renameTarget: SessionSummary? {
        guard let stored = model.storedSessionID, !stored.isEmpty else { return nil }
        if let known = app.hubSessions.first(where: { $0.id == stored }) { return known }
        return SessionSummary(json: .object(["id": .string(stored)]))
    }

    /// BUG-062 C. Another conversation this phone is attached to that is waiting on the person, from the current-request registry (`LiveActivityController.waiting`).
    private var elsewherePrompt: ElsewherePrompt? {
        ElsewherePrompt.pick(
            waiting: app.liveActivities.waiting.byRuntimeID,
            currentRuntimeID: model.runtimeSessionID,
            currentStoredID: model.storedSessionID,
            storedID: { runtimeID in
                if let stored = app.chat(runtimeSessionID: runtimeID)?.storedSessionID, !stored.isEmpty { return stored }
                return app.liveStatuses.first { $0.value.id == runtimeID }?.key
            },
            title: { storedID in
                app.hubSessions.first(where: { $0.id == storedID })?.displayTitle ?? ""
            }
        )
    }

    /// Opens the waiting chat in place of this one; Back from it returns to Home, as from a branch.
    private func openElsewhere(_ prompt: ElsewherePrompt) {
        let summary = app.hubSessions.first { $0.id == prompt.storedID }
            ?? SessionSummary(json: .object(["id": .string(prompt.storedID)]))
        app.requestRoute([.thread(.existing(summary))])
    }

    /// The working directory the subtitle describes and the project picker writes to: the live session's, or the draft's seed.
    private var subtitleCwd: String {
        if let cwd = model.info?.cwd, !cwd.isEmpty { return cwd }
        return model.draftCwd ?? app.defaultCwd
    }

    private var subtitleResolveKey: String {
        "\(subtitleCwd)|\(app.connectionState.isOpen)"
    }

    /// `projects.for_cwd`, or nothing when there is no socket to make it on.
    private var projectResolver: ChatProjectSubtitleModel.ForCwd? {
        guard let api = app.projectsAPI else { return nil }
        return { try await api.forCwd($0) }
    }

    // MARK: Transcript

    private func transcript(width: CGFloat) -> some View {
        ColdOpenTrace.markOnce("transcript.body")
        // Three functions rather than one chain: the modifier chain outgrew the type checker's budget once the follow had its triggers.
        return ScrollViewReader { proxy in
            transcriptGeometry(transcriptTriggers(transcriptScroller(width: width, proxy: proxy), proxy), proxy)
        }
    }

    /// The scroll view, its content, and the modifiers that must sit directly on it.
    private func transcriptScroller(width: CGFloat, proxy: ScrollViewProxy) -> some View {
            ScrollView {
                // BUG-016: a plain `VStack` and not a `LazyVStack`, because a lazy stack lays out from an estimated content height and every anchor resolves against that estimate. The cost is bounded by `TranscriptScroll.Window`.
                VStack(alignment: .leading, spacing: Space.s7) {
                    if hiddenEarlierCount > 0 {
                        EarlierMessagesRow(hidden: hiddenEarlierCount) { revealEarlier(proxy) }
                    }

                    if transcriptIsHeld || (model.isLoading && model.entries.isEmpty) {
                        if resolvedStyle == .conversation {
                            conversationOpeningState
                        } else {
                            ProgressView("Loading conversation…")
                                .frame(maxWidth: .infinity)
                                .padding(.top, 40)
                        }
                    }

                    if let notice = model.autoContinueNotice {
                        AutoContinueRow(notice: notice) {
                            model.dismissAutoContinueNotice()
                        }
                    }

                    if transcriptIsHeld {
                        // BUG-121: laying these rows out is what stops the push transition mid-slide.
                        EmptyView()
                    } else if model.entries.isEmpty, !model.isLoading {
                        // BUG-052: `transcriptGap` is the model's answer to why there is nothing here; only one of its three causes is a new conversation.
                        switch model.transcriptGap {
                        case .unavailable:
                            TranscriptUnavailableState(model: model)
                        case .pending:
                            if resolvedStyle == .conversation {
                                conversationOpeningState
                            } else {
                                ProgressView("Loading conversation…")
                                    .frame(maxWidth: .infinity)
                                    .padding(.top, 40)
                            }
                        case .none:
                            // `ChatEmptyState` offers a resume list of other sessions, which is the wrong door out of a bot thread.
                            if resolvedStyle == .session {
                                ChatEmptyState(model: model)
                            }
                        }
                    } else if resolvedStyle == .conversation {
                        conversationRows
                    } else {
                        sessionRows
                    }

                    // The send contract's status slot and the 8 s honesty threshold; never empty between send and first token.
                    if model.isSendStalled {
                        StatusLine(
                            phase: .stalled(host: hostName),
                            onRetry: { model.retryStalledConnection() },
                            onCancel: { model.cancelStalledSend() }
                        )
                    } else if let status = model.statusLineText {
                        StatusLine(phase: .status(status))
                    }

                    // Bottom sentinel: auto-scroll follows the stream only while the reader is at the tail. It reports its own bottom edge in the scroll view's coordinate space rather than through `onAppear`, which in a plain stack would mean "exists" and never "visible".
                    // It is the stack's bottom padding as well as its last row, so its bottom edge is the content's: a scroll that lands the sentinel at the viewport's bottom lands the conversation at its true end, not a padding short of it.
                    Color.clear
                        .frame(height: 1 + Space.s5)
                        .id(bottomAnchor)
                        .background {
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: TranscriptSentinelBottomKey.self,
                                    value: geometry.frame(in: .named(Self.transcriptSpace)).maxY
                                )
                            }
                        }
                }
                .padding(.horizontal, Space.s6)
                .padding(.top, Space.s5)
                // BUG-016: pinned to the viewport, never to the content, because a plain stack reports the width of its widest child and `.frame(maxWidth:)` does not clamp a child that is already wider.
                .frame(width: TranscriptScroll.Geometry.contentWidth(viewport: width))
                .frame(maxWidth: .infinity)
                // BUG-012: tapping the transcript's content dismisses the keyboard. `simultaneousGesture` and never `onTapGesture`, so every tap target inside keeps doing what it did rather than losing the tap to an ancestor.
                .simultaneousGesture(TapGesture().onEnded { Keyboard.dismiss() })
                // BUG-012: and taps on the empty canvas, which a `VStack` has no hit shape of its own to catch. A background is hit-tested last, so it only ever sees a touch no row wanted.
                .background {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { Keyboard.dismiss() }
                }
                // BUG-051: the one way to reach the `UIScrollView` that owns this transcript's momentum, in the scroll content rather than in an overlay, because only from here does the superview chain climb into the scroll view.
                .background(alignment: .top) {
                    EnclosingScrollViewReader(momentum: momentum)
                        .frame(width: 0, height: 0)
                        .allowsHitTesting(false)
                }
                // `scrollClipDisabled` travels through the environment, so every scroller inside a row (the reasoning trace, diffs, code, tables) is handed clipping back here.
                .scrollClipDisabled(false)
            }
            // The space the sentinel measures against, directly on the scroll view, before anything that could wrap its frame.
            .coordinateSpace(name: Self.transcriptSpace)
            .background(t.canvas)
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            // Glass: rows past the scroll view's edges are drawn rather than clipped, so the conversation passes behind the top plane and the dock. Drawing only: the frame, content offset, safe area and anchor are exactly what they were, which is why this is safe where an overlay or an inset was not (BUG-016, FEAT-024 §4). Rows behind the chrome are not touchable; the chrome is on top.
            .scrollClipDisabled()
    }

    /// Everything that moves the transcript on a model or view change.
    private func transcriptTriggers(_ content: some View, _ proxy: ScrollViewProxy) -> some View {
        content
            .onChange(of: model.entries.count) { _, _ in
                applyScrollDecision(proxy)
            }
            .onChange(of: model.entries.last?.text) { _, _ in
                applyScrollDecision(proxy)
            }
            // The end-of-turn reload replaces the live rows with the persisted ones under the same count and text; the ids are what change.
            .onChange(of: model.entries.last?.id) { _, _ in
                applyScrollDecision(proxy)
            }
            // The status row is scroll content, not chrome: it comes and goes under the last reply and moves the content's end without touching any entry.
            .onChange(of: model.statusLineText) { _, _ in
                applyScrollDecision(proxy)
            }
            // The turn ending is what adds the footer row and takes the streaming indicator away, with no entry count or text changing.
            .onChange(of: model.live.isBusy) { was, busy in
                guard was, !busy else { return }
                applyScrollDecision(proxy)
            }
            // The person's own send, a steer included, always goes to the bottom: it is the one thing a reader in scrollback does that means "take me back".
            .onChange(of: model.sendPhase) { _, phase in
                guard phase == .sending else { return }
                recoverToTail(proxy)
            }
            .onChange(of: jumpTarget) { _, target in
                guard let target else { return }
                jumpTarget = nil
                jump(to: target, proxy)
            }
            // Also on appear, because a chat already cached with a populated transcript never fires either `onChange`.
            .onAppear { applyScrollDecision(proxy) }
            // BUG-121: the rows usually arrive while the gate is closed, so opening the gate is the first paint and therefore a placement trigger.
            .onChange(of: pushTransitionEnded) { _, ended in
                if ended { applyScrollDecision(proxy) }
            }
            // Everything between this scroll view and the composer resizes it when it appears or leaves, and a shrink can push the bottom sentinel out of the viewport, so the tail is re-asserted for a reader who was at it.
            .onChange(of: bottomChrome) { old, new in
                reassertTailAcrossChrome(proxy, from: old, to: new)
            }
            // Remember how the reader came to be off the tail at the moment it happens: `isNearBottom` read after a geometry change cannot say whether they were at the tail before it, because the change is what cleared it.
            .onChange(of: isNearBottom) { _, near in
                tailLatch.record(isNearBottom: near, reading: momentum.reading)
            }
    }

    /// The measurements the transcript takes of itself, and the disc drawn from them.
    private func transcriptGeometry(_ content: some View, _ proxy: ScrollViewProxy) -> some View {
        content
            // `.onGeometryChange` would be the spelling, but it is iOS 18 and this app targets 17.0, so the scroll view's own frame is reported from a `GeometryReader` in its background.
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: TranscriptContainerHeightKey.self,
                        value: geometry.size.height
                    )
                }
            }
            .onPreferenceChange(TranscriptContainerHeightKey.self) { height in
                // The reassert runs first: it reads the latch's account of where the reader was, and must not see a near-bottom recomputed against the new height.
                reassertTailAcrossContainerHeight(proxy, height: height)
                transcriptViewportHeight = height
                updateNearBottom()
            }
            .onPreferenceChange(TranscriptSentinelBottomKey.self) { bottom in
                // The sentinel is the last child of the stack, so its first report is the closest thing this view has to "the transcript is laid out".
                ColdOpenTrace.markOnce("sentinel.first", "bottom=\(Int(bottom))")
                // BUG-122: a reading on the far side of a reveal describes a viewport that was never drawn, so nothing is stored and `isNearBottom` is not recomputed against it.
                if momentum.absorbReveal(sentinelBottom: bottom) { return }
                // Content grew under a reader who was following: a row that got taller after its text did, a tool card filling in, the footer arriving. One trailing scroll lands it, debounced so a stream in motion earns none until it pauses.
                let grew = sentinel.bottom != 0 && bottom > sentinel.bottom + TranscriptScroll.ContainerHeight.epsilon
                sentinel.bottom = bottom
                updateNearBottom()
                if grew, isFollowing { settleFollow(proxy) }
            }
            .overlay(alignment: .bottomTrailing) {
                if !isNearBottom {
                    ScrollToLatestButton {
                        // BUG-051: stop the flick first, because a discrete `scrollTo` issued into a decelerating scroll view is superseded by the deceleration. A no-op when nothing is moving.
                        momentum.halt()
                        TranscriptScrollLog.scroll(.recoveryButton, isNearBottom: isNearBottom)
                        recoverToTail(proxy)
                    }
                    // Outside the control on purpose: padding around a button is not part of its hit target, so this insets a 44 pt box from the transcript edge.
                    .padding(.trailing, Space.s6)
                    .padding(.bottom, Space.s4)
                }
            }
    }

    // MARK: Transcript rows

    /// Sessions grammar: one row per entry, with consecutive calls of the same tool grouped.
    @ViewBuilder
    private var sessionRows: some View {
        let items = ColdOpenTrace.measure("group.session") {
            Self.groupItems(
                visibleEntries,
                grouping: TranscriptPreferences.groupRepeatedCalls
            )
        }
        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            if shouldShowDaySeparator(items: items, at: index) {
                DaySeparator(label: Self.dayLabel(item.timestamp))
            }
            switch item {
            case .entry(let entry):
                MessageBubbleView(
                    entry: entry,
                    onRetry: retryAction(for: entry),
                    onStartNewChat: startNewChatAction(for: entry),
                    actions: messageActions(for: entry),
                    turnStartedAt: model.turnStartedAt
                )
                .id(entry.id)
            case .toolGroup(let entries):
                ToolGroupCard(entries: entries)
                    .id(item.id)
            }
        }
    }

    /// Conversation grammar: the same entries with one level of grouping more, so a turn's tool calls ride under its bubble. A turn keeps its assistant entry's id, which the scroll machinery targets.
    @ViewBuilder
    private var conversationRows: some View {
        let items = ConversationGrouping.group(visibleEntries)
        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            if shouldShowDaySeparator(conversation: items, at: index) {
                DaySeparator(label: Self.dayLabel(item.timestamp))
            }
            switch item {
            case .entry(let entry):
                MessageBubbleView(
                    entry: entry,
                    onRetry: retryAction(for: entry),
                    onStartNewChat: startNewChatAction(for: entry),
                    actions: messageActions(for: entry),
                    turnStartedAt: model.turnStartedAt
                )
                .id(entry.id)
            case .turn(let assistant, let tools):
                VStack(alignment: .leading, spacing: Space.s3) {
                    MessageBubbleView(
                        entry: assistant,
                        actions: messageActions(for: assistant),
                        turnStartedAt: model.turnStartedAt
                    )
                    if let label = ConversationDisclosureLabel.phrase(for: item) {
                        ConversationDisclosure(label: label, assistant: assistant, tools: tools)
                    }
                }
                .id(assistant.id)
            case .pendingTools(let tools):
                if let label = ConversationDisclosureLabel.phrase(for: item) {
                    ConversationDisclosure(label: label, assistant: nil, tools: tools)
                        .id(item.id)
                }
            }
        }
    }

    /// While the resolver runs. Not `ChatEmptyState`, whose resume list is a Sessions affordance.
    private var conversationOpeningState: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            Text(conversationTitle)
                .font(HermesFont.display)
                .foregroundStyle(t.text1)
            Text("Opening your conversation…")
                .font(HermesFont.subhead)
                .foregroundStyle(t.text3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Space.s9)
    }

    #if DEBUG
    /// Screenshot harness: `-hermesScreenshotStyle conversation|session`, which re-renders an existing route in the other grammar.
    static var screenshotStyleOverride: TranscriptStyle? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-hermesScreenshotStyle"),
              index + 1 < arguments.count else { return nil }
        return TranscriptStyle(rawValue: arguments[index + 1])
    }
    #endif

    // MARK: Transcript grouping

    /// Consecutive calls of the same tool collapse into one group row.
    enum TranscriptItem: Identifiable {
        case entry(ChatEntry)
        case toolGroup([ChatEntry])

        var id: String {
            switch self {
            case .entry(let entry): return entry.id
            case .toolGroup(let entries): return "group-\(entries.first?.id ?? "")"
            }
        }

        var timestamp: Date {
            switch self {
            case .entry(let entry): return entry.timestamp
            case .toolGroup(let entries): return entries.first?.timestamp ?? Date()
            }
        }
    }

    static func groupItems(_ entries: [ChatEntry], grouping: Bool = true) -> [TranscriptItem] {
        guard grouping else { return entries.map { .entry($0) } }
        var items: [TranscriptItem] = []
        var run: [ChatEntry] = []

        func flushRun() {
            if run.count >= 2 {
                items.append(.toolGroup(run))
            } else if let single = run.first {
                items.append(.entry(single))
            }
            run.removeAll()
        }

        for entry in entries {
            if entry.kind == .tool,
               let name = entry.tool?.name,
               let last = run.last, last.tool?.name == name {
                run.append(entry)
            } else {
                flushRun()
                if entry.kind == .tool {
                    run = [entry]
                } else {
                    items.append(.entry(entry))
                }
            }
        }
        flushRun()
        return items
    }

    /// The action row appears on completed assistant messages and on failed ones, so a turn that failed (a 429 included) can be retried or edited, as on Desktop.
    private func messageActions(for entry: ChatEntry) -> MessageActions? {
        guard entry.kind == .assistant, entry.status == "complete" || entry.isError, !entry.isStreaming else { return nil }
        let hasPrecedingUser = model.entries.prefix(while: { $0.id != entry.id }).contains { $0.kind == .user }
        return MessageActions(
            canBranch: model.branchCount(forEntryID: entry.id) != nil,
            onBranch: {
                guard !model.hasBlockingPrompt else { return }
                branchTarget = entry
            },
            onRetry: hasPrecedingUser ? {
                guard !model.hasBlockingPrompt else { return }
                if model.turnMutatedState(before: entry.id) {
                    retryTarget = entry
                } else {
                    model.resendPrecedingUserTurn(before: entry.id)
                }
            } : nil,
            // Desktop parity: Edit beside Retry on the reply, never a long press on the user bubble, which BUG-044 rules out.
            onEdit: model.precedingUserEntry(before: entry.id).flatMap { user in
                model.canEdit(entryID: user.id) ? {
                    guard !model.hasBlockingPrompt else { return }
                    model.beginEditing(entryID: user.id)
                } : nil
            }
        )
    }

    /// Failed optimistic sends carry an inline Retry on their bubble.
    /// BUG-141: every failed row keeps its Retry, a refusal included, because `retryOutbound` is the only writer that clears a row's `refusal` and this button is its only caller.
    private func retryAction(for entry: ChatEntry) -> (() -> Void)? {
        guard let uuid = Self.outboundID(of: entry) else { return nil }
        return {
            guard !model.hasBlockingPrompt else { return }
            model.retryOutbound(id: uuid)
        }
    }

    /// BUG-141: the ownership refusal's primary action and only its; every other failure gets nil here.
    private func startNewChatAction(for entry: ChatEntry) -> (() -> Void)? {
        guard let onStartNewChat,
              let uuid = Self.outboundID(of: entry),
              model.outboundRefusal(for: uuid) == .sessionNotOwned
        else { return nil }
        return onStartNewChat
    }

    /// The outbound row an error bubble stands for, if it is one.
    private static func outboundID(of entry: ChatEntry) -> UUID? {
        guard entry.kind == .user, entry.isError,
              entry.id.hasPrefix("outbound-")
        else { return nil }
        return UUID(uuidString: String(entry.id.dropFirst("outbound-".count)))
    }

    private var hostName: String {
        let name = app.activeProfile?.displayName ?? ""
        return name.isEmpty ? "the backend" : name
    }

    /// The one place the transcript decides whether to move itself; the rule lives in `TranscriptScroll.Placement`. `afterLayout` marks the deferred re-entry a placement attempt schedules, once the layout it was issued against has happened.
    @discardableResult
    private func applyScrollDecision(
        _ proxy: ScrollViewProxy,
        afterLayout: Bool = false
    ) -> TranscriptScroll.Action {
        let reading = momentum.reading
        tailLatch.observe(reading: reading)
        tailLatch.noteDeparture(isNearBottom: isNearBottom, reading: reading)
        let action = placement.decide(
            chat: ObjectIdentifier(model),
            isNonEmpty: model.hasEntries,
            isNearBottom: isNearBottom,
            isFollowing: tailLatch.wasAtTail(isNearBottom: isNearBottom, reading: reading),
            afterLayout: afterLayout
        )
        // BUG-016: read before the switch and acted on regardless of which way the ladder closed, because one momentary sentinel reading can latch the ladder closed while the next layout pass takes the sentinel away again.
        if placement.takeSettleOwed() { settleAtBottom(proxy) }
        switch action {
        case .none:
            break
        case .initialPlacement:
            TranscriptScrollLog.scroll(.initialPlacement, isNearBottom: isNearBottom)
            scrollToBottom(proxy, animated: false)
            // The latch is recorded on the outcome by the deferred check, never here: this call is issued from inside a body update, so `proxy.scrollTo` can simply fail to place the view.
            verifyPlacement(proxy)
        case .followTail:
            // BUG-009: discrete, never animated. This runs on every entry-count and last-text change, so an animated scroll would keep one layout drive in flight while deltas started the next.
            TranscriptScrollLog.scroll(.followTail, isNearBottom: isNearBottom)
            scrollToBottom(proxy, animated: false)
            // The scroll above is issued against the layout before this change; the trailing one lands whatever the change added.
            settleFollow(proxy)
        }
        return action
    }

    /// Whether the transcript should still move with the stream: the reader is at or near the tail, or the content carried them past the slack and their own finger did not. A finger on the transcript is a hard no.
    private var isFollowing: Bool {
        tailLatch.wasAtTail(isNearBottom: isNearBottom, reading: momentum.reading)
    }

    /// One trailing scroll after a burst of content growth: the last delta of a reply, the footer that arrives with its completion, a row that grew after its text did. Debounced, so a stream that keeps moving earns none until it pauses, and re-checked when it fires, so a reader who has since left the tail by hand is not moved.
    private func settleFollow(_ proxy: ScrollViewProxy) {
        let token = followSettle.arm()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: TranscriptScroll.FollowSettle.settleNanoseconds)
            guard followSettle.fire(token: token), isFollowing else { return }
            TranscriptScrollLog.scroll(.followSettle, isNearBottom: isNearBottom)
            scrollToBottom(proxy, animated: false)
        }
    }

    /// BUG-016: what a finger drag does, once at the end of every initial placement and never during one. Skipped while the reader is touching the transcript, because an offset write into a live drag loses anyway.
    private func settleAtBottom(_ proxy: ScrollViewProxy) {
        guard !momentum.reading.isTouching else { return }
        let reached = momentum.settleAtBottom()
        TranscriptScrollLog.settle(reached: reached, isNearBottom: isNearBottom)
        guard reached else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            TranscriptScrollLog.scroll(.offsetSettle, isNearBottom: isNearBottom)
            scrollToBottom(proxy, animated: false)
        }
    }

    /// The ↓ button, which forces the ladder open rather than deferring to one in flight the way `replaceTail` does: a tap outranks a layout-driven repair, and deferring made the tap do nothing for the ~400 ms after every open and every debounced resize.
    private func recoverToTail(_ proxy: ScrollViewProxy, afterReload: Bool = false) {
        // After a jump the history is a page from the middle of the conversation; the live end is the latest page, so that is loaded first while the chat is quiet. A send while windowed places at the window's end and the end-of-turn reconciliation brings the latest page back.
        if !afterReload, model.historyWindowRowID != nil, !model.live.isBusy, !model.isSending, model.sendPhase == .idle {
            Task { @MainActor in
                await model.reloadLatestHistory()
                recoverToTail(proxy, afterReload: true)
            }
            return
        }
        tailLatch.rejoin()
        placement.forceRestart(chat: ObjectIdentifier(model))
        guard applyScrollDecision(proxy) == TranscriptScroll.Action.none else { return }
        // Belt and braces: `forceRestart` guarantees `.initialPlacement` for a non-empty transcript, so this is unreachable while the button is on screen.
        TranscriptScrollLog.scroll(.recoveryButton, isNearBottom: isNearBottom)
        scrollToBottom(proxy, animated: false)
        verifyPlacement(proxy)
    }

    /// BUG-016: the placement trigger for a container that changes size with no content change — the keyboard, the composer wrapping, rotation. Debounced, because a keyboard raise is one height change per frame of the animation and re-placing on each would be a pump.
    private func reassertTailAcrossContainerHeight(_ proxy: ScrollViewProxy, height: CGFloat) {
        let reading = momentum.reading
        // A reader whose content offset is measurably at the bottom is at the tail, so a `leftByHand` that was set wrongly is repaired here.
        tailLatch.observe(reading: reading)
        let wasAtTail = tailLatch.wasAtTail(isNearBottom: isNearBottom, reading: reading)
        // A chrome row arriving changes `bottomChrome` and shortens the transcript, so both drivers see it; this one stands down while the chrome coalescer is armed, and still records the height.
        let placing = TranscriptScroll.heightHookShouldPlace(
            wasAtTail: wasAtTail,
            chromeReassertPending: chromeReassert.pending != nil
        )
        let previous = containerHeight.last
        let token = containerHeight.arm(height: height, wasAtTail: placing)
        if height > 0, let previous, abs(height - previous) > TranscriptScroll.ContainerHeight.epsilon {
            TranscriptScrollLog.containerHeight(
                from: previous, to: height, wasAtTail: wasAtTail, armed: token != nil
            )
        }
        guard let token else { return }
        Task { @MainActor in
            try? await Task.sleep(
                nanoseconds: TranscriptScroll.ContainerHeight.settleNanoseconds
            )
            guard containerHeight.fire(token: token) else { return }
            TranscriptScrollLog.scroll(.containerResize, isNearBottom: isNearBottom)
            replaceTail(proxy)
        }
    }

    /// Put the reader back on the tail through the placement ladder rather than around it: a bare `scrollToBottom` is unverified and subject to the near-bottom guard, which the geometry change is what cleared. A no-op while a ladder for this chat is still running.
    private func replaceTail(_ proxy: ScrollViewProxy) {
        placement.restart(chat: ObjectIdentifier(model))
        applyScrollDecision(proxy)
    }

    /// Everything stacked between the transcript and the composer, as a value; the rule about which transitions resize the transcript lives in `TranscriptScroll.Chrome`.
    private var bottomChrome: TranscriptScroll.Chrome {
        TranscriptScroll.Chrome(
            hasTodos: !model.live.activity.todos.isEmpty,
            hasAgents: !model.live.activity.subagents.isEmpty,
            hasNotice: model.live.notice != nil,
            hasError: model.errorMessage != nil,
            hasBlockingPrompt: model.hasBlockingPrompt,
            hasConnection: model.pendingConnection != nil,
            isEditing: model.editingEntryID != nil
        )
    }

    /// BUG-050: put the reader back on the tail across a chrome change, once per burst and only for a change that moved the ground. `isNearBottom` is read synchronously inside the `onChange`, before the layout pass that can hide the sentinel and clear it.
    private func reassertTailAcrossChrome(
        _ proxy: ScrollViewProxy,
        from old: TranscriptScroll.Chrome,
        to new: TranscriptScroll.Chrome
    ) {
        let resized = TranscriptScroll.Chrome.changesHeight(from: old, to: new)
        let token = resized ? chromeReassert.arm(isNearBottom: isNearBottom) : nil
        TranscriptScrollLog.chromeTransition(
            from: old.logSignature,
            to: new.logSignature,
            changesHeight: resized,
            isNearBottom: isNearBottom,
            armed: token != nil
        )
        guard let token else { return }
        Task { @MainActor in
            try? await Task.sleep(
                nanoseconds: TranscriptScroll.ChromeReassert.settleNanoseconds
            )
            guard chromeReassert.fire(token: token) else { return }
            TranscriptScrollLog.scroll(.chromeReassert, isNearBottom: isNearBottom)
            scrollToBottom(proxy, animated: false)
        }
    }

    /// Ask again after the layout the placement scroll was issued against: one short hop off the current update, not a poll.
    private func verifyPlacement(_ proxy: ScrollViewProxy) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            applyScrollDecision(proxy, afterLayout: true)
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        if animated {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(bottomAnchor, anchor: .bottom)
        }
    }

    // MARK: BUG-016 — exact geometry

    /// `isNearBottom` from the two measurements, written only when the answer changes so a scroll's stream of preference updates does not re-render the transcript on every frame.
    private func updateNearBottom() {
        guard let near = TranscriptScroll.Geometry.isNearBottom(
            sentinelBottom: sentinel.bottom,
            viewportHeight: transcriptViewportHeight
        ) else { return }
        if near != isNearBottom { isNearBottom = near }
    }

    /// BUG-121: true while the push into this conversation is still running and the transcript has nothing painted yet.
    private var transcriptIsHeld: Bool {
        TranscriptScroll.PushGate.holds(
            hadRowsOnAppear: hadRowsOnAppear,
            transitionEnded: pushTransitionEnded
        )
    }

    private var revealedEarlierCount: Int {
        revealedEarlierFor == ObjectIdentifier(model) ? revealedEarlier : 0
    }

    private var hiddenEarlierCount: Int {
        TranscriptScroll.Window.hiddenCount(
            total: model.entries.count,
            revealed: revealedEarlierCount
        )
    }

    /// The entries the plain stack renders: `model.entries` less the window's hidden head.
    private var visibleEntries: [ChatEntry] {
        TranscriptScroll.Window.visible(model.entries, revealed: revealedEarlierCount)
    }

    /// Bring one of the conversation's prompts into view. A loaded prompt is scrolled to, the window's hidden head revealed first if it is in it; one outside the loaded history has its page loaded first. Either way the reader has left the tail on purpose, so the follow stands down until the scroll-to-latest disc or a send.
    private func jump(to target: TranscriptJump, _ proxy: ScrollViewProxy) {
        momentum.halt()
        tailLatch.leave()
        if let entry = loadedEntry(for: target) {
            if hiddenEarlierCount > 0 {
                revealedEarlier = model.entries.count
                revealedEarlierFor = ObjectIdentifier(model)
            }
            scrollToRow(entry.id, proxy)
            return
        }
        guard let rowID = target.rowID else { return }
        Task { @MainActor in
            guard await model.loadHistoryAround(rowID: rowID), let entry = model.loadedPrompt(rowID: rowID) else { return }
            tailLatch.leave()
            scrollToRow(entry.id, proxy)
        }
    }

    private func loadedEntry(for target: TranscriptJump) -> ChatEntry? {
        if let id = target.entryID, let entry = model.entries.first(where: { $0.id == id }) { return entry }
        if let rowID = target.rowID { return model.loadedPrompt(rowID: rowID) }
        return nil
    }

    /// The row's top at the viewport's top, now and once more after the layout the request may have caused. Discrete, like every scroll in this transcript.
    private func scrollToRow(_ id: String, _ proxy: ScrollViewProxy) {
        proxy.scrollTo(id, anchor: .top)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            proxy.scrollTo(id, anchor: .top)
        }
    }

    /// BUG-122: reveal a window and keep the reader's place across it. `.defaultScrollAnchor(.bottom)` does not absorb rows inserted above the viewport — the content offset does not move — so the offset is moved by the measured height of the inserted block.
    private func revealEarlier(_ proxy: ScrollViewProxy) {
        // Named before the window moves, for the degraded path below.
        let previousTop = visibleEntries.first?.id
        // BUG-051: a flick still in flight owns the offset and would carry the relative correction away. A no-op when nothing is moving.
        momentum.halt()
        let measured = sentinel.bottom
        revealedEarlier = revealedEarlierCount + TranscriptScroll.Window.size
        revealedEarlierFor = ObjectIdentifier(model)
        if momentum.reading.isAvailable, measured != 0 {
            momentum.armReveal(sentinelBottom: measured)
        } else if let previousTop {
            // No scroll view was found, or the sentinel has never reported: put the row that was under the reveal row at the top of the viewport, which is approximate rather than exact.
            proxy.scrollTo(previousTop, anchor: .top)
        }
    }

    // MARK: Day separators

    /// A separator on the first item, and whenever the calendar day changes.
    private func shouldShowDaySeparator(items: [TranscriptItem], at index: Int) -> Bool {
        guard index < items.count else { return false }
        guard index > 0 else { return true }
        let previous = items[index - 1].timestamp
        let current = items[index].timestamp
        return !Calendar.current.isDate(previous, inSameDayAs: current)
    }

    /// The same rule over conversation rows, where the separator is also the only absolute clock outside the bubble's context-menu header.
    private func shouldShowDaySeparator(conversation items: [ConversationItem], at index: Int) -> Bool {
        guard index < items.count else { return false }
        guard index > 0 else { return true }
        return !Calendar.current.isDate(items[index - 1].timestamp, inSameDayAs: items[index].timestamp)
    }

    private static func dayLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    // MARK: Blocking prompts

    /// A persistent bar and not just a sheet: an unanswered approval blocks the agent for the configured `approvals.timeout`, then fails the tool closed, and is not recoverable across a reconnect.
    private var blockingPromptBar: some View {
        Button {
            isPromptMinimised = false
            blockingPromptPresentationReady = true
        } label: {
            HStack(spacing: Space.s4) {
                Circle().fill(t.warn).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: Space.s1) {
                    Text(promptTitle)
                        .font(HermesFont.calloutStrong)
                        .foregroundStyle(t.text1)
                    Text(promptSubtitle)
                        .font(HermesFont.footnote)
                        .foregroundStyle(t.text3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: Space.s4)
                if let deadline = promptDeadline {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let remaining = max(0, deadline.seconds - context.date.timeIntervalSince(deadline.received))
                        Text(RelativeTime.countdown(remaining: remaining))
                            .font(HermesFont.footnote)
                            .hermesNumeric()
                            .foregroundStyle(remaining < 30 ? t.danger : t.warn)
                    }
                }
                Text("Review")
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.action)
            }
            .padding(.horizontal, Space.s6)
            .padding(.vertical, Space.s5)
            .frame(minHeight: Hit.min)
            // No ground of its own: it sits on the dock's one frosted plate. The separator is below it, so the plate's top edge is drawn once, by the plate.
            .hairline(.bottom)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The wall-clock deadline of the current prompt, for the docked-bar countdown; one accessor feeds this bar, the sheet and the dismissal timer so the three cannot disagree.
    private var promptDeadline: (received: Date, seconds: TimeInterval)? {
        switch currentPrompt {
        // Approvals do expire: the gateway wait fails closed after `approvals.timeout`, with no frame sent to say so.
        case .approval(let request): return model.approvalBudget(for: request)
        case .clarify(let request):
            guard request.serverRequest == nil else { return nil }
            // Same resolution order as ApprovalSheetView.budget.
            let seconds: TimeInterval = {
                if let wire = request.wireTimeoutSeconds { return wire }
                if let configured = app.settings.clarifyTimeoutSeconds() { return configured }
                return ClarifyRequestEvent.defaultTimeoutSeconds
            }()
            // `<= 0` means wait forever; no deadline to show.
            guard seconds > 0 else { return nil }
            return (request.receivedAt, seconds)
        case .sudo(let request): return request.serverRequest == nil ? (request.receivedAt, request.timeoutSeconds) : nil
        case .secret(let request): return request.serverRequest == nil ? (request.receivedAt, request.timeoutSeconds) : nil
        case nil: return nil
        }
    }

    /// One ladder, on the model: the sheet decides whether to stay by comparing the prompt it is showing against this.
    private var currentPrompt: BlockingPrompt? { model.currentBlockingPrompt }

    private var promptTitle: String {
        switch currentPrompt {
        case .approval: return "Hermes needs approval"
        case .clarify: return "Hermes has a question"
        case .sudo: return "Administrator password needed"
        case .secret(let request): return request.requiresDesktop ? "Continue in Desktop" : "Credential needed"
        case nil: return ""
        }
    }

    private var promptSubtitle: String {
        switch currentPrompt {
        case .approval(let request): return DisplayRedaction.preview(request.command, limit: 90)
        case .clarify(let request): return DisplayRedaction.preview(request.question, limit: 90)
        case .sudo: return "Tap to enter it securely"
        case .secret(let request): return request.requiresDesktop ? "View the pending request" : (request.envVar.isEmpty ? "Tap to provide it" : request.envVar)
        case nil: return ""
        }
    }

    private var serverIdentity: String {
        guard let profile = app.activeProfile,
              let configuration = try? profile.makeConfiguration()
        else { return "Unknown backend" }
        return DisplayRedaction.serverIdentity(configuration)
    }

    // MARK: Message-action sheets

    /// Branch: names the new chat and says how much history comes with it.
    private func branchSheet(_ entry: ChatEntry) -> some View {
        VStack(alignment: .leading, spacing: Space.s5) {
            Text("Branch into a new chat")
                .font(HermesFont.heading)
                .foregroundStyle(t.text1)
            if let count = model.branchCount(forEntryID: entry.id) {
                Text("The new conversation starts with the first \(count) messages of this one, up to this reply.")
                    .font(HermesFont.subhead)
                    .foregroundStyle(t.text3)
            }
            TextField("Name the new chat (optional)", text: $branchName)
                .font(HermesFont.body)
                .padding(Space.s5)
                .background(t.surface2, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            Button("Create branch") {
                let entryID = entry.id
                let name = branchName
                branchTarget = nil
                branchName = ""
                Task {
                    guard let storedID = await model.branch(fromEntryID: entryID, name: name) else { return }
                    if let summary = app.threads.first(where: { $0.id == storedID }) {
                        app.requestRoute([.thread(.existing(summary))])
                    }
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            Spacer(minLength: 0)
        }
        .padding(Space.s6)
        .background(t.surface)
        .presentationDetents([.height(280)])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(Radius.sheet)
        .presentationBackground(t.surface)
    }

    /// Retry after a state-mutating turn discards work, so it escalates to a hold.
    private func retryConfirmSheet(_ entry: ChatEntry) -> some View {
        VStack(alignment: .leading, spacing: Space.s5) {
            Text("Re-run this turn?")
                .font(HermesFont.heading)
                .foregroundStyle(t.text1)
            Text("The turn being retried ran commands that changed files on your machine. Re-running repeats them; the protocol has no way to undo the originals.")
                .font(HermesFont.subhead)
                .foregroundStyle(t.text3)
            HoldToConfirmButton("Hold to re-run") {
                let entryID = entry.id
                retryTarget = nil
                model.resendPrecedingUserTurn(before: entryID)
            }
            Spacer(minLength: 0)
        }
        .padding(Space.s6)
        .background(t.surface)
        .presentationDetents([.height(240)])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(Radius.sheet)
        .presentationBackground(t.surface)
    }
}

// MARK: - The transcript container's height (BUG-016 direction C)

/// The bottom sentinel's bottom edge in the scroll view's coordinate space; one reporter, last wins, and a negative value means the sentinel is above the viewport.
private struct TranscriptSentinelBottomKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// The top of a windowed transcript: `TranscriptScroll.Window` caps how many rows the plain stack lays out, and this row lifts the cap one window at a time.
private struct EarlierMessagesRow: View {
    @Environment(\.hermes) private var t
    let hidden: Int
    let reveal: () -> Void

    var body: some View {
        Button(action: reveal) {
            Text(TranscriptScroll.Window.revealLabel(hidden: hidden))
                .font(HermesFont.subhead)
                .foregroundStyle(t.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Space.s3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("hermes.transcript.earlier")
    }
}

private struct TranscriptContainerHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    /// `max` rather than last-wins, so a default-valued sibling cannot report the container as zero points tall.
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Transcript auto-scroll decision

/// Whether the transcript should scroll itself, and why. The view keeps the wiring, this keeps the judgement, and it is not `@MainActor` so a test can call it directly.
enum TranscriptScroll {
    // MARK: BUG-016 — exact geometry rules

    /// `isNearBottom` as a measurement. Either input unreported means no answer and the caller keeps what it had, which starts at true, so a transcript that has not laid out yet is followed rather than declined.
    enum Geometry {
        /// How far below the visible bottom the sentinel may sit and still count as at the tail.
        static var slack: CGFloat { 80 }

        static func isNearBottom(sentinelBottom: CGFloat, viewportHeight: CGFloat) -> Bool? {
            guard viewportHeight > 0, sentinelBottom != 0 else { return nil }
            return sentinelBottom <= viewportHeight + slack
        }

        /// Landscape cap; the transcript is never wider than this.
        static var maxContentWidth: CGFloat { 680 }

        /// The width the transcript's stack is pinned to: the viewport's, capped. An unmeasured viewport pins nothing rather than pinning to zero.
        static func contentWidth(viewport: CGFloat) -> CGFloat? {
            viewport > 0 ? min(viewport, maxContentWidth) : nil
        }
    }

    /// BUG-121: the push animation has to finish before the transcript's first layout starts, because a `UINavigationController` push is driven from the main thread and laying out up to 200 messages holds that thread for seconds.
    enum PushGate {
        /// A little past the 0.35 s a navigation push runs for, so the transition has ended rather than nearly ended.
        static var settleDelay: TimeInterval { 0.4 }

        /// Whether the transcript is still held back. A chat whose rows were already in the model is never held: its layout is paid before the push begins.
        static func holds(hadRowsOnAppear: Bool, transitionEnded: Bool) -> Bool {
            !hadRowsOnAppear && !transitionEnded
        }
    }

    /// The bottom sentinel's last reported edge, in a reference rather than `@State`: SwiftUI invalidates a view on any write to its `@State` whether or not `body` reads it, and this is written on every layout.
    @MainActor
    final class SentinelReading {
        var bottom: CGFloat = 0
    }

    /// The bounded window a plain stack renders: the newest `size` entries, plus whatever the reader has revealed from the top.
    enum Window {
        /// 200 is a product decision, not a tuning constant: lowering it makes the reveal row appear on more transcripts.
        static var size: Int {
            #if DEBUG
            if let override = debugSizeOverride { return override }
            #endif
            return 200
        }

        #if DEBUG
        /// `-hermesTranscriptWindow <n>` on the launch arguments; absent in every ordinary run, tests included.
        private static let debugSizeOverride: Int? = {
            let arguments = ProcessInfo.processInfo.arguments
            guard let index = arguments.firstIndex(of: "-hermesTranscriptWindow"),
                  index + 1 < arguments.count,
                  let value = Int(arguments[index + 1]),
                  value > 0
            else { return nil }
            return value
        }()
        #endif

        static func hiddenCount(total: Int, revealed: Int) -> Int {
            max(0, total - size - max(0, revealed))
        }

        static func visible<Entry>(_ entries: [Entry], revealed: Int) -> [Entry] {
            let hidden = hiddenCount(total: entries.count, revealed: revealed)
            return hidden > 0 ? Array(entries.dropFirst(hidden)) : entries
        }

        /// BUG-122: the label leads with what one tap actually reveals and carries the rest as a count, because one tap reveals one window rather than everything hidden.
        static func revealLabel(hidden: Int) -> String {
            let reveal = min(hidden, size)
            if reveal == 1 { return "Show 1 earlier message" }
            if reveal == hidden { return "Show \(reveal) earlier messages" }
            return "Show \(reveal) earlier messages · \(hidden) hidden"
        }
    }

    enum Action: Equatable {
        /// Leave the viewport where the reader put it.
        case none
        /// BUG-007: the first non-empty layout for this chat, scrolled to the tail without consulting the near-bottom guard, which on a fresh open reads the transcript's arrival as deliberate scrollback.
        case initialPlacement
        /// Follow the stream only while the reader is already at the tail, so scrollback is never yanked back down.
        case followTail
    }

    /// Which driver owns a change both can see: a row arriving below the transcript is a chrome transition and a container-height change, and the chrome path wins because it reads the near-bottom flag before the layout clears it.
    static func heightHookShouldPlace(wasAtTail: Bool, chromeReassertPending: Bool) -> Bool {
        wasAtTail && !chromeReassertPending
    }

    /// Whether to place, follow or stand still, given which chat has already been placed and whether the reader is at the tail.
    static func action<Key: Equatable>(
        placedChat: Key?,
        currentChat: Key,
        isNonEmpty: Bool,
        isNearBottom: Bool
    ) -> Action {
        // A brand-new chat with no stored session has nothing to scroll to and must not jump.
        guard isNonEmpty else { return .none }
        guard placedChat == currentChat else { return .initialPlacement }
        return isNearBottom ? .followTail : .none
    }

    /// The latch policy around that rule: when a chat counts as placed. Placement is latched on the outcome — the bottom sentinel coming back on screen — because the view's first scroll is issued before the rows it targets have been laid out and may simply not place the view.
    struct Placement<Key: Equatable> {
        /// How many placement scrolls must have been issued before the sentinel's testimony is trusted, so the first attempt can never settle on a reading of the layout that came before the transcript arrived.
        static var minAttempts: Int { 2 }
        /// The ceiling; on reaching it the chat is latched regardless, so an unplaceable transcript costs a bounded number of no-op scrolls rather than a permanent fight.
        static var maxAttempts: Int { 5 }

        /// The chat whose placement is finished, observed or given up on.
        private(set) var placedChat: Key?
        /// The chat the in-flight ladder belongs to.
        private var attemptingChat: Key?
        /// Placement scrolls issued for `attemptingChat`.
        private(set) var attempts = 0
        /// An attempt has been issued and its outcome not yet judged.
        private var isAwaitingLayout = false
        /// One-shot: this chat's initial placement has just closed and owes the content-offset settle.
        private(set) var settleOwed = false

        init() {}

        /// `afterLayout` is true only for the deferred re-entry a placement attempt schedules, which is the one call whose `isNearBottom` reads the layout the attempt was issued against and so the only call allowed to judge the outcome.
        /// `isNearBottom` judges the ladder (the sentinel is back on screen); `isFollowing` decides a placed chat's follow, and may be true past the slack for a reader the content carried off the tail. Nil means the two are the same measurement.
        mutating func decide(
            chat: Key,
            isNonEmpty: Bool,
            isNearBottom: Bool,
            isFollowing: Bool? = nil,
            afterLayout: Bool = false
        ) -> Action {
            guard isNonEmpty else { return .none }

            if placedChat != chat {
                // A `ChatView` re-bound to another chat starts that chat's ladder over rather than inheriting the previous one's.
                if attemptingChat != chat {
                    attemptingChat = chat
                    attempts = 0
                    isAwaitingLayout = false
                }

                // An attempt is out and has not been judged; a second scroll in the same frame would only spend the budget before a layout.
                if isAwaitingLayout, !afterLayout { return .none }

                if afterLayout {
                    isAwaitingLayout = false
                    let took = attempts >= Self.minAttempts && isNearBottom
                    if took || attempts >= Self.maxAttempts {
                        // The latch, recorded here and nowhere else: on the observation that the sentinel is back on screen, or on the ceiling.
                        placedChat = chat
                        // Owed either way, because a momentary sentinel reading can close this ladder for good while the next layout takes the sentinel away again.
                        settleOwed = true
                    }
                }

                if placedChat != chat {
                    attempts += 1
                    isAwaitingLayout = true
                    return .initialPlacement
                }
            }

            return TranscriptScroll.action(
                placedChat: placedChat,
                currentChat: chat,
                isNonEmpty: isNonEmpty,
                isNearBottom: isFollowing ?? isNearBottom
            )
        }

        /// Re-open the ladder for a chat that has already been placed. A no-op while a ladder for this chat is still running, so a keyboard raise during a cold open cannot reset that open's own placement halfway through.
        mutating func restart(chat: Key) {
            guard placedChat == chat else { return }
            forceRestart(chat: chat)
        }

        /// The version a tap gets: clears the whole ladder unconditionally, so the very next `decide` returns `.initialPlacement` and scrolls synchronously.
        mutating func forceRestart(chat: Key) {
            placedChat = nil
            attemptingChat = nil
            attempts = 0
            isAwaitingLayout = false
            settleOwed = false
        }

        /// Consume the one-shot settle flag; true at most once per completed placement, so the caller cannot double-fire it.
        mutating func takeSettleOwed() -> Bool {
            defer { settleOwed = false }
            return settleOwed
        }
    }

    // MARK: Container-height tail retention (BUG-016 direction C)

    /// Was the reader at the tail before the ground moved? `isNearBottom` read when a container resize arrives cannot say, because the resize is what cleared it, so this records why the reader left the tail at the moment they left it: a finger that moved the offset means on purpose, no finger means a layout pass moved them.
    struct TailLatch {
        /// Whether the reader took themselves off the tail; false on a fresh transcript, which starts at the tail by construction.
        private(set) var leftByHand = false

        init() {}

        /// The bottom sentinel appeared or disappeared. A resting finger is not a departure, an unavailable reading is treated as one, and an offset measurably at the bottom outranks both.
        mutating func record(isNearBottom: Bool, reading: TranscriptScrollReading) {
            if isNearBottom {
                leftByHand = false
                return
            }
            guard reading.isAvailable else {
                leftByHand = true
                return
            }
            if reading.isAtBottom {
                leftByHand = false
                return
            }
            if reading.movedOffset {
                leftByHand = true
            }
        }

        /// Repair a flag that was set wrongly; called before every placement decision, and never sets the flag.
        mutating func observe(reading: TranscriptScrollReading) {
            if reading.isAvailable, reading.isAtBottom { leftByHand = false }
        }

        /// The other direction, for a departure the sentinel's edge did not report: a reader found moving the offset while already off the tail (the content carried them past the slack first, then they dragged) left it on purpose.
        mutating func noteDeparture(isNearBottom: Bool, reading: TranscriptScrollReading) {
            guard !isNearBottom, reading.isAvailable, reading.movedOffset, !reading.isAtBottom else { return }
            leftByHand = true
        }

        /// The reader asked to be back at the tail: the scroll-to-latest disc, or their own send.
        mutating func rejoin() {
            leftByHand = false
        }

        /// The reader asked to be somewhere else: a jump to an earlier prompt.
        mutating func leave() {
            leftByHand = true
        }

        /// `isTouching` is a hard no regardless of the flag, because a re-placement issued into a live drag loses anyway (BUG-051), and a measured `isAtBottom` is a hard yes.
        func wasAtTail(isNearBottom: Bool, reading: TranscriptScrollReading) -> Bool {
            if reading.isTouching { return false }
            if reading.isAvailable, reading.isAtBottom { return true }
            return isNearBottom || !leftByHand
        }
    }

    /// The transcript container's height, debounced: one keyboard raise is one height change per frame of the animation, and re-placing on each is a pump. A report that repeats the height already held is not news and spends nothing, which is what stops the hook feeding itself.
    struct ContainerHeight {
        /// How long the height is given to stop moving before the one placement it earns, so the correction lands one layout pass after the resize.
        static var settleNanoseconds: UInt64 { 80_000_000 }
        /// Below this, a height report is noise rather than a resize.
        static var epsilon: CGFloat { 0.5 }

        /// The last height actually reported.
        private(set) var last: CGFloat?
        private var counter = 0
        /// The token the pending placement will fire under, or nil when none is pending.
        private(set) var pending: Int?

        init() {}

        /// A height arrived; returns the token to schedule the placement under, or nil when this height earns none. A zero height is a view on its way out of the hierarchy and is neither acted on nor recorded, and a change found off the tail records the height without cancelling a pending placement.
        mutating func arm(height: CGFloat, wasAtTail: Bool) -> Int? {
            guard height > 0 else { return nil }
            let previous = last
            last = height
            guard let previous, abs(height - previous) > Self.epsilon else { return nil }
            guard wasAtTail else { return nil }
            counter += 1
            pending = counter
            return counter
        }

        /// The deferred hop woke up; true only if this token is still the pending one, so a later height supersedes an earlier hop.
        mutating func fire(token: Int) -> Bool {
            guard pending == token else { return false }
            pending = nil
            return true
        }
    }

    // MARK: The trailing scroll after content growth

    /// One scroll per burst of growth, issued once the content has stopped moving for a moment. A debounce and not a throttle: a reply streaming at thirty deltas a second earns none until it pauses, and the per-delta follow carries the reader meanwhile.
    struct FollowSettle {
        /// Long enough for the layout the growth caused to have happened, short enough that the reader never sees the gap.
        static var settleNanoseconds: UInt64 { 80_000_000 }

        private var counter = 0
        private(set) var pending: Int?

        init() {}

        /// Arming supersedes whatever was pending.
        mutating func arm() -> Int {
            counter += 1
            pending = counter
            return counter
        }

        /// True only if this token is still the pending one.
        mutating func fire(token: Int) -> Bool {
            guard pending == token else { return false }
            pending = nil
            return true
        }
    }

    // MARK: Chrome-driven tail reassertion (BUG-050)

    /// Everything stacked between the transcript and the composer, as a value. The flags are the state and not the height — the activity strip is one 44 pt line per populated group — so `changesHeight(from:to:)` is the distinction, while `Equatable` stays the raw flag comparison for instrumentation.
    struct Chrome: Equatable {
        var hasTodos: Bool
        var hasAgents: Bool
        var hasNotice: Bool
        var hasError: Bool
        var hasBlockingPrompt: Bool
        /// The connection card and the editing banner, dock rows like the notice and the error.
        var hasConnection: Bool
        var isEditing: Bool

        init(
            hasTodos: Bool = false,
            hasAgents: Bool = false,
            hasNotice: Bool = false,
            hasError: Bool = false,
            hasBlockingPrompt: Bool = false,
            hasConnection: Bool = false,
            isEditing: Bool = false
        ) {
            self.hasTodos = hasTodos
            self.hasAgents = hasAgents
            self.hasNotice = hasNotice
            self.hasError = hasError
            self.hasBlockingPrompt = hasBlockingPrompt
            self.hasConnection = hasConnection
            self.isEditing = isEditing
        }

        /// Populated strip groups: 0, 1 or 2, which is the strip's height in 44 pt lines and the only thing about the strip the transcript feels.
        var stripGroups: Int {
            (hasTodos ? 1 : 0) + (hasAgents ? 1 : 0)
        }

        /// Whether this transition actually resized the transcript; every row except the strip is present or absent, so its flag is its height, while the strip is two flags and three heights.
        static func changesHeight(from old: Chrome, to new: Chrome) -> Bool {
            old.stripGroups != new.stripGroups
                || old.hasNotice != new.hasNotice
                || old.hasError != new.hasError
                || old.hasBlockingPrompt != new.hasBlockingPrompt
                || old.hasConnection != new.hasConnection
                || old.isEditing != new.isEditing
        }
    }

    /// BUG-050: one scroll per burst, and only for a reader who was at the tail. A debounce and not a throttle, so a chrome that keeps flapping earns no scroll until it settles; `ChatView` owns the timer, this owns the judgement.
    struct ChromeReassert {
        /// How long a burst is given to settle before the one scroll it earns, so the correction lands one layout pass after the resize.
        static var settleNanoseconds: UInt64 { 80_000_000 }

        private var counter = 0
        /// The token the pending scroll will fire under, or nil when none is pending.
        private(set) var pending: Int?

        init() {}

        /// A chrome transition that changed the transcript's height arrived; arming supersedes whatever was pending, and a transition found off the tail neither schedules nor cancels, because cancelling would let the resize disarm its own repair.
        mutating func arm(isNearBottom: Bool) -> Int? {
            guard isNearBottom else { return nil }
            counter += 1
            pending = counter
            return counter
        }

        /// The deferred hop woke up; true only if this token is still the pending one, so a later transition supersedes an earlier hop.
        mutating func fire(token: Int) -> Bool {
            guard pending == token else { return false }
            pending = nil
            return true
        }
    }
}

// MARK: - BUG-062 C: a question waiting in another conversation

/// Another conversation this phone is attached to that is stopped on a question for the person, as the open chat announces it.
struct ElsewherePrompt: Equatable {
    /// The durable id the banner opens.
    let storedID: String
    let title: String
    let kind: ApprovalNotifications.PromptKind
    /// How many more conversations are waiting besides this one.
    let others: Int

    /// What is being asked, and that it is somewhere else. No question text: the banner is above another conversation, and the question is that chat's to show.
    var headline: String {
        switch kind {
        case .approval: return "Hermes needs approval in another chat"
        case .clarify: return "Hermes has a question in another chat"
        case .sudo: return "Hermes needs a password in another chat"
        case .secret: return "Hermes needs a value in another chat"
        case .desktop: return "Another chat is waiting on Desktop"
        case .signIn: return "Hermes needs you to sign in in another chat"
        }
    }

    var detail: String {
        let name = title.isEmpty ? "Untitled chat" : title
        return others == 0 ? name : "\(name) · \(others) more waiting"
    }

    /// The conversation to announce, given the current-request registry's view keyed by runtime id (`WaitingSessions.byRuntimeID`); nil when nothing outside the open chat is waiting.
    /// The open chat is excluded by either id, because it shows its own prompt. A session with no durable id cannot be opened from here and is not offered. An approval leads, because it fails closed on the shortest fuse; ties go by runtime id so the banner does not flip between equals.
    static func pick(
        waiting: [String: ApprovalNotifications.PromptKind],
        currentRuntimeID: String?,
        currentStoredID: String?,
        storedID: (String) -> String?,
        title: (String) -> String
    ) -> ElsewherePrompt? {
        var seen: Set<String> = []
        var candidates: [(runtimeID: String, storedID: String, kind: ApprovalNotifications.PromptKind)] = []
        for (runtimeID, kind) in waiting where runtimeID != currentRuntimeID {
            guard let stored = storedID(runtimeID), !stored.isEmpty, stored != currentStoredID,
                  seen.insert(stored).inserted
            else { continue }
            candidates.append((runtimeID, stored, kind))
        }
        candidates.sort { lhs, rhs in
            let left = lhs.kind == .approval ? 0 : 1
            let right = rhs.kind == .approval ? 0 : 1
            return left != right ? left < right : lhs.runtimeID < rhs.runtimeID
        }
        guard let first = candidates.first else { return nil }
        return ElsewherePrompt(
            storedID: first.storedID,
            title: title(first.storedID),
            kind: first.kind,
            others: candidates.count - 1
        )
    }
}

/// The banner under the bar: one warn dot, what is waiting, which chat, and Open. Opaque on the canvas with one hairline, like the connection banner it stacks under, because it is a notice and never glass.
@MainActor
private struct ElsewherePromptBanner: View {
    @Environment(\.hermes) private var t
    let prompt: ElsewherePrompt
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: Space.s4) {
                Circle()
                    .fill(t.warn)
                    .frame(width: 8, height: 8)
                    .padding(.top, 5)
                    .frame(width: 16, height: 20)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Space.s1) {
                    Text(prompt.headline)
                        .font(HermesFont.calloutStrong)
                        .foregroundStyle(t.text1)
                    Text(prompt.detail)
                        .font(HermesFont.footnote)
                        .foregroundStyle(t.text3)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: Space.s4)
                Text("Open")
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.action)
                    .padding(.top, 2)
            }
            .padding(.horizontal, Space.s6)
            .padding(.vertical, Space.s5)
            .frame(maxWidth: .infinity, minHeight: Hit.min, alignment: .leading)
            .background(t.canvas)
            .hairline()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens that chat")
        .accessibilityIdentifier("hermes.chat.elsewherePrompt")
    }
}

// MARK: - Scroll to latest

/// The transcript's escape hatch: a floating glass disc exactly the 44 pt house hit box, Liquid Glass on iOS 26 and a material disc below it, so it reads as a control over the conversation rather than a glyph colliding with it.
@MainActor
struct ScrollToLatestButton: View {
    @Environment(\.hermes) private var t

    let action: () -> Void

    init(action: @escaping () -> Void) { self.action = action }

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(t.action)
                // The disc is the hit box: one frame, the house 44, and the call site's paddings stay outside it.
                .frame(width: Hit.min, height: Hit.min)
                .glassFloating(in: Circle())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Scroll to latest")
    }
}

// MARK: - Flat notice / error / auto-continue

/// The single keyed notice slot above the composer: one leading dot and one line, replaced in place.
@MainActor
private struct NoticeSlot: View {
    @Environment(\.hermes) private var t
    let notice: Notice

    var body: some View {
        HStack(alignment: .top, spacing: Space.s4) {
            Circle().fill(dotColor).frame(width: 8, height: 8).padding(.top, 5)
            Text(notice.text)
                .font(HermesFont.subhead)
                .foregroundStyle(t.text2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Space.s6)
        .padding(.vertical, Space.s5)
        .frame(maxWidth: .infinity, alignment: .leading)
        // On the dock's plate, with no ground of its own; separated from what follows it, not from the plate's edge.
        .hairline(.bottom)
        .id(notice.key)
    }

    private var dotColor: Color {
        switch notice.level {
        case "error", "danger": return t.danger
        case "warn", "warning": return t.warn
        case "success", "ok": return t.ok
        default: return t.text4
        }
    }
}

@MainActor
private struct SessionErrorRow: View {
    @Environment(\.hermes) private var t
    let message: String
    /// FEAT-040: present while the kept draft would run as a command again.
    var sendAsText: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: Space.s4) {
            Circle().fill(t.danger).frame(width: 8, height: 8).padding(.top, 5)
            Text(message)
                .font(HermesFont.subhead)
                .foregroundStyle(t.text2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let sendAsText {
                Button(action: sendAsText) {
                    Text("Send as text")
                        .font(HermesFont.footnote)
                        .foregroundStyle(t.action)
                        .padding(.top, Space.s1)
                        .frame(minHeight: Hit.min, alignment: .top)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Space.s6)
        .padding(.vertical, Space.s5)
        .frame(maxWidth: .infinity, alignment: .leading)
        // On the dock's plate, with no ground of its own; separated from what follows it, not from the plate's edge.
        .hairline(.bottom)
    }
}

/// Per jsonrpc-methods §4.6: `auto_continue` means the backend re-submitted a crash-interrupted turn itself, and it arrives as a normal `message.start` stream right after the resume.
@MainActor
private struct AutoContinueRow: View {
    @Environment(\.hermes) private var t
    let notice: AutoContinueNotice
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Space.s4) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 13))
                .foregroundStyle(t.text3)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: Space.s1) {
                Text("Resuming an interrupted turn")
                    .font(HermesFont.subhead)
                    .foregroundStyle(t.text2)
                Text("Hermes restarted mid-turn and is re-running it (attempt \(notice.attempt)). The reply will stream in normally.")
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.text3)
            }
            Spacer(minLength: Space.s4)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(t.text3)
                    .frame(width: Hit.min, height: Hit.min)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Empty state

/// BUG-052: an existing conversation with nothing on screen, as distinct from a chat nothing has been said in yet.
@MainActor
private struct TranscriptUnavailableState: View {
    @Environment(\.hermes) private var t
    let model: ChatModel

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s5) {
            Text("This conversation didn't load")
                .font(HermesFont.heading)
                .foregroundStyle(t.text1)
            Text("Its messages are still on the backend — this device could not read them.")
                .font(HermesFont.subhead)
                .foregroundStyle(t.text3)
            Button("Try again") { Task { await model.open() } }
                .buttonStyle(SecondaryButtonStyle())
                .frame(maxWidth: 220)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Space.s9)
    }
}

/// BUG-076: the blocking-prompt presentation in its own modifier, which gives SwiftUI one host for the sheet's lifecycle and keeps `ChatView.body` below the compiler's type-checking complexity limit.
@MainActor
private struct BlockingPromptPresentationModifier: ViewModifier {
    let model: ChatModel
    let serverIdentity: String
    @Binding var isPromptMinimised: Bool
    @Binding var presentationReady: Bool
    let dismissSiblingPresentations: () -> Void

    private var promptIdentity: String? { model.currentBlockingPrompt?.id }

    func body(content: Content) -> some View {
        content
            .sheet(item: presentedPrompt) { prompt in
                ApprovalSheetView(
                    prompt: prompt,
                    serverIdentity: serverIdentity,
                    model: model
                ) {
                    // Minimise: collapse to the docked bar, do NOT answer.
                    isPromptMinimised = true
                    presentationReady = false
                }
                // Prompt B must not inherit prompt A's read gate or in-flight response state when it replaces A in the same sheet.
                .id(prompt.id)
            }
            .task(id: promptIdentity) {
                guard let identity = promptIdentity else {
                    isPromptMinimised = false
                    presentationReady = false
                    return
                }
                // Dismiss every sibling first: presenting during the same transaction is the single-presentation race BUG-076 found.
                isPromptMinimised = false
                presentationReady = false
                dismissSiblingPresentations()
                while !presentationHostIsClear {
                    guard !Task.isCancelled,
                          promptIdentity == identity,
                          model.hasBlockingPrompt,
                          !isPromptMinimised
                    else { return }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                // Let the dismissal transaction finish committing; the loop above is driven by the actual presentation state, so this yield adds no timer.
                await Task.yield()
                guard presentationHostIsClear,
                      !Task.isCancelled,
                      promptIdentity == identity,
                      model.hasBlockingPrompt,
                      !isPromptMinimised
                else { return }
                presentationReady = true
            }
            .onChange(of: model.hasBlockingPrompt) { _, hasPrompt in
                if !hasPrompt {
                    isPromptMinimised = false
                    presentationReady = false
                }
            }
    }

    private var presentedPrompt: Binding<BlockingPrompt?> {
        Binding(
            get: {
                guard presentationReady else { return nil }
                return model.presentedBlockingPrompt(minimised: isPromptMinimised)
            },
            set: { newValue in
                // Swipe-to-dismiss or expire. Never treat this as an answer.
                if newValue == nil, model.hasBlockingPrompt {
                    isPromptMinimised = true
                    presentationReady = false
                }
            }
        )
    }

    /// SwiftUI's sibling presentations all resolve through UIKit's presentation host, so the approval sheet becomes eligible on dismissal completion rather than on animation timing.
    private var presentationHostIsClear: Bool {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes where scene.activationState != .unattached {
            let window = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first
            if window?.rootViewController?.presentedViewController != nil { return false }
        }
        return true
    }
}

/// The front door: a greeting, the model / effort / cwd / branch line, and up to three resume rows. A new `session.create` writes no DB row, so a brand-new chat is empty until the first prompt.
@MainActor
private struct ChatEmptyState: View {
    @Environment(\.hermes) private var t
    @Environment(AppModel.self) private var app
    let model: ChatModel

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s6) {
            Text("Ready when you are")
                .font(HermesFont.display)
                .foregroundStyle(t.text1)

            if !detailLine.isEmpty {
                Text(detailLine)
                    .font(HermesFont.subhead)
                    .foregroundStyle(t.text3)
            }

            let resumable = app.threads.filter { $0.id != model.storedSessionID }.prefix(3)
            if !resumable.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Resume")
                        .hermesCaption()
                        .foregroundStyle(t.text3)
                        .padding(.bottom, Space.s3)
                    ForEach(Array(resumable)) { thread in
                        NavigationLink(value: AppRoute.thread(.existing(thread))) {
                            FlatRow {
                                Text(thread.displayTitle)
                                    .font(HermesFont.callout)
                                    .foregroundStyle(t.text1)
                                    .lineLimit(1)
                            } trailing: {
                                Text(RelativeTime.short(epochSeconds: thread.lastActive))
                                    .font(HermesFont.footnote)
                                    .hermesNumeric()
                                    .foregroundStyle(t.text3)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, Space.s4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Space.s9)
    }

    private var detailLine: String {
        var parts: [String] = []
        if let m = model.info?.model, !m.isEmpty { parts.append(m) }
        if let e = model.info?.reasoningEffort, !e.isEmpty { parts.append(e) }
        if let cwd = model.info?.cwd, !cwd.isEmpty { parts.append((cwd as NSString).abbreviatingWithTildeInPath) }
        if let b = model.info?.branch, !b.isEmpty { parts.append(b) }
        return parts.joined(separator: " · ")
    }
}
