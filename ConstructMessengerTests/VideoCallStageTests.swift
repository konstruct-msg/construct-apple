//
//  VideoCallStageTests.swift
//  ConstructMessengerTests
//
//  The video call screen's decisions (`VideoCallStage`): what fills the screen, what sits in the
//  small window, where the window lands, when the controls hide, and when the sound leaves the
//  earpiece. Each test names the mutation that reddens it.
//

import XCTest
@testable import Construct_Messenger

final class VideoCallStageTests: XCTestCase {

    private func state(local: Bool, remote: Bool) -> CallVideoState {
        CallVideoState(canSend: true, localCameraOn: local, remoteCameraOn: remote)
    }

    private func stage(local: Bool, remote: Bool, connecting: Bool = false, ended: Bool = false, swapped: Bool = false) -> VideoCallStage? {
        VideoCallStage.make(state(local: local, remote: remote), isConnecting: connecting, isEnded: ended, swapped: swapped)
    }

    // MARK: - What goes where

    /// Mutation: return a stage for (false, false) — an audio call opens on an empty video screen.
    func testNoCameraIsTheAudioScreen() {
        XCTAssertNil(stage(local: false, remote: false))
    }

    /// An ended call shows why it ended, on the audio screen, whatever the cameras were doing.
    func testAnEndedCallLeavesTheVideoScreen() {
        XCTAssertNil(stage(local: true, remote: true, ended: true))
    }

    func testBothCamerasPutThePeerBigAndUsSmall() {
        XCTAssertEqual(stage(local: true, remote: true), VideoCallStage(big: .remoteVideo, small: .localVideo))
    }

    /// Mutation: ignore `swapped` — a tap on the window does nothing.
    func testASwapTradesThePlaces() {
        XCTAssertEqual(stage(local: true, remote: true, swapped: true), VideoCallStage(big: .localVideo, small: .remoteVideo))
    }

    /// Mutation: show `.localVideo` big while ringing only when not connecting — the caller of a
    /// video call stares at an avatar of someone who has not answered.
    func testWhileRingingOurCameraFillsTheScreen() {
        XCTAssertEqual(stage(local: true, remote: false, connecting: true), VideoCallStage(big: .localVideo, small: nil))
    }

    func testThePeersCameraOffShowsTheirAvatar() {
        XCTAssertEqual(stage(local: true, remote: false), VideoCallStage(big: .remoteAvatar, small: .localVideo))
    }

    func testOurCameraOffKeepsAnEmptyWindow() {
        XCTAssertEqual(stage(local: false, remote: true), VideoCallStage(big: .remoteVideo, small: .localCameraOff))
    }

    /// A camera iOS took away in the background counts as off here too, as it does for the peer.
    func testABackgroundedCameraIsShownOff() {
        var video = state(local: true, remote: true)
        video.isInBackground = true
        let stage = VideoCallStage.make(video, isConnecting: false, isEnded: false, swapped: false)
        XCTAssertEqual(stage?.small, .localCameraOff)
    }

    /// Mutation: `canSwap` always true — a swap puts "camera off" on the whole screen.
    func testOnlyTwoFacesSwap() {
        XCTAssertTrue(VideoCallStage(big: .remoteVideo, small: .localVideo).canSwap)
        XCTAssertFalse(VideoCallStage(big: .remoteVideo, small: .localCameraOff).canSwap)
        XCTAssertFalse(VideoCallStage(big: .remoteAvatar, small: .localVideo).canSwap)
        XCTAssertFalse(VideoCallStage(big: .localVideo, small: nil).canSwap)
    }

    // MARK: - Controls

    /// Mutation: drop the `voiceOver` term — a VoiceOver user loses the end button three seconds in.
    func testControlsStayForVoiceOver() {
        let faces = VideoCallStage(big: .remoteVideo, small: .localVideo)
        XCTAssertTrue(faces.controlsAutoHide(isConnecting: false, voiceOver: false))
        XCTAssertFalse(faces.controlsAutoHide(isConnecting: false, voiceOver: true))
    }

    func testControlsStayWhileThereIsNoFaceToSee() {
        XCTAssertFalse(VideoCallStage(big: .remoteAvatar, small: .localVideo).controlsAutoHide(isConnecting: false, voiceOver: false))
        XCTAssertFalse(VideoCallStage(big: .localVideo, small: nil).controlsAutoHide(isConnecting: true, voiceOver: false))
    }

    // MARK: - The small window

    func testTheWindowLandsInTheNearestCorner() {
        let screen = CGSize(width: 390, height: 844)
        XCTAssertEqual(PreviewCorner.nearest(to: CGPoint(x: 20, y: 30), in: screen), .topLeading)
        XCTAssertEqual(PreviewCorner.nearest(to: CGPoint(x: 380, y: 30), in: screen), .topTrailing)
        XCTAssertEqual(PreviewCorner.nearest(to: CGPoint(x: 20, y: 800), in: screen), .bottomLeading)
        XCTAssertEqual(PreviewCorner.nearest(to: CGPoint(x: 380, y: 800), in: screen), .bottomTrailing)
        // A flick past the edge still lands in a corner.
        XCTAssertEqual(PreviewCorner.nearest(to: CGPoint(x: -400, y: 2000), in: screen), .bottomLeading)
    }

    // MARK: - Sound

    /// Mutation: drop `outputIsEarpiece` — AirPods are overridden to the loudspeaker.
    func testTurningTheCameraOnLeavesTheEarpiece() {
        XCTAssertTrue(CallVideoAudio.movesToSpeaker(wasSending: false, isSending: true, outputIsEarpiece: true))
        XCTAssertFalse(CallVideoAudio.movesToSpeaker(wasSending: false, isSending: true, outputIsEarpiece: false))
    }

    /// Mutation: drop `!wasSending` — a flip of the camera undoes the earpiece the person chose.
    func testOnlyTheMomentTheCameraComesOnMovesTheSound() {
        XCTAssertFalse(CallVideoAudio.movesToSpeaker(wasSending: true, isSending: true, outputIsEarpiece: true))
        XCTAssertFalse(CallVideoAudio.movesToSpeaker(wasSending: true, isSending: false, outputIsEarpiece: true))
    }
}
