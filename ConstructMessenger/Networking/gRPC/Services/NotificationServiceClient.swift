//
//  NotificationServiceClient.swift
//  Construct Messenger
//
//  Push token registration via DeviceService.UpdatePushToken.
//  Envoy route: /shared.proto.services.v1.DeviceService/UpdatePushToken
//

import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2


final class NotificationServiceClient: Sendable {
    static let shared = NotificationServiceClient()

    private init() {}

    // MARK: - Register / Update Device Token

    /// Registers (or updates) the APNs push token with the server.
    /// Uses DeviceService.UpdatePushToken — the only endpoint that writes to device_tokens.
    func registerDeviceToken(token: String) async throws -> DeviceTokenResponse {
        let deviceId = KeychainManager.shared.loadDeviceID() ?? ""

        #if DEBUG
        let environment = Shared_Proto_Services_V1_PushEnvironment.pushEnvSandbox
        #else
        let environment = Shared_Proto_Services_V1_PushEnvironment.pushEnvProduction
        #endif

        return try await GRPCChannelManager.shared.performRPC { grpcClient in
            let client = Shared_Proto_Services_V1_DeviceService.Client(wrapping: grpcClient)

            var request = Shared_Proto_Services_V1_UpdatePushTokenRequest()
            request.deviceID = deviceId
            request.pushToken = token
            request.provider = .apns
            request.environment = environment

            let response = try await client.updatePushToken(
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
        let deviceId = KeychainManager.shared.loadDeviceID() ?? ""

        try await GRPCChannelManager.shared.performRPC { grpcClient in
            let client = Shared_Proto_Services_V1_DeviceService.Client(wrapping: grpcClient)

            var request = Shared_Proto_Services_V1_UnregisterPushTokenRequest()
            request.deviceID = deviceId

            _ = try await client.unregisterPushToken(
                request: .init(message: request)
            )
        }
    }
}
