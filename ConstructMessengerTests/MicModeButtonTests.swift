//
//  MicModeButtonTests.swift
//  ConstructMessengerTests
//
//  Where a finger lets go on the mic ↔ camera switch decides what is recorded — or that nothing
//  is. The switch grows upwards from the mic: camera over mic, the mic under the finger.
//

import XCTest
@testable import Construct_Messenger

final class MicModeButtonTests: XCTestCase {
    private let size: CGFloat = 42
    private var segment: CGFloat { ChatUIConstants.VideoNote.switchSegmentLength }
    private var margin: CGFloat { ChatUIConstants.VideoNote.switchCancelMargin }

    private func mode(_ x: CGFloat, _ y: CGFloat) -> MicModeButton.Mode? {
        MicModeButton.mode(at: CGPoint(x: x, y: y), buttonSize: size)
    }

    func testReleasingWhereThePressBeganIsTheVoiceMessage() {
        XCTAssertEqual(mode(size / 2, size / 2), .voice)
    }

    func testSlidingUpOntoTheCameraSegmentIsTheVideoNote() {
        XCTAssertEqual(mode(size / 2, size - segment - 1), .videoNote)
        XCTAssertEqual(mode(size / 2, size - 2 * segment + 1), .videoNote)
    }

    /// Sideways is not the gesture any more: a slide left stays on the mic, and far enough is off.
    func testSlidingLeftDoesNotChooseTheCamera() {
        XCTAssertEqual(mode(-margin + 1, size / 2), .voice)
        XCTAssertNil(mode(-margin - 1, size / 2))
    }

    func testLeavingTheSwitchChoosesNothing() {
        XCTAssertNil(mode(size / 2, size - 2 * segment - margin - 1), "past the camera end")
        XCTAssertNil(mode(size / 2, size + margin + 1), "dragged down")
        XCTAssertNil(mode(size + margin + 1, size / 2), "dragged right")
    }

    func testAFingerThatDriftsALittleStillChooses() {
        XCTAssertEqual(mode(size + margin - 1, size / 2), .voice)
        XCTAssertEqual(mode(size / 2, size - 2 * segment - margin + 1), .videoNote)
    }
}
