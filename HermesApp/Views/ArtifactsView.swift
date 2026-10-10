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
    /// What the last finished scan could not read, said beside the list so a partial result never passes for a whole one (BUG-089, BUG-107).
    @State private var shortfall = ArtifactScan.Shortfall()
    @State private var safariURL: URL?
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
        .hermesTopBar()
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
            StatePanel.loadFailure(title: "Couldn't scan sessions", error: loadError, hasBackend: app.rest != nil) {
                Task { await scan() }
            }
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
            VStack(alignment: .leading, spacing: Space.s5) {
                Text("Nothing here yet. Artifacts are the images, files and links the agent produced in your \(Self.sessionBudget) most recent sessions.")
                    .font(HermesFont.subhead)
                    .foregroundStyle(t.text3)
                    .fixedSize(horizontal: false, vertical: true)
                shortfallNote
            }
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
            ArtifactImageTile(record: record)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(record.label), from \(record.sessionTitle)")
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
        VStack(alignment: .leading, spacing: Space.s5) {
            shortfallNote
            Text("From your \(Self.sessionBudget) most recent sessions. Links open in an in-app browser so the session stays alive behind them.")
                .font(HermesFont.footnote)
                .foregroundStyle(t.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.s6)
    }

    /// The scan's shortfall in words, with a retry when a retry could help; nothing at all after a whole scan.
    @ViewBuilder
    private var shortfallNote: some View {
        if let note = ArtifactScan.note(for: shortfall, of: totalToScan) {
            VStack(alignment: .leading, spacing: Space.s4) {
                Text(note)
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.danger)
                    .fixedSize(horizontal: false, vertical: true)
                // A session too long to finish will be just as long next time; only an unread one is worth asking again.
                if shortfall.unread > 0 {
                    Button("Try again") { Task { await scan() } }
                        .buttonStyle(SecondaryButtonStyle())
                        .frame(maxWidth: 220)
                        .disabled(isScanning)
                }
            }
        }
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
        switch Self.destination(kind: record.kind, value: record.value) {
        case .quickLook(let path):
            quickLookPath = path
        case .browser:
            Task { if let url = await resolveURL(record), Self.isBrowsable(url) { safariURL = url } }
        }
    }

    /// `SFSafariViewController` takes http and https only and raises on any other scheme, so nothing else is handed to it.
    static func isBrowsable(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return scheme == "http" || scheme == "https"
    }

    /// Where a tapped record opens.
    enum Destination: Equatable {
        /// Quick Look, with the path or `data:` URL `MediaFileFetch` reads.
        case quickLook(String)
        /// The in-app browser, after `resolveURL`.
        case browser
    }

    /// The routing `open` follows, apart from the view so a test can read it.
    static func destination(kind: ArtifactScrape.Kind, value: String) -> Destination {
        // An inline `data:` image (the scrape accepts `data:image/`) would reach `SFSafariViewController`, which raises on any scheme but http and https (BUG-176). Quick Look decodes a `data:` URL locally (`MediaFileFetch.data(for:gateway:)`), so it previews there.
        if value.hasPrefix("data:") { return .quickLook(value) }
        switch kind {
        case .file:
            return .quickLook(value)
        case .link:
            return .browser
        case .image:
            return isRemoteOrDataURL(value) ? .browser : .quickLook(value)
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

        let sessions = app.threads.prefix(Self.sessionBudget).map {
            ArtifactScan.Session(id: $0.id, title: $0.displayTitle)
        }
        totalToScan = sessions.count
        scanned = 0
        let outcome = await ArtifactScan.run(
            sessions: sessions,
            loadPage: { sessionID, limit, offset in
                try await rest.getMessages(sessionID: sessionID, limit: limit, offset: offset)
            },
            progress: { scanned = $0 }
        )
        // Cancelled (the screen went away): publish nothing, so the next visit scans again instead of showing a fragment as the result.
        guard let outcome else { return }
        records = outcome.records
        shortfall = outcome.shortfall
        if !sessions.isEmpty, outcome.shortfall.unread == sessions.count {
            loadError = sessions.count == 1
                ? "Your most recent session couldn't be read."
                : "None of your \(sessions.count) most recent sessions could be read."
        }
    }
}

/// The Artifacts scan as a value, so a test can drive it with fixture pages instead of a view and a socket.
enum ArtifactScan {
    struct Session: Equatable, Sendable {
        let id: String
        let title: String
    }

    /// What a finished scan could not cover.
    struct Shortfall: Equatable {
        /// Sessions whose transcript could not be fetched, or stopped failing part-way.
        var unread = 0
        /// Sessions longer than ``pageCeiling`` pages, whose newest rows were never fetched.
        var truncated = 0

        var isEmpty: Bool { unread == 0 && truncated == 0 }
    }

    struct Outcome: Equatable {
        var records: [ArtifactScrape.Record]
        var shortfall: Shortfall
    }

    /// One page of one session's transcript: `GET /api/sessions/{id}/messages?limit=&offset=`.
    typealias PageLoader = (_ sessionID: String, _ limit: Int, _ offset: Int) async throws -> TranscriptPage

    /// The server's own cap: `sessions.py` clamps `limit` to 500.
    static let pageSize = 500
    /// A backstop, not a budget: 100 pages is 50,000 rows, past any real session; it exists so a server that ignores `offset` cannot keep a scan running forever.
    static let pageCeiling = 100

    /// `pageSize` and `pageCeiling` are parameters only so a test can reach the ceiling without building 50,000 rows. On the main actor because `progress` writes the screen's state.
    @MainActor
    static func run(
        sessions: [Session],
        pageSize: Int = ArtifactScan.pageSize,
        pageCeiling: Int = ArtifactScan.pageCeiling,
        loadPage: PageLoader,
        progress: (Int) -> Void = { _ in }
    ) async -> Outcome? {
        var collected: [ArtifactScrape.Record] = []
        var shortfall = Shortfall()
        for (index, session) in sessions.enumerated() {
            defer { progress(index + 1) }
            // The scrape dedupes within one call; across pages the same `session:value` id would otherwise reach `ForEach` twice. The first sighting is kept, as Desktop's `loadArtifactsForSessions` does.
            var seen = Set<String>()
            var offset = 0
            var pages = 0
            do {
                while true {
                    guard pages < pageCeiling else {
                        shortfall.truncated += 1
                        break
                    }
                    // An explicit limit pages from the OLDEST row (`sessions.py` `get_session_messages`), so the newest rows are on the last page and stopping after the first is BUG-107.
                    let page = try await loadPage(session.id, pageSize, offset)
                    pages += 1
                    let found = ArtifactScrape.collect(
                        sessionID: session.id,
                        sessionTitle: session.title,
                        messages: scrapeMessages(page.messages)
                    )
                    collected.append(contentsOf: found.filter { seen.insert($0.id).inserted })
                    // A short or empty page is the end. So is one longer than asked for: a backend that predates paging returns the whole transcript and ignores `offset`.
                    guard page.mayHaveMore, page.returned > 0, page.returned <= pageSize else { break }
                    offset += page.returned
                }
            } catch {
                if error is CancellationError || Task.isCancelled { return nil }
                // Counted, not dropped: a skipped session is what made a partial list read as a whole one (BUG-089). Rows from its pages that did load are kept.
                shortfall.unread += 1
            }
            if Task.isCancelled { return nil }
        }
        return Outcome(records: collected, shortfall: shortfall)
    }

    /// What the screen says about a shortfall, beside the list; nil when the scan read everything it set out to.
    static func note(for shortfall: Shortfall, of total: Int) -> String? {
        var sentences: [String] = []
        if shortfall.unread > 0 {
            sentences.append("\(shortfall.unread) of \(total) sessions couldn't be read, so this list may be missing what they produced.")
        }
        if shortfall.truncated > 0 {
            // The copy is English, so the number is grouped the English way whatever the region.
            let rows = (pageSize * pageCeiling).formatted(.number.locale(Locale(identifier: "en_US")))
            sentences.append(shortfall.truncated == 1
                ? "1 session is longer than \(rows) messages; only its first \(rows) were scanned."
                : "\(shortfall.truncated) sessions are longer than \(rows) messages; only their first \(rows) were scanned.")
        }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }

    /// The slice of each transcript row the scrape reads, with each tool call's arguments parsed back into JSON so key hints can match them.
    static func scrapeMessages(_ messages: [TranscriptMessage]) -> [ArtifactScrape.Message] {
        messages.map { message in
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
    }
}

/// How an Images tile gets its bitmap: downsampled to the tile through ImageIO, never a full decode, because a 12 MP photo is about 48 MB as a bitmap and under 1 MB at the tile's budget (BUG-075 C). Not on the main actor, so the async work below runs off it.
enum ArtifactTile {
    /// Decoded tiles by record id. `NSCache` gives them back under memory pressure, which a `@State` dictionary of every tile ever scrolled past would not.
    static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    /// `data:image/…` to a tile-sized image; nil for anything that is not an image.
    static func image(fromDataURL string: String) -> UIImage? {
        guard let data = DownsampledImage.data(fromDataURL: string) else { return nil }
        return DownsampledImage.thumbnail(data: data, maxPixelSize: DownsampledImage.artifactTileMaxPixelSize)
    }

    /// A record's tile, wherever its bytes are: in the value itself, at a link the phone fetches directly (through ``RemoteMedia``'s cap, with none of this app's credentials), or on the gateway's media route. Decoded here, so the first draw does not decode on the main thread.
    static func thumbnail(for value: String, mediaDataURL: (@Sendable (String) async throws -> String)?) async -> UIImage? {
        let image: UIImage?
        switch MediaDirective.fetchPlan(for: value) {
        case .decodeDataURL:
            image = Self.image(fromDataURL: value)
        case .fetchRemote(let url):
            guard let bytes = try? await RemoteMedia.data(from: url) else { return nil }
            image = DownsampledImage.thumbnail(data: bytes, maxPixelSize: DownsampledImage.artifactTileMaxPixelSize)
        case .askGateway:
            guard let mediaDataURL, let dataURL = try? await mediaDataURL(value) else { return nil }
            image = Self.image(fromDataURL: dataURL)
        }
        return image?.preparingForDisplay() ?? image
    }

    /// How many tiles may fetch and decode at once.
    static let maxConcurrentLoads = 3

    /// Bounds ``cachedThumbnail(key:value:mediaDataURL:)``: each load holds a whole file (a remote one up to 32 MB) until it is decoded.
    private static let gate = TileLoadGate(limit: maxConcurrentLoads)

    /// A tile from ``cache``, else loaded and cached; nil when it cannot be had.
    /// The cache write comes before the caller looks at cancellation: a fling cancels a tile's task after its bytes have already arrived (kit requests run to completion, BUG-093), and throwing the decoded tile away made every pass fetch it again.
    static func cachedThumbnail(key: String, value: String, mediaDataURL: (@Sendable (String) async throws -> String)?) async -> UIImage? {
        if let cached = cache.object(forKey: key as NSString) { return cached }
        await gate.acquire()
        // A tile scrolled away while it waited has fetched nothing yet, so it gives its turn up; another may have filled the cache meanwhile.
        if Task.isCancelled {
            await gate.release()
            return cache.object(forKey: key as NSString)
        }
        if let cached = cache.object(forKey: key as NSString) {
            await gate.release()
            return cached
        }
        let loaded = await thumbnail(for: value, mediaDataURL: mediaDataURL)
        await gate.release()
        guard let loaded else { return nil }
        cache.setObject(loaded, forKey: key as NSString, cost: cost(of: loaded))
        return loaded
    }

    /// What a tile costs to keep, for ``cache``.
    static func cost(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
    }
}

/// At most `limit` tile loads at a time; the rest wait their turn in arrival order.
actor TileLoadGate {
    private let limit: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func acquire() async {
        if running < limit {
            running += 1
            return
        }
        // `release` hands its place straight to the waiter, so `running` is not touched here.
        await withCheckedContinuation { continuation in
            waiting.append(continuation)
        }
    }

    func release() {
        if waiting.isEmpty {
            running -= 1
        } else {
            waiting.removeFirst().resume()
        }
    }
}

/// One Images tile. Its bitmap is decoded once, off the main thread, into this view's state rather than in `body`, and let go when the tile scrolls away; coming back is a cache hit.
@MainActor
private struct ArtifactImageTile: View {
    @Environment(\.hermes) private var t
    @Environment(AppModel.self) private var app

    let record: ArtifactScrape.Record

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(t.surface2)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if failed {
                Image(systemName: "photo")
                    .foregroundStyle(t.text4)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(minHeight: 104)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        // Plain `.task`, not `.task(id:)`: the grid already identifies the tile by record, and a data: record's id is the whole payload, too long to compare on every pass.
        .task { await load() }
        .onDisappear { image = nil }
    }

    private func load() async {
        let mediaDataURL: (@Sendable (String) async throws -> String)?
        if let rest = app.rest {
            mediaDataURL = { path in try await rest.mediaDataURL(path: path) }
        } else {
            mediaDataURL = nil
        }
        let loaded = await ArtifactTile.cachedThumbnail(key: record.id, value: record.value, mediaDataURL: mediaDataURL)
        // Scrolled away mid-load: the next appearance asks again, so a cancellation is not a failure.
        guard !Task.isCancelled else { return }
        guard let loaded else {
            failed = true
            return
        }
        image = loaded
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
