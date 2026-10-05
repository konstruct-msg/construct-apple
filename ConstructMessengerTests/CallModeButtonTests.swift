//
//  CallModeButtonTests.swift
//  ConstructMessengerTests
//
//  Where a finger lets go on the header's call ↔ video switch decides which call starts — or that
//  none does. The switch grows downwards from the call button: phone over camera, the phone under
//  the finger. Each test names the mutation that reddens it.
//

import XCTest
@testable import Construct_Messenger

final class CallModeButtonTests: XCTestCase {
    private let size: CGFloat = 44
    private var segment: CGFloat { ChatUIConstants.HoldSwitch.segmentLength }
    private var margin: CGFloat { ChatUIConstants.HoldSwitch.cancelMargin }

    private func mode(_ x: CGFloat, _ y: CGFloat) -> CallModeButton.Mode? {
        CallModeButton.mode(at: CGPoint(x: x, y: y), buttonSize: size)
    }

    func testReleasingWhereThePressBeganIsAVoiceCall() {
        XCTAssertEqual(mode(size / 2, size / 2), .voice)
    }

    /// Mutation: open the switch upwards, as the composer's does — the camera segment is off the
    /// top of the screen, behind the status bar.
    func testSlidingDownOntoTheCameraIsAVideoCall() {
        XCTAssertEqual(mode(size / 2, segment + 1), .video)
        XCTAssertEqual(mode(size / 2, 2 * segment - 1), .video)
    }

    /// Mutation: drop the guard — a finger dragged away to give up still starts a call.
    func testReleasingFarAwayStartsNothing() {
        XCTAssertNil(mode(size / 2, 2 * segment + margin + 1))
        XCTAssertNil(mode(size / 2, -margin - 1))
        XCTAssertNil(mode(-margin - 1, size / 2))
        XCTAssertNil(mode(size + margin + 1, segment + 1))
    }

    /// The composer and the header are one gesture; their numbers are one set.
    func testTheTwoSwitchesShareTheirNumbers() {
        XCTAssertEqual(ChatUIConstants.VideoNote.switchSegmentLength, ChatUIConstants.HoldSwitch.segmentLength)
        XCTAssertEqual(ChatUIConstants.VideoNote.switchPressDelay, ChatUIConstants.HoldSwitch.pressDelay)
    }
}
