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

    func createOffer() async throws -> String
    func createAnswer() async throws -> String
    func setRemoteOffer(sdp: String) async throws
    func setRemoteAnswer(sdp: String) async throws
    func addRemoteIceCandidate(_ candidate: WebRTCIceCandidate) async throws
    func setMuted(_ muted: Bool)
    func setSpeaker(_ enabled: Bool)
    func close()
}

#if os(iOS) && canImport(WebRTC)
import AVFoundation
import WebRTC

@MainActor
private final class WebRTCFactory {
    static let shared = WebRTCFactory()
    let factory: RTCPeerConnectionFactory

    private init() {
        RTCInitializeSSL()
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        self.factory = RTCPeerConnectionFactory(encoderFactory: encoderFactory, decoderFactory: decoderFactory)
    }
}

@MainActor
final class WebRTCSession: NSObject, WebRTCSessionProtocol {
    var onLocalIceCandidate: (@Sendable (WebRTCIceCandidate) -> Void)?
    var onConnectionFailed: (@Sendable () -> Void)?

    private let role: WebRTCSessionRole
    private let factory: RTCPeerConnectionFactory
    private let peerConnection: RTCPeerConnection

    private var localAudioTrack: RTCAudioTrack?

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

        try Self.configureAudioSession()
        self.localAudioTrack = Self.makeLocalAudioTrack(factory: factory)
        if let track = localAudioTrack {
            _ = peerConnection.add(track, streamIds: ["audio"])
        }
    }

    func close() {
        peerConnection.close()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    func setMuted(_ muted: Bool) {
        localAudioTrack?.isEnabled = !muted
    }

    func setSpeaker(_ enabled: Bool) {
        let session = AVAudioSession.sharedInstance()
        try? session.overrideOutputAudioPort(enabled ? .speaker : .none)
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
    }

    func setRemoteAnswer(sdp: String) async throws {
        let desc = RTCSessionDescription(type: .answer, sdp: sdp)
        try await setRemoteDescription(desc)
    }

    func addRemoteIceCandidate(_ candidate: WebRTCIceCandidate) async throws {
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
            // Server-provided TURN credentials — primary server (AMS).
            // TURN servers also handle STUN binding requests, so no separate STUN needed.
            servers.append(RTCIceServer(urlStrings: turn.urls, username: turn.username, credential: turn.credential))
            // Secondary TURN: Moscow coturn for RU users (lower latency relay path).
            // Uses the same credentials — coturn shared-secret is server-wide, not per-host.
            servers.append(RTCIceServer(
                urlStrings: [ICEConfig.mskTURNAddress],
                username: turn.username,
                credential: turn.credential
            ))
        } else {
            // TURN unavailable (credentials fetch failed). Fall back to own STUN servers
            // for NAT traversal without relay capability. Never use public STUN servers
            // (privacy: ICE activity would reveal call metadata to Google/Cloudflare).
            servers.append(RTCIceServer(urlStrings: [ICEConfig.mskSTUNAddress, "stun:ams.konstruct.cc:3478"]))
        }
        return servers
    }

    private static func makeLocalAudioTrack(factory: RTCPeerConnectionFactory) -> RTCAudioTrack {
        let source = factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        return factory.audioTrack(with: source, trackId: "audio0")
    }

    private static func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try? session.setPreferredSampleRate(NetworkTiming.Calls.audioPreferredSampleRateHz)
        try? session.setPreferredIOBufferDuration(NetworkTiming.Calls.audioPreferredIOBufferDuration)
        // Do NOT call setActive(true) here — CallKit manages the audio session lifecycle.
        // Activation happens via CXProviderDelegate.provider(_:didActivate:audioSession:).
        // Calling setActive() here races with CallKit's own activation and throws
        // NSOSStatusErrorDomain 561017449 when a previous call's session is still tearing down.
    }
}

extension WebRTCSession: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let c = WebRTCIceCandidate(
            sdp: candidate.sdp,
            sdpMid: candidate.sdpMid ?? "",
            sdpMLineIndex: candidate.sdpMLineIndex
        )
        Task { @MainActor in
            self.onLocalIceCandidate?(c)
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        Log.debug("📞 WebRTC signalingState → \(stateChanged.rawValue)", category: "Calls")
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        Log.info("📞 WebRTC iceConnectionState → \(newState.debugDescription)", category: "Calls")
        // `.disconnected` is transient on mobile (brief network hiccup, device lock, switch
        // between WiFi/cellular). Triggering teardown immediately cuts live calls unnecessarily.
        // Only `.failed` means ICE has exhausted all candidates and the call cannot continue.
        if newState == .failed {
            Task { @MainActor in
                self.onConnectionFailed?()
            }
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        Log.debug("📞 WebRTC iceGatheringState → \(newState.debugDescription)", category: "Calls")
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        Log.info("📞 WebRTC peerConnectionState → \(newState.debugDescription)", category: "Calls")
        if newState == .failed {
            Task { @MainActor in
                self.onConnectionFailed?()
            }
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove rtpReceiver: RTCRtpReceiver) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
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

    init(role: WebRTCSessionRole, turn: Shared_Proto_Signaling_V1_TurnCredentials?) throws {
        throw WebRTCSessionError.webRTCLibraryMissing
    }

    func createOffer() async throws -> String { throw WebRTCSessionError.webRTCLibraryMissing }
    func createAnswer() async throws -> String { throw WebRTCSessionError.webRTCLibraryMissing }
    func setRemoteOffer(sdp: String) async throws { throw WebRTCSessionError.webRTCLibraryMissing }
    func setRemoteAnswer(sdp: String) async throws { throw WebRTCSessionError.webRTCLibraryMissing }
    func addRemoteIceCandidate(_ candidate: WebRTCIceCandidate) async throws { throw WebRTCSessionError.webRTCLibraryMissing }
    func setMuted(_ muted: Bool) {}
    func setSpeaker(_ enabled: Bool) {}
    func close() {}
}

#endif
