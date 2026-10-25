//
//  TokenUtilsTests.swift
//  ConstructMessengerTests
//

import XCTest
@testable import Construct_Messenger

final class TokenUtilsTests: XCTestCase {

    // MARK: - Fixtures

    /// A real-looking PASETO v4.public token crafted so that `sub` can be extracted.
    /// Structure: "v4.public." + base64url(nonce[32] || message[JSON] || signature[64])
    /// Signature bytes are zeros — we don't verify on the client, so any 64 bytes work.
    private let pasetoTokenUserId = "14f28d31-7c3f-4c97-8ef0-7a1111111111"

    private lazy var pasetoToken: String = {
        let nonce = Data(repeating: 0xAB, count: 32)
        let claims: [String: Any] = [
            "sub": pasetoTokenUserId,
            "jti": "test-jti",
            "exp": 1893456000,
            "iat": 1700000000,
            "iss": "construct-server"
        ]
        let message = try! JSONSerialization.data(withJSONObject: claims)
        let signature = Data(repeating: 0x00, count: 64)
        let payload = nonce + message + signature
        let payloadB64 = payload.base64URLEncodedString()
        return "v4.public.\(payloadB64)"
    }()

    /// A legacy RS256 JWT with a readable `sub`: well-formed, so a rejection is the format's,
    /// not a parse failure's. Not accepted since 2026-10-24.
    private let jwtUserId = "22a44f12-1234-5678-9abc-def012345678"

    private lazy var jwtToken: String = {
        let header: [String: Any] = ["alg": "RS256", "typ": "JWT"]
        let claims: [String: Any] = [
            "sub": jwtUserId,
            "jti": "test-jti",
            "exp": 1893456000,
            "iat": 1700000000,
            "iss": "construct-server"
        ]
        let headerB64 = base64URLEncode(try! JSONSerialization.data(withJSONObject: header))
        let payloadB64 = base64URLEncode(try! JSONSerialization.data(withJSONObject: claims))
        let sigB64 = base64URLEncode(Data(repeating: 0x00, count: 64))
        return "\(headerB64).\(payloadB64).\(sigB64)"
    }()

    // MARK: - Format detection

    func testFormat_Paseto() {
        XCTAssertEqual(TokenUtils.format(of: pasetoToken), .paseto)
    }

    func testFormat_JWT_IsUnknown() {
        XCTAssertEqual(TokenUtils.format(of: jwtToken), .unknown)
    }

    func testFormat_unknownEmpty() {
        XCTAssertEqual(TokenUtils.format(of: ""), .unknown)
    }

    func testFormat_unknownGarbage() {
        XCTAssertEqual(TokenUtils.format(of: "not_a_token"), .unknown)
    }

    // MARK: - headerAlgorithm

    func testHeaderAlgorithm_Paseto() {
        XCTAssertEqual(TokenUtils.headerAlgorithm(from: pasetoToken), "v4.public")
    }

    func testHeaderAlgorithm_JWT_IsNil() {
        XCTAssertNil(TokenUtils.headerAlgorithm(from: jwtToken))
    }

    // MARK: - extractUserId

    func testExtractUserId_Paseto() {
        XCTAssertEqual(TokenUtils.extractUserId(from: pasetoToken), pasetoTokenUserId)
    }

    /// A JWT's `sub` is readable, and must not be read: a userId recovered from a token the
    /// server no longer issues would name the account behind a session that cannot authenticate.
    func testExtractUserId_JWT_IsNil() {
        XCTAssertNil(TokenUtils.extractUserId(from: jwtToken))
    }

    func testExtractUserId_Unknown() {
        XCTAssertNil(TokenUtils.extractUserId(from: "garbage"))
        XCTAssertNil(TokenUtils.extractUserId(from: ""))
    }

    func testExtractUserId_Paseto_TooShort() {
        // Payload shorter than nonce+sig overhead → nil
        let shortB64 = Data(repeating: 0x01, count: 50).base64URLEncodedString()
        XCTAssertNil(TokenUtils.extractUserId(from: "v4.public.\(shortB64)"))
    }

    func testExtractUserId_Paseto_BadJSON() {
        // Nonce(32) + non-JSON message(10) + sig(64)
        let payload = Data(repeating: 0xFF, count: 106)
        let payloadB64 = payload.base64URLEncodedString()
        XCTAssertNil(TokenUtils.extractUserId(from: "v4.public.\(payloadB64)"))
    }

    // MARK: - extractIssuedAt

    func testExtractIssuedAt_Paseto() {
        XCTAssertEqual(TokenUtils.extractIssuedAt(from: pasetoToken), 1_700_000_000)
    }

    func testExtractIssuedAt_JWT_IsNil() {
        XCTAssertNil(TokenUtils.extractIssuedAt(from: jwtToken))
    }

    func testExtractIssuedAt_Unknown() {
        XCTAssertNil(TokenUtils.extractIssuedAt(from: "garbage"))
    }

    func testDeviceLinkCheckpointCursorUsesTokenIssuedAt() {
        XCTAssertEqual(
            DeviceLinkStreamCursorPolicy.checkpointCursor(accessToken: pasetoToken),
            "1700000000000-0"
        )
    }

    func testDeviceLinkCheckpointCursorRejectsInvalidIssuedAt() {
        XCTAssertNil(DeviceLinkStreamCursorPolicy.checkpointCursor(issuedAtSeconds: 0))
    }

    // MARK: - Cached-token gate (AuthSessionManager.loadSessionToken)

    /// A cached JWT is cleared and the device re-authenticates; only PASETO v4.public stays.
    func testOnlyAPasetoTokenIsKeptFromTheKeychain() {
        XCTAssertTrue(AuthSessionManager.isAcceptedCachedToken(pasetoToken))
        XCTAssertTrue(AuthSessionManager.isAcceptedCachedToken(pasetoToken + ".Zm9vdGVy"))
        XCTAssertFalse(AuthSessionManager.isAcceptedCachedToken(jwtToken))
        XCTAssertFalse(AuthSessionManager.isAcceptedCachedToken("garbage"))
    }

    func test_Paseto_accepted() {
        XCTAssertEqual(TokenUtils.format(of: pasetoToken), .paseto)
        XCTAssertEqual(TokenUtils.headerAlgorithm(from: pasetoToken), "v4.public")
    }

    // MARK: - PASETO with footer

    func testFormat_Paseto_WithFooter() {
        let tokenWithFooter = pasetoToken + ".Zm9vdGVy"
        XCTAssertEqual(TokenUtils.format(of: tokenWithFooter), .paseto)
        XCTAssertEqual(TokenUtils.extractUserId(from: tokenWithFooter), pasetoTokenUserId)
    }

    // MARK: - Helpers

    private func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
