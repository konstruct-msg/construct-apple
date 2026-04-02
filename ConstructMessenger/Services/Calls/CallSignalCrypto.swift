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
//  Format: encrypted fields are prefixed with "ENC:v1:" followed by
//  a base64-encoded JSON envelope. Plaintext values (no prefix) are
//  passed through unchanged for backward compatibility.
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

// MARK: - Envelope

private struct SignalFieldEnvelope: Codable {
    /// Base64-encoded ephemeral public key from Double Ratchet.
    let epk: String
    /// DR message counter.
    let n: UInt32
    /// Padded ciphertext produced by OrchestratorCore.encryptMessage.
    let c: String
}

// MARK: - Service

/// Encrypts/decrypts individual WebRTC signaling string fields (SDP, ICE candidate)
/// using the peer's Double Ratchet session via CryptoManager.
final class CallSignalCrypto {
    static let shared = CallSignalCrypto()
    private init() {}

    private static let encryptedPrefix = "ENC:v1:"

    // MARK: Encrypt

    /// Encrypt a signaling field for a peer.
    /// Returns a prefixed ciphertext string safe to embed in any proto String field.
    /// Throws if there is no established E2E session with the peer.
    func encryptField(_ plaintext: String, for peerUserId: String) throws -> String {
        do {
            let components = try CryptoManager.shared.encryptMessage(plaintext, for: peerUserId)
            let envelope = SignalFieldEnvelope(
                epk: components.ephemeralPublicKey.base64EncodedString(),
                n: components.messageNumber,
                c: components.content.base64EncodedString()
            )
            let json = try JSONEncoder().encode(envelope)
            return Self.encryptedPrefix + json.base64EncodedString()
        } catch CryptoManagerError.sessionNotFound {
            throw CallSignalCryptoError.missingSession(peerUserId: peerUserId)
        }
    }

    // MARK: Decrypt

    /// Decrypt a signaling field from a peer.
    /// If the value is not prefixed, returns it unchanged (plaintext passthrough).
    func decryptField(_ value: String, from peerUserId: String) throws -> String {
        guard value.hasPrefix(Self.encryptedPrefix) else {
            Log.info("📞 Received unencrypted signal field from \(peerUserId.prefix(8))… — legacy or plaintext mode", category: "Calls")
            return value
        }
        let b64 = String(value.dropFirst(Self.encryptedPrefix.count))
        guard let json = Data(base64Encoded: b64) else {
            throw CallSignalCryptoError.invalidEnvelope
        }
        let envelope: SignalFieldEnvelope
        do {
            envelope = try JSONDecoder().decode(SignalFieldEnvelope.self, from: json)
        } catch {
            throw CallSignalCryptoError.invalidEnvelope
        }
        guard let epkData = Data(base64Encoded: envelope.epk) else {
            throw CallSignalCryptoError.invalidEnvelope
        }
        return try CryptoManager.shared.decryptRawComponents(
            contactId: peerUserId,
            ephemeralPublicKey: epkData,
            messageNumber: envelope.n,
            content: envelope.c
        )
    }

    /// Returns true if the value was encrypted by this layer.
    func isEncrypted(_ value: String) -> Bool {
        value.hasPrefix(Self.encryptedPrefix)
    }
}
