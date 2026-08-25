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
/// **Not durable.** In memory, with the same hour-long TTL the own-device cache uses. A miss is
/// safe by construction: every consumer treats "we do not know this account's devices" as "cannot
/// decide", which is the answer that attempts the message rather than discarding it. Persistence
/// becomes necessary only when sessions are addressed per device and the registry has to survive
/// a relaunch to route an incoming message — at which point the session store itself carries the
/// same fact and should be the source, rather than this becoming a second one.
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

    /// Forget everything. Used when the account changes under us (link, recovery, sign-out), where
    /// keeping another account's device list would attribute its devices to the new one.
    func clear() {
        entries.removeAll()
    }
}
