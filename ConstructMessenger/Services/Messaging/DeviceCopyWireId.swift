//
//  DeviceCopyWireId.swift
//  Construct Messenger
//
//  Reading back the wire id `DeviceDeliveryPlan` writes, and deciding whether a copy is ours.
//
//  Renamed from `SenderSyncWireId` on 2026-08-25: it now reads both markers, and a name saying
//  "sender sync" over a function that also classifies copies from a peer is the kind of small lie
//  that costs an hour later.
//

import Foundation

/// What we can conclude about a per-device copy from its wire id alone.
///
/// Three-valued on purpose. The predicate this replaced returned `Bool` and collapsed "we know
/// this is for a sibling" into the same answer as "we have no way to tell" — behaviourally
/// correct, since both must lead to attempting the message, but it made the two indistinguishable
/// in logs and metrics. Whether the mechanism is working and whether it is merely never deciding
/// are different questions, and one carrier could not answer both.
enum DeviceCopyVerdict: Equatable {
    /// The tag reproduces for this device: the copy is addressed to us.
    case ours
    /// The tag is a valid one written for a different device of this account.
    case foreign
    /// Not a per-device copy, or nothing here can decide. Must be treated as ours — wrongly
    /// opening a copy costs failed decrypts, wrongly discarding one loses a message from the
    /// transcript, silently, which is the failure mode this feature already spent months in.
    case undecidable
}

/// Reading of the device-tag suffix `DeviceDeliveryPlan` puts on a per-device copy.
///
/// Delivery is not per device: `messaging-service/src/core.rs` writes the same envelope to every
/// one of the recipient's per-device streams. An account with three devices therefore receives, on
/// each of them, the two copies meant for the other two.
///
/// Recognising those costs one X25519 per candidate key. Without it each foreign copy walks the
/// whole candidate-session list, fails every decrypt, and — on a first message — reaches for a key
/// bundle over the network, all for a message that was never ours to read.
enum DeviceCopyWireId {

    /// The target device tag, or `nil` when the id names no per-device copy.
    ///
    /// Forms produced by the sender (see `DeviceDeliveryPlan.wireId`):
    ///
    ///     <uuid>-ss-<tag>          a copy for one of the sender's own devices
    ///     <uuid>-fd-<tag>          a copy for one of the recipient's devices
    ///     …-<tag>-c<n>             chunk n of many, either kind
    static func targetDeviceTag(of wireId: String) -> String? {
        guard let range = markerRange(in: wireId) else { return nil }
        let rest = wireId[range.upperBound...]
        // Cut the chunk suffix. `-c` cannot occur inside a tag: it is hex.
        let tag = rest.range(of: "-c", options: .backwards).map { String(rest[..<$0.lowerBound]) }
            ?? String(rest)
        return tag.isEmpty ? nil : tag
    }

    /// The id the tag was computed over: everything before the marker.
    ///
    /// The sender MACs this rather than the full wire id, so every chunk of one copy carries the
    /// same tag and the receiver can recompute it from whichever chunk it happens to see first.
    static func baseId(of wireId: String) -> String? {
        guard let range = markerRange(in: wireId) else { return nil }
        let base = String(wireId[..<range.lowerBound])
        return base.isEmpty ? nil : base
    }

    /// Whose copy this is, by the marker alone.
    static func audience(of wireId: String) -> DeviceDeliveryTarget.Audience? {
        guard let range = markerRange(in: wireId) else { return nil }
        return wireId[range] == DeviceDeliveryPlan.Marker.ownReplica ? .ownReplica : .recipient
    }

    /// The last marker in the id, whichever kind it is.
    ///
    /// Searched backwards because a message id is a UUID and cannot contain either marker, but a
    /// future id shape might; taking the last one keeps the tag the trailing field it is.
    private static func markerRange(in wireId: String) -> Range<String.Index>? {
        let candidates = [DeviceDeliveryPlan.Marker.ownReplica, DeviceDeliveryPlan.Marker.recipient]
            .compactMap { wireId.range(of: $0, options: .backwards) }
        return candidates.max { $0.lowerBound < $1.lowerBound }
    }

    /// Whether this copy is ours to open.
    ///
    /// `peerIdentityKeys` are the public identity keys of the devices that could have been the
    /// *other* end of the tag's pair secret; `ourIdentityPrivateKey` is our half; `ourDeviceId` is
    /// what the sender would have bound into the MAC had it been addressing us.
    ///
    /// ## Why the two kinds of copy get different conclusions
    ///
    /// For a copy from **one of our own devices** we hold every sibling's public key (the
    /// own-device cache), so a tag that reproduces for none of them is definitively for a sibling.
    /// Both conclusions are available.
    ///
    /// For a copy from **a peer** the same holds only when the caller actually knows that peer's
    /// devices — `peerDeviceSetIsComplete`. It passed `false` until 2026-08-25, because nothing
    /// cached a peer's device list and the only key on hand was `User.knownIdentityKey`, pinned at
    /// invite. A non-match then meant either "addressed to another of my devices" or "sent from a
    /// device of theirs I never pinned", and concluding `foreign` would have discarded our own
    /// message every time a multi-device peer wrote from an unpinned device. `PeerDeviceRegistry`
    /// now answers that question, and the flag is what carries the answer here rather than this
    /// function guessing from the size of the array it was handed — an empty list and a list we
    /// have no reason to trust look identical from in here.
    static func verdict(
        wireId: String,
        ourDeviceId: String?,
        ourIdentityPrivateKey: Data?,
        peerIdentityKeys: [Data],
        peerDeviceSetIsComplete: Bool
    ) -> DeviceCopyVerdict {
        guard let tag = targetDeviceTag(of: wireId),
              let base = baseId(of: wireId),
              let audience = audience(of: wireId) else {
            return .undecidable  // not a per-device copy — not ours to judge
        }

        switch tag.count {
        case SenderSyncDeviceTag.hexLength:
            guard let ourDeviceId, !ourDeviceId.isEmpty,
                  let ourIdentityPrivateKey, !peerIdentityKeys.isEmpty else { return .undecidable }

            // The target is bound into the MAC, so a copy we sent to another device does not match
            // here even though we share its pair secret.
            let isOurs = peerIdentityKeys.contains {
                SenderSyncDeviceTag.matches(
                    tag,
                    baseMessageId: base,
                    ourDeviceId: ourDeviceId,
                    ourIdentityPrivateKey: ourIdentityPrivateKey,
                    peerIdentityPublicKey: $0
                )
            }
            if isOurs { return .ours }
            // Own replicas: we hold every sibling's key, so a tag matching none of them is a
            // sibling's. Peer copies: only when the caller vouches that it knows their devices.
            let canConcludeForeign = audience == .ownReplica || peerDeviceSetIsComplete
            return canConcludeForeign ? .foreign : .undecidable

        case SenderSyncDeviceTag.legacyHexLength:
            // Sender at or below 0.18.0 wrote `deviceId.prefix(8)`. Prefix, not equality —
            // comparing a full device id against a truncated tag never matches, and every copy
            // including our own would be discarded as foreign.
            //
            // Removal condition: no builds at or below 0.18.0 left in the field. Until then
            // dropping this stops placing copies from a tester who has not updated.
            guard let ourDeviceId, !ourDeviceId.isEmpty else { return .undecidable }
            return ourDeviceId.hasPrefix(tag) ? .ours : .foreign

        default:
            return .undecidable
        }
    }
}

/// The one decision the SENDER_SYNC receive path makes before it can recover.
enum SenderSyncRecovery {

    /// Whether the candidate list names no device at all, and so cannot recover on its own.
    ///
    /// A candidate is a contact id. Since 2026-08-26 a per-device one is the bare `deviceId`;
    /// before that it was `userId:deviceId`, and this asked whether any candidate contained a
    /// colon. Establishing a session needs the device id — that is what a bundle is fetched for —
    /// so a list holding only an account id can do nothing.
    ///
    /// That was the state of every freshly linked device until 2026-08-18: own devices were known
    /// only from a cache the **send** path filled, so a device that had linked and not yet sent
    /// anything had none. `handleUnopenedSenderSync` then walked a one-entry list, skipped it for
    /// having no `:`, and returned — no session, no fetch, no log line. Seen on the two-simulator
    /// stand 2026-08-17: a linked device received both copies and neither reached the transcript.
    static func needsOwnDeviceRefresh(candidates: [String]) -> Bool {
        !candidates.contains(where: SessionAddressing.isCryptoIdentity)
    }
}
