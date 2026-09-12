import Foundation

/// The client's own version, formatted in one place (FEAT-002).
enum AppVersion {
    /// `CFBundleShortVersionString` — the marketing version, set from `MARKETING_VERSION` in `project.yml`; the app and the Live Activity extension carry the same value because the extension will not embed otherwise.
    static var marketing: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// `CFBundleVersion` — the build number, stamped into the bundle on every build from `git rev-list --count HEAD` (FEAT-021), with `CURRENT_PROJECT_VERSION` in `project.yml` the fallback outside a git checkout.
    static var build: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    static var current: String { display(marketing: marketing, build: build) }

    static let unknown = "unknown"

    /// `1.0.0` + `12` → `1.0.0 (12)`; no build number drops the parentheses, no marketing version is `unknown`.
    static func display(marketing: String?, build: String?) -> String {
        guard let short = marketing, !short.isEmpty else { return unknown }
        guard let number = build, !number.isEmpty else { return short }
        return "\(short) (\(number))"
    }
}
