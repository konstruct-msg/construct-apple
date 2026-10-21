//
//  StudioControlMachineTests.swift
//  ConstructMessengerTests
//
//  The studio-control protocol between a host and a guest machine: the path rule (direct only
//  when both chose it, and a side that chose relay never widens whatever arrives), VEIL forcing
//  relay, format epochs, and the ways a studio ends.
//

import SwiftProtobuf
import XCTest
@testable import Construct_Messenger

private typealias M = StudioControlMachine

final class StudioControlMachineTests: XCTestCase {
    private func invite(_ format: StudioAudioFormat = .lossless, screen: Bool = true) -> StudioInvite {
        var i = StudioInvite()
        i.program = format.program(magicCookie: Data([1, 2, 3]))
        i.screen = screen
        i.screenHeight = screen ? 1440 : 0
        i.bufferMs = 400
        return i
    }

    private func sent(_ effects: [M.Effect]) -> [StudioControl] {
        effects.compactMap { if case .send(let m) = $0 { m } else { nil } }
    }

    /// Runs one studio to live: host invites with `hostPath`, guest accepts with `guestPath`.
    /// Every message one machine sends is fed to the other, through the wire encoding.
    private func open(hostPath: StudioPath, guestPath: StudioPath, hostVeil: Bool = false, guestVeil: Bool = false)
        throws -> (host: M.State, guest: M.State, hostEffects: [M.Effect], guestEffects: [M.Effect]) {
        var host = M.State(role: .host), guest = M.State(role: .guest)
        var hostFx: [M.Effect] = [], guestFx: [M.Effect] = []
        func toGuest(_ fx: [M.Effect]) throws {
            for m in sent(fx) {
                let (s, e) = M.reduce(guest, .received(try StudioControl(serializedBytes: m.serializedData())))
                guest = s; guestFx += e
                try toHost(e)
            }
        }
        func toHost(_ fx: [M.Effect]) throws {
            for m in sent(fx) {
                let (s, e) = M.reduce(host, .received(try StudioControl(serializedBytes: m.serializedData())))
                host = s; hostFx += e
                try toGuest(e)
            }
        }
        var (s, e) = M.reduce(host, .invite(invite(), ownPath: hostPath, veil: hostVeil))
        host = s; hostFx += e
        try toGuest(e)
        (s, e) = M.reduce(guest, .accept(ownPath: guestPath, veil: guestVeil))
        guest = s; guestFx += e
        try toHost(e)
        return (host, guest, hostFx, guestFx)
    }

    func testBothChoosingDirectGoesDirectOnBothSides() throws {
        let r = try open(hostPath: .direct, guestPath: .direct)
        XCTAssertEqual(r.host.phase, .live)
        XCTAssertEqual(r.guest.phase, .live)
        XCTAssertEqual(r.host.path, .direct)
        XCTAssertEqual(r.guest.path, .direct)
        XCTAssertTrue(r.hostEffects.contains(.goDirect))
        XCTAssertTrue(r.guestEffects.contains(.goDirect))
    }

    func testEitherChoosingRelayKeepsBothOnRelay() throws {
        for (h, g) in [(StudioPath.relay, StudioPath.direct), (.direct, .relay), (.relay, .relay)] {
            let r = try open(hostPath: h, guestPath: g)
            XCTAssertEqual(r.host.path, .relay, "host \(h) guest \(g)")
            XCTAssertEqual(r.guest.path, .relay, "host \(h) guest \(g)")
            XCTAssertFalse(r.hostEffects.contains(.goDirect), "host \(h) guest \(g)")
            XCTAssertFalse(r.guestEffects.contains(.goDirect), "host \(h) guest \(g)")
            XCTAssertEqual(r.host.phase, .live)
        }
    }

    /// The host's choice never travels: the invite has no path, and a relay decision reads the
    /// same whichever side refused.
    func testTheInviteDoesNotCarryTheHostsChoice() throws {
        let direct = sent(M.reduce(M.State(role: .host), .invite(invite(), ownPath: .direct, veil: false)).effects)
        let relay = sent(M.reduce(M.State(role: .host), .invite(invite(), ownPath: .relay, veil: false)).effects)
        XCTAssertEqual(try direct[0].serializedData(), try relay[0].serializedData())
    }

    /// A guest that chose relay does not widen even if a (misbehaving) host decides direct.
    func testARelayGuestIgnoresADirectDecision() {
        var guest = M.State(role: .guest)
        guest = M.reduce(guest, .received(M.message(.invite(invite())))).state
        guest = M.reduce(guest, .accept(ownPath: .relay, veil: false)).state
        var decision = Construct_Client_Studio_V1_PathDecision()
        decision.path = .direct
        let (s, e) = M.reduce(guest, .received(M.message(.pathDecision(decision))))
        XCTAssertEqual(s.phase, .live)
        XCTAssertEqual(s.path, .relay)
        XCTAssertFalse(e.contains(.goDirect))
    }

    func testVeilForcesRelayOnEitherSide() throws {
        for (hv, gv) in [(true, false), (false, true)] {
            let r = try open(hostPath: .direct, guestPath: .direct, hostVeil: hv, guestVeil: gv)
            XCTAssertEqual(r.host.path, .relay, "host veil \(hv)")
            XCTAssertEqual(r.guest.path, .relay, "guest veil \(gv)")
        }
        let r = try open(hostPath: .direct, guestPath: .direct, guestVeil: true)
        let accept = sent(r.guestEffects).compactMap { if case .accept(let a)? = $0.body { a } else { nil } }
        XCTAssertEqual(accept.first?.guestPath, .relay, "the clamped choice is what the host learns")
    }

    func testTheGuestIsShownTheInviteAndSetsUpItsDecoderOnAccept() throws {
        let r = try open(hostPath: .relay, guestPath: .relay)
        XCTAssertTrue(r.guestEffects.contains(.presentInvite(invite())))
        XCTAssertTrue(r.guestEffects.contains(.useFormat(invite().program)))
        XCTAssertTrue(r.hostEffects.contains(.useFormat(invite().program)))
        XCTAssertTrue(r.guest.screenShown)
    }

    func testAnInviteThisBuildCannotPlayIsDeclined() {
        var i = invite()
        i.program.sampleRate = 96_000
        let (s, e) = M.reduce(M.State(role: .guest), .received(M.message(.invite(i))))
        XCTAssertEqual(s.phase, .ended(.unsupported))
        XCTAssertEqual(sent(e).first?.body, .decline(.init()))
    }

    func testAnotherProtocolVersionEndsTheStudio() throws {
        let r = try open(hostPath: .relay, guestPath: .relay)
        var ping = M.message(.ping(.init()))
        ping.version = 2
        let (s, e) = M.reduce(r.host, .received(ping))
        XCTAssertEqual(s.phase, .ended(.incompatible))
        XCTAssertEqual(sent(e).first?.body, .leave(.init()))
    }

    func testAFormatChangeAdvancesTheEpochAndOldPacketsAreDropped() throws {
        var r = try open(hostPath: .relay, guestPath: .relay)
        var packet = Construct_Client_Studio_V1_ProgramPacket()
        packet.formatEpoch = 0
        XCTAssertTrue(r.guest.accepts(packet))

        let (h, e) = M.reduce(r.host, .changeFormat(StudioAudioFormat.high.program(magicCookie: Data())))
        XCTAssertEqual(h.format?.epoch, 1, "the machine assigns the epoch")
        r.host = h
        let (g, ge) = M.reduce(r.guest, .received(sent(e)[0]))
        r.guest = g
        XCTAssertEqual(g.format?.codec, .opus)
        XCTAssertTrue(ge.contains(.useFormat(h.format!)))
        XCTAssertFalse(g.accepts(packet), "a packet of the old format is dropped")
        packet.formatEpoch = 1
        XCTAssertTrue(g.accepts(packet))

        let (_, again) = M.reduce(g, .received(sent(e)[0]))
        XCTAssertTrue(again.isEmpty, "a repeated change is ignored")
    }

    func testOnlyTheHostChangesFormatOrScreenAndOnlyTheGuestAsksForQuality() throws {
        let r = try open(hostPath: .relay, guestPath: .relay)
        XCTAssertTrue(M.reduce(r.guest, .changeFormat(StudioAudioFormat.high.program(magicCookie: Data()))).effects.isEmpty)
        XCTAssertTrue(M.reduce(r.guest, .setScreen(false)).effects.isEmpty)
        XCTAssertTrue(M.reduce(r.host, .requestQuality(.opus)).effects.isEmpty)

        let ask = M.reduce(r.guest, .requestQuality(.opus)).effects
        XCTAssertEqual(M.reduce(r.host, .received(sent(ask)[0])).effects, [.qualityRequested(.opus)])

        let hide = M.reduce(r.host, .setScreen(false))
        XCTAssertFalse(hide.state.screenShown)
        XCTAssertEqual(M.reduce(r.guest, .received(sent(hide.effects)[0])).effects, [.screenShown(false)])
    }

    func testLeavingEndsBothSidesAndNothingMovesAfterward() throws {
        let r = try open(hostPath: .direct, guestPath: .direct)
        let (g, ge) = M.reduce(r.guest, .leave)
        XCTAssertEqual(g.phase, .ended(.left))
        XCTAssertEqual(ge.last, .end(.left))
        let (h, he) = M.reduce(r.host, .received(sent(ge)[0]))
        XCTAssertEqual(h.phase, .ended(.remoteLeft))
        XCTAssertEqual(he, [.end(.remoteLeft)], "no leave is echoed back")
        XCTAssertTrue(M.reduce(h, .received(M.message(.ping(.init())))).effects.isEmpty)
        XCTAssertTrue(M.reduce(h, .setScreen(false)).effects.isEmpty)
    }

    func testADeclineEndsTheHostsInvite() {
        var host = M.reduce(M.State(role: .host), .invite(invite(), ownPath: .relay, veil: false)).state
        var guest = M.reduce(M.State(role: .guest), .received(M.message(.invite(invite())))).state
        let d = M.reduce(guest, .decline)
        guest = d.state
        XCTAssertEqual(guest.phase, .ended(.declined))
        host = M.reduce(host, .received(sent(d.effects)[0])).state
        XCTAssertEqual(host.phase, .ended(.declined))
    }

    func testAnUnansweredInviteTimesOutAndALateAcceptIsIgnored() {
        var host = M.reduce(M.State(role: .host), .invite(invite(), ownPath: .direct, veil: false)).state
        let t = M.reduce(host, .inviteTimedOut)
        host = t.state
        XCTAssertEqual(host.phase, .ended(.noAnswer))
        XCTAssertEqual(sent(t.effects).first?.body, .leave(.init()))
        var accept = Construct_Client_Studio_V1_Accept()
        accept.guestPath = .direct
        XCTAssertTrue(M.reduce(host, .received(M.message(.accept(accept)))).effects.isEmpty)
    }

    func testAClosedChannelEndsWithoutSending() throws {
        let r = try open(hostPath: .relay, guestPath: .relay)
        let (s, e) = M.reduce(r.host, .channelClosed)
        XCTAssertEqual(s.phase, .ended(.channelClosed))
        XCTAssertEqual(e, [.end(.channelClosed)])
    }

    func testMessagesBeforeAStudioOpensAreIgnored() {
        let idle = M.State(role: .guest)
        XCTAssertTrue(M.reduce(idle, .received(M.message(.ping(.init())))).effects.isEmpty)
        XCTAssertTrue(M.reduce(idle, .received(M.message(.leave(.init())))).effects.isEmpty)
        XCTAssertEqual(M.reduce(idle, .received(M.message(.leave(.init())))).state.phase, .idle)
    }

    func testAPingIsAnsweredWithItsOwnTimestamp() throws {
        let r = try open(hostPath: .relay, guestPath: .relay)
        let p = M.reduce(r.host, .ping(sentAtNs: 42)).effects
        let pong = M.reduce(r.guest, .received(sent(p)[0])).effects
        XCTAssertEqual(M.reduce(r.host, .received(sent(pong)[0])).effects, [.roundTrip(sentAtNs: 42)])
    }

    func testTheWireFormatRoundTripsBothPresets() {
        for f in [StudioAudioFormat.lossless, .high] {
            XCTAssertEqual(StudioAudioFormat(program: f.program(magicCookie: Data())), f)
        }
        var p = StudioAudioFormat.high.program(magicCookie: Data())
        p.bitRate = 600_000
        XCTAssertNil(StudioAudioFormat(program: p), "above what AudioToolbox's Opus takes")
    }
}
