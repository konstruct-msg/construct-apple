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
    /// The devices of an account that had a verdict and left it. Wiped with the marks.
    static func formerKey(_ accountId: String) -> String { keyFamily + "former.v1." + accountId }

    /// The devices of `accountId` the core may treat as trusted, or nil when that cannot be read.
    ///
    /// **Nil is not an empty list.** The core reads no trusted device as a first meeting and accepts
    /// everything offered, so a failed read must judge nothing rather than pass a rogue device.
    ///
    /// **For the same reason this is empty only for an account that never had a verdict.** With
    /// every judged device gone from the active set, what is left is unjudged, and a server could
    /// use a first meeting to pass it. The devices that left go to the core instead: nothing offered
    /// matches them, and a certificate from one cannot be checked once it is gone, so the alarm fires.
    ///
    /// An account with no rows keeps the answer it always had: the device its pinned key derives to.
    static func trusted(ofPeer accountId: String) -> [String]? {
        do {
            let keyValue = LocalRepositories.keyValue
            try seedIfDue(peerDevices: LocalRepositories.peerDevices, keyValue: keyValue)
            let rows = try LocalRepositories.peerDevices.devices(ofAccount: accountId)
            let marked = try rows.map(\.deviceId).filter { try keyValue.get(key($0)) != nil }
            if !marked.isEmpty { return marked }
            let former = try formerlyTrusted(ofPeer: accountId, keyValue: keyValue)
            if !former.isEmpty { return former }
            return rows.isEmpty ? SessionAddressing.deviceIds(ofPeer: accountId) : []
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

    /// These devices left the account. One that comes back is judged again, so each loses its mark;
    /// those that had one are kept, so the account cannot read as a first meeting again.
    static func retire(_ deviceIds: [String], ofPeer accountId: String) {
        let keyValue = LocalRepositories.keyValue
        do {
            let judged = try deviceIds.filter { try keyValue.get(key($0)) != nil }
            if !judged.isEmpty {
                let former = judged.sorted().joined(separator: "\n")
                try keyValue.put(formerKey(accountId), Data(former.utf8))
            }
            for deviceId in deviceIds {
                try keyValue.remove(key(deviceId))
            }
        } catch {
            // A device that keeps its mark reads as pinned if it comes back. Losing the mark and
            // not recording it would be a first meeting, so the marks go last.
            Log.error("PEER_DEVICE_JUDGED_RETIRE_FAIL for \(accountId.prefix(8))…: \(error)", category: "Crypto")
        }
    }

    private static func formerlyTrusted(ofPeer accountId: String, keyValue: any KeyValueStore) throws -> [String] {
        guard let stored = try keyValue.get(formerKey(accountId)) else { return [] }
        return String(decoding: stored, as: UTF8.self).split(separator: "\n").map(String.init)
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
