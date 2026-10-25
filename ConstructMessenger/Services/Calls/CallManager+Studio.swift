//
//  CallManager+Studio.swift
//  Construct Messenger
//
//  Studio added to a call in progress (`decisions/studio-mode-on-desktop.md`, steps 3–4): the host
//  makes Studio's channels and offers again; the guest makes its own before it answers. Once both
//  channels are open the host invites on `studio-control` with the program's format and its
//  decoder cookie; when the guest accepts, the host's capture runs into `studio-program` and the
//  guest plays it through its ring and drift loop.
//
//  Behind `StudioFeature`, on by default on a Mac while the Desktop build goes only to its testers:
//  no invite screen, no path choice (always relay), no screen — those are steps 5–6.
//

import Foundation
import SwiftProtobuf
import Synchronization

/// Studio mode, while it is built. On by default on a Mac since 2026-10-23: the Desktop build is
/// handed only to the testers who asked for Studio. Off by hand:
/// `defaults write <Desktop bundle id> StudioDebug -bool NO`. A user default rather than a Debug
/// build, so the notarised build can be tried on two Macs.
enum StudioFeature {
    static let defaultsKey = "StudioDebug"

    static var isEnabled: Bool {
        #if os(macOS)
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
        #else
        false
        #endif
    }
}

/// What an offer says about Studio. Pure, so the rule is tested apart from WebRTC.
enum StudioOffer {
    /// Whether the offer has a data section — the only thing a call puts one there for is Studio.
    /// By line: SDP ends its lines with CRLF, which Swift reads as one character, so a search for
    /// "\nm=application" never matches.
    static func carriesStudio(sdp: String) -> Bool {
        sdp.split(whereSeparator: \.isNewline).contains { $0.hasPrefix("m=application") }
    }
}

/// What captures the program on this machine — the Desktop's process tap. Started on the main
/// actor; feeds `packetizer` on its own thread.
protocol StudioProgramCapture: AnyObject {
    /// A line for the log: what is being captured.
    var sourceDescription: String { get }
    func start(into packetizer: StudioCapturePacketizer) throws
    func stop()
}

/// What plays the program on this machine — the Desktop's output with its drift loop. Started and
/// stopped on the main actor; reads `playout` on the audio render thread.
protocol StudioProgramOutput: AnyObject {
    func stop()
}

/// The program receiver the `studio-program` channel feeds, swapped on the main actor when the
/// format changes and read on WebRTC's thread for every packet.
final class StudioProgramRoute: Sendable {
    private let current = Mutex<StudioProgramReceiver?>(nil)

    func use(_ receiver: StudioProgramReceiver?) { current.withLock { $0 = receiver } }

    func deliver(_ data: Data) { current.withLock { $0 }?.receive(data) }
}

/// One studio on one call: the control link and whatever runs for it on this side.
@MainActor
final class StudioRun {
    let link: StudioLink
    let route = StudioProgramRoute()
    /// Host: made with the invite, whose magic cookie is its encoder's.
    var sender: StudioProgramSender?
    var capture: (any StudioProgramCapture)?
    /// Guest.
    var receiver: StudioProgramReceiver?
    var output: (any StudioProgramOutput)?
    /// Guest: the depth the invite asked for.
    var bufferMs = StudioBuffer.defaultMs
    var inviteTimeout: Task<Void, Never>?

    init(link: StudioLink) { self.link = link }

    func stop() {
        inviteTimeout?.cancel()
        inviteTimeout = nil
        capture?.stop()
        capture = nil
        output?.stop()
        output = nil
        route.use(nil)
        if let sender {
            Log.info("Studio program sent: \(sender.sent) packets, \(sender.refused) refused", category: "Calls")
        }
        if let receiver {
            let c = receiver.counts
            Log.info(
                "Studio program received: \(c.packets) packets, \(c.otherEpoch) of another format, "
                + "\(c.malformed) malformed, \(c.undecodable) undecodable; \(receiver.playout.gapFrames) frames of gap, "
                + "\(receiver.playout.underruns) underruns, \(receiver.playout.droppedSamples) samples dropped",
                category: "Calls"
            )
        }
        sender = nil
        receiver = nil
    }
}

/// The program's buffer depth until question 5 of the decision (fixed or adaptive) is settled.
enum StudioBuffer {
    static let defaultMs: UInt32 = 400
    /// What a guest takes from an invite: deep enough for a resend to arrive, short enough that a
    /// mistaken value cannot hold the program back for seconds.
    static func targetSeconds(invite bufferMs: UInt32) -> Double {
        let ms = bufferMs == 0 ? defaultMs : min(max(bufferMs, 100), 2_000)
        return Double(ms) / 1_000
    }
}

#if canImport(WebRTC)
extension CallManager {
    /// What makes the host's capture on this machine; set by the Desktop app at launch.
    nonisolated(unsafe) static var makeStudioCapture: (() throws -> any StudioProgramCapture)?
    /// What plays the program on this machine; set by the Desktop app at launch.
    nonisolated(unsafe) static var makeStudioOutput: ((StudioPlayout) throws -> any StudioProgramOutput)?

    /// How long the host waits for the guest's answer.
    static let studioInviteTimeout: Duration = .seconds(30)

    /// Host: add Studio to the call in progress. Once both channels are open the invite goes out
    /// on `studio-control`; the program starts when the guest accepts.
    func startStudio() async {
        guard StudioFeature.isEnabled else { return }
        guard let active, let webrtc = active.webrtc as? WebRTCSession else {
            Log.info("Studio: no call to add it to", category: "Calls")
            return
        }
        guard active.studio == nil else {
            Log.info("Studio: already on", category: "Calls")
            return
        }
        guard Self.makeStudioCapture != nil else {
            Log.error("Studio: nothing on this machine can capture the program", category: "Calls")
            return
        }
        let run = makeStudioRun(role: .host, on: webrtc, for: active)
        do {
            // The call is named by its id: `ActiveCall` is the main actor's and does not cross
            // to WebRTC's thread, where this is called.
            let callId = active.session.id
            webrtc.onStudioChannelsOpen = { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, let active = self.active, active.session.id == callId,
                              active.studio === run else { return }
                        self.inviteToStudio(run, on: webrtc, for: active)
                    }
                }
            }
            try webrtc.openStudioChannels()
            let sdp = try await webrtc.createOffer()
            guard self.active === active else { return }
            try sendOffer(sdp: sdp, toUserId: active.session.peerUserId, isIceRestart: false)
            Log.info("Studio offer sent call_id=\(active.session.id.prefix(8))…", category: "Calls")
        } catch {
            Log.error("Studio not started: \(error)", category: "Calls")
            endStudio(run, for: active)
        }
    }

    /// Guest: the peer offered Studio; make our channels before the answer, so the answer accepts
    /// them. The invite follows on `studio-control`.
    func joinStudioIfOffered(sdp: String, on webrtc: any WebRTCSessionProtocol) {
        guard StudioFeature.isEnabled, StudioOffer.carriesStudio(sdp: sdp), let active,
              let webrtc = webrtc as? WebRTCSession, !webrtc.studioChannelsOpen, active.studio == nil else { return }
        let run = makeStudioRun(role: .guest, on: webrtc, for: active)
        do {
            webrtc.onStudioChannelsOpen = { Log.info("Studio: channels open as guest", category: "Calls") }
            try webrtc.openStudioChannels()
        } catch {
            Log.error("Studio offered, channels not made: \(error)", category: "Calls")
            endStudio(run, for: active)
        }
    }

    /// Leave the studio; the call goes on.
    func stopStudio() {
        guard let active else { return }
        if let run = active.studio {
            run.link.handle(.leave)
        } else {
            (active.webrtc as? WebRTCSession)?.closeStudioChannels()
        }
    }

    private func makeStudioRun(role: StudioControlMachine.Role, on webrtc: WebRTCSession, for active: ActiveCall) -> StudioRun {
        let run = StudioRun(link: StudioLink(role: role) { webrtc.sendStudio($0, on: .control) })
        active.studio = run
        studioCallId = active.session.id
        let route = run.route
        // Control messages go to the main actor in arrival order (a queue, not a task per
        // message, whose order is not promised); program packets stay off it.
        webrtc.setStudioReceiver { [weak run] channel, data in
            switch channel {
            case .control:
                DispatchQueue.main.async { [weak run] in MainActor.assumeIsolated { run?.link.receive(data) } }
            case .program:
                route.deliver(data)
            }
        }
        run.link.onInvite = { [weak self, weak run, weak active] invite in
            guard let self, let run, let active else { return }
            self.answerStudioInvite(invite, run: run, for: active)
        }
        run.link.onUseFormat = { [weak self, weak run, weak active] format in
            guard let self, let run, let active else { return }
            switch role {
            case .host: self.startStudioProgram(format, run: run, on: webrtc, for: active)
            case .guest: self.playStudioProgram(format, run: run, for: active)
            }
        }
        run.link.onEnd = { [weak self, weak run, weak active] reason in
            Log.info("Studio ended: \(reason)", category: "Calls")
            guard let self, let run, let active else { return }
            self.endStudio(run, for: active)
        }
        return run
    }

    private func inviteToStudio(_ run: StudioRun, on webrtc: WebRTCSession, for active: ActiveCall) {
        guard let send = webrtc.studioSender(on: .program) else { return }
        do {
            let sender = try StudioProgramSender(format: .lossless, epoch: 0, send: send)
            run.sender = sender
            var invite = StudioInvite()
            invite.program = StudioAudioFormat.lossless.program(magicCookie: sender.magicCookie)
            invite.bufferMs = StudioBuffer.defaultMs
            // Relay: the path choice comes with the invite screen (step 6).
            run.link.handle(.invite(invite, ownPath: .relay, veil: false))
            Log.info("Studio invite sent (FLAC 48/24, \(invite.bufferMs) ms)", category: "Calls")
            run.inviteTimeout = Task { [weak run] in
                try? await Task.sleep(for: Self.studioInviteTimeout)
                guard !Task.isCancelled else { return }
                run?.link.handle(.inviteTimedOut)
            }
        } catch {
            Log.error("Studio invite not made: \(error)", category: "Calls")
            endStudio(run, for: active)
        }
    }

    /// Guest. There is no invite screen until step 6, and the switch that turns Studio on is set
    /// by hand on this Mac: setting it is the consent, so the invite is taken here — on relay.
    private func answerStudioInvite(_ invite: StudioInvite, run: StudioRun, for active: ActiveCall) {
        guard Self.makeStudioOutput != nil else {
            Log.error("Studio invite declined: nothing on this machine can play the program", category: "Calls")
            run.link.handle(.decline)
            return
        }
        run.bufferMs = invite.bufferMs
        Log.info("Studio invite accepted (\(invite.program.codec), \(invite.bufferMs) ms)", category: "Calls")
        run.link.handle(.accept(ownPath: .relay, veil: false))
    }

    private func startStudioProgram(_ format: StudioProgramFormat, run: StudioRun, on webrtc: WebRTCSession, for active: ActiveCall) {
        run.inviteTimeout?.cancel()
        guard run.capture == nil else {
            // A format change mid-studio needs a new encoder and a new invite cookie; not built yet.
            Log.error("Studio: a change of format is not supported yet", category: "Calls")
            return
        }
        guard let sender = run.sender, format.epoch == sender.epoch, let make = Self.makeStudioCapture else { return }
        do {
            let capture = try make()
            let packetizer = StudioCapturePacketizer(format: sender.format) { samples, firstFrame in
                do { try sender.submit(samples, firstFrame: firstFrame) } catch {
                    Log.error("Studio program not encoded: \(error)", category: "Calls")
                }
            }
            try capture.start(into: packetizer)
            run.capture = capture
            Log.info("Studio program: capturing \(capture.sourceDescription) → FLAC 48/24", category: "Calls")
        } catch {
            Log.error("Studio program not started: \(error)", category: "Calls")
            run.link.handle(.leave)
        }
    }

    private func playStudioProgram(_ format: StudioProgramFormat, run: StudioRun, for active: ActiveCall) {
        guard let makeOutput = Self.makeStudioOutput else {
            run.link.handle(.leave)
            return
        }
        do {
            let receiver = try StudioProgramReceiver(
                program: format, targetSeconds: StudioBuffer.targetSeconds(invite: run.bufferMs)
            )
            let output = try makeOutput(receiver.playout)
            run.output?.stop()
            run.output = output
            run.receiver = receiver
            run.route.use(receiver)
            Log.info("Studio program: playing \(format.codec) \(format.sampleRate / 1_000) kHz, buffer \(Int(StudioBuffer.targetSeconds(invite: run.bufferMs) * 1_000)) ms", category: "Calls")
        } catch {
            Log.error("Studio program not played: \(error)", category: "Calls")
            run.link.handle(.leave)
        }
    }

    private func endStudio(_ run: StudioRun, for active: ActiveCall) {
        run.stop()
        if active.studio === run {
            active.studio = nil
            if studioCallId == active.session.id { studioCallId = nil }
        }
        guard let webrtc = active.webrtc as? WebRTCSession else { return }
        webrtc.setStudioReceiver(nil)
        webrtc.onStudioChannelsOpen = nil
        webrtc.closeStudioChannels()
    }
}
#else
extension CallManager {
    func joinStudioIfOffered(sdp: String, on webrtc: any WebRTCSessionProtocol) {}
}
#endif
