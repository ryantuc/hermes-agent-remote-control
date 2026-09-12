import HermesServeKit
import SwiftUI

/// The composer: one surface with the controls inside it, portrait carrying them on one row with the model beneath and landscape keeping both on a single row.
/// Attachment routing must stay as it is: images go to `image.attach_bytes`, and everything else, PDFs and video included, goes to `file.attach` and returns a `@file:` reference spliced into the text.
@MainActor
struct ComposerView: View {
    @Environment(\.hermes) private var t
    @Environment(AppModel.self) private var app

    @Bindable var model: ChatModel

    /// BUG-040: the height of the viewport this composer is laid out in, measured by `ComposerViewport`. Nil means nobody measured and the field falls back to the size-class rule.
    var viewportHeight: CGFloat?

    /// Which host is mounting this composer, and therefore how it is painted; only Chat's composer is glass over a transcript.
    var chrome: ComposerChrome = .opaque

    /// Everything on this surface that is not the field, measured rather than assumed. The seed is the portrait control row's resting arithmetic, which over-estimates the landscape row, so a preference that never arrives asks for a shorter field rather than a taller one.
    @State private var measuredChrome: CGFloat = 2 * Hit.min + Space.s3 + Space.s3

    @State private var showingOptions = false
    @State private var showingModelSheet = false
    @State private var showingEffortSheet = false
    @State private var showingFolderPicker = false
    @State private var showingWorktreeSheet = false
    @State private var showingSessionSheet = false
    #if DEBUG
    @State private var showingDirectoryBrowser = false
    #endif
    /// A quick action queued by the options sheet, applied on its dismissal: dismiss, then present.
    @State private var queuedQuickAction: ComposerQuickAction?
    @State private var queuedCustomise = false
    /// Stop, aimed at a turn this client did not start; confirmed rather than immediate.
    @State private var confirmingForeignStop = false
    /// Whether the composer field holds the keyboard. Plain `@State` and not `@FocusState`, because the field is a `UIViewRepresentable` that no view can claim with `.focused(_:)`, so SwiftUI's focus system discards writes to it.
    @State private var isFocused = false

    /// Landscape on a phone is compact height; horizontal size class cannot tell the two postures apart.
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    /// The pixel grid the field's lines are quantised to (BUG-039).
    @Environment(\.displayScale) private var displayScale
    @Environment(\.scenePhase) private var scenePhase

    // Voice
    @State private var dictation = Dictation()
    @State private var showingVoiceChat = false
    /// The draft as it stood when dictation started; partial results are spliced against this, never against the draft they are already editing.
    @State private var dictationBase = ""

    /// The phrase this conversation's resting state shows, picked once.
    @State private var restingPlaceholder = ""

    private var isConnected: Bool { app.connectionState.isOpen }

    /// While the transport is down the placeholder says so, as on desktop, because a cold start and a dropped connection read as different sentences. `.offline` and `.unauthorized` are neither, so the resting phrase stands.
    private var placeholder: String {
        switch app.connectionState {
        case .open: return restingPlaceholder
        case .idle, .connecting: return ComposerPlaceholders.starting
        case .reconnecting: return ComposerPlaceholders.reconnecting
        case .offline, .unauthorized: return restingPlaceholder
        }
    }

    var body: some View {
        VStack(spacing: Space.s4) {
            if !model.attachments.isEmpty {
                attachmentStrip
                    .measuredAsComposerChrome()
            }

            // The failure sits with the control that produced it, above the surface, where nothing can scroll it away.
            if case .failed(let message) = dictation.state {
                HStack(alignment: .top, spacing: Space.s3) {
                    Text(message)
                        .font(HermesFont.footnote)
                        .foregroundStyle(t.danger)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Dismiss") { dictation.cancel() }
                        .font(HermesFont.footnote)
                        .foregroundStyle(t.text3)
                        .frame(minHeight: Hit.min)
                }
                .accessibilityElement(children: .combine)
                .measuredAsComposerChrome()
            }

            VStack(alignment: .leading, spacing: 0) {
                // Not disabled while the transport is down, as on desktop: a flaky network should not block drafting, and `canSend` still guards the send itself on an open socket.
                // The field is a real `UITextView` and not SwiftUI's `TextField(axis: .vertical)`, which has been observed to refuse intrinsic-height growth and collapse to one internal-scrolling line.
                ZStack(alignment: .topLeading) {
                    GrowingComposerField(
                        text: $model.draft,
                        placeholder: placeholder,
                        textColor: t.text1,
                        maxLineCount: fieldLineCap,
                        isFocused: $isFocused
                    )
                    // The representable owns the field; the placeholder is SwiftUI's, drawn over the empty view and never letting a touch through.
                    if model.draft.isEmpty {
                        Text(placeholder)
                            .font(HermesFont.body)
                            .foregroundStyle(t.text3)
                            .padding(.top, Space.s5)
                            .padding(.leading, Space.s5)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .onAppear {
                    // First mount; later conversations are picked up by the identity `onChange` on the body.
                    if restingPlaceholder.isEmpty {
                        restingPlaceholder = ComposerPlaceholders.resting(isNewConversation: model.isDraft)
                    }
                }

                controlRow
                    // The foreign-turn confirmation belongs to both Stop controls, so it sits on the row that is always in the hierarchy.
                    .foreignStopConfirmation(isPresented: $confirmingForeignStop) {
                        model.stopTapped()
                    }
                    .padding(.horizontal, Space.s3)
                    .padding(.bottom, Space.s3)
                    // Measured after its padding: the field's budget has to leave room for the whole row, gap included.
                    .measuredAsComposerChrome()
            }
            // Fill and rest stroke are Desktop's: `input` behind a flat one-pixel neutral border that does not change on focus.
            // Not animated: `.animation(_:value:)` here would wrap the subtree that reports the composer's chrome height through a preference, republishing it every frame while the height budget it feeds is recomputing.
            // The focus stroke is a mobile divergence, deliberately: desktop has hover and a persistent caret to say where typing goes, and a phone has neither.
            // On the Chat host the well is left unfilled so the frost behind it shows through; filling it with `input` would put an opaque slab back over the transcript. Home still paints Desktop's fill.
            .background(
                chrome == .glass ? Color.clear : t.composerSurface,
                in: RoundedRectangle(cornerRadius: Radius.sheet, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.sheet, style: .continuous)
                    .strokeBorder(
                        isFocused ? t.composerFocusStroke : t.composerStroke,
                        // `strokeBorder` draws inward, so the extra pixel is spent inside the well and the composer's footprint, which feeds the field's height budget, is unchanged.
                        lineWidth: isFocused ? Stroke.focusRing : Stroke.hairline
                    )
            )
        }
        .padding(.horizontal, Space.s6)
        .padding(.vertical, Space.s4)
        // The Chat host's frost is painted once by `ChatView`, behind this whole stack, so there is nothing to paint here.
        .background(chrome == .glass ? Color.clear : t.canvas)
        .onPreferenceChange(ComposerChromeKey.self) { height in
            measuredChrome = height
        }
        // The keyboard's only owner: nothing else in the app holds a focus binding, so if this view does not put it away, nothing does.
        .onChange(of: isPresentingSheet) { _, presented in
            if presented { isFocused = false }
        }
        // Leaving the screen ends the composition, keyboard and microphone alike. `stop()` and never `cancel()`, so what was heard is delivered into the draft rather than thrown away.
        // BUG-012: `isFocused = false` is a request rather than a dismissal, because the field's only `resignFirstResponder` lives inside `updateUIView` and no body update follows a pop. `Keyboard.dismiss()` is responder-chain based and runs synchronously here.
        .onDisappear {
            isFocused = false
            Keyboard.dismiss()
            dictation.stop()
        }
        // Backgrounding is the other way off this screen and does not fire `onDisappear`. `.inactive` is excluded: it arrives for the app switcher and the notification-centre pull, neither of which is leaving.
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { dictation.stop() }
        }
        // Keyed on the model's identity rather than its session id, so a fresh session persisting its id is the same `ChatModel` and the phrase cannot flip under the user mid-stream.
        .onChange(of: ObjectIdentifier(model)) { _, _ in
            restingPlaceholder = ComposerPlaceholders.resting(isNewConversation: model.isDraft)
        }
        .sheet(isPresented: $showingOptions, onDismiss: applyQueuedQuickAction) {
            ComposerOptionsSheet(
                model: model,
                onQuickAction: { queuedQuickAction = $0 },
                onCustomise: { queuedCustomise = true }
            )
        }
        .sheet(isPresented: $showingModelSheet) {
            ModelEffortSheet(model: model)
        }
        .sheet(isPresented: $showingEffortSheet) {
            EffortSheet(model: model)
        }
        .sheet(isPresented: $showingFolderPicker) {
            FolderPickerSheet(currentPath: cwd) { path in
                await model.applyCwd(path)
            }
        }
        .sheet(isPresented: $showingWorktreeSheet) {
            WorktreeSheet(currentPath: cwd) { path in
                await model.applyCwd(path)
            }
        }
        .sheet(isPresented: $showingSessionSheet) {
            SessionSheetView(model: model)
        }
        .fullScreenCover(isPresented: $showingVoiceChat) {
            VoiceChatView(model: model)
        }
        .onChange(of: model.hasBlockingPrompt) { _, hasPrompt in
            if hasPrompt { dismissPresentationsForBlockingPrompt() }
        }
        // A minimised blocking prompt stays the only presentation entry point until it is answered or expires, so prompt B cannot contend with a sibling opened while prompt A was minimised.
        .allowsHitTesting(!model.hasBlockingPrompt)
        #if DEBUG
        // The browser is normally reached through the folder picker; the harness needs it one level up so a capture is a single launch.
        .sheet(isPresented: $showingDirectoryBrowser) {
            DirectoryBrowserSheet(startPath: cwd, currentPath: cwd) { path in
                await model.applyCwd(path)
            }
        }
        #endif
        #if DEBUG
        .onAppear {
            // Screenshot harness: `-hermesScreenshotSheet options|models|effort` presents a sheet without UI automation.
            let arguments = ProcessInfo.processInfo.arguments
            // `-hermesScreenshotDraft <text>` fills the field without sending.
            if let draftIndex = arguments.firstIndex(of: "-hermesScreenshotDraft"),
               draftIndex + 1 < arguments.count {
                model.draft = arguments[draftIndex + 1]
            }
            if let index = arguments.firstIndex(of: "-hermesScreenshotSheet"), index + 1 < arguments.count {
                switch arguments[index + 1] {
                case "options": showingOptions = true
                case "models": showingModelSheet = true
                case "folder": showingFolderPicker = true
                case "worktree": showingWorktreeSheet = true
                case "effort": showingEffortSheet = true
                case "session": showingSessionSheet = true
                case "browser": showingDirectoryBrowser = true
                case "voicechat": showingVoiceChat = true
                default: break
                }
            }
        }
        #endif
    }

    /// BUG-076: a consent request outranks every composer-owned sheet, and the `ChatView` host waits for these dismissals before presenting the approval sheet.
    private func dismissPresentationsForBlockingPrompt() {
        showingOptions = false
        showingModelSheet = false
        showingEffortSheet = false
        showingFolderPicker = false
        showingWorktreeSheet = false
        showingSessionSheet = false
        showingVoiceChat = false
        confirmingForeignStop = false
        queuedQuickAction = nil
        queuedCustomise = false
        #if DEBUG
        showingDirectoryBrowser = false
        #endif
    }

    // MARK: Quick actions — applied after the options sheet dismisses

    /// BUG-100: every jump carries the conversation's own route as its first element, so the absolute assignment `RootView` performs leaves the chat on the stack and Back returns to it.
    private func settingsRoute(_ screen: AppRoute) -> [AppRoute] {
        ComposerSettingsRoute.path(from: app.openRoute(for: model), to: screen)
    }

    private func applyQueuedQuickAction() {
        if queuedCustomise {
            queuedCustomise = false
            app.requestRoute(settingsRoute(.settingsScreen(.composerActions)))
            return
        }
        guard let action = queuedQuickAction else { return }
        queuedQuickAction = nil
        switch action {
        case .workingDirectory:
            showingFolderPicker = true
        case .repositoryBranch:
            showingWorktreeSheet = true
        case .contextUsage:
            showingSessionSheet = true
        case .personality:
            app.requestRoute(settingsRoute(.settingsScreen(.personality)))
        case .approvalMode:
            app.requestRoute(settingsRoute(.settingsScreen(.safety)))
        case .toolsets:
            app.requestRoute(settingsRoute(.settingsScreen(.advanced)))
        case .profile:
            app.requestRoute(settingsRoute(.settingsBackend))
        case .skills:
            app.requestRoute(settingsRoute(.settingsScreen(.capabilities)))
        }
    }

    /// Every sheet this view can raise, in one place, so a new one cannot be added that forgets to put the keyboard away.
    private var isPresentingSheet: Bool {
        if showingOptions || showingModelSheet || showingEffortSheet
            || showingFolderPicker || showingWorktreeSheet || showingSessionSheet
            || showingVoiceChat {
            return true
        }
        #if DEBUG
        if showingDirectoryBrowser { return true }
        #endif
        return false
    }

    /// The working directory both pickers read and write.
    private var cwd: String {
        model.isDraft ? (model.draftCwd ?? app.defaultCwd) : (model.info?.cwd ?? "")
    }

    // MARK: Control row — inside the surface

    /// Portrait takes two rows, the controls then the model beneath them, because one row is 40 pt short of what the model pill needs; landscape stays one row. Driven off `verticalSizeClass` and not horizontal, because a standard iPhone is compact width in either orientation.
    @ViewBuilder
    private var controlRow: some View {
        if verticalSizeClass == .compact {
            HStack(spacing: Space.s3) {
                plusButton
                modelPill
                effortPill
                Spacer(minLength: Space.s3)
                dictateButton
                voiceChatButton
                if model.showsSecondaryStop { secondaryStopButton }
                sendControl
            }
        } else {
            VStack(spacing: Space.s3) {
                HStack(spacing: Space.s3) {
                    plusButton
                    Spacer(minLength: Space.s3)
                    dictateButton
                    voiceChatButton
                    if model.showsSecondaryStop { secondaryStopButton }
                    sendControl
                }
                HStack(spacing: Space.s3) {
                    // The model pill takes what the effort pill leaves: the
                    // effort is content-sized and never truncates, the model
                    // name is the one that can.
                    modelPill
                        .frame(maxWidth: .infinity, alignment: .leading)
                    effortPill
                }
            }
        }
    }

    private var plusButton: some View {
        Button {
            showingOptions = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(t.text2)
                .frame(width: 34, height: 34)
                .background(t.fill2, in: Circle())
        }
        .buttonStyle(IconButtonStyle())
        .disabled(!isConnected)
        .accessibilityLabel("Options")
    }

    /// The composer may take at most two thirds of the viewport it sits in, the remaining third belonging to the conversation. A proportion rather than a number of points, because any constant would break at some phone or type size instead of degrading with the viewport.
    private static let viewportShare: CGFloat = 2.0 / 3.0

    /// And never fewer than three lines where the screen physically holds them, since the share alone can land on one line on a small phone with the keyboard up. Bounded by what actually fits, so the floor can never overflow the way an unbounded cap would.
    private static let minimumLines = 3

    /// How far the field may grow: the smaller of what the viewport can spare and the 16-line ceiling. BUG-040: the ceiling alone is a cap on the text and not on the screen, and a long draft pushed the control row under the keyboard.
    private var fieldLineCap: Int {
        let ceiling = verticalSizeClass == .compact ? 5 : 16
        guard let viewportHeight, viewportHeight > 0 else { return ceiling }
        let share = GrowingComposerField.lineCount(
            fitting: viewportHeight * Self.viewportShare - chromeHeight,
            upTo: ceiling, displayScale: displayScale
        )
        // What the viewport holds at all, the composer and nothing else; the floor is allowed up to here and no further.
        let fits = GrowingComposerField.lineCount(
            fitting: viewportHeight - chromeHeight,
            upTo: ceiling, displayScale: displayScale
        )
        return max(min(Self.minimumLines, fits), share)
    }

    /// Everything this surface costs that is not the field, measured where it can be, because the control row's height depends on orientation, Dynamic Type size and which controls are in it.
    private var chromeHeight: CGFloat {
        var rowsAboveField = model.attachments.isEmpty ? 0 : 1
        if case .failed = dictation.state { rowsAboveField += 1 }
        return measuredChrome
            + 2 * Space.s4
            + CGFloat(rowsAboveField) * Space.s4
    }

    // MARK: Dictate

    /// Always present: a control that disappears as soon as you type is a control you cannot use to add to what you typed.
    private var dictateButton: some View {
        let active = dictation.isListening
        let busy = dictation.state == .transcribing
        return Group {
            if VoicePreferences.tapToToggle {
                Button { toggleDictation() } label: { dictateGlyph(active: active, busy: busy) }
                    .buttonStyle(IconButtonStyle())
            } else {
                // Push and hold: a drag with no minimum distance is the only spelling that reports press and release, where a `LongPressGesture` fires once and never says the finger lifted.
                dictateGlyph(active: active, busy: busy)
                    .contentShape(Circle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in if !dictation.isListening && !busy { startDictation() } }
                            .onEnded { _ in if dictation.isListening { dictation.stop() } }
                    )
            }
        }
        .disabled(!isConnected || busy)
        // VoiceOver cannot hold a button, so the direct action is the whole control for those users.
        .accessibilityLabel(active ? "Stop dictating" : "Dictate")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { toggleDictation() }
    }

    private func dictateGlyph(active: Bool, busy: Bool) -> some View {
        ZStack {
            Circle()
                .fill(active ? t.danger : t.fill2)
                .frame(width: 34, height: 34)
            if busy {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: active ? "mic.fill" : "mic")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(active ? t.actionInk : t.text2)
                    // The level ring is the only feedback that the mic is hearing anything; a red circle alone looks identical either way.
                    .scaleEffect(active ? 1 + 0.18 * dictation.level : 1)
                    .animation(Motion.quick, value: dictation.level)
            }
        }
        .frame(width: Hit.min, height: Hit.min)
    }

    private func toggleDictation() {
        if dictation.isListening { dictation.stop() } else { startDictation() }
    }

    private func startDictation() {
        HapticFeedback.selection()
        dictationBase = model.draft
        dictation.start(
            engine: VoicePreferences.engine,
            audioAPI: app.audioAPI,
            onPartial: { partial in
                guard VoicePreferences.insertAsYouSpeak,
                      VoicePreferences.engine.supportsPartialResults else { return }
                // Against the base and not the current draft: partials revise themselves, so stacking them repeats every word.
                model.draft = DictationSplice.replacingPartial(partial, base: dictationBase)
            },
            onFinal: { text in
                model.draft = DictationSplice.appending(text, to: dictationBase)
            }
        )
    }

    // MARK: Voice chat

    private var voiceChatButton: some View {
        Button {
            showingVoiceChat = true
        } label: {
            Image(systemName: "waveform")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(t.text2)
                .frame(width: 34, height: 34)
                .background(t.fill2, in: Circle())
        }
        .buttonStyle(IconButtonStyle())
        .disabled(!isConnected)
        .accessibilityLabel("Voice chat")
    }

    /// The model, and nothing else; `EffortRung` keeps its place in the model drawer, where the name is not always visible.
    private var modelPill: some View {
        ComposerPill(isInteractive: isAdjustable, action: { showingModelSheet = true }) {
            ValueView(pillState) {
                Text(modelName)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .accessibilityLabel(pillAccessibilityLabel)
    }

    /// Effort, in words, one tap away. Removed rather than disabled when the model reports no reasoning configuration at all, because the backend distinguishes `""` (no reasoning config) from `"none"` (reasoning explicitly disabled).
    @ViewBuilder
    private var effortPill: some View {
        if !effort.isEmpty {
            ComposerPill(isInteractive: isAdjustable, action: { showingEffortSheet = true }) {
                HStack(spacing: Space.s3) {
                    ValueView(effortPillState) {
                        Text(effortLabel)
                            .lineLimit(1)
                    }
                    Text(verbatim: "⌄")
                        .font(HermesFont.caption)
                        .foregroundStyle(t.text4)
                        .accessibilityHidden(true)
                }
            }
            .fixedSize()
            .accessibilityLabel("Reasoning effort: \(effortLabel)")
        }
    }

    private var effortLabel: String {
        ReasoningEffort(backendValue: effort)?.label ?? effort
    }

    /// A live session's pill reports `session.info` and nothing else; a draft shows its local override, else the backend's global default.
    private var modelName: String {
        if let info = model.info { return info.model }
        if model.isDraft { return model.draftModelSlug ?? app.defaultModel }
        return ""
    }

    private var effort: String {
        if let info = model.info { return info.reasoningEffort }
        if model.isDraft { return model.draftEffort ?? app.defaultEffort }
        return ""
    }

    /// Two pills, two pending dots: a deferred model write must not put the
    /// amber dot on the effort the user did not touch, and the reverse.
    private var pillState: ValueState {
        if model.pendingModelWrite { return .pending }
        if modelName.isEmpty { return .unknown }
        return isConnected ? .live : .stale
    }

    private var effortPillState: ValueState {
        if model.pendingEffortWrite { return .pending }
        return isConnected ? .live : .stale
    }

    /// A session's writes go through `config.set`, which needs a session id, or they land on the backend's global default; a draft adjusts locally and `session.create` carries the choice.
    private var isAdjustable: Bool {
        isConnected && (model.runtimeSessionID != nil || model.isDraft)
    }

    /// Model only; the effort pill carries its own label.
    private var pillAccessibilityLabel: String {
        "Model: \(modelName.isEmpty ? "not reported" : modelName)"
    }

    /// Send and stop occupy the same position, so the target never moves under a thumb mid-turn; as on desktop, Send stays while a turn runs and only an empty composer shows Stop.
    /// Stop is kept for a turn another client started, with the label saying whose turn it is and a confirmation standing between a thumb and someone else's work.
    @ViewBuilder
    private var sendControl: some View {
        if model.showsStopControl {
            Button {
                if model.isForeignStop {
                    confirmingForeignStop = true
                } else {
                    model.stopTapped()
                }
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(t.actionInk)
                    .frame(width: 34, height: 34)
                    .background(t.danger, in: Circle())
            }
            .buttonStyle(IconButtonStyle())
            .accessibilityLabel(model.isForeignStop ? "Stop work another client started" : "Stop")
        } else {
            Button {
                // Only on Home, where a send ends that composition; inside a chat the user is likely to type again in the next few seconds.
                if model.isDraft { isFocused = false }
                model.sendTapped()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(t.actionInk)
                    .frame(width: 34, height: 34)
                    .background(model.canSend ? t.action : t.action.opacity(0.18), in: Circle())
            }
            .buttonStyle(IconButtonStyle())
            .disabled(!model.canSend)
            .accessibilityLabel("Send")
        }
    }

    /// Compact Stop beside Send while a turn is active with text or attachments in the composer, because the primary slot is Send then and the desktop's Esc has no equivalent on a phone.
    private var secondaryStopButton: some View {
        Button {
            if model.isForeignStop {
                confirmingForeignStop = true
            } else {
                model.stopTapped()
            }
        } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(t.danger)
                .frame(width: 30, height: 30)
                .background(t.danger.opacity(0.14), in: Circle())
        }
        .buttonStyle(IconButtonStyle())
        .accessibilityLabel(model.isForeignStop ? "Stop work another client started" : "Stop")
    }

    // MARK: Attachments — the strip sits above the surface

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.s4) {
                ForEach(model.attachments) { attachment in
                    HStack(spacing: Space.s3) {
                        Text(attachment.filename)
                            .font(HermesFont.footnote)
                            .foregroundStyle(t.text1)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(attachment.byteDescription)
                            .font(HermesFont.footnote)
                            .foregroundStyle(t.text3)
                        Button {
                            model.removeAttachment(id: attachment.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(t.text3)
                                .frame(width: Hit.min, height: Hit.min)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(attachment.filename)")
                    }
                    .padding(.leading, Space.s5)
                    .frame(height: 34)
                    .frame(maxWidth: 230)
                    .background(t.surface2, in: Capsule())
                }
            }
        }
        .frame(height: Hit.min)
    }
}

/// How a host paints the composer: `.opaque` is the Desktop-fidelity fill and border on a `canvas` strip, and `.glass` drops both fills so the host's frost shows through.
enum ComposerChrome: Equatable {
    case opaque
    case glass
}

// MARK: - The viewport the composer has to fit in (BUG-040)

/// BUG-040: the height the host was actually proposed, already net of the navigation bar, the safe areas and the keyboard, which SwiftUI publishes as a bottom safe-area inset.
/// Pinning the stack to that height with `.bottom` alignment sends any overflow off the top, where the transcript is scrollable, instead of off the bottom into the keyboard.
@MainActor
struct ComposerViewport<Content: View>: View {
    @ViewBuilder var content: (CGFloat) -> Content

    var body: some View {
        GeometryReader { proxy in
            content(proxy.size.height)
                .frame(height: proxy.size.height, alignment: .bottom)
        }
    }
}

// MARK: - Chrome measurement

/// The composer's non-field height; `reduce` adds rather than replaces, because the rows are siblings and the budget has to leave room for all of them at once.
private struct ComposerChromeKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value += nextValue()
    }
}

private extension View {
    /// Report this row's rendered height into the composer's chrome budget.
    func measuredAsComposerChrome() -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(key: ComposerChromeKey.self, value: proxy.size.height)
            }
        )
    }
}
