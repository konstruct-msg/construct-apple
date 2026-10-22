//
//  StudioDataChannelTests.swift
//  ConstructMessengerTests
//
//  Studio's data channels on two of this app's `WebRTCSession`s, connected to each other in one
//  process (`init(loopbackRole:)`): a call connects as it does today, then Studio is added by a
//  second offer, as the design has it (`decisions/studio-mode-on-desktop.md`, step 2). Each test
//  names the mutation that reddens it.
//

import Synchronization
import XCTest
@testable import Construct_Messenger

@MainActor
final class StudioDataChannelTests: XCTestCase {

    private var caller: WebRTCSession!
    private var callee: WebRTCSession!

    override func setUp() async throws {
        caller = try WebRTCSession(loopbackRole: .caller, video: false)
        callee = try WebRTCSession(loopbackRole: .callee, video: false)
        let caller = caller!, callee = callee!
        caller.onLocalIceCandidate = { candidate in
            Task { @MainActor in try? await callee.addRemoteIceCandidate(candidate) }
        }
        callee.onLocalIceCandidate = { candidate in
            Task { @MainActor in try? await caller.addRemoteIceCandidate(candidate) }
        }
    }

    override func tearDown() async throws {
        caller.close()
        callee.close()
    }

    /// The call as it is today: one offer, one answer, connected.
    private func connectCall() async throws -> String {
        let connected = expectation(description: "connected")
        connected.expectedFulfillmentCount = 2
        caller.onConnected = { connected.fulfill() }
        callee.onConnected = { connected.fulfill() }
        let offer = try await caller.createOffer()
        try await callee.setRemoteOffer(sdp: offer)
        try await caller.setRemoteAnswer(sdp: try await callee.createAnswer())
        await fulfillment(of: [connected], timeout: 30)
        return offer
    }

    /// Studio added to the connected call: the caller makes its channels and offers again, the
    /// callee makes its own before it answers.
    private func startStudio() async throws -> String {
        let open = expectation(description: "studio channels open")
        open.expectedFulfillmentCount = 2
        caller.onStudioChannelsOpen = { open.fulfill() }
        callee.onStudioChannelsOpen = { open.fulfill() }
        try caller.openStudioChannels()
        let offer = try await caller.createOffer()
        try await callee.setRemoteOffer(sdp: offer)
        try callee.openStudioChannels()
        try await caller.setRemoteAnswer(sdp: try await callee.createAnswer())
        await fulfillment(of: [open], timeout: 30)
        return offer
    }

    /// Without Studio a call's SDP is what it always was: no data section.
    ///
    /// Mutation: make the channels in `init` — this reddens.
    func testACallWithoutStudioOffersNoDataSection() async throws {
        let offer = try await connectCall()
        XCTAssertFalse(offer.contains("m=application"))
        XCTAssertFalse(caller.studioChannelsOpen)
        XCTAssertFalse(caller.sendStudio(Data([1]), on: .control), "nothing to send on")
    }

    /// Studio's offer adds the data section to the call, and both channels open on both sides.
    func testStudioChannelsOpenWhenStudioIsOffered() async throws {
        _ = try await connectCall()
        let offer = try await startStudio()
        XCTAssertTrue(offer.contains("m=application"))
        XCTAssertTrue(caller.studioChannelsOpen)
        XCTAssertTrue(callee.studioChannelsOpen)
    }

    /// What one side sends arrives on the other, on the channel it was sent on, in order.
    ///
    /// Mutation: report every message as `.control` in the delegate — this reddens.
    /// Mutation: drop `isNegotiated` — each side announces its own channel in-band; the channels
    /// still report open, but what one side sends never reaches the other's; this reddens, as does
    /// `testTheCalleeCanSendBack`.
    func testMessagesArriveOnTheirChannelInOrder() async throws {
        _ = try await connectCall()
        _ = try await startStudio()

        let received = Mutex<[(StudioChannel, Data)]>([])
        let packets = 50
        let all = expectation(description: "all received")
        all.expectedFulfillmentCount = packets + 1
        callee.setStudioReceiver { channel, data in
            received.withLock { $0.append((channel, data)) }
            all.fulfill()
        }

        XCTAssertTrue(caller.sendStudio(Data("invite".utf8), on: .control))
        for n in 0..<packets {
            // A program packet's size, a counter at the front.
            var packet = Data(repeating: UInt8(n), count: 4_096)
            packet[0] = UInt8(n)
            XCTAssertTrue(caller.sendStudio(packet, on: .program))
        }
        await fulfillment(of: [all], timeout: 30)

        let messages = received.withLock { $0 }
        let control = messages.filter { $0.0 == .control }.map(\.1)
        let program = messages.filter { $0.0 == .program }.map(\.1)
        XCTAssertEqual(control, [Data("invite".utf8)])
        XCTAssertEqual(program.count, packets)
        XCTAssertEqual(program.map { $0.first }, (0..<packets).map { UInt8($0) }, "out of order")
        XCTAssertTrue(program.allSatisfy { $0.count == 4_096 })
    }

    /// The guest answers on the same channels.
    func testTheCalleeCanSendBack() async throws {
        _ = try await connectCall()
        _ = try await startStudio()
        let got = expectation(description: "caller received")
        let received = Mutex<[(StudioChannel, Data)]>([])
        caller.setStudioReceiver { channel, data in
            received.withLock { $0.append((channel, data)) }
            got.fulfill()
        }
        XCTAssertTrue(callee.sendStudio(Data("accept".utf8), on: .control))
        await fulfillment(of: [got], timeout: 30)
        let first = received.withLock { $0.first }
        XCTAssertEqual(first?.0, .control)
        XCTAssertEqual(first?.1, Data("accept".utf8))
    }

    /// Leaving Studio closes the channels; the call stays.
    func testClosingStudioLeavesNothingToSendOn() async throws {
        _ = try await connectCall()
        _ = try await startStudio()
        caller.closeStudioChannels()
        XCTAssertFalse(caller.studioChannelsOpen)
        XCTAssertFalse(caller.sendStudio(Data([1]), on: .program))
    }
}
