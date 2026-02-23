//
//  SentinelServiceClient.swift
//  Construct Messenger
//
//  gRPC SentinelService client — spam reporting and trust management
//

import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2

@available(iOS 18.0, *)
final class SentinelServiceClient: Sendable {
    static let shared = SentinelServiceClient()

    private init() {}

    // MARK: - Report Spam

    func reportSpam(deviceId: String, category: Shared_Proto_Sentinel_V1_SpamCategory = .unspecified) async throws -> String {
        try await GRPCChannelManager.shared.performRPC { grpcClient in
            let client = Shared_Proto_Sentinel_V1_SentinelService.Client(wrapping: grpcClient)

            var request = Shared_Proto_Sentinel_V1_ReportSpamRequest()
            request.reportedDeviceID = deviceId
            request.category = category

            let response = try await client.reportSpam(request: .init(message: request))
            return response.reportID
        }
    }

    // MARK: - Get Trust Status

    func getTrustStatus() async throws -> Shared_Proto_Sentinel_V1_GetTrustStatusResponse {
        try await GRPCChannelManager.shared.performRPC { grpcClient in
            let client = Shared_Proto_Sentinel_V1_SentinelService.Client(wrapping: grpcClient)

            let request = Shared_Proto_Sentinel_V1_GetTrustStatusRequest()

            return try await client.getTrustStatus(request: .init(message: request))
        }
    }

    // MARK: - Check Send Permission

    func checkSendPermission(targetDeviceId: String) async throws -> Shared_Proto_Sentinel_V1_CheckSendPermissionResponse {
        try await GRPCChannelManager.shared.performRPC { grpcClient in
            let client = Shared_Proto_Sentinel_V1_SentinelService.Client(wrapping: grpcClient)

            var request = Shared_Proto_Sentinel_V1_CheckSendPermissionRequest()
            request.targetDeviceID = targetDeviceId

            return try await client.checkSendPermission(request: .init(message: request))
        }
    }
}
