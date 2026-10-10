import AVKit
import HermesServeKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - What a full-screen viewer offers

/// The three things a viewer lets the user do with what it shows, in the order the row draws them. One set for images and videos, so the two viewers cannot drift.
enum MediaViewerAction: CaseIterable, Equatable {
    case copy
    case save
    case share

    var glyph: String {
        switch self {
        case .copy: return "doc.on.doc"
        case .save: return PhotoSave.State.idle.glyph
        case .share: return "square.and.arrow.up"
        }
    }

    func label(_ noun: String) -> String {
        switch self {
        case .copy: return "Copy \(noun)"
        case .save: return "Save \(noun) to Photos"
        case .share: return "Share \(noun)"
        }
    }
}

/// The viewer's control row: Close on the leading edge, then Copy, Save and Share on dark glass discs, forced dark because they float over the media and not over the skin.
struct MediaViewerControls<Share: View>: View {
    @Environment(\.hermes) private var t
    @Environment(\.dismiss) private var dismiss

    /// What the viewer shows, for the accessibility labels: "image" or "video".
    let noun: String
    let onCopy: () -> Void
    let onSave: () async -> PhotoSave.State
    @ViewBuilder let share: () -> Share

    @Binding var saveState: PhotoSave.State
    /// False while what the actions act on is still arriving; Close stays live.
    var actionsEnabled = true

    static var actions: [MediaViewerAction] { MediaViewerAction.allCases }

    var body: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Self.control("xmark", weight: .semibold)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")

            Spacer()

            GlassControlRow(spacing: Space.s4) {
                ForEach(Self.actions, id: \.self) { action in
                    switch action {
                    case .copy:
                        Button {
                            onCopy()
                            HapticFeedback.selection()
                        } label: {
                            Self.control(action.glyph)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(action.label(noun))
                    case .save:
                        // The glyph flips to a tick the moment the write lands and rolls back visibly to an exclamation if the grant is refused, never a silent no-op.
                        Button {
                            Task { saveState = await onSave() }
                        } label: {
                            Self.control(saveState.glyph, color: saveState == .failed ? t.danger : .white)
                        }
                        .buttonStyle(.plain)
                        .disabled(saveState == .saving)
                        .accessibilityLabel(saveState == .idle ? action.label(noun) : saveState.accessibilityLabel)
                    case .share:
                        share()
                            .accessibilityLabel(action.label(noun))
                    }
                }
            }
            .disabled(!actionsEnabled)
            .opacity(actionsEnabled ? 1 : 0.4)
        }
        .padding(.horizontal, Space.s4)
        .environment(\.colorScheme, .dark)
    }

    /// The dark tint the viewer's glass carries: the media, not the skin, is what these controls float over.
    static var controlTint: Color { Color.black.opacity(0.35) }

    /// One viewer control: a glyph on a 44 pt glass disc, the disc being the hit box.
    static func control(_ systemName: String, weight: Font.Weight = .regular, color: Color = .white) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 15, weight: weight))
            .foregroundStyle(color)
            .frame(width: Hit.min, height: Hit.min)
            .glassFloating(in: Circle(), tint: controlTint)
            .contentShape(Rectangle())
    }
}

// MARK: - The poster in the chat

/// A playable video where it was announced. Nothing is downloaded to draw it: the row shows a play disc with the filename and the size a HEAD states, and the clip is fetched only when the viewer opens. Once a clip is in the cache (an earlier play), the row draws its first frame and duration instead.
@MainActor
struct VideoPosterView: View {
    @Environment(\.hermes) private var t
    @Environment(AppModel.self) private var app

    let ref: MediaDirective.Ref
    /// The poster's longest side in points; the transcript thumbnails are 240.
    var maxSide: CGFloat = 240

    @State private var state: LoadState = .probing
    @State private var refreshToken = 0
    @State private var playing: PlayablePath?

    enum LoadState: Equatable {
        case probing
        case idle(bytes: Int64?)
        case ready(VideoMedia.Poster, URL)
        case failed(String, retryable: Bool)

        static func == (lhs: LoadState, rhs: LoadState) -> Bool {
            switch (lhs, rhs) {
            case (.probing, .probing): return true
            case (.idle(let a), .idle(let b)): return a == b
            case (.ready(_, let a), .ready(_, let b)): return a == b
            case (.failed(let a, let ra), .failed(let b, let rb)): return a == b && ra == rb
            default: return false
            }
        }
    }

    struct PlayablePath: Identifiable {
        let path: String
        var id: String { path }
    }

    var body: some View {
        Group {
            switch state {
            case .ready(let poster, _):
                Button {
                    playing = PlayablePath(path: ref.path)
                } label: {
                    posterImage(poster)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityLabel(duration: poster.duration))
                .accessibilityHint("Double tap to play.")
            case .probing, .idle:
                Button {
                    playing = PlayablePath(path: ref.path)
                } label: {
                    placeholderPoster
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityLabel(duration: nil))
                .accessibilityHint("Double tap to play.")
            case .failed(let reason, let retryable):
                Button {
                    refreshToken += 1
                    state = .probing
                } label: {
                    HStack(spacing: Space.s3) {
                        Image(systemName: retryable ? "arrow.clockwise" : "film")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(retryable ? t.action : t.text3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ref.name)
                                .font(HermesFont.footnote)
                                .foregroundStyle(t.text1)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Text(reason)
                                .font(HermesFont.footnote)
                                .foregroundStyle(t.text3)
                                .lineLimit(2)
                        }
                    }
                    .padding(.horizontal, Space.s5)
                    .padding(.vertical, Space.s3)
                    .frame(minHeight: Hit.min)
                    .background(t.surface2, in: RoundedRectangle(cornerRadius: Radius.enclosure, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.enclosure, style: .continuous).strokeBorder(t.stroke3, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(!retryable)
                .accessibilityLabel(retryable ? "Couldn't load video \(ref.name). \(reason) Double tap to retry." : "Video \(ref.name). \(reason)")
            }
        }
        .task(id: "\(ref.path)#\(refreshToken)") {
            guard case .probing = state else { return }
            await load()
        }
        .fullScreenCover(item: $playing, onDismiss: {
            // A clip the viewer finished fetching is in the cache now; draw its frame instead of the placeholder.
            if case .ready = state { return }
            if VideoMedia.cachedFile(for: ref.path) != nil {
                state = .probing
                refreshToken += 1
            }
        }) { item in
            VideoViewer(path: item.path, name: ref.name, gateway: VideoMedia.gateway(app.rest))
        }
    }

    private var sizeLabel: String? {
        guard case .idle(let bytes?) = state, bytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var placeholderPoster: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Radius.enclosure, style: .continuous)
                .fill(t.surface2)
            RoundedRectangle(cornerRadius: Radius.enclosure, style: .continuous)
                .strokeBorder(t.stroke3, lineWidth: 1)
            playDisc
        }
        .frame(width: maxSide, height: maxSide * 9 / 16)
        .overlay(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: 2) {
                Text(ref.name)
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.text1)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let sizeLabel {
                    Text(sizeLabel)
                        .font(HermesFont.footnote)
                        .hermesNumeric()
                        .foregroundStyle(t.text3)
                }
            }
            .padding(Space.s4)
        }
    }

    private var playDisc: some View {
        Image(systemName: "play.fill")
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: Hit.min + 8, height: Hit.min + 8)
            .glassFloating(in: Circle(), tint: MediaViewerControls<EmptyView>.controlTint)
            .environment(\.colorScheme, .dark)
    }

    private func posterImage(_ poster: VideoMedia.Poster) -> some View {
        Image(uiImage: poster.image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: maxSide, maxHeight: maxSide)
            .clipShape(RoundedRectangle(cornerRadius: Radius.enclosure, style: .continuous))
            .overlay { playDisc }
            .overlay(alignment: .bottomTrailing) {
                if let duration = poster.duration, let label = VideoMedia.durationLabel(duration) {
                    Text(label)
                        .font(HermesFont.footnote)
                        .hermesNumeric()
                        .foregroundStyle(.white)
                        .padding(.horizontal, Space.s3)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.55), in: Capsule())
                        .padding(Space.s3)
                }
            }
    }

    private func accessibilityLabel(duration: TimeInterval?) -> String {
        if let duration, let label = VideoMedia.durationLabel(duration) {
            return "Video: \(ref.name), \(label)."
        }
        if let sizeLabel {
            return "Video: \(ref.name), \(sizeLabel)."
        }
        return "Video: \(ref.name)."
    }

    /// A cached clip draws its frame (decoded off the main actor); otherwise a HEAD states the size. A refusal the HEAD carries is shown at once; a HEAD that could not reach the host leaves the placeholder, and the viewer reports the reason if the person taps.
    private func load() async {
        let path = ref.path
        if let file = VideoMedia.cachedFile(for: path),
           let poster = try? await Task.detached(priority: .userInitiated, operation: { try await VideoMedia.poster(for: path, file: file) }).value {
            guard !Task.isCancelled else { return }
            state = .ready(poster, file)
            return
        }
        do {
            let probe = try await VideoMedia.probe(for: path, gateway: VideoMedia.gateway(app.rest))
            guard !Task.isCancelled else { return }
            state = .idle(bytes: probe.bytes)
        } catch let failure as VideoMedia.Failure {
            guard !Task.isCancelled else { return }
            state = .failed(failure.errorDescription ?? "Couldn't load this video.", retryable: failure.isRetryable)
        } catch {
            guard !Task.isCancelled else { return }
            state = .idle(bytes: nil)
        }
    }
}

// MARK: - The full-screen player

/// The system player over black, with the image viewer's Close, Copy, Save and Share on the same glass discs. The clip is fetched when the viewer opens, through the shared transfer for its path, and the transfer stops if the viewer closes first. Copy puts the video itself on the pasteboard, Save adds it to Photos through the add-only grant, Share hands the file to the share sheet.
@MainActor
struct VideoViewer: View {
    @Environment(\.hermes) private var t

    let path: String
    let name: String
    let gateway: VideoMedia.Gateway?

    @State private var file: URL?
    @State private var failure: VideoMedia.Failure?
    @State private var otherFailure: String?
    @State private var attempt = 0
    @State private var player: AVPlayer?
    @State private var saveState: PhotoSave.State = .idle

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            } else if let reason = failure?.errorDescription ?? otherFailure {
                VStack(spacing: Space.s5) {
                    Text(reason)
                        .font(HermesFont.subhead)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    if failure?.isRetryable ?? true {
                        Button("Try Again") {
                            failure = nil
                            otherFailure = nil
                            attempt += 1
                        }
                        .font(HermesFont.calloutStrong)
                        .foregroundStyle(.white)
                        .frame(minHeight: Hit.min)
                    }
                }
                .padding(.horizontal, Space.s8)
            } else {
                VStack(spacing: Space.s4) {
                    ProgressView()
                        .tint(.white)
                    Text(name)
                        .font(HermesFont.footnote)
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, Space.s8)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Loading video \(name)")
            }
        }
        .overlay(alignment: .top) {
            MediaViewerControls(
                noun: "video",
                onCopy: { if let file { Self.copyToPasteboard(file) } },
                onSave: {
                    guard let file else { return .idle }
                    return await PhotoSave.saveVideo(at: file)
                },
                share: {
                    if let file {
                        ShareLink(item: file, preview: SharePreview(name)) {
                            MediaViewerControls<EmptyView>.control("square.and.arrow.up")
                        }
                    } else {
                        MediaViewerControls<EmptyView>.control("square.and.arrow.up")
                    }
                },
                saveState: $saveState,
                actionsEnabled: file != nil
            )
        }
        .overlay(alignment: .bottom) {
            if let note = saveState.note {
                Text(note)
                    .font(HermesFont.footnote)
                    .foregroundStyle(saveState == .failed ? t.danger : .white)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Space.s8)
                    .padding(.bottom, Space.s8 + 56)
                    .transition(.opacity)
            }
        }
        .animation(Motion.quick, value: saveState)
        .task(id: attempt) {
            await load()
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }

    /// The cache first; otherwise join or start the one transfer for this path. Closing the viewer cancels this task, which leaves the transfer and stops it when nothing else is waiting on it.
    private func load() async {
        guard file == nil else { return }
        let path = path
        let gateway = gateway
        do {
            let url: URL
            if let cached = VideoMedia.cachedFile(for: path) {
                url = cached
            } else {
                url = try await VideoDownloads.shared.file(for: path) { path in
                    try await VideoMedia.localFile(for: path, gateway: gateway)
                }
            }
            guard !Task.isCancelled else { return }
            file = url
            let player = AVPlayer(url: url)
            self.player = player
            player.play()
        } catch is CancellationError {
            return
        } catch let failure as VideoMedia.Failure {
            guard !Task.isCancelled else { return }
            self.failure = failure
        } catch {
            guard !Task.isCancelled else { return }
            otherFailure = (error as? LocalizedError)?.errorDescription ?? "Couldn't load this video."
        }
    }

    /// The file itself, as an item provider, so a 100 MB clip is not read into memory to be copied; the pasteboard reads it when something pastes.
    static func copyToPasteboard(_ file: URL) {
        guard let provider = NSItemProvider(contentsOf: file) else { return }
        UIPasteboard.general.setItemProviders([provider], localOnly: false, expirationDate: nil)
    }
}
