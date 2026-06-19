//
//  StealthSenderService.swift
//  Construct Messenger
//
//  ConstructSEALED: sealed sender — hides sender identity from the server.
//  Analogous to Signal's Sealed Sender but without phone numbers.
//
//  Send:  seal(certBytes, recipientIdentityKey) → box
//  Recv:  unseal(sealedInner, ourIdentityPrivKey) → SenderCertificate
//  Verify: Ed25519 signature against bundle_signing_key from well-known
//

import Foundation
import CryptoKit
import SwiftProtobuf
import Observation

@Observable
@MainActor
final class StealthSenderService {
    static let shared = StealthSenderService()

    // Cache key in UserDefaults
    private static let certCacheKey = "construct.sealed_sender_cert"
    private static let certExpiryKey = "construct.sealed_sender_cert_expiry"

    private init() {}

    // MARK: - Sender Certificate (from auth-service)

    /// Returns cached cert bytes, or fetches a fresh one from auth-service.
    func getSenderCertificate() async throws -> Data {
        // Return cached cert if still valid (with 5-min leeway)
        if let cached = loadCachedCert() {
            return cached
        }
        let response = try await AuthServiceClient.shared.getSenderCertificate()
        cacheCert(response.certificate, expiresAt: response.expiresAt)
        return response.certificate
    }

    private func loadCachedCert() -> Data? {
        guard
            let data = UserDefaults.standard.data(forKey: Self.certCacheKey),
            let expiry = UserDefaults.standard.object(forKey: Self.certExpiryKey) as? Double,
            Date().timeIntervalSince1970 < expiry - 300 // 5-min leeway
        else { return nil }
        return data
    }

    private func cacheCert(_ cert: Data, expiresAt: Int64) {
        UserDefaults.standard.set(cert, forKey: Self.certCacheKey)
        UserDefaults.standard.set(Double(expiresAt), forKey: Self.certExpiryKey)
    }

    /// Call when logging out / identity changes.
    func clearCertCache() {
        UserDefaults.standard.removeObject(forKey: Self.certCacheKey)
        UserDefaults.standard.removeObject(forKey: Self.certExpiryKey)
    }

    // MARK: - Seal (send path)

    /// Encrypts `certBytes` (serialized SenderCertificate proto) to the recipient's
    /// X25519 identity key. Returns the sealed box:
    ///   ephemeral_pub(32) || nonce(12) || ciphertext || tag(16)
    func sealSenderCert(_ certBytes: Data, recipientIdentityKey: Data) throws -> Data {
        let ephemeralPrivKey = Curve25519.KeyAgreement.PrivateKey()
        let recipientPubKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientIdentityKey)
        let sharedSecret = try ephemeralPrivKey.sharedSecretFromKeyAgreement(with: recipientPubKey)
        let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("ConstructSEALED-v1".utf8),
            sharedInfo: Data(),
            outputByteCount: 32
        )
        let sealedBox = try ChaChaPoly.seal(certBytes, using: symmetricKey)
        let nonce = sealedBox.nonce.withUnsafeBytes { Data($0) }
        var box = Data(capacity: 32 + 12 + sealedBox.ciphertext.count + 16)
        box.append(ephemeralPrivKey.publicKey.rawRepresentation)
        box.append(nonce)
        box.append(sealedBox.ciphertext)
        box.append(sealedBox.tag)
        return box
    }

    // MARK: - Unseal (receive path)

    /// Decrypts `sealedBox` using our X25519 identity private key.
    /// Returns the decoded SenderCertificate proto.
    func unsealSenderCert(
        _ sealedBox: Data,
        ourIdentityPrivKeyBytes: Data
    ) throws -> Shared_Proto_Core_V1_SenderCertificate {
        guard sealedBox.count >= 32 + 12 + 16 else {
            throw StealthError.invalidBoxLength
        }
        let epPubBytes = sealedBox[..<32]
        let nonceBytes = sealedBox[32..<44]
        let ciphertextAndTag = sealedBox[44...]
        guard ciphertextAndTag.count >= 16 else {
            throw StealthError.invalidBoxLength
        }
        let ciphertext = ciphertextAndTag.dropLast(16)
        let tag = ciphertextAndTag.suffix(16)

        let ourPrivKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: ourIdentityPrivKeyBytes)
        let epPubKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: epPubBytes)
        let sharedSecret = try ourPrivKey.sharedSecretFromKeyAgreement(with: epPubKey)
        let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("ConstructSEALED-v1".utf8),
            sharedInfo: Data(),
            outputByteCount: 32
        )
        let nonce = try ChaChaPoly.Nonce(data: nonceBytes)
        let box = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        let certBytes = try ChaChaPoly.open(box, using: symmetricKey)
        return try Shared_Proto_Core_V1_SenderCertificate(serializedBytes: certBytes)
    }

    // MARK: - Verify

    /// Verifies the server Ed25519 signature on a SenderCertificate.
    /// Uses the `bundle_signing_key` cached from /.well-known/construct-server.
    func verifyCert(_ cert: Shared_Proto_Core_V1_SenderCertificate) -> Bool {
        guard
            let serverPubKeyData = UserDefaults.standard.data(forKey: VeilCertFetcher.cachedBundleSigningKeyKey),
            !cert.serverSignature.isEmpty
        else { return false }

        // Reconstruct the signed payload (must match auth-service signing format)
        var payload = Data()
        payload.append(contentsOf: cert.senderUserID.utf8)
        payload.append(UInt8(ascii: ":"))
        payload.append(contentsOf: cert.senderDomain.utf8)
        payload.append(UInt8(ascii: ":"))
        payload.append(cert.senderIdentityKey)
        payload.append(UInt8(ascii: ":"))
        payload.append(contentsOf: cert.senderDeviceID.utf8)
        payload.append(UInt8(ascii: ":"))
        payload.append(contentsOf: String(cert.issuedAt).utf8)
        payload.append(UInt8(ascii: ":"))
        payload.append(contentsOf: String(cert.expiresAt).utf8)

        do {
            let pubKey = try Curve25519.Signing.PublicKey(rawRepresentation: serverPubKeyData)
            return pubKey.isValidSignature(cert.serverSignature, for: payload)
        } catch {
            Log.error("StealthSenderService: failed to create server pub key: \(error)", category: "Stealth")
            return false
        }
    }

    // MARK: - Resolve sender (receive path, full pipeline)

    /// Decrypts SealedInner bytes to recover sender user ID.
    /// Returns nil if decryption or verification fails (should trigger unseal error handling).
    func resolveSender(sealedInnerBytes: Data) -> String? {
        guard let ourPrivKeyBytes = KeychainManager.shared.loadDeviceIdentityKey() else {
            Log.error("Stealth: no identity key in Keychain", category: "Stealth")
            return nil
        }
        do {
            let sealedInner = try Shared_Proto_Core_V1_SealedInner(serializedBytes: sealedInnerBytes)
            guard !sealedInner.senderCertCiphertext.isEmpty else { return nil }
            let cert = try unsealSenderCert(sealedInner.senderCertCiphertext, ourIdentityPrivKeyBytes: ourPrivKeyBytes)

            // Reject expired certificates
            let now = Int64(Date().timeIntervalSince1970)
            guard cert.expiresAt > now else {
                Log.info("Stealth: received expired sender cert (expired \(cert.expiresAt - now)s ago)", category: "Stealth")
                return nil
            }

            guard verifyCert(cert) else {
                Log.error("Stealth: sender cert signature invalid for \(cert.senderUserID.prefix(8))…", category: "Stealth")
                return nil
            }

            Log.debug("Stealth: resolved sender \(cert.senderUserID.prefix(8))…", category: "Stealth")
            return cert.senderUserID
        } catch {
            Log.error("Stealth: unseal failed: \(error)", category: "Stealth")
            return nil
        }
    }

    // MARK: - Build SealedInner for sending

    /// Builds SealedInner proto bytes for a sealed sender message.
    func buildSealedInner(
        recipientUserId: String,
        certBytes: Data,
        recipientIdentityKey: Data,
        encryptedPayload: Data
    ) async throws -> Data {
        let sealedCert = try sealSenderCert(certBytes, recipientIdentityKey: recipientIdentityKey)
        var inner = Shared_Proto_Core_V1_SealedInner()
        inner.recipientUserID = recipientUserId
        inner.senderCertCiphertext = sealedCert
        inner.encryptedPayload = encryptedPayload
        inner.deliveryTag = Data((0..<32).map { _ in UInt8.random(in: 0...255) })

        // Ask StealthPolicy whether we should attach a token.
        // - When stealth is disabled → no token (and caller shouldn't even call this method).
        // - Per-message → attach token every time.
        // - Per-stream → attach at most once per recipient per day.
        // The SealedInner certificate (hiding the sender) is still built by the caller
        // whenever stealth is enabled.
        if let token = StealthPolicy.shared.consumeTokenIfNeeded(for: recipientUserId) {
            inner.tokenNonce = token.nonce
            // Encrypt token_bytes to the server's X25519 key so relay operators cannot
            // read the spent token. Falls back to plaintext if key is not yet cached.
            inner.tokenBytes = await ServerKeyManager.shared.sealTokenBytes(token.token)
        }

        return try inner.serializedData()
    }

    /// Static bridge for calling from non-MainActor contexts (e.g. ChunkedMessageSender).
    /// getSenderCertificate() already handles caching; we just hop to MainActor for the async call.
    static func buildSealedInner(
        recipientUserId: String,
        recipientIdentityKey: Data,
        encryptedPayload: Data
    ) async throws -> Data {
        // getSenderCertificate is @MainActor async — call it directly (will hop automatically)
        let certBytes = try await StealthSenderService.shared.getSenderCertificate()
        return try await StealthSenderService.shared.buildSealedInner(
            recipientUserId: recipientUserId,
            certBytes: certBytes,
            recipientIdentityKey: recipientIdentityKey,
            encryptedPayload: encryptedPayload
        )
    }
}

enum StealthError: Error {
    case invalidBoxLength
    case decryptionFailed
    case invalidCertificate
    case expired
}
