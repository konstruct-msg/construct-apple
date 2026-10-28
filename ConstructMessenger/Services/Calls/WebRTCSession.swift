//
//  WebRTCSession.swift
//  Construct Messenger
//
//  WebRTC PeerConnection wrapper for calls: audio always, and a video transceiver when video
//  calls are on (`CallVideo.swift`).
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
    /// No TURN to relay through, and a call is never direct (`CallIcePlan`).
    case noRelay
}

/// Studio's data channels on the call's own peer connection (`decisions/studio-mode-on-desktop.md`):
/// negotiated — neither side announces them in-band — ordered and reliable. The ids and labels are
/// fixed by `client/studio/studio.proto` in construct-protos; both clients must agree on them, so
/// they are written once, here.
enum StudioChannel: Int32, CaseIterable, Sendable {
    /// `StudioControl` messages.
    case control = 1
    /// `ProgramPacket`s.
    case program = 2

    var label: String {
        switch self {
        case .control: "studio-control"
        case .program: "studio-program"
        }
    }
}

@MainActor
protocol WebRTCSessionProtocol: AnyObject {
    var onLocalIceCandidate: (@Sendable (WebRTCIceCandidate) -> Void)? { get set }
    var onConnectionFailed: (@Sendable () -> Void)? { get set }
    var onConnected: (@Sendable () -> Void)? { get set }
    var onQualityChanged: (@Sendable (CallQuality) -> Void)? { get set }

    func createOffer() async throws -> String
    func restartIce() async throws -> String
    func createAnswer() async throws -> String
    func setRemoteOffer(sdp: String) async throws
    func setRemoteAnswer(sdp: String) async throws
    func addRemoteIceCandidate(_ candidate: WebRTCIceCandidate) async throws
    func setMuted(_ muted: Bool)
    /// The microphone's level as WebRTC measures it at the source, 0…1; nil before it has one.
    func microphoneLevel() async -> Double?
    /// This side has a video sender the camera can feed.
    var canSendVideo: Bool { get }
    /// Feed the camera into the video sender, or take it away. A swap on the sender the call
    /// already negotiated — never an offer.
    func setCameraOn(_ on: Bool, facing: CameraFacing)
    func close()
}

#if canImport(WebRTC)
import AVFoundation
import Synchronization
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
        // Read once, into the environment the factory is built with — so it must precede it.
        RTCPeerConnectionFactory.configureFieldTrials(WebRTCFieldTrials.configured)
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        #if os(macOS)
        // The engine module, observed: the only way this WebRTC build lets a Mac call choose its
        // microphone and output (`CallAudioRouting.swift`). VPIO would pin the system defaults.
        self.factory = RTCPeerConnectionFactory(
            audioDeviceModuleType: .audioEngine,
            bypassVoiceProcessing: false,
            encoderFactory: encoderFactory,
            decoderFactory: decoderFactory,
            audioProcessingModule: nil
        )
        factory.audioDeviceModule.setPlatformVoiceProcessingAllowed(false)
        factory.audioDeviceModule.observer = CallAudioRouter.shared
        #else
        self.factory = RTCPeerConnectionFactory(encoderFactory: encoderFactory, decoderFactory: decoderFactory)
        #endif
    }
}

/// Field trials this app runs WebRTC with.
///
/// `WebRTC-EnableDtlsPqc` puts X25519MLKEM768 first among the DTLS key-exchange groups
/// (`rtc_base/ssl_stream_adapter.cc`, `GetDefaultEphemeralKeyExchangeCipherGroups`); DTLS 1.3 is
/// already the default from M150. The media keys of a call then come from a hybrid exchange, and
/// a recording of the call does not open once X25519 does (`PQC-4`,
/// `decisions/calls-post-quantum-dtls.md`). The DTLS fingerprint that authenticates the exchange
/// travels in the SDP, inside the session.
///
/// Upstream keeps it behind a trial (bug 404763475), so a WebRTC update can rename or drop it
/// without a compile error; `WebRTCFieldTrialsTests` reads the linked binary for the key.
enum WebRTCFieldTrials {
    static let dtlsPqcKey = "WebRTC-EnableDtlsPqc"
    static let configured = "\(dtlsPqcKey)/Enabled/"
}

#if os(macOS)
/// The Mac's microphones and outputs for a call, as CoreAudio lists them — WebRTC's module lists
/// none (`CallAudioRouting.swift`). `nil` selects the system's current default and follows it when
/// it changes. A choice is kept between calls, by device UID; a device that is not connected reads
/// as `nil`.
@MainActor
enum WebRTCAudioDevices {
    struct Device: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
    }

    static var inputs: [Device] { CallAudioRouter.devices().filter(\.hasInput).map(Device.init) }
    static var outputs: [Device] { CallAudioRouter.devices().filter(\.hasOutput).map(Device.init) }

    static var selectedInput: String? {
        get { selected(CallAudioRouter.inputKey, among: inputs) }
        set { select(newValue, CallAudioRouter.inputKey) }
    }

    static var selectedOutput: String? {
        get { selected(CallAudioRouter.outputKey, among: outputs) }
        set { select(newValue, CallAudioRouter.outputKey) }
    }

    private static func selected(_ key: String, among devices: [Device]) -> String? {
        UserDefaults.standard.string(forKey: key).flatMap { uid in devices.contains { $0.id == uid } ? uid : nil }
    }

    private static func select(_ uid: String?, _ key: String) {
        UserDefaults.standard.set(uid, forKey: key)
        CallAudioRouter.shared.reapply(WebRTCFactory.shared.factory.audioDeviceModule)
    }
}

private extension WebRTCAudioDevices.Device {
    init(_ device: CallAudioRoute.Device) {
        self.init(id: device.uid, name: device.name)
    }
}
#endif

/// One-time WebRTC runtime setup. Call `bootstrap()` exactly once at app launch,
/// before any code touches `RTCAudioSession` or `CallKitProvider`. This puts
/// `RTCAudioSession` into manual-audio mode so CallKit (not WebRTC) drives the
/// AVAudioSession activation, and force-initialises the peer-connection factory
/// so its setup never races later activation events.
@MainActor
enum WebRTCRuntime {
    static func bootstrap() {
        #if canImport(WebRTC)
        #if os(iOS)
        let rtc = RTCAudioSession.sharedInstance()
        rtc.useManualAudio = true
        rtc.isAudioEnabled = false
        Log.info(
            "WebRTC bootstrap: useManualAudio=\(rtc.useManualAudio) isAudioEnabled=\(rtc.isAudioEnabled)",
            category: "Calls"
        )
        #endif
        // Always warm the factory (RTCInitializeSSL + peer connection factory).
        // On macOS this is sufficient; WebRTC uses native audio devices.
        _ = WebRTCFactory.shared
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

    /// Video calls on: the caller offers a `sendrecv` video section in every call and the callee
    /// takes up one it is offered. Off, this session is the audio-only one it always was.
    private let videoEnabled: Bool
    private var videoTransceiver: RTCRtpTransceiver?
    private var videoSource: RTCVideoSource?
    /// One capturer — one `AVCaptureSession` — per run of the camera, never restarted.
    ///
    /// WebRTC's capturer swaps the camera of a session it already configured by removing the input
    /// and adding the new one with a hand-made connection (`addInputWithNoConnections:` +
    /// `addConnection:`), and `-[AVCaptureSession addConnection:]` raises on the second time
    /// round — an Objective-C exception on WebRTC's capture queue, which nothing catches. Build 716
    /// died that way on every flip to the back camera (2026-10-05; read from the disassembly at
    /// the crashing frame). The first run of a session has no connection yet, which is why the
    /// camera came on and the call worked. So a new run gets a new capturer, after the old one
    /// has stopped.
    private var capturer: RTCCameraVideoCapturer?
    /// The camera running now, so asking for it again is not a restart.
    private var capturingFacing: CameraFacing?
    /// Whether frames flow, both ways (`VideoFrameCounter`). The capture counter is the
    /// capturer's delegate — which WebRTC holds weakly, so it lives here — and forwards to the
    /// source.
    private var captureCounter: VideoFrameCounter?
    private var captureWatcher: CaptureSessionWatcher?
    private let receiveCounter = VideoFrameCounter(label: "received")
    /// The track the counter is attached through. `receiver.track` makes a new wrapper on every
    /// read, and a wrapper takes its renderers off the track when it goes away — attached through
    /// a temporary, the counter saw nothing while the screen, holding its own, showed the video
    /// ("0 frames — none arrived" over a working picture, 2026-10-05).
    private var countedTrack: RTCVideoTrack?
    /// The camera's track, kept across off/on so the preview and the sender reuse one source.
    private(set) var localVideoTrack: RTCVideoTrack?
    var remoteVideoTrack: RTCVideoTrack? { videoTransceiver?.receiver.track as? RTCVideoTrack }
    var canSendVideo: Bool { videoTransceiver != nil }

    /// WebRTC rejects `addIceCandidate` before the remote description is set, and a
    /// rejected candidate is lost permanently (no retry) — a frequent cause of a call
    /// stuck at `iceConnectionState=checking` when the peer's candidates arrive before
    /// its SDP. We buffer remote candidates until the remote description is applied,
    /// then drain them. Single owner of ICE-candidate ordering (was fragmented across
    /// CallManager's ad-hoc `pendingIceCandidates` which covered only one path).
    private var remoteDescriptionSet = false
    private var pendingRemoteCandidates: [WebRTCIceCandidate] = []

    /// Studio's channels while a studio runs; empty otherwise. A call that never starts Studio
    /// makes none, so its SDP has no `m=application` and is what it always was.
    private var studioChannels: [StudioChannel: RTCDataChannel] = [:]
    /// Fires once, when both of Studio's channels are open — on the side that offered Studio, not
    /// before the answer: until then the other side has not made its channels, and what is sent
    /// on ours is lost.
    var onStudioChannelsOpen: (@Sendable () -> Void)?
    private var studioOpenAnnounced = false
    /// This side made the channels to offer them, and the answer is not in yet.
    private var studioAwaitingAnswer = false
    /// Channels of the studio before, still closing: their ids are not free until they are closed,
    /// and a channel made on such an id is not made (`studioChannelsClosed()`).
    private var closingStudioChannels: [RTCDataChannel] = []
    private var studioClosedWaiters: [CheckedContinuation<Void, Never>] = []
    /// Who receives Studio's messages (`setStudioReceiver`). Called on WebRTC's thread.
    private let studioReceiver = Mutex<StudioReceiver?>(nil)
    /// Host: the screen's send-only section, made with Studio's offer and kept for the rest of the
    /// call, so a second Studio on it adds no section.
    private var studioScreenTransceiver: RTCRtpTransceiver?
    private var studioScreenFeed: StudioScreenFeed?
    /// Guest: the host's screen track, held while it is shown — a renderer is attached through
    /// it, and a wrapper read anew drops its renderers (see `countedTrack`).
    private var heldStudioScreenTrack: RTCVideoTrack?

    convenience init(role: WebRTCSessionRole, turn: Shared_Proto_Signaling_V1_TurnCredentials?, video: Bool,
                     veilOn: Bool) throws {
        guard let plan = CallIcePlan.make(
            turnURLs: turn?.urls, username: turn?.username ?? "", credential: turn?.credential ?? "", veilOn: veilOn
        ) else {
            Log.error("ICE config → none: no TURN credentials — not placing a direct call", category: "Calls")
            throw WebRTCSessionError.noRelay
        }
        Log.info("ICE config → \(plan.servers.flatMap(\.urls)) policy=\(plan.policy)", category: "Calls")
        let config = RTCConfiguration()
        config.iceServers = plan.servers.map {
            RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential)
        }
        switch plan.policy { case .relay: config.iceTransportPolicy = .relay }
        try self.init(role: role, video: video, config: config)
    }

    #if DEBUG
    /// Two sessions in one process, connected over the host's loopback: no servers, every
    /// candidate kind. Tests only — a call is relay-only (`CallIcePlan`), and this path is what a
    /// test needs that a call must never have, so it does not exist in a release build.
    convenience init(loopbackRole role: WebRTCSessionRole, video: Bool) throws {
        let config = RTCConfiguration()
        config.iceTransportPolicy = .all
        try self.init(role: role, video: video, config: config)
    }
    #endif

    /// The ICE part of `config` is the caller's; the rest is set here, the same for every session.
    private init(role: WebRTCSessionRole, video: Bool, config: RTCConfiguration) throws {
        self.role = role
        self.videoEnabled = video

        self.factory = WebRTCFactory.shared.factory

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
        // The callee's transceiver comes from the offer instead (`adoptOfferedVideo`): one added
        // here would not be matched to the offered section — JSEP reuses only transceivers made
        // by addTrack — and the answer would carry two video sections.
        if video, role == .caller {
            let initValue = RTCRtpTransceiverInit()
            initValue.direction = .sendRecv
            initValue.streamIds = ["video"]
            videoTransceiver = peerConnection.addTransceiver(of: .video, init: initValue)
            countReceivedFrames()
            Log.info("WebRTC video transceiver added (sendrecv, no track)", category: "Calls")
        }
        Self.dumpAudioState(label: "session-init role=\(role)")
    }

    func close() {
        closeStudioChannels()
        studioScreenFeed = nil
        heldStudioScreenTrack = nil
        stopCapture()
        if videoTransceiver != nil { Log.info(receiveCounter.summary(), category: "Calls") }
        peerConnection.close()
        // A start waiting for the studio before to close waits no more: there is no call.
        closingStudioChannels.removeAll()
        studioClosedWaiters.forEach { $0.resume() }
        studioClosedWaiters.removeAll()
        // Do NOT deactivate the audio session here. A raw
        // `AVAudioSession.setActive(false)` bypasses RTCAudioSession and desyncs its
        // internal active-state from the real session. With `useManualAudio`, that
        // leaves the shared voice-processing audio unit wedged, so the NEXT call in
        // the same app session is silent until a full relaunch re-runs
        // WebRTCRuntime.bootstrap(). Deactivation is owned by CallAudioController,
        // driven by CallKit's didDeactivate (RTCAudioSession.audioSessionDidDeactivate).
    }

    func setMuted(_ muted: Bool) {
        localAudioTrack?.isEnabled = !muted
    }

    func microphoneLevel() async -> Double? {
        let report = await peerConnection.statistics()
        // `media-source` is the capture side: it keeps measuring while the track is muted, so
        // the level meter shows whether the microphone hears anything at all.
        return report.statistics.values
            .first { $0.type == "media-source" && ($0.values["kind"] as? String) == "audio" }?
            .values["audioLevel"] as? Double
    }

    func setCameraOn(_ on: Bool, facing: CameraFacing) {
        guard let sender = videoTransceiver?.sender else {
            Log.info("Camera \(on ? "on" : "off") ignored — this call has no video sender", category: "Calls")
            return
        }
        guard on else {
            // No track, no frames; the direction stays sendrecv, so turning it back on is the
            // same swap.
            sender.track = nil
            stopCapture()
            return
        }
        let track = localVideoTrack ?? makeLocalVideoTrack()
        if sender.track !== track { sender.track = track }
        guard capturingFacing != facing else { return }
        startCapture(facing: facing)
    }

    private func makeLocalVideoTrack() -> RTCVideoTrack {
        let source = factory.videoSource()
        let track = factory.videoTrack(with: source, trackId: "video0")
        videoSource = source
        localVideoTrack = track
        return track
    }

    private func countReceivedFrames() {
        countedTrack = remoteVideoTrack
        countedTrack?.add(receiveCounter)
    }

    private func stopCapture() {
        capturer?.stopCapture()
        if let captureCounter { Log.info(captureCounter.summary(), category: "Calls") }
        capturer = nil
        capturingFacing = nil
        captureCounter = nil
        captureWatcher = nil
    }

    private func startCapture(facing: CameraFacing) {
        guard let videoSource else { return }
        // A new capturer for this run (see `capturer`). It replaces the old one only once a camera
        // and a format are found; the old one stops first, and only then does this one start.
        let counter = VideoFrameCounter(label: "camera \(facing)", forwardingTo: videoSource)
        let capturer = RTCCameraVideoCapturer(delegate: counter)
        // By position, for now. The design asks for the camera by the direction it faces, which
        // is what keeps "front" the front on a folded iPhone Duo (TODO 104).
        let position: AVCaptureDevice.Position = facing == .front ? .front : .back
        guard let device = RTCCameraVideoCapturer.captureDevices().first(where: { $0.position == position }) else {
            Log.error("No \(facing) camera to capture from", category: "Calls")
            return
        }
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        let preferred = capturer.preferredOutputPixelFormat()
        let candidates = formats.map { format -> CallVideoCapture.Candidate in
            let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return CallVideoCapture.Candidate(
                width: d.width,
                height: d.height,
                rateRanges: format.videoSupportedFrameRateRanges.map { $0.minFrameRate...$0.maxFrameRate },
                isPreferredPixelFormat: CMFormatDescriptionGetMediaSubType(format.formatDescription) == preferred
            )
        }
        guard let (index, fps) = CallVideoCapture.choose(candidates) else {
            Log.error("Camera \(facing): no format can run at \(CallVideoCapture.maxFps) fps or below", category: "Calls")
            return
        }
        let format = formats[index]
        let c = candidates[index]
        let previous = self.capturer
        if let captureCounter { Log.info(captureCounter.summary(), category: "Calls") }
        self.capturer = capturer
        capturingFacing = facing
        captureCounter = counter
        captureWatcher = CaptureSessionWatcher(session: capturer.captureSession, label: "camera \(facing)")
        let start: @MainActor @Sendable () -> Void = { [weak self] in
            // A later flip or a hang-up replaced this run while the old one was stopping.
            guard let self, self.capturer === capturer else { return }
            capturer.startCapture(with: device, format: format, fps: fps)
            Log.info("Camera \(facing) capturing \(c.width)x\(c.height)@\(fps) (ranges \(c.rateRanges))", category: "Calls")
        }
        guard let previous else {
            start()
            return
        }
        previous.stopCapture {
            Task { @MainActor in start() }
        }
    }

    /// Take up the video section of an offer as `sendrecv`, so the camera can be turned on later
    /// without renegotiating. Without it the transceiver the offer created stays `recvonly` and
    /// this side could watch but never send. An offer with no video section (an audio-only
    /// client) leaves `canSendVideo` false.
    private func adoptOfferedVideo() {
        // Not Studio's screen section: that one is the host's DAW, sent only, and taken up as a
        // camera this side would answer it sendrecv and show the host's windows as the face.
        let screenMid = peerConnection.remoteDescription.flatMap { StudioOffer.screenMid(sdp: $0.sdp) }
        guard videoEnabled, videoTransceiver == nil,
              let offered = peerConnection.transceivers.first(where: { $0.mediaType == .video && $0.mid != screenMid })
        else { return }
        var error: NSError?
        offered.setDirection(.sendRecv, error: &error)
        if let error {
            Log.error("Offered video section not taken up: \(error)", category: "Calls")
            return
        }
        videoTransceiver = offered
        countReceivedFrames()
        Log.info("WebRTC offered video section taken up (sendrecv)", category: "Calls")
    }

    func createOffer() async throws -> String {
        try await createOffer(iceRestart: false)
    }

    func restartIce() async throws -> String {
        try await createOffer(iceRestart: true)
    }

    private func createOffer(iceRestart: Bool) async throws -> String {
        let offerConstraints = RTCMediaConstraints(
            // No `OfferToReceiveVideo`: under Unified Plan a "false" there takes the receive
            // direction off the video transceiver, and the peer's camera would never arrive.
            mandatoryConstraints: [
                "OfferToReceiveAudio": "true",
                "IceRestart": iceRestart ? "true" : "false"
            ],
            optionalConstraints: nil
        )
        let offer = try await createSessionDescription { completion in
            self.peerConnection.offer(for: offerConstraints, completionHandler: completion)
        }
        try await setLocalDescription(offer)
        if iceRestart {
            Log.info("WebRTC ICE restart offer created", category: "Calls")
        }
        return offer.sdp
    }

    func createAnswer() async throws -> String {
        let answerConstraints = RTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveAudio": "true"],
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
        adoptOfferedVideo()
        await onRemoteDescriptionSet()
    }

    func setRemoteAnswer(sdp: String) async throws {
        let desc = RTCSessionDescription(type: .answer, sdp: sdp)
        try await setRemoteDescription(desc)
        if studioAwaitingAnswer {
            studioAwaitingAnswer = false
            studioChannelChanged()
        }
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

    // MARK: - Studio

    /// Make Studio's channels on this side. Both sides make them, since they are negotiated: the
    /// side that starts Studio then makes an offer, which carries the `m=application` section, and
    /// the other side makes them before it answers. Making them again is a no-op.
    func openStudioChannels() throws {
        for channel in StudioChannel.allCases where studioChannels[channel] == nil {
            let config = RTCDataChannelConfiguration()
            config.isNegotiated = true
            config.channelId = channel.rawValue
            config.isOrdered = true
            guard let dataChannel = peerConnection.dataChannel(forLabel: channel.label, configuration: config) else {
                closeStudioChannels()
                throw WebRTCSessionError.invalidState("Studio channel \(channel.label) not created")
            }
            dataChannel.delegate = self
            studioChannels[channel] = dataChannel
        }
        studioAwaitingAnswer = peerConnection.signalingState == .stable
        Log.info("Studio channels made (negotiated, ids \(StudioChannel.allCases.map(\.rawValue)))", category: "Calls")
        // On a call whose data section is already negotiated (a second studio), a channel can be
        // open as it is made, and no change of state follows to say so.
        studioChannelChanged()
    }

    /// Returns once the channels of the studio before are closed; at once when there are none.
    func studioChannelsClosed() async {
        closingStudioChannels.removeAll { $0.readyState == .closed }
        guard !closingStudioChannels.isEmpty else { return }
        Log.info("Studio: waiting for the channels of the studio before to close", category: "Calls")
        await withCheckedContinuation { studioClosedWaiters.append($0) }
    }

    var studioChannelsOpen: Bool {
        StudioChannel.allCases.allSatisfy { studioChannels[$0]?.readyState == .open }
    }

    /// Queue `data` on `channel`. False when the channel is not open, or WebRTC refused it.
    @discardableResult
    func sendStudio(_ data: Data, on channel: StudioChannel) -> Bool {
        guard let dataChannel = studioChannels[channel], dataChannel.readyState == .open else { return false }
        return dataChannel.sendData(RTCDataBuffer(data: data, isBinary: true))
    }

    /// A send on `channel` usable from any thread — the capture's, where the program is produced.
    /// `RTCDataChannel` is safe to send on from any thread; it is held, not the session. Nil when
    /// the channel was not made.
    func studioSender(on channel: StudioChannel) -> (@Sendable (Data) -> Bool)? {
        guard let dataChannel = studioChannels[channel] else { return nil }
        nonisolated(unsafe) let held = dataChannel
        return { data in
            held.readyState == .open && held.sendData(RTCDataBuffer(data: data, isBinary: true))
        }
    }

    /// Bytes queued on `channel` and not yet handed to the network — the sender's measure of a
    /// path that cannot keep up.
    func studioBufferedAmount(on channel: StudioChannel) -> UInt64 {
        studioChannels[channel]?.bufferedAmount ?? 0
    }

    /// Who receives Studio's messages, and on which channel each came. Called on WebRTC's
    /// signalling thread, never the main actor: the program goes into a ring buffer from there
    /// (`StudioPlayout`), and a hop per packet would put the main thread on the audio path.
    nonisolated func setStudioReceiver(_ receiver: (@Sendable (StudioChannel, Data) -> Void)?) {
        studioReceiver.withLock { $0 = receiver.map(StudioReceiver.init) }
    }

    func closeStudioChannels() {
        guard !studioChannels.isEmpty else { return }
        for dataChannel in studioChannels.values {
            dataChannel.close()
            // Kept with this side as delegate until closed: its messages are dropped (it is not
            // open), its closing is watched.
            closingStudioChannels.append(dataChannel)
        }
        studioChannels.removeAll()
        studioOpenAnnounced = false
        studioAwaitingAnswer = false
        Log.info("Studio channels closed", category: "Calls")
    }

    /// Host: the screen's section, made on the first call — before Studio's offer, which then
    /// carries it — and the feed the capture writes frames into. Send-only: the guest sends no
    /// screen back.
    func addStudioScreen() -> StudioScreenFeed {
        if let studioScreenFeed { return studioScreenFeed }
        let source = factory.videoSource(forScreenCast: true)
        let track = factory.videoTrack(with: source, trackId: StudioScreen.trackId)
        let initValue = RTCRtpTransceiverInit()
        initValue.direction = .sendOnly
        initValue.streamIds = [StudioScreen.streamId]
        let encoding = RTCRtpEncodingParameters()
        encoding.maxBitrateBps = NSNumber(value: StudioScreen.maxBitrateBps)
        encoding.maxFramerate = NSNumber(value: StudioScreen.maxFps)
        initValue.sendEncodings = [encoding]
        let transceiver = peerConnection.addTransceiver(with: track, init: initValue)
        if let sender = transceiver?.sender {
            // Frames go before pixels: a DAW's text and meters have to stay readable.
            let parameters = sender.parameters
            parameters.degradationPreference = NSNumber(value: RTCDegradationPreference.maintainResolution.rawValue)
            sender.parameters = parameters
        }
        studioScreenTransceiver = transceiver
        let feed = StudioScreenFeed(source: source)
        studioScreenFeed = feed
        Log.info("Studio screen section added (send-only, ≤\(StudioScreen.maxBitrateBps / 1_000_000) Mbit/s, maintain resolution)", category: "Calls")
        return feed
    }

    /// Guest: the host's screen track, from the section the offer names as the screen. Nil when the
    /// offer has none. Held, so a renderer attached to it stays attached.
    func studioScreenTrack() -> RTCVideoTrack? {
        if let heldStudioScreenTrack { return heldStudioScreenTrack }
        guard let sdp = peerConnection.remoteDescription?.sdp, let mid = StudioOffer.screenMid(sdp: sdp),
              let transceiver = peerConnection.transceivers.first(where: { $0.mid == mid }),
              let track = transceiver.receiver.track as? RTCVideoTrack
        else { return nil }
        heldStudioScreenTrack = track
        return track
    }

    /// Guest: the screen is no longer shown; the track is let go.
    func releaseStudioScreenTrack() {
        heldStudioScreenTrack = nil
    }

    private func studioChannelChanged() {
        closingStudioChannels.removeAll { $0.readyState == .closed }
        if closingStudioChannels.isEmpty, !studioClosedWaiters.isEmpty {
            let waiters = studioClosedWaiters
            studioClosedWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        guard !studioOpenAnnounced, !studioAwaitingAnswer, studioChannelsOpen else { return }
        studioOpenAnnounced = true
        Log.info("Studio channels open", category: "Calls")
        onStudioChannelsOpen?()
    }

    // MARK: - Helpers

    private func createSessionDescription(
        _ build: @escaping (@Sendable @escaping (RTCSessionDescription?, Error?) -> Void) -> Void
    ) async throws -> RTCSessionDescription {
        // The description crosses from WebRTC's signalling thread as its two plain fields;
        // `RTCSessionDescription` is not Sendable.
        let (type, sdp) = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(RTCSdpType, String), Error>) in
            build { sdp, error in
                if let error { cont.resume(throwing: error); return }
                guard let sdp else {
                    cont.resume(throwing: WebRTCSessionError.invalidState("Missing SDP"))
                    return
                }
                cont.resume(returning: (sdp.type, sdp.sdp))
            }
        }
        return RTCSessionDescription(type: type, sdp: sdp)
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

/// The receiver, in a struct of its own inside the lock. A bare closure as the `Mutex`'s generic
/// value is reabstracted on every read through `withLock`'s `inout` and written back wrapped in one
/// more thunk: the closure grew a layer per message until the signalling thread's stack ran out
/// (Desktop 0.3.18, 2026-10-28, ~5,600 packets in). A struct's field keeps the closure as it is.
private struct StudioReceiver: Sendable {
    let receive: @Sendable (StudioChannel, Data) -> Void
}

extension WebRTCSession: RTCDataChannelDelegate {
    nonisolated func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        Log.info("Studio channel \(dataChannel.label) (id \(dataChannel.channelId)) → state \(dataChannel.readyState.rawValue)", category: "Calls")
        Task { @MainActor in self.studioChannelChanged() }
    }

    nonisolated func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard dataChannel.readyState == .open, let channel = StudioChannel(rawValue: dataChannel.channelId) else { return }
        let data = buffer.data
        studioReceiver.withLock { $0 }?.receive(channel, data)
    }
}

/// Where the host's capture writes the screen's frames, from its own thread: `RTCVideoSource`
/// takes frames from any thread, and nothing else is held.
final class StudioScreenFeed: @unchecked Sendable {
    private let source: RTCVideoSource
    private let capturer: RTCVideoCapturer

    init(source: RTCVideoSource) {
        self.source = source
        self.capturer = RTCVideoCapturer(delegate: source)
    }

    /// One frame of the screen; `timeNs` on the host's clock.
    func deliver(_ pixelBuffer: CVPixelBuffer, timeNs: Int64) {
        let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: pixelBuffer), rotation: ._0, timeStampNs: timeNs)
        source.capturer(capturer, didCapture: frame)
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

#if !os(iOS)
@MainActor
enum WebRTCRuntime {
    static func bootstrap() {}
}
#endif

final class WebRTCSession: WebRTCSessionProtocol {
    var onLocalIceCandidate: (@Sendable (WebRTCIceCandidate) -> Void)?
    var onConnectionFailed: (@Sendable () -> Void)?
    var onConnected: (@Sendable () -> Void)?
    var onQualityChanged: (@Sendable (CallQuality) -> Void)?

    init(role: WebRTCSessionRole, turn: Shared_Proto_Signaling_V1_TurnCredentials?, video: Bool,
         veilOn: Bool) throws {
        throw WebRTCSessionError.webRTCLibraryMissing
    }

    var canSendVideo: Bool { false }
    func setCameraOn(_ on: Bool, facing: CameraFacing) {}

    func createOffer() async throws -> String { throw WebRTCSessionError.webRTCLibraryMissing }
    func restartIce() async throws -> String { throw WebRTCSessionError.webRTCLibraryMissing }
    func createAnswer() async throws -> String { throw WebRTCSessionError.webRTCLibraryMissing }
    func setRemoteOffer(sdp: String) async throws { throw WebRTCSessionError.webRTCLibraryMissing }
    func setRemoteAnswer(sdp: String) async throws { throw WebRTCSessionError.webRTCLibraryMissing }
    func addRemoteIceCandidate(_ candidate: WebRTCIceCandidate) async throws { throw WebRTCSessionError.webRTCLibraryMissing }
    func setMuted(_ muted: Bool) {}
    func microphoneLevel() async -> Double? { nil }
    func close() {}
}

#endif
