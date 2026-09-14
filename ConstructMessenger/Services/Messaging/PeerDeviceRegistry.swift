//
//  PeerDeviceRegistry.swift
//  Construct Messenger
//
//  Which devices an account has, as far as this process has been told.
//

import Foundation

/// What we know locally about a peer's devices.
///
/// ## Why this exists
///
/// Until 2026-08-25 nothing here cached a peer's device list. Our own devices had a cache
/// (`MultiDeviceSendCoordinator.ownDeviceCache`) and a peer was represented by exactly one key —
/// `User.knownIdentityKey`, pinned at invite. That asymmetry decided a correctness question on the
/// receive path: a per-device copy from a peer whose tag did not reproduce for us could be either
/// "addressed to another of my devices" or "sent from a device of theirs I never pinned", and with
/// one key on hand the two are not separable. The safe answer was to attempt every such copy,
/// which means the tag bought nothing on that path — no way to skip the candidate walk, no way to
/// avoid the bundle fetch that a `messageNumber == 0` copy triggers.
///
/// With the device list the question is answerable: a tag that reproduces for none of the sender's
/// devices, when we know the sender's devices, is for another of ours.
///
/// ## What it is not
///
/// **Not a trust root.** The list comes from the server's answer to `GetPreKeyBundles`, and a
/// server that adds a device to it is claiming that device belongs to the account. This registry
/// does not make that better or worse — it is the same claim the send path already acts on — but
/// it must not be mistaken for evidence. Closing that needs cross-signed device sets; see
/// `decisions/identity-is-a-set-of-keys.md`.
///
/// **Durable answers come from the session store, not from here.** The in-memory map is an hour-long
/// cache of what the key server last said. Behind it sits the set of devices we actually hold
/// sessions with, read from the Keychain session namespace — which is the same fact, already on
/// disk, already surviving relaunch. Keeping a second list in agreement with it is the antipattern
/// this project keeps paying for, so there is no second list: `KeychainSessionAccounts` owns the
/// shape and both readers go through it.
///
/// The two answer slightly different questions and that is deliberate. The cache says "these are
/// the devices the account has"; the session store says "these are the devices we have talked to".
/// The second is a subset, it is what survives a restart, and it is the honest basis for deciding
/// that a copy belongs to a sibling — we can only conclude that about devices we know.
@MainActor
final class PeerDeviceRegistry {

    static let shared = PeerDeviceRegistry()
    private init() {}

    private struct Entry {
        let devices: [DeviceBundleData]
        let fetchedAt: Date
    }

    private var entries: [String: Entry] = [:]
    private let ttl: TimeInterval = 3600

    /// Record what the key server returned for `userId`.
    ///
    /// Called from the one place bundles are fetched, so every caller fills it without knowing it
    /// exists — a registry each caller has to remember to update is a registry that is stale for
    /// whichever path was added last.
    ///
    /// An empty list is **not** recorded: the server returns nothing for a user whose devices are
    /// momentarily unreadable as well as for one with none, and storing that would turn a
    /// transient failure into an hour of "we know this account has no devices".
    func record(userId: String, devices: [DeviceBundleData]) {
        guard !userId.isEmpty, !devices.isEmpty else { return }
        entries[userId] = Entry(devices: devices, fetchedAt: Date())
    }

    /// Devices of `userId` as far as this process knows — cache only, never a fetch.
    ///
    /// Must not go to the network: the caller is routing an incoming message and needs the answer
    /// now. Empty means "we do not know", never "there are none".
    func knownDevices(of userId: String) -> [DeviceBundleData] {
        guard let entry = entries[userId],
              Date().timeIntervalSince(entry.fetchedAt) < ttl else { return [] }
        return entry.devices
    }

    /// Identity public keys of `userId`'s devices — the other half of a copy tag's pair secret.
    func identityKeys(of userId: String) -> [Data] {
        knownDevices(of: userId).map(\.bundle.identityPublic)
    }

    /// Device ids of `userId` we hold a session with.
    ///
    /// ## What changed, and what it costs
    ///
    /// Until the addressing flip a session account was `session_<userId>:<deviceId>`, so this
    /// could be answered from the Keychain alone — durably, after a cold start, without a
    /// network fetch. A contact id is now the bare device id: the account no longer records
    /// whose device it is, and the store cannot attribute a session to an account by itself.
    ///
    /// So this intersects what the key server last told us with what we actually hold sessions
    /// for. Warm cache: the same answer as before. Cold cache: empty, which
    /// `deviceSetIsKnown(for:)` reports honestly as "we do not know" — the receive path then
    /// returns `.undecidable` and attempts the copy, which is the safe direction.
    ///
    /// Closing that gap is the remaining half of the flip: the account this device belongs to
    /// becomes a field of the session record, not part of its name. See
    /// `decisions/session-record-is-self-describing.md`.
    ///
    /// Sorted so the answer is stable: the Keychain returns items in no defined order, and a
    /// caller that walks candidates would otherwise try them differently on every launch, making
    /// a failure reproduce only sometimes.
    func sessionDeviceIds(of userId: String) -> [String] {
        let held = Set(
            KeychainManager.shared.sessionAccounts()
                .compactMap(KeychainSessionAccounts.contactId(ofAccount:))
        )
        return knownDevices(of: userId)
            .map(\.deviceId)
            .filter(held.contains)
            .sorted()
    }

    /// Whether we can claim to know this account's devices.
    ///
    /// True when either source has something to say. The consumer that concludes "this copy is for
    /// another device" needs this to be honest: claiming completeness we do not have turns a copy
    /// addressed to us into one we discard, silently.
    func deviceSetIsKnown(for userId: String) -> Bool {
        !knownDevices(of: userId).isEmpty || !sessionDeviceIds(of: userId).isEmpty
    }

    /// Forget everything. Used when the account changes under us (link, recovery, sign-out), where
    /// keeping another account's device list would attribute its devices to the new one.
    func clear() {
        entries.removeAll()
    }
}
