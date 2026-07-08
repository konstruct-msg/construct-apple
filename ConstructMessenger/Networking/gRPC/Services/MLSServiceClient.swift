//
//  MLSServiceClient.swift
//  Construct Messenger
//
//  gRPC MLSService client — group key package distribution.
//  Foundation slice: key package publish/count only; group RPCs
//  (CreateGroup, InviteToGroup, SubmitCommit, …) come with the group flow.
//

import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2

final class MLSServiceClient: Sendable {
    static let shared = MLSServiceClient()

    private init() {}

    // MARK: - Key packages

    /// Publish MLS KeyPackages (single-use, opaque RFC 9420 blobs) for this device.
    /// The store snapshot holding their private keys MUST already be persisted —
    /// see the persistence contract in `MlsStoreManager`.
    /// Returns the total number of KeyPackages now available for this device.
    @discardableResult
    func publishKeyPackages(deviceId: String, keyPackages: [Data]) async throws -> UInt32 {
        try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.uploadPreKeys) { grpcClient in
            let mlsClient = Shared_Proto_Services_V1_MLSService.Client(wrapping: grpcClient)

            var request = Shared_Proto_Services_V1_PublishKeyPackageRequest()
            request.deviceID = deviceId
            request.keyPackages = keyPackages

            let response = try await mlsClient.publishKeyPackage(
                request: .init(message: request)
            )
            return response.count
        }
    }

    struct KeyPackageStatus {
        let count: UInt32
        let recommendedMinimum: UInt32
        /// True if the user has zero KeyPackages and cannot be invited to any group.
        let cannotBeInvited: Bool
    }

    /// Server-side KeyPackage availability for a user (optionally one device).
    func getKeyPackageCount(userId: String, deviceId: String? = nil) async throws -> KeyPackageStatus {
        try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.getPreKeyCount) { grpcClient in
            let mlsClient = Shared_Proto_Services_V1_MLSService.Client(wrapping: grpcClient)

            var request = Shared_Proto_Services_V1_GetKeyPackageCountRequest()
            request.userID = userId
            if let deviceId, !deviceId.isEmpty {
                request.deviceID = deviceId
            }

            let response = try await mlsClient.getKeyPackageCount(
                request: .init(message: request)
            )
            return KeyPackageStatus(
                count: response.count,
                recommendedMinimum: response.recommendedMinimum,
                cannotBeInvited: response.cannotBeInvited
            )
        }
    }
}
