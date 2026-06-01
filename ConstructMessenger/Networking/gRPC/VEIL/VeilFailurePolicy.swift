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
    ///
    /// - Returns: `VeilFailureReason` if the error represents a transport failure that
    ///            should trigger VEIL failover; `nil` for application errors (auth, validation, etc.).
    static func classify(_ error: Error) -> VeilFailureReason? {
        // Local proxy dead — distinct from relay failure.
        if isStaleLocalProxy(error) { return .staleLocalProxy }
        
        guard let rpc = error as? RPCError else {
            // Non-RPC errors (e.g. NWError, POSIXError) are transport-layer.
            return .transportUnknown
        }
        
        switch rpc.code {
        case .unimplemented:
            // "Unexpected non-200 HTTP Status Code" → relay decoy 404 on WebTunnel.
            if isWebTunnelBlocked(rpc) { return .webTunnelBlocked }
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
    
    /// Map a failure reason to the corresponding relay blacklist TTL.
    ///
    /// - Parameter reason: The classified failure reason.
    /// - Returns: RelayFailureType with appropriate TTL for blacklist.
    static func relayFailureType(for reason: VeilFailureReason) -> RelayFailureType {
        switch reason {
        case .staleLocalProxy:
            // Local proxy crash — no blacklist needed (coordinator handles restart).
            return .streamTimeout  // fallback
        case .webTunnelBlocked:
            return .webTunnelBlocked
        case .tlsCertExpired:
            return .tlsHandshake
        case .tlsFingerprintBlocked:
            return .fingerprintBlocked
        case .streamTimeout:
            return .streamTimeout
        case .transportUnknown:
            return .streamTimeout  // default
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
