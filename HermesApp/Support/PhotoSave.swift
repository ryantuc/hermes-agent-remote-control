import Photos
import UIKit

/// Save an image to the camera roll via `PHAccessLevel.addOnly`, which grants writing one asset and no read access to the library; the picker's read grant stays a separate switch.
/// iOS offers no "limited" tier for add-only, so the answer is authorised or denied with nothing in between.
enum PhotoSave {
    enum State: Equatable {
        case idle
        case saving
        case saved
        case failed
        /// Refused at the system prompt — a different repair from a failure.
        case denied

        var glyph: String {
            switch self {
            case .idle: return "square.and.arrow.down"
            case .saving: return "ellipsis"
            case .saved: return "checkmark"
            case .failed, .denied: return "exclamationmark.triangle"
            }
        }

        var note: String? {
            switch self {
            case .idle, .saving: return nil
            case .saved: return "Saved to Photos."
            case .failed: return "Could not save to Photos."
            case .denied: return "Hermes cannot add to Photos. Turn it on in Settings › Hermes › Photos."
            }
        }

        var accessibilityLabel: String {
            switch self {
            case .idle: return "Save to Photos"
            case .saving: return "Saving to Photos"
            case .saved: return "Saved to Photos"
            case .failed: return "Could not save to Photos"
            case .denied: return "Photos access is off for Hermes"
            }
        }
    }

    @MainActor
    static func save(_ image: UIImage) async -> State {
        let status = await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { continuation.resume(returning: $0) }
        }
        guard status == .authorized || status == .limited else { return .denied }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }
            HapticFeedback.selection()
            return .saved
        } catch {
            return .failed
        }
    }
}
