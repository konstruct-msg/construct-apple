//
//  VeilBundledFrontPolicyTests.swift
//  ConstructMessengerTests
//
//  No front ships inside the app. Until 2026-10-02 one did — address, SNI and pin in
//  `Constants.swift`, in a public repository and in every binary — and it was retired
//  for being known. Fronts reach a device only as signed data: the server's manifest
//  or a config link. These tests fail when a name is bundled again, so that doing it
//  is a decision someone makes and not an edit that slips through.
//

import XCTest
@testable import Construct_Messenger

final class VeilBundledFrontPolicyTests: XCTestCase {
    func testNoFrontIsBundled() {
        XCTAssertTrue(VEILConfig.seedRelays.isEmpty,
                      "a bundled front is public: ship it as signed data (manifest, config link) instead")
        XCTAssertTrue(VEILConfig.hardcodedRelayAddresses.isEmpty)
        XCTAssertTrue(VEILConfig.hardcodedRelaySPKIs.isEmpty)
        XCTAssertTrue(VEILConfig.hardcodedRelaySNIs.isEmpty)
    }

    func testNoRegionPrefersABundledFront() {
        XCTAssertTrue(VEILConfig.hardcodedRelayRegions.flatMap(\.preferredRelays).isEmpty)
    }
}
