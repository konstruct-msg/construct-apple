//
//  PeerDeviceJudgement.swift
//  Construct Messenger
//
//  Which of a contact's devices the core has given a verdict.
//
//  `PeerDevice` says a device was seen, which is what delivery needs. It was also read as "trusted",
//  and four paths write it without judging anything: a full answer with no hybrid key, a single
//  bundle fetch, a first message, a full answer while the core is down. A device that came in by any
//  of them read as `pinned` on the next answer and never raised the alarm, so a server could get a
//  device of its own past it (todo/268). One meaning, one carrier: this is the other meaning.
//
//  An invite's device is marked when it is pinned: its key is the root the rest is judged against.
//

import Foundation

enum PeerDeviceJudgement {

    /// One entry per judged device, wiped with the account (`AccountWipeKeys.wipedPrefixes`).
    static let keyFamily = "construct.peerDeviceJudged."
    /// Set once the rows that existed before this file were marked.
    static let seededKey = "construct.peerDeviceJudged.seeded.v1"

    private static func key(_ deviceId: String) -> String { keyFamily + "v1." + deviceId }

    /// The devices of `accountId` the core may treat as trusted, or nil when that cannot be read.
    ///
    /// **Nil is not an empty list.** The core reads no trusted device as a first meeting and accepts
    /// everything offered, so a failed read must judge nothing rather than pass a rogue device.
    ///
    /// An account with no rows keeps the answer it always had: the device its pinned key derives to.
    static func trusted(ofPeer accountId: String) -> [String]? {
        seedIfDue()
        do {
            let rows = try LocalRepositories.peerDevices.devices(ofAccount: accountId)
            guard !rows.isEmpty else { return SessionAddressing.deviceIds(ofPeer: accountId) }
            let keyValue = LocalRepositories.keyValue
            return try rows.map(\.deviceId).filter { try keyValue.get(key($0)) != nil }
        } catch {
            Log.error("PEER_DEVICE_JUDGED_READ_FAIL for \(accountId.prefix(8))…: \(error)", category: "Crypto")
            return nil
        }
    }

    /// The devices of `accountId` seen and not judged yet. Empty when that cannot be read: this only
    /// decides whether to ask the key server early, and the next full answer asks anyway.
    static func unjudged(ofPeer accountId: String) -> [String] {
        seedIfDue()
        do {
            let keyValue = LocalRepositories.keyValue
            return try LocalRepositories.peerDevices.devices(ofAccount: accountId)
                .map(\.deviceId)
                .filter { try keyValue.get(key($0)) == nil }
        } catch {
            Log.error("PEER_DEVICE_JUDGED_READ_FAIL for \(accountId.prefix(8))…: \(error)", category: "Crypto")
            return []
        }
    }

    static func mark(_ deviceIds: [String]) {
        let keyValue = LocalRepositories.keyValue
        for deviceId in deviceIds {
            do {
                try keyValue.put(key(deviceId), Data([1]))
            } catch {
                // Not marked is judged again on the next answer: the safe direction.
                Log.error("PEER_DEVICE_JUDGED_WRITE_FAIL \(deviceId.prefix(8))…: \(error)", category: "Crypto")
            }
        }
    }

    static func forget(_ deviceIds: [String]) {
        let keyValue = LocalRepositories.keyValue
        for deviceId in deviceIds {
            try? keyValue.remove(key(deviceId))
        }
    }

    /// Once per store: the rows from before this distinction count as judged. Left unmarked, an
    /// account would read as a first meeting after the update and accept anything offered with it.
    /// Runs before the first read and the first write, so no new row can be taken for an old one.
    static func seedIfDue() {
        do {
            try seedIfDue(peerDevices: LocalRepositories.peerDevices, keyValue: LocalRepositories.keyValue)
        } catch {
            Log.error("PEER_DEVICE_JUDGED_SEED_FAIL: \(error) — again on the next read", category: "Crypto")
        }
    }

    static func seedIfDue(peerDevices: any PeerDeviceStore, keyValue: any KeyValueStore) throws {
        guard try keyValue.get(seededKey) == nil else { return }
        for row in try peerDevices.allDevices() {
            try keyValue.put(key(row.deviceId), Data([1]))
        }
        try keyValue.put(seededKey, Data([1]))
    }
}
