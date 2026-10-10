import CryptoKit
import Foundation
import HermesServeKit

/// A disposable, device-local recovery cache. The server's epoch and event replay, never this
/// file alone, authorize restoring it. No send or approval action is persisted here.
actor LiveTranscriptStore {
    struct Record: Codable, Sendable {
        let coverageVersion: Int
        let savedAt: Date
        let history: [ChatEntry]
        let ordinals: [String: Int]
        let turn: TurnCheckpoint

        init(savedAt: Date, history: [ChatEntry], ordinals: [String: Int], turn: TurnCheckpoint) {
            coverageVersion = 2
            self.savedAt = savedAt
            self.history = history
            self.ordinals = ordinals
            self.turn = turn
        }
    }

    static let shared = LiveTranscriptStore()
    private let root: URL
    private var latestWrite: [String: Date] = [:]
    private var purgedAt: [String: Date] = [:]
    private static let maxFileBytes = 8 * 1024 * 1024

    init(root: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LiveTranscripts-v1", isDirectory: true)) {
        self.root = root
    }

    private func url(_ key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(backendHash(key) + "-" + digest).appendingPathExtension("json")
    }

    private func backendHash(_ key: String) -> String {
        let backend = key.components(separatedBy: "\u{0}").first ?? key
        return SHA256.hash(data: Data(backend.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func removeBackend(_ id: UUID, at date: Date = Date()) {
        let prefix = backendHash(id.uuidString)
        purgedAt[prefix] = date
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix(prefix + "-") {
            try? FileManager.default.removeItem(at: file)
        }
    }

    func load(key: String) -> Record? {
        let file = url(key)
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= Self.maxFileBytes,
              let data = try? Data(contentsOf: file),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.coverageVersion == 2,
              Date().timeIntervalSince(record.savedAt) < 86_400 else { return nil }
        return record
    }

    func save(_ record: Record?, key: String, at date: Date) {
        guard date >= latestWrite[key, default: .distantPast] else { return }
        guard date > purgedAt[backendHash(key), default: .distantPast] else { return }
        latestWrite[key] = date
        let file = url(key)
        guard let record, let data = try? JSONEncoder().encode(record), data.count <= Self.maxFileBytes else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            #if os(iOS)
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: file, options: .atomic)
            #endif
            prune()
        } catch { /* Cache failure cannot interrupt a running conversation. */ }
    }

    private func prune() {
        let files = (try? FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
        let sorted = files.compactMap { file -> (URL, Date, Int)? in
            guard let v = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return nil }
            return (file, v.contentModificationDate ?? .distantPast, v.fileSize ?? 0)
        }.sorted { $0.1 > $1.1 }
        var bytes = 0
        for (index, item) in sorted.enumerated() {
            bytes += item.2
            if index >= 8 || bytes > 32 * 1024 * 1024 || Date().timeIntervalSince(item.1) >= 86_400 {
                try? FileManager.default.removeItem(at: item.0)
            }
        }
    }
}
