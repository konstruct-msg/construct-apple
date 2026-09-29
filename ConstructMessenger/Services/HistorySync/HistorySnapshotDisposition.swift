//
//  HistorySnapshotDisposition.swift
//  Construct Messenger
//
//  The importer's own policy: how a received record meets rows already in the store. The
//  protocol's rules — record order, phases, the manifest, discovery, the QR fingerprint — are the
//  core's (`construct-core/src/history/`) since 2026-09-29, and are not repeated here.
//

import Foundation

enum HistoryConflictPolicy: Equatable {
    case keepExisting
    case insert
}

/// A record the store cannot take: an id missing, a body that does not map. The stream itself was
/// judged by the core; these are this app's reasons.
enum HistorySnapshotError: Error, Equatable {
    case malformed
    case unsetBody
}

enum HistorySnapshotDisposition {
    static func messageConflict(existing: Bool) -> HistoryConflictPolicy {
        existing ? .keepExisting : .insert
    }

    /// Upsert key is the peer's account id. Chat.id is minted per device.
    static func chatUpsertKey(otherUserId: Data) -> Data {
        otherUserId
    }

    /// Share flags only go false→true. A profile-true on the receiver is not clobbered.
    static func contactShareFlag(snapshot: Bool, alreadyTrueOnReceiver: Bool) -> Bool {
        alreadyTrueOnReceiver || snapshot
    }

    /// Core derivation, not a second SHA-256. device_id is 32 lowercase hex.
    static func peerDeviceHintAcceptable(deviceId: String, identityKey: Data) -> Bool {
        let derived = deriveDeviceId(identityPublicKey: identityKey)
        return derived == deviceId.lowercased()
    }

    static func lowercaseMessageId(_ id: String) -> String {
        id.lowercased()
    }
}
