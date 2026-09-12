import HermesServeKit
import SwiftUI

/// The Bots roster — a Messages-style list of 1:1 threads, one per Hermes profile.
///
/// Mounted twice, like `HistoryGroupList`, so it carries **no** `ScrollView` of its own: the hub's history region is already a scroller with a pinned footer beneath it (BUG-043).
///
/// It owns no navigation — the two containers navigate differently, so the tap is a closure — but it does own `markOpened`, which is true wherever the row was tapped.
@MainActor
struct BotRosterList: View {
    @Environment(\.hermes) private var t
    @Environment(AppModel.self) private var app

    /// Performed after `markOpened`, with the bot that was tapped.
    let onOpen: (BotsModel.Bot) -> Void

    /// Avatar bytes this list has fetched, per profile. Held here rather than in the row so a row that scrolls out and back does not refetch, and so `BotRosterRow` stays a pure function of its arguments and is measurable without a model.
    @State private var avatars: [String: Data] = [:]

    private var bots: BotsModel { app.bots }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            if bots.botModeProtocol == false { protocolCaption }
            if let error = visibleError { errorRow(error) }

            if roster.isEmpty {
                if bots.isLoading && !bots.hasLoadedOnce {
                    loadingRow
                } else if bots.hasLoadedOnce && visibleError == nil && app.connectionState.isOpen {
                    emptyRow
                }
            } else {
                ForEach(roster) { bot in
                    row(bot)
                }
            }

            if bots.hasDesktopGroups { groupsFootnote }
        }
    }

    /// A roster error, but only while there is a connection for it to be an error *about*: a closed socket is the connection banner's to report, not this list's.
    private var visibleError: String? {
        app.connectionState.isOpen ? bots.error : nil
    }

    /// The rows to draw. In DEBUG the screenshot harness can stand a demo roster in front of the model, so an offline capture shows the surface rather than its empty state; in release this is the model, full stop.
    private var roster: [BotsModel.Bot] {
        #if DEBUG
        if let demo = BotsDemoRoster.bots { return demo }
        #endif
        return bots.bots
    }

    // MARK: Rows

    private func row(_ bot: BotsModel.Bot) -> some View {
        Button {
            app.bots.markOpened(bot.profile)
            onOpen(bot)
        } label: {
            BotRosterRow(
                displayName: bot.displayName,
                preview: bot.preview,
                lastActive: bot.lastActive,
                isWorking: bot.isWorking,
                isUnread: bot.isUnread,
                avatarData: avatars[bot.profile]
            )
        }
        .buttonStyle(.plain)
        // Lazily, and once: `has_avatar` is a roster field and the asset is a
        // separate round trip. A profile with no avatar never asks.
        .task(id: bot.profile) {
            guard bot.hasAvatar, avatars[bot.profile] == nil else { return }
            if let data = await app.bots.avatarData(for: bot.profile) {
                avatars[bot.profile] = data
            }
        }
        .accessibilityLabel(bot.displayName)
        .accessibilityHint("Opens your conversation with \(bot.displayName)")
    }

    // MARK: States

    /// The flag governs prompt injection on the backend, not the roster, so this is a caption and not an empty state — the list below it works.
    private var protocolCaption: some View {
        Text("This backend does not run the Bot Mode protocol.")
            .font(HermesFont.footnote)
            .foregroundStyle(t.text3)
            .padding(.horizontal, Space.s6)
            .padding(.vertical, Space.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var loadingRow: some View {
        HStack {
            Spacer(minLength: 0)
            ProgressView()
            Spacer(minLength: 0)
        }
        .padding(.vertical, Space.s9)
    }

    private var emptyRow: some View {
        Text("This backend has no profiles yet")
            .font(HermesFont.subhead)
            .foregroundStyle(t.text3)
            .padding(.horizontal, Space.s6)
            .padding(.vertical, Space.s8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The shape `ChatView`'s session error row draws — a danger dot and one line — plus the retry the roster can offer and a thread cannot.
    private func errorRow(_ message: String) -> some View {
        HStack(alignment: .top, spacing: Space.s4) {
            Circle().fill(t.danger).frame(width: 8, height: 8).padding(.top, 5)
            Text(message)
                .font(HermesFont.subhead)
                .foregroundStyle(t.text2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Retry") {
                Task { await app.bots.refresh() }
            }
            .font(HermesFont.calloutStrong)
            .foregroundStyle(t.action)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Space.s6)
        .padding(.vertical, Space.s5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hairline()
    }

    /// Rendered only when the default profile's `ui_meta` actually carries rooms. There is no group primitive on this backend to call, so with no groups there is nothing to say.
    private var groupsFootnote: some View {
        Text("Group chats are managed from Hermes Desktop.")
            .font(HermesFont.footnote)
            .foregroundStyle(t.text4)
            .padding(.horizontal, Space.s6)
            .padding(.vertical, Space.s5)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One roster row: identity chip, name over one line of preview, and a trailing recency + state column.
///
/// **Its own view, taking plain values, because its height is the thing under test** (FEAT-008): 56 pt is a *floor*, not a cap, since `.frame(height:)` does not clip and a pinned row draws its labels through the row below at accessibility content sizes.
@MainActor
struct BotRosterRow: View {
    @Environment(\.hermes) private var t

    /// What the row measures at the default content size, and the floor it never drops below.
    static let restingHeight: CGFloat = 56

    let displayName: String
    let preview: String
    /// Epoch seconds; 0 renders as no timestamp rather than as 1970.
    let lastActive: Double
    let isWorking: Bool
    let isUnread: Bool
    var avatarData: Data?

    /// A profile the user has never spoken to has no preview and no purpose declared. Saying so is better than a blank line, which reads as a row that failed to load.
    private var previewLine: String {
        preview.isEmpty ? "No conversation yet" : preview
    }

    var body: some View {
        HStack(spacing: Space.s4) {
            IdentityChip(displayName: displayName, imageData: avatarData, size: IdentityChip.rosterSize)

            VStack(alignment: .leading, spacing: Space.s1) {
                Text(displayName)
                    .font(HermesFont.callout)
                    .foregroundStyle(t.text1)
                    .lineLimit(1)
                Text(previewLine)
                    .font(HermesFont.subhead)
                    .foregroundStyle(t.text3)
                    .lineLimit(1)
            }

            Spacer(minLength: Space.s4)

            VStack(alignment: .trailing, spacing: Space.s2) {
                Text(RelativeTime.short(epochSeconds: lastActive))
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.text4)
                    .lineLimit(1)
                HStack(spacing: Space.s2) {
                    if isWorking { PulsingDot(color: t.warn, size: 6) }
                    if isUnread {
                        Circle()
                            .fill(t.accent)
                            .frame(width: 8, height: 8)
                            .accessibilityLabel("Unread")
                    }
                }
            }
        }
        .padding(.horizontal, Space.s6)
        .frame(minHeight: Self.restingHeight)
        .contentShape(Rectangle())
        .hairline()
    }
}

#if DEBUG
/// The screenshot harness's roster (`-hermesScreenshotRoute bots` / `bots-hub`).
///
/// A view-layer seam, deliberately: `BotsModel.bots` is `private(set)`, so this stands four demo bots in front of the model for the duration of a capture and costs a release build nothing.
@MainActor
enum BotsDemoRoster {
    static var bots: [BotsModel.Bot]?

    static func seed(now: Double = Date().timeIntervalSince1970) {
        bots = [
            BotsModel.Bot(
                profile: "default",
                displayName: "Hermes",
                description: "Your own Hermes.",
                isDefault: true,
                hasAvatar: false,
                preview: "The rebase is clean — 4 files, no conflicts.",
                lastActive: now - 40,
                isWorking: true,
                isUnread: false
            ),
            BotsModel.Bot(
                profile: "ops-bot",
                displayName: "Ops Bot",
                description: "Watches the boxes.",
                isDefault: false,
                hasAvatar: false,
                preview: "The build finished. All checks passed.",
                lastActive: now - 900,
                isWorking: false,
                isUnread: true
            ),
            BotsModel.Bot(
                profile: "code-review",
                displayName: "Code Review",
                description: "Reads diffs before you do.",
                isDefault: false,
                hasAvatar: false,
                preview: "Two things in the approval path I would change.",
                lastActive: now - 7_200,
                isWorking: false,
                isUnread: false
            ),
            BotsModel.Bot(
                profile: "research",
                displayName: "Research",
                description: "Long reads, summarised.",
                isDefault: false,
                hasAvatar: false,
                preview: "",
                lastActive: 0,
                isWorking: false,
                isUnread: false
            ),
        ]
    }
}
#endif
