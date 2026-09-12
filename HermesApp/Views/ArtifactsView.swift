import HermesServeKit
import SafariServices
import SwiftUI
import UIKit

/// Settings → Workspace → Artifacts: the desktop's four filters — All · Images
/// · Files · Links — over the same client-side scrape. It is a scrape, not an
/// index: recent sessions only, cached per session.
@MainActor
struct ArtifactsView: View {
    @Environment(\.hermes) private var t
    @Environment(AppModel.self) private var app

    @AppStorage("hermes.artifacts.tab") private var tab = "All"

    @State private var records: [ArtifactScrape.Record] = []
    @State private var scanned = 0
    @State private var totalToScan = 0
    @State private var isScanning = false
    @State private var loadError: String?
    @State private var safariURL: URL?
    @State private var imageURLs: [String: URL] = [:]
    /// A gateway path awaiting Quick Look.
    @State private var quickLookPath: String?

    /// The scrape covers this many recent sessions — a phone-scale cap, said
    /// out loud in the footer rather than silently truncating.
    private static let sessionBudget = 15

    var body: some View {
        VStack(spacing: 0) {
            TabRow(tabs: ["All", "Images", "Files", "Links"], selection: $tab)
                .padding(.horizontal, Space.s6)
                .padding(.vertical, Space.s4)

            content
        }
        .background(t.canvas)
        .navigationTitle("Artifacts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(t.canvas, for: .navigationBar)
        .task { await scanIfNeeded() }
        .refreshable { await scan() }
        .sheet(item: Binding(
            get: { safariURL.map(SafariItem.init(url:)) },
            set: { safariURL = $0?.url }
        )) { item in
            SafariView(url: item.url)
                .ignoresSafeArea()
        }
        .sheet(item: Binding(
            get: { quickLookPath.map(QuickLookItem.init(path:)) },
            set: { quickLookPath = $0?.path }
        )) { item in
            QuickLookSheet(path: item.path)
        }
    }

    private struct SafariItem: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }

    private struct QuickLookItem: Identifiable {
        let path: String
        var id: String { path }
    }

    private var filtered: [ArtifactScrape.Record] {
        let byTab: [ArtifactScrape.Record]
        switch tab {
        case "Images": byTab = records.filter { $0.kind == .image }
        case "Files": byTab = records.filter { $0.kind == .file }
        case "Links": byTab = records.filter { $0.kind == .link }
        default: byTab = records
        }
        return byTab.sorted { $0.timestamp > $1.timestamp }
    }

    @ViewBuilder
    private var content: some View {
        if let loadError {
            VStack(alignment: .leading, spacing: Space.s5) {
                Text("Couldn't scan sessions")
                    .font(HermesFont.heading)
                    .foregroundStyle(t.text1)
                Text(loadError)
                    .font(HermesFont.subhead)
                    .foregroundStyle(t.text3)
                Button("Try again") { Task { await scan() } }
                    .buttonStyle(SecondaryButtonStyle())
                    .frame(maxWidth: 220)
            }
            .padding(Space.s6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if isScanning && records.isEmpty {
            VStack(spacing: Space.s4) {
                ProgressView()
                Text(totalToScan > 0 ? "Scanning \(scanned) of \(totalToScan) sessions" : "Scanning…")
                    .font(HermesFont.footnote)
                    .hermesNumeric()
                    .foregroundStyle(t.text3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filtered.isEmpty {
            Text("Nothing here yet. Artifacts are the images, files and links the agent produced in your \(Self.sessionBudget) most recent sessions.")
                .font(HermesFont.subhead)
                .foregroundStyle(t.text3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(Space.s6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if tab == "Images" {
            imageGrid
        } else {
            rowList
        }
    }

    // MARK: Images — 3-up, newest first

    private var imageGrid: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.s3), count: 3), spacing: Space.s3) {
                ForEach(filtered) { record in
                    imageCell(record)
                }
            }
            .padding(.horizontal, Space.s6)
            .padding(.bottom, Space.s10)
            footer
        }
    }

    private func imageCell(_ record: ArtifactScrape.Record) -> some View {
        Button {
            open(record)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .fill(t.surface2)
                if let url = imageURLs[record.id] {
                    // Authenticated gateway images resolve to data: URLs;
                    // AsyncImage only loads http(s), so decode those inline.
                    if url.scheme == "data", let dataImage = Self.uiImage(fromDataURL: url) {
                        Image(uiImage: dataImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().aspectRatio(contentMode: .fill)
                            case .failure:
                                Image(systemName: "photo")
                                    .foregroundStyle(t.text4)
                            default:
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 104)
            .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .task { imageURLs[record.id] = await resolveURL(record) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(record.label), from \(record.sessionTitle)")
    }

    private static func uiImage(fromDataURL url: URL) -> UIImage? {
        // data:image/...;base64,<payload>
        let absolute = url.absoluteString
        guard let comma = absolute.firstIndex(of: ","),
              let data = Data(base64Encoded: String(absolute[absolute.index(after: comma)...]))
        else { return nil }
        return UIImage(data: data)
    }

    // MARK: Files and links — provenance rows

    private var rowList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(filtered) { record in
                    Button {
                        open(record)
                    } label: {
                        FlatRow {
                            HStack(spacing: Space.s3) {
                                Image(systemName: glyph(for: record.kind))
                                    .font(.system(size: 14))
                                    .foregroundStyle(t.text3)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: Space.s1) {
                                    Text(record.label)
                                        .font(HermesFont.code)
                                        .foregroundStyle(t.text1)
                                        .lineLimit(1)
                                        .truncationMode(.head)
                                    Text(record.sessionTitle)
                                        .font(HermesFont.footnote)
                                        .foregroundStyle(t.text3)
                                        .lineLimit(1)
                                }
                            }
                        } trailing: {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(t.text4)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(record.label), from \(record.sessionTitle)")
                }
                footer
            }
            .padding(.bottom, Space.s10)
        }
    }

    private var footer: some View {
        Text("From your \(Self.sessionBudget) most recent sessions. Links open in an in-app browser so the session stays alive behind them.")
            .font(HermesFont.footnote)
            .foregroundStyle(t.text3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(Space.s6)
    }

    private func glyph(for kind: ArtifactScrape.Kind) -> String {
        switch kind {
        case .image: return "photo"
        case .file: return "doc"
        case .link: return "link"
        }
    }

    /// Files open in Quick Look, links in the in-app browser. Images split by
    /// *value*, not only by scraped kind, because `kind(of:)` labels any
    /// image-extension string as `.image`, including plain remote links.
    private func open(_ record: ArtifactScrape.Record) {
        switch record.kind {
        case .file:
            quickLookPath = record.value
        case .link:
            Task { if let url = await resolveURL(record) { safariURL = url } }
        case .image:
            if Self.isRemoteOrDataURL(record.value) {
                Task { if let url = await resolveURL(record) { safariURL = url } }
            } else {
                quickLookPath = record.value
            }
        }
    }

    // MARK: Resolution — gateway paths ride the media route (N8's route)

    /// Resolve a record to a URL the UI can render.
    ///
    /// - Absolute `http://` / `https://` values are remote links: return as-is.
    /// - `data:` values are already renderable (in-chat generated images).
    /// - Everything else is a gateway path: fetch an authenticated `data:` URL
    ///   via ``RestAPI/mediaDataURL(path:)``. Do **not** use ``downloadURL``,
    ///   which only appends a loopback query token and 401s on a gated backend
    ///   when handed to `SFSafariViewController`.
    private func resolveURL(_ record: ArtifactScrape.Record) async -> URL? {
        let value = record.value
        if Self.isRemoteOrDataURL(value) {
            return URL(string: value)
        }
        switch record.kind {
        case .link:
            return URL(string: value)
        case .image, .file:
            guard let rest = app.rest else { return nil }
            guard let dataURL = try? await rest.mediaDataURL(path: value) else { return nil }
            return URL(string: dataURL)
        }
    }

    private static func isRemoteOrDataURL(_ value: String) -> Bool {
        value.hasPrefix("http://") || value.hasPrefix("https://") || value.hasPrefix("data:")
    }

    // MARK: The scan

    private func scanIfNeeded() async {
        guard records.isEmpty, !isScanning else { return }
        await scan()
    }

    private func scan() async {
        guard let rest = app.rest else {
            loadError = "Not connected to a backend."
            return
        }
        isScanning = true
        defer { isScanning = false }
        loadError = nil

        let sessions = Array(app.threads.prefix(Self.sessionBudget))
        totalToScan = sessions.count
        scanned = 0
        var collected: [ArtifactScrape.Record] = []
        for session in sessions {
            defer { scanned += 1 }
            guard let page = try? await rest.getMessages(sessionID: session.id, limit: 500) else { continue }
            let messages = page.messages.map { message in
                ArtifactScrape.Message(
                    role: message.role.rawValue,
                    text: message.content.plainText,
                    toolCalls: .array(message.toolCalls.map { call in
                        var arguments: JSONValue = .string(call.argumentsJSON)
                        if let data = call.argumentsJSON.data(using: .utf8),
                           let parsed = try? JSONDecoder().decode(JSONValue.self, from: data) {
                            arguments = parsed
                        }
                        return .object(["name": .string(call.name), "arguments": arguments])
                    }),
                    timestamp: message.timestamp
                )
            }
            collected.append(contentsOf: ArtifactScrape.collect(
                sessionID: session.id,
                sessionTitle: session.displayTitle,
                messages: messages
            ))
        }
        records = collected
    }
}

/// The in-app browser: links open here so the session stays alive behind them.
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
