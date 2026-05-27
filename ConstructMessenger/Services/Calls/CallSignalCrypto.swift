//
//  CallSignalCrypto.swift
//  Construct Messenger
//
//  End-to-end encryption for WebRTC signaling fields.
//
//  The gRPC/TLS transport already protects data in transit, but the
//  signaling server can see plaintext SDP and ICE candidates, which
//  contain DTLS fingerprints and IP addresses. This service encrypts
//  those fields using the existing Double Ratchet session so the server
//  sees only ciphertext.
//
//  Format (v2): encrypted fields are prefixed with "ENC:v2:" followed by
//  a single base64-encoded binary frame: [4 bytes msgNum LE][32 bytes epk][ciphertext].
//  v1 ("ENC:v1:" + base64(JSON)) is still decoded for backward compatibility.
//  Plaintext values (no prefix) are passed through unchanged.
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

// MARK: - Service

/// Encrypts/decrypts individual WebRTC signaling string fields (SDP, ICE candidate)
/// using the peer's Double Ratchet session via CryptoManager.
final class CallSignalCrypto {
    static let shared = CallSignalCrypto()
    private init() {}

    private static let v2Prefix = "ENC:v2:"
    private static let v1Prefix = "ENC:v1:"

    // MARK: Encrypt

    /// Encrypt a signaling field for a peer.
    /// Returns a prefixed ciphertext string safe to embed in any proto String field.
    /// Throws if there is no established E2E session with the peer.
    func encryptField(_ plaintext: String, for peerUserId: String) throws -> String {
        do {
            let components = try CryptoManager.shared.encryptMessage(plaintext, for: peerUserId)
            var frame = Data(capacity: 4 + 32 + components.content.count)
            var msgNumLE = components.messageNumber.littleEndian
            withUnsafeBytes(of: &msgNumLE) { frame.append(contentsOf: $0) }
            frame.append(contentsOf: components.ephemeralPublicKey)
            frame.append(components.content)
            return Self.v2Prefix + frame.base64EncodedString()
        } catch CryptoManagerError.sessionNotFound {
            throw CallSignalCryptoError.missingSession(peerUserId: peerUserId)
        }
    }

    // MARK: Decrypt

    /// Decrypt a signaling field from a peer.
    /// If the value is not prefixed, returns it unchanged (plaintext passthrough).
    func decryptField(_ value: String, from peerUserId: String) throws -> String {
        if value.hasPrefix(Self.v2Prefix) {
            return try decryptV2(String(value.dropFirst(Self.v2Prefix.count)), from: peerUserId)
        } else if value.hasPrefix(Self.v1Prefix) {
            return try decryptV1(String(value.dropFirst(Self.v1Prefix.count)), from: peerUserId)
        } else {
            Log.info("Received unencrypted signal field from \(peerUserId.prefix(8))… — legacy or plaintext mode", category: "Calls")
            return value
        }
    }

    /// Returns true if the value was encrypted by this layer.
    func isEncrypted(_ value: String) -> Bool {
        value.hasPrefix(Self.v2Prefix) || value.hasPrefix(Self.v1Prefix)
    }

    // MARK: - Private

    private func decryptV2(_ b64: String, from peerUserId: String) throws -> String {
        guard let frame = Data(base64Encoded: b64), frame.count > 36 else {
            throw CallSignalCryptoError.invalidEnvelope
        }
        let msgNum = frame.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self).littleEndian }
        let epk = frame[4..<36]
        let content = frame[36...]
        return try CryptoManager.shared.decryptRawComponents(
            contactId: peerUserId,
            ephemeralPublicKey: epk,
            messageNumber: msgNum,
            content: content
        )
    }

    private func decryptV1(_ b64: String, from peerUserId: String) throws -> String {
        guard let json = Data(base64Encoded: b64) else {
            throw CallSignalCryptoError.invalidEnvelope
        }
        struct V1Envelope: Decodable { let epk: String; let n: UInt32; let c: String }
        guard let envelope = try? JSONDecoder().decode(V1Envelope.self, from: json),
              let epkData = Data(base64Encoded: envelope.epk),
              let cipherData = Data(base64Encoded: envelope.c) else {
            throw CallSignalCryptoError.invalidEnvelope
        }
        return try CryptoManager.shared.decryptRawComponents(
            contactId: peerUserId,
            ephemeralPublicKey: epkData,
            messageNumber: envelope.n,
            content: cipherData
        )
    }
}
