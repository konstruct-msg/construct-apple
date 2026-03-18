//
//  KeyServiceClient.swift
//  Construct Messenger
//
//  gRPC KeyService client — replaces CryptoAPI for key management
//

import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2


final class KeyServiceClient: Sendable {
    static let shared = KeyServiceClient()

    private init() {}

    // MARK: - Get Pre-Key Bundles (multi-device)

    /// Fetch pre-key bundles for ALL active devices of a user (or specific device IDs).
    /// Returns one bundle per device — caller must encrypt separately for each.
    func getPreKeyBundles(userId: String, deviceIds: [String] = []) async throws -> [DeviceBundleData] {
        try await GRPCChannelManager.shared.performRPC { grpcClient in
            let keyClient = Shared_Proto_Services_V1_KeyService.Client(wrapping: grpcClient)

            var request = Shared_Proto_Services_V1_GetPreKeyBundlesRequest()
            request.userID = userId
            if !deviceIds.isEmpty {
                request.deviceIds = deviceIds
            }

            let response = try await keyClient.getPreKeyBundles(
                request: .init(message: request)
            )

            return response.bundles.compactMap { deviceBundle in
                let b = deviceBundle.bundle
                guard !b.identityKey.isEmpty else { return nil }

                let otpkPublic = b.oneTimePreKey.isEmpty ? nil : b.oneTimePreKey.base64EncodedString()
                let otpkId: UInt32? = b.oneTimePreKeyID > 0 ? b.oneTimePreKeyID : nil
                let kyberPK: Data? = b.hasKyberPreKey && !b.kyberPreKey.isEmpty ? b.kyberPreKey : nil
                let kyberPKId: UInt32? = b.hasKyberPreKeyID && b.kyberPreKeyID > 0 ? b.kyberPreKeyID : nil
                let kyberSig: Data? = b.hasKyberPreKeySignature && !b.kyberPreKeySignature.isEmpty ? b.kyberPreKeySignature : nil
                let kyberOtpkPK: Data? = b.hasKyberOneTimePreKey && !b.kyberOneTimePreKey.isEmpty ? b.kyberOneTimePreKey : nil
                let kyberOtpkId: UInt32? = b.hasKyberOneTimePreKeyID && b.kyberOneTimePreKeyID > 0 ? b.kyberOneTimePreKeyID : nil

                let bundle = PublicKeyBundleData(
                    userId: userId,
                    username: "",
                    identityPublic: b.identityKey.base64EncodedString(),
                    signedPrekeyPublic: b.signedPreKey.base64EncodedString(),
                    signature: b.signedPreKeySignature.base64EncodedString(),
                    verifyingKey: "",
                    suiteId: Self.parseSuiteId(b.cryptoSuite),
                    oneTimePreKeyPublic: otpkPublic,
                    oneTimePreKeyId: otpkId,
                    kyberPreKeyPublic: kyberPK,
                    kyberPreKeyId: kyberPKId,
                    kyberPreKeySignature: kyberSig,
                    kyberOneTimePreKeyPublic: kyberOtpkPK,
                    kyberOneTimePreKeyId: kyberOtpkId,
                    spkUploadedAt: b.generatedAt > 0 ? UInt64(b.generatedAt) : 0,
                    spkRotationEpoch: 0,
                    kyberSpkUploadedAt: 0,
                    kyberSpkRotationEpoch: 0
                )
                return DeviceBundleData(deviceId: deviceBundle.deviceID, bundle: bundle, platform: deviceBundle.platform)
            }
        }
    }

    // MARK: - Get Pre-Key Bundle (replaces CryptoAPI.getPublicKey)

    /// Fetch a user's pre-key bundle for establishing an E2EE session.
    func getPreKeyBundle(userId: String, deviceId: String? = nil) async throws -> PublicKeyBundleData {
        try await GRPCChannelManager.shared.performRPC { grpcClient in
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

            let verifyingKeyB64 = response.verifyingKey.isEmpty
                ? ""
                : response.verifyingKey.base64EncodedString()

            let otpkPublic = bundle.oneTimePreKey.isEmpty ? nil : bundle.oneTimePreKey.base64EncodedString()
            let otpkId: UInt32? = bundle.oneTimePreKeyID > 0 ? bundle.oneTimePreKeyID : nil

            // PQXDH fields (optional — nil if server doesn't support Kyber yet)
            let kyberPK: Data? = bundle.hasKyberPreKey && !bundle.kyberPreKey.isEmpty ? bundle.kyberPreKey : nil
            let kyberPKId: UInt32? = bundle.hasKyberPreKeyID && bundle.kyberPreKeyID > 0 ? bundle.kyberPreKeyID : nil
            let kyberSig: Data? = bundle.hasKyberPreKeySignature && !bundle.kyberPreKeySignature.isEmpty ? bundle.kyberPreKeySignature : nil

            let kyberOtpkPK: Data? = bundle.hasKyberOneTimePreKey && !bundle.kyberOneTimePreKey.isEmpty
                ? bundle.kyberOneTimePreKey : nil
            let kyberOtpkId: UInt32? = bundle.hasKyberOneTimePreKeyID && bundle.kyberOneTimePreKeyID > 0
                ? bundle.kyberOneTimePreKeyID : nil

            return PublicKeyBundleData(
                userId: userId,
                username: "",
                identityPublic: bundle.identityKey.base64EncodedString(),
                signedPrekeyPublic: bundle.signedPreKey.base64EncodedString(),
                signature: bundle.signedPreKeySignature.base64EncodedString(),
                verifyingKey: verifyingKeyB64,
                suiteId: Self.parseSuiteId(bundle.cryptoSuite),
                oneTimePreKeyPublic: otpkPublic,
                oneTimePreKeyId: otpkId,
                kyberPreKeyPublic: kyberPK,
                kyberPreKeyId: kyberPKId,
                kyberPreKeySignature: kyberSig,
                kyberOneTimePreKeyPublic: kyberOtpkPK,
                kyberOneTimePreKeyId: kyberOtpkId,
                spkUploadedAt: bundle.generatedAt > 0 ? UInt64(bundle.generatedAt) : 0,
                spkRotationEpoch: 0,
                kyberSpkUploadedAt: 0,
                kyberSpkRotationEpoch: 0
            )
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
        kyberOneTimePreKeys: [(keyId: UInt32, publicKey: Data, signature: Data)]? = nil
    ) async throws -> (classicCount: UInt32, kyberCount: UInt32) {
        try await GRPCChannelManager.shared.performRPC { grpcClient in
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

            let response = try await keyClient.uploadPreKeys(
                request: .init(message: request)
            )
            return (classicCount: response.preKeyCount, kyberCount: response.kyberPreKeyCount)
        }
    }

    // MARK: - Get Pre-Key Count

    /// Check how many one-time pre-keys remain on the server.
    func getPreKeyCount(deviceId: String) async throws -> UInt32 {
        try await GRPCChannelManager.shared.performRPC { grpcClient in
            let keyClient = Shared_Proto_Services_V1_KeyService.Client(wrapping: grpcClient)

            var request = Shared_Proto_Services_V1_GetPreKeyCountRequest()
            request.deviceID = deviceId

            let response = try await keyClient.getPreKeyCount(
                request: .init(message: request)
            )
            return response.count
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
        reason: Shared_Proto_Services_V1_SignedPreKeyRotationReason = .scheduled
    ) async throws -> Shared_Proto_Services_V1_RotateSignedPreKeyResponse {
        try await GRPCChannelManager.shared.performRPC { grpcClient in
            let keyClient = Shared_Proto_Services_V1_KeyService.Client(wrapping: grpcClient)

            var signed = Shared_Proto_Services_V1_SignedPreKeyUpload()
            signed.keyID = newClassicKey.keyId
            signed.publicKey = newClassicKey.publicKey
            signed.signature = newClassicKey.signature

            var request = Shared_Proto_Services_V1_RotateSignedPreKeyRequest()
            request.deviceID = deviceId
            request.newSignedPreKey = signed
            request.reason = reason

            if let kyberSpk = newKyberKey {
                var kSigned = Shared_Proto_Services_V1_KyberSignedPreKeyUpload()
                kSigned.keyID = kyberSpk.keyId
                kSigned.publicKey = kyberSpk.publicKey
                kSigned.signature = kyberSpk.signature
                request.kyberSignedPreKey = kSigned
            }

            return try await keyClient.rotateSignedPreKey(
                request: .init(message: request)
            )
        }
    }

    // MARK: - Get Identity Key

    /// Fetch a user's identity key (for safety number verification).
    func getIdentityKey(userId: String) async throws -> Data {
        try await GRPCChannelManager.shared.performRPC { grpcClient in
            let keyClient = Shared_Proto_Services_V1_KeyService.Client(wrapping: grpcClient)

            var request = Shared_Proto_Services_V1_GetIdentityKeyRequest()
            request.userID = userId

            let response = try await keyClient.getIdentityKey(
                request: .init(message: request)
            )
            return response.identityKey
        }
    }
}
