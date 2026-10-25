//
//  StudioLinkTests.swift
//  ConstructMessengerTests
//
//  Two `StudioLink`s back to back are a whole studio without WebRTC: the host's invite reaches
//  the guest with the decoder's cookie, an accept makes both live, and the guest plays what the
//  host then sends (`decisions/studio-mode-on-desktop.md`, step 4). Each test names the mutation
//  that reddens it.
//

import XCTest
@testable import Construct_Messenger

@MainActor
final class StudioLinkTests: XCTestCase {

    /// The control channel between the two: messages wait here until `pump`, so neither link is
    /// re-entered from inside its own effects — as on the real channel.
    private var inFlight: [(to: StudioLink, data: Data)] = []
    private var host: StudioLink!
    private var guest: StudioLink!

    override func setUp() async throws {
        try await super.setUp()
        inFlight = []
        host = StudioLink(role: .host) { [unowned self] in inFlight.append((guest, $0)); return true }
        guest = StudioLink(role: .guest) { [unowned self] in inFlight.append((host, $0)); return true }
    }

    override func tearDown() async throws {
        host = nil
        guest = nil
        try await super.tearDown()
    }

    private func pump() {
        while !inFlight.isEmpty {
            let (to, data) = inFlight.removeFirst()
            to.receive(data)
        }
    }

    private func invite(cookie: Data) -> StudioInvite {
        var invite = StudioInvite()
        invite.program = StudioAudioFormat.lossless.program(magicCookie: cookie)
        invite.bufferMs = 400
        return invite
    }

    /// Invite, accept, and the program plays on the guest — the step-4 path end to end, with the
    /// guest answering as the debug build does.
    ///
    /// Mutation: the link drops its `.send` effects — the guest never sees the invite; this
    /// reddens.
    /// Mutation: the guest's `useFormat` carries no cookie (the link hands over a fresh
    /// `StudioProgramFormat`) — the receiver cannot be made; this reddens.
    func testTheGuestPlaysWhatTheHostSendsAfterAccepting() throws {
        var wire: [Data] = []
        let sender = try StudioProgramSender(format: .lossless, epoch: 0) { wire.append($0); return true }
        var hostFormat: StudioProgramFormat?
        var receiver: StudioProgramReceiver?
        host.onUseFormat = { hostFormat = $0 }
        guest.onInvite = { [unowned self] _ in guest.handle(.accept(ownPath: .relay, veil: false)) }
        guest.onUseFormat = { receiver = try? StudioProgramReceiver(program: $0, targetSeconds: 0.001) }

        host.handle(.invite(invite(cookie: sender.magicCookie), ownPath: .relay, veil: false))
        pump()

        XCTAssertEqual(host.state.phase, .live)
        XCTAssertEqual(guest.state.phase, .live)
        XCTAssertEqual(hostFormat?.epoch, 0)
        let r = try XCTUnwrap(receiver, "the guest made a receiver from the invite's format")

        let format = StudioAudioFormat.lossless
        let input = (0..<8).map { n in
            (0..<format.samplesPerPacket).map { Int32((($0 * 31 + n * 977) % 4_000_000) - 2_000_000) }
        }
        for (n, samples) in input.enumerated() {
            try sender.submit(samples, firstFrame: UInt64(n) * UInt64(format.framesPerPacket))
        }
        wire.forEach(r.receive)
        r.settle()

        let frames = Int((r.playout.fillSeconds * r.playout.sampleRate).rounded())
        XCTAssertGreaterThan(frames, 0)
        var played = [Float](repeating: 0, count: frames * r.playout.channels)
        played.withUnsafeMutableBufferPointer { r.playout.render(into: $0.baseAddress!, frames: frames) }
        let expected = input.joined().map { Float($0) * (1 / studioSampleFullScale) }
        XCTAssertEqual(played, Array(expected.prefix(played.count)))
    }

    /// Leaving on one side ends the studio on both, each once.
    ///
    /// Mutation: the link ignores `.end` — the other side's program keeps running; this reddens.
    func testLeavingEndsTheStudioOnBothSides() {
        var hostEnds: [StudioControlMachine.EndReason] = []
        var guestEnds: [StudioControlMachine.EndReason] = []
        host.onEnd = { hostEnds.append($0) }
        guest.onEnd = { guestEnds.append($0) }
        guest.onInvite = { [unowned self] _ in guest.handle(.accept(ownPath: .relay, veil: false)) }
        host.handle(.invite(invite(cookie: Data()), ownPath: .relay, veil: false))
        pump()

        guest.handle(.leave)
        pump()

        XCTAssertEqual(guestEnds, [.left])
        XCTAssertEqual(hostEnds, [.remoteLeft])
    }

    /// Bytes that are no control message change nothing.
    func testAMalformedControlMessageChangesNothing() {
        guest.receive(Data([0xFF, 0xFF, 0xFF, 0xFF]))
        XCTAssertEqual(guest.state.phase, .idle)
    }
}
