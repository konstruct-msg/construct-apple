//
//  SenderSyncDeviceTag.swift
//  Construct Messenger
//
//  The tag that says which of your devices a SENDER_SYNC copy is for, without saying it to anyone
//  else.
//

import Foundation
import CryptoKit

/// Derives and checks the `-ss-<tag>` suffix on a SENDER_SYNC wire id.
///
/// **What the tag is for.** Delivery is per user, not per device: `messaging-service/src/core.rs`
/// writes the same envelope to every one of the recipient's per-device streams. So each device
/// receives the copies meant for the other devices — and the sending device receives its own copy
/// back. Recognising a foreign copy has to be cheap, because the alternative is not merely a few
/// failed decrypts: a copy with `messageNumber == 0` that opens under no session takes the recovery
/// path, which fetches a key bundle over the network and initialises a receiving session. On the
/// sender's own echo that is session churn caused by a message it wrote itself.
///
/// **What it used to leak.** Until 2026-08-17 the tag was `deviceId.prefix(8)` — the device id in
/// plain hex, stable for the life of the device. The relay, which routes every one of these copies,
/// could read which device each was for and group a user's traffic by device. That is precisely the
/// metadata `decisions/sender-sync-routing-inside-the-ciphertext.md` refused to add when it declined
/// to put the *sender's* device in the id; the target's device was already there and had been since
/// multi-device shipped.
///
/// **What it is now.** A per-message value keyed by a secret only the two devices hold:
///
///     secret = HKDF(X25519(our identity private, peer identity public), "ConstructSSTAG-v1")
///     tag    = HMAC-SHA256(secret, base message id || 0x00 || target device id)[0..<8], hex
///
/// X25519 is symmetric in the pair, so the sender derives it against the target device's bundle key
/// and the receiver derives the same value against each of its own devices' bundle keys. The relay
/// holds both public keys — it serves the bundles — and still cannot compute the secret, so the tag
/// is an unlinkable 16 hex characters that changes with every message.
///
/// **The target device id is in the MAC input, and has to be.** The pair secret alone is symmetric:
/// A and B derive the same value, so a tag keyed on it says "this concerns A and B" and not which
/// of the two it is for. Delivery hands the sender its own copy back, so A would then read its own
/// echo as addressed to itself and try to open a message it had just encrypted. Binding the target
/// makes the tag directional while leaving it opaque — the relay cannot compute either direction.
///
/// The `-ss-` marker itself stays. It tells the relay nothing it does not already have: a
/// SENDER_SYNC envelope is unsealed and carries content type 23 with sender equal to recipient.
enum SenderSyncDeviceTag {

    /// Hex characters in a tag: 16, against the legacy form's 8 (`deviceId.prefix(8)`). The two
    /// forms are told apart by length alone, which is why the new one is not also 8.
    static let hexLength = 16
    /// Length of the form this replaced, still read from senders at or below 0.18.0.
    static let legacyHexLength = 8

    private static let domain = "ConstructSSTAG-v1"

    /// The secret shared by two devices of the same account.
    ///
    /// Static-static X25519: no ephemeral, because both sides must derive the same value without
    /// exchanging anything. That makes it stable for the lifetime of the two devices — which is
    /// wanted here, since the per-message variation comes from the message id below, not the key.
    static func pairSecret(ourIdentityPrivateKey: Data, peerIdentityPublicKey: Data) -> SymmetricKey? {
        guard let ourKey = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: ourIdentityPrivateKey),
              let peerKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerIdentityPublicKey),
              let shared = try? ourKey.sharedSecretFromKeyAgreement(with: peerKey) else {
            return nil
        }
        return shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(domain.utf8),
            sharedInfo: Data(),
            outputByteCount: 32
        )
    }

    /// The tag a copy for `targetDeviceId` travels under.
    ///
    /// `baseMessageId` is the id **without** the `-ss-` suffix and without any `-c<n>` chunk
    /// suffix, so every chunk of one message carries the same tag.
    static func tag(baseMessageId: String, targetDeviceId: String, pairSecret: SymmetricKey) -> String {
        var input = Data(baseMessageId.utf8)
        input.append(0x00)  // neither an id nor a device id contains a NUL, so the split is unambiguous
        input.append(Data(targetDeviceId.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: input, using: pairSecret)
        return Data(mac).prefix(hexLength / 2).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether `tag` was written **for `ourDeviceId`** by the device behind `pairSecret`.
    ///
    /// Not constant-time on purpose: both operands are ours, a mismatch means only "this copy is for
    /// another of my devices", and there is no remote party whose timing could learn anything.
    static func matches(
        _ tag: String,
        baseMessageId: String,
        ourDeviceId: String,
        pairSecret: SymmetricKey
    ) -> Bool {
        guard tag.count == hexLength else { return false }
        return tag == self.tag(baseMessageId: baseMessageId, targetDeviceId: ourDeviceId, pairSecret: pairSecret)
    }
}
