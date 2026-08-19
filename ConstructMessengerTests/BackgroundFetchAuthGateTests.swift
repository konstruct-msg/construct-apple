//
//  BackgroundFetchAuthGateTests.swift
//  ConstructMessengerTests
//
//  Background fetch used to read only `GRPCAuthCache`. The cache is empty until
//  `AuthSessionManager.loadSessionToken()` runs, so a silent push that beat restore
//  logged ERROR "No session token available" four times (2026-08-19) — the token
//  was in Keychain the whole time. That is a launch race, not a missing session.
//

import XCTest
@testable import Construct_Messenger

final class BackgroundFetchAuthGateTests: XCTestCase {

    func testCacheHit_ProceedsWithoutHydrating() {
        XCTAssertEqual(
            BackgroundFetchAuthGate.decision(cacheHasToken: true, keychainHasToken: true),
            .proceed
        )
        XCTAssertEqual(
            BackgroundFetchAuthGate.decision(cacheHasToken: true, keychainHasToken: false),
            .proceed,
            "a live cache is enough; Keychain is the fallback, not a veto"
        )
    }

    func testCacheEmptyKeychainFull_Hydrates() {
        XCTAssertEqual(
            BackgroundFetchAuthGate.decision(cacheHasToken: false, keychainHasToken: true),
            .hydrateThenProceed,
            "this is the 2026-08-19 race: restore has not copied Keychain into the cache yet"
        )
    }

    func testNeitherStoreHasAToken_Skips() {
        XCTAssertEqual(
            BackgroundFetchAuthGate.decision(cacheHasToken: false, keychainHasToken: false),
            .skipNotAuthenticated
        )
    }
}
