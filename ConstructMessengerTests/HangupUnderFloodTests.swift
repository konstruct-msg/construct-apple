//
//  HangupUnderFloodTests.swift
//  ConstructMessengerTests
//
//  A hang-up is never queued behind what the peer sends. In 2026-10 Signal was found to keep the
//  microphone (and possibly the camera) live after the user hung up: the other side could flood
//  the call's event queue so the hang-up, waiting in that same queue, was never processed. Here
//  `end` runs as its own task and closes the media at once; this test holds that in place while
//  the peer floods the signalling stream.
//

import CoreData
import XCTest
@testable import Construct_Messenger

@MainActor
final class HangupUnderFloodTests: XCTestCase {

    /// The media, as far as a hang-up is concerned: when it was closed.
    private final class MediaProbe: WebRTCSessionProtocol {
        var onLocalIceCandidate: (@Sendable (WebRTCIceCandidate) -> Void)?
        var onConnectionFailed: (@Sendable () -> Void)?
        var onConnected: (@Sendable () -> Void)?
        var onQualityChanged: (@Sendable (CallQuality) -> Void)?
        private(set) var closedAt: Date?

        func createOffer() async throws -> String { "" }
        func restartIce() async throws -> String { "" }
        func createAnswer() async throws -> String { "" }
        func setRemoteOffer(sdp: String) async throws {}
        func setRemoteAnswer(sdp: String) async throws {}
        func addRemoteIceCandidate(_ candidate: WebRTCIceCandidate) async throws {}
        func setMuted(_ muted: Bool) {}
        func microphoneLevel() async -> Double? { nil }
        var canSendVideo: Bool { false }
        func setCameraOn(_ on: Bool, facing: CameraFacing) {}
        func close() { if closedAt == nil { closedAt = Date() } }
    }

    private let manager = CallManager.shared

    override func setUp() {
        super.setUp()
        // The hang-up records the call; not in the simulator's app store.
        LocalRepositories.useCallsForTesting(PersistenceController(inMemory: true).container)
    }

    override func tearDown() {
        manager.endActiveCall(reason: .local("test"), reportToCallKit: false)
        manager.dismissEndedCall()
        LocalRepositories.useCallsForTesting(nil)
        super.tearDown()
    }

    /// The peer sends as fast as it can for 1.5 s; this side hangs up 0.2 s in. The media is
    /// closed long before the flood ends, and the call is over.
    ///
    /// Mutation: leave `endActiveCall` out of `end` — the hang-up then waits on something the
    /// peer controls (here, nothing ever comes) and the media stays open; this reddens.
    /// Mutation: Signal's design — `end` waits for the receive loop to finish what came before
    /// it (`await active.receiveTask?.value`) — the media is still open when the flood stops,
    /// because the backlog has not drained; this reddens. That is also what shows the flood here
    /// is one: the loop is behind it.
    func testAHangUpClosesTheMediaWhileThePeerFloodsTheStream() async throws {
        let session = CallSession(id: "flood-call", uuid: UUID(), peerUserId: "peer",
                                  peerName: "", direction: .outgoing)
        manager.begin(session: session, initialState: .active(session))
        let active = try XCTUnwrap(manager.active)
        let media = MediaProbe()
        active.webrtc = media

        let (incoming, peer) = AsyncStream<Shared_Proto_Signaling_V1_SignalResponse>.makeStream()
        let (_, outbound) = AsyncStream<Shared_Proto_Signaling_V1_SignalRequest>.makeStream()
        let stream = SignalStream(streamTask: Task {}, outboundContinuation: outbound,
                                  accepted: AsyncStream { _ in }, incoming: incoming)
        active.stream = stream
        manager.receiveSignals(from: stream, for: active)

        // Faster than the loop takes them, so a backlog builds; bounded, so memory stays small.
        let floodSeconds = 1.5
        let flood = Task.detached {
            var pong = Shared_Proto_Signaling_V1_SignalResponse()
            pong.pong = .init()
            let end = Date().addingTimeInterval(floodSeconds)
            while Date() < end, !Task.isCancelled {
                for _ in 0..<200 { peer.yield(pong) }
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            peer.finish()
            return Date()
        }

        try await Task.sleep(nanoseconds: 200_000_000)
        let hungUpAt = Date()
        manager.endCall()

        let floodEnded = await flood.value
        let closedAt = try XCTUnwrap(media.closedAt, "the media was never closed")
        XCTAssertLessThan(closedAt.timeIntervalSince(hungUpAt), 0.5, "the hang-up waited")
        XCTAssertLessThan(closedAt, floodEnded, "the hang-up waited for the peer to stop")
        XCTAssertNil(manager.active)
        guard case .ended = manager.state else { return XCTFail("state \(manager.state)") }
    }
}
