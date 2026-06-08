//
//  NotificationServiceClient.swift
//  Construct Messenger
//
//  Push token registration via NotificationService.RegisterDeviceToken.
//  Envoy route: /shared.proto.services.v1.NotificationService/RegisterDeviceToken
//

import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2


final class NotificationServiceClient: Sendable {
    static let shared = NotificationServiceClient()

    private init() {}

    private var pushEnvironment: Shared_Proto_Services_V1_PushEnvironment {
        #if DEBUG
        return .sandbox
        #else
        return .production
        #endif
    }

    // MARK: - Register / Update Device Token

    /// Registers (or updates) the APNs push token with the server.
    /// Uses NotificationService.RegisterDeviceToken (canonical push endpoint).
    func registerDeviceToken(token: String) async throws -> DeviceTokenResponse {
        let deviceId = KeychainManager.shared.loadDeviceID() ?? ""

        let environment = pushEnvironment

        Log.info("Registering APNs token — environment: \(environment.rawValue) (\(environment == .production ? "production" : "sandbox"))", category: "Notifications")

        return try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.registerDeviceToken) { grpcClient in
            let client = Shared_Proto_Services_V1_NotificationService.Client(wrapping: grpcClient)

            var request = Shared_Proto_Services_V1_RegisterDeviceTokenRequest()
            request.deviceToken = token
            request.deviceID = deviceId
            request.provider = .apns
            request.environment = environment
            request.notificationFilter = .visibleAll

            let response = try await client.registerDeviceToken(
                request: .init(message: request)
            )

            return DeviceTokenResponse(
                success: response.success,
                message: nil
            )
        }
    }

    // MARK: - VoIP Token (CallKit)

    /// Registers (or updates) the APNs VoIP token (PushKit) used for incoming calls.
    func registerVoipToken(voipToken: String) async throws -> Bool {
        let deviceId = KeychainManager.shared.loadDeviceID() ?? ""
        let environment = pushEnvironment

        return try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.registerVoipToken) { grpcClient in
            let client = Shared_Proto_Services_V1_NotificationService.Client(wrapping: grpcClient)

            var request = Shared_Proto_Services_V1_RegisterVoipTokenRequest()
            request.voipToken = voipToken
            request.deviceID = deviceId
            request.platform = "ios"
            request.environment = environment

            let response = try await client.registerVoipToken(request: .init(message: request))
            return response.success
        }
    }

    /// Removes the VoIP token (typically on logout or PushKit token invalidation).
    func unregisterVoipToken() async throws {
        let deviceId = KeychainManager.shared.loadDeviceID() ?? ""

        try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.unregisterVoipToken) { grpcClient in
            let client = Shared_Proto_Services_V1_NotificationService.Client(wrapping: grpcClient)
            var request = Shared_Proto_Services_V1_UnregisterVoipTokenRequest()
            request.deviceID = deviceId
            _ = try await client.unregisterVoipToken(request: .init(message: request))
        }
    }

    // MARK: - Unregister Device Token

    /// Removes the push token on logout / notifications disabled.
    func unregisterDeviceToken(token: String) async throws {
        try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.unregisterDeviceToken) { grpcClient in
            let client = Shared_Proto_Services_V1_NotificationService.Client(wrapping: grpcClient)

            var request = Shared_Proto_Services_V1_UnregisterDeviceTokenRequest()
            request.deviceToken = token

            _ = try await client.unregisterDeviceToken(
                request: .init(message: request)
            )
        }
    }
}
