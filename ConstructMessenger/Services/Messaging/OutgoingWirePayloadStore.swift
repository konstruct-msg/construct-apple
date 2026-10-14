import Foundation

/// Persists outgoing encrypted wire-payloads for safe retries.
///
/// Critical: retries must re-send the exact same encrypted payload bytes.
/// Re-encrypting advances Double Ratchet state and causes decryption failures on the peer.
///
/// A chunk is stored **with the device it was encrypted for**. One message is N ciphertexts, one
/// per recipient device, each bound to that device's ratchet and sealed to that device's key; a
/// retry that re-seals a chunk has to seal it to the same device, and the chunk id alone does not
/// say which — the tag in it is a MAC, unreadable by design. An entry written before 2026-09-22
/// carries no device; a retry then falls back to the recipient's pinned device, which is the only
/// device that path ever encrypted for.
final class OutgoingWirePayloadStore {
    static let shared = OutgoingWirePayloadStore()

    private let defaults = UserDefaults.standard
    private let entryTtl: TimeInterval = 24 * 60 * 60
    private let queue = DispatchQueue(label: "construct.OutgoingWirePayloadStore")

    private init() {}

    /// One stored ciphertext: the wire id it went out under, the bytes, and the device whose
    /// ratchet produced them (`nil` only for an entry from before devices were recorded).
    struct StoredChunk: Equatable {
        let chunkMessageId: String
        let wirePayload: Data
        let recipientDeviceId: String?
    }

    func saveChunk(baseMessageId: String, chunkMessageId: String, wirePayload: Data, recipientDeviceId: String?) {
        queue.sync {
            let baseKey = normalize(baseMessageId)
            let chunkKey = normalize(chunkMessageId)

            var entry = loadEntry(baseKey) ?? Entry(createdAt: Date().timeIntervalSince1970, chunks: [:])
            entry.chunks[chunkKey] = wirePayload
            if let recipientDeviceId, !recipientDeviceId.isEmpty {
                var devices = entry.devices ?? [:]
                devices[chunkKey] = recipientDeviceId
                entry.devices = devices
            }
            saveEntry(entry, baseKey: baseKey)
        }
    }

    /// Every stored chunk of a message, chunk index first and wire id second — a fixed order, so
    /// a retry re-sends the copies of one message device by device rather than in whatever order
    /// the dictionary hands back.
    func loadChunks(baseMessageId: String) -> [StoredChunk]? {
        queue.sync {
            let baseKey = normalize(baseMessageId)
            purgeIfExpired(baseKey: baseKey)
            guard let entry = loadEntry(baseKey) else { return nil }

            let sortedKeys = entry.chunks.keys.sorted(by: chunkSort)
            let decoded: [StoredChunk] = sortedKeys.compactMap { chunkId in
                guard let data = entry.chunks[chunkId] else { return nil }
                return StoredChunk(
                    chunkMessageId: chunkId,
                    wirePayload: data,
                    recipientDeviceId: entry.devices?[chunkId]
                )
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

    /// Deletes every stored payload past its TTL, across the whole keyspace.
    ///
    /// `purgeIfExpired` only ever ran for a key someone asked for by id, so a payload for a message
    /// that was never retried was never even looked at — the TTL existed but had no reader. Call
    /// this once at launch; it is the only thing that bounds this store.
    func sweepExpired() {
        queue.sync {
            let now = Date().timeIntervalSince1970
            let keys = defaults.dictionaryRepresentation().keys
                .filter { $0.hasPrefix(OutgoingWirePayloadRetention.keyPrefix) }
            guard !keys.isEmpty else { return }

            let entries: [(key: String, createdAt: TimeInterval?)] = keys.map { key in
                guard let data = defaults.data(forKey: key),
                      let entry = try? JSONDecoder().decode(Entry.self, from: data) else {
                    return (key, nil)
                }
                return (key, entry.createdAt)
            }

            let expired = OutgoingWirePayloadRetention.expiredKeys(
                entries: entries, now: now, ttl: entryTtl
            )
            for key in expired { defaults.removeObject(forKey: key) }

            Log.info(
                "OutgoingWirePayloadStore sweep: \(expired.count) expired of \(keys.count) stored",
                category: "Messaging"
            )
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
        var chunks: [String: Data] // chunkMessageId -> wirePayload
        /// chunkMessageId -> the device the chunk was encrypted for. Optional so an entry written
        /// before the field existed still decodes; its chunks then read as device-less.
        var devices: [String: String]?
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
        "\(OutgoingWirePayloadRetention.keyPrefix)\(baseKey)"
    }

    private func normalize(_ id: String) -> String {
        id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func chunkSort(_ a: String, _ b: String) -> Bool {
        let (ia, ib) = (chunkIndex(of: a), chunkIndex(of: b))
        return ia == ib ? a < b : ia < ib
    }

    private func chunkIndex(of chunkId: String) -> Int {
        // base chunk has index 0; others are "<base>-cN"
        guard let range = chunkId.range(of: "-c", options: [.backwards]) else { return 0 }
        let suffix = chunkId[range.upperBound...]
        return Int(suffix) ?? 0
    }
}
