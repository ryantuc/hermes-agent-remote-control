import Foundation
import Security
#if targetEnvironment(simulator)
import os
#endif

/// Minimal Keychain wrapper for backend credentials; secrets live only here, never in UserDefaults,
/// logs, or diagnostics exports.
public struct KeychainStore: Sendable {
    public enum KeychainError: Error {
        case unexpectedStatus(OSStatus)
        case encodingFailed
    }

    public let service: String

    public init(service: String = "com.hermes.mobile.credentials") {
        self.service = service
    }

    public func setString(_ value: String, for account: String) throws {
        guard let data = value.data(using: .utf8) else { throw KeychainError.encodingFailed }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                #if targetEnvironment(simulator)
                if addStatus == errSecMissingEntitlement {
                    try SimulatorSecretFallback.shared.set(value, service: service, account: account)
                    return
                }
                #endif
                throw KeychainError.unexpectedStatus(addStatus)
            }
        } else {
            guard status == errSecSuccess else {
                #if targetEnvironment(simulator)
                if status == errSecMissingEntitlement {
                    try SimulatorSecretFallback.shared.set(value, service: service, account: account)
                    return
                }
                #endif
                throw KeychainError.unexpectedStatus(status)
            }
        }
    }

    public func string(for account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            #if targetEnvironment(simulator)
            if status == errSecMissingEntitlement {
                return SimulatorSecretFallback.shared.get(service: service, account: account)
            }
            #endif
            throw KeychainError.unexpectedStatus(status)
        }
        return String(data: data, encoding: .utf8)
    }

    public func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            #if targetEnvironment(simulator)
            if status == errSecMissingEntitlement {
                try SimulatorSecretFallback.shared.remove(service: service, account: account)
                return
            }
            #endif
            throw KeychainError.unexpectedStatus(status)
        }
    }

    #if targetEnvironment(simulator)
    /// Test seam: discard everything a process relaunch would discard, so a test can say "the old
    /// process is gone" without spawning a second one.
    public static func simulateProcessRelaunch() {
        SimulatorSecretFallback.resetProcessState()
    }
    #endif
}

#if targetEnvironment(simulator)
/// Stand-in secret store used only when the Simulator Keychain is unavailable.
/// Never compiled into a device build: an unsigned simulator app carries no keychain entitlements,
/// so `securityd` answers every `SecItem` call with `errSecMissingEntitlement`.
///
/// File-backed on purpose. A heap dictionary loses the secret across a relaunch while REST still
/// authenticates from its cookie, so the user reads "Sign in again" on a backend that otherwise
/// works — a store that stands in for the Keychain has to keep the Keychain's promise.
private final class SimulatorSecretFallback: @unchecked Sendable {
    private static let sharedLock = NSLock()
    private static var _shared = SimulatorSecretFallback()

    static var shared: SimulatorSecretFallback {
        sharedLock.lock(); defer { sharedLock.unlock() }
        return _shared
    }

    /// Replace the process-wide instance, dropping what it held in memory, as a relaunch does.
    static func resetProcessState() {
        sharedLock.lock(); defer { sharedLock.unlock() }
        _shared = SimulatorSecretFallback()
    }

    private static let warnOnce: Void = {
        os.Logger(subsystem: "com.hermes.mobile.diagnostics", category: "keychain")
            .warning("Keychain unavailable (errSecMissingEntitlement) — this simulator build is unsigned, so secrets are going to the simulator fallback file, not the Keychain.")
    }()

    private let lock = NSLock()
    private let fileURL: URL

    /// - Parameter directory: overridable so a test can point at a scratch location.
    init(directory: URL? = nil) {
        let base = directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("hermes-simulator-secrets.json")
        _ = Self.warnOnce
    }

    private func key(_ service: String, _ account: String) -> String { "\(service)\u{0}\(account)" }

    /// Read through to the file on every call. No in-memory copy means nothing
    /// that can go stale between instances, and nothing a relaunch can drop.
    private func load() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let items = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return items
    }

    private func store(_ items: [String: String]) throws {
        let data = try JSONEncoder().encode(items)
        try data.write(to: fileURL, options: [.atomic])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    func set(_ value: String, service: String, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        var items = load()
        items[key(service, account)] = value
        try store(items)
    }

    func get(service: String, account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return load()[key(service, account)]
    }

    func remove(service: String, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        var items = load()
        guard items.removeValue(forKey: key(service, account)) != nil else { return }
        try store(items)
    }
}
#endif
