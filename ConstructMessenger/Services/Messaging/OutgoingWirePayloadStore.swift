import Foundation

/// Persists outgoing encrypted wire-payloads for safe retries.
///
/// Critical: retries must re-send the exact same encrypted payload bytes.
/// Re-encrypting advances Double Ratchet state and causes decryption failures on the peer.
final class OutgoingWirePayloadStore {
    static let shared = OutgoingWirePayloadStore()

    private let defaults = UserDefaults.standard
    private let entryTtl: TimeInterval = 24 * 60 * 60
    private let queue = DispatchQueue(label: "construct.OutgoingWirePayloadStore")

    private init() {}

    func saveChunk(baseMessageId: String, chunkMessageId: String, wirePayload: Data) {
        queue.sync {
            let baseKey = normalize(baseMessageId)
            let chunkKey = normalize(chunkMessageId)

            var entry = loadEntry(baseKey) ?? Entry(createdAt: Date().timeIntervalSince1970, chunks: [:])
            entry.chunks[chunkKey] = wirePayload.base64EncodedString()
            saveEntry(entry, baseKey: baseKey)
        }
    }

    /// Loads all chunks for a base message ID, sorted by chunk index.
    func loadChunks(baseMessageId: String) -> [(chunkMessageId: String, wirePayload: Data)]? {
        queue.sync {
            let baseKey = normalize(baseMessageId)
            purgeIfExpired(baseKey: baseKey)
            guard let entry = loadEntry(baseKey) else { return nil }

            let sortedKeys = entry.chunks.keys.sorted(by: chunkSort)
            let decoded: [(String, Data)] = sortedKeys.compactMap { chunkId in
                guard let b64 = entry.chunks[chunkId], let data = Data(base64Encoded: b64) else { return nil }
                return (chunkId, data)
            }
            return decoded.isEmpty ? nil : decoded
        }
    }

    func remove(baseMessageId: String) {
        queue.sync {
            let baseKey = normalize(baseMessageId)
            defaults.removeObject(forKey: key(baseKey))
        }
    }

    private func purgeIfExpired(baseKey: String) {
        guard let entry = loadEntry(baseKey) else { return }
        let createdAt = Date(timeIntervalSince1970: entry.createdAt)
        if Date().timeIntervalSince(createdAt) > entryTtl {
            defaults.removeObject(forKey: key(baseKey))
        }
    }

    // MARK: - Storage

    private struct Entry: Codable {
        var createdAt: TimeInterval
        var chunks: [String: String] // chunkMessageId -> base64(wirePayload)
    }

    private func loadEntry(_ baseKey: String) -> Entry? {
        guard let data = defaults.data(forKey: key(baseKey)) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    private func saveEntry(_ entry: Entry, baseKey: String) {
        if let data = try? JSONEncoder().encode(entry) {
            defaults.set(data, forKey: key(baseKey))
        }
    }

    private func key(_ baseKey: String) -> String {
        "construct.outgoingWirePayload.\(baseKey)"
    }

    private func normalize(_ id: String) -> String {
        id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func chunkSort(_ a: String, _ b: String) -> Bool {
        chunkIndex(of: a) < chunkIndex(of: b)
    }

    private func chunkIndex(of chunkId: String) -> Int {
        // base chunk has index 0; others are "<base>-cN"
        guard let range = chunkId.range(of: "-c", options: [.backwards]) else { return 0 }
        let suffix = chunkId[range.upperBound...]
        return Int(suffix) ?? 0
    }
}
