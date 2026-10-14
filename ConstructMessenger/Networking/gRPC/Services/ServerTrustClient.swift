//
//  ServerTrustClient.swift
//  Construct Messenger
//
//  The server's public trust material — the signed manifest and the server-key delegations —
//  asked over gRPC, so a client with VEIL `on` receives it through the tunnel instead of going
//  around it to `/.well-known` (vault decisions/veil-on-never-goes-direct.md).
//
//  Nothing here is trusted for having arrived this way: the manifest goes through the same
//  signature and freshness check as the HTTPS fetch (`VeilCertFetcher.acceptManifest`), the
//  delegations through the core's root check, and both are stored by the same rule.
//

import Foundation
import GRPCCore

enum ServerTrustClient {

    /// Ask the server and store what verifies. Under `on` with no tunnel up the channel refuses
    /// (`VeilTunnelNotUp`) and nothing is asked; the cache stands.
    @discardableResult
    static func refresh() async -> [RelayInfo]? {
        let response: Shared_Proto_Services_V1_GetServerTrustResponse
        do {
            response = try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.serverTrust) { grpcClient in
                let client = Shared_Proto_Services_V1_ServerTrustService.Client(wrapping: grpcClient)
                return try await client.getServerTrust(request: .init(message: .init()))
            }
        } catch {
            Log.debug("ServerTrust: not refreshed — \(error)", category: "VEIL")
            return nil
        }
        return apply(response)
    }

    /// What a response changes, apart from the network. An empty field leaves the cache alone:
    /// the server has nothing to say about it, which is not the same as "forget it".
    @discardableResult
    static func apply(_ response: Shared_Proto_Services_V1_GetServerTrustResponse) -> [RelayInfo]? {
        ServerKeyManager.storeServerDelegations(response.delegations)
        guard !response.signedManifest.isEmpty else { return nil }
        do {
            return try VeilCertFetcher.shared.acceptManifest(response.signedManifest, source: "ServerTrustService")
        } catch {
            Log.error("ServerTrust: manifest unreadable — \(error)", category: "VEIL")
            return nil
        }
    }
}
