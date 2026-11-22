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

/// Marker for errors that originate ABOVE the transport layer — crypto, bundle,
/// or session validation that runs on an RPC's *response*. The call physically
/// reached the server and returned a payload; the failure is in interpreting
/// that payload, so it must never be counted as a transport failure. Counting it
/// as one spuriously increments the consecutive-fail counter (flipping the status
/// indicator to "Connecting…" on a healthy link) and can even trigger VEIL
/// failover for a non-network problem. Conforming types are routed to
/// `.applicationError`, which is neutral for transport health.
protocol ApplicationLayerError: Error {}

enum RPCFailureClassifier {
    /// Classify any error thrown by a gRPC call.
    static func classify(_ error: Error, method: VeilMethod? = nil) -> RPCFailureKind {
        if error is CancellationError { return .transientCancellation }
        // Our own deadline elapsed with no answer. Not "the connection is healthy": a relay that
        // accepts the connection and carries nothing looks exactly like this, and it is the case
        // the soft-failure count exists for. Android counts the same thing — a client deadline
        // reaches its interceptor as DEADLINE_EXCEEDED → STREAM_TIMEOUT.
        if case GRPCClientError.clientSideTimeout = error { return .streamTimeout }
        if let rpc = error as? RPCError, rpc.code == .cancelled { return .transientCancellation }

        // Application-layer validation (bundle/crypto/session) rides on top of a
        // transport call that actually succeeded — classify before the transport
        // heuristics below, which would otherwise bucket any non-RPCError as
        // `.transportUnknown`.
        if error is ApplicationLayerError { return .applicationError }

        // The server's edge answered — before the heuristics below, which read any UNAVAILABLE as
        // the path's failure. Not over WebTunnel, where a middlebox can answer the upgrade itself.
        if method != .webTunnel, let rpc = error as? RPCError, let status = edgeHTTPStatus(rpc.message), (500...599).contains(status) {
            return .serverNotReady
        }

        if let reason = VeilFailurePolicy.classify(error, method: method) {
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

    /// The HTTP status of a response that carried no gRPC status, from the message grpc-swift
    /// gives it ("Unexpected non-200 HTTP Status Code (502 Bad Gateway)." —
    /// `GRPCStreamStateMachine.clientValidateHeadersReceivedFromServer`); nil for anything else.
    /// Over VEIL the inner HTTP/2 is the server's: the relay ferries bytes and writes no status
    /// (construct-veil `crates/construct-veil-relay/src/tunnel.rs`), so the answer is Caddy's.
    static func edgeHTTPStatus(_ message: String) -> Int? {
        let prefix = "Unexpected non-200 HTTP Status Code ("
        guard let start = message.range(of: prefix)?.upperBound else { return nil }
        let digits = message[start...].prefix(3)
        guard digits.count == 3, digits.allSatisfy(\.isNumber) else { return nil }
        return Int(digits)
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
