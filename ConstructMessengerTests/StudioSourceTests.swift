//
//  StudioSourceTests.swift
//  ConstructMessengerTests
//

import XCTest
@testable import Construct_Messenger

final class StudioSourceTests: XCTestCase {

    private let reaper = StudioSource(bundleID: "com.cockos.reaper", name: "REAPER")
    private let logic = StudioSource(bundleID: "com.apple.logic10", name: "Logic Pro")
    private let cubase = StudioSource(bundleID: "com.steinberg.cubase14", name: "Cubase 14")
    private let safari = StudioSource(bundleID: "com.apple.Safari", name: "Safari")

    func testPick_StoredChoiceWinsWhenRunning() {
        XCTAssertEqual(StudioSource.pick(stored: safari.bundleID, running: [reaper, safari]), safari)
    }

    /// A stored choice that is not running falls to a known DAW, not to nothing.
    func testPick_StoredNotRunning_TakesKnownDAW() {
        XCTAssertEqual(StudioSource.pick(stored: "com.example.gone", running: [safari, logic]), logic)
    }

    func testPick_KnownDAWsInOrder_PrefixMatches() {
        XCTAssertEqual(StudioSource.pick(stored: nil, running: [cubase, logic]), logic)
        XCTAssertEqual(StudioSource.pick(stored: nil, running: [safari, cubase]), cubase)
    }

    /// Nothing is guessed from an application that is not a DAW.
    func testPick_NoDAWRunning_Nil() {
        XCTAssertNil(StudioSource.pick(stored: nil, running: [safari]))
    }

    func testStoredChoices_RoundTrip() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "StudioSourceTests-\(UUID().uuidString)"))
        XCTAssertNil(StudioSource.stored(in: defaults))
        logic.store(in: defaults)
        XCTAssertEqual(StudioSource.stored(in: defaults), logic.bundleID)

        XCTAssertTrue(StudioScreenChoice.stored(in: defaults))
        StudioScreenChoice.store(false, in: defaults)
        XCTAssertFalse(StudioScreenChoice.stored(in: defaults))
    }
}
