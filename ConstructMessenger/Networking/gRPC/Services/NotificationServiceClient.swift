//
//  NotificationServiceClient.swift
//  Construct Messenger
//
//  gRPC NotificationService client — replaces APNsAPI
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif
import GRPCCore
import GRPCNIOTransportHTTP2


final class NotificationServiceClient: Sendable {
    static let shared = NotificationServiceClient()

    private init() {}

    // MARK: - Register Device Token

    func registerDeviceToken(token: String) async throws -> DeviceTokenResponse {
        #if canImport(UIKit)
        let deviceName = await MainActor.run { UIDevice.current.name }
        #else
        let deviceName = Host.current().localizedName ?? "Mac"
        #endif
        return try await GRPCChannelManager.shared.performRPC { grpcClient in
            let client = Shared_Proto_Services_V1_NotificationService.Client(wrapping: grpcClient)

            var request = Shared_Proto_Services_V1_RegisterDeviceTokenRequest()
            request.deviceToken = token
            request.deviceName = deviceName

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
