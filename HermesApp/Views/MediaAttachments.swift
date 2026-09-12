import AVKit
import HermesServeKit

import SwiftUI
import UIKit

/// What a reply delivered, drawn under the words that announced it: an image renders as a thumbnail, everything else as a chip naming the file that opens a previewer.
@MainActor
struct MediaAttachmentRow: View {
    @Environment(\.hermes) private var t

    let refs: [MediaDirective.Ref]
    /// Bot bubbles are narrow and leading-aligned inside their 86% cap; the session column is full width. Only the alignment differs.
    var alignment: HorizontalAlignment = .leading

    @State private var previewing: MediaDirective.Ref?

    var body: some View {
        VStack(alignment: alignment, spacing: Space.s3) {
            ForEach(refs) { ref in
                switch ref.kind {
                case .image:
                    AssistantMediaImage(ref: ref)
                case .video:
                    // A video the phone can reach itself plays inline, but one on the gateway's disk keeps the chip and goes to Quick Look, because authenticating `AVPlayer` would mean putting a token in a URL — Desktop plays it instead through a custom Electron protocol the phone has no equivalent of.
                    if case .fetchRemote(let url) = MediaDirective.fetchPlan(for: ref.path) {
                        AssistantMediaVideo(ref: ref, url: url)
                    } else {
                        fileChip(ref)
                    }
                case .audio, .markdown, .file:
                    fileChip(ref)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
        .sheet(item: $previewing) { ref in
            MediaPreviewSheet(ref: ref)
        }
    }

    /// A file, named and tappable: a chip rather than a link inside the prose, because the token is extracted out of the text before rendering and there is no run of characters left to make a link of.
    private func fileChip(_ ref: MediaDirective.Ref) -> some View {
        Button {
            previewing = ref
        } label: {
            HStack(spacing: Space.s3) {
                Image(systemName: Self.glyph(for: ref.kind))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(t.action)
                Text(ref.name)
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.text1)
                    .lineLimit(1)
                    // The identifying part of a filename is its start, and a generated report's name is long.
                    .truncationMode(.tail)
            }
            .padding(.horizontal, Space.s5)
            .frame(minHeight: Hit.min)
            .background(t.surface2, in: Capsule())
            .overlay(Capsule().strokeBorder(t.stroke3, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(Self.kindLabel(ref.kind)): \(ref.name). Double tap to open.")
    }

    static func glyph(for kind: MediaDirective.Kind) -> String {
        switch kind {
        case .image: return "photo"
        case .audio: return "waveform"
        case .video: return "film"
        case .markdown: return "doc.richtext"
        case .file: return "doc"
        }
    }

    /// Desktop labels these `Image:`, `Audio:`, `Video:`, `File:`; the phone shows the filename and says the kind to VoiceOver instead, so the chip spends its width on the part that identifies the file.
    static func kindLabel(_ kind: MediaDirective.Kind) -> String {
        switch kind {
        case .image: return "Image"
        case .audio: return "Audio"
        case .video: return "Video"
        case .markdown: return "Markdown document"
        case .file: return "File"
        }
    }
}

// MARK: - Images

/// An agent-generated image, resolved over the media route and shown inline.
/// The resolve is `RestAPI.mediaDataURL(path:)`, the authenticated route, never `downloadURL`, which would put a token in a URL.
@MainActor
private struct AssistantMediaImage: View {
    @Environment(\.hermes) private var t
    @Environment(AppModel.self) private var app

    let ref: MediaDirective.Ref

    @State private var thumbnail: UIImage?
    @State private var encoded: Data?
    @State private var failed = false
    /// True only while a retry is in flight, kept separate from the first load so the failure chip stays at its own size instead of collapsing back to the image-sized placeholder.
    @State private var retrying = false
    @State private var retryToken = 0
    @State private var viewing: Data?

    var body: some View {
        Group {
            if let thumbnail, let encoded {
                Button { viewing = encoded } label: {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 240, maxHeight: 240)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.enclosure, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Image: \(ref.name). Double tap to view full screen.")
            } else if failed {
                // BUG-133: never a broken-image glyph, and the chip holds its own size while it retries so the transcript does not jump to the placeholder and back.
                Button {
                    retrying = true
                    retryToken += 1
                } label: {
                    HStack(spacing: Space.s3) {
                        if retrying {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(t.action)
                        }
                        Text("Couldn't load \(ref.name)")
                            .font(HermesFont.footnote)
                            .foregroundStyle(t.text2)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .padding(.horizontal, Space.s5)
                    .frame(minHeight: Hit.min)
                    .background(t.surface2, in: Capsule())
                    .overlay(Capsule().strokeBorder(t.stroke3, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(retrying)
                .accessibilityLabel(
                    retrying
                        ? "Retrying \(ref.name)"
                        : "Couldn't load \(ref.name). Double tap to retry."
                )
            } else {
                RoundedRectangle(cornerRadius: Radius.enclosure, style: .continuous)
                    .fill(t.surface2)
                    .frame(width: 240, height: 150)
                    .accessibilityLabel("Loading image")
            }
        }
        .task(id: "\(ref.path)#\(retryToken)") {
            guard thumbnail == nil else { return }
            await load()
        }
        .fullScreenCover(isPresented: Binding(get: { viewing != nil }, set: { if !$0 { viewing = nil } })) {
            if let viewing { MediaViewer(data: viewing) }
        }
    }

    /// Three sources, one decision, made by ``MediaDirective/fetchPlan(for:)``.
    private func load() async {
        let bytes: Data?
        switch MediaDirective.fetchPlan(for: ref.path) {
        case .decodeDataURL:
            bytes = DownsampledImage.data(fromDataURL: ref.path)
        case .fetchRemote(let url):
            bytes = try? await RemoteMedia.data(from: url)
        case .askGateway:
            if let rest = app.rest, let dataURL = try? await rest.mediaDataURL(path: ref.path) {
                bytes = DownsampledImage.data(fromDataURL: dataURL)
            } else {
                bytes = nil
            }
        }

        defer { retrying = false }
        guard let bytes, let loaded = DownsampledImage.thumbnail(data: bytes) else {
            failed = true
            return
        }
        encoded = bytes
        thumbnail = loaded
        failed = false
    }
}

// MARK: - Video

/// An agent-generated video, played where it was announced.
/// Nothing is downloaded: `AVPlayer` streams the URL and handles its own ranges, which is why this does not go through ``RemoteMedia``.
/// The 16:9 box is a default, not a measurement, because `AVPlayer` reports the real ratio only after the asset loads.
@MainActor
private struct AssistantMediaVideo: View {
    let ref: MediaDirective.Ref
    let url: URL

    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .frame(maxWidth: 320)
            .clipShape(RoundedRectangle(cornerRadius: Radius.enclosure, style: .continuous))
            .onAppear {
                if player == nil { player = AVPlayer(url: url) }
            }
            .onDisappear {
                player?.pause()
                player = nil
            }
            .accessibilityLabel("Video: \(ref.name)")
    }
}

// MARK: - The previewer (FEAT-029)

/// What opens when a file chip is tapped.
/// Markdown is rendered with the transcript's own `MarkdownText` rather than dumped, because `QLPreviewController` shows a `.md` as monospaced source.
/// Everything else goes to Quick Look, which needs a file on disk, so the bytes are written to a temporary file and removed when the sheet goes.
@MainActor
struct MediaPreviewSheet: View {
    @Environment(\.hermes) private var t
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app

    let ref: MediaDirective.Ref

    @State private var state: LoadState = .loading

    enum LoadState {
        case loading
        case markdown(String)
        /// Hand off to `QuickLookSheet`, which does its own fetch.
        case quickLook
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(t.canvas)
                .navigationTitle(ref.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }.foregroundStyle(t.action)
                    }
                }
                .toolbarBackground(t.canvas, for: .navigationBar)
        }
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView()
        case .markdown(let text):
            ScrollView {
                MarkdownText(text: text)
                    .padding(.horizontal, Space.s6)
                    .padding(.vertical, Space.s5)
            }
        case .quickLook:
            // `QuickLookSheet` already does fetch → temp file → preview through the authenticated client, and works unchanged for a MEDIA path.
            QuickLookSheet(path: ref.path)
                .ignoresSafeArea(edges: .bottom)
        case .failed(let reason):
            VStack(spacing: Space.s4) {
                Text("Couldn't open \(ref.name)")
                    .font(HermesFont.callout)
                    .foregroundStyle(t.text1)
                Text(reason)
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.text3)
                    .multilineTextAlignment(.center)
            }
            .padding(Space.s6)
        }
    }

    /// Only markdown is fetched here; everything else is handed to `QuickLookSheet`, which fetches for itself, so a PDF's bytes are pulled once.
    private func load() async {
        guard ref.kind == .markdown else {
            state = .quickLook
            return
        }
        do {
            // BUG-133: a markdown document can be a link as easily as a gateway path, and a link is not the gateway's to serve.
            let data: Data
            switch MediaDirective.fetchPlan(for: ref.path) {
            case .fetchRemote(let url):
                data = try await RemoteMedia.data(from: url)
            case .decodeDataURL, .askGateway:
                guard let rest = app.rest else {
                    state = .failed("Not connected to a backend.")
                    return
                }
                data = try await rest.downloadFileData(path: ref.path)
            }
            // A file that will not decode as UTF-8 is not a markdown document whatever its extension claims, so it falls through to Quick Look rather than rendering mojibake.
            if let text = String(data: data, encoding: .utf8) {
                state = .markdown(text)
            } else {
                state = .quickLook
            }
        } catch {
            state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}
