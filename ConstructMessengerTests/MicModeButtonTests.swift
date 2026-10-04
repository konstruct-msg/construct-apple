//
//  MicModeButtonTests.swift
//  ConstructMessengerTests
//
//  Where a finger lets go on the mic ↔ camera switch decides what is recorded — or that nothing
//  is. The switch grows leftwards from the mic: [camera | mic], the mic under the finger.
//

import XCTest
@testable import Construct_Messenger

final class MicModeButtonTests: XCTestCase {
    private let size: CGFloat = 42
    private var segment: CGFloat { ChatUIConstants.VideoNote.switchSegmentWidth }
    private var margin: CGFloat { ChatUIConstants.VideoNote.switchCancelMargin }

    private func mode(_ x: CGFloat, _ y: CGFloat) -> MicModeButton.Mode? {
        MicModeButton.mode(at: CGPoint(x: x, y: y), buttonSize: size)
    }

    func testReleasingWhereThePressBeganIsTheVoiceMessage() {
        XCTAssertEqual(mode(size / 2, size / 2), .voice)
    }

    func testSlidingLeftOntoTheCameraSegmentIsTheVideoNote() {
        XCTAssertEqual(mode(size - segment - 1, size / 2), .videoNote)
        XCTAssertEqual(mode(size - 2 * segment + 1, size / 2), .videoNote)
    }

    func testLeavingTheSwitchChoosesNothing() {
        XCTAssertNil(mode(size / 2, -margin - 1), "dragged up, away from the switch")
        XCTAssertNil(mode(size / 2, size + margin + 1), "dragged down")
        XCTAssertNil(mode(size - 2 * segment - margin - 1, size / 2), "past the camera end")
        XCTAssertNil(mode(size + margin + 1, size / 2), "past the mic end")
    }

    func testAFingerThatDriftsALittleStillChooses() {
        XCTAssertEqual(mode(size / 2, -margin + 1), .voice)
        XCTAssertEqual(mode(size - 2 * segment - margin + 1, size / 2), .videoNote)
    }
}
