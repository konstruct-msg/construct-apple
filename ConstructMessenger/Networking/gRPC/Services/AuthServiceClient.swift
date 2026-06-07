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
        registrationBundle: RegistrationBundleFields,
        challenge: String,
        powSolution: PowSolution
    ) async throws -> RegisterSuccessData {
        return try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.registerDevice, allowAuthRetry: false) { grpcClient in
            let authClient = Shared_Proto_Services_V1_AuthService.Client(wrapping: grpcClient)

            var publicKeys = Shared_Proto_Services_V1_DevicePublicKeys()
            publicKeys.verifyingKey = Data(registrationBundle.verifyingKey)
            publicKeys.identityPublic = Data(registrationBundle.identityPublic)
            publicKeys.signedPrekeyPublic = Data(registrationBundle.signedPrekeyPublic)
            publicKeys.signedPrekeySignature = Data(registrationBundle.signature)
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
                userId: response.tokens.userID,
                username: username ?? "",
                sessionToken: response.tokens.accessToken,
                refreshToken: response.tokens.refreshToken,
                expires: response.tokens.expiresAt,
                veilBridgeCert: response.tokens.hasVeilBridgeCert ? response.tokens.veilBridgeCert : nil
            )
        }
    }

    // MARK: - Authenticate Device (replaces AuthAPI.authenticateDevice)

    func authenticateDevice(deviceId: String, timestamp: Int64, signature: Data) async throws -> AuthResponse {
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
                userId: response.tokens.userID,
                accessToken: response.tokens.accessToken,
                refreshToken: response.tokens.refreshToken,
                expiresAt: response.tokens.expiresAt,
                expiresIn: nil,
                veilBridgeCert: response.tokens.hasVeilBridgeCert ? response.tokens.veilBridgeCert : nil
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
            // Include the current access token so the server can add its JTI to the
            // Redis blocklist, preventing the token from being used for up to its 24h TTL.
            // Falls back to empty string if the token was already removed from Keychain
            // (e.g. crash before logout, race with refresh). The server returns
            // INVALID_ARGUMENT in that case, which we treat as a non-error below.
            request.accessToken = KeychainManager.shared.loadSessionToken() ?? ""

            do {
                _ = try await authClient.logout(
                    request: .init(message: request)
                )
            } catch let rpc as RPCError where rpc.code == .invalidArgument {
                // Token was absent or already expired — nothing to add to blocklist.
                // Refresh token is still revoked server-side; treat as success.
                Log.error("Logout: access token not invalidated (absent or expired) — continuing", category: "Auth")
            }
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
                veilBridgeCert: response.tokens.hasVeilBridgeCert ? response.tokens.veilBridgeCert : nil
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
        let veilBridgeCert: String?
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
                userId: response.tokens.userID,
                accessToken: response.tokens.accessToken,
                refreshToken: response.tokens.refreshToken,
                expiresAt: response.tokens.expiresAt,
                veilBridgeCert: response.tokens.hasVeilBridgeCert ? response.tokens.veilBridgeCert : nil
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
                    let di = info.device           // DeviceInfo
                    let deviceId = di.device.deviceID
                    devices.append(LinkedDevice(
                        id: deviceId,
                        name: di.deviceName.isEmpty
                            ? "Device …\(deviceId.suffix(8))"
                            : di.deviceName,
                        platform: di.platform,
                        lastSeen: di.lastSeen > 0
                            ? Date(timeIntervalSince1970: TimeInterval(di.lastSeen))
                            : Date(timeIntervalSince1970: TimeInterval(di.createdAt)),
                        createdAt: Date(timeIntervalSince1970: TimeInterval(di.createdAt)),
                        isCurrent: di.isCurrent
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

    /// Called by the phone when it scans the TUI's "link-to-me" QR and the user confirms.
    /// Sends `ApproveJoinRequest` to the server; the server issues tokens and stores them
    /// keyed by `pendingId` for the TUI to poll via `checkDeviceLinkStatus`.
    func approveDeviceJoinRequest(
        pendingId: String,
        newDeviceId: String,
        newDevicePublicKey: String,
        newDeviceName: String,
        newDevicePlatform: String
    ) async throws {
        try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.authenticateDevice) { grpcClient in
            let authClient = Shared_Proto_Services_V1_AuthService.Client(wrapping: grpcClient)

            var request = Shared_Proto_Services_V1_ApproveJoinRequestRequest()
            request.pendingDeviceID = pendingId
            request.cryptoSuite = "Curve25519+Ed25519"

            _ = try await authClient.approveJoinRequest(request: .init(message: request))
        }
    }

    /// Called by the new device (TUI) to poll for credentials approved by the phone.
    /// Returns `nil` while still pending; returns `ConfirmLinkResult` when approved.
    /// Throws on network errors; caller should continue polling on transient failures.
    func checkDeviceLinkStatus(pendingId: String) async throws -> ConfirmLinkResult? {
        return try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.confirmDeviceLink, allowAuthRetry: false) { grpcClient in
            let linkClient = Shared_Proto_Services_V1_DeviceLinkService.Client(wrapping: grpcClient)

            var request = Shared_Proto_Services_V1_CheckJoinRequestStatusRequest()
            request.pendingDeviceID = pendingId

            let response = try await linkClient.checkJoinRequestStatus(request: .init(message: request))

            switch response.status {
            case .approved:
                guard response.hasTokens else { return nil }
                let t = response.tokens
                return ConfirmLinkResult(
                    userId: t.userID,
                    accessToken: t.accessToken,
                    refreshToken: t.refreshToken,
                    expiresAt: t.expiresAt,
                    veilBridgeCert: t.hasIceBridgeCert ? t.veilBridgeCert : nil
                )
            case .rejected:
                throw DeviceLinkError.rejected
            case .expired:
                throw DeviceLinkError.expired
            default:
                return nil // .pending
            }
        }
    }

    func getSenderCertificate() async throws -> Shared_Proto_Services_V1_GetSenderCertificateResponse {
        try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.getSenderCertificate) { grpcClient in
            let authClient = Shared_Proto_Services_V1_AuthService.Client(wrapping: grpcClient)
            let request = Shared_Proto_Services_V1_GetSenderCertificateRequest()
            return try await authClient.getSenderCertificate(request: .init(message: request))
        }
    }

    // MARK: - Privacy Pass — issue blind tokens

    func issueTokens(blindedPoints: [Data]) async throws -> Shared_Proto_Services_V1_IssueTokensResponse {
        try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.issueTokens) { grpcClient in
            let authClient = Shared_Proto_Services_V1_AuthService.Client(wrapping: grpcClient)
            var request = Shared_Proto_Services_V1_IssueTokensRequest()
            request.blindedPoints = blindedPoints
            return try await authClient.issueTokens(request: .init(message: request))
        }
    }

    // MARK: - Social Recovery Bundle (SLIP-39 Variant A)

    /// Upload encrypted recovery bundle (authenticated). Bundle must be ≤ 4096 bytes.
    func storeRecoveryBundle(ciphertext: Data) async throws {
        try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.recovery) { grpcClient in
            let authClient = Shared_Proto_Services_V1_AuthService.Client(wrapping: grpcClient)
            var request = Shared_Proto_Services_V1_StoreRecoveryBundleRequest()
            request.bundleCiphertext = ciphertext
            _ = try await authClient.storeRecoveryBundle(request: .init(message: request))
        }
    }

    /// Fetch encrypted recovery bundle by username (unauthenticated).
    /// Returns nil if no bundle is stored for this username.
    func getRecoveryBundle(username: String) async throws -> Data? {
        try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.recovery, allowAuthRetry: false) { grpcClient in
            let authClient = Shared_Proto_Services_V1_AuthService.Client(wrapping: grpcClient)
            var request = Shared_Proto_Services_V1_GetRecoveryBundleRequest()
            request.username = username
            let response = try await authClient.getRecoveryBundle(request: .init(message: request))
            guard response.bundleExists else { return nil }
            return response.bundleCiphertext
        }
    }
}
