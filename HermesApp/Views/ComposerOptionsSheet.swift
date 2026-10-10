import AVFoundation
import CoreTransferable
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
    /// The camera closed without a photo the app could send (BUG-080).
    static let cameraFailedMessage = "That photo could not be prepared. Try taking it again."
    /// The Camera tile was tapped after the camera stopped being available.
    static let cameraUnavailableMessage = "The camera isn't available right now."

    /// A nil load writes `failedToLoadMessage` so both pickers can share
    /// the size-cap path's user-visible copy.
    static func note(data: Data?, into failure: inout String?) -> Data? {
        guard let data else {
            failure = failedToLoadMessage
            return nil
        }
        return data
    }

    /// What one picker arm produced: the payloads to queue, and the line the sheet shows when something did not make it.
    struct Outcome {
        var payloads: [AttachmentPayload] = []
        var failure: String?
    }

    /// One picked file read against a byte cap.
    enum CappedRead: Equatable {
        case loaded(Data)
        case tooLarge(bytes: Int)
        case unreadable
    }

    /// Reads `url` and holds the bytes to `limit`, refusing a file the file system already says is too big without reading any of it (BUG-079): a long 4K video used to be pulled whole into memory just to learn it was over the cap, and the app died before the refusal could show.
    static func readCapped(
        _ url: URL,
        limit: Int,
        read: (URL) throws -> Data = { try Data(contentsOf: $0) }
    ) -> CappedRead {
        if let size = byteSize(of: url), size > limit { return .tooLarge(bytes: size) }
        guard let data = try? read(url) else { return .unreadable }
        // A size the file system could not report, or under-reported, is still held to the cap once read.
        guard data.count <= limit else { return .tooLarge(bytes: data.count) }
        return .loaded(data)
    }

    /// The file's size from its metadata, without opening it.
    static func byteSize(of url: URL) -> Int? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .totalFileSizeKey])
        return values?.fileSize ?? values?.totalFileSize
    }

    /// The Files arm: one payload per readable file under the cap, and the last failure as the sheet's line.
    static func importFiles(
        _ result: Result<[URL], Error>,
        limit: Int,
        read: (URL) throws -> Data = { try Data(contentsOf: $0) }
    ) -> Outcome {
        var outcome = Outcome()
        let urls: [URL]
        switch result {
        case .success(let picked):
            urls = picked
        case .failure(let error):
            // BUG-080: this arm used to return with nothing on the sheet, indistinguishable from a cancel.
            if !isCancellation(error) { outcome.failure = failedToLoadMessage }
            return outcome
        }
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            switch readCapped(url, limit: limit, read: read) {
            case .unreadable:
                outcome.failure = failedToLoadMessage
            case .tooLarge(let bytes):
                outcome.failure = tooLargeMessage(bytes: bytes, limit: limit)
            case .loaded(let data):
                let type = UTType(filenameExtension: url.pathExtension)
                outcome.payloads.append(AttachmentAPI.preparedForUpload(AttachmentPayload(
                    data: data,
                    filename: url.lastPathComponent,
                    mimeType: type?.preferredMIMEType ?? "application/octet-stream"
                )))
            }
        }
        return outcome
    }

    /// Backing out of a picker is not a failure worth a line on the sheet.
    static func isCancellation(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError
    }

    /// The Photo arm once an item's bytes are in hand: name and MIME type come from the item's content type, and the extension is appended to `baseName`.
    static func photoPayload(data: Data, contentType: UTType?, baseName: String) -> AttachmentPayload {
        let isVideo = contentType?.conforms(to: .movie) ?? false
        let ext = contentType?.preferredFilenameExtension ?? (isVideo ? "mov" : "jpg")
        let mime = contentType?.preferredMIMEType ?? (isVideo ? "video/quicktime" : "image/jpeg")
        return AttachmentAPI.preparedForUpload(AttachmentPayload(
            data: data,
            filename: "\(baseName).\(ext)",
            mimeType: mime
        ))
    }

    static func tooLargeMessage(bytes: Int, limit: Int) -> String {
        AttachmentSize.tooLargeMessage(bytes: bytes, limit: limit)
    }
}

/// A video from the photo library, copied to a temporary file so its size can be read before any of it is in memory (BUG-079). The owner deletes `url` once it has read it.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            // `received.file` is only valid inside this closure.
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("picked-\(UUID().uuidString)")
                .appendingPathExtension(received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
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
                        // Availability was read when the tile was drawn; read it again at the tap and say so, rather than let CameraPicker open the library in the camera's place (BUG-146).
                        if CameraAvailability.isAvailable {
                            showingCamera = true
                        } else {
                            loadFailure = AttachmentPick.cameraUnavailableMessage
                        }
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
            Task { @MainActor in await importFiles(result) }
        }
        .fullScreenCover(isPresented: $showingCamera) {
            CameraPicker(
                onCapture: { data, filename in
                    model.addAttachment(data: data, filename: filename, mimeType: "image/jpeg")
                    dismiss()
                },
                // The camera closes itself; the sheet stays up with the line (BUG-080).
                onFailure: { message in loadFailure = message }
            )
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
            let type = item.supportedContentTypes.first
            let isVideo = type?.conforms(to: .movie) ?? false
            let data: Data
            if isVideo {
                switch await loadMovie(item) {
                case .loaded(let bytes):
                    data = bytes
                case .tooLarge(let bytes):
                    loadFailure = AttachmentPick.tooLargeMessage(bytes: bytes, limit: Self.fileByteLimit)
                    continue
                case .unreadable:
                    loadFailure = AttachmentPick.failedToLoadMessage
                    continue
                }
            } else {
                var failure = loadFailure
                guard let bytes = AttachmentPick.note(
                    data: try? await item.loadTransferable(type: Data.self),
                    into: &failure
                ) else {
                    loadFailure = failure
                    continue
                }
                // A photo has no file to measure first, but one over the cap is still refused before it is decoded for conversion or queued.
                guard bytes.count <= Self.fileByteLimit else {
                    loadFailure = AttachmentPick.tooLargeMessage(bytes: bytes.count, limit: Self.fileByteLimit)
                    continue
                }
                data = bytes
            }
            let stem = isVideo ? "video" : "photo"
            let baseName = "\(stem)-\(Int(Date().timeIntervalSince1970))-\(abs(item.hashValue % 1000))"
            // A HEIC is decoded and re-encoded here (BUG-077); keep that off the main actor.
            let payload = await Task.detached(priority: .userInitiated) {
                AttachmentPick.photoPayload(data: data, contentType: type, baseName: baseName)
            }.value
            model.addAttachment(data: payload.data, filename: payload.filename, mimeType: payload.mimeType)
            added = true
        }
        if added, loadFailure == nil { dismiss() }
    }

    /// BUG-079: a video arrives as a temporary file, so the cap is checked against its size before any of it is read. No in-memory fallback: a video that cannot come as a file says so rather than risking the old whole-file load.
    @MainActor
    private func loadMovie(_ item: PhotosPickerItem) async -> AttachmentPick.CappedRead {
        guard let movie = try? await item.loadTransferable(type: PickedMovie.self) else { return .unreadable }
        let limit = Self.fileByteLimit
        let read = await Task.detached(priority: .userInitiated) {
            AttachmentPick.readCapped(movie.url, limit: limit)
        }.value
        try? FileManager.default.removeItem(at: movie.url)
        return read
    }

    /// The Files arm reads and may convert each file, so it runs off the main actor behind the same spinner as the Photo arm.
    @MainActor
    private func importFiles(_ result: Result<[URL], Error>) async {
        isLoading = true
        defer { isLoading = false }
        let limit = Self.fileByteLimit
        let outcome = await Task.detached(priority: .userInitiated) {
            AttachmentPick.importFiles(result, limit: limit)
        }.value
        // Each pick gets its own verdict, as the Photo arm's does: an earlier pick's failure no longer holds the sheet open after a clean import.
        loadFailure = outcome.failure
        for payload in outcome.payloads {
            model.addAttachment(data: payload.data, filename: payload.filename, mimeType: payload.mimeType)
        }
        if !outcome.payloads.isEmpty, loadFailure == nil { dismiss() }
    }
}
