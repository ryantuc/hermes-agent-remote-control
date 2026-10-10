import SwiftUI
import UIKit

/// `UIImagePickerController` wrapper for the camera, because SwiftUI has no native camera capture in iOS 17 and `PhotosPicker` only reaches the library.
/// Requires `NSCameraUsageDescription`, which the generated Info.plist already declares.
@MainActor
struct CameraPicker: UIViewControllerRepresentable {
    /// Delivers JPEG bytes plus a filename the gateway will accept: it takes the format from the name's extension, so a `.jpg` name over JPEG data is the safe pairing.
    var onCapture: (Data, String) -> Void
    /// The line the sheet shows when a capture produced nothing it can send.
    var onFailure: (String) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        // The library is only a guard against presenting an unavailable camera, which raises; the sheet re-checks availability at the tap, and a library pick is named as one (BUG-146).
        controller.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        controller.allowsEditing = false
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, onFailure: onFailure, onFinish: { dismiss() })
    }

    /// The filename a picked image is sent under: `camera-` only for a real capture, so the library fallback does not pass off a stored photo as a fresh shot.
    nonisolated static func captureName(sourceType: UIImagePickerController.SourceType, at date: Date) -> String {
        let stem = sourceType == .camera ? "camera" : "photo"
        return "\(stem)-\(Int(date.timeIntervalSince1970)).jpg"
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onCapture: (Data, String) -> Void
        private let onFailure: (String) -> Void
        private let onFinish: () -> Void

        init(
            onCapture: @escaping (Data, String) -> Void,
            onFailure: @escaping (String) -> Void,
            onFinish: @escaping () -> Void
        ) {
            self.onCapture = onCapture
            self.onFailure = onFailure
            self.onFinish = onFinish
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage,
               let data = image.jpegData(compressionQuality: 0.85) {
                onCapture(data, CameraPicker.captureName(sourceType: picker.sourceType, at: Date()))
            } else {
                // BUG-080: no image, or a JPEG encode that failed under memory pressure, used to close the camera with nothing said and the shot gone.
                onFailure(AttachmentPick.cameraFailedMessage)
            }
            onFinish()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onFinish()
        }
    }
}

/// Camera availability, so the composer can hide the button on a simulator.
enum CameraAvailability {
    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }
}
