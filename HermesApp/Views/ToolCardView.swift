import HermesServeKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A tool invocation card — **an enclosure**, because a tool call is the app
/// acting on the user's machine.
///
/// `tool.start` carries only `tool_id`, `name` and an ≤80-char `context`
/// preview; full arguments and output exist only in the backend's `verbose`
/// tool-progress mode.
@MainActor
struct ToolCardView: View {
    @Environment(\.hermes) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let activity: ToolActivity
    /// Collapsed by default (a transcript of expanded tool cards is a log
    /// file) — unless Settings → Chat → Transcript flips the default.
    #if DEBUG
    @State private var isExpanded = ProcessInfo.processInfo.arguments.contains("-hermesScreenshotExpandTools")
        || TranscriptPreferences.toolCardsExpandByDefault
    #else
    @State private var isExpanded = TranscriptPreferences.toolCardsExpandByDefault
    #endif
    @State private var exportDocument: CodeExportDocument?
    @State private var openFull = false

    var body: some View {
        // BUG-006: branches on the TYPED value, not the tool's name, so a
        // payload the parser did not understand falls back to the ordinary card.
        if let todos = activity.todos {
            TodoToolRow(activity: activity, todos: todos)
        } else {
            standardCard
        }
    }

    private var standardCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                header
                if isExpanded {
                    detail
                }
            }
            .enclosure(activity.isError ? .danger : .neutral)
            .overlay(alignment: .top) {
                if activity.isRunning, !reduceMotion {
                    RunningSweep()
                        .clipShape(RoundedRectangle(cornerRadius: Radius.enclosure, style: .continuous))
                }
            }

            // Actions live outside the panel — the desktop's rule for inline
            // widgets, kept here.
            if isExpanded {
                actionRow
            }
        }
        .fileExporter(
            isPresented: Binding(
                get: { exportDocument != nil },
                set: { if !$0 { exportDocument = nil } }
            ),
            document: exportDocument,
            contentType: .plainText,
            defaultFilename: "\(activity.name.isEmpty ? "tool" : activity.name)-output"
        ) { _ in }
        // Cover lives on the root so the collapsed header's context menu can
        // present "Open full" without needing the expanded action row.
        .fullScreenCover(isPresented: $openFull) {
            FullScreenCodeReader(text: DisplayRedaction.toolOutput(activity.resultText))
        }
    }

    // MARK: Tool families

    enum Family {
        case terminal, file, edit, search, browser, todo, other

        var glyph: String {
            switch self {
            case .terminal: return "$"
            case .file: return "▤"
            case .edit: return "✎"
            case .search: return "⌕"
            case .browser: return "◉"
            // The backend's own registry emoji for the todo tool.
            case .todo: return "📋"
            case .other: return "⚒"
            }
        }

        /// The SF Symbol a card draws for the family. Typed characters came out at mixed optical sizes and weights, and the todo tool's emoji drew as a missing-glyph box in the monospaced header font.
        var symbol: String {
            switch self {
            case .terminal: return "terminal"
            case .file: return "doc.text"
            case .edit: return "pencil"
            case .search: return "magnifyingglass"
            case .browser: return "globe"
            case .todo: return "checklist"
            case .other: return "hammer"
            }
        }

        init(toolName: String) {
            let name = toolName.lowercased()
            // BUG-145: whole-name match, tested before every substring bucket
            // below, so `todoist_add_task` cannot inherit the checklist renderer.
            if TodoList.isPlanTool(name) {
                self = .todo
            } else if ["terminal", "bash", "shell", "run", "exec", "command"].contains(where: name.contains) {
                self = .terminal
            } else if ["edit", "patch", "replace", "apply_diff"].contains(where: name.contains) {
                self = .edit
            } else if ["read", "write", "file", "cat", "ls", "glob"].contains(where: name.contains) {
                self = .file
            } else if ["search", "grep", "find", "query"].contains(where: name.contains) {
                self = .search
            } else if ["browser", "browse", "navigate", "screenshot"].contains(where: name.contains)
                        || Self.words(in: toolName).contains("web") {
                // BUG-146: `web` is a word, not a substring, so `webhook_send` is not a browser tool.
                self = .browser
            } else {
                self = .other
            }
        }

        /// A tool name's words, lowercased: split on anything that is not a letter or digit and where a lowercase letter or digit meets an uppercase one, so `web_extract`, `web-fetch` and `fetchWebPage` each contain `web`.
        static func words(in toolName: String) -> [String] {
            var words: [String] = []
            var current = ""
            var previous: Character?
            for character in toolName {
                if !(character.isLetter || character.isNumber) {
                    if !current.isEmpty { words.append(current.lowercased()) }
                    current = ""
                } else {
                    if character.isUppercase, let previous, previous.isLowercase || previous.isNumber, !current.isEmpty {
                        words.append(current.lowercased())
                        current = ""
                    }
                    current.append(character)
                }
                previous = character
            }
            if !current.isEmpty { words.append(current.lowercased()) }
            return words
        }
    }

    private var family: Family { Family(toolName: activity.name) }

    // MARK: Header — a 44 pt row

    private var header: some View {
        Button {
            // BUG-009: DISCRETE. Animating this height change inside the
            // transcript ScrollView races `.defaultScrollAnchor(.bottom)` and
            // never settles while a turn streams; only the chevron animates.
            isExpanded.toggle()
            HapticFeedback.selection()
        } label: {
            HStack(spacing: Space.s4) {
                ToolFamilyIcon(family: family)

                Text(activity.name.isEmpty ? "Preparing…" : activity.name)
                    .font(HermesFont.codeStrong)
                    .foregroundStyle(t.text1)
                    .layoutPriority(1)

                // The one string that says *which* call. Paths truncate from
                // the left so the leaf stays visible.
                Text(DisplayRedaction.preview(activity.context, limit: 90))
                    .font(HermesFont.code)
                    .foregroundStyle(t.text3)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !activity.inlineDiff.isEmpty, TranscriptPreferences.showDiffs {
                    diffChip
                }
                riskMarker
                trailingStatus

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(t.text4)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    // Scoped to the chevron so the detail's height change stays
                    // discrete.
                    .animation(reduceMotion ? nil : Motion.quick, value: isExpanded)
            }
            .padding(.horizontal, Space.s5)
            .frame(minHeight: Hit.min)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(activity.name) tool\(activity.isRunning ? ", running" : "")")
        .accessibilityHint(isExpanded ? "Collapse detail" : "Expand detail")
        .contextMenu {
            copyButton
            if !activity.resultText.isEmpty {
                Button {
                    openFull = true
                } label: {
                    Label("Open full", systemImage: "arrow.up.left.and.arrow.down.right")
                }
            }
        }
    }

    /// `+12 −3` for edit calls, from the diff the backend sent.
    private var diffChip: some View {
        let counts = diffCounts
        return HStack(spacing: Space.s2) {
            Text(verbatim: "+\(counts.added)")
                .foregroundStyle(t.diffAddInk)
            Text(verbatim: "−\(counts.removed)")
                .foregroundStyle(t.diffRemoveInk)
        }
        .font(HermesFont.footnote)
        .hermesNumeric()
    }

    private var diffCounts: (added: Int, removed: Int) {
        var added = 0
        var removed = 0
        for line in activity.inlineDiff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("+"), !line.hasPrefix("+++") { added += 1 }
            if line.hasPrefix("-"), !line.hasPrefix("---") { removed += 1 }
        }
        return (added, removed)
    }

    /// The card is collapsed by default, so a risk signal that only rendered in
    /// the detail would be invisible until tapped. The header carries a marker.
    @ViewBuilder
    private var riskMarker: some View {
        if activity.hasOutputRisk {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(t.warn)
                .accessibilityLabel(
                    activity.outputRisk.isEmpty
                        ? "Output risk reported"
                        : "Output risk reported: \(activity.outputRisk)"
                )
        }
    }

    /// Spinner-free: ✓ + duration, ✕ on failure, `running` (in warn) while the
    /// sweep runs — and as the only running indicator under Reduce Motion.
    @ViewBuilder
    private var trailingStatus: some View {
        if activity.isRunning {
            Text("running")
                .font(HermesFont.footnote)
                .foregroundStyle(t.warn)
        } else if activity.isError {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(t.danger)
                .accessibilityLabel("Failed")
        } else if let duration = activity.durationSeconds {
            HStack(spacing: Space.s2) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(t.ok)
                Text(RelativeTime.duration(duration))
                    .font(HermesFont.footnote)
                    .hermesNumeric()
                    .foregroundStyle(t.text3)
            }
            .accessibilityLabel("Completed in \(RelativeTime.duration(duration))")
        }
    }

    // MARK: Detail — invocation zone, result zone

    private var detail: some View {
        VStack(alignment: .leading, spacing: Space.s6) {
            // A safety signal the backend sends. Findings are relayed
            // **verbatim**; the client never rewords them. A band or a
            // redaction with no findings still shows.
            if activity.hasOutputRisk {
                riskBand
            }

            if activity.isError, !activity.errorText.isEmpty {
                // Error line first on a failed card.
                zone("Error") {
                    CodeScroller(text: activity.errorText, maxHeight: 240, ink: t.danger)
                }
            }

            if family == .terminal {
                terminalZones
            } else {
                genericZones
            }

            if !activity.inlineDiff.isEmpty, TranscriptPreferences.showDiffs {
                diffZone
            }

            if isEmptyDetail {
                Text("No detail was sent. The backend only streams full tool input and output in verbose progress mode.")
                    .font(HermesFont.subhead)
                    .foregroundStyle(t.text3)
            }
        }
        .padding(.horizontal, Space.s5)
        .padding(.bottom, Space.s5)
        .padding(.top, Space.s2)
    }

    /// Terminal calls: the command with a `$` gutter, then the output. ANSI is
    /// stripped, not rendered.
    @ViewBuilder
    private var terminalZones: some View {
        let command = activity.context.isEmpty ? activity.argsText : activity.context
        if !command.isEmpty {
            zone("Command") {
                CodeScroller(
                    text: command
                        .components(separatedBy: "\n")
                        .map { "$ \($0)" }
                        .joined(separator: "\n"),
                    maxHeight: 240
                )
            }
        }
        if !activity.resultText.isEmpty {
            zone("Output") {
                CodeScroller(text: Self.strippingANSI(DisplayRedaction.toolOutput(activity.resultText)))
            }
        }
    }

    @ViewBuilder
    private var genericZones: some View {
        if !activity.argsText.isEmpty {
            zone("Input") {
                CodeScroller(text: DisplayRedaction.toolOutput(activity.argsText), maxHeight: 240)
            }
        } else if !activity.context.isEmpty {
            zone("Input") {
                CodeScroller(text: activity.context, maxHeight: 240)
            }
        }
        if !activity.resultText.isEmpty {
            zone("Output") {
                CodeScroller(text: Self.strippingANSI(DisplayRedaction.toolOutput(activity.resultText)))
            }
        }
    }

    private func zone(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            Text(title)
                .hermesCaption()
                .foregroundStyle(t.text3)
            content()
        }
    }

    private var isEmptyDetail: Bool {
        activity.argsText.isEmpty && activity.resultText.isEmpty
            && activity.inlineDiff.isEmpty && activity.errorText.isEmpty
            && activity.context.isEmpty
    }

    static func strippingANSI(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return text }
        return text.replacingOccurrences(
            of: "\u{1B}\\[[0-9;?]*[A-Za-z]",
            with: "",
            options: .regularExpression
        )
    }

    private var riskBand: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            // The band is the backend's own word for the severity and is shown
            // as sent — this client has no vocabulary of its own to map it to.
            Text(activity.outputRisk.isEmpty ? "Output risk" : "Output risk — \(activity.outputRisk)")
                .hermesCaption()
                .foregroundStyle(t.warn)
            // Keyed by offset + value: duplicate finding strings must not
            // collide (NEW-2a).
            ForEach(Array(activity.outputRiskFindings.enumerated()), id: \.offset) { _, finding in
                Text(finding)
                    .font(HermesFont.subhead)
                    .foregroundStyle(t.text1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if activity.outputRiskRedacted {
                Text("The backend withheld part of this tool's output.")
                    .font(HermesFont.subhead)
                    .foregroundStyle(t.text2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(Space.s5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(t.warnFill, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }

    /// Per-line grounds derived from the semantic tokens, so a diff stays
    /// legible under any skin.
    private var diffZone: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            Text("Diff")
                .hermesCaption()
                .foregroundStyle(t.text3)
            ScrollView(.vertical, showsIndicators: true) {
                ScrollView(.horizontal, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(activity.inlineDiff.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                            let text = String(line)
                            Text(text.isEmpty ? " " : text)
                                .font(HermesFont.codeSmall)
                                .foregroundStyle(ink(for: text))
                                .padding(.horizontal, Space.s3)
                                .fixedSize(horizontal: true, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(ground(for: text))
                        }
                    }
                }
            }
            .frame(maxHeight: 320)
        }
    }

    private func ground(for line: String) -> Color {
        if line.hasPrefix("+") { return t.diffAddGround }
        if line.hasPrefix("-") { return t.diffRemoveGround }
        return .clear
    }

    private func ink(for line: String) -> Color {
        if line.hasPrefix("+") { return t.diffAddInk }
        if line.hasPrefix("-") { return t.diffRemoveInk }
        return t.text2
    }

    // MARK: Actions — outside the panel

    private var actionRow: some View {
        HStack(spacing: Space.s6) {
            actionButton("Copy") {
                UIPasteboard.general.string = copyPayload
                HapticFeedback.selection()
            }
            if !activity.resultText.isEmpty {
                actionButton("Open full") {
                    openFull = true
                }
                actionButton("Save to Files") {
                    exportDocument = CodeExportDocument(text: DisplayRedaction.toolOutput(activity.resultText))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.s2)
    }

    private func actionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(HermesFont.subhead)
                .foregroundStyle(t.text3)
                .frame(minHeight: Hit.min)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var copyPayload: String {
        [activity.name, activity.context, activity.argsText, activity.resultText, activity.errorText]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private var copyButton: some View {
        Button {
            UIPasteboard.general.string = copyPayload
        } label: {
            Label("Copy tool detail", systemImage: "doc.on.doc")
        }
    }
}

/// A run of consecutive same-tool calls, collapsed into one 44 pt row with a
/// count. Expanding lists the individual calls, each independently expandable.
@MainActor
struct ToolGroupCard: View {
    @Environment(\.hermes) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let entries: [ChatEntry]
    @State private var isExpanded = false
    @State private var openFull = false

    private var activities: [ToolActivity] { entries.compactMap(\.tool) }
    private var name: String { activities.first?.name ?? "tool" }
    private var anyRunning: Bool { activities.contains(where: \.isRunning) }
    private var anyFailed: Bool { activities.contains(where: \.isError) }
    private var groupHasOutput: Bool {
        activities.contains { !$0.resultText.isEmpty }
    }

    /// The danger stroke waits until the group has settled: a group whose header still reads "running" is not a failure yet, even when a finished member failed.
    static func tone(anyRunning: Bool, anyFailed: Bool) -> EnclosureModifier.Tone {
        anyFailed && !anyRunning ? .danger : .neutral
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            Button {
                // BUG-009: DISCRETE, for the same reason as ToolCardView's
                // header.
                isExpanded.toggle()
                HapticFeedback.selection()
            } label: {
                HStack(spacing: Space.s4) {
                    ToolFamilyIcon(family: ToolCardView.Family(toolName: name))
                    Text(name)
                        .font(HermesFont.codeStrong)
                        .foregroundStyle(t.text1)
                    Text(verbatim: "×\(activities.count)")
                        .font(HermesFont.footnote)
                        .hermesNumeric()
                        .foregroundStyle(t.text3)
                    Spacer(minLength: Space.s4)
                    if anyRunning {
                        Text("running")
                            .font(HermesFont.footnote)
                            .foregroundStyle(t.warn)
                    } else if anyFailed {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(t.danger)
                            .accessibilityLabel("One or more calls failed")
                    } else {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(t.ok)
                            .accessibilityLabel("All calls completed")
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(t.text4)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        // Chevron only — the rows below stay discrete.
                        .animation(reduceMotion ? nil : Motion.quick, value: isExpanded)
                }
                .padding(.horizontal, Space.s5)
                .frame(minHeight: Hit.min)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .enclosure(Self.tone(anyRunning: anyRunning, anyFailed: anyFailed))
            .accessibilityLabel("\(activities.count) \(name) calls")
            .accessibilityHint(isExpanded ? "Collapse the group" : "Expand the group")
            .contextMenu {
                Button {
                    UIPasteboard.general.string = groupCopyPayload
                } label: {
                    Label("Copy tool detail", systemImage: "doc.on.doc")
                }
                if groupHasOutput {
                    Button {
                        openFull = true
                    } label: {
                        Label("Open full", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                }
            }

            if isExpanded {
                ForEach(entries) { entry in
                    if let activity = entry.tool {
                        ToolCardView(activity: activity)
                            .padding(.leading, Space.s5)
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $openFull) {
            FullScreenCodeReader(text: groupFullOutput)
        }
    }

    private var groupCopyPayload: String {
        activities.map { activity in
            [activity.name, activity.context, activity.argsText, activity.resultText, activity.errorText]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n———\n\n")
    }

    private var groupFullOutput: String {
        let chunks = activities.compactMap { activity -> String? in
            let raw = activity.resultText
            guard !raw.isEmpty else { return nil }
            return DisplayRedaction.toolOutput(raw)
        }
        return chunks.joined(separator: "\n\n———\n\n")
    }
}

/// The 2 pt bar sweeping the enclosure's top edge while a tool runs — a sweep
/// says "working", a spinner says "waiting". Nil under Reduce Motion (the
/// caller drops it; the state chip then reads `running`).
@MainActor
private struct RunningSweep: View {
    @Environment(\.hermes) private var t
    @State private var phase = false

    var body: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(t.warn)
                .frame(width: max(geo.size.width * 0.28, 40), height: 2)
                .offset(x: phase ? geo.size.width : -max(geo.size.width * 0.28, 40))
                .animation(.linear(duration: 1.4).repeatForever(autoreverses: false), value: phase)
        }
        .frame(height: 2)
        .allowsHitTesting(false)
        .onAppear { phase = true }
        .accessibilityHidden(true)
    }
}

/// Plain-text export wrapper for "Save to Files".
struct CodeExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.plainText]

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        text = String(decoding: data, as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// The live indicator dot used across the app. `color` nil resolves to the
/// accent token; static at 60% under reduced motion.
struct PulsingDot: View {
    @Environment(\.hermes) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isUp = false

    var color: Color?
    var size: CGFloat = 7

    var body: some View {
        Circle()
            .fill(color ?? t.accent)
            .frame(width: size, height: size)
            .opacity(reduceMotion ? 0.6 : (isUp ? 1 : 0.35))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(Motion.loop) { isUp = true }
            }
            .accessibilityLabel("Running")
    }
}

/// A tool family's mark in a card header's leading slot. The symbol and its slot grow with the header's text size, so the mark never clips at larger sizes the way a fixed 16 pt box did.
struct ToolFamilyIcon: View {
    @Environment(\.hermes) private var t
    @ScaledMetric(relativeTo: .footnote) private var size: CGFloat = 12
    @ScaledMetric(relativeTo: .footnote) private var slot: CGFloat = 16

    let family: ToolCardView.Family

    var body: some View {
        Image(systemName: family.symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(t.text3)
            .frame(width: slot)
            .accessibilityHidden(true)
    }
}
