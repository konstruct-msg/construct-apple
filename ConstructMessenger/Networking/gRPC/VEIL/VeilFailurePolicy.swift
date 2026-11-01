//
//  VeilFailurePolicy.swift
//  Construct Messenger
//
//  Pure classification function for VEIL transport failures.
//

import Foundation
import GRPCCore

/// Pure classifier for VEIL/relay transport failures.
///
/// This type contains no state and performs no I/O. It exists to make
/// transport-layer error classification testable and to enforce the invariant
/// that transport errors are handled before application-layer auth retry.
enum VeilFailurePolicy {
    /// Classify an error as a transport-layer VEIL failure, or nil if application-layer.
    /// `method` is captured with the failed call's route; a later rotation cannot change it.
    ///
    /// - Returns: `VeilFailureReason` if the error represents a transport failure that
    ///            should trigger VEIL failover; `nil` for application errors (auth, validation, etc.).
    static func classify(_ error: Error, method: VeilMethod? = nil) -> VeilFailureReason? {
        // Local proxy dead — distinct from relay failure.
        if isStaleLocalProxy(error) { return .staleLocalProxy }
        
        guard let rpc = error as? RPCError else {
            // Non-RPC errors (e.g. NWError, POSIXError) are transport-layer.
            return .transportUnknown
        }
        
        switch rpc.code {
        case .unimplemented:
            // "Unexpected non-200 HTTP Status Code" → relay decoy 404 on WebTunnel — only when
            // WebTunnel carries the call. Over veil-front or direct TLS a 404 is the server's own
            // answer to a method it does not serve: on 2026-10-14 a server without
            // ServerTrustService answered 404 and a working veil-front tunnel was torn down as
            // "WebTunnel blocked" on every trust refresh.
            if method == .webTunnel, isWebTunnelBlocked(rpc) { return .webTunnelBlocked }
            return nil  // Other unimplemented errors are application-layer.
            
        case .unavailable, .unknown:
            // TLS cert expiry.
            if isTLSCertExpired(rpc) { return .tlsCertExpired }
            // TLS fingerprint blocked (alert 40).
            if isTLSFingerprintBlocked(rpc) { return .tlsFingerprintBlocked }
            // Generic transport unavailable.
            return .transportUnknown
            
        case .deadlineExceeded:
            return .streamTimeout
            
        default:
            // Auth, permission, validation, not-found, etc. are application-layer.
            return nil
        }
    }
    
    // MARK: - Classification predicates (moved from GRPCCallExecutor)
    
    /// True when the error is ECONNREFUSED on the local VEIL proxy port (127.0.0.1).
    private static func isStaleLocalProxy(_ error: Error) -> Bool {
        guard let rpc = error as? RPCError, rpc.code == .unavailable else { return false }
        return rpc.message.contains(GRPCMessages.localProxyAddr)
    }
    
    /// True when a transparent HTTP proxy intercepted the WebSocket UPGRADE and returned
    /// a non-101/non-200 response instead of forwarding it to the relay.
    private static func isWebTunnelBlocked(_ rpc: RPCError) -> Bool {
        let msg = rpc.message.lowercased()
        return msg.contains(GRPCMessages.nonHttpUpgrade)
            || msg.contains(GRPCMessages.httpStatusCode)
            || (msg.contains(GRPCMessages.unexpectedHttp) && msg.contains("http"))
    }
    
    /// True when the TLS connection failed due to an expired or untrusted certificate.
    private static func isTLSCertExpired(_ rpc: RPCError) -> Bool {
        let msg = rpc.message.lowercased()
        return (msg.contains(GRPCMessages.tlsCertificate)
                && (msg.contains("expired") || msg.contains("verify") || msg.contains("invalid")))
            || msg.contains(GRPCMessages.tlsCertVerifyFailed)
    }
    
    /// True when TLS alert 40 (handshake_failure) is returned, indicating the relay's
    /// TLS fingerprint is blocked by DPI at the network level.
    private static func isTLSFingerprintBlocked(_ rpc: RPCError) -> Bool {
        let msg = rpc.message.lowercased()
        return (msg.contains(GRPCMessages.tlsHandshakeAlert) && msg.contains("40"))
            || msg.contains(GRPCMessages.tlsHandshakeFailure)
    }
}
