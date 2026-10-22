//
//  CallManager+Studio.swift
//  Construct Messenger
//
//  Studio added to a call in progress (`decisions/studio-mode-on-desktop.md`, step 3): the host
//  makes Studio's channels and offers again; the guest makes its own before it answers. Once both
//  channels are open the host's program capture runs into the `studio-program` channel.
//
//  Behind `StudioFeature`, a switch nobody but a developer sets: no invite yet, no consent, no
//  playout — the guest counts what arrives (step 4 plays it, and the `studio-control` invite comes
//  with it).
//

import Foundation
import SwiftProtobuf
import Synchronization

/// Studio mode, while it is built. Off unless set by hand on a Mac:
/// `defaults write <Desktop bundle id> StudioDebug -bool YES`. A user default rather than a Debug
/// build, so the notarised build can be tried on two Macs.
enum StudioFeature {
    static let defaultsKey = "StudioDebug"

    static var isEnabled: Bool {
        #if os(macOS)
        UserDefaults.standard.bool(forKey: defaultsKey)
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

/// Counts what arrives on Studio's channels and says so in the log, sparsely — until step 4
/// plays the program, the guest's only reader. Called on WebRTC's thread.
final class StudioReceiveCounter: Sendable {
    private struct Counts {
        var control = 0
        var program = 0
        var programBytes = 0
        var lastSequence: UInt32?
        var lastFirstFrame: UInt64?
        var malformed = 0
    }
    private let counts = Mutex(Counts())
    static let logEvery = 250

    func receive(_ channel: StudioChannel, _ data: Data) {
        let line: String? = counts.withLock { c in
            switch channel {
            case .control:
                c.control += 1
                return "Studio control message \(c.control) (\(data.count) B)"
            case .program:
                guard let packet = try? StudioProgramPacket(serializedBytes: data) else {
                    c.malformed += 1
                    return "Studio program: malformed packet (\(c.malformed))"
                }
                c.program += 1
                c.programBytes += data.count
                c.lastSequence = packet.sequence
                c.lastFirstFrame = packet.firstFrame
                guard c.program == 1 || c.program % Self.logEvery == 0 else { return nil }
                return "Studio program: \(c.program) packets, \(c.programBytes) B, seq \(packet.sequence), frame \(packet.firstFrame), epoch \(packet.formatEpoch)"
            }
        }
        if let line { Log.info(line, category: "Calls") }
    }
}

#if canImport(WebRTC)
extension CallManager {
    /// What makes the host's capture on this machine; set by the Desktop app at launch.
    nonisolated(unsafe) static var makeStudioCapture: (() throws -> any StudioProgramCapture)?

    /// Host: add Studio to the call in progress.
    func startStudio() async {
        guard StudioFeature.isEnabled else { return }
        guard let active, let webrtc = active.webrtc as? WebRTCSession else {
            Log.info("Studio: no call to add it to", category: "Calls")
            return
        }
        guard Self.makeStudioCapture != nil else {
            Log.error("Studio: nothing on this machine can capture the program", category: "Calls")
            return
        }
        do {
            webrtc.onStudioChannelsOpen = { [weak self, weak active] in
                Task { @MainActor in
                    guard let self, let active, self.active === active else { return }
                    self.startStudioProgram(for: active, on: webrtc)
                }
            }
            webrtc.setStudioReceiver(StudioReceiveCounter().receive)
            try webrtc.openStudioChannels()
            let sdp = try await webrtc.createOffer()
            guard self.active === active else { return }
            try sendOffer(sdp: sdp, toUserId: active.session.peerUserId, isIceRestart: false)
            Log.info("Studio offer sent call_id=\(active.session.id.prefix(8))…", category: "Calls")
        } catch {
            Log.error("Studio not started: \(error)", category: "Calls")
            webrtc.closeStudioChannels()
        }
    }

    /// Guest: the peer offered Studio; make our channels before the answer, so the answer accepts
    /// them. Nothing is played yet — what arrives is counted.
    func joinStudioIfOffered(sdp: String, on webrtc: any WebRTCSessionProtocol) {
        guard StudioFeature.isEnabled, StudioOffer.carriesStudio(sdp: sdp),
              let webrtc = webrtc as? WebRTCSession, !webrtc.studioChannelsOpen else { return }
        do {
            webrtc.setStudioReceiver(StudioReceiveCounter().receive)
            webrtc.onStudioChannelsOpen = { Log.info("Studio: joined as guest", category: "Calls") }
            try webrtc.openStudioChannels()
        } catch {
            Log.error("Studio offered, channels not made: \(error)", category: "Calls")
        }
    }

    func stopStudio() {
        guard let active else { return }
        active.studioCapture?.stop()
        active.studioCapture = nil
        (active.webrtc as? WebRTCSession)?.closeStudioChannels()
    }

    private func startStudioProgram(for active: ActiveCall, on webrtc: WebRTCSession) {
        guard active.studioCapture == nil, let make = Self.makeStudioCapture,
              let send = webrtc.studioSender(on: .program) else { return }
        do {
            let capture = try make()
            let sender = try StudioProgramSender(format: .lossless, epoch: 0, send: send)
            let packetizer = StudioCapturePacketizer(format: .lossless) { samples, firstFrame in
                do { try sender.submit(samples, firstFrame: firstFrame) } catch {
                    Log.error("Studio program not encoded: \(error)", category: "Calls")
                }
            }
            try capture.start(into: packetizer)
            active.studioCapture = capture
            Log.info("Studio program: capturing \(capture.sourceDescription) → FLAC 48/24", category: "Calls")
        } catch {
            Log.error("Studio program not started: \(error)", category: "Calls")
        }
    }
}
#else
extension CallManager {
    func joinStudioIfOffered(sdp: String, on webrtc: any WebRTCSessionProtocol) {}
}
#endif
