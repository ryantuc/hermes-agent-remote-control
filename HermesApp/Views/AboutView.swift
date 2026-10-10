import HermesServeKit
import SwiftUI

/// The About screen's two outbound links: the privacy policy and the contact/support surface.
enum AboutLinkRow: CaseIterable {
    case privacyPolicy
    case support

    var title: String {
        switch self {
        case .privacyPolicy: return "Privacy Policy"
        case .support: return "Contact & Support"
        }
    }

    var detail: String {
        switch self {
        case .privacyPolicy:
            return "What this app sends to the backend you chose, and what that backend keeps."
        case .support:
            return "Reach the developer about this app."
        }
    }

    func url(privacyPolicy: URL?, support: URL?) -> URL? {
        switch self {
        case .privacyPolicy: return privacyPolicy
        case .support: return support
        }
    }

    /// The rows About draws. A `nil` link means no row.
    static func visibleRows(
        privacyPolicy: URL? = HermesLinks.privacyPolicy,
        support: URL? = HermesLinks.support
    ) -> [AboutLinkRow] {
        allCases.filter { $0.url(privacyPolicy: privacyPolicy, support: support) != nil }
    }
}

/// One row in the About screen's Support group, in the order it is drawn; unlike `AboutLinkRow` this group always exists.
enum AboutSupportEntry: Hashable {
    case github(URL)
    case link(AboutLinkRow)
    /// The second way into `DiagnosticsView`, and the one a person looks for.
    case diagnostics
    /// A preference about this app, which is what this screen is.
    case advancedToggle

    static func entries(
        github: URL? = HermesLinks.github,
        privacyPolicy: URL? = HermesLinks.privacyPolicy,
        support: URL? = HermesLinks.support
    ) -> [AboutSupportEntry] {
        var entries: [AboutSupportEntry] = []
        if let github { entries.append(.github(github)) }
        entries += AboutLinkRow
            .visibleRows(privacyPolicy: privacyPolicy, support: support)
            .map(AboutSupportEntry.link)
        entries.append(.diagnostics)
        entries.append(.advancedToggle)
        return entries
    }

    static func entries(_ links: AboutLinks) -> [AboutSupportEntry] {
        entries(github: links.github, privacyPolicy: links.privacyPolicy, support: links.support)
    }

    /// Where a row goes, from the same links that decided it exists; nil for the two rows that are not links.
    func destination(in links: AboutLinks) -> URL? {
        switch self {
        case .github(let url): return url
        case .link(let row): return row.url(privacyPolicy: links.privacyPolicy, support: links.support)
        case .diagnostics, .advancedToggle: return nil
        }
    }
}

/// The About screen's outbound links, read once (BUG-146): the view used to build its rows from one read of `HermesLinks` and resolve their URLs from another, so a row built from any other values drew nothing.
struct AboutLinks: Equatable {
    var github: URL?
    var privacyPolicy: URL?
    var support: URL?

    static let shipped = AboutLinks(github: HermesLinks.github, privacyPolicy: HermesLinks.privacyPolicy, support: HermesLinks.support)
}

/// Settings → About: versions, a configuration export, and the Support group.
///
/// Import and reset-to-defaults stay off the phone: the PUT contract is a deep merge and cannot delete keys, so a faithful reset needs the raw config route.
@MainActor
struct AboutView: View {
    @Environment(\.hermes) private var t
    @Environment(AppModel.self) private var app

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                SectionHeader("This app")
                    .padding(.top, Space.settingsTop)
                infoRow("Version", value: AppVersion.current)

                SectionHeader("Backend")
                    .padding(.top, Space.s8)
                if let status = app.serverStatus {
                    infoRow("Hermes", value: Self.backendVersionLabel(version: status.version, isDemo: app.isDemoActive))
                    if !status.releaseDate.isEmpty {
                        infoRow("Release", value: status.releaseDate)
                    }
                    let contract = status.raw["config_version"]?.coercedInt ?? 0
                    if contract > 0 {
                        infoRow("Config version", value: String(contract))
                    }
                } else {
                    infoRow("Hermes", value: "Not connected")
                }

                configurationSection

                supportSection
            }
            .padding(.bottom, Space.s10)
        }
        .background(t.canvas)
        .navigationTitle("About HARC")
        .navigationBarTitleDisplayMode(.inline)
        .hermesTopBar()
        .task { await app.settings.loadIfNeeded() }
    }

    /// The backend row's value: the demo by name, never a bare "v" for a backend that reports no version.
    static func backendVersionLabel(version: String, isDemo: Bool) -> String {
        if isDemo { return "Demo" }
        return version.isEmpty ? "Unknown" : "v\(version)"
    }

    static let advancedSubtitle = "Timeouts, output limits, subagents and other advanced options."

    private func infoRow(_ label: String, value: String) -> some View {
        FlatRow {
            Text(label)
                .font(HermesFont.callout)
                .foregroundStyle(t.text1)
        } trailing: {
            Text(value)
                .font(HermesFont.subhead)
                .hermesNumeric()
                .foregroundStyle(t.text3)
        }
    }

    /// Header and row together, or neither: the export row is this group's only member and exists only while a document is loaded.
    @ViewBuilder
    private var configurationSection: some View {
        if let document = app.settings.document {
            let redacted = ConfigExportRedaction.redactForShare(document)
            if let text = try? JSONRPCCodec.encodeLine(redacted.document) {
                SectionHeader("Configuration")
                    .padding(.top, Space.s8)
                exportRow(redacted, text: text)
            }
        }
    }

    private func exportRow(_ redacted: ConfigExportRedaction.Result, text: String) -> some View {
        ShareLink(item: text, preview: SharePreview("Hermes configuration")) {
            FlatRow {
                VStack(alignment: .leading, spacing: Space.s1) {
                    Text("Export configuration")
                        .font(HermesFont.callout)
                        .foregroundStyle(t.text1)
                    Text(Self.exportExplainer(redacted))
                        .font(HermesFont.footnote)
                        .foregroundStyle(t.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } trailing: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 15))
                    .foregroundStyle(t.text3)
            }
        }
    }

    /// What the export row says, given what the redactor actually removed; BUG-085: no state may promise the export is clean, since a secret under an unknown key is residual by construction.
    static func exportExplainer(_ result: ConfigExportRedaction.Result) -> String {
        guard result.didRedactAnything else {
            return "The configuration as JSON, for backup or a bug report. No known secret fields were present — check it before sharing anyway, since a secret under a custom key cannot be recognised."
        }
        let base = "The configuration as JSON, for backup or a bug report. Known secret fields — API keys, dashboard auth, MCP environment values — are replaced with \(ConfigExportRedaction.placeholder). Redaction is best-effort: check it before sharing, especially if you keep secrets under custom keys."
        guard result.usedFallbackLiteralPass else { return base }
        return base + " Values repeating a secret found elsewhere were masked too."
    }

    /// The group always exists; a privacy or support URL the operator has not supplied draws no row, because a dead link is worse than no link.
    @ViewBuilder
    private var supportSection: some View {
        SectionHeader("Support")
            .padding(.top, Space.s8)
        ForEach(AboutSupportEntry.entries(links), id: \.self) { entry in
            supportRow(entry)
        }
    }

    /// One read for both the rows and their URLs.
    private var links: AboutLinks { .shipped }

    @ViewBuilder
    private func supportRow(_ entry: AboutSupportEntry) -> some View {
        switch entry {
        case .github(let url):
            outboundRow(
                title: "GitHub",
                detail: "The source for this app, and where to report a problem with it.",
                url: url
            )
        case .link(let row):
            if let url = entry.destination(in: links) {
                outboundRow(title: row.title, detail: row.detail, url: url)
            }
        case .diagnostics:
            diagnosticsRow
        case .advancedToggle:
            advancedToggleRow
        }
    }

    private func outboundRow(title: String, detail: String, url: URL) -> some View {
        Link(destination: url) {
            FlatRow {
                VStack(alignment: .leading, spacing: Space.s1) {
                    Text(title)
                        .font(HermesFont.callout)
                        .foregroundStyle(t.text1)
                    Text(detail)
                        .font(HermesFont.footnote)
                        .foregroundStyle(t.text3)
                        // `Link` centres a wrapped label; every other row on this screen is flush left.
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } trailing: {
                Image(systemName: "arrow.up.forward.square")
                    .font(.system(size: 15))
                    .foregroundStyle(t.text3)
            }
        }
        .accessibilityLabel(title)
    }

    /// `NavigationLink(value:)` rather than a path binding, which keeps this screen constructible with no arguments as `RootView`'s route table needs.
    private var diagnosticsRow: some View {
        NavigationLink(value: AppRoute.settingsDiagnostics) {
            FlatRow {
                VStack(alignment: .leading, spacing: Space.s1) {
                    Text("Connection diagnostics")
                        .font(HermesFont.callout)
                        .foregroundStyle(t.text1)
                    Text("Connection state, server status, and the rolling log — what to attach to a report.")
                        .font(HermesFont.footnote)
                        .foregroundStyle(t.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } trailing: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(t.text4)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Connection diagnostics")
    }

    private var advancedToggleRow: some View {
        SwitchRow(
            "Show advanced settings",
            subtitle: Self.advancedSubtitle,
            isOn: Binding(
                get: { app.settings.showAdvanced },
                set: { app.settings.showAdvanced = $0 }
            )
        )
    }
}
