//
//  VeilFailurePolicyTests.swift
//  ConstructMessengerTests
//
//  Unit tests for ICE failure classification policy.
//  Pure function tests — no I/O, no async.
//

import XCTest
import GRPCCore
@testable import Construct_Messenger

final class VeilFailurePolicyTests: XCTestCase {

    // MARK: - Helper
    
    private func makeRPCError(code: RPCError.Code, message: String) -> RPCError {
        RPCError(code: code, message: message)
    }
    
    // MARK: - Classification: Stale Local Proxy
    
    func testClassify_ECONNREFUSED_LocalProxy() {
        let error = makeRPCError(code: .unavailable, message: "Connection refused (127.0.0.1:54952)")
        let reason = VeilFailurePolicy.classify(error)
        XCTAssertEqual(reason, .staleLocalProxy)
    }
    
    func testClassify_ECONNREFUSED_DifferentPort() {
        let error = makeRPCError(code: .unavailable, message: "Connection refused (192.168.1.1:443)")
        let reason = VeilFailurePolicy.classify(error)
        XCTAssertNotEqual(reason, .staleLocalProxy)
    }
    
    // MARK: - Classification: WebTunnel Blocked
    
    func testClassify_WebTunnelBlocked_NonHttpUpgrade() {
        let error = makeRPCError(code: .unimplemented, message: "Unexpected non-200 HTTP Status Code (404 Not Found)")
        let reason = VeilFailurePolicy.classify(error, method: .webTunnel)
        XCTAssertEqual(reason, .webTunnelBlocked)
    }
    
    func testClassify_WebTunnelBlocked_HTTPStatusCode() {
        let error = makeRPCError(code: .unimplemented, message: "HTTP Status Code: 403 Forbidden")
        let reason = VeilFailurePolicy.classify(error, method: .webTunnel)
        XCTAssertEqual(reason, .webTunnelBlocked)
    }
    
    func testClassify_WebTunnelBlocked_UnexpectedHttp() {
        let error = makeRPCError(code: .unimplemented, message: "Unexpected HTTP response from upstream")
        let reason = VeilFailurePolicy.classify(error, method: .webTunnel)
        XCTAssertEqual(reason, .webTunnelBlocked)
    }
    
    /// 2026-10-14: a server without ServerTrustService answered 404 through a working veil-front
    /// tunnel, and the tunnel was torn down as "WebTunnel blocked". Without WebTunnel a status
    /// code is the server's answer, and the transport is fine.
    func testA404OverVeilFrontIsTheServersAnswerNotABlock() {
        let error = makeRPCError(code: .unimplemented, message: "Unexpected non-200 HTTP Status Code (404 Not Found).")
        XCTAssertNil(VeilFailurePolicy.classify(error, method: .veilFront))
        XCTAssertEqual(RPCFailureClassifier.classify(error), .applicationError, "neutral for transport health")
    }

    func testClassify_Unimplemented_NotWebTunnel() {
        let error = makeRPCError(code: .unimplemented, message: "Method not found: /construct.v1.UserService/GetProfile")
        let reason = VeilFailurePolicy.classify(error)
        XCTAssertNil(reason, "Application-layer unimplemented should return nil")
    }
    
    // MARK: - Classification: TLS Cert Expired
    
    func testClassify_TLSCertExpired() {
        let error = makeRPCError(code: .unavailable, message: "TLS certificate expired")
        let reason = VeilFailurePolicy.classify(error)
        XCTAssertEqual(reason, .tlsCertExpired)
    }
    
    func testClassify_TLSCertVerifyFailed() {
        let error = makeRPCError(code: .unknown, message: "tls: failed to verify certificate: x509: certificate has expired")
        let reason = VeilFailurePolicy.classify(error)
        XCTAssertEqual(reason, .tlsCertExpired)
    }
    
    func testClassify_TLSCertInvalid() {
        let error = makeRPCError(code: .unavailable, message: "TLS handshake failed: certificate invalid")
        let reason = VeilFailurePolicy.classify(error)
        XCTAssertEqual(reason, .tlsCertExpired)
    }
    
    // MARK: - Classification: TLS Fingerprint Blocked
    
    func testClassify_TLSFingerprintBlocked_Alert40() {
        let error = makeRPCError(code: .unavailable, message: "tls: handshake failure (alert 40)")
        let reason = VeilFailurePolicy.classify(error)
        XCTAssertEqual(reason, .tlsFingerprintBlocked)
    }
    
    func testClassify_TLSFingerprintBlocked_HandshakeFailure() {
        let error = makeRPCError(code: .unknown, message: "tls: handshake_failure from server")
        let reason = VeilFailurePolicy.classify(error)
        XCTAssertEqual(reason, .tlsFingerprintBlocked)
    }
    
    // MARK: - Classification: Stream Timeout
    
    func testClassify_StreamTimeout() {
        let error = makeRPCError(code: .deadlineExceeded, message: "stream timeout")
        let reason = VeilFailurePolicy.classify(error)
        XCTAssertEqual(reason, .streamTimeout)
    }
    
    // MARK: - Classification: Transport Unknown
    
    func testClassify_TransportUnknown_Unavailable() {
        let error = makeRPCError(code: .unavailable, message: "connection lost")
        let reason = VeilFailurePolicy.classify(error)
        XCTAssertEqual(reason, .transportUnknown)
    }
    
    func testClassify_TransportUnknown_Unknown() {
        let error = makeRPCError(code: .unknown, message: "network error")
        let reason = VeilFailurePolicy.classify(error)
        XCTAssertEqual(reason, .transportUnknown)
    }
    
    func testClassify_NonRPCError() {
        struct TestError: Error {}
        let error = TestError()
        let reason = VeilFailurePolicy.classify(error)
        XCTAssertEqual(reason, .transportUnknown)
    }
    
    // MARK: - Classification: Application-Layer Errors (Should Return Nil)
    
    func testClassify_Unauthenticated() {
        let error = makeRPCError(code: .unauthenticated, message: "Session token expired")
        let reason = VeilFailurePolicy.classify(error)
        XCTAssertNil(reason, "Auth errors should return nil")
    }
    
    func testClassify_PermissionDenied() {
        let error = makeRPCError(code: .permissionDenied, message: "Access denied")
        let reason = VeilFailurePolicy.classify(error)
        XCTAssertNil(reason)
    }
    
    func testClassify_InvalidArgument() {
        let error = makeRPCError(code: .invalidArgument, message: "Invalid user ID")
        let reason = VeilFailurePolicy.classify(error)
        XCTAssertNil(reason)
    }
    
    func testClassify_NotFound() {
        let error = makeRPCError(code: .notFound, message: "User not found")
        let reason = VeilFailurePolicy.classify(error)
        XCTAssertNil(reason)
    }
    
    func testClassify_Cancelled() {
        let error = makeRPCError(code: .cancelled, message: "Call cancelled by client")
        let reason = VeilFailurePolicy.classify(error)
        XCTAssertNil(reason)
    }
    
    // MARK: - Our own deadline

    /// 2026-10-17, TODO 159: a relay that accepts the connection and carries nothing ends every
    /// RPC on our own deadline. That was classified as a cancellation, which the router does not
    /// count, so the relay was never rotated; Android counts it (DEADLINE_EXCEEDED → STREAM_TIMEOUT).
    /// Mutation: map `clientSideTimeout` back to `.transientCancellation` — both assertions redden.
    func testOurOwnDeadlineIsASoftFailureThatRotatesTheRelay() {
        XCTAssertEqual(RPCFailureClassifier.classify(GRPCClientError.clientSideTimeout), .streamTimeout)

        let kind = RPCFailureClassifier.classify(GRPCClientError.clientSideTimeout)
        let via = TransportTarget.veil(port: 7000, relay: "r")
        var state = TransportState.veilActive(relay: "r", port: 7000, since: Date(timeIntervalSince1970: 0))
        for _ in 0..<TransportConfig().veilSoftFailThreshold {
            state = TransportReducer.route(
                state: state,
                event: .rpcFailed(kind: kind, via: via, foreground: true, lane: .sealed),
                mode: .on, config: TransportConfig(), now: Date(timeIntervalSince1970: 60)
            ).state
        }
        XCTAssertEqual(state, .veilProbing, "three timeouts in a row on one lane rotate the relay")
    }

    func testTheCallerGivingUpIsStillNotCounted() {
        XCTAssertEqual(RPCFailureClassifier.classify(CancellationError()), .transientCancellation)
    }

    // MARK: - The person reads it

    func testNoTunnelSaysSoInWords() {
        let text = VeilTunnelNotUp().localizedDescription
        XCTAssertFalse(text.contains("VeilTunnelNotUp"), text)
        XCTAssertEqual(text, NSLocalizedString("veil_tunnel_not_up", comment: ""))
    }
}
