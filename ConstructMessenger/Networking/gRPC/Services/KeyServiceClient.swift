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
    ///
    /// `consumeOneTimePrekey` has no default **on purpose** — see `getPreKeyBundle`.
    func getPreKeyBundles(
        userId: String,
        deviceIds: [String] = [],
        consumeOneTimePrekey: Bool
    ) async throws -> [DeviceBundleData] {
        // Under the Phase-4 unauthenticated-transport flag, fetch over the sealed channel so the
        // server/gateway does not learn who is fetching whose bundle. Bundles are public keys, and
        // key-service's GetPreKeyBundles reads no caller identity (IP-only rate limiting), so the
        // unauthenticated fetch is safe end-to-end. Off → authenticated (current behaviour).
        let (bundles, activeDevices) = try await GRPCChannelManager.shared.performRPC(sealed: FeatureFlags.sealedSenderUnauthenticatedTransport, timeout: GRPCTimeouts.getPreKeyBundles) { grpcClient in
            let keyClient = Shared_Proto_Services_V1_KeyService.Client(wrapping: grpcClient)

            var request = Shared_Proto_Services_V1_GetPreKeyBundlesRequest()
            request.userID = userId
            request.consumeOneTimePrekey = consumeOneTimePrekey
            if !deviceIds.isEmpty {
                request.deviceIds = deviceIds
            }

            let response = try await keyClient.getPreKeyBundles(
                request: .init(message: request)
            )

            let accepted = response.bundles.compactMap { deviceBundle -> DeviceBundleData? in
                let b = deviceBundle.bundle
                guard !b.identityKey.isEmpty else { return nil }

                // Nothing about the post-quantum keys is judged here. The hybrid identity binding
                // and both signatures on each Kyber key are the core's to check when a session is
                // opened, and a bundle it would refuse is refused there, with its reason
                // (`PQ_REQUIRED: …`). This used to verify the v1 hybrid signatures in Swift and
                // drop the device on a mismatch.
                //
                // The per-device Ed25519 verifying key: was hardcoded to Data() once, and every
                // fan-out/SenderSync init failed in the core with "Invalid verifying_key size:
                // expected 32, got 0" (B3, vk=0B).
                let bundle = Self.bundleData(b, userId: userId, verifyingKey: deviceBundle.verifyingKey)
                return DeviceBundleData(
                    deviceId: deviceBundle.deviceID,
                    bundle: bundle,
                    platform: deviceBundle.platform,
                    hybridIdentityKey: b.hasHybridIdentityKey ? b.hybridIdentityKey : Data()
                )
            }
            // Carried out of the closure beside the bundles, and deliberately not folded into
            // them: `accepted` above has already dropped devices this client refused (failed
            // hybrid-PQ verification), and `active_devices` is the server's own answer about which
            // devices exist. Merging the two would destroy the only distinction that makes
            // pruning safe. See `SessionAddressing.reconcileDevices`.
            return (accepted, response.activeDevices)
        }
        // Recorded here rather than at each call site: a registry every caller has to remember to
        // update is stale for whichever path was added last, and the staleness is invisible —
        // consumers read "we do not know this account's devices", which is a legal answer.
        await MainActor.run {
            PeerDeviceRegistry.shared.record(userId: userId, devices: bundles)
        }
        // The durable half of the same answer. The registry above expires in an hour and lives in
        // memory; this survives relaunch and answers during a locked-device background decrypt,
        // which is what a seal or a teardown addressed to a specific device needs. Two stores, two
        // questions — "which devices does this account have right now" and "which devices have we
        // pinned a key for" — and the second is the one an envelope may be built against.
        let pins = bundles.map { (deviceId: $0.deviceId, identityKey: $0.bundle.identityPublic) }
        let context = PersistenceController.shared.container.newBackgroundContext()
        // Awaited, not fired off: the caller's next move is usually to act on these devices, and a
        // write that lands after that would leave the first use of a newly-linked device reading an
        // incomplete set. It is one small write against a background context.
        await context.perform {
            SessionAddressing.reconcileDevices(
                pins, activeSet: activeDevices, ofPeer: userId, in: context
            )
        }
        return bundles
    }

    // MARK: - Get Pre-Key Bundle (replaces CryptoAPI.getPublicKey)

    /// Intermediate result of the gRPC fetch + KT verify. Core Data side effects
    /// (KT status) are applied on the MainActor *after* the RPC returns so
    /// SwiftUI `@ObservedObject` User rows never receive objectWillChange off-main
    /// (the classic "Publishing changes from background threads is not allowed" warning).
    private struct PreKeyBundleFetchResult: Sendable {
        let data: PublicKeyBundleData
        let deviceID: String
        /// Non-nil when a KT inclusion proof was present and evaluated.
        let ktStatus: KTStatus?
    }

    /// Fetch a user's pre-key bundle for establishing an E2EE session.
    /// Fetch one device's pre-key bundle.
    ///
    /// - Parameter consumeOneTimePrekey: whether this fetch may **burn** one of the target's
    ///   one-time pre-keys. Deliberately has **no default value** so every call site has to
    ///   state its intent: fetching a bundle is destructive (the server DELETEs an OTPK), and
    ///   a caller that only needs the identity / verifying / signed pre-key drains the target's
    ///   pool for nothing. Once that pool hits zero, every new inbound session to that peer is
    ///   established without a one-time pre-key — weaker X3DH forward secrecy — and the peer
    ///   re-uploads endlessly to refill it. Pass `true` **only** when about to run X3DH.
    func getPreKeyBundle(
        userId: String,
        deviceId: String? = nil,
        consumeOneTimePrekey: Bool
    ) async throws -> PublicKeyBundleData {
        // See getPreKeyBundles: sealed (unauthenticated) channel under the Phase-4 flag so the
        // server/gateway can't correlate (caller, target) at session-init time.
        let fetched = try await GRPCChannelManager.shared.performRPC(sealed: FeatureFlags.sealedSenderUnauthenticatedTransport, timeout: GRPCTimeouts.getPreKeyBundle) { grpcClient -> PreKeyBundleFetchResult in
            let keyClient = Shared_Proto_Services_V1_KeyService.Client(wrapping: grpcClient)

            var request = Shared_Proto_Services_V1_GetPreKeyBundleRequest()
            request.userID = userId
            request.consumeOneTimePrekey = consumeOneTimePrekey
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

            // KT verification (non-blocking: failure is logged but does not reject the bundle).
            // Core Data write is deferred to MainActor after the RPC — see apply below.
            var ktStatus: KTStatus? = nil
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
                    ktStatus = .verified
                case .failed(let e):
                    KTStore.shared.recordFailure()
                    Log.error("KT: proof FAILED for device \(response.deviceID) — \(e)", category: "KT")
                    ktStatus = .failed
                case .unavailable:
                    break
                }
            }

            // Hybrid identity KT inclusion proof (defense-in-depth, non-blocking like the
            // identity KT proof above — the blocking PQ checks are the core's, at session init).
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

            let data = Self.bundleData(bundle, userId: userId, verifyingKey: response.verifyingKey)

            return PreKeyBundleFetchResult(
                data: data,
                deviceID: response.deviceID,
                ktStatus: ktStatus
            )
        }

        // --- MainActor Core Data side effects (UI-observed User fields) ---
        if let ktStatus = fetched.ktStatus {
            await MainActor.run {
                Self.updateContactKTStatus(
                    userId: userId,
                    identityKey: fetched.data.identityPublic,
                    newStatus: ktStatus
                )
            }
        }

        // Backstop. The KT writer above pins `knownIdentityKey` only on `.verified`, and bails
        // without a word when the `User` row does not exist. Otherwise we have just fetched and
        // are about to run X3DH against an identity key that nothing kept, and every subsequent
        // sealed send to this peer fails closed with `StealthDowngradeBlocked` (TODO #45).
        //
        // It used to have a second writer: the Swift hybrid-bundle check pinned the key on every
        // bundle with a valid hybrid identity, silently overwriting a changed one. That check is
        // gone (the core verifies the hybrid chain at session init and pins the hybrid key per
        // device); an identity change is now surfaced by KT alone, as for any other key.
        await MainActor.run {
            // A bundle came back, so whatever marked them gone is stale.
            VanishedPeerStore.shared.clear(userId)
            ContactLinkService.shared.rememberIdentityKeyIfUnknown(
                userId: userId,
                identityKey: fetched.data.identityPublic,
                source: "bundle_fetch",
                // We asked for this user; a session with them is being established either way.
                createIfMissing: true,
                context: PersistenceController.shared.container.viewContext
            )
        }

        return fetched.data
    }

    /// Map proto CryptoSuite enum → the core's SuiteID (suite_id.rs):
    /// 1 = CLASSIC (X25519+ChaCha20), 2 = PQ_HYBRID (X25519+ML-KEM-768, ML-DSA-65),
    /// 3 = PQ_RATCHET — NEVER produced from a bundle: suite 3 is negotiated
    /// per-session from the supports_pq_ratchet capability, not declared as the
    /// bundle's crypto suite. (The old mapping sent hybrid bundles to 3, which
    /// now means the sparse PQ ratchet — a different protocol entirely.)
    private static func parseSuiteId(_ cryptoSuite: Shared_Proto_Core_V1_CryptoSuite) -> UInt16 {
        switch cryptoSuite {
        case .classicX25519Chacha20: return 1
        // The core has no AES-256 provider — treat as classic rather than
        // accidentally selecting the ML-KEM hybrid provider (core suite 2).
        case .classicX25519Aes256:   return 1
        case .hybridKyber1024X25519: return 2
        case .hybridKyber768X25519:  return 2
        default:                     return 1
        }
    }

    /// Map proto crypto_suite string → the core's SuiteID (see enum overload above).
    /// Server returns named strings ("X25519_CHACHA20") per proto spec; also
    /// accepts legacy numeric strings ("1") from older server versions.
    private static func parseSuiteId(_ cryptoSuite: String) -> UInt16 {
        switch cryptoSuite {
        case "X25519_CHACHA20", "Curve25519+ChaCha20": return 1
        case "X25519_AES256", "Curve25519+AES256":    return 1
        case "KYBER_HYBRID":                           return 2
        default:
            return UInt16(cryptoSuite) ?? 1
        }
    }

    /// A served bundle as the app carries it until `PublicKeyBundleData.binaryKeyBundle` hands it
    /// to the core. One reading for both fetch paths: they were two copies of twenty fields, and
    /// the multi-device one had already lost the verifying key once.
    ///
    /// Empty proto bytes and zero ids read as absent. The PQXDH v2 fields (25–28, 20–21) are
    /// passed through as served; the core decides what it can trust.
    /// Internal, not private, for `PQXDHBundleConversionTests`.
    static func bundleData(
        _ b: Shared_Proto_Services_V1_PreKeyBundle,
        userId: String,
        verifyingKey: Data
    ) -> PublicKeyBundleData {
        func bytes(_ present: Bool, _ value: Data) -> Data? { present && !value.isEmpty ? value : nil }
        return PublicKeyBundleData(
            userId: userId,
            username: "",
            identityPublic: b.identityKey,
            signedPrekeyPublic: b.signedPreKey,
            signature: b.signedPreKeySignature,
            verifyingKey: verifyingKey,
            suiteId: parseSuiteId(b.cryptoSuite),
            oneTimePreKeyPublic: b.oneTimePreKey.isEmpty ? nil : b.oneTimePreKey,
            oneTimePreKeyId: b.oneTimePreKeyID > 0 ? b.oneTimePreKeyID : nil,
            kyberPreKeyPublic: bytes(b.hasKyberPreKey, b.kyberPreKey),
            kyberPreKeyId: b.hasKyberPreKeyID && b.kyberPreKeyID > 0 ? b.kyberPreKeyID : nil,
            kyberPreKeySignature: bytes(b.hasKyberPreKeySignature, b.kyberPreKeySignature),
            kyberPreKeyCreatedAt: b.hasKyberPreKeyCreatedAt ? b.kyberPreKeyCreatedAt : nil,
            kyberPreKeyHybridSignature: bytes(b.hasKyberPreKeyHybridSignature, b.kyberPreKeyHybridSignature),
            kyberOneTimePreKeyPublic: bytes(b.hasKyberOneTimePreKey, b.kyberOneTimePreKey),
            kyberOneTimePreKeyId: b.hasKyberOneTimePreKeyID && b.kyberOneTimePreKeyID > 0 ? b.kyberOneTimePreKeyID : nil,
            kyberOneTimePreKeyCreatedAt: b.hasKyberOneTimePreKeyCreatedAt ? b.kyberOneTimePreKeyCreatedAt : nil,
            kyberOneTimePreKeySignature: bytes(b.hasKyberOneTimePreKeySignature, b.kyberOneTimePreKeySignature),
            kyberOneTimePreKeyHybridSignature: bytes(b.hasKyberOneTimePreKeyHybridSignature, b.kyberOneTimePreKeyHybridSignature),
            hybridIdentityKey: bytes(b.hasHybridIdentityKey, b.hybridIdentityKey),
            hybridIdentitySignature: bytes(b.hasHybridIdentitySignature, b.hybridIdentitySignature),
            spkUploadedAt: b.spkUploadedAt > 0 ? UInt64(b.spkUploadedAt) : (b.generatedAt > 0 ? UInt64(b.generatedAt) : 0),
            spkRotationEpoch: b.spkRotationEpoch,
            kyberSpkUploadedAt: b.hasKyberSpkUploadedAt ? UInt64(b.kyberSpkUploadedAt) : 0,
            kyberSpkRotationEpoch: b.hasKyberSpkRotationEpoch ? b.kyberSpkRotationEpoch : 0
        )
    }

    // MARK: - Upload Pre-Keys

    /// Upload a batch of one-time pre-keys to the server.
    func uploadPreKeys(
        deviceId: String,
        preKeys: [(keyId: UInt32, publicKey: Data)]? = nil,
        signedPreKey: (keyId: UInt32, publicKey: Data, signature: Data)? = nil,
        replaceExisting: Bool = false,
        kyberSignedPreKey: KyberPrekeyUpload? = nil,
        kyberOneTimePreKeys: [KyberPrekeyUpload]? = nil,
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
            // Both Kyber shapes as the core produced them: the signed `created_at` travels with the
            // key, since both signatures cover it. The SPK's hybrid signature goes in
            // `kyberSignedPreKeyHybridSignature` below, stored by the server with the hybrid
            // identity; a one-time key carries its own.
            if let kyberSpk = kyberSignedPreKey {
                request.kyberSignedPreKey = Self.kyberSignedUpload(kyberSpk)
            }
            if let kyberOtpks = kyberOneTimePreKeys {
                request.kyberPreKeys = kyberOtpks.map { key in
                    var kotpk = Shared_Proto_Services_V1_KyberOneTimePreKey()
                    kotpk.keyID = key.keyId
                    kotpk.publicKey = Data(key.publicKey)
                    kotpk.signature = Data(key.signature)
                    kotpk.createdAt = key.createdAt
                    kotpk.hybridSignature = Data(key.hybridSignature)
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

            // `supports_pq_ratchet` is left at its default. Suite 3 is mandatory since PQXDH v2 and
            // nothing reads the field any more (it is deprecated in the proto).

            let response = try await keyClient.uploadPreKeys(
                request: .init(message: request)
            )
            return (classicCount: response.preKeyCount, kyberCount: response.kyberPreKeyCount)
        }
    }

    private static func kyberSignedUpload(_ key: KyberPrekeyUpload) -> Shared_Proto_Services_V1_KyberSignedPreKeyUpload {
        var signed = Shared_Proto_Services_V1_KyberSignedPreKeyUpload()
        signed.keyID = key.keyId
        signed.publicKey = Data(key.publicKey)
        signed.signature = Data(key.signature)
        signed.createdAt = key.createdAt
        return signed
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
    ///   - newKyberKey:   The core's pending Kyber SPK (`beginKyberSpkRotation`). Commit it only
    ///                    after this call returns successfully.
    @discardableResult
    func rotateSignedPreKey(
        deviceId: String,
        newClassicKey: (keyId: UInt32, publicKey: Data, signature: Data),
        newKyberKey: KyberPrekeyUpload? = nil,
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
                request.newKyberSignedPreKey = Self.kyberSignedUpload(kyberSpk)
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
    /// **MainActor-only** — User is `@ObservedObject` in chat/list UI; writing from a
    /// background context caused "Publishing changes from background threads".
    ///
    /// - On first verification (`knownIdentityKey == nil`): stores the key and marks `.verified`.
    /// - On matching key: updates status to the new value (`.verified` or `.failed`).
    /// - On key change (was set, now different): marks `.keyChanged` and posts
    ///   `.contactKeyChanged` — regardless of whether the proof itself was valid,
    ///   because any unexpected key change must surface to the user.
    @MainActor
    private static func updateContactKTStatus(
        userId: String,
        identityKey: Data,
        newStatus: KTStatus
    ) {
        let context = PersistenceController.shared.container.viewContext
        let fetch = User.fetchRequest()
        fetch.predicate = NSPredicate(format: "id == %@", userId)
        fetch.fetchLimit = 1
        guard let user = try? context.fetch(fetch).first else { return }

        if let known = user.knownIdentityKey, known != identityKey {
            // Identity key has changed since the last verified session.
            user.ktStatus = .keyChanged
            user.knownIdentityKey = identityKey
            Log.error("KT: identity key changed for user \(userId)", category: "KT")
            if context.hasChanges {
                try? context.save()
            }
            NotificationCenter.default.post(
                name: .contactKeyChanged,
                object: nil,
                userInfo: ["userId": userId]
            )
            KeyChangeUX.notifyKeyChange(
                userId: userId,
                displayName: user.resolvedDisplayName
            )
        } else {
            user.ktStatus = newStatus
            if newStatus == .verified {
                user.knownIdentityKey = identityKey
            }
            if context.hasChanges {
                try? context.save()
            }
        }
    }
}
