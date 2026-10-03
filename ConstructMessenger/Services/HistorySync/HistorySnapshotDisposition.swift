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

    /// The two account ids a transferred message names, as dashed strings.
    ///
    /// A row's stored `fromUserId` / `toUserId` is not always an account id — older rows carry
    /// something else (empty, or a device id). The wire field is 16 bytes, and the encoder used to
    /// leave an unparseable one out; the receiver then refused the record, and a refused record
    /// ends the whole phase (a real phone's first transfer died on exactly this: `from=0B`).
    /// A side that does not parse is the one the row's role names: ours for a sent row, the
    /// chat's peer for a received one. A value that does parse is kept as stored.
    static func participants(
        storedFrom: String,
        storedTo: String,
        isSentByMe: Bool,
        ownId: String,
        chatPeerId: String?
    ) -> (from: String?, to: String?) {
        func valid(_ id: String) -> String? { HistoryAccountID.raw(id) != nil ? id : nil }
        let from = valid(storedFrom) ?? (isSentByMe ? ownId : chatPeerId)
        let to = valid(storedTo) ?? (isSentByMe ? chatPeerId : ownId)
        return (from, to)
    }
}
