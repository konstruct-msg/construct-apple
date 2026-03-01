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

            return PublicKeyBundleData(
                userId: userId,
                username: "",
                identityPublic: bundle.identityKey.base64EncodedString(),
                signedPrekeyPublic: bundle.signedPreKey.base64EncodedString(),
                signature: bundle.signedPreKeySignature.base64EncodedString(),
                verifyingKey: verifyingKeyB64,
                suiteId: Self.parseSuiteId(bundle.cryptoSuite)
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
        preKeys: [(keyId: UInt32, publicKey: Data)],
        signedPreKey: (keyId: UInt32, publicKey: Data, signature: Data)? = nil
    ) async throws -> UInt32 {
        try await GRPCChannelManager.shared.performRPC { grpcClient in
            let keyClient = Shared_Proto_Services_V1_KeyService.Client(wrapping: grpcClient)

            var request = Shared_Proto_Services_V1_UploadPreKeysRequest()
            request.deviceID = deviceId
            request.preKeys = preKeys.map { key in
                var otpk = Shared_Proto_Services_V1_OneTimePreKey()
                otpk.keyID = key.keyId
                otpk.publicKey = key.publicKey
                return otpk
            }
            if let spk = signedPreKey {
                var signed = Shared_Proto_Services_V1_SignedPreKeyUpload()
                signed.keyID = spk.keyId
                signed.publicKey = spk.publicKey
                signed.signature = spk.signature
                request.signedPreKey = signed
            }

            let response = try await keyClient.uploadPreKeys(
                request: .init(message: request)
            )
            return response.preKeyCount
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

    /// Rotate the signed pre-key on the server.
    func rotateSignedPreKey(
        deviceId: String,
        newKey: (keyId: UInt32, publicKey: Data, signature: Data),
        reason: Shared_Proto_Services_V1_SignedPreKeyRotationReason = .scheduled
    ) async throws {
        try await GRPCChannelManager.shared.performRPC { grpcClient in
            let keyClient = Shared_Proto_Services_V1_KeyService.Client(wrapping: grpcClient)

            var signed = Shared_Proto_Services_V1_SignedPreKeyUpload()
            signed.keyID = newKey.keyId
            signed.publicKey = newKey.publicKey
            signed.signature = newKey.signature

            var request = Shared_Proto_Services_V1_RotateSignedPreKeyRequest()
            request.deviceID = deviceId
            request.newSignedPreKey = signed
            request.reason = reason

            _ = try await keyClient.rotateSignedPreKey(
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
