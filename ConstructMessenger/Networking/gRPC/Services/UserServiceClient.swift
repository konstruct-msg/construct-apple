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
        try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.getUserProfile) { grpcClient in
            let client = Shared_Proto_Services_V1_UserService.Client(wrapping: grpcClient)

            var request = Shared_Proto_Services_V1_GetUserProfileRequest()
            request.userID = userId

            return try await client.getUserProfile(request: .init(message: request))
        }
    }

    // MARK: - Delete Account (replaces AuthAPI.getDeleteChallenge + confirmDeleteDevice)

    func deleteAccount(confirmation: String, reason: String? = nil) async throws -> Shared_Proto_Services_V1_DeleteAccountResponse {
        try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.deleteAccount) { grpcClient in
            let client = Shared_Proto_Services_V1_UserService.Client(wrapping: grpcClient)

            var request = Shared_Proto_Services_V1_DeleteAccountRequest()
            request.confirmation = confirmation
            if let reason { request.reason = reason }

            return try await client.deleteAccount(request: .init(message: request))
        }
    }

    // MARK: - Block / Unblock User

    func blockUser(userId: String, reason: String? = nil) async throws -> Bool {
        try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.blockUser) { grpcClient in
            let client = Shared_Proto_Services_V1_UserService.Client(wrapping: grpcClient)

            var request = Shared_Proto_Services_V1_BlockUserRequest()
            request.userID = userId
            if let reason { request.reason = reason }

            let response = try await client.blockUser(request: .init(message: request))
            return response.success
        }
    }

    func unblockUser(userId: String) async throws -> Bool {
        try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.unblockUser) { grpcClient in
            let client = Shared_Proto_Services_V1_UserService.Client(wrapping: grpcClient)

            var request = Shared_Proto_Services_V1_UnblockUserRequest()
            request.userID = userId

            let response = try await client.unblockUser(request: .init(message: request))
            return response.success
        }
    }

    // MARK: - Update Username

    func updateUsername(userId: String, username: String) async throws {
        try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.updateUserProfile) { grpcClient in
            let client = Shared_Proto_Services_V1_UserService.Client(wrapping: grpcClient)

            var request = Shared_Proto_Services_V1_UpdateUserProfileRequest()
            request.userID = userId
            request.username = username

            _ = try await client.updateUserProfile(request: .init(message: request))
        }
    }

    // MARK: - Check Username Availability (no auth required)

    struct UsernameAvailability: Sendable {
        let available: Bool
        let reason: String?
    }

    func checkUsernameAvailability(username: String) async throws -> UsernameAvailability {
        try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.usernameAvailability) { grpcClient in
            let client = Shared_Proto_Services_V1_UserService.Client(wrapping: grpcClient)

            var request = Shared_Proto_Services_V1_CheckUsernameAvailabilityRequest()
            request.username = username

            let response = try await client.checkUsernameAvailability(request: .init(message: request))
            return UsernameAvailability(
                available: response.available,
                reason: response.hasReason ? response.reason : nil
            )
        }
    }
}
