//
//  SessionArchive.swift
//  Construct Messenger
//

import Foundation

/// Reason for archiving a session
enum ArchiveReason: String, Codable {
    case decryptionFailed    = "decryption_failed"
    case endSessionReceived  = "end_session_received"
    case manualReset         = "manual_reset"
    case preKeyChanged       = "prekey_changed"
    /// Remote peer re-keyed: messageNumber=0 arrived for an existing session.
    case remoteRekeying      = "remote_rekeying"
}

/// Archived session data for fallback decryption.
/// Stored in CFE binary format (MessagePack + header). Legacy archives written as
/// JSON strings are transparently read back via the migration initializer and fed
/// to `import_session`, which has a built-in `LegacyJson` fallback.
struct SessionArchive: Codable {
    let sessionData: Data  // CFE binary (new) or UTF-8 JSON bytes (legacy)
    let archivedAt: Date
    let reason: ArchiveReason

    init(sessionData: Data, archivedAt: Date, reason: ArchiveReason) {
        self.sessionData = sessionData
        self.archivedAt = archivedAt
        self.reason = reason
    }

    // MARK: Migration — read archives written with the old `sessionJson: String` field
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        archivedAt = try c.decode(Date.self, forKey: .archivedAt)
        reason     = try c.decode(ArchiveReason.self, forKey: .reason)
        if let data = try c.decodeIfPresent(Data.self, forKey: .sessionData) {
            sessionData = data
        } else if let json = try c.decodeIfPresent(String.self, forKey: .sessionJson) {
            // Old format: JSON string → store as UTF-8 bytes; importSession handles LegacyJson
            sessionData = Data(json.utf8)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: c.codingPath,
                                      debugDescription: "SessionArchive missing sessionData and sessionJson"))
        }
    }

    // Explicit Encodable: always write the new `sessionData` key
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sessionData, forKey: .sessionData)
        try c.encode(archivedAt,  forKey: .archivedAt)
        try c.encode(reason,      forKey: .reason)
    }

    private enum CodingKeys: String, CodingKey {
        case sessionData, sessionJson, archivedAt, reason
    }

    func isExpired(retentionDays: Int) -> Bool {
        let expirationDate = Calendar.current.date(byAdding: .day, value: retentionDays, to: archivedAt) ?? Date()
        return Date() > expirationDate
    }
}
