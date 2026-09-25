//
//  WirePayloadCoder.swift
//  Construct Messenger
//
//  Thin adapter over the Rust core's canonical wire framing
//  (`wirePayloadPack` / `wirePayloadUnpack`, backed by wire_payload.rs).
//
//  This type intentionally contains NO byte-layout logic. The encrypted_payload
//  format lives in exactly one place — the Rust core — so suite_id /
//  pq_message_epoch / pq_ratchet_field can never be silently dropped on the wire
//  again (the suite-3 messaging outage came from a hand-rolled duplicate here
//  that hardcoded suite_id = 1 and skipped the PQ section).
//

import Foundation

enum WirePayloadCoder {

    /// Fixed header size (no KEM ciphertext) — mirrors `wire_payload::HEADER_SIZE`.
    /// Used only as a size threshold to distinguish real payloads from short
    /// control sentinels; the actual layout is owned by the core.
    static let headerSize = 52

    // MARK: - Encode

    /// Pack `EncryptedMessageComponents` into the canonical opaque blob via the core.
    ///
    /// The PQXDH v2 header (KEM ciphertext, Kyber prekey id) is taken from the components as the
    /// core produced them — it was a pair of separate arguments here, for the caller to remember;
    /// the core sets the v2 flag on the wire from the ciphertext.
    static func encode(_ components: MessageCryptoService.EncryptedMessageComponents) throws -> Data {
        let payload = WirePayload(
            dhPublicKey: [UInt8](components.ephemeralPublicKey),
            messageNumber: components.messageNumber,
            oneTimePrekeyId: components.oneTimePreKeyId,
            kyberOtpkId: components.kyberPrekeyId,
            // Swift never sets the DR PN field here; the Rust orchestrator send path
            // packs the authoritative value. This component path (tests / call signals)
            // only produces PN = 0.
            previousChainLength: 0,
            suiteId: components.suiteId,
            kemCiphertext: components.kemCiphertext.isEmpty ? nil : [UInt8](components.kemCiphertext),
            sealedBox: [UInt8](components.content),
            pqMessageEpoch: components.pqMessageEpoch,
            pqRatchetField: [UInt8](components.pqRatchetField)
        )
        return Data(try wirePayloadPack(payload: payload))
    }

    // MARK: - Decode

    struct DecodedPayload {
        let messageNumber: UInt32
        let ephemeralPublicKey: [UInt8]   // 32 bytes
        let oneTimePreKeyId: UInt32       // 0 = no OTPK
        let kyberOtpkId: UInt32           // the responder's Kyber prekey (with a KEM ciphertext); 0 = none
        let previousChainLength: UInt32   // DR PN field
        let suiteId: UInt16               // crypto-suite identifier
        let kemCiphertext: Data?          // ML-KEM-1024, on the initiator's first flight; nil otherwise
        let content: Data                 // raw sealed box: nonce || ciphertext || auth_tag
        let pqMessageEpoch: UInt32        // suite-3 per-message PQ epoch tag (0 otherwise)
        let pqRatchetField: Data          // suite-3 sparse PQ field, serialized (empty = none)
    }

    /// Unpack a received encrypted_payload blob into components for decryption.
    static func decode(_ data: Data) throws -> DecodedPayload {
        let p = try wirePayloadUnpack(data: [UInt8](data))
        return DecodedPayload(
            messageNumber: p.messageNumber,
            ephemeralPublicKey: p.dhPublicKey,
            oneTimePreKeyId: p.oneTimePrekeyId,
            kyberOtpkId: p.kyberOtpkId,
            previousChainLength: p.previousChainLength,
            suiteId: p.suiteId,
            kemCiphertext: p.kemCiphertext.map { Data($0) },
            content: Data(p.sealedBox),
            pqMessageEpoch: p.pqMessageEpoch,
            pqRatchetField: Data(p.pqRatchetField)
        )
    }
}
