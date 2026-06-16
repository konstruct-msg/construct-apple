//
//  KeyServiceClient.swift
//  Construct Messenger
//
//  gRPC KeyService client — replaces CryptoAPI for key management
//

import Foundation
import CoreData
import GRPCCore
import GRPCNIOTransportHTTP2

// MARK: - Key Transparency result store

/// Persists the Key Transparency verification state so SecurityView can show
/// an aggregate status without re-verifying every time.
///
/// Reset logic: after `successesNeededToReset` consecutive successful verifications
/// the `failureCount` is cleared — this prevents permanent red state after a
/// transient outage or misconfiguration that has since been resolved.
final class KTStore {
    static let shared = KTStore()
    private init() {}

    // MARK: UserDefaults keys
    private let lastVerifiedAtKey        = "construct.kt_last_verified_at"
    private let lastFailedAtKey          = "construct.kt_last_failed_at"
    private let failureCountKey          = "construct.kt_failure_count"
    private let verifiedCountKey         = "construct.kt_verified_count"
    private let consecutiveSuccessKey    = "construct.kt_consecutive_success"

    /// Number of consecutive successful verifications needed to clear `failureCount`.
    private let successesNeededToReset = 3

    // MARK: Record outcomes

    func recordVerified() {
        let ud = UserDefaults.standard
        ud.set(Date(), forKey: lastVerifiedAtKey)
        ud.set(ud.integer(forKey: verifiedCountKey) + 1, forKey: verifiedCountKey)

        let consecutive = ud.integer(forKey: consecutiveSuccessKey) + 1
        ud.set(consecutive, forKey: consecutiveSuccessKey)

        if consecutive >= successesNeededToReset && ud.integer(forKey: failureCountKey) > 0 {
            ud.set(0, forKey: failureCountKey)
            ud.set(0, forKey: consecutiveSuccessKey)
        }
    }

    func recordFailure() {
        let ud = UserDefaults.standard
        ud.set(Date(), forKey: lastFailedAtKey)
        ud.set(ud.integer(forKey: failureCountKey) + 1, forKey: failureCountKey)
        ud.set(0, forKey: consecutiveSuccessKey)
    }

    // MARK: Read state

    var lastVerifiedAt: Date? {
        UserDefaults.standard.object(forKey: lastVerifiedAtKey) as? Date
    }

    var lastFailedAt: Date? {
        UserDefaults.standard.object(forKey: lastFailedAtKey) as? Date
    }

    var verifiedCount: Int {
        UserDefaults.standard.integer(forKey: verifiedCountKey)
    }

    var failureCount: Int {
        UserDefaults.standard.integer(forKey: failureCountKey)
    }
}


final class KeyServiceClient: Sendable {
    static let shared = KeyServiceClient()

    private init() {}

    // MARK: - Get Pre-Key Bundles (multi-device)

    /// Fetch pre-key bundles for ALL active devices of a user (or specific device IDs).
    /// Returns one bundle per device — caller must encrypt separately for each.
    func getPreKeyBundles(userId: String, deviceIds: [String] = []) async throws -> [DeviceBundleData] {
        try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.getPreKeyBundles) { grpcClient in
            let keyClient = Shared_Proto_Services_V1_KeyService.Client(wrapping: grpcClient)

            var request = Shared_Proto_Services_V1_GetPreKeyBundlesRequest()
            request.userID = userId
            if !deviceIds.isEmpty {
                request.deviceIds = deviceIds
            }

            let response = try await keyClient.getPreKeyBundles(
                request: .init(message: request)
            )

            return response.bundles.compactMap { deviceBundle -> DeviceBundleData? in
                let b = deviceBundle.bundle
                guard !b.identityKey.isEmpty else { return nil }

                let otpkPublic: Data? = b.oneTimePreKey.isEmpty ? nil : b.oneTimePreKey
                let otpkId: UInt32? = b.oneTimePreKeyID > 0 ? b.oneTimePreKeyID : nil
                let kyberPK: Data? = b.hasKyberPreKey && !b.kyberPreKey.isEmpty ? b.kyberPreKey : nil

                // Hybrid PQ verification (Phase 2 only — per-device). The Phase 3 TOFU pin is
                // per-userId, which can't distinguish a user's devices, so downgrade pinning is
                // left to the single-fetch path; here a present-but-invalid hybrid bundle drops
                // that device rather than failing the whole batch.
                switch HybridBundleVerifier.verify(
                    hybridIdentityKey: b.hasHybridIdentityKey ? b.hybridIdentityKey : Data(),
                    hybridIdentitySignature: b.hasHybridIdentitySignature ? b.hybridIdentitySignature : Data(),
                    verifyingKey: deviceBundle.verifyingKey,
                    signedPreKey: b.signedPreKey,
                    signedPreKeyHybridSignature: b.hasSignedPreKeyHybridSignature ? b.signedPreKeyHybridSignature : Data(),
                    kyberPreKey: kyberPK,
                    kyberPreKeyHybridSignature: b.hasKyberPreKeyHybridSignature ? b.kyberPreKeyHybridSignature : Data()
                ) {
                case .verified:
                    Log.info("Hybrid PQ bundle verified for device \(deviceBundle.deviceID)", category: "HybridPQ")
                case .absent:
                    break
                case .failed(let reason):
                    Log.error("Hybrid PQ bundle dropped for device \(deviceBundle.deviceID): \(reason)", category: "HybridPQ")
                    return nil
                }
                let kyberPKId: UInt32? = b.hasKyberPreKeyID && b.kyberPreKeyID > 0 ? b.kyberPreKeyID : nil
                let kyberSig: Data? = b.hasKyberPreKeySignature && !b.kyberPreKeySignature.isEmpty ? b.kyberPreKeySignature : nil
                let kyberOtpkPK: Data? = b.hasKyberOneTimePreKey && !b.kyberOneTimePreKey.isEmpty ? b.kyberOneTimePreKey : nil
                let kyberOtpkId: UInt32? = b.hasKyberOneTimePreKeyID && b.kyberOneTimePreKeyID > 0 ? b.kyberOneTimePreKeyID : nil

                let bundle = PublicKeyBundleData(
                    userId: userId,
                    username: "",
                    identityPublic: b.identityKey,
                    signedPrekeyPublic: b.signedPreKey,
                    signature: b.signedPreKeySignature,
                    verifyingKey: Data(),
                    suiteId: Self.parseSuiteId(b.cryptoSuite),
                    oneTimePreKeyPublic: otpkPublic,
                    oneTimePreKeyId: otpkId,
                    kyberPreKeyPublic: kyberPK,
                    kyberPreKeyId: kyberPKId,
                    kyberPreKeySignature: kyberSig,
                    kyberOneTimePreKeyPublic: kyberOtpkPK,
                    kyberOneTimePreKeyId: kyberOtpkId,
                    spkUploadedAt: b.spkUploadedAt > 0 ? UInt64(b.spkUploadedAt) : (b.generatedAt > 0 ? UInt64(b.generatedAt) : 0),
                    spkRotationEpoch: b.spkRotationEpoch,
                    kyberSpkUploadedAt: b.hasKyberSpkUploadedAt ? UInt64(b.kyberSpkUploadedAt) : 0,
                    kyberSpkRotationEpoch: b.hasKyberSpkRotationEpoch ? b.kyberSpkRotationEpoch : 0
                )
                return DeviceBundleData(deviceId: deviceBundle.deviceID, bundle: bundle, platform: deviceBundle.platform)
            }
        }
    }

    // MARK: - Get Pre-Key Bundle (replaces CryptoAPI.getPublicKey)

    /// Fetch a user's pre-key bundle for establishing an E2EE session.
    func getPreKeyBundle(userId: String, deviceId: String? = nil) async throws -> PublicKeyBundleData {
        try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.getPreKeyBundle) { grpcClient in
            let keyClient = Shared_Proto_Services_V1_KeyService.Client(wrapping: grpcClient)

            var request = Shared_Proto_Services_V1_GetPreKeyBundleRequest()
            request.userID = userId
            if let deviceId, !deviceId.isEmpty {
                request.deviceID = deviceId
            }

            let response = try await keyClient.getPreKeyBundle(
                request: .init(message: request)
            )

            guard response.hasBundle else {
                throw NetworkError.decodingFailed
            }
            let bundle = response.bundle

            let otpkPublic: Data? = bundle.oneTimePreKey.isEmpty ? nil : bundle.oneTimePreKey
            let otpkId: UInt32? = bundle.oneTimePreKeyID > 0 ? bundle.oneTimePreKeyID : nil

            // PQXDH fields (optional — nil if server doesn't support Kyber yet)
            let kyberPK: Data? = bundle.hasKyberPreKey && !bundle.kyberPreKey.isEmpty ? bundle.kyberPreKey : nil
            let kyberPKId: UInt32? = bundle.hasKyberPreKeyID && bundle.kyberPreKeyID > 0 ? bundle.kyberPreKeyID : nil
            let kyberSig: Data? = bundle.hasKyberPreKeySignature && !bundle.kyberPreKeySignature.isEmpty ? bundle.kyberPreKeySignature : nil

            let kyberOtpkPK: Data? = bundle.hasKyberOneTimePreKey && !bundle.kyberOneTimePreKey.isEmpty
                ? bundle.kyberOneTimePreKey : nil
            let kyberOtpkId: UInt32? = bundle.hasKyberOneTimePreKeyID && bundle.kyberOneTimePreKeyID > 0
                ? bundle.kyberOneTimePreKeyID : nil

            // KT verification (non-blocking: failure is logged but does not reject the bundle)
            if response.hasKtProof {
                let p = response.ktProof
                let serverKey = UserDefaults.standard.data(forKey: VeilCertFetcher.cachedBundleSigningKeyKey)
                let result = KeyTransparencyVerifier.verify(
                    leafIndex: p.leafIndex,
                    treeSize: p.treeSize,
                    rootHash: p.rootHash,
                    proofHashes: p.proofHashes,
                    treeHeadSignature: p.treeHeadSignature,
                    deviceId: response.deviceID,
                    identityKey: bundle.identityKey,
                    serverBundleSigningPublicKey: serverKey
                )
                switch result {
                case .verified:
                    KTStore.shared.recordVerified()
                    Log.info("KT: inclusion proof verified for device \(response.deviceID)", category: "KT")
                    Self.updateContactKTStatus(
                        userId: userId,
                        identityKey: bundle.identityKey,
                        newStatus: .verified
                    )
                case .failed(let e):
                    KTStore.shared.recordFailure()
                    Log.error("KT: proof FAILED for device \(response.deviceID) — \(e)", category: "KT")
                    Self.updateContactKTStatus(
                        userId: userId,
                        identityKey: bundle.identityKey,
                        newStatus: .failed
                    )
                case .unavailable:
                    break
                }
            }

            // Hybrid identity KT inclusion proof (defense-in-depth, non-blocking like the
            // identity KT proof above — the blocking PQ check is HybridBundleVerifier below).
            if response.hasHybridKtProof, bundle.hasHybridIdentityKey, !bundle.hybridIdentityKey.isEmpty {
                let hp = response.hybridKtProof
                let serverKey = UserDefaults.standard.data(forKey: VeilCertFetcher.cachedBundleSigningKeyKey)
                switch KeyTransparencyVerifier.verifyHybrid(
                    leafIndex: hp.leafIndex,
                    treeSize: hp.treeSize,
                    rootHash: hp.rootHash,
                    proofHashes: hp.proofHashes,
                    treeHeadSignature: hp.treeHeadSignature,
                    deviceId: response.deviceID,
                    hybridIdentityKey: bundle.hybridIdentityKey,
                    serverBundleSigningPublicKey: serverKey
                ) {
                case .verified:
                    Log.info("KT(hybrid): inclusion proof verified for device \(response.deviceID)", category: "KT")
                case .failed(let e):
                    Log.error("KT(hybrid): proof FAILED for device \(response.deviceID) — \(e)", category: "KT")
                case .unavailable:
                    break
                }
            }

            // Hybrid PQ verification. Phase 2: present-but-invalid → tampering, reject.
            // Phase 3: absent for a previously hybrid-capable peer → downgrade, reject.
            let hybridOutcome = HybridBundleVerifier.verify(
                hybridIdentityKey: bundle.hasHybridIdentityKey ? bundle.hybridIdentityKey : Data(),
                hybridIdentitySignature: bundle.hasHybridIdentitySignature ? bundle.hybridIdentitySignature : Data(),
                verifyingKey: response.verifyingKey,
                signedPreKey: bundle.signedPreKey,
                signedPreKeyHybridSignature: bundle.hasSignedPreKeyHybridSignature ? bundle.signedPreKeyHybridSignature : Data(),
                kyberPreKey: kyberPK,
                kyberPreKeyHybridSignature: bundle.hasKyberPreKeyHybridSignature ? bundle.kyberPreKeyHybridSignature : Data()
            )
            let hybridDowngrade = Self.recordAndCheckHybrid(
                userId: userId,
                identityKey: bundle.identityKey,
                outcome: hybridOutcome
            )
            switch hybridOutcome {
            case .verified:
                Log.info("Hybrid PQ bundle verified for device \(response.deviceID)", category: "HybridPQ")
            case .absent:
                if hybridDowngrade {
                    Log.error("Hybrid PQ DOWNGRADE for device \(response.deviceID): peer was hybrid-capable, bundle now Ed25519-only", category: "HybridPQ")
                    throw HybridBundleVerificationError(reason: "hybrid downgrade — peer previously presented a hybrid key for this identity")
                }
            case .failed(let reason):
                Log.error("Hybrid PQ bundle REJECTED for device \(response.deviceID): \(reason)", category: "HybridPQ")
                throw HybridBundleVerificationError(reason: reason)
            }

            return PublicKeyBundleData(
                userId: userId,
                username: "",
                identityPublic: bundle.identityKey,
                signedPrekeyPublic: bundle.signedPreKey,
                signature: bundle.signedPreKeySignature,
                verifyingKey: response.verifyingKey,
                suiteId: Self.parseSuiteId(bundle.cryptoSuite),
                oneTimePreKeyPublic: otpkPublic,
                oneTimePreKeyId: otpkId,
                kyberPreKeyPublic: kyberPK,
                kyberPreKeyId: kyberPKId,
                kyberPreKeySignature: kyberSig,
                kyberOneTimePreKeyPublic: kyberOtpkPK,
                kyberOneTimePreKeyId: kyberOtpkId,
                spkUploadedAt: bundle.spkUploadedAt > 0 ? UInt64(bundle.spkUploadedAt) : (bundle.generatedAt > 0 ? UInt64(bundle.generatedAt) : 0),
                spkRotationEpoch: bundle.spkRotationEpoch,
                kyberSpkUploadedAt: bundle.hasKyberSpkUploadedAt ? UInt64(bundle.kyberSpkUploadedAt) : 0,
                kyberSpkRotationEpoch: bundle.hasKyberSpkRotationEpoch ? bundle.kyberSpkRotationEpoch : 0
            )
        }
    }

    /// Map proto CryptoSuite enum → numeric suite ID used by CryptoCore.
    private static func parseSuiteId(_ cryptoSuite: Shared_Proto_Core_V1_CryptoSuite) -> UInt16 {
        switch cryptoSuite {
        case .classicX25519Chacha20: return 1
        case .classicX25519Aes256:   return 2
        case .hybridKyber1024X25519: return 3
        case .hybridKyber768X25519:  return 3
        default:                     return 1
        }
    }

    /// Map proto crypto_suite string → numeric suite ID used by CryptoCore.
    /// Server returns named strings ("X25519_CHACHA20") per proto spec; also
    /// accepts legacy numeric strings ("1") from older server versions.
    private static func parseSuiteId(_ cryptoSuite: String) -> UInt16 {
        switch cryptoSuite {
        case "X25519_CHACHA20", "Curve25519+ChaCha20": return 1
        case "X25519_AES256", "Curve25519+AES256":    return 2
        case "KYBER_HYBRID":                           return 3
        default:
            return UInt16(cryptoSuite) ?? 1
        }
    }

    // MARK: - Upload Pre-Keys

    /// Upload a batch of one-time pre-keys to the server.
    func uploadPreKeys(
        deviceId: String,
        preKeys: [(keyId: UInt32, publicKey: Data)]? = nil,
        signedPreKey: (keyId: UInt32, publicKey: Data, signature: Data)? = nil,
        replaceExisting: Bool = false,
        kyberSignedPreKey: (keyId: UInt32, publicKey: Data, signature: Data)? = nil,
        kyberOneTimePreKeys: [(keyId: UInt32, publicKey: Data, signature: Data)]? = nil,
        hybridIdentity: (key: Data, signature: Data)? = nil,
        signedPreKeyHybridSignature: Data? = nil,
        kyberSignedPreKeyHybridSignature: Data? = nil
    ) async throws -> (classicCount: UInt32, kyberCount: UInt32) {
        try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.uploadPreKeys) { grpcClient in
            let keyClient = Shared_Proto_Services_V1_KeyService.Client(wrapping: grpcClient)

            var request = Shared_Proto_Services_V1_UploadPreKeysRequest()
            request.deviceID = deviceId
            if let pks = preKeys {
                request.preKeys = pks.map { key in
                    var otpk = Shared_Proto_Services_V1_OneTimePreKey()
                    otpk.keyID = key.keyId
                    otpk.publicKey = key.publicKey
                    return otpk
                }
            }
            if let spk = signedPreKey {
                var signed = Shared_Proto_Services_V1_SignedPreKeyUpload()
                signed.keyID = spk.keyId
                signed.publicKey = spk.publicKey
                signed.signature = spk.signature
                request.signedPreKey = signed
            }
            if let kyberSpk = kyberSignedPreKey {
                var kSigned = Shared_Proto_Services_V1_KyberSignedPreKeyUpload()
                kSigned.keyID = kyberSpk.keyId
                kSigned.publicKey = kyberSpk.publicKey
                kSigned.signature = kyberSpk.signature
                request.kyberSignedPreKey = kSigned
            }
            if let kyberOtpks = kyberOneTimePreKeys {
                request.kyberPreKeys = kyberOtpks.map { key in
                    var kotpk = Shared_Proto_Services_V1_KyberOneTimePreKey()
                    kotpk.keyID = key.keyId
                    kotpk.publicKey = key.publicKey
                    kotpk.signature = key.signature
                    return kotpk
                }
            }
            request.replaceExisting = replaceExisting

            // Hybrid PQ identity bundle (Ed25519 + ML-DSA-65), decoupled from rotation.
            if let hybrid = hybridIdentity {
                request.hybridIdentityKey = hybrid.key
                request.hybridIdentitySignature = hybrid.signature
            }
            if let spkHybridSig = signedPreKeyHybridSignature {
                request.signedPreKeyHybridSignature = spkHybridSig
            }
            if let kyberHybridSig = kyberSignedPreKeyHybridSignature {
                request.kyberSignedPreKeyHybridSignature = kyberHybridSig
            }

            let response = try await keyClient.uploadPreKeys(
                request: .init(message: request)
            )
            return (classicCount: response.preKeyCount, kyberCount: response.kyberPreKeyCount)
        }
    }

    // MARK: - Get Pre-Key Count

    /// Check how many one-time pre-keys remain on the server.
    func getPreKeyCount(deviceId: String) async throws -> UInt32 {
        try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.getPreKeyCount) { grpcClient in
            let keyClient = Shared_Proto_Services_V1_KeyService.Client(wrapping: grpcClient)

            var request = Shared_Proto_Services_V1_GetPreKeyCountRequest()
            request.deviceID = deviceId

            let response = try await keyClient.getPreKeyCount(
                request: .init(message: request)
            )
            return response.count
        }
    }

    /// Returns both the current count and the server-recommended minimum.
    func getPreKeyCountFull(deviceId: String) async throws -> (count: UInt32, recommendedMinimum: UInt32) {
        try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.getPreKeyCount) { grpcClient in
            let keyClient = Shared_Proto_Services_V1_KeyService.Client(wrapping: grpcClient)

            var request = Shared_Proto_Services_V1_GetPreKeyCountRequest()
            request.deviceID = deviceId

            let response = try await keyClient.getPreKeyCount(
                request: .init(message: request)
            )
            return (count: response.count, recommendedMinimum: response.recommendedMinimum)
        }
    }

    // MARK: - Rotate Signed Pre-Key

    /// Atomically rotate both the classical (X25519) and Kyber signed pre-keys.
    ///
    /// Both keys are included in a single RotateSignedPreKeyRequest so the server
    /// updates them in one transaction — preventing desynchronization where one key
    /// rotates successfully but the other does not.
    ///
    /// - Parameters:
    ///   - newClassicKey: New X25519 SPK generated by the Rust core via `rotateSignedPrekey()`
    ///   - newKyberKey:   New Kyber SPK generated in-memory via `PQCKeyManager.generateKyberSPKInMemory()`
    ///                    Commit to Keychain only after this call returns successfully.
    @discardableResult
    func rotateSignedPreKey(
        deviceId: String,
        newClassicKey: (keyId: UInt32, publicKey: Data, signature: Data),
        newKyberKey: (keyId: UInt32, publicKey: Data, signature: Data)? = nil,
        reason: Shared_Proto_Services_V1_SignedPreKeyRotationReason = .scheduled,
        // Hybrid (ML-DSA) signatures over the new SPK / Kyber SPK. When provided the server stores
        // them atomically with the rotation, so the published bundle never has a hybrid identity
        // with an unsigned fresh SPK (the breakage that hard-rejects initiators).
        signedPreKeyHybridSignature: Data? = nil,
        kyberSignedPreKeyHybridSignature: Data? = nil
    ) async throws -> Shared_Proto_Services_V1_RotateSignedPreKeyResponse {
        try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.rotateSignedPreKey) { grpcClient in
            let keyClient = Shared_Proto_Services_V1_KeyService.Client(wrapping: grpcClient)

            var signed = Shared_Proto_Services_V1_SignedPreKeyUpload()
            signed.keyID = newClassicKey.keyId
            signed.publicKey = newClassicKey.publicKey
            signed.signature = newClassicKey.signature

            var request = Shared_Proto_Services_V1_RotateSignedPreKeyRequest()
            request.deviceID = deviceId
            request.newSignedPreKey = signed
            request.reason = reason
            if let spkHybrid = signedPreKeyHybridSignature, !spkHybrid.isEmpty {
                request.signedPreKeyHybridSignature = spkHybrid
            }

            if let kyberSpk = newKyberKey {
                var kSigned = Shared_Proto_Services_V1_KyberSignedPreKeyUpload()
                kSigned.keyID = kyberSpk.keyId
                kSigned.publicKey = kyberSpk.publicKey
                kSigned.signature = kyberSpk.signature
                request.newKyberSignedPreKey = kSigned
                if let kyberHybrid = kyberSignedPreKeyHybridSignature, !kyberHybrid.isEmpty {
                    request.kyberSignedPreKeyHybridSignature = kyberHybrid
                }
            }

            return try await keyClient.rotateSignedPreKey(
                request: .init(message: request)
            )
        }
    }

    // MARK: - Get Identity Key

    /// Fetch a user's identity key (for safety number verification).
    func getIdentityKey(userId: String) async throws -> Data {
        try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.getIdentityKey) { grpcClient in
            let keyClient = Shared_Proto_Services_V1_KeyService.Client(wrapping: grpcClient)

            var request = Shared_Proto_Services_V1_GetIdentityKeyRequest()
            request.userID = userId

            let response = try await keyClient.getIdentityKey(
                request: .init(message: request)
            )
            return response.identityKey
        }
    }

    // MARK: - KT per-contact state update

    /// Update the `knownIdentityKey` and `ktStatus` on the User Core Data record
    /// for `userId` after a KT verification result.
    ///
    /// - On first verification (`knownIdentityKey == nil`): stores the key and marks `.verified`.
    /// - On matching key: updates status to the new value (`.verified` or `.failed`).
    /// - On key change (was set, now different): marks `.keyChanged` and posts
    ///   `.contactKeyChanged` — regardless of whether the proof itself was valid,
    ///   because any unexpected key change must surface to the user.
    private static func updateContactKTStatus(
        userId: String,
        identityKey: Data,
        newStatus: KTStatus
    ) {
        let context = PersistenceController.shared.container.newBackgroundContext()
        context.perform {
            let fetch = User.fetchRequest()
            fetch.predicate = NSPredicate(format: "id == %@", userId)
            fetch.fetchLimit = 1
            guard let user = try? context.fetch(fetch).first else { return }

            if let known = user.knownIdentityKey, known != identityKey {
                // Identity key has changed since the last verified session.
                user.ktStatus = .keyChanged
                user.knownIdentityKey = identityKey
                Log.error("KT: identity key changed for user \(userId)", category: "KT")
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .contactKeyChanged,
                        object: nil,
                        userInfo: ["userId": userId]
                    )
                }
            } else {
                user.ktStatus = newStatus
                if newStatus == .verified {
                    user.knownIdentityKey = identityKey
                }
            }
            try? context.save()
        }
    }

    /// Phase 3 hybrid downgrade protection. Records hybrid capability on a verified bundle and,
    /// for an Ed25519-only (`.absent`) bundle, reports whether this is a downgrade: the peer was
    /// previously seen hybrid-capable under the SAME identity key.
    ///
    /// Returns `true` only when the caller must REJECT the bundle as a downgrade.
    /// Capability is keyed to `knownIdentityKey`, so a legitimate account reset (new identity key)
    /// clears the pin instead of false-positiving.
    private static func recordAndCheckHybrid(
        userId: String,
        identityKey: Data,
        outcome: HybridBundleVerifier.Outcome
    ) -> Bool {
        let context = PersistenceController.shared.container.newBackgroundContext()
        var isDowngrade = false
        context.performAndWait {
            let fetch = User.fetchRequest()
            fetch.predicate = NSPredicate(format: "id == %@", userId)
            fetch.fetchLimit = 1
            guard let user = try? context.fetch(fetch).first else { return }

            let identityChanged = user.knownIdentityKey != nil && user.knownIdentityKey != identityKey

            switch outcome {
            case .verified:
                // Pin hybrid capability to this identity.
                user.hybridCapable = true
                user.knownIdentityKey = identityKey
            case .absent:
                if identityChanged {
                    // Legitimate new identity (account reset / new device) — clear the pin, accept.
                    user.hybridCapable = false
                    user.knownIdentityKey = identityKey
                } else if user.hybridCapable {
                    // Same identity, previously hybrid-capable, now Ed25519-only → downgrade.
                    isDowngrade = true
                }
            case .failed:
                break // caller rejects regardless
            }
            if context.hasChanges { try? context.save() }
        }
        return isDowngrade
    }
}
