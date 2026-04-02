//
//  WirePayloadCoder.swift
//  Construct Messenger
//
//  Encodes/decodes the encrypted_payload blob sent to/from the server.
//
//  Wire format (little-endian):
//    [4 bytes]  message_number      (UInt32 LE)
//    [32 bytes] dh_public_key       (X25519 ephemeral public key)
//    [4 bytes]  one_time_prekey_id  (UInt32 LE; 0 = no OTPK / fallback 3-DH mode)
//    [4 bytes]  kyber_otpk_id       (UInt32 LE; 0 = Kyber SPK used; >0 = Kyber OTPK ID)
//    [2 bytes]  kem_ciphertext_len  (UInt16 LE; 0 = no PQC)
//    [N bytes]  kem_ciphertext      (optional)
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
    /// Minimum fixed header: msgNum + dhKey + otpkId + kyberOtpkId + kemLen (46 bytes).
    static let headerSize = messageNumberSize + dhPublicKeySize + otpkIdSize + kyberOtpkIdSize + kemCiphertextLenSize  // 46 bytes

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
            Log.error("❌ WirePayload: KEM ciphertext too large (\(kemLen) bytes, max \(UInt16.max))", category: "WirePayload")
            throw WirePayloadError.kemTooLarge(kemLen)
        }
        var kemLenField = UInt16(kemLen).littleEndian
        withUnsafeBytes(of: &kemLenField) { payload.append(contentsOf: $0) }

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
        let kemCiphertext: Data?          // nil if no PQC
        let content: String               // Base64(nonce || ciphertext || auth_tag)
    }

    /// Unpack a received encrypted_payload blob into components for decryption.
    static func decode(_ data: Data) throws -> DecodedPayload {
        guard data.count > headerSize else {
            throw WirePayloadError.payloadTooShort(data.count)
        }

        let messageNumber = data.prefix(messageNumberSize)
            .withUnsafeBytes { $0.load(as: UInt32.self) }
            .littleEndian

        let dhPubKeyRange = messageNumberSize ..< (messageNumberSize + dhPublicKeySize)
        let ephemeralPublicKey = [UInt8](data[dhPubKeyRange])

        let otpkIdOffset = messageNumberSize + dhPublicKeySize
        let oneTimePreKeyId = data[otpkIdOffset ..< (otpkIdOffset + otpkIdSize)]
            .withUnsafeBytes { $0.load(as: UInt32.self) }
            .littleEndian

        // 4 bytes: kyber_otpk_id (LE)
        let kyberOtpkIdOffset = otpkIdOffset + otpkIdSize
        let kyberOtpkId = data[kyberOtpkIdOffset ..< (kyberOtpkIdOffset + kyberOtpkIdSize)]
            .withUnsafeBytes { $0.load(as: UInt32.self) }
            .littleEndian

        // 2 bytes: kem_ciphertext_len (LE)
        let kemLenOffset = messageNumberSize + dhPublicKeySize + otpkIdSize + kyberOtpkIdSize
        let kemLen = Int(data[kemLenOffset ..< (kemLenOffset + kemCiphertextLenSize)]
            .withUnsafeBytes { $0.load(as: UInt16.self) }
            .littleEndian)

        let sealedBoxStart = headerSize + kemLen
        guard data.count > sealedBoxStart else {
            throw WirePayloadError.payloadTooShort(data.count)
        }

        let kemCiphertext: Data? = kemLen > 0 ? data[headerSize ..< sealedBoxStart] : nil

        let sealedBoxData = data[sealedBoxStart...]
        let content = sealedBoxData.base64EncodedString()

        return DecodedPayload(
            messageNumber: messageNumber,
            ephemeralPublicKey: ephemeralPublicKey,
            oneTimePreKeyId: oneTimePreKeyId,
            kyberOtpkId: kyberOtpkId,
            kemCiphertext: kemCiphertext,
            content: content
        )
    }
}

// MARK: - Errors

enum WirePayloadError: Error, LocalizedError {
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
