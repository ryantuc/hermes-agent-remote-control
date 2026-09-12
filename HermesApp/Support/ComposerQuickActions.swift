import Foundation

/// The `+` sheet's configurable quick-action zone; membership and order live in Settings → Chat → Composer actions.
enum ComposerQuickAction: String, CaseIterable, Identifiable {
    case workingDirectory
    case repositoryBranch
    case profile
    case personality
    case approvalMode
    case toolsets
    case skills
    case contextUsage

    var id: String { rawValue }

    var label: String {
        switch self {
        case .workingDirectory: return "Working directory"
        case .repositoryBranch: return "Repository & branch"
        case .profile: return "Profile"
        case .personality: return "Personality"
        case .approvalMode: return "Approval mode"
        case .toolsets: return "Toolsets"
        case .skills: return "Skills"
        case .contextUsage: return "Context usage"
        }
    }

    private static let key = "hermes.composer.quickActions"
    /// What a fresh install ticks; existing users have their order persisted under the same key, so this never migrates a ticked row out from under them.
    static let defaultEnabled: [ComposerQuickAction] = [.repositoryBranch]

    /// The enabled actions, in the user's order.
    static var enabled: [ComposerQuickAction] {
        get {
            guard let raw = UserDefaults.standard.stringArray(forKey: key) else {
                return defaultEnabled
            }
            return raw.compactMap(ComposerQuickAction.init(rawValue:))
        }
        set {
            UserDefaults.standard.set(newValue.map(\.rawValue), forKey: key)
        }
    }
}
