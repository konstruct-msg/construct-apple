//
//  CallVideoTests.swift
//  ConstructMessengerTests
//
//  Video calls, stage 1 (TODO 105): the camera state the peer is told, the `MediaUpdate` that
//  carries it, the capture format, and the video section every call now offers. Each test names
//  the mutation that reddens it.
//

import SwiftProtobuf
import XCTest
@testable import Construct_Messenger

final class CallVideoTests: XCTestCase {

    // MARK: - What the peer is told

    /// Mutation: drop `!isInBackground` — the peer watches a frozen frame while we are away.
    func testABackgroundedCameraIsAnnouncedOff() {
        var state = CallVideoState(canSend: true, localCameraOn: true)
        XCTAssertTrue(state.announcedCameraOn)
        state.isInBackground = true
        XCTAssertFalse(state.announcedCameraOn)
    }

    /// Mutation: drop `canSend` — a callee offered audio only claims a camera it cannot send.
    func testNoSenderMeansNoCamera() {
        let state = CallVideoState(canSend: false, localCameraOn: true)
        XCTAssertFalse(state.announcedCameraOn)
    }

    /// An older client never sends `MediaUpdate`; its avatar is what it is sending.
    func testThePeerStartsWithTheCameraOff() {
        XCTAssertFalse(CallVideoState().remoteCameraOn)
    }

    // MARK: - MediaUpdate

    /// Mutation: always return `true` — turning the camera off leaves the peer on a frozen frame.
    func testTheUpdateRoundTripsBothWays() {
        for on in [true, false] {
            let update = CallVideoSignal.mediaUpdate(cameraOn: on, atMs: 1)
            XCTAssertEqual(CallVideoSignal.remoteCameraOn(after: update), on)
        }
    }

    /// Mutation: drop the `mediaType == .video` guard — a microphone mute hides the peer's face.
    func testAnUpdateAboutAnotherMediaIsNotAboutTheCamera() {
        var update = CallVideoSignal.mediaUpdate(cameraOn: false, atMs: 1)
        update.mediaType = .audio
        XCTAssertNil(CallVideoSignal.remoteCameraOn(after: update))
        update.mediaType = .screen
        XCTAssertNil(CallVideoSignal.remoteCameraOn(after: update))
    }

    func testTheUpdateSurvivesTheWire() throws {
        var signal = Shared_Proto_Signaling_V1_WebRTCSignal()
        signal.callID = "c"
        signal.signal = .mediaUpdate(CallVideoSignal.mediaUpdate(cameraOn: true, atMs: 7))
        let decoded = try Shared_Proto_Signaling_V1_WebRTCSignal(serializedBytes: signal.serializedBytes() as [UInt8])
        guard case .mediaUpdate(let update) = decoded.signal else { return XCTFail("not a MediaUpdate") }
        XCTAssertEqual(CallVideoSignal.remoteCameraOn(after: update), true)
    }

    // MARK: - Capture format

    private func format(_ w: Int32, _ h: Int32, _ ranges: [ClosedRange<Double>] = [1...30], preferred: Bool = true) -> CallVideoCapture.Candidate {
        CallVideoCapture.Candidate(width: w, height: h, rateRanges: ranges, isPreferredPixelFormat: preferred)
    }

    /// Mutation: pick the largest format overall — 1080p goes up the uplink the design budgets
    /// for 720p.
    func testThePickIsTheLargestWithin720p() {
        let formats = [format(640, 480), format(1920, 1080), format(1280, 720), format(352, 288)]
        XCTAssertEqual(CallVideoCapture.choose(formats)?.index, 2)
    }

    func testACameraWithNothingSmallGivesItsSmallest() {
        XCTAssertEqual(CallVideoCapture.choose([format(3840, 2160), format(1920, 1080)])?.index, 1)
        XCTAssertNil(CallVideoCapture.choose([]).map(\.index))
    }

    /// The build 716 crash: a back camera lists its 1280×720 formats, slow-motion ones last, and a
    /// slow-motion format cannot run at 30. Asked to, AVFoundation raises on WebRTC's capture
    /// queue and the app dies.
    /// Mutation: drop `canRun` from the filter — the 240 fps format is picked, at 30.
    func testASlowMotionTwinIsNeverPicked() throws {
        // The only 1280×720 is the slow-motion one; the largest format that can run is smaller.
        let formats = [
            format(640, 480, [1...30]),
            format(1280, 720, [240...240]),
        ]
        let pick = try XCTUnwrap(CallVideoCapture.choose(formats))
        XCTAssertEqual(pick.index, 0)
        XCTAssertTrue(formats[pick.index].rateRanges.contains { $0.contains(Double(pick.fps)) })
    }

    /// Of equals, the ordinary format over the faster one, and the capturer's pixel format over a
    /// converted one. Mutation: drop the tie-breaks — `min(by:)` returns whichever came first.
    func testOfEqualsTheOrdinaryPreferredFormatWins() {
        XCTAssertEqual(CallVideoCapture.choose([format(1280, 720, [1...60]), format(1280, 720, [1...30])])?.index, 1)
        XCTAssertEqual(CallVideoCapture.choose([format(1280, 720, preferred: false), format(1280, 720)])?.index, 1)
    }

    func testTheFrameRateIsCappedAt30() {
        XCTAssertEqual(CallVideoCapture.choose([format(1280, 720, [1...60])])?.fps, 30)
        XCTAssertEqual(CallVideoCapture.choose([format(1280, 720, [1...24])])?.fps, 24)
    }
}

// MARK: - The negotiated video section

#if os(iOS) && canImport(WebRTC)
/// Real peer connections, no network: the offer and answer are read as text. This is the part a
/// later WebRTC update or a constraint edit can break without any other test noticing.
@MainActor
final class CallVideoNegotiationTests: XCTestCase {

    private func videoSection(of sdp: String) -> String? {
        guard let start = sdp.range(of: "m=video") else { return nil }
        let rest = sdp[start.lowerBound...]
        let end = rest.dropFirst().range(of: "\r\nm=")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    /// Mutation: add the transceiver only when the call starts with the camera — turning it on
    /// mid-call would need an offer.
    /// Mutation: put `"OfferToReceiveVideo": "false"` back — the section goes out `sendonly`.
    func testEveryCallOffersVideoBothWays() async throws {
        let caller = try WebRTCSession(role: .caller, turn: nil, video: true)
        defer { caller.close() }
        XCTAssertTrue(caller.canSendVideo)
        let offer = try await caller.createOffer()
        let video = try XCTUnwrap(videoSection(of: offer), "no video section in the offer")
        XCTAssertTrue(video.contains("a=sendrecv"), video)
    }

    /// Mutation: drop `adoptOfferedVideo()` — the callee answers `recvonly` and can never send.
    func testTheCalleeTakesUpTheOfferedVideo() async throws {
        let caller = try WebRTCSession(role: .caller, turn: nil, video: true)
        let callee = try WebRTCSession(role: .callee, turn: nil, video: true)
        defer { caller.close(); callee.close() }
        XCTAssertFalse(callee.canSendVideo, "nothing to take up before the offer")

        try await callee.setRemoteOffer(sdp: caller.createOffer())
        XCTAssertTrue(callee.canSendVideo)
        let answer = try await callee.createAnswer()
        let video = try XCTUnwrap(videoSection(of: answer))
        XCTAssertTrue(video.contains("a=sendrecv"), video)
        XCTAssertEqual(answer.components(separatedBy: "m=video").count - 1, 1, "one video section, not two")
    }

    /// An audio-only caller — Android today, or this app with video off — gets an audio-only
    /// answer, and the callee has no camera to offer.
    func testAnAudioOnlyOfferStaysAudioOnly() async throws {
        let caller = try WebRTCSession(role: .caller, turn: nil, video: false)
        let callee = try WebRTCSession(role: .callee, turn: nil, video: true)
        defer { caller.close(); callee.close() }

        let offer = try await caller.createOffer()
        XCTAssertNil(videoSection(of: offer))
        try await callee.setRemoteOffer(sdp: offer)
        XCTAssertFalse(callee.canSendVideo)
        let answer = try await callee.createAnswer()
        XCTAssertNil(videoSection(of: answer))
    }

    /// A callee with video off still answers a video offer — receiving only, as every build
    /// before this one did — so a call from a video-capable build connects.
    func testAVideoOfferToAnAudioOnlyCalleeIsAnsweredWithoutSending() async throws {
        let caller = try WebRTCSession(role: .caller, turn: nil, video: true)
        let callee = try WebRTCSession(role: .callee, turn: nil, video: false)
        defer { caller.close(); callee.close() }

        try await callee.setRemoteOffer(sdp: caller.createOffer())
        XCTAssertFalse(callee.canSendVideo)
        let answer = try await callee.createAnswer()
        XCTAssertTrue(answer.contains("m=audio"))
        if let video = videoSection(of: answer) {
            XCTAssertFalse(video.contains("a=sendrecv"), video)
        }
    }
}
#endif
