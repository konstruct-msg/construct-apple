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

    // Two RPCs were removed from InviteService on 2026-08-15 (server-side, see
    // construct-docs backend/INVITE_LIST_REVOKE_SERVER_SPEC.md), and their wrappers with
    // them:
    //
    //   GenerateInvite — a second invite issuer with a 300 s TTL against the device-minted
    //     v4's 12 h. Nothing on iOS or Android called it; it was the parallel invite system
    //     decisions/invite-two-modes-deferred forbids, arrived at by accretion.
    //   ListInvites — answered OK with an empty list, always. The server never sees an
    //     invite before it is redeemed or revoked, so there is nothing to list; a screen
    //     built on it would have reported "no outstanding invites" forever. The issuing
    //     device keeps that journal.

    // MARK: - Accept Invite

    func acceptInvite(invite: Shared_Proto_Services_V1_AcceptInviteRequest) async throws -> Shared_Proto_Services_V1_AcceptInviteResponse {
        try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.acceptInvite) { grpcClient in
            let client = Shared_Proto_Services_V1_InviteService.Client(wrapping: grpcClient)

            return try await client.acceptInvite(request: .init(message: invite))
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
