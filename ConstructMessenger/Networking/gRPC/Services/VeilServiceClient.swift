//
//  VeilServiceClient.swift
//  Construct Messenger
//
//  Client wrapper for VeilService.IssueVeilCapability — in-band renewal of the
//  backend-signed veil-front capability (B2). The first capability arrives
//  out-of-band (QR / konstruct://veil-config / pasted blob); near expiry the client
//  renews it over the already-up transport via this RPC, so testers never have to
//  re-provision manually. See decisions/veil-ticket-provisioning-system.md (P4d).
//
//  The call routes through `GRPCChannelManager.performRPC`, i.e. over whatever
//  transport is currently active — when VEIL is up it renews in-band through the
//  tunnel. JWT-gated: the session token is attached at the channel level and envoy
//  injects `x-user-id` from it.
//

import Foundation
import GRPCCore

final class VeilServiceClient: Sendable {
    static let shared = VeilServiceClient()
    private init() {}

    /// A freshly issued, backend-signed capability plus the relay's confirmed network
    /// parameters. `capability` is the canonical signed blob (Capability::encode bytes).
    struct IssuedCapability: Sendable {
        let capability: Data
        let relayAddress: String
        let spki: String        // hex SHA-256 SPKI pin
        let sni: String
        let notAfter: Int64      // unix expiry of the new capability
    }

    /// Request a fresh capability for `relayAddress`. `currentTicketId` optionally
    /// references the capability being replaced (rotation accounting). Throws on RPC
    /// failure; the caller validates the returned blob before storing it.
    func issueCapability(relayAddress: String, currentTicketId: Data? = nil) async throws -> IssuedCapability {
        try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.issueVeilCapability) { grpcClient in
            let client = Shared_Proto_Services_V1_VeilService.Client(wrapping: grpcClient)

            var request = Shared_Proto_Services_V1_IssueVeilCapabilityRequest()
            request.relayAddress = relayAddress
            if let currentTicketId, !currentTicketId.isEmpty {
                request.currentTicketID = currentTicketId
            }

            let response = try await client.issueVeilCapability(request: .init(message: request))
            return IssuedCapability(
                capability: response.capability,
                relayAddress: response.relayAddress.isEmpty ? relayAddress : response.relayAddress,
                spki: response.spki,
                sni: response.sni,
                notAfter: response.notAfter
            )
        }
    }
}
