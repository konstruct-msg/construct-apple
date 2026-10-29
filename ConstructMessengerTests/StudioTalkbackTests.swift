//
//  StudioTalkbackTests.swift
//  ConstructMessengerTests
//

import XCTest
@testable import Construct_Messenger

final class StudioTalkbackTests: XCTestCase {

    func testHoldToTalk_OpenOnlyWhileHeld() {
        var talkback = StudioTalkback(mode: .holdToTalk)
        XCTAssertFalse(talkback.microphoneOpen(muted: false, studioOn: true))
        talkback.held = true
        XCTAssertTrue(talkback.microphoneOpen(muted: false, studioOn: true))
    }

    func testAlwaysOn_OpenWithoutHolding() {
        XCTAssertTrue(StudioTalkback(mode: .alwaysOn).microphoneOpen(muted: false, studioOn: true))
    }

    func testMuteWinsInBothModes() {
        for mode in StudioTalkbackMode.allCases {
            let talkback = StudioTalkback(mode: mode, held: true)
            XCTAssertFalse(talkback.microphoneOpen(muted: true, studioOn: true), "\(mode)")
            XCTAssertFalse(talkback.microphoneOpen(muted: true, studioOn: false), "\(mode)")
        }
    }

    /// Outside Studio a call's microphone does not wait for a key.
    func testOutsideStudio_OpenUnlessMuted() {
        XCTAssertTrue(StudioTalkback(mode: .holdToTalk).microphoneOpen(muted: false, studioOn: false))
    }

    func testStoredMode_DefaultsToHoldToTalk() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "StudioTalkbackTests-\(UUID().uuidString)"))
        XCTAssertEqual(StudioTalkbackMode.stored(in: defaults), .holdToTalk)
        defaults.set("somethingElse", forKey: StudioTalkbackMode.defaultsKey)
        XCTAssertEqual(StudioTalkbackMode.stored(in: defaults), .holdToTalk)
        StudioTalkbackMode.alwaysOn.store(in: defaults)
        XCTAssertEqual(StudioTalkbackMode.stored(in: defaults), .alwaysOn)
    }
}
