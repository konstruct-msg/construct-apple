//
//  InviteServiceClient.swift
//  Construct Messenger
//
//  gRPC InviteService client — invite generation and acceptance
//

import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2


final class InviteServiceClient: Sendable {
    static let shared = InviteServiceClient()

    private init() {}

    // MARK: - Generate Invite

    func generateInvite(ttlSeconds: Int64 = 86400) async throws -> Shared_Proto_Services_V1_GenerateInviteResponse {
        try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.generateInvite) { grpcClient in
            let client = Shared_Proto_Services_V1_InviteService.Client(wrapping: grpcClient)

            var request = Shared_Proto_Services_V1_GenerateInviteRequest()
            request.ttlSeconds = ttlSeconds

            return try await client.generateInvite(request: .init(message: request))
        }
    }

    // MARK: - Accept Invite

    func acceptInvite(invite: Shared_Proto_Services_V1_AcceptInviteRequest) async throws -> Shared_Proto_Services_V1_AcceptInviteResponse {
        try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.acceptInvite) { grpcClient in
            let client = Shared_Proto_Services_V1_InviteService.Client(wrapping: grpcClient)

            return try await client.acceptInvite(request: .init(message: invite))
        }
    }

    // MARK: - List Invites

    func listInvites(limit: Int32 = 20, includeExpired: Bool = false) async throws -> Shared_Proto_Services_V1_ListInvitesResponse {
        try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.listInvites) { grpcClient in
            let client = Shared_Proto_Services_V1_InviteService.Client(wrapping: grpcClient)

            var request = Shared_Proto_Services_V1_ListInvitesRequest()
            request.limit = limit
            request.includeExpired = includeExpired

            return try await client.listInvites(request: .init(message: request))
        }
    }

    // MARK: - Revoke Invite

    func revokeInvite(jti: String) async throws -> Bool {
        try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.revokeInvite) { grpcClient in
            let client = Shared_Proto_Services_V1_InviteService.Client(wrapping: grpcClient)

            var request = Shared_Proto_Services_V1_RevokeInviteRequest()
            request.jti = jti

            let response = try await client.revokeInvite(request: .init(message: request))
            return response.success
        }
    }
}
