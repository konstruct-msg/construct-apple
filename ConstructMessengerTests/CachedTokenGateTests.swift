//
//  CachedTokenGateTests.swift
//  ConstructMessengerTests
//

import XCTest
@testable import Construct_Messenger

/// A cached token that is not PASETO v4.public is cleared and the device signs in again with its
/// key. How one is read is the core's (`session_token`).
final class CachedTokenGateTests: XCTestCase {

    private let claims = Data(#"{"sub":"u","iat":1700000000}"#.utf8)

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    func testOnlyAPasetoTokenIsKeptFromTheKeychain() {
        let paseto = "v4.public." + base64URL(Data(repeating: 0xAB, count: 32) + claims + Data(count: 64))
        XCTAssertTrue(AuthSessionManager.isAcceptedCachedToken(paseto))
        XCTAssertTrue(AuthSessionManager.isAcceptedCachedToken(paseto + ".Zm9vdGVy"))
        XCTAssertEqual(sessionTokenClaims(token: paseto)?.userId, "u")
        XCTAssertFalse(AuthSessionManager.isAcceptedCachedToken("h.\(base64URL(claims)).s"))
        XCTAssertFalse(AuthSessionManager.isAcceptedCachedToken("garbage"))
    }
}
