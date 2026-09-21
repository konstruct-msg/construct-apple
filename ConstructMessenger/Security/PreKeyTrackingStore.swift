//
//  PreKeyTrackingStore.swift
//  Construct Messenger
//
//  The last signed pre-key seen from each **device**, so a bundle whose SPK differs from the one
//  before it can be read as "this device reinstalled or rotated" and its session put away.
//
//  Keyed by `CryptoDeviceId`, not by account, since 2026-09-21. It was keyed by account — one
//  slot — and the responder walk calls it once per candidate device with that device's bundle.
//  For a two-device peer the slot flipped between the two devices' SPKs on every walk (17 flips
//  in 20 walks on 2026-08-30; still firing on the 2026-09-21 stand: C read A's bundle after B's
//  and logged "potential reinstall detected"), and each flip archived the session
//  `contactId(forPeer:)` named — the pinned device's, which was the one healthy ratchet. An SPK
//  is a property of a device; a store that cannot say whose SPK it holds cannot say whether it
//  changed. See `decisions/a-peer-is-a-set-of-devices.md`, item 4.
//
//  The persisted dictionary is the same Keychain item. Entries written under an account id are
//  dropped on load rather than migrated: the account's one slot held whichever device's SPK was
//  seen last, which is not either device's history, and a device seen after the switch is simply
//  observed for the first time — the correct reading.
//

import Foundation

enum PreKeyTrackingResult: Equatable {
    case firstSeen
    case unchanged
    case changed(previous: String)
    /// The key was not a device id. Nothing was stored and nothing should be archived: an
    /// account-keyed observation is the defect this store exists to refuse.
    case refused
}

/// Where the dictionary lives. The Keychain in the app; memory in tests, which do not reach
/// the Keychain and should not have to.
protocol PreKeyTrackingPersistence {
    func loadTracked() -> Data?
    func saveTracked(_ data: Data) -> Bool
}

struct KeychainPreKeyTrackingPersistence: PreKeyTrackingPersistence {
    let storageKey: String
    func loadTracked() -> Data? {
        KeychainManager.shared.loadData(forKey: storageKey)
    }
    func saveTracked(_ data: Data) -> Bool {
        KeychainManager.shared.saveData(data, forKey: storageKey, accessible: KeychainManager.cryptoKeyAccessible)
    }
}

final class PreKeyTrackingStore {
    private let storageKey: String
    private let persistence: PreKeyTrackingPersistence
    private var tracked: [String: String] = [:]
    private let lock = NSLock()

    init(storageKey: String = "tracked_prekey_ids", persistence: PreKeyTrackingPersistence? = nil) {
        self.storageKey = storageKey
        self.persistence = persistence ?? KeychainPreKeyTrackingPersistence(storageKey: storageKey)
        load()
    }

    /// Record `preKeyId` as the SPK last seen from `deviceId`, and say how it compares to the
    /// one before. `deviceId` must be a `CryptoDeviceId`; callers hold the bundle the SPK came
    /// from, and `SessionAddressing.cryptoIdentity(ofIdentityKey:)` names the device from it.
    func track(preKeyId: String, forDevice deviceId: String) -> PreKeyTrackingResult {
        guard SessionAddressing.isCryptoIdentity(deviceId) else {
            Log.error(
                "PREKEY_TRACK_REFUSED: \(deviceId.prefix(8))… is not a device id — an SPK is a device's, not an account's",
                category: "PreKeyTracking"
            )
            return .refused
        }
        lock.lock()
        defer { lock.unlock() }
        let previous = tracked[deviceId]

        if previous == nil {
            tracked[deviceId] = preKeyId
            save()
            return .firstSeen
        }

        if previous != preKeyId {
            tracked[deviceId] = preKeyId
            save()
            return .changed(previous: previous ?? "")
        }

        return .unchanged
    }

    /// The devices with a recorded SPK. For tests and diagnostics.
    var trackedDeviceIds: [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(tracked.keys)
    }

    private func load() {
        // Primary: Keychain (encrypted social graph)
        if let data = persistence.loadTracked(),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            adopt(decoded)
            return
        }
        // Migration: if Keychain empty, check UserDefaults, then migrate and remove
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            adopt(decoded)
            save()  // writes to Keychain
            UserDefaults.standard.removeObject(forKey: storageKey)
        }
    }

    /// Keep the device-keyed entries; drop the account-keyed ones the pre-2026-09-21 store wrote.
    private func adopt(_ decoded: [String: String]) {
        tracked = decoded.filter { SessionAddressing.isCryptoIdentity($0.key) }
        let dropped = decoded.count - tracked.count
        if dropped > 0 {
            Log.info("PreKeyTracking: dropped \(dropped) account-keyed entr\(dropped == 1 ? "y" : "ies") — SPKs are tracked per device now", category: "PreKeyTracking")
            save()
        }
    }

    private func save() {
        if let encoded = try? JSONEncoder().encode(tracked) {
            if !persistence.saveTracked(encoded) {
                Log.error("PERSIST-FAIL prekey tracking state (\(encoded.count)B)", category: "PreKeyTracking")
            }
        }
    }
}
