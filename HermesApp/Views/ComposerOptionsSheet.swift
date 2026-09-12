import AVFoundation
import HermesServeKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The `+` sheet: three fixed tiles — Photo, Camera, Files — and the
/// configurable quick-action zone beneath them.
///
/// Photo admits images *and* video: images go to `image.attach_bytes`, video
/// rides `file.attach` like a PDF, since the protocol has no video path.
enum AttachmentPick {
    static let failedToLoadMessage = "One of those attachments could not be loaded."

    /// A nil load writes `failedToLoadMessage` so both pickers can share
    /// the size-cap path's user-visible copy.
    static func note(data: Data?, into failure: inout String?) -> Data? {
        guard let data else {
            failure = failedToLoadMessage
            return nil
        }
        return data
    }
}

@MainActor
struct ComposerOptionsSheet: View {
    @Environment(\.hermes) private var t
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    let model: ChatModel
    /// The composer runs these after the sheet is gone (dismiss-then-present).
    let onQuickAction: (ComposerQuickAction) -> Void
    let onCustomise: () -> Void

    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showingPhotoPicker = false
    @State private var showingCamera = false
    @State private var showingFileImporter = false
    @State private var isLoading = false
    @State private var loadFailure: String?

    /// Contract v5 raised `ws_max_size` well past the old 16 MiB, but a
    /// one-shot base64 frame still has to be built in phone memory — this cap
    /// keeps the encode comfortably under pressure limits.
    static let fileByteLimit = 64 * 1024 * 1024

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Options")
                    .font(HermesFont.heading)
                    .foregroundStyle(t.text1)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(t.text3)
                        .frame(width: Hit.min, height: Hit.min)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            .padding(.leading, Space.s6)
            .padding(.trailing, Space.s3)
            .padding(.top, Space.s5)

            HStack(spacing: Space.s4) {
                tile("Photo", systemImage: "photo.on.rectangle") {
                    showingPhotoPicker = true
                }
                if CameraAvailability.isAvailable {
                    tile("Camera", systemImage: "camera") {
                        showingCamera = true
                    }
                }
                tile("Files", systemImage: "folder") {
                    showingFileImporter = true
                }
            }
            .padding(.horizontal, Space.s6)
            .padding(.top, Space.s5)

            if let loadFailure {
                Text(loadFailure)
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.danger)
                    .padding(.horizontal, Space.s6)
                    .padding(.top, Space.s4)
            }

            if isLoading {
                HStack(spacing: Space.s4) {
                    ProgressView().controlSize(.small)
                    Text("Preparing attachment…")
                        .font(HermesFont.footnote)
                        .foregroundStyle(t.text3)
                }
                .padding(.horizontal, Space.s6)
                .padding(.top, Space.s4)
            }

            quickActionZone

            Spacer(minLength: 0)
        }
        .background(t.surface)
        .presentationDetents([.height(quickActions.isEmpty ? 220 : 360), .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(Radius.sheet)
        .presentationBackground(t.surface)
        .photosPicker(
            isPresented: $showingPhotoPicker,
            selection: $photoItems,
            maxSelectionCount: 4,
            matching: .any(of: [.images, .videos])
        )
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            handleFileImport(result)
        }
        .fullScreenCover(isPresented: $showingCamera) {
            CameraPicker { data, filename in
                model.addAttachment(data: data, filename: filename, mimeType: "image/jpeg")
                dismiss()
            }
            .ignoresSafeArea()
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task { @MainActor in await loadPhotos(items) }
        }
    }

    private var quickActions: [ComposerQuickAction] { ComposerQuickAction.enabled }

    // MARK: Quick actions — the customisable zone (spec §4.1)

    @ViewBuilder
    private var quickActionZone: some View {
        if !quickActions.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    SectionHeader("Quick actions")
                    Spacer()
                    Button("Customise") {
                        dismiss()
                        onCustomise()
                    }
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.action)
                    .buttonStyle(.plain)
                    .padding(.trailing, Space.s6)
                }
                ForEach(quickActions) { action in
                    Button {
                        dismiss()
                        onQuickAction(action)
                    } label: {
                        FlatRow {
                            Text(action.label)
                                .font(HermesFont.callout)
                                .foregroundStyle(t.text1)
                        } trailing: {
                            HStack(spacing: Space.s3) {
                                Text(quickActionValue(action))
                                    .font(HermesFont.code)
                                    .foregroundStyle(t.text3)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                                    .frame(maxWidth: 170, alignment: .trailing)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(t.text4)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(action.label): \(quickActionValue(action))")
                }
            }
            .padding(.top, Space.s4)
        }
    }

    private func quickActionValue(_ action: ComposerQuickAction) -> String {
        switch action {
        case .workingDirectory:
            let path = model.isDraft
                ? (model.draftCwd ?? app.defaultCwd)
                : (model.info?.cwd ?? "")
            return (path as NSString).abbreviatingWithTildeInPath
        case .personality:
            let raw = app.settings.stringValue("display.personality") ?? ""
            return raw.isEmpty || raw == "none" ? "None" : raw.capitalized
        case .approvalMode:
            return (app.settings.stringValue("approvals.mode") ?? "").capitalized
        case .toolsets:
            return app.settings.stringListValue("toolsets")?.joined(separator: ", ") ?? ""
        case .profile:
            return app.activeProfile?.hermesProfile.isEmpty == false
                ? (app.activeProfile?.hermesProfile ?? "") : "Default"
        case .skills:
            return ""
        case .repositoryBranch:
            // The branch is the answer here, not the path — the path is what
            // the row above already says.
            return model.info?.branch ?? ""
        case .contextUsage:
            guard let usage = model.usage, usage.hasContext, let fraction = usage.contextFraction else { return "" }
            return "\(Int((fraction * 100).rounded()))%"
        }
    }
}

extension ComposerOptionsSheet {
    private func tile(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: Space.s3) {
                Image(systemName: systemImage)
                    .font(.system(size: 22))
                    .foregroundStyle(t.text1)
                Text(title)
                    .font(HermesFont.subhead)
                    .foregroundStyle(t.text2)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 78)
            .background(t.fill2, in: RoundedRectangle(cornerRadius: Radius.enclosure, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .accessibilityLabel(title)
    }

    // MARK: Loading

    @MainActor
    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        isLoading = true
        loadFailure = nil
        defer {
            isLoading = false
            photoItems = []
        }
        var added = false
        for item in items {
            var failure = loadFailure
            guard let data = AttachmentPick.note(
                data: try? await item.loadTransferable(type: Data.self),
                into: &failure
            ) else {
                loadFailure = failure
                continue
            }
            let type = item.supportedContentTypes.first
            let isVideo = type?.conforms(to: .movie) ?? false
            if isVideo, data.count > Self.fileByteLimit {
                loadFailure = tooLargeMessage(bytes: data.count)
                continue
            }
            let ext = type?.preferredFilenameExtension ?? (isVideo ? "mov" : "jpg")
            let mime = type?.preferredMIMEType ?? (isVideo ? "video/quicktime" : "image/jpeg")
            let stem = isVideo ? "video" : "photo"
            let name = "\(stem)-\(Int(Date().timeIntervalSince1970))-\(abs(item.hashValue % 1000)).\(ext)"
            model.addAttachment(data: data, filename: name, mimeType: mime)
            added = true
        }
        if added, loadFailure == nil { dismiss() }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        var added = false
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var failure = loadFailure
            guard let data = AttachmentPick.note(
                data: try? Data(contentsOf: url),
                into: &failure
            ) else {
                loadFailure = failure
                continue
            }
            guard data.count <= Self.fileByteLimit else {
                loadFailure = tooLargeMessage(bytes: data.count)
                continue
            }
            let type = UTType(filenameExtension: url.pathExtension)
            model.addAttachment(
                data: data,
                filename: url.lastPathComponent,
                mimeType: type?.preferredMIMEType ?? "application/octet-stream"
            )
            added = true
        }
        if added, loadFailure == nil { dismiss() }
    }

    private func tooLargeMessage(bytes: Int) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        let limit = ByteCountFormatter.string(fromByteCount: Int64(Self.fileByteLimit), countStyle: .file)
        return "That file is \(size); the upload cap is \(limit)."
    }
}
