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

    /// A long studio: every message reaches the same receiver at the same depth. Read out of its
    /// lock as a bare closure, the receiver came back wrapped in one more reabstraction thunk per
    /// message, and the guest's signalling thread ran out of stack after ~5,600 packets — two
    /// minutes of program (Desktop 0.3.18, 2026-10-28).
    ///
    /// Mutation: keep the receiver as a bare optional closure in the `Mutex` — this crashes.
    func testALongStudioKeepsReceiving() async throws {
        _ = try await connectCall()
        _ = try await startStudio()

        let messages = 20_000
        let count = Mutex(0)
        let all = expectation(description: "all received")
        callee.setStudioReceiver { _, _ in
            if count.withLock({ $0 += 1; return $0 }) == messages { all.fulfill() }
        }
        for n in 0..<messages {
            XCTAssertTrue(caller.sendStudio(Data([UInt8(n & 0xFF)]), on: .program))
        }
        await fulfillment(of: [all], timeout: 60)
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

    /// The guest makes Studio's channels only for an offer that has Studio in it: not for the
    /// call's first offer, not for an ICE restart.
    ///
    /// Mutation: `carriesStudio` true for any offer — this reddens.
    func testOnlyAStudioOfferIsTakenForStudio() async throws {
        let first = try await connectCall()
        XCTAssertFalse(StudioOffer.carriesStudio(sdp: first))
        let restart = try await caller.restartIce()
        XCTAssertFalse(StudioOffer.carriesStudio(sdp: restart))
        try await callee.setRemoteOffer(sdp: restart)
        try await caller.setRemoteAnswer(sdp: try await callee.createAnswer())
        let studio = try await startStudio()
        XCTAssertTrue(StudioOffer.carriesStudio(sdp: studio))
    }

    /// Leaving Studio closes the channels; the call stays.
    func testClosingStudioLeavesNothingToSendOn() async throws {
        _ = try await connectCall()
        _ = try await startStudio()
        caller.closeStudioChannels()
        XCTAssertFalse(caller.studioChannelsOpen)
        XCTAssertFalse(caller.sendStudio(Data([1]), on: .program))
    }
    /// Both sides leave the studio, as `endStudio` does.
    private func leaveStudio() {
        caller.onStudioChannelsOpen = nil
        callee.onStudioChannelsOpen = nil
        caller.closeStudioChannels()
        callee.closeStudioChannels()
    }

    /// A second studio in the same call, once the first one's channels are closed: the data
    /// section is negotiated already, the channels are open as they are made, and the open is
    /// still announced — the host invites on it (2026-10-28: the second press sent an offer and
    /// Studio never started).
    ///
    /// Mutation: drop the `studioChannelChanged()` at the end of `openStudioChannels` — this
    /// reddens. Not covered: `studioChannelsClosed` waiting — in one process the old channels are
    /// closed before the next line runs, so a start at once does not fail here; over a network it
    /// did (2026-10-27, `Studio channel studio-control not created` the same second as leaving).
    func testASecondStudioInTheSameCallOpens() async throws {
        _ = try await connectCall()
        _ = try await startStudio()
        leaveStudio()
        await caller.studioChannelsClosed()
        await callee.studioChannelsClosed()
        _ = try await startStudio()
        XCTAssertTrue(caller.studioChannelsOpen)
        XCTAssertTrue(callee.studioChannelsOpen)
        XCTAssertTrue(caller.sendStudio(Data([1]), on: .control))
    }

    /// The guest's app crashes and comes back into the call: it answers the host's ICE restart as a
    /// new instance, with none of Studio's channels. The host learns it from the answer, and the
    /// channels of the studio before keep no new studio waiting (2026-10-28: every press of Studio
    /// waited for them, and only hanging up helped).
    ///
    /// Mutation: drop the `peerRestarted()` call — this reddens. Not covered: the wait itself. In
    /// one process the guest closes its channels as it goes, which a crash does not, so the host's
    /// are closed already and nothing is left to wait for; dropping the `closingStudioChannels`
    /// reset in `peerRestarted` stays green here.
    func testAGuestThatCameBackIsANewInstance() async throws {
        _ = try await connectCall()
        _ = try await startStudio()
        callee.onStudioChannelsOpen = nil
        callee.close()
        let restarted = try WebRTCSession(loopbackRole: .callee, video: false)
        callee = restarted
        let caller = caller!
        caller.onLocalIceCandidate = { candidate in
            Task { @MainActor in try? await restarted.addRemoteIceCandidate(candidate) }
        }
        restarted.onLocalIceCandidate = { candidate in
            Task { @MainActor in try? await caller.addRemoteIceCandidate(candidate) }
        }
        var peerRestarted = 0
        caller.onPeerRestarted = { peerRestarted += 1 }

        let offer = try await caller.restartIce()
        try await restarted.setRemoteOffer(sdp: offer)
        XCTAssertEqual(peerRestarted, 0, "the offerer's own restart says nothing yet")
        caller.closeStudioChannels()
        try await caller.setRemoteAnswer(sdp: try await restarted.createAnswer())
        XCTAssertEqual(peerRestarted, 1)

        let waited = expectation(description: "nothing to wait for")
        Task { await caller.studioChannelsClosed(); waited.fulfill() }
        await fulfillment(of: [waited], timeout: 2)
    }

    /// An ICE restart answered by the same instance is not a new one.
    func testARestartByTheSameGuestIsNotANewInstance() async throws {
        _ = try await connectCall()
        var peerRestarted = 0
        caller.onPeerRestarted = { peerRestarted += 1 }
        let restart = try await caller.restartIce()
        try await callee.setRemoteOffer(sdp: restart)
        try await caller.setRemoteAnswer(sdp: try await callee.createAnswer())
        XCTAssertEqual(peerRestarted, 0)
    }

    func testPeerInstanceReadsTheFingerprint() {
        let sdp = "v=0\r\na=group:BUNDLE 0\r\na=fingerprint:sha-256 AB:CD:EF\r\na=setup:actpass\r\n"
        XCTAssertEqual(PeerInstance.fingerprint(sdp: sdp), "sha-256 ab:cd:ef")
        XCTAssertNil(PeerInstance.fingerprint(sdp: "v=0\r\n"))
        XCTAssertFalse(PeerInstance.isNew("sha-256 ab", before: nil), "the first description")
        XCTAssertFalse(PeerInstance.isNew("sha-256 ab", before: "sha-256 ab"))
        XCTAssertTrue(PeerInstance.isNew("sha-256 cd", before: "sha-256 ab"))
    }

    /// The side that offers a second studio announces its channels only after the answer: before
    /// it the other side has made none, and an invite sent then is lost.
    ///
    /// Mutation: drop `!studioAwaitingAnswer` from the announcement — this reddens.
    func testASecondStudioIsAnnouncedOnlyAfterTheAnswer() async throws {
        _ = try await connectCall()
        _ = try await startStudio()
        leaveStudio()
        await caller.studioChannelsClosed()
        await callee.studioChannelsClosed()

        let early = expectation(description: "announced before the answer")
        early.isInverted = true
        caller.onStudioChannelsOpen = { early.fulfill() }
        try caller.openStudioChannels()
        let offer = try await caller.createOffer()
        await fulfillment(of: [early], timeout: 0.5)

        let open = expectation(description: "announced")
        caller.onStudioChannelsOpen = { open.fulfill() }
        try await callee.setRemoteOffer(sdp: offer)
        try callee.openStudioChannels()
        try await caller.setRemoteAnswer(sdp: try await callee.createAnswer())
        await fulfillment(of: [open], timeout: 10)
    }
}
