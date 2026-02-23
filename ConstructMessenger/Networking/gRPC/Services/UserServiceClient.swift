//
//  UserServiceClient.swift
//  Construct Messenger
//
//  gRPC UserService client — provides user profile and account management
//

import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2


final class UserServiceClient: Sendable {
    static let shared = UserServiceClient()

    private init() {}

    // MARK: - Get User Profile

    func getUserProfile(userId: String) async throws -> Shared_Proto_Services_V1_UserProfile {
        try await GRPCChannelManager.shared.performRPC { grpcClient in
            let client = Shared_Proto_Services_V1_UserService.Client(wrapping: grpcClient)

            var request = Shared_Proto_Services_V1_GetUserProfileRequest()
            request.userID = userId

            return try await client.getUserProfile(request: .init(message: request))
        }
    }

    // MARK: - Delete Account (replaces AuthAPI.getDeleteChallenge + confirmDeleteDevice)

    func deleteAccount(confirmation: String, reason: String? = nil) async throws -> Shared_Proto_Services_V1_DeleteAccountResponse {
        try await GRPCChannelManager.shared.performRPC { grpcClient in
            let client = Shared_Proto_Services_V1_UserService.Client(wrapping: grpcClient)

            var request = Shared_Proto_Services_V1_DeleteAccountRequest()
            request.confirmation = confirmation
            if let reason { request.reason = reason }

            return try await client.deleteAccount(request: .init(message: request))
        }
    }

    // MARK: - Block / Unblock User

    func blockUser(userId: String, reason: String? = nil) async throws -> Bool {
        try await GRPCChannelManager.shared.performRPC { grpcClient in
            let client = Shared_Proto_Services_V1_UserService.Client(wrapping: grpcClient)

            var request = Shared_Proto_Services_V1_BlockUserRequest()
            request.userID = userId
            if let reason { request.reason = reason }

            let response = try await client.blockUser(request: .init(message: request))
            return response.success
        }
    }

    func unblockUser(userId: String) async throws -> Bool {
        try await GRPCChannelManager.shared.performRPC { grpcClient in
            let client = Shared_Proto_Services_V1_UserService.Client(wrapping: grpcClient)

            var request = Shared_Proto_Services_V1_UnblockUserRequest()
            request.userID = userId

            let response = try await client.unblockUser(request: .init(message: request))
            return response.success
        }
    }
}
