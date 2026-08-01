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
import CoreData
import CryptoKit
import SwiftProtobuf
import Observation

/// Opens a ConstructSEALED envelope, recovering the real sender and content type.
///
/// A protocol (rather than a direct `StealthSenderService.shared` call) so the unseal boundary
/// in `MessageRouter` is an explicit, substitutable dependency — that boundary is where
/// `f39e03b4` silently dropped every sealed control message, undetected because no test could
/// reach it. See client/ios/SEALED_CONTROL_CHANNEL_REMEDIATION.md.
@MainActor
protocol SealedSenderResolving {
    func resolveSender(sealedInnerBytes: Data) -> ResolvedSender?
}

@Observable
@MainActor
final class StealthSenderService: SealedSenderResolving {
    static let shared = StealthSenderService()

    // Cache key in UserDefaults
    private static let certCacheKey = "construct.sealed_sender_cert"
    private static let certExpiryKey = "construct.sealed_sender_cert_expiry"
    /// The `currentUserId` the cached cert was issued for. The cert embeds a server-attested
    /// `senderUserID`; if the local identity changes (delete account → re-register) without the
    /// cache being cleared, a stale cert would keep sealing outgoing messages under the OLD user
    /// id — recipients then attribute them to a "ghost" identity and they never reach the new
    /// chat (the 2026-07-26 emulator→device failure). Binding the cache to its owner makes a
    /// mismatched cert self-invalidate regardless of whether `clearCertCache()` was called.
    private static let certOwnerKey = "construct.sealed_sender_cert_owner"

    private init() {}

    // MARK: - Sender Certificate (from auth-service)

    /// Returns cached cert bytes, or fetches a fresh one from auth-service.
    /// stealth-sealed-sender-v2 Phase 4: sealed sending is always on now, so this fetch
    /// sits on every message's hot path once the cache expires — bounded retry with
    /// backoff covers transient network failures instead of failing the send on the
    /// first hiccup.
    func getSenderCertificate() async throws -> Data {
        // Return cached cert if still valid (with 5-min leeway)
        if let cached = loadCachedCert() {
            return cached
        }
        let response = try await withRetry(maxAttempts: 3, backoff: 0.5, label: "getSenderCertificate") {
            try await AuthServiceClient.shared.getSenderCertificate()
        }
        cacheCert(response.certificate, expiresAt: response.expiresAt)
        // Piggyback: the server delivers its X25519 token-encryption key alongside the cert
        // (same authenticated gRPC channel, same 24h lifecycle). This is the robust source
        // for the seal key — the HTTP well-known can fail on-device (self-signed native/VEIL
        // listener + ATS), leaving the client unable to seal tokens → decrypt_failed.
        if !response.tokenEncryptionKey.isEmpty {
            await ServerKeyManager.shared.cacheFromGRPC(response.tokenEncryptionKey)
        }
        return response.certificate
    }

    private func loadCachedCert() -> Data? {
        guard
            let data = UserDefaults.standard.data(forKey: Self.certCacheKey),
            let expiry = UserDefaults.standard.object(forKey: Self.certExpiryKey) as? Double,
            Date().timeIntervalSince1970 < expiry - 300 // 5-min leeway
        else { return nil }
        // Identity binding: reject a cert cached under a DIFFERENT user id (stale after a
        // delete-account → re-register without clearCertCache). Sealing with it would attribute
        // our messages to the old "ghost" identity. A nil/empty owner means legacy cache written
        // before this key existed — treat as stale and refetch (cheap, once).
        let owner = UserDefaults.standard.string(forKey: Self.certOwnerKey)
        guard let owner, !owner.isEmpty, owner == AuthSessionManager.shared.currentUserId else {
            Log.info("Stealth: discarding cached sender cert — owner \(owner?.prefix(8).description ?? "nil") ≠ current \(AuthSessionManager.shared.currentUserId?.prefix(8).description ?? "nil"); refetching", category: "Stealth")
            return nil
        }
        return data
    }

    private func cacheCert(_ cert: Data, expiresAt: Int64) {
        UserDefaults.standard.set(cert, forKey: Self.certCacheKey)
        UserDefaults.standard.set(Double(expiresAt), forKey: Self.certExpiryKey)
        UserDefaults.standard.set(AuthSessionManager.shared.currentUserId, forKey: Self.certOwnerKey)
    }

    /// Call when logging out / identity changes (delete account, re-register, local reset).
    func clearCertCache() {
        UserDefaults.standard.removeObject(forKey: Self.certCacheKey)
        UserDefaults.standard.removeObject(forKey: Self.certExpiryKey)
        UserDefaults.standard.removeObject(forKey: Self.certOwnerKey)
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

    // MARK: - Verify / attest

    /// The trusted bundle-signing keys, in preference order: the key fetched from
    /// `/.well-known/construct-server` (if present), followed by the build-time pins
    /// (`VEILConfig.pinnedBundleSigningKeys`). sealed-sender-resilience lever B — the
    /// pins guarantee a sealed receive can be attested even when the fetched key was
    /// never cached (e.g. VEIL inactive, the 2026-07-05 incident) or after a rotation.
    private func trustedBundleKeys() -> [Curve25519.Signing.PublicKey] {
        var raw: [Data] = []
        if let fetched = UserDefaults.standard.data(forKey: VeilCertFetcher.cachedBundleSigningKeyKey) {
            raw.append(fetched)
        }
        for b64 in VEILConfig.pinnedBundleSigningKeys {
            if let d = Data(base64Encoded: b64) { raw.append(d) }
        }
        #if DEBUG
        raw.append(contentsOf: extraTrustedBundleKeysForTesting)
        #endif
        return raw.compactMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }
    }

    #if DEBUG
    /// Test seam: additional trusted bundle keys (raw 32-byte) injected by unit tests to
    /// exercise the pin/rotation path without shipping a private key for a real pin.
    /// Empty in production paths.
    var extraTrustedBundleKeysForTesting: [Data] = []
    #endif

    /// Checks the server Ed25519 signature on a SenderCertificate against every trusted
    /// bundle key. Canonical (and only) payload format — stealth-sealed-sender-v2 Phase 3:
    /// direct concatenation, no separators, issued_at/expires_at as big-endian i64 bytes.
    /// Must match identity-service::get_sender_certificate's sign_payload exactly.
    /// Returns a *reason* rather than a bare Bool so the caller can tell "no key to check
    /// with" apart from "signature genuinely bad" (the old code conflated them, which is
    /// why the 2026-07-05 nil-key failure was mislogged as `signature invalid`).
    func attestSignature(_ cert: Shared_Proto_Core_V1_SenderCertificate) -> SenderTrust {
        guard !cert.serverSignature.isEmpty else { return .unvouched(.badSignature) }
        let keys = trustedBundleKeys()
        guard !keys.isEmpty else { return .unvouched(.noKey) }

        let payload = Self.buildCertPayload(userID: cert.senderUserID, domain: cert.senderDomain, ik: cert.senderIdentityKey, deviceID: cert.senderDeviceID, issued: cert.issuedAt, expires: cert.expiresAt)
        let ok = keys.contains { $0.isValidSignature(cert.serverSignature, for: payload) }
        return ok ? .vouched(.signature) : .unvouched(.badSignature)
    }

    #if DEBUG
    /// Test seam: overrides the KT-verified-identity lookup so unit tests exercise the KT
    /// cross-check without a Core Data stack. `nil` (default) uses the real `User` store.
    var ktLookupOverrideForTesting: ((String) -> (key: Data, status: KTStatus)?)?
    #endif

    /// The recipient's locally stored, previously-KT-verified identity key for `userId`
    /// (plus its status), read from the `User` Core Data record. `nil` for a first contact
    /// (no bundle fetched / verified yet). sealed-sender-resilience lever C source.
    private func ktVerifiedIdentity(for userId: String) -> (key: Data, status: KTStatus)? {
        #if DEBUG
        if let override = ktLookupOverrideForTesting { return override(userId) }
        #endif
        let ctx = PersistenceController.shared.container.viewContext
        let req = User.fetchRequest()
        req.predicate = NSPredicate(format: "id == %@", userId)
        req.fetchLimit = 1
        guard let user = try? ctx.fetch(req).first, let key = user.knownIdentityKey else { return nil }
        return (key, user.ktStatus)
    }

    /// The full attestation verdict for an unsealed certificate. Never gates delivery —
    /// only labels trust. Ladder, strongest-first (sealed-sender-resilience §2 lever C):
    ///  1. Expiry: an expired cert is `.unvouched(.expired)` regardless of KT match — the
    ///     cert TTL bounds replay of an old sealed message (delivery still proceeds).
    ///  2. KT: cert identity key == our KT-`.verified` `knownIdentityKey` for the sender →
    ///     `.vouched(.kt)`, no bundle key involved at all. A `.keyChanged`/`.failed`/
    ///     `.unverified` status does NOT vouch even on a key match (that is exactly the
    ///     MITM-suspicion case KT exists to catch).
    ///  3. Signature (lever B): fall back to the bundle-key check for a first contact.
    func attest(_ cert: Shared_Proto_Core_V1_SenderCertificate) -> SenderTrust {
        let now = Int64(Date().timeIntervalSince1970)
        if cert.expiresAt <= now { return .unvouched(.expired) }

        if let kt = ktVerifiedIdentity(for: cert.senderUserID),
           kt.status == .verified,
           kt.key == cert.senderIdentityKey {
            return .vouched(.kt)
        }

        return attestSignature(cert)
    }

    static func buildCertPayload(userID: String, domain: String, ik: Data, deviceID: String, issued: Int64, expires: Int64) -> Data {
        var p = Data()
        p.append(contentsOf: userID.utf8)
        p.append(contentsOf: domain.utf8)
        p.append(ik)
        p.append(contentsOf: deviceID.utf8)
        p.append(bigEndian64(issued))
        p.append(bigEndian64(expires))
        return p
    }

    private static func bigEndian64(_ value: Int64) -> Data {
        var v = value.bigEndian
        return Data(bytes: &v, count: 8)
    }

    // MARK: - Resolve sender (receive path, full pipeline)

    /// Decrypts SealedInner bytes to recover the sender user ID, the real content type
    /// carried inside SealedInner (stealth-sealed-sender-v2 Phase 3 — the outer
    /// Envelope.content_type is forced generic for sealed sends, so this is the only
    /// place the recipient can recover whether this was a message/receipt/call signal),
    /// and an attestation verdict.
    ///
    /// sealed-sender-resilience lever A: returns `nil` **only** when the sealed box
    /// itself cannot be opened (no sender/payload recoverable). An expired or
    /// unverifiable certificate is NOT a nil — the sender id and payload are already in
    /// hand, so the caller delivers the message `.unvouched` through the normal ratchet
    /// decrypt (which is the real authentication) instead of dropping it. The
    /// certificate is anti-abuse/anonymity metadata, not the security root.
    func resolveSender(sealedInnerBytes: Data) -> ResolvedSender? {
        guard let ourPrivKeyBytes = KeychainManager.shared.loadDeviceIdentityKey() else {
            Log.error("Stealth: no identity key in Keychain", category: "Stealth")
            return nil
        }
        let cert: Shared_Proto_Core_V1_SenderCertificate
        let contentType: UInt8
        do {
            let sealedInner = try Shared_Proto_Core_V1_SealedInner(serializedBytes: sealedInnerBytes)
            guard !sealedInner.senderCertCiphertext.isEmpty else { return nil }
            cert = try unsealSenderCert(sealedInner.senderCertCiphertext, ourIdentityPrivKeyBytes: ourPrivKeyBytes)
            contentType = UInt8(sealedInner.contentType.rawValue)
        } catch {
            // Unseal failed — genuinely unrecoverable (wrong key / corruption / not for us).
            Log.error("Stealth: unseal failed: \(error)", category: "Stealth")
            return nil
        }

        // Attestation (never gates delivery — only tags trust): expiry → KT → signature.
        let trust = attest(cert)
        switch trust {
        case .vouched(let basis):
            Log.debug("Stealth: resolved sender \(cert.senderUserID.prefix(8))… (vouched via \(basis))", category: "Stealth")
        case .unvouched(let reason):
            Log.info("Stealth: resolved sender \(cert.senderUserID.prefix(8))… UNVOUCHED (\(reason)) — delivering via ratchet", category: "Stealth")
        }
        return ResolvedSender(senderId: cert.senderUserID, contentType: contentType, trust: trust)
    }

    // MARK: - Build SealedInner for sending

    /// Builds SealedInner proto bytes for a sealed sender message.
    /// `contentType` travels inside SealedInner (not the outer Envelope, which stays
    /// generic for sealed sends) so the recipient can recover message/receipt/call-signal
    /// kind after unsealing — stealth-sealed-sender-v2 Phase 3.
    func buildSealedInner(
        recipientUserId: String,
        certBytes: Data,
        recipientIdentityKey: Data,
        encryptedPayload: Data,
        contentType: Shared_Proto_Core_V1_ContentType
    ) async throws -> Data {
        let sealedCert = try sealSenderCert(certBytes, recipientIdentityKey: recipientIdentityKey)
        var inner = Shared_Proto_Core_V1_SealedInner()
        inner.recipientUserID = recipientUserId
        inner.senderCertCiphertext = sealedCert
        inner.encryptedPayload = encryptedPayload
        inner.contentType = contentType
        inner.deliveryTag = Data((0..<32).map { _ in UInt8.random(in: 0...255) })

        // A token accompanies every sealed send (per-message — the only model compatible
        // with server-side enforce; per-stream removed 2026-07-15). `wantedToken` is
        // captured before consuming so "stealth disabled" is distinguishable from
        // "wallet empty" in the else-branch logging below.
        let wantedToken = StealthPolicy.shared.shouldConsumeToken()
        // Peek the server token-encryption key BEFORE consuming a wallet token. An
        // unsealable token is rejected server-side (`decrypt_failed`, fatal under enforce),
        // so if we cannot seal we must NOT spend the token — leave it in the wallet for a
        // later send once the key is cached (it arrives via GetSenderCertificateResponse).
        let canSeal = await ServerKeyManager.shared.hasTokenEncryptionKey()
        if canSeal,
           let token = StealthPolicy.shared.consumeTokenIfNeeded(),
           let sealedToken = await ServerKeyManager.shared.sealTokenBytes(token.token) {
            inner.tokenNonce = token.nonce
            // token_bytes sealed to the server's X25519 key so relay operators cannot read
            // the spent token (VEIL ghost-mode) and the server can redeem it.
            inner.tokenBytes = sealedToken
            // Positive-path visibility: confirms a token was actually attached (successful
            // consume was previously silent — the wallet could only be inferred, not seen).
            Log.info("Stealth: sealed send WITH token (wallet=\(TokenWalletService.shared.balance) left)", category: "Stealth")
        } else if wantedToken {
            // Policy wanted a token but we sent without one — seal + send anyway (the
            // certificate seal hides the sender regardless). Anti-abuse degraded, anonymity
            // intact — the invariant we deliberately preserve. Distinguish the two causes so
            // an on-device diagnosis is unambiguous:
            //   • server key not yet cached → cannot seal (kick a fetch so the next send seals)
            //   • wallet empty → issuance not keeping up
            PerformanceMetrics.shared.record(.stealthTokenlessSend, label: String(recipientUserId.prefix(8)))
            if !canSeal {
                Log.info("Stealth: sealed send WITHOUT token — server key not yet cached, cannot seal (would-be decrypt_failed avoided)", category: "Stealth")
                Task { await ServerKeyManager.shared.prefetch() }
            } else {
                Log.info("Stealth: sealed send WITHOUT token — wallet empty (anti-abuse degraded, anonymity intact)", category: "Stealth")
            }
        }

        // Reactive top-up: per-message scope drains the wallet steadily, so refill toward
        // the server hourly cap as we spend rather than waiting for foreground/background
        // triggers. No-op when the wallet is above the low-water mark or within cooldown.
        Task { await BlindTokenService.shared.topUpIfLow() }

        return try inner.serializedData()
    }

    /// Static bridge for calling from non-MainActor contexts (e.g. ChunkedMessageSender).
    /// getSenderCertificate() already handles caching; we just hop to MainActor for the async call.
    static func buildSealedInner(
        recipientUserId: String,
        recipientIdentityKey: Data,
        encryptedPayload: Data,
        contentType: Shared_Proto_Core_V1_ContentType
    ) async throws -> Data {
        // getSenderCertificate is @MainActor async — call it directly (will hop automatically)
        let certBytes = try await StealthSenderService.shared.getSenderCertificate()
        return try await StealthSenderService.shared.buildSealedInner(
            recipientUserId: recipientUserId,
            certBytes: certBytes,
            recipientIdentityKey: recipientIdentityKey,
            encryptedPayload: encryptedPayload,
            contentType: contentType
        )
    }

    /// Resolve the recipient's Curve25519 identity public key (for sealing) from the persisted `User`
    /// row, or nil if not known yet. Keyed strictly by `recipientId` so it is unambiguous from any
    /// send path (the shared source used by both the live-send and retry paths). Callers gate on
    /// `StealthPolicy.shared.shouldUseSealedSender()` and, when this returns nil under stealth-on,
    /// MUST queue rather than send identified (see `StealthDowngradeBlocked`). Call on `context`'s queue.
    static func recipientIdentityKey(recipientId: String, context: NSManagedObjectContext) -> Data? {
        let req = User.fetchRequest()
        req.predicate = NSPredicate(format: "id == %@", recipientId)
        req.fetchLimit = 1
        return (try? context.fetch(req))?.first?.knownIdentityKey
    }
}

enum StealthError: Error {
    case invalidBoxLength
    case decryptionFailed
    case invalidCertificate
    case expired
}

// MARK: - sealed-sender-resilience trust model

/// How a sealed sender's identity binding was attested.
///  - `.kt` (lever C): the cert's identity key matches the recipient's locally stored,
///    KT-`.verified` `knownIdentityKey` for that contact — the strongest verdict, with
///    zero dependency on any bundle key / well-known / landing.
///  - `.signature` (lever B): the cert's Ed25519 signature validated against a
///    fetched-or-pinned bundle key. Fallback used for first contact (no local KT key yet).
enum SenderVouchBasis: Equatable {
    case kt
    case signature
}

/// Why an attestation did not vouch. Delivery proceeds anyway (ratchet is the real
/// auth); the reason is only for DEBUG telemetry and self-healing (a `.noKey`/`.badSignature`
/// kicks a background bundle-key refresh).
enum SenderVouchReason: Equatable {
    case expired       // cert past its expires_at
    case badSignature  // signature did not validate against any trusted bundle key
    case noKey         // no usable bundle key at all (fetched nil AND pins unusable)
}

enum SenderTrust: Equatable {
    case vouched(SenderVouchBasis)
    case unvouched(SenderVouchReason)
}

/// Result of unsealing a ConstructSEALED message: the recovered sender + content type
/// plus the attestation verdict. Returned by `StealthSenderService.resolveSender`;
/// `nil` from that call means the box could not be opened at all.
struct ResolvedSender: Equatable {
    let senderId: String
    let contentType: UInt8
    let trust: SenderTrust
}
