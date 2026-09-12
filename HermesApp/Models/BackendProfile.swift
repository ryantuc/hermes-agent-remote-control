import Foundation
import HermesServeKit

/// One saved backend; no secrets live here, since every credential is a Keychain item keyed by `id.uuidString`.
struct BackendProfile: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var baseURLString: String
    var authMode: BackendAuthMode
    /// Auth provider name for password login; empty means "the only one".
    var providerName: String
    var username: String
    /// Optional `?profile=` scoping — a Hermes profile, meaning a separate `HERMES_HOME` and `state.db`, not an app profile.
    var hermesProfile: String
    /// Cached from the last successful `/api/status`, for display before a connection exists.
    var lastKnownVersion: String
    var lastConnected: Date?
    /// The user signed this backend out (BUG-119); held on the profile rather than derived from the Keychain because every surface that needs the answer is synchronous and the Keychain is behind an actor.
    var signedOut: Bool

    init(
        id: UUID = UUID(),
        name: String = "",
        baseURLString: String = "",
        authMode: BackendAuthMode = .auto,
        providerName: String = "",
        username: String = "",
        hermesProfile: String = "",
        lastKnownVersion: String = "",
        lastConnected: Date? = nil,
        signedOut: Bool = false
    ) {
        self.id = id
        self.name = name
        self.baseURLString = baseURLString
        self.authMode = authMode
        self.providerName = providerName
        self.username = username
        self.hermesProfile = hermesProfile
        self.lastKnownVersion = lastKnownVersion
        self.lastConnected = lastConnected
        self.signedOut = signedOut
    }

    /// Hand-written so a field added here cannot erase the user's backends: the synthesized decoder throws on a missing key, and `BackendProfileStore.load` decodes the whole array with `try?`.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        baseURLString = try container.decodeIfPresent(String.self, forKey: .baseURLString) ?? ""
        authMode = try container.decodeIfPresent(BackendAuthMode.self, forKey: .authMode) ?? .auto
        providerName = try container.decodeIfPresent(String.self, forKey: .providerName) ?? ""
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        hermesProfile = try container.decodeIfPresent(String.self, forKey: .hermesProfile) ?? ""
        lastKnownVersion = try container.decodeIfPresent(String.self, forKey: .lastKnownVersion) ?? ""
        lastConnected = try container.decodeIfPresent(Date.self, forKey: .lastConnected)
        signedOut = try container.decodeIfPresent(Bool.self, forKey: .signedOut) ?? false
    }

    var displayName: String {
        if !name.isEmpty { return name }
        if let configuration = try? makeConfiguration() { return configuration.displayHost }
        return "New backend"
    }

    func makeConfiguration() throws -> BackendConfiguration {
        BackendConfiguration(
            baseURL: try BackendConfiguration.normalizeBaseURL(baseURLString),
            authMode: authMode,
            providerName: providerName,
            username: username,
            profile: hermesProfile.isEmpty ? nil : hermesProfile
        )
    }

    var isUsable: Bool { (try? makeConfiguration()) != nil }

    /// A backend this app can actually open: its address parses and the user has not signed it out; the launch route and the first-run state read this and nothing else, so they cannot disagree.
    var isSignedIn: Bool { isUsable && !signedOut }
}

/// UserDefaults-backed profile list, deliberately not SwiftData: a handful of non-secret rows, with the backend authoritative for everything else.
enum BackendProfileStore {
    private static let key = "hermes.backendProfiles.v1"
    private static let activeKey = "hermes.activeBackendProfile.v1"

    static func load() -> [BackendProfile] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([BackendProfile].self, from: data)) ?? []
    }

    static func save(_ profiles: [BackendProfile]) {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func loadActiveID() -> UUID? {
        guard let raw = UserDefaults.standard.string(forKey: activeKey) else { return nil }
        return UUID(uuidString: raw)
    }

    static func saveActiveID(_ id: UUID?) {
        if let id {
            UserDefaults.standard.set(id.uuidString, forKey: activeKey)
        } else {
            UserDefaults.standard.removeObject(forKey: activeKey)
        }
    }
}
