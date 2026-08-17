//
//  EndSessionPayload.swift
//  Construct Messenger
//
//  The wire payload of an END_SESSION, and the two things that used to be wrong with it.
//

import Foundation

/// Builds and reads the `encrypted_payload` of an END_SESSION (content type 21).
///
/// **Why this exists.** END_SESSION is the one carrier that cannot be encrypted with the ratchet:
/// it is sent precisely when the ratchet may be unusable, so encrypting it would lose the message
/// in the case it exists for. That is a real constraint and it is why type 21 stays on the
/// envelope. What was *not* a constraint, and shipped as if it were:
///
/// 1. The reset reason travelled in the clear. `SessionControl { op: end, reason: … }` was
///    serialised straight into `encrypted_payload`, so the relay read why any two accounts' session
///    broke. Sealing did not help: `buildEnvelope` fills that field before it branches, and stealth
///    is not optional in Release — so this was the live path, not a fallback.
/// 2. The payload was 4 or 16 bytes. Sealed message bodies are padded to 1024/4096/16384, so
///    END_SESSION was identifiable by length alone, whatever `SealedInner` declared.
///
/// Both are closed here. The reason is sealed to the recipient's **identity** key — no ratchet
/// involved, so the property that made END_SESSION special is preserved — and the payload is a
/// fixed 1024 bytes, indistinguishable from the smallest body bucket.
///
/// Layout (always exactly `paddedSize`):
///
///     [0 ..< boxSize]     box: sealToIdentity(fixed 32-byte plaintext), domain-separated
///     [boxSize ..< 1024]  random padding
///
/// Nothing is length-prefixed and the box is a fixed size, so every END_SESSION looks the same on
/// the wire whether it carries a reason, carries none, or could not be sealed at all.
enum EndSessionPayload {

    /// Plaintext inside the box: `[0] = length of the SessionControl bytes`, then those bytes,
    /// then zeros. Fixed so the box — and therefore the payload — never varies with the reason.
    static let boxPlaintextSize = 32
    static let boxSize = StealthSenderService.identityBoxOverhead + boxPlaintextSize
    /// The smallest padding bucket used by message bodies (`PaddingBucket`), matched deliberately.
    static let paddedSize = 1024

    private static let domain = "ConstructENDSESSION-v1"

    // MARK: - Send

    /// The payload to put on the wire.
    ///
    /// `recipientIdentityKey` may be nil — then the payload is entirely random and the peer simply
    /// recovers no reason, which is the behaviour every pre-reason peer already has. It is never a
    /// cause to fall back to sending the reason in the clear: an unsealable hint is worth less than
    /// the metadata it would cost.
    static func build(
        reason: Shared_Proto_Messaging_V1_SessionResetReason,
        recipientIdentityKey: Data?
    ) -> Data {
        guard let recipientIdentityKey else { return randomBytes(paddedSize) }

        var control = Shared_Proto_Messaging_V1_SessionControl()
        control.op = .end
        control.reason = reason
        guard let controlBytes = try? control.serializedData(),
              controlBytes.count < boxPlaintextSize else {
            return randomBytes(paddedSize)
        }

        var plaintext = Data(capacity: boxPlaintextSize)
        plaintext.append(UInt8(controlBytes.count))
        plaintext.append(controlBytes)
        plaintext.append(Data(repeating: 0, count: boxPlaintextSize - plaintext.count))

        guard let box = try? StealthSenderService.sealToIdentity(
            plaintext, recipientIdentityKey: recipientIdentityKey, domain: domain
        ), box.count == boxSize else {
            return randomBytes(paddedSize)
        }

        return box + randomBytes(paddedSize - boxSize)
    }

    // MARK: - Receive

    /// The reason a peer sent END_SESSION, or `.unspecified` when there is none to read — an
    /// unsealable payload, a payload sealed to a different identity, or a sender old enough to
    /// predate this format.
    ///
    /// A reason is a recovery *hint* (`.otpkUnreproducible` asks for a 3-DH re-init), never an
    /// authorisation: END_SESSION is acted on because it arrived, not because it explained itself.
    /// So every failure below returns `.unspecified` rather than throwing.
    static func reason(
        from payload: Data,
        ourIdentityPrivateKey: Data?
    ) -> Shared_Proto_Messaging_V1_SessionResetReason {
        if payload.count == paddedSize, let ourIdentityPrivateKey {
            let box = payload.prefix(boxSize)
            if let plaintext = try? StealthSenderService.openFromIdentity(
                Data(box), ourIdentityPrivKeyBytes: ourIdentityPrivateKey, domain: domain
            ), let length = plaintext.first, length > 0, Int(length) < plaintext.count {
                let controlBytes = plaintext.dropFirst().prefix(Int(length))
                if let control = try? Shared_Proto_Messaging_V1_SessionControl(
                    serializedBytes: Data(controlBytes)
                ) {
                    return control.reason
                }
            }
            return .unspecified
        }

        // Sender predates the sealed payload (≤ 0.18.0): the reason was a bare SessionControl, and
        // legacy senders before that put a 16-byte sentinel here which simply does not decode.
        //
        // Removal condition: no builds at or below 0.18.0 left in the field. Until then this is the
        // only way a tester's END_SESSION hint reaches us; after that it is a path that accepts an
        // unauthenticated reason from anyone who can write to the envelope.
        guard let control = try? Shared_Proto_Messaging_V1_SessionControl(serializedBytes: payload) else {
            return .unspecified
        }
        return control.reason
    }

    // MARK: - Private

    private static func randomBytes(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: 0...255) })
    }
}
