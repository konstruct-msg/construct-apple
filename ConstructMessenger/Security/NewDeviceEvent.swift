//
//  NewDeviceEvent.swift
//  Construct Messenger
//
//  When a peer's device is a security event. `decisions/a-new-device-is-the-security-event.md`
//

import Foundation

/// A device the contact's account did not have, after we had seen what it had.
///
/// A device id is the hash of its identity key (`derive_device_id`), and the core pins the hybrid
/// key of every device it has opened. So a server substituting a contact's key cannot show it as
/// the same device with a different key — only as **a device the account did not have**. That is
/// the event. It replaced comparing one pinned key per account with whichever device's key came
/// last, which a second device of the contact always failed.
///
/// "After we had seen what it had" is the server's `active_devices` list: the first contact
/// arrives one device at a time (an invite, a sender certificate) before any list, and the devices
/// of that first list are trust on first use, not events. Canon: Android
/// `PeerDeviceRegistry.isNewDeviceEvent`.
enum NewDeviceEvent {

    /// The devices of `incoming` that are an event: each one outside both the account's last
    /// listed set and the devices already pinned for it — none at all before the account's set
    /// has been listed once. Our own account is excluded where the event is raised
    /// (`KeyChangeUX.raise`), which is where "who am I" can be asked.
    static func events(
        incoming: [String],
        listed: Set<String>?,
        pinned: Set<String>
    ) -> [String] {
        guard let listed else { return [] }
        return incoming.filter { !listed.contains($0) && !pinned.contains($0) }
    }

    // MARK: - The account's device set as last listed

    /// Wiped with the account (`AccountWipeKeys`): the sets belong to its contacts.
    static let listedSetsKey = "construct.peerDeviceSets.listed.v1"

    /// The last `active_devices` the server gave for `accountId`, or nil if it never has.
    static func listedSet(ofPeer accountId: String, defaults: UserDefaults = .standard) -> Set<String>? {
        let sets = defaults.dictionary(forKey: listedSetsKey) as? [String: [String]] ?? [:]
        return sets[accountId.lowercased()].map(Set.init)
    }

    /// Replaced, not merged: a device that left the set and comes back is an event again.
    static func recordListedSet(_ deviceIds: [String], ofPeer accountId: String, defaults: UserDefaults = .standard) {
        guard !accountId.isEmpty, !deviceIds.isEmpty else { return }
        var sets = defaults.dictionary(forKey: listedSetsKey) as? [String: [String]] ?? [:]
        sets[accountId.lowercased()] = Array(Set(deviceIds)).sorted()
        defaults.set(sets, forKey: listedSetsKey)
    }
}
