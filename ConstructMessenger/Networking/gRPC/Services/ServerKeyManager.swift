//
//  ServerKeyManager.swift
//  Construct Messenger
//
//  Fetches and caches the server's static X25519 token-encryption public key
//  from /.well-known/construct-server. Clients use this key to encrypt
//  Privacy Pass token_bytes before including them in SealedInner, so that
//  relay operators cannot read tokens in transit (ICE ghost-mode protection).
//
//  Key lifecycle:
//   - Fetched once at app launch, cached in UserDefaults
//   - Re-fetched on successful gRPC auth (server may rotate key at deploy time)
//   - Cache TTL: 24h (key rotations are rare — derived from signing key seed)
//

import CryptoKit
import Foundation

actor ServerKeyManager {
    static let shared = ServerKeyManager()
    private init() {}

    private static let cacheKey    = "construct.server.token_enc_pub"
    private static let cacheAgeKey = "construct.server.token_enc_pub.fetched_at"
    private static let cacheTTL: TimeInterval = 24 * 3600

    // MARK: - Public API

    /// Returns the cached X25519 public key for token encryption, or nil if unavailable.
    /// Call `prefetch()` at app launch to warm the cache.
    func tokenEncryptionKey() -> Curve25519.KeyAgreement.PublicKey? {
        guard let data = UserDefaults.standard.data(forKey: Self.cacheKey),
              data.count == 32 else { return nil }
        return try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: data)
    }

    /// Encrypts `plaintext` as a NaCl sealed box to the server's token encryption key.
    /// Returns the ciphertext (ephemeralPub‖nonce‖ciphertext‖tag) or `plaintext` unchanged
    /// if the server key is unavailable (graceful degradation — relay can still see token,
    /// which is acceptable during the transition period before the key is fetched).
    func sealTokenBytes(_ plaintext: Data) -> Data {
        guard let serverKey = tokenEncryptionKey() else { return plaintext }
        do {
            return try sealBox(plaintext, to: serverKey)
        } catch {
            Log.error("ServerKeyManager: token seal failed — using plaintext fallback: \(error)", category: "Stealth")
            return plaintext
        }
    }

    /// Fetch the token encryption key from the server if the cache is stale or missing.
    func prefetch() async {
        let fetchedAt = UserDefaults.standard.double(forKey: Self.cacheAgeKey)
        let age = Date().timeIntervalSince1970 - fetchedAt
        guard age > Self.cacheTTL || UserDefaults.standard.data(forKey: Self.cacheKey) == nil else {
            return
        }
        await fetchAndCache()
    }

    // MARK: - Fetch

    private func fetchAndCache() async {
        let host = GRPCChannelManager.shared.currentHost
        let urlString = "https://\(host)/.well-known/construct-server"
        guard let url = URL(string: urlString) else { return }

        do {
            var request = URLRequest(url: url, timeoutInterval: 10)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                Log.debug("ServerKeyManager: token_encryption_key missing or invalid in well-known", category: "Stealth")
                return
            }
            let rootKey = json["token_encryption_key"] as? String
            let serverSection = json["server"] as? [String: Any]
            let serverKey = serverSection?["token_encryption_key"] as? String
            guard let keyB64 = rootKey ?? serverKey,
                  let keyData = Data(base64Encoded: keyB64),
                  keyData.count == 32 else {
                Log.debug("ServerKeyManager: token_encryption_key missing or invalid in well-known", category: "Stealth")
                return
            }

            UserDefaults.standard.set(keyData, forKey: Self.cacheKey)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.cacheAgeKey)
            Log.info("ServerKeyManager: token encryption key cached (\(keyData.count)B)", category: "Stealth")
        } catch {
            Log.debug("ServerKeyManager: well-known fetch failed: \(error)", category: "Stealth")
        }
    }

    // MARK: - Sealed box (X25519 + ChaChaPoly)
    //
    // Format: ephemeralPub(32) ‖ nonce(12) ‖ ciphertext ‖ tag(16)
    // Nonce is random per message (ChaChaPoly.seal generates it).
    //
    // Server decryption (Phase 2.1, future):
    //   let shared = try serverPrivKey.sharedSecretFromKeyAgreement(with: ephemeralPub)
    //   let symKey = shared.hkdfDerivedSymmetricKey(SHA256, salt: Data(), info: "construct-token-seal-v1", count: 32)
    //   let plaintext = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: nonce+ct+tag), using: symKey)

    private func sealBox(_ plaintext: Data, to recipientPub: Curve25519.KeyAgreement.PublicKey) throws -> Data {
        let ephemeralPriv = Curve25519.KeyAgreement.PrivateKey()
        let sharedSecret = try ephemeralPriv.sharedSecretFromKeyAgreement(with: recipientPub)
        let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: Data("construct-token-seal-v1".utf8),
            outputByteCount: 32
        )
        let sealedBox = try ChaChaPoly.seal(plaintext, using: symmetricKey)
        // Pack: ephemeral_pub(32) ‖ nonce(12) ‖ ciphertext ‖ tag(16)
        let nonce = sealedBox.nonce.withUnsafeBytes { Data($0) }
        var out = Data(capacity: 32 + 12 + sealedBox.ciphertext.count + 16)
        out.append(ephemeralPriv.publicKey.rawRepresentation)
        out.append(nonce)
        out.append(sealedBox.ciphertext)
        out.append(sealedBox.tag)
        return out
    }
}
