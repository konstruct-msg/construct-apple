//
//  PeerDevice+CoreDataProperties.swift
//  Construct Messenger
//
//  One device of a peer's account.
//
//  ## Why this entity exists
//
//  A peer used to be one key. `User.knownIdentityKey` is a single `Data` slot per account, and
//  every store that held per-peer crypto state inherited that shape — the sealing key, the SPK
//  tracker, the KT verdict. Delivery, meanwhile, goes to N devices. With 1 on one side and N on
//  the other, exactly one device of a multi-device peer can be addressed correctly and the rest
//  are unreachable by construction: a Desktop linked 2026-08-30 failed to unseal 155 of 155
//  envelopes over five hours, because every one of them was sealed to the iPhone's identity key.
//
//  See `decisions/a-peer-is-a-set-of-devices.md`.
//
//  ## What it is not
//
//  **Not a trust root.** Rows come from the server's answer to `GetPreKeyBundles`, so a server
//  that adds a device to that answer is claiming the device belongs to the account. Persisting the
//  claim does not strengthen it — it is the same claim the send path already acts on. Closing that
//  needs cross-signed device sets (P3 in `identity-is-a-set-of-keys.md`).
//
//  **Not a second copy of `PeerDeviceRegistry`.** That is an hour-long in-memory cache of the last
//  server answer, and it answers "which devices does this account have right now". This is the
//  durable pin: it survives relaunch, answers during a locked-device background decrypt, and is
//  what a seal or a teardown may be addressed to. Two different questions — the registry is not
//  allowed to be the durable one, and this is not allowed to be refreshed per send.
//
//  `deviceId` is derived, never assigned: `SHA256(identityKey)[0..16]`. It is therefore a function
//  of `identityKey` and not a second carrier of it — two clients holding the same key compute the
//  same id, and there is nothing to keep in agreement.
//

import Foundation
import CoreData

extension PeerDevice {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<PeerDevice> {
        return NSFetchRequest<PeerDevice>(entityName: "PeerDevice")
    }

    /// `CryptoDeviceId` — 32 hex characters, `SHA256(identityKey)[0..16]`.
    @NSManaged public var deviceId: String

    /// `ServerUserId` of the account this device belongs to.
    @NSManaged public var accountId: String

    /// Raw X25519 identity public key. What a sealed envelope for this device is sealed to.
    @NSManaged public var identityKey: Data

    /// When this device was first recorded. The device set is ordered by it, oldest first, so the
    /// candidate walk keeps a stable order across runs — and so the device a single-device peer
    /// has always had stays first, which is the order the pinned key produced before this entity.
    @NSManaged public var firstSeenAt: Date
}

extension PeerDevice: Identifiable {}
