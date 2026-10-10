import HermesServeKit
import os
import SwiftUI
import UIKit

/// The affordances under a completed assistant message.
struct MessageActions {
    var canBranch = false
    var onBranch: (() -> Void)?
    var onRetry: (() -> Void)?
    /// Desktop parity: load the user turn above into the composer to replace it.
    var onEdit: (() -> Void)?
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
            if let onEdit = actions.onEdit {
                iconButton("pencil", label: "Edit and resend the message above", action: onEdit)
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
        case "cancelled": return "Cancelled before starting"
        case "unconfirmed": return "Delivery unconfirmed"
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
    /// The preview's box: two lines of `HermesFont.subhead` with half a line to spare, so two whole lines always fit and a third never does. Scaled because the text inside it is.
    @ScaledMetric(relativeTo: .subheadline) private var previewHeight: CGFloat = ReasoningPreview.baseBoxHeight

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

    /// The newest words of the trace in at most two whole lines: the longest candidate that fits, each starting on a word and opening with an ellipsis when it was shortened.
    /// Nothing is clipped and nothing is masked. The clipped window this replaces cut its first visible line through the glyphs and faded it with a gradient. `lineLimit` alone is no substitute, because it tail-truncates and would eat the newest text.
    private var preview: some View {
        let candidates = ReasoningPreview.candidates(for: text)
        return ViewThatFits(in: .vertical) {
            ForEach(Array(candidates.enumerated()), id: \.offset) { index, candidate in
                if index == candidates.count - 1 {
                    // The last resort, for type sizes where even the shortest candidate wraps to three lines: it truncates at its old end.
                    previewText(candidate)
                        .lineLimit(2)
                        .truncationMode(.head)
                } else {
                    previewText(candidate)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: previewHeight, maxHeight: previewHeight, alignment: .topLeading)
        .padding(.leading, Space.s5)
    }

    private func previewText(_ candidate: String) -> some View {
        Text(candidate)
            .font(HermesFont.subhead)
            .foregroundStyle(t.text3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A nil duration is a first-class answer rather than a zero: a transcript loaded from history never watched the think happen, and a trace that arrived whole has no interval to report.
    private var headerTitle: String {
        if isStreaming { return "Thinking" }
        guard let duration else { return "Thought" }
        return "Thought for \(RelativeTime.duration(duration))"
    }
}

/// What the collapsed reasoning preview may show of a trace, longest first.
enum ReasoningPreview {
    /// Character budgets for the candidates. The longest fills two lines on a wide screen at a small size; the shortest fits two lines of the narrowest phone at the largest default size.
    static let budgets = [240, 180, 140, 110, 84, 64]

    /// Two lines of `HermesFont.subhead` plus half a line, before Dynamic Type scales it.
    static let baseBoxHeight: CGFloat = (UIFont.systemFont(ofSize: HermesFont.subhead.size).lineHeight * 2.5).rounded(.up)

    /// The trace's newest words with every run of spaces and line breaks closed to one space, then the newest of them under each budget. A candidate that is not the whole trace starts on a word and opens with an ellipsis, so the reader can see it was shortened. Strictly shorter as they go.
    /// Only the trace's tail is read, so a long trace streaming in costs the same on every body pass as a short one.
    static func candidates(for text: String) -> [String] {
        let window = text.suffix((budgets.first ?? 240) + 64)
        let isWhole = window.startIndex == text.startIndex
        var words = window.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
        // A word the window cut through is not shown.
        if !isWhole, words.count > 1, window.first?.isWhitespace == false,
           !text[text.index(before: window.startIndex)].isWhitespace {
            words.removeFirst()
        }
        guard !words.isEmpty else { return [""] }
        let whole = words.joined(separator: " ")
        var candidates: [String] = []
        for budget in budgets {
            let candidate = isWhole && whole.count <= budget ? whole : shortened(words, budget: budget)
            if candidate.count < (candidates.last?.count ?? .max) { candidates.append(candidate) }
        }
        return candidates
    }

    /// The newest words that fit `budget` characters with the ellipsis; a single word longer than that (a hash, a path) keeps its newest characters.
    private static func shortened(_ words: [String], budget: Int) -> String {
        var kept: [String] = []
        var length = 1
        for word in words.reversed() {
            let added = word.count + (kept.isEmpty ? 0 : 1)
            guard length + added <= budget else { break }
            kept.insert(word, at: 0)
            length += added
        }
        if kept.isEmpty, let last = words.last {
            return "…" + String(last.suffix(budget - 1))
        }
        return "…" + kept.joined(separator: " ")
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
            // Desktop parity: when a usage limit lifts, from `error_surface.resets_at`.
            if let reset = surface?.resetNote() {
                Text(reset)
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
struct AttachmentChips: View {
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
            ForEach(Array(Self.displayRefs(refs).enumerated()), id: \.offset) { index, ref in
                if InlineThumbnail.isInline(ref) {
                    // BUG-075 B: decoded once, off the body, and kept for the life of the chip; deciding that a ref is inline is a prefix check, never a decode.
                    InlineImageChip(ref: ref) { data in
                        viewing = ViewerItem(id: "inline-\(index)", data: data)
                    }
                } else if Self.isResolvablePath(ref) || MediaByteCache.shared.holds(ref) {
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

    private func nameChip(_ ref: String) -> some View {
        Text(Self.displayName(ref))
            .font(HermesFont.footnote)
            .foregroundStyle(t.text2)
            .padding(.horizontal, Space.s5)
            .frame(height: 30)
            .background(t.surface2, in: Capsule())
    }

    /// The session store flattens a native-vision turn by standing a `[screenshot]` line in for each image part, beside the `@image:` line that names the same file. The placeholder is dropped whenever a real ref is present, as Desktop's `extractImageRefs` drops it; alone, it stays, because it is then the only sign an image was sent.
    static func displayRefs(_ refs: [String]) -> [String] {
        guard refs.contains(where: { $0 != InlineThumbnail.screenshotPlaceholder }) else { return refs }
        return refs.filter { $0 != InlineThumbnail.screenshotPlaceholder }
    }

    /// Path-shaped refs resolve over the media route, and the backend's paths are the host's: POSIX, `~`, a Windows drive, a UNC share. Markers like `[screenshot]` have no path to resolve.
    static func isResolvablePath(_ ref: String) -> Bool {
        ref.hasPrefix("@image:") || MediaDirective.isResolvableFilePath(ref)
    }

    /// The filename alone, read with the host's separators: `NSString.lastPathComponent` knows one separator and returned the whole of a Windows path.
    static func displayName(_ ref: String) -> String {
        if ref == InlineThumbnail.screenshotPlaceholder { return "Screenshot" }
        return MediaDirective.name(of: path(of: ref))
    }

    /// The host path a ref names, without the `@image:` prefix or the quotes the backend puts around a path with a space in it.
    static func path(of ref: String) -> String {
        UserInputDisplay.unquote(ref.hasPrefix("@image:") ? String(ref.dropFirst("@image:".count)) : ref)
    }
}

/// An in-chat `data:image/…` ref decoded into a chip-sized thumbnail, with the encoded bytes kept so the viewer can full-decode on open.
enum InlineThumbnail {
    /// A decoded chip. `UIImage` is immutable once made, so handing it from the decoding task to the view is safe.
    struct Decoded: @unchecked Sendable {
        let image: UIImage
        let data: Data
    }

    /// How many decodes have run, process-wide; a test reads it to tell a decode inside a body pass from one off it.
    static var decodeCount: Int { counter.withLock { $0 } }
    private static let counter = OSAllocatedUnfairLock(initialState: 0)

    /// Whether a ref is an inline image, by its prefix alone, so the body can decide without decoding.
    static func isInline(_ ref: String) -> Bool {
        ref.hasPrefix("data:image/")
    }

    /// The store's stand-in for an image part it flattened out of a user row.
    static let screenshotPlaceholder = "[screenshot]"

    static func decode(_ ref: String) -> Decoded? {
        counter.withLock { $0 += 1 }
        guard let data = DownsampledImage.data(fromDataURL: ref),
              let image = DownsampledImage.thumbnail(data: data)
        else { return nil }
        return Decoded(image: image, data: data)
    }
}

/// One inline image on a user turn, decoded on a background task the first time the chip appears and held in its state after that, so a row re-rendering while a reply streams costs nothing. The placeholder is the box `RemoteMediaImage` draws while it resolves.
@MainActor
private struct InlineImageChip: View {
    @Environment(\.hermes) private var t
    let ref: String
    let onTap: (Data) -> Void

    @State private var decoded: InlineThumbnail.Decoded?
    @State private var failed = false

    var body: some View {
        Group {
            if let decoded {
                Button {
                    onTap(decoded.data)
                } label: {
                    Image(uiImage: decoded.image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 220, maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.enclosure, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Attached image. Double tap to view full screen.")
            } else if failed {
                Text("Image")
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.text2)
                    .padding(.horizontal, Space.s5)
                    .frame(height: 30)
                    .background(t.surface2, in: Capsule())
                    .accessibilityLabel("Attached image that could not be shown")
            } else {
                RoundedRectangle(cornerRadius: Radius.enclosure, style: .continuous)
                    .fill(t.surface2)
                    .frame(width: 220, height: 140)
                    .accessibilityLabel("Loading image")
            }
        }
        // Keyed on the ref, whose storage is shared with the entry, so the comparison on each body pass is a pointer check and not a walk over the encoded bytes.
        .task(id: ref) {
            guard decoded == nil else { return }
            let ref = ref
            let result = await Task.detached(priority: .userInitiated) { InlineThumbnail.decode(ref) }.value
            guard !Task.isCancelled else { return }
            if let result { decoded = result } else { failed = true }
        }
    }
}

/// Whether a gateway-local image chip should try to resolve.
enum ImageChipLoadGate {
    /// Retry is allowed whenever there is still no thumbnail, failed or not (BUG-027); the view bounds how often `.task` re-runs, so this cannot become a hot loop.
    static func shouldLoad(hasThumbnail: Bool) -> Bool {
        !hasThumbnail
    }

    /// BUG-027's statement form: a failure is deliberately not an input, and `ImageChipLoadGateTests` pins that it changes nothing. Production calls the one-argument form.
    static func shouldLoad(hasThumbnail: Bool, failed: Bool) -> Bool {
        shouldLoad(hasThumbnail: hasThumbnail)
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
    @Environment(\.mediaProfile) private var mediaProfile

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
                    Text(AttachmentChips.displayName(path))
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
            guard ImageChipLoadGate.shouldLoad(hasThumbnail: thumbnail != nil) else { return }
            await load()
        }
    }

    /// Bytes the phone still holds (a photo it just sent, a thumbnail it already fetched) are used first; otherwise the media route. The downsample runs off the main actor either way (BUG-075).
    private func load() async {
        let path = path
        let cleanPath = AttachmentChips.path(of: path)
        let rest = app.rest
        let profile = mediaProfile
        let result = await Task.detached(priority: .userInitiated) { () async -> InlineThumbnail.Decoded? in
            let bytes: Data?
            if let held = MediaByteCache.shared.data(for: path) ?? MediaByteCache.shared.data(for: cleanPath) {
                bytes = held
            } else if let rest, let dataURL = await Self.dataURL(rest: rest, path: cleanPath, profile: profile) {
                bytes = DownsampledImage.data(fromDataURL: dataURL)
            } else {
                bytes = nil
            }
            guard let bytes, let loaded = DownsampledImage.thumbnail(data: bytes) else { return nil }
            MediaByteCache.shared.remember(bytes, keys: [path, cleanPath])
            return InlineThumbnail.Decoded(image: loaded, data: bytes)
        }.value
        guard !Task.isCancelled else { return }
        guard let result else {
            failed = true
            return
        }
        encoded = result.data
        thumbnail = result.image
    }

    /// The media route first; a chat under a named Hermes profile uploads into that profile's own `images`, which `/api/media` refuses, so its file is read through the profile-scoped file route instead.
    nonisolated static func dataURL(rest: RestAPI, path: String, profile: String?) async -> String? {
        if let dataURL = try? await rest.mediaDataURL(path: path) { return dataURL }
        guard let profile, !profile.isEmpty else { return nil }
        return try? await rest.readDataURL(path: path, profile: profile)
    }
}

private struct MediaProfileKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// The Hermes profile the open chat lives under, nil for the backend's own; set by `ChatView` for the images in its transcript.
    var mediaProfile: String? {
        get { self[MediaProfileKey.self] }
        set { self[MediaProfileKey.self] = newValue }
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
        // Each control is a dark glass disc, so its white glyph holds over a light photo as well as over the black ground; the row is the same one the video player wears.
        .overlay(alignment: .top) {
            if let image {
                MediaViewerControls(
                    noun: "image",
                    onCopy: { UIPasteboard.general.image = image },
                    onSave: { await PhotoSave.save(image) },
                    share: {
                        ShareLink(item: Image(uiImage: image), preview: SharePreview("Image", image: Image(uiImage: image))) {
                            MediaViewerControls<EmptyView>.control("square.and.arrow.up")
                        }
                    },
                    saveState: $saveState
                )
            } else {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        MediaViewerControls<EmptyView>.control("xmark", weight: .semibold)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                    Spacer()
                }
                .padding(.horizontal, Space.s4)
                .environment(\.colorScheme, .dark)
            }
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
