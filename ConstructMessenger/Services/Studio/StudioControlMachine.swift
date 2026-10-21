//
//  StudioControlMachine.swift
//  Construct Messenger
//
//  The `studio-control` protocol as a pure machine: a state and an event in, the next state and
//  the effects out. It sends nothing and touches no connection — the caller writes `.send`
//  messages to the channel and carries out the rest. Vault `decisions/studio-mode-on-desktop.md`.
//
//  One host per studio. The host invites, decides the path and owns the format; a guest answers,
//  listens and may ask for a lighter codec.
//
//  Path: each party chooses its own and applies only its own. The host learns the guest's choice
//  (it computes the result); the guest learns only the result. A party that chose relay never
//  widens its ICE policy, whatever decision arrives — the one rule that keeps a refusal from
//  being overridden by the other side.
//

import Foundation

typealias StudioControl = Construct_Client_Studio_V1_StudioControl
typealias StudioPath = Construct_Client_Studio_V1_Path
typealias StudioProgramFormat = Construct_Client_Studio_V1_ProgramFormat
typealias StudioInvite = Construct_Client_Studio_V1_Invite
typealias StudioCodec = Construct_Client_Studio_V1_Codec

enum StudioControlMachine {
    static let version: UInt32 = 1

    enum Role: Equatable, Sendable { case host, guest }

    enum EndReason: Equatable, Sendable {
        /// This side left.
        case left
        /// The other side left.
        case remoteLeft
        /// The guest declined (on the guest: this side did).
        case declined
        /// The host's invite went unanswered.
        case noAnswer
        /// The invite asked for something this build cannot play.
        case unsupported
        /// The other side speaks a version of the protocol this build does not.
        case incompatible
        /// The control channel went away under the studio.
        case channelClosed
    }

    enum Phase: Equatable, Sendable {
        case idle
        /// Host: invite sent, waiting for the guest's answer.
        case inviting
        /// Guest: invite received, waiting for this side's answer.
        case invited(StudioInvite)
        /// Guest: accepted, waiting for the host's path decision.
        case awaitingDecision
        case live
        case ended(EndReason)
    }

    struct State: Equatable, Sendable {
        var role: Role
        var phase: Phase = .idle
        /// This side's own choice, already clamped (relay under VEIL).
        var ownPath: StudioPath = .relay
        /// The path in effect once live.
        var path: StudioPath = .relay
        var format: StudioProgramFormat?
        var screenShown = false

        init(role: Role) { self.role = role }

        var isActive: Bool {
            switch phase {
            case .idle, .ended: false
            default: true
            }
        }

        /// A program packet is played only under the format it was encoded with; packets of the
        /// previous format still in flight after a change are dropped, not decoded wrongly.
        func accepts(_ packet: Construct_Client_Studio_V1_ProgramPacket) -> Bool {
            phase == .live && format?.epoch == packet.formatEpoch
        }
    }

    enum Event: Equatable, Sendable {
        /// Host: open the studio with this invite. `veil`: VEIL is on, so the path is relay.
        case invite(StudioInvite, ownPath: StudioPath, veil: Bool)
        /// Guest: accept with this side's path choice.
        case accept(ownPath: StudioPath, veil: Bool)
        case decline
        case leave
        /// Host: the invite went unanswered for too long.
        case inviteTimedOut
        /// Host: switch the program to this format. The machine assigns the epoch.
        case changeFormat(StudioProgramFormat)
        /// Host: show or hide its windows.
        case setScreen(Bool)
        /// Guest: ask the host for a lighter codec.
        case requestQuality(StudioCodec)
        case ping(sentAtNs: UInt64)
        case received(StudioControl)
        case channelClosed
    }

    enum Effect: Equatable, Sendable {
        case send(StudioControl)
        /// Guest: show the invite and wait for the person's answer.
        case presentInvite(StudioInvite)
        /// Host: start encoding and sending the program in this format (also after a change).
        /// Guest: set the decoder up for it.
        case useFormat(StudioProgramFormat)
        /// Widen this side's ICE policy to direct and restart ICE. Emitted only when this side
        /// chose direct and the decision is direct; relay needs no effect — nothing changes.
        case goDirect
        /// Guest: the host showed or hid its windows.
        case screenShown(Bool)
        /// Host: the guest asks for a lighter codec; the host decides.
        case qualityRequested(StudioCodec)
        case roundTrip(sentAtNs: UInt64)
        /// The studio is over: stop the program, close the channels and the screen track, and
        /// put the ICE policy back to relay. The call continues.
        case end(EndReason)
    }

    typealias Outcome = (state: State, effects: [Effect])

    /// Every event is guarded by the phases it applies in, and none applies once ended, so an
    /// ended studio stays ended.
    static func reduce(_ state: State, _ event: Event) -> Outcome {
        var s = state

        switch event {
        case .invite(var invite, let ownPath, let veil):
            guard s.role == .host, s.phase == .idle, invite.hasProgram else { return (state, []) }
            invite.program.epoch = 0
            s.ownPath = clamp(ownPath, veil: veil)
            s.format = invite.program
            s.screenShown = invite.screen
            s.phase = .inviting
            return (s, [.send(message(.invite(invite)))])

        case .accept(let ownPath, let veil):
            guard s.role == .guest, case .invited(let invite) = s.phase else { return (state, []) }
            s.ownPath = clamp(ownPath, veil: veil)
            s.format = invite.program
            s.screenShown = invite.screen
            s.phase = .awaitingDecision
            var accept = Construct_Client_Studio_V1_Accept()
            accept.guestPath = s.ownPath
            return (s, [.send(message(.accept(accept))), .useFormat(invite.program)])

        case .decline:
            guard s.role == .guest, case .invited = s.phase else { return (state, []) }
            s.phase = .ended(.declined)
            return (s, [.send(message(.decline(.init()))), .end(.declined)])

        case .leave:
            guard s.isActive else { return (state, []) }
            return end(s, .left, notify: true)

        case .inviteTimedOut:
            guard s.role == .host, s.phase == .inviting else { return (state, []) }
            return end(s, .noAnswer, notify: true)

        case .changeFormat(var format):
            guard s.role == .host, s.phase == .live, let current = s.format else { return (state, []) }
            format.epoch = current.epoch &+ 1
            s.format = format
            var change = Construct_Client_Studio_V1_FormatChange()
            change.program = format
            return (s, [.send(message(.formatChange(change))), .useFormat(format)])

        case .setScreen(let shown):
            guard s.role == .host, s.phase == .live, s.screenShown != shown else { return (state, []) }
            s.screenShown = shown
            var screen = Construct_Client_Studio_V1_ScreenState()
            screen.shown = shown
            return (s, [.send(message(.screenState(screen)))])

        case .requestQuality(let codec):
            guard s.role == .guest, s.phase == .live else { return (state, []) }
            var request = Construct_Client_Studio_V1_QualityRequest()
            request.codec = codec
            return (s, [.send(message(.qualityRequest(request)))])

        case .ping(let sentAtNs):
            guard s.isActive else { return (state, []) }
            var ping = Construct_Client_Studio_V1_Ping()
            ping.sentAtNs = sentAtNs
            return (s, [.send(message(.ping(ping)))])

        case .channelClosed:
            guard s.isActive else { return (state, []) }
            return end(s, .channelClosed, notify: false)

        case .received(let control):
            return receive(s, control)
        }
    }

    private static func receive(_ s: State, _ control: StudioControl) -> Outcome {
        // An invite is the only message that may open a studio; everything else needs one open.
        if case .invite = control.body {} else if !s.isActive { return (s, []) }
        if control.version != version {
            // Both sides of a studio run one version. A mismatch cannot be negotiated down
            // from here, so the studio ends cleanly rather than half-understood.
            if s.phase == .idle, s.role == .guest {
                var t = s
                t.phase = .ended(.incompatible)
                return (t, [.send(message(.decline(.init()))), .end(.incompatible)])
            }
            return s.isActive ? end(s, .incompatible, notify: true) : (s, [])
        }
        var t = s

        switch control.body {
        case .invite(let invite)?:
            guard s.role == .guest, s.phase == .idle else { return (s, []) }
            guard invite.hasProgram, StudioAudioFormat(program: invite.program) != nil else {
                t.phase = .ended(.unsupported)
                return (t, [.send(message(.decline(.init()))), .end(.unsupported)])
            }
            t.phase = .invited(invite)
            return (t, [.presentInvite(invite)])

        case .accept(let accept)?:
            guard s.role == .host, s.phase == .inviting, let format = s.format else { return (s, []) }
            let path: StudioPath = (s.ownPath == .direct && accept.guestPath == .direct) ? .direct : .relay
            t.path = path
            t.phase = .live
            var decision = Construct_Client_Studio_V1_PathDecision()
            decision.path = path
            var effects: [Effect] = [.send(message(.pathDecision(decision))), .useFormat(format)]
            if path == .direct { effects.append(.goDirect) }
            return (t, effects)

        case .decline?:
            guard s.role == .host, s.phase == .inviting else { return (s, []) }
            return end(s, .declined, notify: false)

        case .pathDecision(let decision)?:
            guard s.role == .guest, s.phase == .awaitingDecision else { return (s, []) }
            // Only this side's own choice can widen this side's policy.
            t.path = (decision.path == .direct && s.ownPath == .direct) ? .direct : .relay
            t.phase = .live
            return (t, t.path == .direct ? [.goDirect] : [])

        case .formatChange(let change)?:
            guard s.role == .guest, s.phase == .live, change.hasProgram, let current = s.format,
                  change.program.epoch != current.epoch else { return (s, []) }
            guard StudioAudioFormat(program: change.program) != nil else {
                return end(s, .unsupported, notify: true)
            }
            t.format = change.program
            return (t, [.useFormat(change.program)])

        case .qualityRequest(let request)?:
            guard s.role == .host, s.phase == .live else { return (s, []) }
            return (s, [.qualityRequested(request.codec)])

        case .screenState(let screen)?:
            guard s.role == .guest, s.phase == .live, s.screenShown != screen.shown else { return (s, []) }
            t.screenShown = screen.shown
            return (t, [.screenShown(screen.shown)])

        case .leave?:
            return end(s, .remoteLeft, notify: false)

        case .ping(let ping)?:
            var pong = Construct_Client_Studio_V1_Pong()
            pong.sentAtNs = ping.sentAtNs
            return (s, [.send(message(.pong(pong)))])

        case .pong(let pong)?:
            return (s, [.roundTrip(sentAtNs: pong.sentAtNs)])

        case nil:
            return (s, [])
        }
    }

    private static func end(_ s: State, _ reason: EndReason, notify: Bool) -> Outcome {
        var t = s
        t.phase = .ended(reason)
        let effects: [Effect] = notify ? [.send(message(.leave(.init()))), .end(reason)] : [.end(reason)]
        return (t, effects)
    }

    /// VEIL hides where this device is; a direct path would go around it.
    private static func clamp(_ path: StudioPath, veil: Bool) -> StudioPath {
        path == .direct && !veil ? .direct : .relay
    }

    static func message(_ body: StudioControl.OneOf_Body) -> StudioControl {
        var control = StudioControl()
        control.version = version
        control.body = body
        return control
    }
}

extension StudioAudioFormat {
    /// The wire format as something this build can encode and play, or nil. Phase 1 plays
    /// 48 kHz only (owner, 2026-10-21); 96/24 is a separate decision.
    init?(program: StudioProgramFormat) {
        guard program.sampleRate == 48_000, (1...2).contains(program.channels) else { return nil }
        switch program.codec {
        case .flac:
            guard program.framesPerPacket == 1024 else { return nil }
            self.init(codec: .flac, sampleRate: 48_000, channels: program.channels, framesPerPacket: 1024)
        case .opus:
            guard program.framesPerPacket == 960, (6_000...512_000).contains(program.bitRate) else { return nil }
            self.init(codec: .opus(bitRate: program.bitRate), sampleRate: 48_000,
                      channels: program.channels, framesPerPacket: 960)
        case .unspecified, .UNRECOGNIZED:
            return nil
        }
    }

    /// The wire form of this format. The epoch is the machine's to assign.
    func program(magicCookie: Data) -> StudioProgramFormat {
        var p = StudioProgramFormat()
        switch codec {
        case .flac:
            p.codec = .flac
        case .opus(let bitRate):
            p.codec = .opus
            p.bitRate = bitRate
        }
        p.sampleRate = UInt32(sampleRate)
        p.channels = channels
        p.framesPerPacket = framesPerPacket
        p.magicCookie = magicCookie
        return p
    }
}
