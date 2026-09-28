//
//  CallSignalCrypto.swift
//  Construct Messenger
//
//  End-to-end encryption for the WebRTC ICE candidate.
//
//  gRPC/TLS protects the hop; the signaling server terminates it. A candidate reads
//  "candidate:1 1 UDP 2130706431 192.168.1.5 54321 typ host" — an address and a port — so it is
//  encrypted with the peer's Double Ratchet session and the server forwards ciphertext it cannot
//  open.
//
//  ## The frame
//
//      [1B version 0x04][wire payload, exactly as the core packed it]
//
//  v4 (2026-09-28) stopped laying out fields at all. v3 listed them — suiteId, msgNum, pqEpoch,
//  pqRatchetField, epk, ciphertext — and a list is what goes stale: it had no PN field, so a
//  candidate after a ratchet step could not store its skipped keys, and it would have had no room
//  for the responder's answer to the initiator's KEM identity key, without which the initiator
//  cannot read the responder's first reply
//  (`decisions/responder-authenticates-initiator-by-kem.md`). The core owns the payload format;
//  this frame carries it.
//
//  It goes into `IceCandidate.candidate`, which is `bytes` since 2026-08-21. It was `string`, so
//  this frame was base64'd and given an "ENC:v3:" ASCII prefix — 33 % more bytes for a field that
//  never held text, and the exact thing `AGENTS.md` rule 1 forbids outside QR codes, deep links
//  and `mailto:`. construct-protos states the same rule in its own words: crypto material is
//  `bytes`, not `string`.
//
//  The version byte replaces that prefix. It is not decoration: `bytes` has no shape of its own,
//  so without it a malformed value would be parsed as a frame instead of refused.
//
//  ## What is deliberately gone
//
//  **v1, v2 and v3.** v3 is the field list above. v2 dropped suiteId/pqMessageEpoch/pqRatchetField, so every field encrypted over
//  a suite-3 session decrypted as suite 1 and failed — 100 % of candidates, both directions, no
//  media path, silent calls. v1 was base64'd JSON. Both were kept as read paths for peers that no
//  longer exist; alpha force-updates, and a reader for a format nothing writes is a second
//  interpretation of the same bytes.
//
//  **Plaintext passthrough.** `decryptField` used to return an unprefixed value unchanged, which
//  meant a stripped candidate looked exactly like a legacy one. On a `bytes` field there is no
//  "unprefixed" — either it parses as our frame or it is refused.
//
//  **The SDP half.** `decryptSdp` was the same passthrough for `CallOffer.sdp` / `CallAnswer.sdp`,
//  kept for a peer that might one day encrypt them. Nothing needed it: an offer or answer reaches
//  this client only through `handleCallSignalProto`, so it is already plaintext, having come out of
//  the Double Ratchet with the rest of the `WebRTCSignal`. What the hop did instead was let three
//  writers of `pendingRemoteOfferSdp` disagree about whether what they stored was ciphertext, and
//  let `handleSignalResponse` apply an SDP handed to it by the signaling server. Both are gone as
//  of 2026-08-21 — see `signalStreamAdmission`. There is no base64 left in this file.
//

import Foundation

// MARK: - Errors

enum CallSignalCryptoError: Error, LocalizedError {
    case invalidEnvelope
    case missingSession(peerUserId: String)

    var errorDescription: String? {
        switch self {
        case .invalidEnvelope:
            return "Signal envelope is malformed or corrupted"
        case .missingSession(let id):
            return "No E2E session found for peer \(id.prefix(8))… — cannot encrypt signal"
        }
    }
}

// MARK: - The frame

/// The binary layout of an encrypted ICE candidate: a version byte and the core's wire payload.
///
/// Pure on purpose, so a test reaches it without a Keychain-backed singleton. The layouts before
/// this one failed by **dropping fields** — v2 lost the suite and the PQ tags (every suite-3
/// candidate failed), v3 lost the PN field — which is why this one lists none.
enum CallSignalFrame {

    /// Frame version. Bump when the layout changes; a reader that does not know a version refuses
    /// rather than guessing. `bytes` has no shape of its own, so without this a malformed value
    /// would be handed to the core as a payload instead of refused here.
    static let version: UInt8 = 0x04

    static func encode(wirePayload: Data) -> Data {
        var frame = Data(capacity: 1 + wirePayload.count)
        frame.append(version)
        frame.append(wirePayload)
        return frame
    }

    /// The wire payload the frame carries. Refuses anything that is not a v4 frame with a payload.
    static func decode(_ frame: Data) throws -> Data {
        guard frame.count > 1, frame[frame.startIndex] == version else {
            throw CallSignalCryptoError.invalidEnvelope
        }
        return Data(frame.dropFirst())
    }
}

// MARK: - Service

/// Encrypts/decrypts the WebRTC ICE candidate using the peer's Double Ratchet session.
final class CallSignalCrypto {
    static let shared = CallSignalCrypto()
    private init() {}

    // MARK: Encrypt

    /// Encrypt a candidate for a peer. Throws if there is no established session.
    ///
    /// Length is hidden by the core, once: `pad_message_default` pads the plaintext to a 255-byte
    /// block before encryption, so every candidate under that ceiling produces the same 283-byte
    /// ciphertext. A second scheme used to re-pad this to 1024 bytes — see the 2026-08-21 removal
    /// of `MessagePadding`, which made call signals the one traffic class with a distinct size.
    ///
    /// Encrypts for the peer's **pinned** device, like the offer that opened the call — the two
    /// have to name the same ratchet, so this surface moves when call signalling does, not before
    /// (`decisions/a-peer-is-a-set-of-devices.md`).
    func encryptCandidate(_ plaintext: String, for peerUserId: String) throws -> Data {
        guard let peerDevice = SessionAddressing.pinnedDevice(ofPeer: peerUserId) else {
            throw CallSignalCryptoError.missingSession(peerUserId: peerUserId)
        }
        do {
            let wire = try CryptoManager.shared.encryptMessage(plaintext, forDevice: peerDevice)
            return CallSignalFrame.encode(wirePayload: wire)
        } catch CryptoManagerError.sessionNotFound {
            throw CallSignalCryptoError.missingSession(peerUserId: peerUserId)
        }
    }

    // MARK: Decrypt

    /// Decrypt a candidate from a peer — on the same pinned device's ratchet it was encrypted for.
    func decryptCandidate(_ frame: Data, from peerUserId: String) throws -> String {
        guard let peerDevice = SessionAddressing.pinnedDevice(ofPeer: peerUserId) else {
            throw CallSignalCryptoError.missingSession(peerUserId: peerUserId)
        }
        let wire = try CallSignalFrame.decode(frame)
        return try CryptoManager.shared.decryptCallSignal(contactId: peerDevice, wirePayload: wire)
    }

}
