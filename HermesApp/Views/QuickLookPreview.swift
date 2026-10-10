import HermesServeKit
import Observation
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Quick Look for a file the gateway holds: fetch through the authenticated client to a temp file, preview it, remove it when the sheet goes away.
@MainActor
struct QuickLookSheet: View {
    @Environment(\.hermes) private var t
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    /// The path on the gateway.
    let path: String

    @State private var file: QuickLookFile

    init(path: String) {
        self.path = path
        _file = State(initialValue: QuickLookFile(path: path))
    }

    /// A sheet over a file the caller holds, so a test can watch its lifecycle.
    init(file: QuickLookFile) {
        self.path = file.path
        _file = State(initialValue: file)
    }

    var body: some View {
        // A `ZStack`, not a `Group`: a `Group` hands `.task` and `.onDisappear` to each branch, so the spinner leaving when the load landed ran `discard()`, deleted the file, and the spinner's return fetched it again, in a loop. The stack persists across the branch switch, so the two run once each, for the sheet.
        ZStack {
            if let localURL = file.localURL {
                QuickLookPreview(url: localURL)
                    .ignoresSafeArea()
            } else {
                VStack(spacing: Space.s5) {
                    if let failure = file.failure {
                        Text(failure)
                            .font(HermesFont.footnote)
                            .foregroundStyle(t.danger)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Try again") {
                            let gateway = MediaFileFetch.gateway(app.rest)
                            Task { await file.retry(gateway: gateway) }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        Button("Close") { dismiss() }
                            .buttonStyle(SecondaryButtonStyle())
                    } else {
                        ProgressView()
                        Text("Fetching \(file.filename) from the host…")
                            .font(HermesFont.footnote)
                            .foregroundStyle(t.text3)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(Space.s8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(t.canvas)
            }
        }
        .task { await file.load(gateway: MediaFileFetch.gateway(app.rest)) }
        .onDisappear { file.discard() }
    }
}

/// One preview's file on disk: fetched, written to a temporary directory of its own, and removed when the sheet goes. A class, so a test can drive the whole lifecycle without presenting a sheet.
@MainActor
@Observable
final class QuickLookFile {
    let path: String
    private(set) var localURL: URL?
    private(set) var failure: String?

    /// Worked out once: the sheet's body reads it on every pass, and for a data: URL the path can be megabytes.
    let filename: String

    /// The `quicklook-<UUID>` directory this preview wrote into. It holds only this preview's file, so removing it removes everything the preview left on disk.
    @ObservationIgnored private var directory: URL?
    /// Bumped by every ``discard()``. A fetch that finds it changed when its bytes arrive belongs to a sheet that has gone, and writes nothing.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loadingGeneration: Int?

    #if DEBUG
    /// How many times a fetched file was written to disk; one per sheet, unless something reloads it.
    @ObservationIgnored private(set) var writesForTesting = 0
    #endif

    init(path: String) {
        self.path = path
        self.filename = MediaFileFetch.filename(for: path)
    }

    func load(gateway: MediaFileFetch.Gateway?) async {
        guard localURL == nil, failure == nil, loadingGeneration != generation else { return }
        let mine = generation
        loadingGeneration = mine
        defer { if loadingGeneration == mine { loadingGeneration = nil } }
        do {
            let data = try await MediaFileFetch.data(for: path, gateway: gateway)
            // The sheet went while the bytes were on their way. Writing them now would leave a full copy of the document with nothing left to remove it (BUG-081).
            guard generation == mine else { return }
            // Keep the real filename: Quick Look picks its renderer from the extension, and a UUID with no suffix previews as nothing.
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("quicklook-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            do {
                let destination = directory.appendingPathComponent(filename.isEmpty ? "file" : filename)
                try data.write(to: destination)
                self.directory = directory
                localURL = destination
                #if DEBUG
                writesForTesting += 1
                #endif
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        } catch {
            // A fetch cancelled because the sheet went is not a failure to show anyone.
            guard generation == mine, !Task.isCancelled else { return }
            failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Fetch again after a failure. `load` refuses while a failure stands, which is what latched the sheet on its error with only Close to press (BUG-146).
    func retry(gateway: MediaFileFetch.Gateway?) async {
        guard failure != nil else { return }
        failure = nil
        await load(gateway: gateway)
    }

    /// The sheet has gone: remove the directory, not only the file in it (BUG-081), and disown any fetch still in flight. If the same sheet appears again, its `.task` fetches afresh.
    func discard() {
        generation += 1
        localURL = nil
        failure = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }
}

/// Where a previewed file's bytes come from, decided once by ``MediaDirective/fetchPlan(for:)`` and shared by Quick Look and the markdown previewer so the two cannot disagree.
enum MediaFileFetch {
    /// `GET /api/files/download` through the authenticated client; nil when no backend is connected.
    typealias Gateway = @Sendable (String) async throws -> Data

    enum Failure: LocalizedError, Equatable {
        case notConnected
        case undecodableDataURL

        var errorDescription: String? {
            switch self {
            case .notConnected:
                return "Not connected to a backend."
            case .undecodableDataURL:
                return "That file's data couldn't be decoded."
            }
        }
    }

    static func gateway(_ rest: RestAPI?) -> Gateway? {
        guard let rest else { return nil }
        return { path in try await rest.downloadFileData(path: path) }
    }

    static func data(for path: String, gateway: Gateway?) async throws -> Data {
        // BUG-133: not every path here is the gateway's, and a link is fetched directly, with none of this app's credentials.
        switch MediaDirective.fetchPlan(for: path) {
        case .fetchRemote(let url):
            return try await RemoteMedia.data(from: url)
        case .decodeDataURL:
            // The bytes are already in the string. Sent to the gateway they arrived as a filesystem path, the whole payload in a query parameter, a request that could only fail (BUG-146).
            guard let parsed = DataURL(path) else { throw Failure.undecodableDataURL }
            return parsed.data
        case .askGateway:
            guard let gateway else { throw Failure.notConnected }
            return try await gateway(path)
        }
    }

    /// The name Quick Look sees, and it picks its renderer from the extension. Through `MediaDirective`, not `HostPath` directly: a URL's `?v=2` would otherwise be part of the name. A data: URL has no name in it, only a media type, so it is named for that; its last path component is a run of base64.
    static func filename(for path: String) -> String {
        guard case .decodeDataURL = MediaDirective.fetchPlan(for: path) else {
            return MediaDirective.name(of: path)
        }
        guard let mediaType = DataURL.mediaType(of: path),
              let ext = UTType(mimeType: mediaType)?.preferredFilenameExtension
        else { return "file" }
        return "file.\(ext)"
    }
}

/// Thin `QLPreviewController` wrapper that carries no styling: Quick Look owns its own chrome.
private struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        context.coordinator.url = url
        controller.reloadData()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
