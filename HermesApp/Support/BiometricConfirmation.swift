import Foundation
import LocalAuthentication

/// Optional Face ID / Touch ID gate for `choice: "always"`, which writes a pattern key into `config["command_allowlist"]` (reference-clients.md §5.2) rather than granting one command.
@MainActor
enum BiometricConfirmation {
    struct Availability {
        let isAvailable: Bool
        let displayName: String
    }

    static func availability() -> Availability {
        let context = LAContext()
        var error: NSError?
        let canEvaluate = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
        guard canEvaluate else { return Availability(isAvailable: false, displayName: "") }
        switch context.biometryType {
        case .faceID: return Availability(isAvailable: true, displayName: "Face ID")
        case .touchID: return Availability(isAvailable: true, displayName: "Touch ID")
        case .opticID: return Availability(isAvailable: true, displayName: "Optic ID")
        default: return Availability(isAvailable: true, displayName: "your passcode")
        }
    }

    /// True when the user confirmed, false when they cancelled or the device cannot evaluate; never throws, because a biometric failure must not block a deny.
    static func confirm(reason: String) async -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return false
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }
}
