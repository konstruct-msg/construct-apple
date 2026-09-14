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

    /// Whether a usable token-encryption key is cached. Callers peek this BEFORE consuming
    /// a wallet token so they never spend one on a send that could not seal it (an
    /// unsealable token is `decrypt_failed` server-side — fatal under enforce).
    func hasTokenEncryptionKey() -> Bool {
        tokenEncryptionKey() != nil
    }

    /// Encrypts `plaintext` as a sealed box to the server's token-encryption key.
    /// Returns the ciphertext (ephemeralPub‖nonce‖ciphertext‖tag), or `nil` if the key is
    /// unavailable / sealing fails. **Never returns unsealed plaintext**: the server opens
    /// `token_bytes` as an X25519 sealed box, so raw bytes would always fail redemption
    /// (`decrypt_failed`). `nil` tells the caller to send WITHOUT a token instead —
    /// anonymity is intact (cert seal is independent), only anti-abuse degrades.
    func sealTokenBytes(_ plaintext: Data) -> Data? {
        guard let serverKey = tokenEncryptionKey() else { return nil }
        do {
            // The core seals it. This file carried its own X25519+ChaChaPoly box until
            // 2026-08-27, under a doc comment in `crypto/privacy_pass/mod.rs` promising the core
            // "matches iOS `ServerKeyManager.sealBox` and construct-server's
            // `privacy_pass::open_sealed_token_bytes`" — one comment naming three implementations
            // of one format, none of which was ever checked against another.
            return Data(try ppSealTokenBytes(
                token: [UInt8](plaintext),
                serverEncryptionKey: [UInt8](serverKey.rawRepresentation)
            ))
        } catch {
            Log.error("ServerKeyManager: token seal failed — sending token-less: \(error)", category: "Stealth")
            return nil
        }
    }

    /// Cache the token-encryption key delivered over the authenticated gRPC channel
    /// (`GetSenderCertificateResponse.token_encryption_key`). This is the robust path —
    /// it reuses the working gRPC transport instead of the HTTP well-known, which can fail
    /// on the device (self-signed native/VEIL listener + ATS, DPI). Ignores empty / non-32B.
    /// Also stamps the fetch time so the HTTP `prefetch()` TTL gate won't redundantly refetch.
    func cacheFromGRPC(_ raw: Data) {
        guard raw.count == 32 else { return }
        UserDefaults.standard.set(raw, forKey: Self.cacheKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.cacheAgeKey)
        Log.info("ServerKeyManager: token encryption key cached via gRPC (32B)", category: "Stealth")
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

    // The sealed box itself is gone — `crypto::privacy_pass::pp_seal_token_bytes` is the one
    // implementation, and `TokenSealDifferentialTests` is the record that the two agreed at the
    // moment the second was deleted: one opener, written from the format rather than from either
    // sealer, read both.
    //
    // Format, for anyone reading a capture: ephemeralPub(32) ‖ nonce(12) ‖ ciphertext ‖ tag(16),
    // key = HKDF-SHA256(ikm: X25519(eph, server), salt: ∅, info: "construct-token-seal-v1").
    // The authority is construct-protos/conformance/knst_token_seal.json.
}
