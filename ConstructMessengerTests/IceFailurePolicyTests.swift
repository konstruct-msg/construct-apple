//
//  IceFailurePolicyTests.swift
//  ConstructMessengerTests
//
//  Unit tests for ICE failure classification policy.
//  Pure function tests — no I/O, no async.
//

import XCTest
import GRPCCore
@testable import Construct_Messenger

final class IceFailurePolicyTests: XCTestCase {
    
    // MARK: - Helper
    
    private func makeRPCError(code: RPCCode, message: String) -> RPCError {
        RPCError(code: code, message: message)
    }
    
    // MARK: - Classification: Stale Local Proxy
    
    func testClassify_ECONNREFUSED_LocalProxy() {
        let error = makeRPCError(code: .unavailable, message: "Connection refused (127.0.0.1:54952)")
        let reason = IceFailurePolicy.classify(error)
        XCTAssertEqual(reason, .staleLocalProxy)
    }
    
    func testClassify_ECONNREFUSED_DifferentPort() {
        let error = makeRPCError(code: .unavailable, message: "Connection refused (192.168.1.1:443)")
        let reason = IceFailurePolicy.classify(error)
        XCTAssertNotEqual(reason, .staleLocalProxy)
    }
    
    // MARK: - Classification: WebTunnel Blocked
    
    func testClassify_WebTunnelBlocked_NonHttpUpgrade() {
        let error = makeRPCError(code: .unimplemented, message: "Unexpected non-200 HTTP Status Code (404 Not Found)")
        let reason = IceFailurePolicy.classify(error)
        XCTAssertEqual(reason, .webTunnelBlocked)
    }
    
    func testClassify_WebTunnelBlocked_HTTPStatusCode() {
        let error = makeRPCError(code: .unimplemented, message: "HTTP Status Code: 403 Forbidden")
        let reason = IceFailurePolicy.classify(error)
        XCTAssertEqual(reason, .webTunnelBlocked)
    }
    
    func testClassify_WebTunnelBlocked_UnexpectedHttp() {
        let error = makeRPCError(code: .unimplemented, message: "Unexpected HTTP response from upstream")
        let reason = IceFailurePolicy.classify(error)
        XCTAssertEqual(reason, .webTunnelBlocked)
    }
    
    func testClassify_Unimplemented_NotWebTunnel() {
        let error = makeRPCError(code: .unimplemented, message: "Method not found: /construct.v1.UserService/GetProfile")
        let reason = IceFailurePolicy.classify(error)
        XCTAssertNil(reason, "Application-layer unimplemented should return nil")
    }
    
    // MARK: - Classification: TLS Cert Expired
    
    func testClassify_TLSCertExpired() {
        let error = makeRPCError(code: .unavailable, message: "TLS certificate expired")
        let reason = IceFailurePolicy.classify(error)
        XCTAssertEqual(reason, .tlsCertExpired)
    }
    
    func testClassify_TLSCertVerifyFailed() {
        let error = makeRPCError(code: .unknown, message: "tls: failed to verify certificate: x509: certificate has expired")
        let reason = IceFailurePolicy.classify(error)
        XCTAssertEqual(reason, .tlsCertExpired)
    }
    
    func testClassify_TLSCertInvalid() {
        let error = makeRPCError(code: .unavailable, message: "TLS handshake failed: certificate invalid")
        let reason = IceFailurePolicy.classify(error)
        XCTAssertEqual(reason, .tlsCertExpired)
    }
    
    // MARK: - Classification: TLS Fingerprint Blocked
    
    func testClassify_TLSFingerprintBlocked_Alert40() {
        let error = makeRPCError(code: .unavailable, message: "tls: handshake failure (alert 40)")
        let reason = IceFailurePolicy.classify(error)
        XCTAssertEqual(reason, .tlsFingerprintBlocked)
    }
    
    func testClassify_TLSFingerprintBlocked_HandshakeFailure() {
        let error = makeRPCError(code: .unknown, message: "TLS handshake failure")
        let reason = IceFailurePolicy.classify(error)
        XCTAssertEqual(reason, .tlsFingerprintBlocked)
    }
    
    // MARK: - Classification: Stream Timeout
    
    func testClassify_StreamTimeout() {
        let error = makeRPCError(code: .deadlineExceeded, message: "stream timeout")
        let reason = IceFailurePolicy.classify(error)
        XCTAssertEqual(reason, .streamTimeout)
    }
    
    // MARK: - Classification: Transport Unknown
    
    func testClassify_TransportUnknown_Unavailable() {
        let error = makeRPCError(code: .unavailable, message: "connection lost")
        let reason = IceFailurePolicy.classify(error)
        XCTAssertEqual(reason, .transportUnknown)
    }
    
    func testClassify_TransportUnknown_Unknown() {
        let error = makeRPCError(code: .unknown, message: "network error")
        let reason = IceFailurePolicy.classify(error)
        XCTAssertEqual(reason, .transportUnknown)
    }
    
    func testClassify_NonRPCError() {
        struct TestError: Error {}
        let error = TestError()
        let reason = IceFailurePolicy.classify(error)
        XCTAssertEqual(reason, .transportUnknown)
    }
    
    // MARK: - Classification: Application-Layer Errors (Should Return Nil)
    
    func testClassify_Unauthenticated() {
        let error = makeRPCError(code: .unauthenticated, message: "Session token expired")
        let reason = IceFailurePolicy.classify(error)
        XCTAssertNil(reason, "Auth errors should return nil")
    }
    
    func testClassify_PermissionDenied() {
        let error = makeRPCError(code: .permissionDenied, message: "Access denied")
        let reason = IceFailurePolicy.classify(error)
        XCTAssertNil(reason)
    }
    
    func testClassify_InvalidArgument() {
        let error = makeRPCError(code: .invalidArgument, message: "Invalid user ID")
        let reason = IceFailurePolicy.classify(error)
        XCTAssertNil(reason)
    }
    
    func testClassify_NotFound() {
        let error = makeRPCError(code: .notFound, message: "User not found")
        let reason = IceFailurePolicy.classify(error)
        XCTAssertNil(reason)
    }
    
    func testClassify_Cancelled() {
        let error = makeRPCError(code: .cancelled, message: "Call cancelled by client")
        let reason = IceFailurePolicy.classify(error)
        XCTAssertNil(reason)
    }
    
    // MARK: - Relay Failure Type Mapping
    
    func testRelayFailureType_WebTunnelBlocked() {
        let type = IceFailurePolicy.relayFailureType(for: .webTunnelBlocked)
        XCTAssertEqual(type, .webTunnelBlocked)
    }
    
    func testRelayFailureType_TLSCertExpired() {
        let type = IceFailurePolicy.relayFailureType(for: .tlsCertExpired)
        XCTAssertEqual(type, .tlsHandshake)
    }
    
    func testRelayFailureType_TLSFingerprintBlocked() {
        let type = IceFailurePolicy.relayFailureType(for: .tlsFingerprintBlocked)
        XCTAssertEqual(type, .fingerprintBlocked)
    }
    
    func testRelayFailureType_StreamTimeout() {
        let type = IceFailurePolicy.relayFailureType(for: .streamTimeout)
        XCTAssertEqual(type, .streamTimeout)
    }
    
    func testRelayFailureType_StaleLocalProxy() {
        let type = IceFailurePolicy.relayFailureType(for: .staleLocalProxy)
        XCTAssertEqual(type, .streamTimeout, "Local proxy crash maps to streamTimeout as fallback")
    }
    
    func testRelayFailureType_TransportUnknown() {
        let type = IceFailurePolicy.relayFailureType(for: .transportUnknown)
        XCTAssertEqual(type, .streamTimeout, "Unknown failures default to streamTimeout TTL")
    }
    
    // MARK: - Event Conversion
    
    func testEvent_WebTunnelBlocked() {
        let event = IceFailurePolicy.event(for: .webTunnelBlocked, address: "relay:443")
        XCTAssertEqual(event, .webTunnelBlocked(address: "relay:443"))
    }
    
    func testEvent_RelayFailed_StreamTimeout() {
        let event = IceFailurePolicy.event(for: .streamTimeout, address: "relay:443")
        XCTAssertEqual(event, .relayFailed(address: "relay:443", reason: .streamTimeout))
    }
    
    func testEvent_StaleLocalProxy() {
        let event = IceFailurePolicy.event(for: .staleLocalProxy, address: nil)
        XCTAssertEqual(event, .foregroundProxyDead, "Stale local proxy maps to foregroundProxyDead event")
    }
    
    func testEvent_NilAddress() {
        let event = IceFailurePolicy.event(for: .streamTimeout, address: nil)
        XCTAssertNil(event, "Event requires address for relayFailed")
    }
    
    // MARK: - TTL Verification (Integration with RelayFailureType)
    
    func testTTL_WebTunnelBlocked() {
        let type: RelayFailureType = .webTunnelBlocked
        XCTAssertEqual(type.ttl, 180, "WebTunnel blocked should have 180s TTL")
    }
    
    func testTTL_TLSCertExpired() {
        let type: RelayFailureType = .tlsHandshake
        XCTAssertEqual(type.ttl, 300, "TLS handshake/cert errors should have 300s TTL")
    }
    
    func testTTL_FingerprintBlocked() {
        let type: RelayFailureType = .fingerprintBlocked
        XCTAssertEqual(type.ttl, 120, "Fingerprint blocked should have 120s TTL")
    }
    
    func testTTL_StreamTimeout() {
        let type: RelayFailureType = .streamTimeout
        XCTAssertEqual(type.ttl, 60, "Stream timeout should have 60s TTL")
    }
}
