import Foundation
import WebRTC

/// One end of the studio link: an `RTCPeerConnection` with the factory set up as the app's calls
/// set it up (`WebRTCFieldTrials` — post-quantum DTLS first), carrying one negotiated, ordered,
/// reliable data channel. No media tracks: the spike is about the program audio path alone.
///
/// Signalling is not ICE-trickled: each side waits for gathering to finish and sends one complete
/// SDP, so the exchange is one message each way over whatever carries it.
public final class StudioPeer: NSObject {
    public enum Role { case offerer, answerer }

    public static let fieldTrials = "WebRTC-EnableDtlsPqc/Enabled/"

    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        RTCPeerConnectionFactory.configureFieldTrials(fieldTrials)
        return RTCPeerConnectionFactory()
    }()

    public let role: Role
    private let pc: RTCPeerConnection
    private let channel: RTCDataChannel
    private var gathered: CheckedContinuation<Void, Never>?
    private var gatheringComplete = false
    private let lock = NSLock()

    public var onOpen: (() -> Void)?
    public var onClose: (() -> Void)?
    public var onMessage: ((Data) -> Void)?
    public var onLog: ((String) -> Void)?

    /// `stunServers` empty: host candidates only (loopback, LAN).
    public init(role: Role, stunServers: [String] = []) {
        self.role = role
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        config.iceServers = stunServers.isEmpty ? [] : [RTCIceServer(urlStrings: stunServers)]
        config.continualGatheringPolicy = .gatherOnce
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil,
                                              optionalConstraints: ["DtlsSrtpKeyAgreement": "true"])
        pc = Self.factory.peerConnection(with: config, constraints: constraints, delegate: nil)!

        // Negotiated on both sides with a fixed id: no in-band DATA_CHANNEL_OPEN, no didOpen race.
        let dc = RTCDataChannelConfiguration()
        dc.isOrdered = true
        dc.isNegotiated = true
        dc.channelId = 0
        channel = pc.dataChannel(forLabel: "studio-program", configuration: dc)!
        super.init()
        pc.delegate = self
        channel.delegate = self
    }

    /// Offerer: create the offer and return the complete SDP once gathering is done.
    public func makeOffer() async throws -> String {
        let offer = try await pc.offer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        try await pc.setLocalDescription(offer)
        await waitForGathering()
        return pc.localDescription!.sdp
    }

    /// Answerer: take the offer, return the complete answer SDP.
    public func answer(offer: String) async throws -> String {
        try await pc.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: offer))
        let answer = try await pc.answer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        try await pc.setLocalDescription(answer)
        await waitForGathering()
        return pc.localDescription!.sdp
    }

    /// Offerer: take the answer.
    public func accept(answer: String) async throws {
        try await pc.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: answer))
    }

    @discardableResult
    public func send(_ data: Data) -> Bool {
        channel.sendData(RTCDataBuffer(data: data, isBinary: true))
    }

    /// Bytes queued in the SCTP send buffer — the backpressure signal.
    public var bufferedAmount: UInt64 { channel.bufferedAmount }

    public var isOpen: Bool { channel.readyState == .open }

    /// The DTLS parameters the transport actually negotiated, from `getStats`.
    public func transportSummary() async -> String {
        await withCheckedContinuation { cont in
            pc.statistics { report in
                let transports = report.statistics.values.filter { $0.type == "transport" }
                let lines = transports.map { s -> String in
                    let v = s.values
                    return ["tlsVersion", "dtlsCipher", "dtlsRole", "srtpCipher", "tlsGroup", "selectedCandidatePairId"]
                        .compactMap { k in v[k].map { "\(k)=\($0)" } }.joined(separator: " ")
                }
                let pairs = report.statistics.values.filter { $0.type == "candidate-pair" && ($0.values["nominated"] as? NSNumber)?.boolValue == true }
                let rtt = pairs.compactMap { $0.values["currentRoundTripTime"] }.map { "rtt=\($0)s" }
                cont.resume(returning: (lines + rtt).joined(separator: "; "))
            }
        }
    }

    public func close() {
        channel.close()
        pc.close()
    }

    private func waitForGathering() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if gatheringComplete {
                lock.unlock()
                cont.resume()
            } else {
                gathered = cont
                lock.unlock()
            }
        }
    }
}

extension StudioPeer: RTCPeerConnectionDelegate {
    public func peerConnection(_ pc: RTCPeerConnection, didChange state: RTCIceGatheringState) {
        guard state == .complete else { return }
        lock.lock()
        gatheringComplete = true
        let cont = gathered
        gathered = nil
        lock.unlock()
        cont?.resume()
    }

    public func peerConnection(_ pc: RTCPeerConnection, didChange state: RTCPeerConnectionState) {
        onLog?("peer connection: \(state.rawValue)")
    }

    public func peerConnection(_ pc: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    public func peerConnection(_ pc: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    public func peerConnection(_ pc: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    public func peerConnectionShouldNegotiate(_ pc: RTCPeerConnection) {}
    public func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    public func peerConnection(_ pc: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    public func peerConnection(_ pc: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    public func peerConnection(_ pc: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

extension StudioPeer: RTCDataChannelDelegate {
    public func dataChannelDidChangeState(_ dc: RTCDataChannel) {
        switch dc.readyState {
        case .open: onOpen?()
        case .closed: onClose?()
        default: break
        }
    }

    public func dataChannel(_ dc: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        onMessage?(buffer.data)
    }
}
