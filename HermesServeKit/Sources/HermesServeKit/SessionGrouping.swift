import Foundation

/// The desktop's session-source vocabulary, ported verbatim from
/// `apps/desktop/src/lib/session-source.ts` so the two clients cannot drift:
/// same labels, same local/messaging id sets, same fallback beautification.
public enum SessionSource {
    public static let sourceLabels: [String: String] = [
        "api_server": "API",
        "bluebubbles": "iMessage",
        "cli": "CLI",
        "codex": "Codex",
        "desktop": "Desktop",
        "discord": "Discord",
        "email": "Email",
        "gateway": "Gateway",
        // Our own source tag (SessionAPI.sourceTag) — not in the desktop's
        // map yet; without an entry the fallback beautifier renders "Ios".
        "ios": "iOS",
        "kanban": "Kanban",
        "local": "Local",
        "matrix": "Matrix",
        "mattermost": "Mattermost",
        "photon": "Photon",
        "qqbot": "QQ",
        "signal": "Signal",
        "slack": "Slack",
        "sms": "SMS",
        "telegram": "Telegram",
        "tui": "TUI",
        "webhook": "Webhook",
        "weixin": "WeChat",
        "whatsapp": "WhatsApp",
        "yuanbao": "Yuanbao",
    ]

    /// Sources that run on the local machine — the Recents membership.
    /// `ios` is this client's own tag; its chats belong with the user's
    /// other first-party sessions, not in a per-platform messaging group.
    public static let localSourceIDs: Set<String> = [
        "cli", "codex", "desktop", "gateway", "ios", "kanban", "local", "tui",
    ]

    /// External messaging platforms, each with its own collapsed group.
    public static let messagingSourceIDs: Set<String> = [
        "telegram", "discord", "slack", "mattermost", "matrix", "signal",
        "whatsapp", "bluebubbles", "photon", "homeassistant", "email", "sms",
        "webhook", "api_server", "weixin", "wecom", "qqbot", "yuanbao",
        "dingtalk", "feishu",
    ]

    /// Scheduled-job origins — the Cron group.
    public static let cronSourceIDs: Set<String> = ["cron", "schedule", "scheduler"]

    public static func normalize(_ source: String?) -> String? {
        let trimmed = (source ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The desktop's label map, with its exact fallback: underscores/hyphens
    /// become spaces, words title-case.
    public static func label(_ source: String?) -> String? {
        guard let id = normalize(source) else { return nil }
        if let label = sourceLabels[id] { return label }
        return id
            .replacingOccurrences(of: "[_-]+", with: " ", options: .regularExpression)
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

/// One rendered history group (01-SCREEN-SPECS §3, Sessions mode).
public struct SessionGroup: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable, Hashable {
        case pinned
        case live
        case recents
        case platform(String)
        case cron
        case archived
    }

    public let kind: Kind
    public let title: String
    public let sessions: [SessionSummary]
    public let defaultExpanded: Bool

    public var id: String {
        switch kind {
        case .pinned: return "pinned"
        case .live: return "live"
        case .recents: return "recents"
        case .platform(let id): return "platform-\(id)"
        case .cron: return "cron"
        case .archived: return "archived"
        }
    }

    /// Only Recents mixes sources, so only its rows carry a source badge.
    public var isMixed: Bool { kind == .recents }
}

/// The six-group Sessions-mode derivation. Order is fixed; an empty group is
/// removed, never rendered as zero. Membership precedence: archived is
/// exclusive, then pinned, then live, then source routes the rest.
public enum HistoryGrouping {
    public static func groups(from sessions: [SessionSummary]) -> [SessionGroup] {
        var pinned: [SessionSummary] = []
        var live: [SessionSummary] = []
        var recents: [SessionSummary] = []
        var platforms: [String: [SessionSummary]] = [:]
        var cron: [SessionSummary] = []
        var archived: [SessionSummary] = []

        for session in sessions {
            if session.archived {
                archived.append(session)
            } else if session.pinned {
                pinned.append(session)
            } else if session.isActive {
                live.append(session)
            } else if let source = SessionSource.normalize(session.source),
                      SessionSource.cronSourceIDs.contains(source) {
                cron.append(session)
            } else if let source = SessionSource.normalize(session.source),
                      SessionSource.messagingSourceIDs.contains(source) {
                platforms[source, default: []].append(session)
            } else {
                // Local ids and anything unrecognised — the desktop's recents
                // fetch keeps unknown sources in the main list too.
                recents.append(session)
            }
        }

        var result: [SessionGroup] = []
        if !pinned.isEmpty {
            result.append(SessionGroup(kind: .pinned, title: "Pinned", sessions: pinned, defaultExpanded: true))
        }
        if !live.isEmpty {
            result.append(SessionGroup(kind: .live, title: "Live", sessions: live, defaultExpanded: true))
        }
        if !recents.isEmpty {
            result.append(SessionGroup(kind: .recents, title: "Recents", sessions: recents, defaultExpanded: true))
        }
        // One group per platform, ordered by most-recent activity.
        let orderedPlatforms = platforms.sorted { lhs, rhs in
            (lhs.value.map(\.lastActive).max() ?? 0) > (rhs.value.map(\.lastActive).max() ?? 0)
        }
        for (source, rows) in orderedPlatforms {
            result.append(SessionGroup(
                kind: .platform(source),
                title: SessionSource.label(source) ?? source,
                sessions: rows,
                defaultExpanded: false
            ))
        }
        if !cron.isEmpty {
            result.append(SessionGroup(kind: .cron, title: "Cron jobs", sessions: cron, defaultExpanded: false))
        }
        if !archived.isEmpty {
            result.append(SessionGroup(kind: .archived, title: "Archived", sessions: archived, defaultExpanded: false))
        }
        return result
    }
}
