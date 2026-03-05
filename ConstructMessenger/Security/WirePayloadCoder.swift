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
    static let headerSize = messageNumberSize + dhPublicKeySize + otpkIdSize  // 40 bytes

    // MARK: - Encode

    /// Pack EncryptedMessageComponents into a single opaque Data blob.
    static func encode(_ components: MessageCryptoService.EncryptedMessageComponents) throws -> Data {
        guard components.ephemeralPublicKey.count == dhPublicKeySize else {
            throw WirePayloadError.invalidDHPublicKey
        }
        guard let sealedBox = Data(base64Encoded: components.content) else {
            throw WirePayloadError.invalidBase64Content
        }

        var payload = Data(capacity: headerSize + sealedBox.count)

        // 4 bytes: message_number (LE)
        var msgNum = components.messageNumber.littleEndian
        withUnsafeBytes(of: &msgNum) { payload.append(contentsOf: $0) }

        // 32 bytes: dh_public_key
        payload.append(contentsOf: components.ephemeralPublicKey)

        // 4 bytes: one_time_prekey_id (LE); 0 = no OTPK used
        var otpkId = components.oneTimePreKeyId.littleEndian
        withUnsafeBytes(of: &otpkId) { payload.append(contentsOf: $0) }

        // rest: nonce || ciphertext || auth_tag
        payload.append(sealedBox)

        return payload
    }

    // MARK: - Decode

    struct DecodedPayload {
        let messageNumber: UInt32
        let ephemeralPublicKey: [UInt8]   // 32 bytes
        let oneTimePreKeyId: UInt32       // 0 = no OTPK
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

        let sealedBoxData = data[headerSize...]
        let content = sealedBoxData.base64EncodedString()

        return DecodedPayload(
            messageNumber: messageNumber,
            ephemeralPublicKey: ephemeralPublicKey,
            oneTimePreKeyId: oneTimePreKeyId,
            content: content
        )
    }
}

// MARK: - Errors

enum WirePayloadError: Error, LocalizedError {
    case invalidDHPublicKey
    case invalidBase64Content
    case payloadTooShort(Int)

    var errorDescription: String? {
        switch self {
        case .invalidDHPublicKey:
            return "DH public key must be exactly 32 bytes"
        case .invalidBase64Content:
            return "Content is not valid Base64"
        case .payloadTooShort(let size):
            return "Payload too short: \(size) bytes (minimum \(WirePayloadCoder.headerSize + 1))"
        }
    }
}
