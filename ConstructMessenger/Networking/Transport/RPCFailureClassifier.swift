//
//  RPCFailureClassifier.swift
//  Construct Messenger
//
//  Bridges raw RPC errors to the transport-router's `RPCFailureKind`.
//
//  This is the single place that maps gRPC concerns to FSM concerns. The reducer
//  must never see a raw `Error` — only a classified `RPCFailureKind` — so this
//  classifier is the boundary.
//
//  Built on top of the existing `VeilFailurePolicy` so we don't duplicate the
//  message-text heuristics; this file only translates the result.
//

import Foundation
import GRPCCore

enum RPCFailureClassifier {
    /// Classify any error thrown by a gRPC call.
    static func classify(_ error: Error) -> RPCFailureKind {
        if error is CancellationError { return .transientCancellation }
        if error is GRPCClientError { return .transientCancellation }
        if let rpc = error as? RPCError, rpc.code == .cancelled { return .transientCancellation }

        if let reason = VeilFailurePolicy.classify(error) {
            return translate(reason)
        }

        // Not a transport failure as classified by VeilFailurePolicy — likely application-layer.
        if let rpc = error as? RPCError {
            switch rpc.code {
            case .unauthenticated, .permissionDenied:
                return .authRejected
            default:
                return .applicationError
            }
        }
        return .transportUnknown
    }

    /// Public variant of the VeilFailureReason→RPCFailureKind translation, for code
    /// paths that already have an VeilFailureReason on hand (e.g. nested auth-retry).
    static func classifyVEILReason(_ reason: VeilFailureReason) -> RPCFailureKind {
        translate(reason)
    }

    private static func translate(_ reason: VeilFailureReason) -> RPCFailureKind {
        switch reason {
        case .staleLocalProxy:          return .staleLocalProxy
        case .webTunnelBlocked:         return .webTunnelBlocked
        case .tlsCertExpired:           return .tlsCertExpired
        case .tlsFingerprintBlocked:    return .tlsFingerprintBlocked
        case .streamTimeout:            return .streamTimeout
        case .transportUnknown:         return .transportUnknown
        }
    }
}
