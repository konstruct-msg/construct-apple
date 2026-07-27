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

    /// Send a contact request. Retries on transient transport blips ("Stream unexpectedly closed")
    /// — same pattern as AcceptInvite. Safe to retry: server returns the existing request id
    /// when a pending request already exists (dedup on from/to).
    ///
    /// - Parameters:
    ///   - toUserId: Recipient server user id.
    ///   - username: Sender username snapshot (normalized lowercase, no `@`). Empty/nil if none.
    ///   - displayName: Sender display name snapshot as shown in profile/QR UI.
    ///     Server stores both in an envelope-encrypted identity snapshot for the recipient inbox.
    func sendContactRequest(
        toUserId: String,
        username: String? = nil,
        displayName: String? = nil
    ) async throws -> String {
        let snapshotUsername = Self.normalizedRequestUsername(username)
        let snapshotDisplayName = (displayName ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return try await withRetry(
            maxAttempts: 3,
            backoff: 1.0,
            retryIf: Self.isTransientTransportError,
            label: "SendContactRequest"
        ) {
            // Invalidate the shared channel on transport failure so the next attempt
            // does not reuse a dead HTTP/2 stream (MessageStream disconnect often kills
            // the same persistent connection used by unary contact-request RPCs).
            try await GRPCChannelManager.shared.performRPC(
                timeout: GRPCTimeouts.sendContactRequest,
                invalidatesConnectionOnFailure: true
            ) { grpcClient in
                let client = Shared_Proto_Services_V1_UserService.Client(wrapping: grpcClient)
                var request = Shared_Proto_Services_V1_SendContactRequestRequest()
                request.toUserID = toUserId

                // Always set from_identity so recipients see @username / display name
                // without a profile fetch (server validates username against caller's hash).
                var identity = Shared_Proto_Services_V1_ContactIdentitySnapshot()
                identity.username = snapshotUsername
                identity.displayName = snapshotDisplayName
                request.fromIdentity = identity

                let response = try await client.sendContactRequest(request: .init(message: request))
                return response.requestID
            }
        }
    }

    /// Normalize username for `ContactIdentitySnapshot`: trim, lowercase, strip leading `@`.
    private static func normalizedRequestUsername(_ raw: String?) -> String {
        var trimmed = (raw ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if trimmed.hasPrefix("@") {
            trimmed = String(trimmed.dropFirst())
        }
        return trimmed
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
        try await withRetry(
            maxAttempts: 3,
            backoff: 1.0,
            retryIf: Self.isTransientTransportError,
            label: "RespondToContactRequest"
        ) {
            try await GRPCChannelManager.shared.performRPC(
                timeout: GRPCTimeouts.getUserProfile,
                invalidatesConnectionOnFailure: true
            ) { grpcClient in
                let client = Shared_Proto_Services_V1_UserService.Client(wrapping: grpcClient)
                var request = Shared_Proto_Services_V1_RespondToContactRequestRequest()
                request.requestID = requestId
                request.action = action
                _ = try await client.respondToContactRequest(request: .init(message: request))
            }
        }
    }

    /// Transient gRPC/transport failures worth a short backoff retry.
    /// Matches AcceptInvite: "Stream unexpectedly closed" during MessageStream disconnect
    /// or VEIL/channel invalidation must not surface as a hard UI failure on first try.
    private static func isTransientTransportError(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let rpc = error as? RPCError {
            switch rpc.code {
            // Transient transport / stream codes only — not ALREADY_EXISTS / rate-limit /
            // permission / invalidArgument (those are permanent application errors).
            case .unavailable, .deadlineExceeded, .cancelled, .unknown:
                return true
            default:
                break
            }
        }
        let desc = error.localizedDescription.lowercased()
        return desc.contains("stream")
            || desc.contains("unavailable")
            || desc.contains("closed")
            || desc.contains("reset")
            || desc.contains("connection")
    }
}

/// gRPC SentinelService client — user-driven spam reports that feed the server-side
/// auto-escalation (flag/ban) engine. The reporter identity is derived server-side from
/// the authenticated caller; the client supplies only the reported device id + a coarse
/// category (never message content). See construct-server `sentinel/grpc.rs`.
final class SentinelServiceClient: Sendable {
    static let shared = SentinelServiceClient()
    private init() {}

    /// Report a device for spam/abuse. `reportedDeviceId` is the peer's crypto device id
    /// (`deriveDeviceId(identityPublicKey:)` — the same `SHA256(identity_public)[0..16]` the
    /// server uses as its sentinel key). Returns whether the report was accepted.
    @discardableResult
    func reportSpam(
        reportedDeviceId: String,
        category: Shared_Proto_Sentinel_V1_SpamCategory = .unwanted
    ) async throws -> Bool {
        try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.reportSpam) { grpcClient in
            let client = Shared_Proto_Sentinel_V1_SentinelService.Client(wrapping: grpcClient)

            var request = Shared_Proto_Sentinel_V1_ReportSpamRequest()
            request.reportedDeviceID = reportedDeviceId
            request.category = category

            let response = try await client.reportSpam(request: .init(message: request))
            return response.accepted
        }
    }
}
