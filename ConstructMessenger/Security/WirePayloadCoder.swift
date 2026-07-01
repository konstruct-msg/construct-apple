//
//  WirePayloadCoder.swift
//  Construct Messenger
//
//  Encodes/decodes the encrypted_payload blob sent to/from the server.
//
//  Wire format (little-endian) — must match wire_payload.rs HEADER_SIZE = 52:
//    [4 bytes]  message_number        (UInt32 LE)
//    [32 bytes] dh_public_key         (X25519 ephemeral public key)
//    [4 bytes]  one_time_prekey_id    (UInt32 LE; 0 = no OTPK / fallback 3-DH mode)
//    [4 bytes]  kyber_otpk_id         (UInt32 LE; 0 = Kyber SPK used; >0 = Kyber OTPK ID)
//    [2 bytes]  kem_ciphertext_len    (UInt16 LE; 0 = no PQC)
//    [4 bytes]  previous_chain_length (UInt32 LE; DR PN field for out-of-order recovery)
//    [2 bytes]  suite_id              (UInt16 LE; crypto-suite identifier)
//    [N bytes]  kem_ciphertext        (optional)
//    [rest]     nonce || ciphertext || auth_tag  (ChaCha20-Poly1305 sealed box)
//
//  The server stores and forwards this blob opaquely — it never parses the contents.
//

import Foundation

enum WirePayloadCoder {

    // MARK: - Constants

    private static let messageNumberSize = 4
    private static let dhPublicKeySize = 32
    private static let otpkIdSize = 4
    private static let kyberOtpkIdSize = 4
    private static let kemCiphertextLenSize = 2
    private static let previousChainLengthSize = 4
    private static let suiteIdSize = 2
    /// Fixed header: msgNum + dhKey + otpkId + kyberOtpkId + kemLen + prevChainLen + suiteId (52 bytes).
    static let headerSize = messageNumberSize + dhPublicKeySize + otpkIdSize + kyberOtpkIdSize + kemCiphertextLenSize + previousChainLengthSize + suiteIdSize  // 52 bytes

    // MARK: - Encode

    /// Pack EncryptedMessageComponents into a single opaque Data blob.
    /// - Parameter kemCiphertext: Optional ML-KEM-768 ciphertext (1088 bytes) for PQXDH first messages.
    /// - Parameter kyberOtpkId: Kyber OTPK key ID (0 = Kyber SPK was used).
    static func encode(_ components: MessageCryptoService.EncryptedMessageComponents, kemCiphertext: Data? = nil, kyberOtpkId: UInt32 = 0) throws -> Data {
        guard components.ephemeralPublicKey.count == dhPublicKeySize else {
            throw WirePayloadError.invalidDHPublicKey
        }
        let sealedBox = components.content

        let kemLen = kemCiphertext?.count ?? 0
        var payload = Data(capacity: headerSize + kemLen + sealedBox.count)

        // 4 bytes: message_number (LE)
        var msgNum = components.messageNumber.littleEndian
        withUnsafeBytes(of: &msgNum) { payload.append(contentsOf: $0) }

        // 32 bytes: dh_public_key
        payload.append(contentsOf: components.ephemeralPublicKey)

        // 4 bytes: one_time_prekey_id (LE); 0 = no OTPK used
        var otpkId = components.oneTimePreKeyId.littleEndian
        withUnsafeBytes(of: &otpkId) { payload.append(contentsOf: $0) }

        // 4 bytes: kyber_otpk_id (LE); 0 = Kyber SPK was used; >0 = Kyber OTPK ID
        var kOtpkId = kyberOtpkId.littleEndian
        withUnsafeBytes(of: &kOtpkId) { payload.append(contentsOf: $0) }

        // 2 bytes: kem_ciphertext_len (LE); 0 = no PQC
        guard kemLen <= Int(UInt16.max) else {
            Log.error("WirePayload: KEM ciphertext too large (\(kemLen) bytes, max \(UInt16.max))", category: "WirePayload")
            throw WirePayloadError.kemTooLarge(kemLen)
        }
        var kemLenField = UInt16(kemLen).littleEndian
        withUnsafeBytes(of: &kemLenField) { payload.append(contentsOf: $0) }

        // 4 bytes: previous_chain_length (LE); always 0 from Swift (Rust orchestrator sets the real value)
        var prevChainLen = UInt32(0).littleEndian
        withUnsafeBytes(of: &prevChainLen) { payload.append(contentsOf: $0) }

        // 2 bytes: suite_id (LE); 1 = Classic Curve25519+Ed25519
        var suiteIdField = UInt16(1).littleEndian
        withUnsafeBytes(of: &suiteIdField) { payload.append(contentsOf: $0) }

        // N bytes: kem_ciphertext (only present if kemLen > 0)
        if let kem = kemCiphertext { payload.append(kem) }

        // rest: nonce || ciphertext || auth_tag
        payload.append(sealedBox)

        return payload
    }

    // MARK: - Decode

    struct DecodedPayload {
        let messageNumber: UInt32
        let ephemeralPublicKey: [UInt8]   // 32 bytes
        let oneTimePreKeyId: UInt32       // 0 = no OTPK
        let kyberOtpkId: UInt32           // 0 = Kyber SPK used; >0 = Kyber OTPK ID
        let previousChainLength: UInt32   // DR PN field
        let suiteId: UInt16               // crypto-suite identifier
        let kemCiphertext: Data?          // nil if no PQC
        let content: Data               // Base64(nonce || ciphertext || auth_tag)
    }

    /// Unpack a received encrypted_payload blob into components for decryption.
    static func decode(_ data: Data) throws -> DecodedPayload {
        guard data.count > headerSize else {
            throw WirePayloadError.payloadTooShort(data.count)
        }

        // Use loadUnaligned throughout — gRPC Data slices may start at any byte offset,
        // so load(as:) (which requires pointer alignment) can crash on non-aligned payloads.
        let messageNumber = data.prefix(messageNumberSize)
            .withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            .littleEndian

        let dhPubKeyRange = messageNumberSize ..< (messageNumberSize + dhPublicKeySize)
        let ephemeralPublicKey = [UInt8](data[dhPubKeyRange])

        let otpkIdOffset = messageNumberSize + dhPublicKeySize
        let oneTimePreKeyId = data[otpkIdOffset ..< (otpkIdOffset + otpkIdSize)]
            .withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            .littleEndian

        // 4 bytes: kyber_otpk_id (LE)
        let kyberOtpkIdOffset = otpkIdOffset + otpkIdSize
        let kyberOtpkId = data[kyberOtpkIdOffset ..< (kyberOtpkIdOffset + kyberOtpkIdSize)]
            .withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            .littleEndian

        // 2 bytes: kem_ciphertext_len (LE)
        let kemLenOffset = messageNumberSize + dhPublicKeySize + otpkIdSize + kyberOtpkIdSize
        let kemLen = Int(data[kemLenOffset ..< (kemLenOffset + kemCiphertextLenSize)]
            .withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
            .littleEndian)

        // 4 bytes: previous_chain_length (LE)
        let prevChainLenOffset = kemLenOffset + kemCiphertextLenSize
        let previousChainLength = data[prevChainLenOffset ..< (prevChainLenOffset + previousChainLengthSize)]
            .withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            .littleEndian

        // 2 bytes: suite_id (LE)
        let suiteIdOffset = prevChainLenOffset + previousChainLengthSize
        let suiteId = data[suiteIdOffset ..< (suiteIdOffset + suiteIdSize)]
            .withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
            .littleEndian

        let sealedBoxStart = headerSize + kemLen
        guard data.count > sealedBoxStart else {
            throw WirePayloadError.payloadTooShort(data.count)
        }

        let kemCiphertext: Data? = kemLen > 0 ? data[headerSize ..< sealedBoxStart] : nil

        // suite==3 may carry additive pq_ratchet (u8 type + u16 len + data) after kem; skip for content.
        var contentStart = sealedBoxStart
        if suiteId == 3 && data.count > contentStart + 3 {
            let pqLen = Int(data[(contentStart + 1) ..< (contentStart + 3)]
                .withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
                .littleEndian)
            contentStart += 3 + pqLen
        }
        let sealedBoxData = data[contentStart...]
        let content = Data(sealedBoxData)

        return DecodedPayload(
            messageNumber: messageNumber,
            ephemeralPublicKey: ephemeralPublicKey,
            oneTimePreKeyId: oneTimePreKeyId,
            kyberOtpkId: kyberOtpkId,
            previousChainLength: previousChainLength,
            suiteId: suiteId,
            kemCiphertext: kemCiphertext,
            content: content
        )
    }
}

// MARK: - Errors

enum WirePayloadError: Error, LocalizedError, Equatable {
    case invalidDHPublicKey
    case payloadTooShort(Int)
    case kemTooLarge(Int)

    var errorDescription: String? {
        switch self {
        case .invalidDHPublicKey:
            return "DH public key must be exactly 32 bytes"
        case .payloadTooShort(let size):
            return "Payload too short: \(size) bytes (minimum \(WirePayloadCoder.headerSize + 1))"
        case .kemTooLarge(let size):
            return "KEM ciphertext too large: \(size) bytes (max \(UInt16.max))"
        }
    }
}
