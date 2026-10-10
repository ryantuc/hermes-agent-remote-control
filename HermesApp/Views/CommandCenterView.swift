import HermesServeKit
import SwiftUI

enum UsageAutoload {
    /// Parent-scoped trigger (BUG-023). A branch-scoped `.task` on the Usage
    /// ScrollView can skip the first insertion.
    static func shouldLoad(tab: String, usageIsNull: Bool) -> Bool {
        tab == "Usage" && usageIsNull
    }
}

/// BUG-086: what the maintenance actions say instead of silently doing nothing.
///
/// `rest` and `client` are nilled only in `teardown()`, so this fires for a
/// phone with no profile at all, not for a dropped socket.
enum CommandCenterActionGate {
    static let noBackendMessage = "Not connected to a backend."

    /// `nil` when the action can be attempted; otherwise what to show instead
    /// of doing nothing.
    static func blockedMessage(hasBackend: Bool) -> String? {
        hasBackend ? nil : noBackendMessage
    }
}

/// What a Command Center tab draws when there is nothing it could load from: one centred "Not connected" note instead of a red error over an empty list.
///
/// Sessions are read over the gateway socket; the other three tabs read REST, which the demo never has, so in the demo those three say so rather than offering actions that can only fail.
enum CommandCenterAvailability {
    static let title = "Not connected"
    static let symbol = "bolt.horizontal.circle"

    /// nil when the tab can load; otherwise the line under the title.
    static func unavailableMessage(tab: String, hasSessionAPI: Bool, hasREST: Bool, isDemo: Bool) -> String? {
        switch tab {
        case "Sessions":
            return hasSessionAPI ? nil : "Connect a backend to see what is running."
        case "System", "Usage", "Maintenance":
            guard !hasREST else { return nil }
            if isDemo { return "The demo has no computer behind it, so there is nothing to show here." }
            switch tab {
            case "System": return "Connect a backend to see its status and logs."
            case "Usage": return "Connect a backend to see its token use and cost."
            default: return "Connect a backend to run diagnostics or back it up."
            }
        default:
            return nil
        }
    }

    /// What the Sessions tab draws over an empty list.
    enum SessionsEmptyState: Equatable {
        case notConnected(String)
        case loading
        case failed(String)
        case nothingRunning
    }

    /// A load in flight outranks a previous failure, so Try again shows progress instead of flashing "Nothing is running" and then the same error.
    static func sessionsEmptyState(hasSessionAPI: Bool, isLoading: Bool, error: String?) -> SessionsEmptyState {
        if !hasSessionAPI, let message = unavailableMessage(tab: "Sessions", hasSessionAPI: false, hasREST: false, isDemo: false) {
            return .notConnected(message)
        }
        if isLoading { return .loading }
        if let error { return .failed(error) }
        return .nothingRunning
    }
}

/// How one `/api/logs` line is classed for the System tab's counts and the log sheet's ink.
///
/// BUG-146: read the way the backend reads it, so a line the phone counts or inks as an error is a line the backend's `level=ERROR` filter would return. (The two still cover different windows: the counts read the last 200 lines unfiltered, the filtered sheet the last 300 matching lines.) The backend takes the FIRST whitespace-delimited level word as the line's level (`hermes_cli/logs.py` `_LEVEL_RE`, `_extract_level`) and its ERROR filter keeps CRITICAL (`_LEVEL_ORDER`); lines arrive newline-terminated, and `\s` includes that newline.
enum LogLineLevel: Equatable {
    case error
    case warning
    case other

    private static let levelPattern = try! NSRegularExpression(pattern: #"\s(DEBUG|INFO|WARNING|ERROR|CRITICAL)\s"#)

    static func of(_ line: String) -> LogLineLevel {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = levelPattern.firstMatch(in: line, range: range),
              let word = Range(match.range(at: 1), in: line)
        else { return .other }
        switch line[word] {
        case "ERROR", "CRITICAL": return .error
        case "WARNING": return .warning
        default: return .other
        }
    }
}

/// Command Center: the desktop's four sections at the bottom of
/// the hub — Sessions · System · Usage · Maintenance. Usage refreshes on
/// pull only (`session.usage` and the analytics route are not free); every
/// destructive action is a hold that names what it does. Curator and
/// memory-reset stay on the desktop, a deliberate divergence.
@MainActor
struct CommandCenterView: View {
    @Environment(\.hermes) private var t
    @Environment(AppModel.self) private var app

    @AppStorage("hermes.commandcenter.tab") private var tab = "Sessions"

    // Sessions
    @State private var live: [LiveSessionStatus] = []
    @State private var sessionsError: String?
    /// True from the first frame, so the screen does not say "Nothing is running" before it has asked.
    @State private var sessionsLoading = true
    @State private var interrupting: Set<String> = []
    /// The row awaiting the foreign-stop confirmation. `LiveSessionStatus` is
    /// already `Identifiable` on the runtime id, which is the id the interrupt
    /// is addressed to — the row and the target cannot drift apart.
    @State private var confirmingStop: LiveSessionStatus?

    // System
    @State private var logCounts: [String: (errors: Int, warnings: Int)] = [:]
    @State private var readingLog: String?
    @State private var restartResult: String?

    // Usage
    @State private var usageDays = 7
    @State private var usage: JSONValue = .null
    @State private var usageError: String?

    // Maintenance
    @State private var diagnostics: String?
    @State private var diagnosticsRunning = false
    @State private var backupResult: String?
    @State private var backupRunning = false

    private static let logFiles = ["agent", "gateway", "errors", "gui"]

    /// BUG-086, in the copy the three guards below write.
    private static let noBackendMessage = CommandCenterActionGate.noBackendMessage

    var body: some View {
        VStack(spacing: 0) {
            TabRow(tabs: ["Sessions", "System", "Usage", "Maintenance"], selection: $tab)
                .padding(.horizontal, Space.s6)
                .padding(.vertical, Space.s4)

            if tab != "Sessions", let message = unavailableMessage(for: tab) {
                StatePanel(symbol: CommandCenterAvailability.symbol, title: CommandCenterAvailability.title, message: message)
            } else {
                switch tab {
                case "System": systemTab
                case "Usage": usageTab
                case "Maintenance": maintenanceTab
                default: sessionsTab
                }
            }
        }
        .background(t.canvas)
        .navigationTitle("Command Center")
        .navigationBarTitleDisplayMode(.inline)
        .hermesTopBar()
        .task { await loadSessions(); await loadLogCounts() }
        .onAppear { Task { await loadUsageIfNeeded() } }
        .onChange(of: tab) { _, _ in
            Task { await loadUsageIfNeeded() }
        }
        .sheet(item: Binding(
            get: { readingLog.map(LogSelection.init(file:)) },
            set: { readingLog = $0?.file }
        )) { selection in
            LogReaderSheet(file: selection.file)
        }
    }

    private func unavailableMessage(for tab: String) -> String? {
        CommandCenterAvailability.unavailableMessage(
            tab: tab,
            hasSessionAPI: app.sessionAPI != nil,
            hasREST: app.rest != nil,
            isDemo: app.isDemoActive
        )
    }

    private struct LogSelection: Identifiable {
        let file: String
        var id: String { file }
    }

    // MARK: Sessions — live runtimes

    private var sessionsTab: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if live.isEmpty {
                    // One centred state for an empty list, never a red line over "Nothing is running."
                    Group {
                        switch CommandCenterAvailability.sessionsEmptyState(hasSessionAPI: app.sessionAPI != nil, isLoading: sessionsLoading, error: sessionsError) {
                        case .notConnected(let message):
                            StatePanel(symbol: CommandCenterAvailability.symbol, title: CommandCenterAvailability.title, message: message)
                        case .loading:
                            ProgressView()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .accessibilityLabel("Loading sessions")
                        case .failed(let error):
                            StatePanel.loadFailure(title: "Couldn't load sessions", error: error, hasBackend: app.sessionAPI != nil) {
                                Task { await loadSessions() }
                            }
                        case .nothingRunning:
                            StatePanel(symbol: "bolt.horizontal.circle", title: "Nothing is running", message: "Sessions working on your computer show here.")
                        }
                    }
                    .containerRelativeFrame(.vertical)
                } else {
                    if let sessionsError {
                        inlineError(sessionsError)
                    }
                    ForEach(live) { session in
                        FlatRow {
                            HStack(spacing: Space.s3) {
                                PulsingDot(color: session.status == "waiting" ? t.danger : t.warn, size: 7)
                                VStack(alignment: .leading, spacing: Space.s1) {
                                    Text(session.title.isEmpty ? "Untitled session" : session.title)
                                        .font(HermesFont.callout)
                                        .foregroundStyle(t.text1)
                                        .lineLimit(1)
                                    Text("\(session.status) · \(RelativeTime.short(epochSeconds: session.lastActive))")
                                        .font(HermesFont.footnote)
                                        .hermesNumeric()
                                        .foregroundStyle(t.text3)
                                }
                            }
                        } trailing: {
                            if interrupting.contains(session.id) {
                                ProgressView().controlSize(.small)
                            } else {
                                Button("Interrupt") {
                                    if app.stopRoute(forRuntimeSessionID: session.id).needsConfirmation {
                                        confirmingStop = session
                                    } else {
                                        Task { await interrupt(session) }
                                    }
                                }
                                .font(HermesFont.subhead)
                                .foregroundStyle(t.danger)
                                .buttonStyle(.plain)
                                .frame(minHeight: Hit.min)
                                .contentShape(Rectangle())
                                .accessibilityLabel(
                                    "Interrupt \(session.title.isEmpty ? "untitled session" : session.title)"
                                )
                            }
                        }
                    }
                }
            }
            .padding(.bottom, Space.s10)
        }
        .refreshable { await loadSessions() }
        // Attached to the scroll view, OUTSIDE the `ForEach`: a presentation
        // modifier inside a `LazyVStack` row belongs to a view the container is
        // free to tear down as the alert is asked to appear.
        .foreignStopConfirmation(target: $confirmingStop) { session in
            Task { await interrupt(session) }
        }
    }

    // MARK: System — status, logs, and system actions

    private var systemTab: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                SectionHeader("Status")
                statusRow(
                    "Gateway",
                    state: app.serverStatus?.gatewayRunning == true
                        ? (app.serverStatus?.gatewayState ?? "running") : "stopped",
                    healthy: app.serverStatus?.gatewayRunning == true
                )
                if let platforms = app.serverStatus?.raw["gateway_platforms"]?.objectValue {
                    ForEach(platforms.keys.sorted(), id: \.self) { key in
                        let state = platforms[key]?["state"]?.coercedString ?? ""
                        statusRow(key.capitalized, state: state, healthy: state == "connected")
                    }
                }

                SectionHeader("Logs")
                    .padding(.top, Space.s6)
                ForEach(Self.logFiles, id: \.self) { file in
                    logRow(file)
                }

                SectionHeader("Actions")
                    .padding(.top, Space.s6)
                VStack(alignment: .leading, spacing: Space.s3) {
                    HoldToConfirmButton("Hold to restart the gateway") {
                        Task { await restartGateway() }
                    }
                    if let restartResult {
                        Text(restartResult)
                            .font(HermesFont.footnote)
                            .foregroundStyle(t.text3)
                    }
                }
                .padding(.horizontal, Space.s6)
                .padding(.vertical, Space.s4)
            }
            .padding(.bottom, Space.s10)
        }
        .refreshable { await loadLogCounts() }
    }

    private func statusRow(_ label: String, state: String, healthy: Bool) -> some View {
        FlatRow {
            HStack(spacing: Space.s3) {
                Circle()
                    .fill(healthy ? t.ok : (state.isEmpty || state == "disconnected" ? t.text4 : t.danger))
                    .frame(width: 7, height: 7)
                Text(label)
                    .font(HermesFont.callout)
                    .foregroundStyle(t.text1)
            }
        } trailing: {
            Text(state.isEmpty ? "unknown" : state)
                .font(HermesFont.subhead)
                .foregroundStyle(t.text3)
        }
    }

    private func logRow(_ file: String) -> some View {
        Button {
            readingLog = file
        } label: {
            FlatRow {
                Text("\(file).log")
                    .font(HermesFont.code)
                    .foregroundStyle(t.text1)
            } trailing: {
                HStack(spacing: Space.s3) {
                    if let counts = logCounts[file] {
                        if counts.errors > 0 {
                            Text("\(counts.errors) ERROR")
                                .font(HermesFont.caption)
                                .hermesNumeric()
                                .foregroundStyle(t.danger)
                        }
                        if counts.warnings > 0 {
                            Text("\(counts.warnings) WARN")
                                .font(HermesFont.caption)
                                .hermesNumeric()
                                .foregroundStyle(t.warn)
                        }
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(t.text4)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(file) log")
    }

    // MARK: Usage — pull to refresh only

    private var usageTab: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                SegmentedRow(
                    options: [7, 30, 90],
                    selection: Binding(
                        get: { usageDays },
                        set: { newValue in
                            usageDays = newValue
                            Task { await loadUsage() }
                        }
                    ),
                    label: { "\($0) days" }
                )
                .padding(.horizontal, Space.s6)
                .padding(.vertical, Space.s4)

                if let usageError {
                    inlineError(usageError)
                } else if usage == .null {
                    Text("Pull to load usage.")
                        .font(HermesFont.subhead)
                        .foregroundStyle(t.text3)
                        .padding(Space.s6)
                } else {
                    statCards
                    modelBreakdown
                }
            }
            .padding(.bottom, Space.s10)
        }
        .refreshable { await loadUsage() }
    }

    private var statCards: some View {
        let totals = usage["totals"]
        let items: [(String, String)] = [
            ("Tokens in", compact(totals?["total_input"]?.coercedDouble)),
            ("Tokens out", compact(totals?["total_output"]?.coercedDouble)),
            ("Sessions", compact(totals?["total_sessions"]?.coercedDouble)),
            ("Est. cost", cost(totals?["total_estimated_cost"]?.coercedDouble)),
        ]
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: Space.s3), GridItem(.flexible(), spacing: Space.s3)], spacing: Space.s3) {
            ForEach(items, id: \.0) { item in
                VStack(alignment: .leading, spacing: Space.s1) {
                    Text(item.1)
                        .font(HermesFont.title)
                        .hermesNumeric()
                        .foregroundStyle(t.text1)
                    Text(item.0)
                        .font(HermesFont.footnote)
                        .foregroundStyle(t.text3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Space.s5)
                .background(t.fill2, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            }
        }
        .padding(.horizontal, Space.s6)
    }

    @ViewBuilder
    private var modelBreakdown: some View {
        let models = usage["by_model"]?.arrayValue ?? []
        if !models.isEmpty {
            SectionHeader("By model")
                .padding(.top, Space.s6)
            let totalTokens = models.reduce(0.0) {
                $0 + ($1["input_tokens"]?.coercedDouble ?? 0) + ($1["output_tokens"]?.coercedDouble ?? 0)
            }
            ForEach(Array(models.enumerated()), id: \.offset) { _, model in
                let tokens = (model["input_tokens"]?.coercedDouble ?? 0) + (model["output_tokens"]?.coercedDouble ?? 0)
                FlatRow {
                    Text(model["model"]?.coercedString ?? "unknown")
                        .font(HermesFont.code)
                        .foregroundStyle(t.text1)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } trailing: {
                    Text(totalTokens > 0
                         ? "\(compact(tokens)) · \(Int((tokens / totalTokens * 100).rounded()))%"
                         : compact(tokens))
                        .font(HermesFont.subhead)
                        .hermesNumeric()
                        .foregroundStyle(t.text3)
                }
            }
        }
    }

    // MARK: Maintenance

    private var maintenanceTab: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                SectionHeader("Diagnostics")
                VStack(alignment: .leading, spacing: Space.s3) {
                    Button(diagnosticsRunning ? "Running…" : "Run diagnostics") {
                        Task { await runDiagnostics() }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(diagnosticsRunning)
                    if let diagnostics {
                        ScrollView(.horizontal, showsIndicators: true) {
                            Text(diagnostics)
                                .font(HermesFont.codeSmall)
                                .foregroundStyle(t.text2)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 320)
                    }
                }
                .padding(.horizontal, Space.s6)
                .padding(.vertical, Space.s4)

                SectionHeader("Backups")
                    .padding(.top, Space.s6)
                VStack(alignment: .leading, spacing: Space.s3) {
                    Button(backupRunning ? "Backing up…" : "Back up now") {
                        Task { await runBackup() }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(backupRunning)
                    if let backupResult {
                        Text(backupResult)
                            .font(HermesFont.footnote)
                            .foregroundStyle(t.text3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, Space.s6)
                .padding(.vertical, Space.s4)

                Text("The curator and memory-data reset stay on the desktop: gardening long-term memory is deliberate work, and a mis-tap here would delete it.")
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.text3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(Space.s6)
            }
            .padding(.bottom, Space.s10)
        }
    }

    private func inlineError(_ message: String) -> some View {
        Text(message)
            .font(HermesFont.footnote)
            .foregroundStyle(t.danger)
            .padding(.horizontal, Space.s6)
            .padding(.vertical, Space.s4)
    }

    // MARK: Data

    #if DEBUG
    /// Two rows that look exactly like `session.active_list` answered them, for
    /// the `commandcenter-live` screenshot route (BUG-032). Neither id is known
    /// to the engine, so both route to `.confirmThenStopUnattended`.
    static func demoLiveSessions() -> [LiveSessionStatus] {
        let now = Date().timeIntervalSince1970
        func row(_ id: String, _ title: String, _ status: String, ago: Double) -> LiveSessionStatus {
            LiveSessionStatus(json: .object([
                "id": .string(id),
                "session_key": .string("stored-" + id),
                "title": .string(title),
                "preview": .string(""),
                "last_active": .number(now - ago),
                "status": .string(status),
            ]))
        }
        return [
            row("rt-demo-working", "Nightly digest", "working", ago: 40),
            row("rt-demo-waiting", "Refactor the connect machine", "waiting", ago: 120),
        ]
    }
    #endif

    private func loadSessions() async {
        sessionsLoading = true
        defer { sessionsLoading = false }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-hermesDemoLiveSessions") {
            sessionsError = nil
            live = Self.demoLiveSessions()
            return
        }
        #endif
        guard let sessionAPI = app.sessionAPI else {
            sessionsError = "Not connected to a backend."
            return
        }
        // The previous error stays until a load succeeds, so a retry never passes through "Nothing is running" on its way back to the same failure.
        do {
            live = try await sessionAPI.activeList()
            sessionsError = nil
        } catch {
            sessionsError = describe(error)
        }
    }

    private func interrupt(_ session: LiveSessionStatus) async {
        interrupting.insert(session.id)
        defer { interrupting.remove(session.id) }
        do {
            switch app.stopRoute(forRuntimeSessionID: session.id) {
            case .stopAttendedChat, .confirmThenStopAttendedChat:
                // The phone has this conversation open, so route through its own
                // Stop rather than re-implementing the shared machinery here.
                app.chat(runtimeSessionID: session.id)?.stopTapped()
            case .confirmThenStopUnattended:
                try await app.stopUnattendedSession(runtimeSessionID: session.id)
            }
            await loadSessions()
        } catch {
            sessionsError = describe(error)
        }
    }

    private func loadLogCounts() async {
        guard let rest = app.rest else { return }
        for file in Self.logFiles {
            guard let json = try? await rest.getJSON(
                "/api/logs",
                query: [URLQueryItem(name: "file", value: file), URLQueryItem(name: "lines", value: "200")]
            ) else { continue }
            let lines = json["lines"]?.arrayValue?.compactMap { $0.coercedString } ?? []
            logCounts[file] = (
                errors: lines.filter { LogLineLevel.of($0) == .error }.count,
                warnings: lines.filter { LogLineLevel.of($0) == .warning }.count
            )
        }
    }

    private func restartGateway() async {
        guard let rest = app.rest else {
            restartResult = Self.noBackendMessage
            return
        }
        restartResult = "Restarting…"
        do {
            try await rest.sendJSON("POST", "/api/gateway/restart")
            restartResult = "Restart requested. The gateway comes back on its own."
        } catch {
            restartResult = describe(error)
        }
    }

    private func loadUsageIfNeeded() async {
        guard UsageAutoload.shouldLoad(tab: tab, usageIsNull: usage == .null) else { return }
        await loadUsage()
    }

    private func loadUsage() async {
        guard let rest = app.rest else {
            usageError = "Not connected to a backend."
            return
        }
        usageError = nil
        do {
            usage = try await rest.getJSON(
                "/api/analytics/usage",
                query: [URLQueryItem(name: "days", value: String(usageDays))]
            )
        } catch {
            usageError = describe(error)
        }
    }

    private func runDiagnostics() async {
        guard let client = app.client else {
            diagnostics = Self.noBackendMessage
            return
        }
        diagnosticsRunning = true
        defer { diagnosticsRunning = false }
        do {
            let result = try await client.request("setup.runtime_check", params: .object([:]))
            diagnostics = (try? JSONRPCCodec.encodeLine(result)) ?? "\(result)"
        } catch {
            diagnostics = describe(error)
        }
    }

    private func runBackup() async {
        guard let rest = app.rest else {
            backupResult = Self.noBackendMessage
            return
        }
        backupRunning = true
        defer { backupRunning = false }
        do {
            // BUG-106: the body and the response envelope both live in the
            // kit now. This call sent no body at all, which the route answers
            // with a 422, and then read two keys it has never returned.
            let archive = try await rest.runBackup()
            backupResult = archive.isEmpty ? "Backup finished." : "Backed up to \(archive)"
        } catch {
            backupResult = describe(error)
        }
    }

    private func compact(_ value: Double?) -> String {
        guard let value else { return "—" }
        if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fk", value / 1_000) }
        // BUG-109's third site. The two branches above return before the
        // conversion for any large *positive* number, so only a large negative
        // one reaches it — narrower than the settings rows, same trap.
        return SettingRowDescriptor.integerText(value)
    }

    private func cost(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "$%.2f", value)
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

// MARK: - Log reader

/// The filtered log reader: monospace tail with a level
/// filter, redacted the same way Diagnostics is.
@MainActor
private struct LogReaderSheet: View {
    @Environment(\.hermes) private var t
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    let file: String

    @State private var lines: [String] = []
    @State private var level = "All"
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(file).log")
                    .font(HermesFont.heading)
                    .foregroundStyle(t.text1)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(t.text3)
                }
                .buttonStyle(IconButtonStyle())
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, Space.s6)
            .padding(.top, Space.s6)

            SegmentedRow(
                options: ["All", "WARNING", "ERROR"],
                selection: Binding(
                    get: { level },
                    set: { newValue in
                        level = newValue
                        Task { await load() }
                    }
                ),
                label: { $0.capitalized }
            )
            .padding(.horizontal, Space.s6)
            .padding(.vertical, Space.s4)

            if let loadError {
                Text(loadError)
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.danger)
                    .padding(.horizontal, Space.s6)
            }

            ScrollView([.vertical, .horizontal], showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(DisplayRedaction.preview(line, limit: 400))
                            .font(HermesFont.codeSmall)
                            .foregroundStyle(tone(for: line))
                            .textSelection(.enabled)
                    }
                }
                .padding(Space.s6)
            }
        }
        .background(t.canvas)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(Radius.sheet)
        .presentationBackground(t.canvas)
        .task { await load() }
    }

    private func tone(for line: String) -> Color {
        switch LogLineLevel.of(line) {
        case .error: return t.danger
        case .warning: return t.warn
        case .other: return t.text2
        }
    }

    private func load() async {
        guard let rest = app.rest else {
            loadError = "Not connected to a backend."
            return
        }
        loadError = nil
        var query = [
            URLQueryItem(name: "file", value: file),
            URLQueryItem(name: "lines", value: "300"),
        ]
        if level != "All" { query.append(URLQueryItem(name: "level", value: level)) }
        do {
            let json = try await rest.getJSON("/api/logs", query: query)
            lines = json["lines"]?.arrayValue?.compactMap { $0.coercedString } ?? []
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
