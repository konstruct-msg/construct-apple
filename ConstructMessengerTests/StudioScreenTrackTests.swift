//
//  StudioScreenTrackTests.swift
//  ConstructMessengerTests
//
//  The host's screen on two of this app's `WebRTCSession`s in one process
//  (`decisions/studio-mode-on-desktop.md`, step 5): the screen's section rides Studio's offer,
//  frames written into the host's feed reach the guest's track at the size they were captured,
//  and the guest's renderer holds each one for the program's depth. Each test names the mutation
//  that reddens it.
//

import CoreVideo
import Synchronization
import WebRTC
import XCTest
@testable import Construct_Messenger

@MainActor
final class StudioScreenTrackTests: XCTestCase {

    private var host: WebRTCSession!
    private var guest: WebRTCSession!

    override func setUp() async throws {
        try await super.setUp()
        host = try WebRTCSession(loopbackRole: .caller, video: false)
        // A guest that takes up an offered camera, so a screen taken for one would show.
        guest = try WebRTCSession(loopbackRole: .callee, video: true)
        let host = host!, guest = guest!
        host.onLocalIceCandidate = { candidate in
            Task { @MainActor in try? await guest.addRemoteIceCandidate(candidate) }
        }
        guest.onLocalIceCandidate = { candidate in
            Task { @MainActor in try? await host.addRemoteIceCandidate(candidate) }
        }
    }

    override func tearDown() async throws {
        host.close()
        guest.close()
        try await super.tearDown()
    }

    /// A call, then Studio with the screen added by the host before its offer, as
    /// `CallManager.startStudio` does it.
    private func startStudioWithScreen() async throws -> (offer: String, feed: StudioScreenFeed) {
        let connected = expectation(description: "connected")
        connected.expectedFulfillmentCount = 2
        host.onConnected = { connected.fulfill() }
        guest.onConnected = { connected.fulfill() }
        try await guest.setRemoteOffer(sdp: try await host.createOffer())
        try await host.setRemoteAnswer(sdp: try await guest.createAnswer())
        await fulfillment(of: [connected], timeout: 30)

        let open = expectation(description: "studio channels open")
        open.expectedFulfillmentCount = 2
        host.onStudioChannelsOpen = { open.fulfill() }
        guest.onStudioChannelsOpen = { open.fulfill() }
        let feed = host.addStudioScreen()
        try host.openStudioChannels()
        let offer = try await host.createOffer()
        try await guest.setRemoteOffer(sdp: offer)
        try guest.openStudioChannels()
        try await host.setRemoteAnswer(sdp: try await guest.createAnswer())
        await fulfillment(of: [open], timeout: 30)
        return (offer, feed)
    }

    /// Studio's offer carries the screen as a send-only section of its own stream; the guest
    /// finds it by that stream and does not take it up as its camera.
    ///
    /// Mutation: drop `$0.mid != screenMid` in `adoptOfferedVideo` — the guest takes the screen's
    /// section as a camera and could send into it; this reddens.
    func testTheScreenSectionIsTheScreensAndNotTheGuestsCamera() async throws {
        let (offer, _) = try await startStudioWithScreen()
        XCTAssertNotNil(StudioOffer.screenMid(sdp: offer))
        XCTAssertTrue(offer.contains("a=sendonly"))
        XCTAssertFalse(guest.canSendVideo, "the screen's section was taken up as the guest's camera")
        XCTAssertNotNil(guest.studioScreenTrack())
        XCTAssertNil(host.studioScreenTrack(), "the host is shown no screen")
    }

    /// Asked twice, the host has one screen section: a second Studio on the call adds none.
    ///
    /// Mutation: drop the early return in `addStudioScreen` — a second feed and section; this
    /// reddens.
    func testTheScreenSectionIsMadeOnce() {
        XCTAssertTrue(host.addStudioScreen() === host.addStudioScreen())
    }

    /// Frames the host's capture writes reach the guest, at the size they were captured: the
    /// sender keeps resolution and gives up frames when the path is short.
    ///
    /// Mutation: `StudioScreenFeed.deliver` does not pass the frame to the source — nothing
    /// arrives; this reddens.
    /// Mutation: `degradationPreference` left at the default — whether the encoder scales a
    /// 640×360 frame down on a fresh loopback path is WebRTC's call, so this one is not claimed.
    func testFramesWrittenIntoTheFeedReachTheGuest() async throws {
        let (_, feed) = try await startStudioWithScreen()
        let track = try XCTUnwrap(guest.studioScreenTrack())
        let counter = FrameCounter()
        let arrived = expectation(description: "frames arrived")
        counter.onFrame = { count in if count == 5 { arrived.fulfill() } }
        track.add(counter)
        defer { track.remove(counter) }

        let pixels = try Self.pixelBuffer(width: 640, height: 360)
        let writer = Task {
            for n in 0..<300 where !Task.isCancelled {
                feed.deliver(pixels, timeNs: Int64(n) * 33_000_000)
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
        defer { writer.cancel() }
        await fulfillment(of: [arrived], timeout: 30)

        let sizes = counter.sizes
        XCTAssertFalse(sizes.isEmpty)
        XCTAssertTrue(sizes.allSatisfy { $0 == CGSize(width: 640, height: 360) }, "\(sizes)")
    }

    /// The guest's renderer passes a frame on only once the program's depth has passed since it
    /// arrived, and then the newest due.
    ///
    /// Mutation: `release` hands over every frame as it arrives — this reddens.
    func testTheRendererHoldsEachFrameForTheDelay() throws {
        let clock = Mutex(100.0)
        let renderer = StudioScreenRenderer(delay: 0.4, now: { clock.withLock { $0 } })
        let view = FrameCounter()
        renderer.show(on: view)
        let frame = RTCVideoFrame(buffer: RTCI420Buffer(width: 16, height: 16), rotation: ._0, timeStampNs: 0)

        renderer.renderFrame(frame)
        renderer.release()
        XCTAssertEqual(view.count, 0, "shown on arrival")
        clock.withLock { $0 = 100.39 }
        renderer.release()
        XCTAssertEqual(view.count, 0)
        clock.withLock { $0 = 100.41 }
        renderer.release()
        XCTAssertEqual(view.count, 1)
        renderer.release()
        XCTAssertEqual(view.count, 1, "shown once")
    }

    private static func pixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attributes, &buffer)
        return try XCTUnwrap(status == kCVReturnSuccess ? buffer : nil)
    }
}

/// Counts what a track or renderer hands it, from whichever thread that is.
private final class FrameCounter: NSObject, RTCVideoRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0
    private var seen: [CGSize] = []
    var onFrame: (Int) -> Void = { _ in }

    var count: Int { lock.withLock { frames } }
    var sizes: [CGSize] { lock.withLock { seen } }

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        let n = lock.withLock { () -> Int in
            frames += 1
            seen.append(CGSize(width: Int(frame.width), height: Int(frame.height)))
            return frames
        }
        onFrame(n)
    }
}
