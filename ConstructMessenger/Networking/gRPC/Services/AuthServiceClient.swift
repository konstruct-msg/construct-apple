//
//  AuthServiceClient.swift
//  Construct Messenger
//
//  gRPC AuthService client — replaces AuthAPI for authentication
//

import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2

// Defined here as AuthAPI.swift is removed
struct ChallengeResponse: Codable {
    let challenge: String
    let difficulty: UInt32
    let expiresAt: Int64
}

final class AuthServiceClient: Sendable {
    static let shared = AuthServiceClient()

    private init() {}

    // MARK: - PoW Challenge (replaces AuthAPI.getRegistrationChallenge)

    func getPowChallenge() async throws -> ChallengeResponse {
        try await GRPCChannelManager.shared.performRPC { grpcClient in
            let authClient = Shared_Proto_Services_V1_AuthService.Client(wrapping: grpcClient)

            let response = try await authClient.getPowChallenge(
                request: .init(message: .init())
            )

            return ChallengeResponse(
                challenge: response.challenge,
                difficulty: response.difficulty,
                expiresAt: response.expiresAt
            )
        }
    }

    // MARK: - Register Device (replaces AuthAPI.registerV2)

    func registerDevice(
        username: String?,
        deviceId: String,
        registrationBundle: String,
        challenge: String,
        powSolution: PowSolution
    ) async throws -> RegisterSuccessData {
        // Parse registration bundle JSON
        guard let bundleData = registrationBundle.data(using: .utf8),
              let bundleDict = try? JSONSerialization.jsonObject(with: bundleData) as? [String: Any] else {
            throw NetworkError.decodingFailed
        }

        let signedPrekeySignature = (bundleDict["signed_prekey_signature"] as? String)
            ?? (bundleDict["signature"] as? String) ?? ""

        return try await GRPCChannelManager.shared.performRPC { grpcClient in
            let authClient = Shared_Proto_Services_V1_AuthService.Client(wrapping: grpcClient)

            var publicKeys = Shared_Proto_Services_V1_DevicePublicKeys()
            publicKeys.verifyingKey = bundleDict["verifying_key"] as? String ?? ""
            publicKeys.identityPublic = bundleDict["identity_public"] as? String ?? ""
            publicKeys.signedPrekeyPublic = bundleDict["signed_prekey_public"] as? String ?? ""
            publicKeys.signedPrekeySignature = signedPrekeySignature
            publicKeys.cryptoSuite = "Curve25519+Ed25519"

            var pow = Shared_Proto_Services_V1_PowSolution()
            pow.challenge = challenge
            pow.nonce = powSolution.nonce
            pow.hash = powSolution.hash

            var request = Shared_Proto_Services_V1_RegisterDeviceRequest()
            if let username, !username.isEmpty {
                request.username = username
            }
            request.deviceID = deviceId
            request.publicKeys = publicKeys
            request.powSolution = pow

            let response = try await authClient.registerDevice(
                request: .init(message: request)
            )

            return RegisterSuccessData(
                userId: response.userID,
                username: username ?? "",
                sessionToken: response.accessToken,
                refreshToken: response.refreshToken,
                expires: response.expiresAt,
                iceBridgeCert: response.hasIceBridgeCert ? response.iceBridgeCert : nil
            )
        }
    }

    // MARK: - Authenticate Device (replaces AuthAPI.authenticateDevice)

    func authenticateDevice(deviceId: String, timestamp: Int64, signature: String) async throws -> AuthResponse {
        try await GRPCChannelManager.shared.performRPC { grpcClient in
            let authClient = Shared_Proto_Services_V1_AuthService.Client(wrapping: grpcClient)

            var request = Shared_Proto_Services_V1_AuthenticateDeviceRequest()
            request.deviceID = deviceId
            request.timestamp = timestamp
            request.signature = signature

            let response = try await authClient.authenticateDevice(
                request: .init(message: request)
            )

            return AuthResponse(
                userId: response.userID,
                accessToken: response.accessToken,
                refreshToken: response.refreshToken,
                expiresAt: response.expiresAt,
                expiresIn: nil,
                iceBridgeCert: response.hasIceBridgeCert ? response.iceBridgeCert : nil
            )
        }
    }

    // MARK: - Refresh Token (replaces AuthAPI.refreshToken)

    func refreshToken(refreshToken: String, deviceId: String = "") async throws -> AuthResponse {
        try await GRPCChannelManager.shared.performRPC { grpcClient in
            let authClient = Shared_Proto_Services_V1_AuthService.Client(wrapping: grpcClient)

            var request = Shared_Proto_Services_V1_RefreshTokenRequest()
            request.refreshToken = refreshToken
            if !deviceId.isEmpty {
                request.deviceID = deviceId
            }

            let response = try await authClient.refreshToken(
                request: .init(message: request)
            )

            return AuthResponse(
                userId: "",
                accessToken: response.accessToken,
                refreshToken: response.hasRefreshToken ? response.refreshToken : refreshToken,
                expiresAt: response.expiresAt,
                expiresIn: nil
            )
        }
    }

    // MARK: - Logout (replaces AuthAPI.logout)

    func logout(allDevices: Bool = false) async throws {
        try await GRPCChannelManager.shared.performRPC { grpcClient in
            let authClient = Shared_Proto_Services_V1_AuthService.Client(wrapping: grpcClient)

            var request = Shared_Proto_Services_V1_LogoutRequest()
            request.allDevices = allDevices

            _ = try await authClient.logout(
                request: .init(message: request)
            )
        }
    }

    // MARK: - Set Recovery Key

    struct RecoveryKeyResult {
        let fingerprint: String
    }

    func setRecoveryKey(publicKey: Data, signature: Data, timestamp: Int64) async throws -> RecoveryKeyResult {
        try await GRPCChannelManager.shared.performRPC { grpcClient in
            let authClient = Shared_Proto_Services_V1_AuthService.Client(wrapping: grpcClient)

            var request = Shared_Proto_Services_V1_SetRecoveryKeyRequest()
            request.recoveryPublicKey = publicKey
            request.setupSignature = signature
            request.timestamp = timestamp

            let response = try await authClient.setRecoveryKey(
                request: .init(message: request)
            )
            return RecoveryKeyResult(fingerprint: response.fingerprint)
        }
    }

    // MARK: - Get Recovery Status

    struct RecoveryStatus {
        let isSetup: Bool
        let fingerprint: String?
        let lastUsedAt: Int64?
    }

    func getRecoveryStatus() async throws -> RecoveryStatus {
        try await GRPCChannelManager.shared.performRPC { grpcClient in
            let authClient = Shared_Proto_Services_V1_AuthService.Client(wrapping: grpcClient)

            let response = try await authClient.getRecoveryStatus(
                request: .init(message: Shared_Proto_Services_V1_GetRecoveryStatusRequest())
            )
            return RecoveryStatus(
                isSetup: response.isSetup,
                fingerprint: response.hasFingerprint ? response.fingerprint : nil,
                lastUsedAt: response.hasLastUsedAt ? response.lastUsedAt : nil
            )
        }
    }

    // MARK: - Recover Account

    func recoverAccount(
        identifier: String,
        challenge: String,
        recoverySignature: Data,
        deviceId: String,
        deviceName: String,
        publicKeys: Shared_Proto_Services_V1_DevicePublicKeys
    ) async throws -> AuthResponse {
        try await GRPCChannelManager.shared.performRPC { grpcClient in
            let authClient = Shared_Proto_Services_V1_AuthService.Client(wrapping: grpcClient)

            var newDevice = Shared_Proto_Services_V1_NewDeviceForRecovery()
            newDevice.deviceID = deviceId
            newDevice.deviceName = deviceName
            newDevice.platform = .ios
            newDevice.publicKeys = publicKeys

            var request = Shared_Proto_Services_V1_RecoverAccountRequest()
            request.identifier = identifier
            request.challenge = challenge
            request.recoverySignature = recoverySignature
            request.newDevice = newDevice

            let response = try await authClient.recoverAccount(
                request: .init(message: request)
            )
            return AuthResponse(
                userId: response.userID,
                accessToken: response.tokens.accessToken,
                refreshToken: response.tokens.refreshToken,
                expiresAt: response.tokens.expiresAt,
                expiresIn: nil,
                iceBridgeCert: response.tokens.hasIceBridgeCert ? response.tokens.iceBridgeCert : nil
            )
        }
    }
}
