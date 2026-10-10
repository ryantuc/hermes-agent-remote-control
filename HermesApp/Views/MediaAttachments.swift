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
                    // A container iOS plays is fetched to the cache and drawn as a poster the tap plays; the rest of Desktop's video set (avi, mkv, webm) keeps the chip and Quick Look.
                    if VideoMedia.isPlayable(ref.path) {
                        VideoPosterView(ref: ref)
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

    /// Three sources, one decision, made by ``MediaDirective/fetchPlan(for:)``; bytes already held by ``MediaByteCache`` are used before any of them, and the downsample runs off the main actor so a row appearing mid-scroll costs the transcript nothing.
    private func load() async {
        let path = ref.path
        let rest = app.rest
        defer { retrying = false }
        let result = await Task.detached(priority: .userInitiated) { () async -> InlineThumbnail.Decoded? in
            let bytes: Data?
            if let held = MediaByteCache.shared.data(for: path) {
                bytes = held
            } else {
                switch MediaDirective.fetchPlan(for: path) {
                case .decodeDataURL:
                    bytes = DownsampledImage.data(fromDataURL: path)
                case .fetchRemote(let url):
                    bytes = try? await RemoteMedia.data(from: url)
                case .askGateway:
                    if let rest, let dataURL = try? await rest.mediaDataURL(path: path) {
                        bytes = DownsampledImage.data(fromDataURL: dataURL)
                    } else {
                        bytes = nil
                    }
                }
            }
            guard let bytes, let loaded = DownsampledImage.thumbnail(data: bytes) else { return nil }
            MediaByteCache.shared.remember(bytes, keys: [path])
            return InlineThumbnail.Decoded(image: loaded, data: bytes)
        }.value
        guard !Task.isCancelled else { return }
        guard let result else {
            failed = true
            return
        }
        encoded = result.data
        thumbnail = result.image
        failed = false
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
                .hermesTopBar()
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
            let data = try await MediaFileFetch.data(for: ref.path, gateway: MediaFileFetch.gateway(app.rest))
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
