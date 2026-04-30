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

            let response = try await client.getUserProfile(request: .init(message: request))
            return response.profile
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

    // MARK: - Set Discoverable

    /// Opts the authenticated user in or out of username search.
    /// The user must have a username set to opt in — server enforces this.
    func setDiscoverable(enabled: Bool) async throws {
        try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.setDiscoverable) { grpcClient in
            let client = Shared_Proto_Services_V1_UserService.Client(wrapping: grpcClient)

            var request = Shared_Proto_Services_V1_SetDiscoverableRequest()
            request.discoverable = enabled

            _ = try await client.setDiscoverable(request: .init(message: request))
        }
    }

    // MARK: - Find User

    /// Searches for a user by exact username match.
    /// Returns the userId if found and discoverable, nil otherwise (NOT_FOUND or rate-limited).
    /// Never distinguishes "no such user" from "user not discoverable" — server intentionally returns
    /// identical NOT_FOUND for both to prevent username enumeration attacks.
    func findUser(username: String) async throws -> String? {
        do {
            return try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.findUser) { grpcClient in
                let client = Shared_Proto_Services_V1_UserService.Client(wrapping: grpcClient)

                var request = Shared_Proto_Services_V1_FindUserRequest()
                request.username = username.trimmingCharacters(in: .whitespaces).lowercased()

                let response = try await client.findUser(request: .init(message: request))
                return response.userID
            }
        } catch {
            // NOT_FOUND and RESOURCE_EXHAUSTED (rate limit) both map to nil — caller never learns why.
            let desc = error.localizedDescription.lowercased()
            if desc.contains("not found") || desc.contains("resource exhausted") || desc.contains("unavailable") {
                return nil
            }
            throw error
        }
    }

    // MARK: - Contact Requests

    func sendContactRequest(toUserId: String) async throws -> String {
        try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.getUserProfile) { grpcClient in
            let client = Shared_Proto_Services_V1_UserService.Client(wrapping: grpcClient)
            var request = Shared_Proto_Services_V1_SendContactRequestRequest()
            request.toUserID = toUserId
            let response = try await client.sendContactRequest(request: .init(message: request))
            return response.requestID
        }
    }

    func getContactRequests() async throws -> (
        incoming: [Shared_Proto_Services_V1_IncomingContactRequest],
        sent: [Shared_Proto_Services_V1_SentContactRequest]
    ) {
        try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.getUserProfile) { grpcClient in
            let client = Shared_Proto_Services_V1_UserService.Client(wrapping: grpcClient)
            let request = Shared_Proto_Services_V1_GetContactRequestsRequest()
            let response = try await client.getContactRequests(request: .init(message: request))
            return (incoming: response.incoming, sent: response.sent)
        }
    }

    func respondToContactRequest(
        requestId: String,
        action: Shared_Proto_Services_V1_ContactRequestAction
    ) async throws {
        try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.getUserProfile) { grpcClient in
            let client = Shared_Proto_Services_V1_UserService.Client(wrapping: grpcClient)
            var request = Shared_Proto_Services_V1_RespondToContactRequestRequest()
            request.requestID = requestId
            request.action = action
            _ = try await client.respondToContactRequest(request: .init(message: request))
        }
    }
}
