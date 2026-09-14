//
//  SenderSyncDeviceTag.swift
//  Construct Messenger
//
//  The tag that says which of your devices a copy is for, without saying it to anyone else.
//

import Foundation

/// Thin seam over the core's `deviceCopyTag` / `deviceCopyTagMatches`.
///
/// **This file used to be the implementation** — X25519, HKDF and HMAC-SHA256 written against
/// CryptoKit. It was moved into `construct-core` on 2026-08-25 and now holds no cryptography at
/// all, only the mapping from this app's vocabulary to the core's.
///
/// Why it moved, when the Swift version worked: the same tag has to be computed by every client
/// that speaks this protocol, and two implementations of it do not fail loudly when they disagree.
/// They produce a copy discarded as foreign, a message that never appears, and no way to tell
/// which side is wrong. Android would have been the second implementation; the TUI and a Linux
/// desktop the third and fourth. See `decisions/core-repatriation-execution-plan.md`.
///
/// The port was verified rather than asserted: the pinned vectors in
/// `construct-protos/conformance/knst_device_copy_tag.json` were produced by *this file's*
/// CryptoKit code before it was deleted, and the Rust module asserts against them.
///
/// **Construction** (the authority is the core; repeated here because a caller reading this file
/// should not have to leave it):
///
///     secret = HKDF-SHA256(X25519(our identity private, peer identity public),
///                          salt = "ConstructSSTAG-v1", info = "") → 32 bytes
///     tag    = HMAC-SHA256(secret, base message id ‖ 0x00 ‖ target device id)[0..<8], hex
///
/// X25519 is symmetric in the pair, so the sender derives it against the target device's bundle
/// key and the receiver derives the same value against each of its own devices' bundle keys. The
/// relay holds both public keys — it serves the bundles — and still cannot compute the secret, so
/// the tag is an unlinkable 16 hex characters that changes with every message.
///
/// **What it used to leak.** Until 2026-08-17 the tag was `deviceId.prefix(8)` — the device id in
/// plain hex, stable for the life of the device. The relay, which routes every one of these
/// copies, could read which device each was for and group a user's traffic by device.
enum SenderSyncDeviceTag {

    /// Hex characters in a tag: 16, against the legacy form's 8 (`deviceId.prefix(8)`). The two
    /// forms are told apart by length alone, which is why the new one is not also 8.
    ///
    /// Duplicated from the core's `TAG_HEX_LEN` because UniFFI does not export constants. Pinned
    /// in the conformance vectors, which both sides read.
    static let hexLength = 16
    /// Length of the form this replaced, still read from senders at or below 0.18.0.
    static let legacyHexLength = 8

    /// The tag a copy for `targetDeviceId` travels under, or `nil` when the key material is
    /// unusable.
    ///
    /// `baseMessageId` is the id **without** the `-ss-` suffix and without any `-c<n>` chunk
    /// suffix, so every chunk of one message carries the same tag.
    static func tag(
        baseMessageId: String,
        targetDeviceId: String,
        ourIdentityPrivateKey: Data,
        peerIdentityPublicKey: Data
    ) -> String? {
        try? deviceCopyTag(
            baseMessageId: baseMessageId,
            targetDeviceId: targetDeviceId,
            ourIdentityPrivate: [UInt8](ourIdentityPrivateKey),
            peerIdentityPublic: [UInt8](peerIdentityPublicKey)
        )
    }

    /// Whether `tag` was written **for `ourDeviceId`** by the device behind
    /// `peerIdentityPublicKey`.
    ///
    /// False for anything it cannot decide, including unusable key material — see the core for
    /// why an undecidable answer here must read as "not foreign".
    static func matches(
        _ tag: String,
        baseMessageId: String,
        ourDeviceId: String,
        ourIdentityPrivateKey: Data,
        peerIdentityPublicKey: Data
    ) -> Bool {
        deviceCopyTagMatches(
            tag: tag,
            baseMessageId: baseMessageId,
            ourDeviceId: ourDeviceId,
            ourIdentityPrivate: [UInt8](ourIdentityPrivateKey),
            peerIdentityPublic: [UInt8](peerIdentityPublicKey)
        )
    }
}
