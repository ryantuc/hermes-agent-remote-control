import HermesServeKit
import SwiftUI
import UIKit

/// Connection log + server status dump.
///
/// Everything shown here is sanitized twice: the log scrubs on write, and the
/// status dump drops the loopback-only recon fields.
@MainActor
struct DiagnosticsView: View {
    @Environment(\.hermes) private var t
    @Environment(AppModel.self) private var app

    @State private var entries: [ConnectionLog.Entry] = []
    @State private var showingStatusDump = false
    @State private var isRefreshing = false
    /// FEAT-034. Snapshotted rather than read live: the buffer is written from
    /// `ChatView`'s scroll path and a view that read it on every draw would be
    /// observing it through a lock on the main thread.
    @State private var scrollLog: [TranscriptScrollBuffer.Entry] = []

    var body: some View {
        // Pushed as Settings → Diagnostics: no inner NavigationStack, no Done.
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                connectionGroup
                if app.serverStatus != nil {
                    statusDumpGroup
                }
                // Above the connection log deliberately: that log is hundreds of
                // rows deep, so a Copy button underneath it is never found.
                transcriptScrollGroup
                logGroup
            }
            .padding(.bottom, Space.s10)
        }
        .background(t.canvas)
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(t.canvas, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        Task { @MainActor in
                            UIPasteboard.general.string = await app.log.export()
                        }
                    } label: {
                        Label("Copy log", systemImage: "doc.on.doc")
                    }
                    Button(role: .destructive) {
                        Task { @MainActor in
                            await app.log.clear()
                            entries = []
                        }
                    } label: {
                        Label("Clear log", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").foregroundStyle(t.text1)
                }
            }
        }
        .refreshable { await reload() }
        .task { await reload() }
        .task {
            // Light poll while the screen is visible; the log is an actor
            // and has no change stream.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled else { return }
                await reload()
            }
        }
    }

    // MARK: Groups

    private var connectionGroup: some View {
        group("Connection") {
            // FEAT-002: a diagnostics copy is worthless without the build it
            // came from, and this screen is the one people photograph.
            infoRow("App", AppVersion.current)
            infoRow("State", stateDescription)
            if let profile = app.activeProfile,
               let configuration = try? profile.makeConfiguration() {
                infoRow("Server", DisplayRedaction.serverIdentity(configuration))
                infoRow("Transport", configuration.isSecure ? "TLS (wss)" : "Plaintext (ws)")
            }
            if let status = app.serverStatus {
                infoRow("Hermes", status.version)
                infoRow("Gateway", status.gatewayState.isEmpty ? "unknown" : status.gatewayState)
                infoRow("Overall", status.overall.isEmpty ? "unknown" : status.overall)
            }
            if let error = app.connectionError {
                Text(error)
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.danger)
                    .padding(.horizontal, Space.s6)
                    .padding(.bottom, Space.s5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var statusDumpGroup: some View {
        group("Server status", footer: "Filesystem paths and process ids are removed before display.") {
            Button {
                withAnimation(Motion.quick) { showingStatusDump.toggle() }
            } label: {
                FlatRow(showsHairline: false) {
                    Text(showingStatusDump ? "Hide /api/status" : "Show /api/status")
                        .font(HermesFont.callout)
                        .foregroundStyle(t.action)
                } trailing: {
                    Image(systemName: "doc.text.magnifyingglass").foregroundStyle(t.text3)
                }
            }
            .buttonStyle(.plain)

            if showingStatusDump, let dump = statusDump {
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(dump)
                        .font(HermesFont.codeSmall)
                        .foregroundStyle(t.text2)
                        .textSelection(.enabled)
                        .padding(Space.s5)
                }
                .frame(maxHeight: 320)
                .background(t.surface2, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .padding(.horizontal, Space.s6)
                .padding(.bottom, Space.s5)
            }
        }
    }

    /// FEAT-034. One block of the exact text the buttons export, so what is on
    /// screen is literally what lands on the clipboard.
    private var transcriptScrollGroup: some View {
        group(
            "Transcript scroll log \u{00B7} \(scrollLog.count)",
            footer: "The last \(TranscriptScrollBuffer.shared.capacity) transcript placement events \u{2014} chrome transitions, status-slot transitions and scroll calls, with their T A N E P fingerprint. Heights and flags only; no message content passes through here. Per-delta follow-scrolls are omitted, as they are in the log stream at its default level."
        ) {
            if scrollLog.isEmpty {
                Text("Nothing recorded yet. Open a conversation, send a message while one is streaming, and come back.")
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.text3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Space.s6)
                    .padding(.bottom, Space.s5)
            } else {
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(scrollLogText)
                        .font(HermesFont.codeSmall)
                        .foregroundStyle(t.text2)
                        .textSelection(.enabled)
                        .padding(Space.s5)
                }
                .frame(maxHeight: 320)
                .background(t.surface2, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .padding(.horizontal, Space.s6)
                .padding(.bottom, Space.s4)
            }

            HStack(spacing: Space.s4) {
                Button("Copy") {
                    UIPasteboard.general.string = scrollLogExport
                    HapticFeedback.copied()
                }
                .disabled(scrollLog.isEmpty)
                ShareLink(item: scrollLogExport) {
                    Text("Share")
                }
                .disabled(scrollLog.isEmpty)
                Spacer(minLength: 0)
                Button("Clear", role: .destructive) {
                    TranscriptScrollBuffer.shared.clear()
                    scrollLog = []
                }
                .disabled(scrollLog.isEmpty)
            }
            .font(HermesFont.callout)
            .frame(minHeight: Hit.min)
            .padding(.horizontal, Space.s6)
            .padding(.bottom, Space.s3)
        }
    }

    /// What the block draws: the entries alone.
    private var scrollLogText: String {
        TranscriptScrollBuffer.shared.exportText()
    }

    /// What Copy and Share hand over: the same text under a header naming the
    /// build (FEAT-002).
    private var scrollLogExport: String {
        TranscriptScrollBuffer.shared.exportText(
            header: "Hermes transcript scroll log \u{00B7} \(AppVersion.current) \u{00B7} \(scrollLog.count) entries"
        )
    }

    private var logGroup: some View {
        group(
            "Connection log · \(entries.count)",
            footer: "A rolling in-memory buffer. Tokens, tickets, cookies and inline attachment bytes are replaced with <redacted> before an entry is stored."
        ) {
            if entries.isEmpty {
                Text("No log entries yet.")
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.text3)
                    .padding(.horizontal, Space.s6)
                    .padding(.bottom, Space.s5)
            }
            ForEach(entries.reversed()) { entry in
                VStack(alignment: .leading, spacing: Space.s1) {
                    HStack(spacing: Space.s3) {
                        Text(entry.level.rawValue.uppercased())
                            .font(HermesFont.caption)
                            .foregroundStyle(color(for: entry.level))
                        Text(entry.category)
                            .font(HermesFont.footnote)
                            .foregroundStyle(t.text3)
                        Spacer()
                        Text(RelativeTime.absolute(entry.date))
                            .font(HermesFont.footnote)
                            .hermesNumeric()
                            .foregroundStyle(t.text3)
                    }
                    Text(entry.message)
                        .font(HermesFont.subhead)
                        .foregroundStyle(t.text2)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, Space.s6)
                .padding(.vertical, Space.s3)
            }
        }
    }

    // MARK: Building blocks

    @ViewBuilder
    private func group<Content: View>(
        _ title: String,
        footer: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .hermesCaption()
                .foregroundStyle(t.text3)
                .padding(.horizontal, Space.s6)
                .padding(.top, Space.s8)
                .padding(.bottom, Space.s3)
            content()
            if let footer {
                Text(footer)
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.text3)
                    .padding(.horizontal, Space.s6)
                    .padding(.top, Space.s3)
                    .padding(.bottom, Space.s5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .hairline()
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        FlatRow(showsHairline: false) {
            Text(label)
                .font(HermesFont.callout)
                .foregroundStyle(t.text2)
        } trailing: {
            Text(value)
                .font(HermesFont.callout)
                .foregroundStyle(t.text1)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    // MARK: Data

    @MainActor
    private func reload() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        entries = await app.log.entries()
        scrollLog = TranscriptScrollBuffer.shared.entries
        isRefreshing = false
    }

    private var statusDump: String? {
        app.serverStatus?.sanitizedDump.prettyJSONString
    }

    private var stateDescription: String {
        switch app.connectionState {
        case .idle: return "Idle"
        case .connecting: return "Connecting"
        case .open: return "Open"
        case .reconnecting(let attempt, let retry):
            return "Reconnecting (attempt \(attempt), retry in \(Int(retry))s)"
        case .offline: return "Offline"
        case .unauthorized: return "Not authorized"
        }
    }

    private func color(for level: ConnectionLog.Level) -> Color {
        switch level {
        case .debug: return t.text3
        case .info: return t.accent
        case .warning: return t.warn
        case .error: return t.danger
        }
    }
}
