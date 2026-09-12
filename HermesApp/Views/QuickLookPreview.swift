import HermesServeKit
import QuickLook
import SwiftUI
import UIKit

/// Quick Look for a file the gateway holds: fetch through the authenticated client to a temp file, preview it, remove it when the sheet goes away.
@MainActor
struct QuickLookSheet: View {
    @Environment(\.hermes) private var t
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    /// The path on the gateway.
    let path: String

    @State private var localURL: URL?
    @State private var failure: String?

    /// Through `MediaDirective`, not `HostPath` directly: a URL's `?v=2` would otherwise be part of the name.
    private var filename: String { MediaDirective.name(of: path) }

    var body: some View {
        Group {
            if let localURL {
                QuickLookPreview(url: localURL)
                    .ignoresSafeArea()
            } else {
                VStack(spacing: Space.s5) {
                    if let failure {
                        Text(failure)
                            .font(HermesFont.footnote)
                            .foregroundStyle(t.danger)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Close") { dismiss() }
                            .buttonStyle(PrimaryButtonStyle())
                    } else {
                        ProgressView()
                        Text("Fetching \(filename) from the host…")
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
        .task { await fetch() }
        .onDisappear {
            if let localURL { try? FileManager.default.removeItem(at: localURL) }
        }
    }

    private func fetch() async {
        guard localURL == nil, failure == nil else { return }
        do {
            // BUG-133: not every path here is the gateway's, and a link is fetched directly, with none of this app's credentials.
            let data: Data
            switch MediaDirective.fetchPlan(for: path) {
            case .fetchRemote(let url):
                data = try await RemoteMedia.data(from: url)
            case .decodeDataURL, .askGateway:
                guard let rest = app.rest else {
                    failure = "Not connected to a backend."
                    return
                }
                data = try await rest.downloadFileData(path: path)
            }
            // Keep the real filename: Quick Look picks its renderer from the extension, and a UUID with no suffix previews as nothing.
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("quicklook-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(filename.isEmpty ? "file" : filename)
            try data.write(to: destination)
            localURL = destination
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
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
