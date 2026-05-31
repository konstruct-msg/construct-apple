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
/// Stored in CFE binary format (MessagePack + header).
struct SessionArchive: Codable {
    let sessionData: Data
    let archivedAt: Date
    let reason: ArchiveReason

    func isExpired(retentionDays: Int) -> Bool {
        let expirationDate = Calendar.current.date(byAdding: .day, value: retentionDays, to: archivedAt) ?? Date()
        return Date() > expirationDate
    }
}
