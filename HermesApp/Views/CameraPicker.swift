import SwiftUI
import UIKit

/// `UIImagePickerController` wrapper for the camera, because SwiftUI has no native camera capture in iOS 17 and `PhotosPicker` only reaches the library.
/// Requires `NSCameraUsageDescription`, which the generated Info.plist already declares.
@MainActor
struct CameraPicker: UIViewControllerRepresentable {
    /// Delivers JPEG bytes plus a filename the gateway will accept: it sniffs magic bytes, so a `.jpg` name over JPEG data is the safe pairing.
    var onCapture: (Data, String) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        controller.allowsEditing = false
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, onFinish: { dismiss() })
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onCapture: (Data, String) -> Void
        private let onFinish: () -> Void

        init(onCapture: @escaping (Data, String) -> Void, onFinish: @escaping () -> Void) {
            self.onCapture = onCapture
            self.onFinish = onFinish
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage,
               let data = image.jpegData(compressionQuality: 0.85) {
                let name = "camera-\(Int(Date().timeIntervalSince1970)).jpg"
                onCapture(data, name)
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
