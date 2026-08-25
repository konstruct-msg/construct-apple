//
//  SenderSyncWireId.swift
//  Construct Messenger
//
//  The wire id a SENDER_SYNC copy travels under, and the one thing it says.
//

import Foundation
import CryptoKit

/// Reading of the `-ss-<tag>` suffix `MultiDeviceSendCoordinator` puts on a SENDER_SYNC copy.
///
/// The suffix names the device the copy is **for**. That matters because delivery is not per
/// device: `messaging-service/src/core.rs` fans a message out with `fetch_recipient_device_ids`,
/// writing the same envelope to every one of the recipient's per-device streams. An account with
/// three devices therefore receives, on each of them, the two copies meant for the other two.
///
/// Recognising those costs one X25519 per own device. Without it each foreign copy walks the whole
/// candidate-session list, fails every decrypt, and — on a first message — reaches for a key bundle
/// over the network, all for a message that was never ours to read.
///
/// What the tag *is* changed on 2026-08-17: it was the device id in plain hex, readable by the
/// relay; it is now a per-message MAC under a secret only the two devices share. See
/// `SenderSyncDeviceTag` for the derivation and for what the old form gave away.
enum SenderSyncWireId {

    private static let marker = "-ss-"

    /// The target device tag, or `nil` when the id is not a SENDER_SYNC wire id.
    ///
    /// Forms produced by the sender:
    ///
    ///     <uuid>-ss-<tag>          single chunk
    ///     <uuid>-ss-<tag>-c<n>     chunk n of many
    static func targetDeviceTag(of wireId: String) -> String? {
        guard let range = wireId.range(of: marker, options: .backwards) else { return nil }
        let rest = wireId[range.upperBound...]
        // Cut the chunk suffix. `-c` cannot occur inside a tag: it is hex.
        let tag = rest.range(of: "-c", options: .backwards).map { String(rest[..<$0.lowerBound]) }
            ?? String(rest)
        return tag.isEmpty ? nil : tag
    }

    /// The id the tag was computed over: everything before `-ss-`.
    ///
    /// The sender MACs this rather than the full wire id, so every chunk of one message carries the
    /// same tag and the receiver can recompute it from any chunk it happens to see first.
    static func baseId(of wireId: String) -> String? {
        guard let range = wireId.range(of: marker, options: .backwards) else { return nil }
        let base = String(wireId[..<range.lowerBound])
        return base.isEmpty ? nil : base
    }

    /// Whether `wireId` addresses one of our *other* devices — i.e. whether this copy is not ours
    /// to open. Also true of the sending device's own echo, which delivery hands back to it.
    ///
    /// `peerIdentityKeys` are the identity public keys of our other devices, one per device;
    /// `ourIdentityPrivateKey` is our half of every pair secret; `ourDeviceId` is what the sender
    /// would have bound into the tag had it been addressing us.
    ///
    /// Fails **open** everywhere it cannot decide: an unrecognised tag shape, no keys to hand, no
    /// device id. Wrongly opening a copy costs failed decrypts; wrongly discarding one loses a
    /// message from the transcript, and silently, which is the failure mode this feature already
    /// spent months in.
    static func isForAnotherDevice(
        wireId: String,
        ourDeviceId: String?,
        ourIdentityPrivateKey: Data?,
        peerIdentityKeys: [Data]
    ) -> Bool {
        guard let tag = targetDeviceTag(of: wireId), let base = baseId(of: wireId) else {
            return false  // not a SENDER_SYNC wire id — not ours to judge
        }

        switch tag.count {
        case SenderSyncDeviceTag.hexLength:
            // Sender on this build or newer. Ours when one of our pair secrets reproduces the tag
            // *for our own device id* — the target is bound into the MAC, so a copy we sent to
            // another device does not match here even though we share its secret.
            guard let ourDeviceId, !ourDeviceId.isEmpty,
                  let ourIdentityPrivateKey, !peerIdentityKeys.isEmpty else { return false }
            return !peerIdentityKeys.contains {
                SenderSyncDeviceTag.matches(
                    tag,
                    baseMessageId: base,
                    ourDeviceId: ourDeviceId,
                    ourIdentityPrivateKey: ourIdentityPrivateKey,
                    peerIdentityPublicKey: $0
                )
            }

        case SenderSyncDeviceTag.legacyHexLength:
            // Sender at or below 0.18.0 wrote `deviceId.prefix(8)`. Prefix, not equality —
            // comparing a full device id against a truncated tag never matches, and every copy
            // including our own would be discarded as foreign.
            //
            // Removal condition: no builds at or below 0.18.0 left in the field. Until then
            // dropping this stops placing copies from a tester who has not updated.
            guard let ourDeviceId, !ourDeviceId.isEmpty else { return false }
            return !ourDeviceId.hasPrefix(tag)

        default:
            return false
        }
    }
}

/// The one decision the SENDER_SYNC receive path makes before it can recover.
enum SenderSyncRecovery {

    /// Whether the candidate list names no device at all, and so cannot recover on its own.
    ///
    /// A candidate is a session key: `userId` for the primary session, `userId:deviceId` for a
    /// per-device one. Establishing a session needs the device id — that is what a bundle is
    /// fetched for — so a list holding only the plain `userId` form can do nothing.
    ///
    /// That was the state of every freshly linked device until 2026-08-18: own devices were known
    /// only from a cache the **send** path filled, so a device that had linked and not yet sent
    /// anything had none. `handleUnopenedSenderSync` then walked a one-entry list, skipped it for
    /// having no `:`, and returned — no session, no fetch, no log line. Seen on the two-simulator
    /// stand 2026-08-17: a linked device received both copies and neither reached the transcript.
    static func needsOwnDeviceRefresh(candidates: [String]) -> Bool {
        !candidates.contains { $0.contains(":") }
    }
}
