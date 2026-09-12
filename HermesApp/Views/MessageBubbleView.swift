import HermesServeKit
import SwiftUI
import UIKit

/// The affordances under a completed assistant message.
struct MessageActions {
    var canBranch = false
    var onBranch: (() -> Void)?
    var onRetry: (() -> Void)?
}

/// One transcript row. Flat rather than boxed: the assistant turn is bare text on the canvas, and the user turn's fill is the single exception because it is the only way to tell speakers apart without avatars.
@MainActor
struct MessageBubbleView: View {
    let entry: ChatEntry
    /// Present only on a failed optimistic send: the bubble's inline Retry.
    var onRetry: (() -> Void)?
    /// BUG-141: present only on a failed send the backend refused because another surface owns the conversation, and nil everywhere else.
    var onStartNewChat: (() -> Void)?
    /// Present only on completed assistant messages.
    var actions: MessageActions?
    /// The backend's own start for the running turn, when it stated one; nil leaves the counter on this client's local stopwatch.
    var turnStartedAt: Date?

    /// `.session` is the environment default; `ChatView` sets `.conversation` for a bot thread and nothing else does.
    @Environment(\.transcriptStyle) private var style

    var body: some View {
        switch entry.kind {
        case .user: UserTurn(entry: entry, onRetry: onRetry, onStartNewChat: onStartNewChat)
        case .assistant:
            // One grammar for message actions in both styles, on the same `MessageActionRow` rather than a variant, because two rows would diverge the first time either was touched.
            // Desktop's hover reveal is deliberately not copied: there is no hover on a phone, and a long-press reveal would reintroduce the `UIContextMenuInteraction` that beats the text-selection interaction underneath (BUG-044).
            VStack(alignment: .leading, spacing: Space.s3) {
                AssistantTurn(entry: entry, turnStartedAt: turnStartedAt)
                if let actions {
                    MessageActionRow(entry: entry, actions: actions)
                }
            }
        case .tool:
            if let tool = entry.tool { ToolCardView(activity: tool) }
        case .notice: NoticeRow(entry: entry)
        case .system: SystemRow(entry: entry)
        }
    }
}

/// Timestamp plus Branch, Copy, Read aloud and Retry, always visible because there is no hover on a phone. Only rendered on `message.complete`.
@MainActor
struct MessageActionRow: View {
    @Environment(\.hermes) private var t
    let entry: ChatEntry
    let actions: MessageActions

    private var readAloud = ReadAloud.shared

    /// BUG-117: the copy that has just happened, if one has.
    @State private var confirmed: CopyConfirmation?

    init(entry: ChatEntry, actions: MessageActions) {
        self.entry = entry
        self.actions = actions
    }

    var body: some View {
        HStack(spacing: Space.s2) {
            // Absolute time and not relative, because a transcript is a record.
            Text(entry.timestamp.formatted(date: .omitted, time: .shortened))
                .font(HermesFont.footnote)
                .hermesNumeric()
                .foregroundStyle(t.text3)
                .padding(.trailing, Space.s3)

            // Membership follows Settings, and the row itself stays because the timestamp is the record.
            if TranscriptPreferences.showBranchAction, actions.canBranch, let onBranch = actions.onBranch {
                iconButton("arrow.triangle.branch", label: "Branch into a new chat", action: onBranch)
            }
            if TranscriptPreferences.showCopyAction {
                copyButton(.message, icon: "doc.on.doc", label: "Copy message")
            }
            // BUG-044: the only place the trace's copy can live, since the truncated preview is not selectable and the expanded trace is a disclosure the reader has to open first.
            if TranscriptPreferences.showCopyAction, !entry.reasoning.isEmpty {
                copyButton(.reasoning, icon: "brain", label: "Copy reasoning")
            }
            if TranscriptPreferences.showReadAloudAction {
                iconButton(
                    readAloud.speakingID == entry.id ? "stop.fill" : "speaker.wave.2",
                    label: readAloud.speakingID == entry.id ? "Stop reading" : "Read aloud"
                ) {
                    readAloud.toggle(id: entry.id, text: entry.text)
                }
            }
            if TranscriptPreferences.showRetryAction, let onRetry = actions.onRetry {
                iconButton("arrow.counterclockwise", label: "Retry this turn", action: onRetry)
            }
            if let confirmed {
                // The row already ends in a `Spacer`, so this costs no height and moves nothing.
                Text(confirmed.kind.label)
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.ok)
                    .transition(.opacity)
                    .accessibilityAddTraits(.isStaticText)
                    // Lives only as long as there is something to clear; on the row instead it would start a no-op task per message every time one scrolls into view. `.task` rather than a detached `Task` so leaving the screen cancels the timer.
                    .task(id: confirmed.token) {
                        try? await Task.sleep(nanoseconds: CopyConfirmation.durationNanoseconds)
                        guard !Task.isCancelled else { return }
                        self.confirmed = nil
                    }
            }
            Spacer(minLength: 0)
        }
        .animation(Motion.quick, value: confirmed)
    }

    /// A copy action: it writes the clipboard, it says so, and it says which of the two it was.
    private func copyButton(_ kind: CopyConfirmation.Kind, icon: String, label: String) -> some View {
        let isConfirmed = confirmed?.kind == kind
        return iconButton(
            isConfirmed ? "checkmark" : icon,
            label: label,
            tint: isConfirmed ? t.ok : t.text3
        ) {
            UIPasteboard.general.string = kind.payload(entry)
            HapticFeedback.copied()
            confirmed = CopyConfirmation(kind: kind)
        }
    }

    private func iconButton(
        _ systemImage: String,
        label: String,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15))
                .foregroundStyle(tint ?? t.text3)
        }
        .buttonStyle(IconButtonStyle())
        .accessibilityLabel(label)
    }
}

// MARK: - BUG-117: what a copy says back

/// The transient acknowledgement a copy action under a reply leaves behind, answered in place rather than as a toast because the transcript already carries enough floating surfaces.
struct CopyConfirmation: Equatable {
    enum Kind: String, CaseIterable, Equatable {
        /// The answer itself.
        case message
        /// The reasoning trace behind it, never the answer.
        case reasoning

        /// What goes on the clipboard.
        func payload(_ entry: ChatEntry) -> String {
            switch self {
            case .message: return entry.text
            case .reasoning: return entry.reasoning
            }
        }

        /// What the row says afterwards; the two are different sentences, so a reader who tapped the brain by mistake knows they are holding a thinking trace rather than the answer.
        var label: String {
            switch self {
            case .message: return "Copied"
            case .reasoning: return "Reasoning copied"
            }
        }
    }

    let kind: Kind
    /// Restarts the timer on every tap, so a second tap gets a full showing rather than the remainder of the first one's.
    let token = UUID()

    /// Long enough to be read once the eye gets back to the row, short enough that it is gone before it reads as part of the transcript.
    static let duration: TimeInterval = 1.2

    static var durationNanoseconds: UInt64 { UInt64(duration * 1_000_000_000) }
}

// MARK: - User

/// Right-aligned, 86% max, filled at the enclosure radius, with no tail and no timestamp: the day separator and the ordering carry that.
@MainActor
private struct UserTurn: View {
    @Environment(\.hermes) private var t
    /// Tool cards in the same transcript draw their border at one device pixel, and a 1 pt bubble border beside a 0.33 pt card border reads as two design systems.
    @Environment(\.displayScale) private var displayScale
    let entry: ChatEntry
    var onRetry: (() -> Void)?
    /// BUG-141: the ownership refusal's primary action.
    var onStartNewChat: (() -> Void)?

    /// BUG-044: no `.contextMenu` here, because a `UIContextMenuInteraction`'s long-press recogniser beats the text-selection interaction under it, so the loupe, the drag handles and the system's own Copy never got the gesture.
    var body: some View {
        turn
    }

    private var turn: some View {
        HStack {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: Space.s3) {
                if !entry.imageRefs.isEmpty {
                    AttachmentChips(refs: entry.imageRefs)
                }
                if !entry.text.isEmpty {
                    // BUG-058: the words on a read-only `UITextView`, so iOS's own loupe and handles answer the long press.
                    SelectableText(entry.text, style: HermesFont.body, color: entry.isError ? t.text3 : t.text1)
                        .padding(.horizontal, Space.s5)
                        .padding(.vertical, 11)
                        // The user's turn gets its own ground rather than the composer's, because sharing one flattens the speaker hierarchy. Desktop distinguishes this bubble by its border more than its fill, and both are reproduced in `HermesTokens`.
                        .background(
                            t.userBubble,
                            in: RoundedRectangle(cornerRadius: Radius.enclosure, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Radius.enclosure, style: .continuous)
                                .strokeBorder(t.userBubbleStroke, lineWidth: 1 / displayScale)
                        )
                }
                if entry.isError {
                    // The rollback is visible and never silent: the failed send stays in place, dimmed, with its reason and a Retry.
                    if !entry.errorText.isEmpty {
                        Text(entry.errorText)
                            .font(HermesFont.footnote)
                            .foregroundStyle(t.danger)
                            .multilineTextAlignment(.trailing)
                    }
                    // BUG-141: when another surface owns this conversation, Retry cannot succeed until that surface lets go, so "New chat" leads and Retry drops to second.
                    if let onStartNewChat {
                        Button("New chat", action: onStartNewChat)
                            .buttonStyle(PrimaryButtonStyle())
                            .frame(maxWidth: 120)
                    }
                    if let onRetry {
                        Button("Retry", action: onRetry)
                            .buttonStyle(SecondaryButtonStyle())
                            .frame(maxWidth: 120)
                    }
                }
                if let tag = statusTag {
                    Text(tag)
                        .font(HermesFont.footnote)
                        .foregroundStyle(t.text3)
                }
            }
            // `.infinity * 0.86` evaluates to `.infinity`, so the cap is bound to the container's width instead.
            .containerRelativeFrame(.horizontal, alignment: .trailing) { width, _ in
                width * 0.86
            }
        }
    }

    private var statusTag: String? {
        switch entry.noticeKind {
        case "queued": return "Queued — runs after the current turn"
        case "correction": return "Mid-turn correction"
        default: return nil
        }
    }
}

// MARK: - Assistant

@MainActor
private struct AssistantTurn: View {
    @Environment(\.hermes) private var t
    @Environment(\.transcriptStyle) private var style
    /// Tool cards in the same transcript draw their border at one device pixel, and a 1 pt bubble border beside a 0.33 pt card border reads as two design systems.
    @Environment(\.displayScale) private var displayScale
    let entry: ChatEntry
    var turnStartedAt: Date?

    init(entry: ChatEntry, turnStartedAt: Date? = nil) {
        self.entry = entry
        self.turnStartedAt = turnStartedAt
    }

    var body: some View {
        if style == .conversation {
            conversationBubble
        } else {
            sessionColumn
        }
    }

    // MARK: What the message says, and what it delivered

    /// A `MEDIA:` token is pulled out of the words and drawn as a thumbnail or a file chip. Computed in the view rather than at entry-build, so it applies to messages already in the transcript and leaves `ChatEntry.text` as what the backend actually said.
    /// While the turn is streaming only finished lines are extracted, because a partial tail satisfies the end-of-text anchor and would yield a truncated path that resolves to nothing.
    private var media: (text: String, refs: [MediaDirective.Ref]) {
        entry.isStreaming
            ? MediaDirective.extractCompleted(from: entry.text)
            : MediaDirective.extract(from: entry.text)
    }

    // MARK: Sessions grammar

    private var sessionColumn: some View {
        VStack(alignment: .leading, spacing: Space.s5) {
            if !entry.reasoning.isEmpty {
                ReasoningBlock(
                    text: entry.reasoning,
                    isStreaming: entry.isStreaming,
                    duration: entry.reasoningDuration
                )
            }

            if !media.text.isEmpty {
                MarkdownText(text: media.text)
            }

            if !media.refs.isEmpty {
                MediaAttachmentRow(refs: media.refs)
            }

            if entry.isStreaming {
                StreamingIndicator(hasText: !entry.text.isEmpty, turnStartedAt: turnStartedAt)
            }

            annotations
        }
        // BUG-044: no `.contextMenu` here, because its long press beat the text-selection interaction on every paragraph, code block and table cell underneath.
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Conversation grammar

    /// A left bubble mirroring the user turn's right one, with no avatar inside the thread because the header carries the identity. The reasoning trace is absent here and moves to the `ConversationDisclosure` under the bubble.
    private var conversationBubble: some View {
        HStack {
            VStack(alignment: .leading, spacing: Space.s3) {
                if !media.text.isEmpty || entry.isStreaming {
                    VStack(alignment: .leading, spacing: Space.s4) {
                        if !media.text.isEmpty {
                            // `hugsContent` is why a short reply gets a short bubble: `MarkdownText` otherwise ends in `.frame(maxWidth: .infinity)` and inflates the ground to the full cap.
                            MarkdownText(text: media.text, hugsContent: true)
                        }
                        // Inside the bubble on purpose: a dot and a counter floating beside an empty bubble reads as two turns.
                        if entry.isStreaming {
                            StreamingIndicator(hasText: !entry.text.isEmpty, turnStartedAt: turnStartedAt)
                        }
                    }
                    .padding(.horizontal, Space.s5)
                    .padding(.vertical, 11)
                    // The bot's turn needs its own ground for the same reason the user's does.
                    .background(
                        t.botBubble,
                        in: RoundedRectangle(cornerRadius: Radius.enclosure, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.enclosure, style: .continuous)
                            .strokeBorder(t.botBubbleStroke, lineWidth: 1 / displayScale)
                    )
                }

                // Outside the bubble, not inside it: a thumbnail drawn on the bot's own ground reads as part of the sentence rather than as what the sentence produced.
                if !media.refs.isEmpty {
                    MediaAttachmentRow(refs: media.refs)
                }

                annotations
            }
            // Mirrors `UserTurn`'s cap, leading instead of trailing. The frame is transparent and only says how wide the bubble may get, which is why the hug belongs on `MarkdownText` above: a `maxWidth` cannot be expressed as a share of a container.
            .containerRelativeFrame(.horizontal, alignment: .leading) { width, _ in
                width * 0.86
            }
            Spacer(minLength: 40)
        }
        // BUG-058: no `.contextMenu` here, so a bot thread can raise iOS's selection callout; everything the menu carried is on `MessageActionRow` under the bubble.
    }

    /// Interim, stopped or failed, stated beside the answer rather than in place of it and never inside the bubble.
    @ViewBuilder
    private var annotations: some View {
        if entry.isInterim {
            Text("Interim update")
                .font(HermesFont.footnote)
                .foregroundStyle(t.text3)
        }

        if entry.status == "interrupted" {
            Text("Stopped")
                .font(HermesFont.footnote)
                .foregroundStyle(t.text3)
        }

        if entry.isError, !entry.errorText.isEmpty {
            // `message.complete {status: "error"}` is the only failure signal a turn gives, and it goes below the text rather than replacing it.
            TurnError(
                message: entry.errorText,
                keptPartialText: entry.isPartial,
                surface: entry.errorSurface
            )
        }
    }
}

/// The reasoning disclosure, which always renders something: `mode` is a local preference and the only thing it decides is whether `.full` opens the trace without a tap.
/// Internal rather than file-private because `ConversationDisclosure` renders this exact block inside its expansion, so the two grammars show one reasoning control rather than two that can drift.
@MainActor
struct ReasoningBlock: View {
    enum Mode: String { case collapsed, truncated, full }

    @Environment(\.hermes) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("hermes.reasoning.mode") private var storedMode = Mode.truncated.rawValue
    @State private var isExpanded = false
    @State private var showingReader = false
    /// Two lines of `HermesFont.subhead`, scaled because the text inside it is.
    @ScaledMetric(relativeTo: .subheadline) private var previewHeight: CGFloat = 34

    let text: String
    let isStreaming: Bool
    /// How long the thinking phase ran, when this client watched it run; nil on a transcript loaded from history and nil for a trace that arrived whole.
    let duration: TimeInterval?

    private var mode: Mode { Mode(rawValue: storedMode) ?? .truncated }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            Button {
                // BUG-009: discrete, because expanding swaps two lines for the whole trace inside a scroll view pinned with `.defaultScrollAnchor(.bottom)`, and animating it puts a second layout drive on that scroll view.
                isExpanded.toggle()
            } label: {
                HStack(spacing: Space.s4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(t.text4)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        // Scoped to the chevron and dropped under Reduce Motion.
                        .animation(reduceMotion ? nil : Motion.quick, value: isExpanded)
                    Text(headerTitle)
                        .font(HermesFont.subhead)
                        .foregroundStyle(t.text3)
                }
                .frame(minHeight: Hit.min, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded || mode == .full {
                expandedTrace
            } else {
                // BUG-017: an `else` rather than `else if mode == .truncated`, so there is no state in which this control renders nothing.
                preview
            }
        }
    }

    /// BUG-017: the expanded trace gets its own scroller inside a 380 pt budget, so the transcript's height is unchanged and a long trace is reachable rather than clipped.
    /// `scrollPosition` and `defaultScrollAnchor` are deliberately not used to pin the tail while streaming, because a second layout drive inside this transcript is BUG-009's lockup mechanism.
    private var expandedTrace: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            // No box: a 1 pt left rule, and its own scroller.
            ScrollView(.vertical, showsIndicators: true) {
                // BUG-124: `.textSelection(.enabled)` raises nothing in this transcript, so the trace is a `SelectableText`.
                SelectableText(text, style: HermesFont.subhead, color: t.text3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 380)
            .scrollBounceBehavior(.basedOnSize)
            .padding(.leading, Space.s5)
            .overlay(alignment: .leading) {
                Rectangle().fill(t.stroke3).frame(width: 1)
            }

            if text.count > Self.readerThreshold {
                Button { showingReader = true } label: {
                    Text("Show all \(text.count) characters")
                        .font(HermesFont.subhead)
                        .foregroundStyle(t.action)
                        .frame(minHeight: Hit.min, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, Space.s5)
            }
        }
        .fullScreenCover(isPresented: $showingReader) {
            FullScreenCodeReader(text: text)
        }
    }

    /// Past this, a 380 pt window is a keyhole and the full-screen reader is the honest way to read the trace.
    private static let readerThreshold = 4_000

    /// The two newest lines of the trace, fading out at the old edge. A bottom-aligned clipping frame rather than a line limit, because `lineLimit` tail-truncates and would eat the newest text.
    private var preview: some View {
        Text(tail)
            .font(HermesFont.subhead)
            .foregroundStyle(t.text3)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Full intrinsic height first, so the frame below clips rather than proposing a height the `Text` would truncate itself into.
            .fixedSize(horizontal: false, vertical: true)
            .frame(height: previewHeight, alignment: .bottom)
            .clipped()
            .padding(.leading, Space.s5)
            .mask(
                LinearGradient(
                    colors: [.clear, .black, .black],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
    }

    /// The window the preview lays out, wide enough to fill two lines at any text size; the frame above decides how much of it is on screen.
    private var tail: String {
        String(text.suffix(220)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A nil duration is a first-class answer rather than a zero: a transcript loaded from history never watched the think happen, and a trace that arrived whole has no interval to report.
    private var headerTitle: String {
        if isStreaming { return "Thinking" }
        guard let duration else { return "Thought" }
        return "Thought for \(RelativeTime.duration(duration))"
    }
}

@MainActor
struct TurnError: View {
    @Environment(\.hermes) private var t
    let message: String
    var keptPartialText = false
    /// The backend's own classification of the failure; nil is the common case and changes nothing.
    var surface: ErrorSurface?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            // BUG-124: the backend's message is selectable; the explanatory lines below are the app's own words and stay plain `Text`.
            SelectableText(message, style: HermesFont.subhead, color: t.text1)
            // Nothing here gates the card: an absent descriptor, an unknown layer or an unset `retryable` each drops its own line and leaves the rest standing.
            if let note = surface?.layerNote {
                Text(note)
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.text3)
            }
            if let surface, surface.isNotRetryable {
                Text("Sending this again will fail the same way.")
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.text3)
            } else if let surface, surface.isRetryable {
                Text("Worth sending again.")
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.text3)
            }
            if keptPartialText {
                Text("The reply above is what streamed before the failure.")
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.text3)
            }
        }
        .padding(Space.s5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(t.dangerFill, in: RoundedRectangle(cornerRadius: Radius.enclosure, style: .continuous))
    }
}

/// A pulsing dot and an elapsed counter, with no typewriter and no per-token animation: text appends into the live paragraph and nothing may imply per-message identity mid-stream.
@MainActor
private struct StreamingIndicator: View {
    @Environment(\.hermes) private var t
    let hasText: Bool
    /// The backend's start for this turn, when it stated one.
    var turnStartedAt: Date?
    /// When this client started watching: the fallback and not the answer, since it is re-stamped every time SwiftUI builds the view.
    @State private var started = Date()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: Space.s4) {
                PulsingDot()
                Text(RelativeTime.duration(TurnElapsed.seconds(
                    backendStart: turnStartedAt,
                    localStart: started,
                    now: context.date
                )))
                    .font(HermesFont.footnote)
                    .hermesNumeric()
                    .foregroundStyle(t.text3)
                if !hasText {
                    Text("Working…")
                        .font(HermesFont.footnote)
                        .foregroundStyle(t.text3)
                }
            }
        }
        .accessibilityLabel("Hermes is replying")
    }
}

// MARK: - Notices and system rows

/// Notices are information rather than consequence, so they get no enclosure.
@MainActor
private struct NoticeRow: View {
    @Environment(\.hermes) private var t
    let entry: ChatEntry

    var body: some View {
        HStack(alignment: .top, spacing: Space.s4) {
            Circle()
                .fill(entry.noticeKind == "error" ? t.danger : t.text4)
                .frame(width: 6, height: 6)
                .padding(.top, 6)
            Text(entry.text)
                .font(HermesFont.subhead)
                .foregroundStyle(t.text3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

@MainActor
private struct SystemRow: View {
    @Environment(\.hermes) private var t
    let entry: ChatEntry

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            Text("Hermes")
                .hermesCaption()
                .foregroundStyle(t.text3)
            MarkdownText(text: entry.text, textColor: t.text2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Centred footnote, with no pill and no rule.
@MainActor
struct DaySeparator: View {
    @Environment(\.hermes) private var t
    let label: String

    var body: some View {
        Text(label)
            .font(HermesFont.footnote)
            .foregroundStyle(t.text3)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, Space.s3)
    }
}

/// A `data:` URL renders inline immediately; a gateway-local path resolves through `GET /api/media?path=` and renders inline once the bytes arrive.
@MainActor
private struct AttachmentChips: View {
    @Environment(\.hermes) private var t
    let refs: [String]

    @State private var viewing: ViewerItem?

    /// Encoded bytes only: the full bitmap is decoded inside ``MediaViewer`` and released when the cover dismisses.
    struct ViewerItem: Identifiable {
        let id: String
        let data: Data
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: Space.s3) {
            ForEach(Array(refs.enumerated()), id: \.offset) { index, ref in
                if let pair = Self.inlineThumbnail(ref) {
                    thumbnail(pair.image, data: pair.data, id: "inline-\(index)")
                } else if Self.isResolvablePath(ref) {
                    RemoteMediaImage(path: ref) { data, id in
                        viewing = ViewerItem(id: id, data: data)
                    }
                } else {
                    nameChip(ref)
                }
            }
        }
        .fullScreenCover(item: $viewing) { item in
            MediaViewer(data: item.data)
        }
    }

    private func thumbnail(_ image: UIImage, data: Data, id: String) -> some View {
        Button {
            viewing = ViewerItem(id: id, data: data)
        } label: {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 220, maxHeight: 220)
                .clipShape(RoundedRectangle(cornerRadius: Radius.enclosure, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Attached image. Double tap to view full screen.")
    }

    private func nameChip(_ ref: String) -> some View {
        Text(Self.displayName(ref))
            .font(HermesFont.footnote)
            .foregroundStyle(t.text2)
            .padding(.horizontal, Space.s5)
            .frame(height: 30)
            .background(t.surface2, in: Capsule())
    }

    /// Downsampled chip for an in-chat `data:image/…` ref, returning the encoded bytes too so the viewer can full-decode on open.
    private static func inlineThumbnail(_ ref: String) -> (image: UIImage, data: Data)? {
        guard let data = DownsampledImage.data(fromDataURL: ref),
              let image = DownsampledImage.thumbnail(data: data)
        else { return nil }
        return (image, data)
    }

    /// Path-shaped refs resolve over the media route; markers like `[screenshot]` have no path to resolve.
    private static func isResolvablePath(_ ref: String) -> Bool {
        ref.hasPrefix("/") || ref.hasPrefix("~") || ref.hasPrefix("@image:")
    }

    private static func displayName(_ ref: String) -> String {
        if ref == "[screenshot]" { return "Screenshot" }
        return (ref as NSString).lastPathComponent
    }
}

/// Whether a gateway-local image chip should try to resolve.
enum ImageChipLoadGate {
    /// Retry is allowed whenever there is still no thumbnail; the view bounds how often `.task` re-runs, so this cannot become a hot loop.
    static func shouldLoad(hasThumbnail: Bool, failed: Bool) -> Bool {
        !hasThumbnail
    }
}

enum ImageChipRetry {
    /// The tap-to-retry mutation; production goes through this so a dropped `retryToken += 1` is visible to the suite.
    static func advance(token: Int) -> (failed: Bool, token: Int) {
        (false, token + 1)
    }
}

/// One gateway-local image, resolved lazily. The placeholder holds a fixed aspect box so the transcript does not jump when the bytes land, and a failed resolve falls back to the filename chip rather than a broken-image glyph.
@MainActor
private struct RemoteMediaImage: View {
    @Environment(\.hermes) private var t
    @Environment(AppModel.self) private var app

    let path: String
    let onTap: (Data, String) -> Void

    @State private var thumbnail: UIImage?
    @State private var encoded: Data?
    @State private var failed = false
    @State private var retryToken = 0

    var body: some View {
        Group {
            if let thumbnail, let encoded {
                Button {
                    onTap(encoded, path)
                } label: {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 220, maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.enclosure, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Attached image. Double tap to view full screen.")
            } else if failed {
                Button {
                    let next = ImageChipRetry.advance(token: retryToken)
                    failed = next.failed
                    retryToken = next.token
                } label: {
                    Text((path as NSString).lastPathComponent)
                        .font(HermesFont.footnote)
                        .foregroundStyle(t.text2)
                        .padding(.horizontal, Space.s5)
                        .frame(height: 30)
                        .background(t.surface2, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Couldn't load image. Double tap to retry.")
            } else {
                RoundedRectangle(cornerRadius: Radius.enclosure, style: .continuous)
                    .fill(t.surface2)
                    .frame(width: 220, height: 140)
                    .accessibilityLabel("Loading image")
            }
        }
        .task(id: "\(path)#\(retryToken)") {
            guard ImageChipLoadGate.shouldLoad(hasThumbnail: thumbnail != nil, failed: failed) else { return }
            await load()
        }
    }

    private func load() async {
        guard let rest = app.rest else {
            failed = true
            return
        }
        let cleanPath = path.hasPrefix("@image:") ? String(path.dropFirst("@image:".count)) : path
        do {
            let dataURL = try await rest.mediaDataURL(path: cleanPath)
            guard let data = DownsampledImage.data(fromDataURL: dataURL),
                  let loaded = DownsampledImage.thumbnail(data: data)
            else {
                failed = true
                return
            }
            encoded = data
            thumbnail = loaded
        } catch {
            failed = true
        }
    }
}

/// Full-screen media viewer: pinch to zoom, double-tap to fit, drag to pan, swipe down to dismiss, plus Share, Copy and Save to Photos.
/// It takes encoded bytes and decodes the full bitmap only while presented, clearing it on dismiss so the transcript never holds it.
@MainActor
struct MediaViewer: View {
    @Environment(\.hermes) private var t
    @Environment(\.dismiss) private var dismiss

    let data: Data

    @State private var image: UIImage?
    @State private var scale: CGFloat = 1
    @State private var steadyScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var steadyOffset: CGSize = .zero
    @State private var saveState: PhotoSave.State = .idle

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(zoomAndPan)
                    .onTapGesture(count: 2) {
                        withAnimation(Motion.quick) {
                            scale = 1; steadyScale = 1
                            offset = .zero; steadyOffset = .zero
                        }
                    }
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .overlay(alignment: .top) {
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .buttonStyle(IconButtonStyle())
                .accessibilityLabel("Close")

                Spacer()

                if let image {
                    Button {
                        UIPasteboard.general.image = image
                        HapticFeedback.selection()
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 15))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(IconButtonStyle())
                    .accessibilityLabel("Copy image")

                    // The glyph flips to a tick the moment the write lands and rolls back visibly to an exclamation if the grant is refused, never a silent no-op.
                    Button {
                        Task { saveState = await PhotoSave.save(image) }
                    } label: {
                        Image(systemName: saveState.glyph)
                            .font(.system(size: 15))
                            .foregroundStyle(saveState == .failed ? t.danger : .white)
                            .frame(width: Hit.min, height: Hit.min)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(saveState == .saving)
                    .accessibilityLabel(saveState.accessibilityLabel)

                    ShareLink(item: Image(uiImage: image), preview: SharePreview("Image", image: Image(uiImage: image))) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 15))
                            .foregroundStyle(.white)
                            .frame(width: Hit.min, height: Hit.min)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Share image")
                }
            }
            .padding(.horizontal, Space.s4)
        }
        .overlay(alignment: .bottom) {
            if let note = saveState.note {
                Text(note)
                    .font(HermesFont.footnote)
                    .foregroundStyle(saveState == .failed ? t.danger : .white)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Space.s8)
                    .padding(.bottom, Space.s8)
                    .transition(.opacity)
            }
        }
        .animation(Motion.quick, value: saveState)
        .task {
            if image == nil {
                image = DownsampledImage.full(data: data)
            }
        }
        .onDisappear {
            image = nil
        }
    }

    private var zoomAndPan: some Gesture {
        SimultaneousGesture(
            MagnificationGesture()
                .onChanged { value in
                    scale = max(steadyScale * value, 0.6)
                }
                .onEnded { _ in
                    steadyScale = max(scale, 1)
                    withAnimation(Motion.quick) { scale = steadyScale }
                },
            DragGesture()
                .onChanged { value in
                    offset = CGSize(
                        width: steadyOffset.width + value.translation.width,
                        height: steadyOffset.height + value.translation.height
                    )
                }
                .onEnded { value in
                    if scale <= 1, value.translation.height > 90 {
                        dismiss()
                        return
                    }
                    steadyOffset = offset
                }
        )
    }
}
