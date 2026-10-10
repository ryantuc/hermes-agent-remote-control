import Foundation

/// The phone's durable record of which session is a given bot's forever-chat, plus the unread watermark and the last bot thread opened.
///
/// Everything here is keyed by `(backend profile id, hermes profile name)`, because a pin is a `state.db` session id and only means something on the machine that minted it.
///
/// The phone never writes the server-side pin (`ui_meta['hermes-bots'].chat`): that object is Desktop's, written whole, and a blind write from here would clobber what Desktop keeps beside the chat id.
struct BotChatPins: Sendable {
    /// `[<backendID>|<profile>: <stored session id>]`, one flat dictionary so a backend's whole pin set is one read.
    static let pinsKey = "hermes.bots.pins.v1"
    /// `[<backendID>|<profile>: <last_active seen>]` — the unread watermark.
    static let watermarksKey = "hermes.bots.unread.v1"
    /// `[<backendID>: <profile>]` — the last bot thread opened on that backend, persisted so a relaunch into Bots mode can restore it.
    static let lastThreadKey = "hermes.bots.lastThread"

    let defaults: UserDefaults

    static let standard = BotChatPins(defaults: .standard)

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: Key shape

    /// `"<backend profile id>|<hermes profile name>"`; a nil backend id collapses to an empty first component, which can never collide with a real UUID.
    static func key(backend: UUID?, profile: String) -> String {
        "\(backend?.uuidString ?? "")|\(profile)"
    }

    private static func prefix(backend: UUID?) -> String {
        "\(backend?.uuidString ?? "")|"
    }

    /// The bot profile name a composite key names, or nil when the key belongs to another backend.
    static func profile(fromKey key: String, backend: UUID?) -> String? {
        let prefix = Self.prefix(backend: backend)
        guard key.hasPrefix(prefix) else { return nil }
        return String(key.dropFirst(prefix.count))
    }

    // MARK: Pins

    func pin(backend: UUID?, profile: String) -> String? {
        let value = stringMap(Self.pinsKey)[Self.key(backend: backend, profile: profile)]
        return (value?.isEmpty == false) ? value : nil
    }

    /// Every pin this backend holds, keyed by profile name. Device-side only: no backend this client supports accepts them on the wire.
    func pins(backend: UUID?) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in stringMap(Self.pinsKey) {
            guard !value.isEmpty, let profile = Self.profile(fromKey: key, backend: backend) else { continue }
            out[profile] = value
        }
        return out
    }

    func setPin(_ storedSessionID: String, backend: UUID?, profile: String) {
        guard !storedSessionID.isEmpty else { return }
        var map = stringMap(Self.pinsKey)
        map[Self.key(backend: backend, profile: profile)] = storedSessionID
        defaults.set(map, forKey: Self.pinsKey)
    }

    func removePin(backend: UUID?, profile: String) {
        var map = stringMap(Self.pinsKey)
        map.removeValue(forKey: Self.key(backend: backend, profile: profile))
        defaults.set(map, forKey: Self.pinsKey)
    }

    // MARK: Unread watermarks

    func watermark(backend: UUID?, profile: String) -> Double? {
        doubleMap(Self.watermarksKey)[Self.key(backend: backend, profile: profile)]
    }

    func setWatermark(_ lastActive: Double, backend: UUID?, profile: String) {
        var map = doubleMap(Self.watermarksKey)
        map[Self.key(backend: backend, profile: profile)] = lastActive
        defaults.set(map, forKey: Self.watermarksKey)
    }

    // MARK: Last opened thread

    func lastOpened(backend: UUID?) -> String? {
        let value = stringMap(Self.lastThreadKey)[backend?.uuidString ?? ""]
        return (value?.isEmpty == false) ? value : nil
    }

    func setLastOpened(_ profile: String?, backend: UUID?) {
        var map = stringMap(Self.lastThreadKey)
        let key = backend?.uuidString ?? ""
        if let profile, !profile.isEmpty {
            map[key] = profile
        } else {
            map.removeValue(forKey: key)
        }
        defaults.set(map, forKey: Self.lastThreadKey)
    }

    // MARK: Test support

    /// Drop every value this store owns; tests only, since the app has no "forget all bots" action.
    func wipe() {
        defaults.removeObject(forKey: Self.pinsKey)
        defaults.removeObject(forKey: Self.watermarksKey)
        defaults.removeObject(forKey: Self.lastThreadKey)
    }

    // MARK: Reads

    private func stringMap(_ key: String) -> [String: String] {
        defaults.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    private func doubleMap(_ key: String) -> [String: Double] {
        guard let raw = defaults.dictionary(forKey: key) else { return [:] }
        var out: [String: Double] = [:]
        for (key, value) in raw {
            if let number = value as? Double { out[key] = number }
            else if let number = value as? NSNumber { out[key] = number.doubleValue }
        }
        return out
    }
}
