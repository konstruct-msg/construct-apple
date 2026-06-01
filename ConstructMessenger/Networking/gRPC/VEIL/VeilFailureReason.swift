//
//  VeilFailureReason.swift
//  Construct Messenger
//
//  Typed classification of VEIL/relay transport failures.
//

import Foundation

/// Categorized reason for an VEIL relay failure.
///
/// Used by `VeilFailurePolicy.classify` to distinguish transport-layer failures
/// (which require VEIL failover) from application-layer errors (auth, validation, etc.).
enum VeilFailureReason: Sendable, Equatable {
    /// WebTunnel blocked by a transparent HTTP proxy (non-200/404 on WebSocket upgrade).
    case webTunnelBlocked
    
    /// TLS certificate expired or invalid.
    case tlsCertExpired
    
    /// TLS fingerprint blocked by DPI (alert 40 / handshake_failure).
    case tlsFingerprintBlocked
    
    /// Local VEIL proxy process died (ECONNREFUSED on 127.0.0.1).
    case staleLocalProxy
    
    /// Stream timeout on unverified relay (DPI block, congestion, etc.).
    case streamTimeout
    
    /// Unknown transport failure not matching other cases.
    case transportUnknown
}
