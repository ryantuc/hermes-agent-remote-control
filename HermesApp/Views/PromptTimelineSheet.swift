import HermesServeKit
import SwiftUI

/// A prompt the person chose to jump to: the loaded entry when the list came from what is on screen, the durable row when it came from the backend.
struct TranscriptJump: Equatable {
    var entryID: String?
    var rowID: Int?
    /// Two taps on the same prompt are two jumps.
    private let token = UUID()

    init(entryID: String? = nil, rowID: Int? = nil) {
        self.entryID = entryID
        self.rowID = rowID
    }
}

/// The conversation's prompts, oldest first, each a jump to where it sits in the transcript. From the backend's timeline where there is one (every prompt in the session, loaded or not), otherwise from the loaded history.
@MainActor
struct PromptTimelineSheet: View {
    @Environment(\.hermes) private var t
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    let model: ChatModel
    let onJump: (TranscriptJump) -> Void

    @State private var remote: [PromptTimelineEntry] = []
    @State private var nextCursor: Int?
    @State private var total: Int?
    /// The list came from the backend, so it may name prompts that are not loaded.
    @State private var fromBackend = false
    @State private var isLoading = true
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let failure {
                        Text(failure)
                            .font(HermesFont.footnote)
                            .foregroundStyle(t.text3)
                            .padding(.horizontal, Space.s6)
                            .padding(.vertical, Space.s5)
                    }
                    if fromBackend {
                        ForEach(remote) { entry in
                            row(preview: entry.preview, date: entry.date, isLoaded: model.loadedPrompt(rowID: entry.rowID) != nil) {
                                onJump(TranscriptJump(entryID: model.loadedPrompt(rowID: entry.rowID)?.id, rowID: entry.rowID))
                            }
                        }
                        if nextCursor != nil {
                            Button {
                                Task { await loadMore() }
                            } label: {
                                Text(isLoading ? "Loading…" : "Show more prompts")
                                    .font(HermesFont.subhead)
                                    .foregroundStyle(t.action)
                                    .frame(maxWidth: .infinity, minHeight: Hit.min)
                            }
                            .buttonStyle(.plain)
                            .disabled(isLoading)
                        }
                    } else {
                        ForEach(model.loadedPrompts) { entry in
                            row(preview: entry.text, date: entry.timestamp, isLoaded: true) {
                                onJump(TranscriptJump(entryID: entry.id, rowID: entry.rowID))
                            }
                        }
                    }
                    if !isLoading, failure == nil, isEmpty {
                        Text("No prompts yet.")
                            .font(HermesFont.footnote)
                            .foregroundStyle(t.text3)
                            .padding(.horizontal, Space.s6)
                            .padding(.vertical, Space.s5)
                    }
                }
                .padding(.vertical, Space.s4)
            }
            .background(t.canvas)
            .task { await load() }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(t.action)
                }
            }
            .hermesTopBar()
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(Radius.sheet)
        .presentationBackground(t.canvas)
    }

    private var isEmpty: Bool {
        fromBackend ? remote.isEmpty : model.loadedPrompts.isEmpty
    }

    private var title: String {
        if let total, fromBackend { return total == 1 ? "1 prompt" : "\(total) prompts" }
        let count = model.loadedPrompts.count
        return count == 1 ? "1 prompt" : "\(count) prompts"
    }

    /// One prompt: its first line, when it was sent, and whether it is already on the phone (a prompt that is not loaded is fetched with the page around it).
    private func row(preview: String, date: Date, isLoaded: Bool, action: @escaping () -> Void) -> some View {
        let line = Self.firstLine(of: preview)
        return Button {
            dismiss()
            action()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Space.s4) {
                VStack(alignment: .leading, spacing: Space.s1) {
                    Text(line)
                        .font(HermesFont.callout)
                        .foregroundStyle(t.text1)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .font(HermesFont.footnote)
                        .hermesNumeric()
                        .foregroundStyle(t.text3)
                }
                Spacer(minLength: 0)
                if !isLoaded {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(t.text4)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, Space.s6)
            .padding(.vertical, Space.s4)
            .frame(maxWidth: .infinity, minHeight: Hit.min, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(line)
        .accessibilityValue(date.formatted(date: .abbreviated, time: .shortened))
        .accessibilityHint(isLoaded ? "Jumps to this prompt" : "Loads the conversation around this prompt")
    }

    /// The prompt's first non-empty line, at most 120 characters, as the backend's own preview cuts it.
    static func firstLine(of text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count <= 120 ? trimmed : String(trimmed.prefix(119)).trimmingCharacters(in: .whitespaces) + "…"
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            guard let page = try await model.loadPromptTimeline() else {
                // No backend list: the loaded prompts are the list, and a backend that has no route says so once.
                fromBackend = false
                if model.timelineUnavailable { failure = "This backend does not list prompts; only the loaded ones are shown." }
                return
            }
            fromBackend = true
            remote = page.entries
            total = page.total
            nextCursor = page.nextCursor
        } catch {
            fromBackend = false
            failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func loadMore() async {
        guard let cursor = nextCursor else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            guard let page = try await model.loadPromptTimeline(afterRowID: cursor) else { return }
            remote += page.entries
            total = page.total
            nextCursor = page.nextCursor
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
