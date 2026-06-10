//
//  WebRTCSession.swift
//  Construct Messenger
//
//  WebRTC PeerConnection wrapper for audio calls.
//

import Foundation

struct WebRTCIceCandidate: Sendable, Equatable {
    let sdp: String
    let sdpMid: String
    let sdpMLineIndex: Int32
}

enum WebRTCSessionRole: Sendable {
    case caller
    case callee
}

enum WebRTCSessionError: Error {
    case webRTCLibraryMissing
    case invalidState(String)
}

@MainActor
protocol WebRTCSessionProtocol: AnyObject {
    var onLocalIceCandidate: (@Sendable (WebRTCIceCandidate) -> Void)? { get set }
    var onConnectionFailed: (@Sendable () -> Void)? { get set }
    var onConnected: (@Sendable () -> Void)? { get set }
    var onQualityChanged: (@Sendable (CallQuality) -> Void)? { get set }

    func createOffer() async throws -> String
    func createAnswer() async throws -> String
    func setRemoteOffer(sdp: String) async throws
    func setRemoteAnswer(sdp: String) async throws
    func addRemoteIceCandidate(_ candidate: WebRTCIceCandidate) async throws
    func setMuted(_ muted: Bool)
    func close()
}

#if canImport(WebRTC)
import AVFoundation
import WebRTC

@MainActor
private final class WebRTCFactory {
    static let shared = WebRTCFactory()
    let factory: RTCPeerConnectionFactory

    private init() {
        RTCInitializeSSL()
        // NOTE: audio-session manual-mode setup lives in `WebRTCRuntime.bootstrap()`
        // which MUST run at app launch, before anything else touches RTCAudioSession.
        // Setting `useManualAudio` lazily here was destructive: by the time the first
        // CallKit `didActivate` fired (which touches RTCAudioSession), this factory
        // wasn't init'd yet, so `useManualAudio` was still false. Then when this
        // factory finally init'd mid-call, it flipped `isAudioEnabled` back to false
        // and silenced the audio unit for the rest of the call.
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        self.factory = RTCPeerConnectionFactory(encoderFactory: encoderFactory, decoderFactory: decoderFactory)
    }
}

/// One-time WebRTC runtime setup. Call `bootstrap()` exactly once at app launch,
/// before any code touches `RTCAudioSession` or `CallKitProvider`. This puts
/// `RTCAudioSession` into manual-audio mode so CallKit (not WebRTC) drives the
/// AVAudioSession activation, and force-initialises the peer-connection factory
/// so its setup never races later activation events.
@MainActor
enum WebRTCRuntime {
    static func bootstrap() {
        #if canImport(WebRTC)
        let rtc = RTCAudioSession.sharedInstance()
        rtc.useManualAudio = true
        rtc.isAudioEnabled = false
        _ = WebRTCFactory.shared
        Log.info(
            "WebRTC bootstrap: useManualAudio=\(rtc.useManualAudio) isAudioEnabled=\(rtc.isAudioEnabled)",
            category: "Calls"
        )
        #endif
    }
}

@MainActor
final class WebRTCSession: NSObject, WebRTCSessionProtocol {
    var onLocalIceCandidate: (@Sendable (WebRTCIceCandidate) -> Void)?
    var onConnectionFailed: (@Sendable () -> Void)?
    // Fires once when `peerConnectionState` first reaches `.connected`. CallManager
    // uses this to stop the outgoing dial tone — otherwise its `AVAudioEngine` keeps
    // running on the shared `.playAndRecord` session and silences WebRTC's voice-
    // processing audio unit (call shows "connected" but no audio).
    var onConnected: (@Sendable () -> Void)?
    /// Fires on `.connected` / `.completed` / `.disconnected` transitions so
    /// the UI can render a "reconnecting" indicator without ending the call.
    /// `.failed` keeps going through `onConnectionFailed`.
    var onQualityChanged: (@Sendable (CallQuality) -> Void)?

    private let role: WebRTCSessionRole
    private let factory: RTCPeerConnectionFactory
    private let peerConnection: RTCPeerConnection

    private var localAudioTrack: RTCAudioTrack?

    /// WebRTC rejects `addIceCandidate` before the remote description is set, and a
    /// rejected candidate is lost permanently (no retry) — a frequent cause of a call
    /// stuck at `iceConnectionState=checking` when the peer's candidates arrive before
    /// its SDP. We buffer remote candidates until the remote description is applied,
    /// then drain them. Single owner of ICE-candidate ordering (was fragmented across
    /// CallManager's ad-hoc `pendingIceCandidates` which covered only one path).
    private var remoteDescriptionSet = false
    private var pendingRemoteCandidates: [WebRTCIceCandidate] = []

    init(role: WebRTCSessionRole, turn: Shared_Proto_Signaling_V1_TurnCredentials?) throws {
        self.role = role

        self.factory = WebRTCFactory.shared.factory

        let config = RTCConfiguration()
        config.iceServers = Self.buildIceServers(turn: turn)
        config.iceTransportPolicy = .all
        config.sdpSemantics = .unifiedPlan
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: ["DtlsSrtpKeyAgreement": "true"]
        )

        guard let pc = factory.peerConnection(with: config, constraints: constraints, delegate: nil) else {
            throw WebRTCSessionError.invalidState("Failed to create RTCPeerConnection")
        }
        self.peerConnection = pc

        super.init()

        self.peerConnection.delegate = self

        Self.configureAudioSession()
        self.localAudioTrack = Self.makeLocalAudioTrack(factory: factory)
        if let track = localAudioTrack {
            let sender = peerConnection.add(track, streamIds: ["audio"])
            Log.info(
                "WebRTC local audio track added: trackId=\(track.trackId) enabled=\(track.isEnabled) sender=\(sender != nil)",
                category: "Calls"
            )
        } else {
            Log.error("WebRTC local audio track is nil — call will be one-way at best", category: "Calls")
        }
        Self.dumpAudioState(label: "session-init role=\(role)")
    }

    func close() {
        peerConnection.close()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        #endif
    }

    func setMuted(_ muted: Bool) {
        localAudioTrack?.isEnabled = !muted
    }

    func createOffer() async throws -> String {
        let offerConstraints = RTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveAudio": "true", "OfferToReceiveVideo": "false"],
            optionalConstraints: nil
        )
        let offer = try await createSessionDescription { completion in
            self.peerConnection.offer(for: offerConstraints, completionHandler: completion)
        }
        try await setLocalDescription(offer)
        return offer.sdp
    }

    func createAnswer() async throws -> String {
        let answerConstraints = RTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveAudio": "true", "OfferToReceiveVideo": "false"],
            optionalConstraints: nil
        )
        let answer = try await createSessionDescription { completion in
            self.peerConnection.answer(for: answerConstraints, completionHandler: completion)
        }
        try await setLocalDescription(answer)
        return answer.sdp
    }

    func setRemoteOffer(sdp: String) async throws {
        let desc = RTCSessionDescription(type: .offer, sdp: sdp)
        try await setRemoteDescription(desc)
        await onRemoteDescriptionSet()
    }

    func setRemoteAnswer(sdp: String) async throws {
        let desc = RTCSessionDescription(type: .answer, sdp: sdp)
        try await setRemoteDescription(desc)
        await onRemoteDescriptionSet()
    }

    func addRemoteIceCandidate(_ candidate: WebRTCIceCandidate) async throws {
        // Buffer until the remote description is set — adding earlier makes WebRTC
        // drop the candidate permanently, stranding ICE at `checking`.
        guard remoteDescriptionSet else {
            pendingRemoteCandidates.append(candidate)
            Log.info("ICE: buffered remote candidate (\(pendingRemoteCandidates.count) pending, no remote SDP yet) \(Self.candidateSummary(candidate))", category: "Calls")
            return
        }
        try await addCandidateNow(candidate)
    }

    /// Drain any candidates that arrived before the remote description was applied.
    private func onRemoteDescriptionSet() async {
        remoteDescriptionSet = true
        guard !pendingRemoteCandidates.isEmpty else { return }
        let buffered = pendingRemoteCandidates
        pendingRemoteCandidates.removeAll()
        Log.info("ICE: remote SDP applied — draining \(buffered.count) buffered candidate(s)", category: "Calls")
        for candidate in buffered {
            do { try await addCandidateNow(candidate) }
            catch { Log.error("ICE: failed to add buffered candidate: \(error)", category: "Calls") }
        }
    }

    private func addCandidateNow(_ candidate: WebRTCIceCandidate) async throws {
        let rtc = RTCIceCandidate(
            sdp: candidate.sdp,
            sdpMLineIndex: candidate.sdpMLineIndex,
            sdpMid: candidate.sdpMid
        )
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            peerConnection.add(rtc) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
        Log.info("ICE: added remote candidate \(Self.candidateSummary(candidate))", category: "Calls")
    }

    /// Compact one-line candidate descriptor (type + protocol) for diagnostics, e.g.
    /// `typ relay udp`. Avoids dumping the full SDP (IPs/ports) at info level.
    nonisolated private static func candidateSummary(_ candidate: WebRTCIceCandidate) -> String {
        let parts = candidate.sdp.split(separator: " ").map(String.init)
        var typ = "?"
        if let i = parts.firstIndex(of: "typ"), i + 1 < parts.count { typ = parts[i + 1] }
        let proto = parts.count > 2 ? parts[2].lowercased() : "?"
        return "typ \(typ) \(proto)"
    }

    // MARK: - Helpers

    private func createSessionDescription(
        _ build: @escaping (@Sendable @escaping (RTCSessionDescription?, Error?) -> Void) -> Void
    ) async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { cont in
            build { sdp, error in
                if let error { cont.resume(throwing: error); return }
                guard let sdp else {
                    cont.resume(throwing: WebRTCSessionError.invalidState("Missing SDP"))
                    return
                }
                cont.resume(returning: sdp)
            }
        }
    }

    private func setLocalDescription(_ sdp: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            peerConnection.setLocalDescription(sdp) { error in
                if let error { cont.resume(throwing: error); return }
                cont.resume()
            }
        }
    }

    private func setRemoteDescription(_ sdp: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            peerConnection.setRemoteDescription(sdp) { error in
                if let error { cont.resume(throwing: error); return }
                cont.resume()
            }
        }
    }

    private static func buildIceServers(turn: Shared_Proto_Signaling_V1_TurnCredentials?) -> [RTCIceServer] {
        var servers: [RTCIceServer] = []
        if let turn, !turn.urls.isEmpty {
            // Server-provided TURN credentials (AMS coturn).
            // TURN servers also handle STUN binding requests, so no separate STUN needed.
            Log.info(
                "ICE config → TURN urls=\(turn.urls) username='\(turn.username)' credential.len=\(turn.credential.count)",
                category: "Calls"
            )
            servers.append(RTCIceServer(urlStrings: turn.urls, username: turn.username, credential: turn.credential))
        } else {
            // TURN unavailable (credentials fetch failed). Fall back to own STUN server (AMS).
            // Never use public STUN servers — call metadata must not leak to Google/Cloudflare.
            Log.info("ICE config → STUN-only fallback (turn=nil)", category: "Calls")
            servers.append(RTCIceServer(urlStrings: ["stun:ams.konstruct.cc:3478"]))
        }
        return servers
    }

    private static func makeLocalAudioTrack(factory: RTCPeerConnectionFactory) -> RTCAudioTrack {
        let source = factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        return factory.audioTrack(with: source, trackId: "audio0")
    }

    private static func configureAudioSession() {
        #if os(iOS)
        // Single owner: CallAudioController sets the category (and never activates —
        // CallKit owns activation). This is idempotent with the pre-fulfill call in
        // the CallKit start/answer handlers; doing it here too covers the in-app
        // answer path that bypasses the CXAnswerCallAction transaction.
        CallAudioController.prepareCategory()
        #endif
        // macOS: WebRTC handles audio device selection natively; no session configuration needed.
    }
}

extension WebRTCSession: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let c = WebRTCIceCandidate(
            sdp: candidate.sdp,
            sdpMid: candidate.sdpMid ?? "",
            sdpMLineIndex: candidate.sdpMLineIndex
        )
        Log.debug("ICE: local candidate generated \(Self.candidateSummary(c))", category: "Calls")
        Task { @MainActor in
            self.onLocalIceCandidate?(c)
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        Log.debug("WebRTC signalingState → \(stateChanged.rawValue)", category: "Calls")
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        Log.info("WebRTC iceConnectionState → \(newState.debugDescription)", category: "Calls")
        // `.disconnected` is transient on mobile (brief network hiccup, device lock, switch
        // between WiFi/cellular). Triggering teardown immediately cuts live calls unnecessarily.
        // Only `.failed` means ICE has exhausted all candidates and the call cannot continue.
        switch newState {
        case .failed:
            Task { @MainActor in self.onConnectionFailed?() }
        case .connected, .completed:
            Task { @MainActor in self.onQualityChanged?(.good) }
        case .disconnected:
            Task { @MainActor in self.onQualityChanged?(.reconnecting) }
        default:
            break
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        Log.debug("WebRTC iceGatheringState → \(newState.debugDescription)", category: "Calls")
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        Log.info("WebRTC peerConnectionState → \(newState.debugDescription)", category: "Calls")
        switch newState {
        case .connected:
            Task { @MainActor in
                Self.dumpAudioState(label: "peer-connected")
                self.dumpPeerTracks(label: "peer-connected")
                self.onConnected?()
            }
        case .failed:
            Task { @MainActor in self.onConnectionFailed?() }
        default:
            break
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        let kind = rtpReceiver.track?.kind ?? "nil"
        let trackId = rtpReceiver.track?.trackId ?? "nil"
        let enabled = rtpReceiver.track?.isEnabled ?? false
        Log.info(
            "WebRTC remote receiver added: kind=\(kind) trackId=\(trackId) enabled=\(enabled) streams=\(streams.count)",
            category: "Calls"
        )
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove rtpReceiver: RTCRtpReceiver) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    // MARK: - Diagnostics

    /// One-line snapshot of AVAudioSession + RTCAudioSession state. Called at session
    /// init and on peerConnectionState→connected so we can tell whether the audio
    /// unit, category, and route are actually what we think they are when the
    /// call goes silent.
    private static func dumpAudioState(label: String) {
        #if os(iOS)
        let av = AVAudioSession.sharedInstance()
        let rtc = RTCAudioSession.sharedInstance()
        let route = av.currentRoute
        let outputs = route.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        let inputs = route.inputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        Log.info(
            "AUDIO[\(label)] AV{cat=\(av.category.rawValue) mode=\(av.mode.rawValue) sr=\(Int(av.sampleRate)) iobuf=\(String(format: "%.3f", av.ioBufferDuration)) in=[\(inputs)] out=[\(outputs)]} RTC{active=\(rtc.isActive) audioEnabled=\(rtc.isAudioEnabled) useManual=\(rtc.useManualAudio)}",
            category: "Calls"
        )
        #endif
    }

    private func dumpPeerTracks(label: String) {
        let senders = peerConnection.senders.compactMap { sender -> String? in
            guard let track = sender.track else { return nil }
            return "\(track.kind)/enabled=\(track.isEnabled)/id=\(track.trackId)"
        }
        let receivers = peerConnection.receivers.compactMap { receiver -> String? in
            guard let track = receiver.track else { return nil }
            return "\(track.kind)/enabled=\(track.isEnabled)/id=\(track.trackId)"
        }
        Log.info(
            "TRACKS[\(label)] senders=[\(senders.joined(separator: " | "))] receivers=[\(receivers.joined(separator: " | "))]",
            category: "Calls"
        )
    }
}

// MARK: - State Debug Descriptions

private extension RTCIceConnectionState {
    var debugDescription: String {
        switch self {
        case .new:          return "new"
        case .checking:     return "checking"
        case .connected:    return "connected"
        case .completed:    return "completed"
        case .failed:       return "failed"
        case .disconnected: return "disconnected"
        case .closed:       return "closed"
        case .count:        return "count"
        @unknown default:   return "unknown(\(rawValue))"
        }
    }
}

private extension RTCIceGatheringState {
    var debugDescription: String {
        switch self {
        case .new:       return "new"
        case .gathering: return "gathering"
        case .complete:  return "complete"
        @unknown default: return "unknown(\(rawValue))"
        }
    }
}

private extension RTCPeerConnectionState {
    var debugDescription: String {
        switch self {
        case .new:          return "new"
        case .connecting:   return "connecting"
        case .connected:    return "connected"
        case .disconnected: return "disconnected"
        case .failed:       return "failed"
        case .closed:       return "closed"
        @unknown default:   return "unknown(\(rawValue))"
        }
    }
}

#else

final class WebRTCSession: WebRTCSessionProtocol {
    var onLocalIceCandidate: (@Sendable (WebRTCIceCandidate) -> Void)?
    var onConnectionFailed: (@Sendable () -> Void)?
    var onConnected: (@Sendable () -> Void)?
    var onQualityChanged: (@Sendable (CallQuality) -> Void)?

    init(role: WebRTCSessionRole, turn: Shared_Proto_Signaling_V1_TurnCredentials?) throws {
        throw WebRTCSessionError.webRTCLibraryMissing
    }

    func createOffer() async throws -> String { throw WebRTCSessionError.webRTCLibraryMissing }
    func createAnswer() async throws -> String { throw WebRTCSessionError.webRTCLibraryMissing }
    func setRemoteOffer(sdp: String) async throws { throw WebRTCSessionError.webRTCLibraryMissing }
    func setRemoteAnswer(sdp: String) async throws { throw WebRTCSessionError.webRTCLibraryMissing }
    func addRemoteIceCandidate(_ candidate: WebRTCIceCandidate) async throws { throw WebRTCSessionError.webRTCLibraryMissing }
    func setMuted(_ muted: Bool) {}
    func close() {}
}

#endif
