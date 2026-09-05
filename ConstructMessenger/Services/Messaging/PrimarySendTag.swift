//
//  PrimarySendTag.swift
//  Construct Messenger
//
//  Naming the sending device on the ordinary send, the way the fan-out already does.
//

import Foundation

/// The wire id an ordinary send travels under.
///
/// ## Why the ordinary send needs one at all
///
/// `DeviceDeliveryPlan.wireId` marks and tags every **fan-out** copy, and `primarySendCovered` is
/// precisely what keeps the recipient's pinned device out of that fan-out — the ordinary send has
/// already reached it. So the pinned device, which receives most of the traffic and *all* of it
/// when the peer has one device, was the only target getting a bare UUID.
///
/// The consequence is not cosmetic. A session is a ratchet between two devices, so a recipient
/// choosing which session to decrypt with needs the sending device, and an untagged id names
/// nobody. The receive path then guessed by walking, and on a failure the core faithfully named
/// the session it had been fed — so a message from the peer's Desktop archived the session with
/// their iPhone. Measured 2026-09-03: 20 of 20 incoming messages attributed to the pinned device,
/// 0 to the other, 6 of 6 archives on the wrong one.
///
/// ## Why this is safe to change
///
/// The envelope id is not the message's identity. The recipient stores an incoming message under
/// the id in its **KNST frame**, inside the ciphertext (`saveMessage`, `e2eMessageId`), because the
/// server already reassigns envelope ids on the sealed-sender path. Receipts, edits and replies
/// all reference that inner id, so lengthening the outer one changes nothing they read.
///
/// ## What it does not do
///
/// Nothing here reaches the network. The target device and its identity key are the ones the
/// ciphertext was already encrypted for — `SessionAddressing` resolved them a moment earlier — so
/// tagging costs one X25519 and no bundle fetch.
enum PrimarySendTag {

    /// The key material the tag needs, as a seam.
    ///
    /// Production reads the Keychain and the pinned contact row. A test cannot: the identity
    /// private key lives in the Keychain and there is no key there under test, so `wireId` would
    /// take its untagged early return and any assertion about tagging would pass without
    /// exercising the tagging. That is not hypothetical — the first version of these tests built
    /// the wire id by hand and asserted the round trip, and the mutation `return baseMessageId`
    /// survived it untouched.
    struct Keys {
        var ourIdentityPrivate: () -> Data?
        var pinnedIdentityPublic: (String) -> Data?
        var pinnedDevice: (String) -> String?

        static let production = Keys(
            ourIdentityPrivate: { KeychainManager.shared.loadDeviceIdentityKey() },
            pinnedIdentityPublic: { SessionAddressing.pinnedIdentityKey(ofUser: $0) },
            pinnedDevice: { SessionAddressing.contactId(forPeer: $0) }
        )
    }

    nonisolated(unsafe) static var keys: Keys = .production

    /// The id to put on the envelope, given the id the message is known by locally.
    ///
    /// Returns `baseMessageId` unchanged whenever the copy cannot be attributed, and that is the
    /// ordinary answer rather than a failure: a first contact with no pinned key, a control message
    /// sent before any session, an unreadable Keychain. The receiver then falls back to the walk it
    /// used before, which is exactly today's behaviour.
    ///
    /// - Parameters:
    ///   - baseMessageId: the local id. Must not already carry a marker — a fan-out copy arrives
    ///     here fully formed and is returned untouched, because tagging it twice would put a second
    ///     marker in the id and `DeviceCopyWireId` reads the last one.
    ///   - recipientId: the account being written to.
    ///   - recipientDeviceId: the device the ciphertext was encrypted for, when the caller knows
    ///     it. Falls back to the peer's pinned device, which is what the ordinary encrypt used.
    static func wireId(
        baseMessageId: String,
        recipientId: String,
        recipientDeviceId: String? = nil
    ) -> String {
        guard DeviceCopyWireId.audience(of: baseMessageId) == nil else {
            return baseMessageId  // already a per-device copy — the fan-out built this one
        }
        guard !baseMessageId.isEmpty, !recipientId.isEmpty else { return baseMessageId }

        // Split a chunk suffix off before tagging, so the result is `<uuid>-fd-<tag>-c<n>` — the
        // one shape `DeviceDeliveryPlan.wireId` produces and `DeviceCopyWireId` documents. Tagging
        // `<uuid>-c1` whole would verify correctly but give every chunk a different tag, and the
        // invariant that all chunks of one message share it is what lets a receiver recompute from
        // whichever chunk arrives first.
        let (logicalId, chunkIndex) = Self.splitChunkSuffix(baseMessageId)

        let target = recipientDeviceId.flatMap { $0.isEmpty ? nil : $0 }
            ?? keys.pinnedDevice(recipientId)
        guard let target, !target.isEmpty,
              let peerKey = keys.pinnedIdentityPublic(recipientId), !peerKey.isEmpty,
              let ourKey = keys.ourIdentityPrivate(), !ourKey.isEmpty,
              let tag = SenderSyncDeviceTag.tag(
                  baseMessageId: logicalId,
                  targetDeviceId: target,
                  ourIdentityPrivateKey: ourKey,
                  peerIdentityPublicKey: peerKey
              )
        else { return baseMessageId }

        return DeviceDeliveryPlan.wireId(
            baseMessageId: logicalId,
            tag: tag,
            // A copy for someone else's device, which is what the ordinary send is. `-ss-` is for
            // our own replicas and only `MultiDeviceSendCoordinator` writes it.
            audience: .recipient,
            chunkIndex: chunkIndex ?? 0,
            // `wireId` appends the chunk suffix only when there is more than one, and we do not
            // know the count here — the presence of an index is the same statement.
            chunkCount: chunkIndex == nil ? 1 : chunkIndex! + 1
        )
    }

    /// `("<uuid>-c3", 3)` from `"<uuid>-c3"`, `("<uuid>", nil)` from `"<uuid>"`.
    ///
    /// `ChunkedMessageDelivery` numbers chunk 0 as the bare id and the rest `-c<n>`, so an id with
    /// no suffix is either a single-chunk message or the first chunk — and both want the tag
    /// computed over the same logical id, which is what makes them share it.
    static func splitChunkSuffix(_ id: String) -> (logicalId: String, chunkIndex: Int?) {
        guard let r = id.range(of: "-c", options: .backwards),
              let index = Int(id[r.upperBound...]), index > 0
        else { return (id, nil) }
        return (String(id[..<r.lowerBound]), index)
    }
}
