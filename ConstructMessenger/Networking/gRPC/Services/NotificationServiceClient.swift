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

    // MARK: - Register / Update Device Token

    /// Registers (or updates) the APNs push token with the server.
    /// Uses NotificationService.RegisterDeviceToken (canonical push endpoint).
    func registerDeviceToken(token: String) async throws -> DeviceTokenResponse {
        let deviceId = KeychainManager.shared.loadDeviceID() ?? ""

        #if DEBUG
        let environment = Shared_Proto_Services_V1_PushEnvironment.pushEnvSandbox
        #else
        let environment = Shared_Proto_Services_V1_PushEnvironment.pushEnvProduction
        #endif

        Log.info("📲 Registering APNs token — environment: \(environment.rawValue) (\(environment == .pushEnvProduction ? "production" : "sandbox"))", category: "Notifications")

        return try await GRPCChannelManager.shared.performRPC { grpcClient in
            let client = Shared_Proto_Services_V1_NotificationService.Client(wrapping: grpcClient)

            var request = Shared_Proto_Services_V1_RegisterDeviceTokenRequest()
            request.deviceToken = token
            request.deviceID = deviceId
            request.provider = .apns
            request.environment = environment

            let response = try await client.registerDeviceToken(
                request: .init(message: request)
            )

            return DeviceTokenResponse(
                success: response.success,
                message: nil
            )
        }
    }

    // MARK: - Unregister Device Token

    /// Removes the push token on logout / notifications disabled.
    func unregisterDeviceToken(token: String) async throws {
        try await GRPCChannelManager.shared.performRPC { grpcClient in
            let client = Shared_Proto_Services_V1_NotificationService.Client(wrapping: grpcClient)

            var request = Shared_Proto_Services_V1_UnregisterDeviceTokenRequest()
            request.deviceToken = token

            _ = try await client.unregisterDeviceToken(
                request: .init(message: request)
            )
        }
    }
}
