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
        try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.powChallenge, allowAuthRetry: false) { grpcClient in
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
        registrationBundle: RegistrationBundleJson,
        challenge: String,
        powSolution: PowSolution
    ) async throws -> RegisterSuccessData {
        return try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.registerDevice, allowAuthRetry: false) { grpcClient in
            let authClient = Shared_Proto_Services_V1_AuthService.Client(wrapping: grpcClient)

            var publicKeys = Shared_Proto_Services_V1_DevicePublicKeys()
            publicKeys.verifyingKey = registrationBundle.verifyingKey
            publicKeys.identityPublic = registrationBundle.identityPublic
            publicKeys.signedPrekeyPublic = registrationBundle.signedPrekeyPublic
            publicKeys.signedPrekeySignature = registrationBundle.signature
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
        try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.authenticateDevice, allowAuthRetry: false) { grpcClient in
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

    func refreshToken(refreshToken: String, deviceId: String = "", allowAuthRetry: Bool = false) async throws -> AuthResponse {
        try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.refreshToken, allowAuthRetry: allowAuthRetry) { grpcClient in
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
        try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.logout) { grpcClient in
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
        try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.recovery) { grpcClient in
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
        try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.recovery) { grpcClient in
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
        try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.recovery, allowAuthRetry: false) { grpcClient in
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

    // MARK: - Device Linking (Device A: initiator, requires JWT)

    struct DeviceLinkToken {
        let token: String
        let expiresAt: Int64
    }

    /// Device A calls this to get a link token to display as QR.
    /// Requires an authenticated JWT. Rate-limited to 1/day/device.
    func initiateDeviceLink() async throws -> DeviceLinkToken {
        return try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.initiateDeviceLink) { grpcClient in
            let deviceClient = Shared_Proto_Services_V1_DeviceService.Client(wrapping: grpcClient)
            let response = try await deviceClient.initiateDeviceLink(
                request: .init(message: Shared_Proto_Services_V1_InitiateDeviceLinkRequest())
            )
            return DeviceLinkToken(token: response.linkToken, expiresAt: response.expiresAt)
        }
    }

    // MARK: - Device Linking (Device B: new device, no JWT required)

    struct ConfirmLinkResult {
        let userId: String
        let accessToken: String
        let refreshToken: String
        let expiresAt: Int64
        let iceBridgeCert: String?
    }

    /// Device B calls this after scanning the QR code.
    /// Sends the new device's public keys; receives JWT for the new device.
    /// Does NOT require an existing JWT (`allowAuthRetry: false`).
    func confirmDeviceLink(linkToken: String, deviceId: String, publicKeys: Shared_Proto_Services_V1_DevicePublicKeys) async throws -> ConfirmLinkResult {
        return try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.confirmDeviceLink, allowAuthRetry: false) { grpcClient in
            let linkClient = Shared_Proto_Services_V1_DeviceLinkService.Client(wrapping: grpcClient)

            var request = Shared_Proto_Services_V1_ConfirmDeviceLinkRequest()
            request.linkToken = linkToken
            request.deviceID = deviceId
            request.publicKeys = publicKeys

            let response = try await linkClient.confirmDeviceLink(
                request: .init(message: request)
            )
            return ConfirmLinkResult(
                userId: response.userID,
                accessToken: response.accessToken,
                refreshToken: response.refreshToken,
                expiresAt: response.expiresAt,
                iceBridgeCert: response.hasIceBridgeCert ? response.iceBridgeCert : nil
            )
        }
    }

    // MARK: - Device Management

    struct LinkedDevice: Identifiable, Sendable {
        let id: String          // deviceId
        let name: String
        let platform: Shared_Proto_Core_V1_DevicePlatform
        let lastSeen: Date
        let createdAt: Date
        let isCurrent: Bool
    }

    /// Returns the list of devices linked to the current account.
    /// Server-side streaming — collects all items before returning.
    func listDevices() async throws -> [LinkedDevice] {
        return try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.listDevices) { grpcClient in
            let deviceClient = Shared_Proto_Services_V1_DeviceService.Client(wrapping: grpcClient)
            return try await deviceClient.listDevices(
                request: .init(message: Shared_Proto_Services_V1_ListDevicesRequest())
            ) { response in
                var devices: [LinkedDevice] = []
                for try await info in response.messages {
                    devices.append(LinkedDevice(
                        id: info.device.deviceID,
                        name: info.deviceName,
                        platform: info.platform,
                        lastSeen: Date(timeIntervalSince1970: TimeInterval(info.lastSeen)),
                        createdAt: Date(timeIntervalSince1970: TimeInterval(info.createdAt)),
                        isCurrent: info.isCurrent
                    ))
                }
                return devices
            }
        }
    }

    /// Revoke (remotely log out) a device. Cannot revoke the current device.
    func revokeDevice(deviceId: String) async throws {
        try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.revokeDevice) { grpcClient in
            let deviceClient = Shared_Proto_Services_V1_DeviceService.Client(wrapping: grpcClient)

            var request = Shared_Proto_Services_V1_RevokeDeviceRequest()
            request.deviceID = deviceId

            _ = try await deviceClient.revokeDevice(
                request: .init(message: request)
            )
        }
    }

    // MARK: - Device Join Request (new device initiates; existing device approves)

    /// Called by the existing device (phone) when it scans the new device's (laptop) "link-to-me" QR.
    /// The server stores the approved credentials keyed by `pendingId`; the new device polls for them.
    ///
    /// - TODO: Backend — implement `ApproveDeviceJoinRequest` RPC in DeviceLinkService.
    func approveDeviceJoinRequest(
        pendingId: String,
        newDeviceId: String,
        newDevicePublicKey: String,
        newDeviceName: String,
        newDevicePlatform: String
    ) async throws {
        // TODO: Wire to gRPC when backend implements ApproveDeviceJoinRequest
        throw DeviceLinkError.joinRequestNotImplemented
    }

    /// Called by the new device (laptop) to poll for credentials approved by the existing device.
    /// Returns `nil` while still pending; returns `ConfirmLinkResult` when approved.
    ///
    /// - TODO: Backend — implement `CheckDeviceLinkStatus` RPC in DeviceLinkService.
    func checkDeviceLinkStatus(pendingId: String) async throws -> ConfirmLinkResult? {
        // TODO: Wire to gRPC when backend implements CheckDeviceLinkStatus
        throw DeviceLinkError.joinRequestNotImplemented
    }
}
