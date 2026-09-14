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
//      [1B version 0x03][2B suiteId LE][4B msgNum LE][4B pqEpoch LE][4B pqFieldLen LE]
//      [pqRatchetField][32B epk][ciphertext]
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
//  **v1 and v2.** v2 dropped suiteId/pqMessageEpoch/pqRatchetField, so every field encrypted over
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

/// The binary layout of an encrypted ICE candidate, separated from the crypto that fills it.
///
/// Pure on purpose. The v2 format failed because it **dropped fields** — no suiteId, no
/// pqMessageEpoch, no pqRatchetField — so every candidate encrypted over a suite-3 session was
/// decrypted as suite 1 and failed, 100 % in both directions, and a call had no media path. That
/// is a property of the layout alone, and it was unreachable by a test while the layout only
/// existed inside a method that needed a Keychain-backed singleton to reach.
enum CallSignalFrame {

    /// Everything the receiver's ratchet needs. A field missing here is the v2 defect.
    struct Fields: Equatable {
        var suiteId: UInt16
        var messageNumber: UInt32
        var pqMessageEpoch: UInt32
        var pqRatchetField: Data
        var ephemeralPublicKey: Data
        var ciphertext: Data
    }

    /// Frame version. Bump when the layout changes; a reader that does not know a version refuses
    /// rather than guessing. It replaces the "ENC:v3:" ASCII prefix the `string` field needed —
    /// `bytes` has no shape of its own, so without this a malformed value would be parsed as a
    /// frame instead of refused.
    static let version: UInt8 = 0x03
    /// version + suiteId + msgNum + pqEpoch + pqFieldLen.
    static let headerLength = 1 + 2 + 4 + 4 + 4
    static let epkLength = 32

    static func encode(_ f: Fields) -> Data {
        var frame = Data(capacity: headerLength + f.pqRatchetField.count + epkLength + f.ciphertext.count)
        frame.append(version)
        appendLE(&frame, f.suiteId)
        appendLE(&frame, f.messageNumber)
        appendLE(&frame, f.pqMessageEpoch)
        appendLE(&frame, UInt32(f.pqRatchetField.count))
        frame.append(f.pqRatchetField)
        frame.append(f.ephemeralPublicKey)
        frame.append(f.ciphertext)
        return frame
    }

    static func decode(_ frame: Data) throws -> Fields {
        // Anchor to startIndex: a `Data` slice carries a non-zero origin and absolute-index reads
        // trap on it.
        let start = frame.startIndex
        guard frame.count >= headerLength + epkLength + 1, frame[start] == version else {
            throw CallSignalCryptoError.invalidEnvelope
        }
        let pqLen = Int(loadLE(frame, at: start + 11) as UInt32)
        let pqEnd = start + headerLength + pqLen
        // `pqEnd` can overflow past the end on a hostile length; compare against the real end and
        // leave at least one ciphertext byte.
        guard pqLen >= 0, pqEnd >= start + headerLength, frame.endIndex > pqEnd + epkLength else {
            throw CallSignalCryptoError.invalidEnvelope
        }
        return Fields(
            suiteId: loadLE(frame, at: start + 1),
            messageNumber: loadLE(frame, at: start + 3),
            pqMessageEpoch: loadLE(frame, at: start + 7),
            pqRatchetField: Data(frame[(start + headerLength)..<pqEnd]),
            ephemeralPublicKey: Data(frame[pqEnd..<(pqEnd + epkLength)]),
            ciphertext: Data(frame[(pqEnd + epkLength)...])
        )
    }

    private static func appendLE<T: FixedWidthInteger>(_ data: inout Data, _ value: T) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    private static func loadLE<T: FixedWidthInteger>(_ data: Data, at index: Data.Index) -> T {
        data.withUnsafeBytes {
            T(littleEndian: $0.loadUnaligned(fromByteOffset: index - data.startIndex, as: T.self))
        }
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
    func encryptCandidate(_ plaintext: String, for peerUserId: String) throws -> Data {
        do {
            let c = try CryptoManager.shared.encryptMessage(plaintext, for: peerUserId)
            return CallSignalFrame.encode(
                CallSignalFrame.Fields(
                    suiteId: c.suiteId,
                    messageNumber: c.messageNumber,
                    pqMessageEpoch: c.pqMessageEpoch,
                    pqRatchetField: c.pqRatchetField,
                    ephemeralPublicKey: c.ephemeralPublicKey,
                    ciphertext: c.content
                )
            )
        } catch CryptoManagerError.sessionNotFound {
            throw CallSignalCryptoError.missingSession(peerUserId: peerUserId)
        }
    }

    // MARK: Decrypt

    /// Decrypt a candidate from a peer.
    func decryptCandidate(_ frame: Data, from peerUserId: String) throws -> String {
        let f = try CallSignalFrame.decode(frame)
        return try CryptoManager.shared.decryptRawComponents(
            contactId: peerUserId,
            ephemeralPublicKey: f.ephemeralPublicKey,
            messageNumber: f.messageNumber,
            content: f.ciphertext,
            suiteId: f.suiteId,
            pqMessageEpoch: f.pqMessageEpoch,
            pqRatchetField: f.pqRatchetField
        )
    }

}
