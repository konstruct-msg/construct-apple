// swiftlint:disable file_length
//
//  CallManager.swift
//  Construct Messenger
//
//  Calls: signaling, WebRTC session, call history. iOS adds PushKit + CallKit; Konstruct Desktop
//  uses the same manager without them (`CallsFeature`).
//

import Foundation
import AVFoundation
import CoreData
import GRPCCore
import SwiftProtobuf
#if os(iOS)
import UIKit
#endif

@MainActor
@Observable
final class CallManager: CallUIManaging {
    static let shared = CallManager()

    enum CallEndSource: String {
        case inAppEndButton = "ui_end_button"
        case inAppDeclineButton = "ui_decline_button"
        case callKit = "callkit"
        case programmatic = "programmatic"
    }

    // `state`, `lastError`, `callQuality` and `video` were `private(set)` until the split into
    // `CallManager+*.swift` (2026-10-20, TODO 183): Swift's `private(set)` is per file, and the
    // extensions set them. Written only by `CallManager` and its extensions — views read them.
    var state: CallState = .idle
    var lastError: String? = nil
    /// Coarse network health for the active call. `good` is the normal
    /// state; flips to `reconnecting` while WebRTC sees `iceConnectionState
    /// .disconnected` (transient network blip). Resets to `good` on every
    /// new call so a stale value from a previous call never leaks into the UI.
    var callQuality: CallQuality = .good
    /// The camera on both sides of the current call. Fresh for every call, like `callQuality`.
    var video = CallVideoState()

    func clearLastError() { lastError = nil }

    /// True while an incoming call is up and we do not yet hold a negotiable SDP.
    /// Silent-push handling consults this so a zombie "connected" MessageStream cannot
    /// hide the offer that CallKit is already ringing for (7CDE9769).
    var needsOfferPull: Bool {
        guard let active, case .incoming = active.session.direction else { return false }
        return incomingCallFetchDisposition(hasUsableRemoteOffer: active.usableRemoteOfferSdp != nil) == .pullMissed
    }

    var active: ActiveCall?

    /// The call Studio is on, for the call window; `ActiveCall` is not observed. Read through
    /// `studioIsOn`, so a call that ended with Studio on does not leave it showing.
    var studioCallId: String?

    var studioIsOn: Bool {
        guard let studioCallId else { return false }
        return studioCallId == active?.session.id
    }

    /// What went wrong with Studio on this side of the current call, for the call window; kept
    /// after the studio ends, so the reason stays on screen. Read through `studioProblem`.
    var studioProblemInCall: (callId: String, problem: StudioProblem)?

    var studioProblem: StudioProblem? {
        guard let studioProblemInCall, studioProblemInCall.callId == active?.session.id else { return nil }
        return studioProblemInCall.problem
    }

    /// Serializes outgoing E2EE call-signal RPC sends so they reach the server in the
    /// order the orchestrator encrypted them (see `sendCallSignalProto`). Without this,
    /// rapid transitions (offer → candidates → hangup) spawn independent send Tasks that
    /// can race and deliver out of order (e.g. hangup before offer). Reset to `nil` at each
    /// call boundary (`begin`/`endActiveCall`) so it orders signals only within one call —
    /// a stalled send from a previous call must never block the next call's signaling.
    var callSignalSendChain: Task<Void, Never>?

    /// Short-lived cache of recipient identity keys during active calls.
    /// Avoids repeated bundle fetches for multiple signals (offer, ICE candidates, etc.).
    var identityKeyCache: [String: Data] = [:]

    /// The call's state: the core's call machine (`CallManager+Machine.swift`). Changed only
    /// through `withMachine`.
    let machine = CallMachine()
    /// The machine's call as of its last change, for views and logs.
    var machineCall: CallSnapshot?
    /// The one timer, at `machine.nextDeadline()`.
    var deadlineTask: Task<Void, Never>?

    /// Refuse a second call while one is in progress: hangup BUSY to its caller over E2EE. The
    /// machine has remembered the id as ended, so the push and the offer — whichever comes second —
    /// find it ended instead of ringing. The call in progress is not touched. Not over the
    /// signaling stream: that stream belongs to the call in progress; the caller's client tells
    /// the server when it ends.
    func declineAsBusy(callId: String, callerUserId: String, callerDevice: String? = nil) {
        var sig = Shared_Proto_Signaling_V1_WebRTCSignal()
        sig.callID = callId
        sig.senderDeviceID = Self.currentDeviceId()
        sig.timestamp = Self.nowMs()
        sig.signal = .hangup(Self.makeCallHangup(deviceId: Self.currentDeviceId(), timestampMs: Self.nowMs(), reason: .busy))
        let result = sendCallSignalProto(sig, to: callerUserId, devices: callerDevice.map { [$0] })
        Log.info("Busy hangup for callId=\(callId.prefix(8))… to \(callerUserId.prefix(8))… (\(result))", category: "Calls")
    }

    /// Pull the message backlog so an SDP that is already on the server can land
    /// without waiting for a zombie MessageStream to time out (7CDE9769: 15 s).
    /// Coalesced with silent-push fetches; a no-op if the offer is already in hand.
    func pullMissedCallSignalsIfNeeded() {
        guard incomingCallFetchDisposition(hasUsableRemoteOffer: active?.usableRemoteOfferSdp != nil) == .pullMissed else {
            return
        }
        let arrivedAt = Date()
        Log.info("Pulling missed messages for incoming call without SDP", category: "Calls")
        Task { await BackgroundFetchManager.shared.fetchPendingMessagesForSilentPush(pushArrivedAt: arrivedAt) }
    }


    final class ActiveCall {
        let session: CallSession
        var stream: SignalStream?
        var turn: Shared_Proto_Signaling_V1_TurnCredentials?
        var webrtc: (any WebRTCSessionProtocol)?
        /// The studio on this call, host or guest (`CallManager+Studio.swift`).
        var studio: StudioRun?
        /// Asked for with the video button: the camera comes on as soon as there is a sender.
        var startsWithCamera = false
        /// Answered with "without video": a video offer that arrives after the answer does not
        /// turn the camera on.
        var answeredWithoutCamera = false
        var keepaliveTask: Task<Void, Never>?
        var receiveTask: Task<Void, Never>?
        var acceptTask: Task<Void, Never>?
        /// SDP offer received via MessagingService before the user answered.
        ///
        /// Read it through `usableRemoteOfferSdp`, never directly: the raw field answers "is there
        /// an offer" differently depending on whether the asker tests `!= nil` or `!isEmpty`, and
        /// that disagreement is what killed the 2026-08-17 call (see `offerSdpIsUsable`).
        var pendingRemoteOfferSdp: String? = nil
        /// The stored offer when it is negotiable, `nil` otherwise. The single reading of
        /// "we are holding an offer" — used by `answer()` and by both ICE-buffering paths, which
        /// must agree or candidates queue against an offer no one will ever apply.
        var usableRemoteOfferSdp: String? {
            offerSdpIsUsable(pendingRemoteOfferSdp) ? pendingRemoteOfferSdp : nil
        }
        /// ICE candidates received via E2EE before the remote offer was applied.
        /// Applied automatically when pendingRemoteOfferSdp is consumed in answer().
        var pendingIceCandidates: [WebRTCIceCandidate] = []
        /// Whether CallKit successfully registered this call (requestStartCall succeeded).
        /// Only true calls should have reportCallEnded called on them.
        var callKitRegistered: Bool = false
        /// Times the server did not accept a newly opened stream in time (`openStreamIfNeeded`).
        /// This platform's own budget: a stream refused this way does not end the call — it goes
        /// on over E2EE — unlike one that closed (`CallMachine.streamClosed`). Capped at the
        /// core's `maxStreamRetries`.
        var acceptTimeouts: UInt32 = 0
        /// ICE candidates waiting to be flushed as a batch to stay under 10/sec signal rate limit.
        /// Our candidates waiting for the debounce, in the clear: each is encrypted per target
        /// device at the flush, because which devices those are can change before it runs.
        var pendingOutgoingIce: [WebRTCIceCandidate] = []
        /// Task that fires after a short debounce to flush pendingOutgoingIce.
        var iceFlushTask: Task<Void, Never>? = nil

        init(session: CallSession) {
            self.session = session
        }

        @MainActor
        func close() {
            keepaliveTask?.cancel()
            receiveTask?.cancel()
            acceptTask?.cancel()
            iceFlushTask?.cancel()
            iceFlushTask = nil
            studio?.stop()
            studio = nil
            webrtc?.close()
            webrtc = nil
            stream?.close()
            stream = nil
        }
    }

    private init() {
        #if os(iOS)
        // SwiftUI Previews run under XOJIT, which cannot register CallKit's
        // @objc class chain (`CXProvider`, `PKPushRegistry`) — touching
        // `CallKitProvider.shared` / `VoIPPushManager.shared` here aborts the
        // preview with `_objc_fatal: Attempt to use unknown class …`. CallKit
        // and PushKit are also meaningless under previews (no real device,
        // no push infra), so skip wiring entirely.
        if PreviewDetector.isRunningInPreview {
            return
        }
        VoIPPushManager.shared.onIncomingPush = { [weak self] payload, reportedUUID in
            self?.handleIncomingPush(payload, reportedUUID: reportedUUID)
        }
        CallKitProvider.shared.onAnswer = { [weak self] uuid in
            Task { @MainActor in self?.answer(callUUID: uuid) }
        }
        CallKitProvider.shared.onEnd = { [weak self] uuid in
            Task { @MainActor in self?.end(callUUID: uuid, source: .callKit) }
        }
        // Audio session lifecycle is owned by CallAudioController; CallKit's
        // didActivate/didDeactivate forward to it directly (see CallKitProvider).
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.setInBackground(true) }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.setInBackground(false) }
        }
        #endif
    }



    // MARK: - Convenience UI actions

    /// End the active call (for in-app end-call button).
    func endCall() {
        guard let active else { return }
        end(callUUID: active.session.uuid, source: .inAppEndButton)
    }

    /// Dismiss the post-call `.ended` overlay immediately, before the auto-clear
    /// timer (`endedAutoClearDelay`) fires. The in-call full-screen cover is
    /// driven by call state; transitioning back to `.idle` here lets it dismiss
    /// on tap instead of leaving the user staring at a phantom screen.
    func dismissEndedCall() {
        if case .ended = state { state = .idle }
    }

    /// Answer the current incoming call from the app's own incoming screen. Through CallKit when
    /// it rings there, so CallKit knows the call is answered and activates the audio session —
    /// answering past it leaves the call silent. Without the camera, a video offer arriving later
    /// does not turn it on (`takeUpVideoCall`).
    func answerIncomingCall(withCamera: Bool) {
        guard let active, case .incoming = state else { return }
        if !withCamera {
            active.answeredWithoutCamera = true
            active.startsWithCamera = false
        }
        #if os(iOS)
        if active.callKitRegistered {
            let uuid = active.session.uuid
            Task { @MainActor [weak self] in
                guard await !CallKitProvider.shared.requestAnswerCall(uuid: uuid) else { return }
                self?.answer(callUUID: uuid)
            }
            return
        }
        #endif
        answer(callUUID: active.session.uuid)
    }

    /// Decline the current incoming call from in-app UI.
    func declineIncomingCall() {
        guard let active, case .incoming = state else { return }
        end(callUUID: active.session.uuid, source: .inAppDeclineButton)
    }

    /// When the current call was answered — the one value the call screen and the call history
    /// both count the call's time from.
    var answeredAt: Date? { machineCall?.answeredAtMs.map { Date(timeIntervalSince1970: Double($0) / 1000) } }

    /// Mute or unmute the local microphone.
    func setMuted(_ muted: Bool) {
        active?.webrtc?.setMuted(muted)
    }

    /// The live call's microphone level, 0…1, for a level meter; nil without a call.
    func microphoneLevel() async -> Double? {
        await active?.webrtc?.microphoneLevel()
    }

    // MARK: - Camera

    /// Turn the camera on or off. Asks for camera access the first time; a refusal leaves the
    /// camera off and says why.
    func setCameraOn(_ on: Bool) {
        guard CallsFeature.isVideoEnabled, active != nil else { return }
        if on {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                break
            case .notDetermined:
                Task { @MainActor [weak self] in
                    let granted = await AVCaptureDevice.requestAccess(for: .video)
                    if granted { self?.setCameraOn(true) } else { self?.lastError = NSLocalizedString("call_error_camera_denied", comment: "") }
                }
                return
            default:
                lastError = NSLocalizedString("call_error_camera_denied", comment: "")
                return
            }
        }
        let wasSending = video.canSend && video.localCameraOn
        updateCamera { $0.localCameraOn = on }
        #if os(iOS)
        if CallVideoAudio.movesToSpeaker(
            wasSending: wasSending,
            isSending: video.canSend && video.localCameraOn,
            outputIsEarpiece: Self.outputIsEarpiece()
        ) {
            CallAudioController.setSpeaker(true)
        }
        #endif
    }

    #if os(iOS)
    static func outputIsEarpiece() -> Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .builtInReceiver }
    }
    #endif

    /// An incoming video call is answered with the camera on (`CallVideoSignal.answersWithCamera`).
    /// When the offer comes after the answer — the push can beat it by seconds — the session is
    /// already there, and the camera comes on now.
    func takeUpVideoCall(_ offer: Shared_Proto_Signaling_V1_CallOffer, for call: ActiveCall) {
        guard case .incoming = call.session.direction, !call.startsWithCamera,
              CallVideoSignal.turnsCameraOn(
                  offerCallType: offer.callType,
                  videoEnabled: CallsFeature.isVideoEnabled,
                  answeredWithoutCamera: call.answeredWithoutCamera
              )
        else { return }
        call.startsWithCamera = true
        if call.webrtc != nil { setCameraOn(true) }
    }

    /// The push rang the call as its `call_type` said; the offer, from inside the ratchet, has the
    /// last word on how CallKit shows it.
    func ringAsOffered(_ offer: Shared_Proto_Signaling_V1_CallOffer, for call: ActiveCall) {
        let isVideo = CallVideoSignal.answersWithCamera(offerCallType: offer.callType, videoEnabled: CallsFeature.isVideoEnabled)
        video.ringsAsVideo = isVideo
        #if os(iOS)
        guard call.callKitRegistered else { return }
        CallKitProvider.shared.updateCallHasVideo(uuid: call.session.uuid, hasVideo: isVideo)
        #endif
    }

    /// The session the video views draw from. Nothing else outside this class needs it.
    var activeWebRTC: (any WebRTCSessionProtocol)? { active?.webrtc }

    func switchCamera() {
        guard video.localCameraOn else { return }
        updateCamera { $0.facing = $0.facing.flipped }
    }

    private func setInBackground(_ background: Bool) {
        guard active != nil, video.isInBackground != background else { return }
        updateCamera { $0.isInBackground = background }
    }

    /// Bring the sender in line with `video` — after an offer, when the sender may have appeared.
    func applyCamera() {
        updateCamera { _ in }
    }

    /// The one way our side of `video` changes: the change (`CallVideoState.apply`, which says
    /// what the peer must be told), then the sender brought in line, then the peer told.
    private func updateCamera(_ change: (inout CallVideoState) -> Void) {
        let webrtc = active?.webrtc
        let announce = video.apply(change, canSend: webrtc?.canSendVideo)
        webrtc?.setCameraOn(video.canSend && video.localCameraOn, facing: video.facing)
        // Before media connects nothing is sent: `onConnected` says it then.
        guard let announce, active != nil, machineCall?.mediaConnected == true else { return }
        sendMediaUpdate(cameraOn: announce)
    }

    func sendMediaUpdate(cameraOn: Bool) {
        guard let active else { return }
        var sig = Shared_Proto_Signaling_V1_WebRTCSignal()
        sig.callID = active.session.id
        sig.senderDeviceID = Self.currentDeviceId()
        sig.timestamp = Self.nowMs()
        sig.signal = .mediaUpdate(CallVideoSignal.mediaUpdate(cameraOn: cameraOn, atMs: sig.timestamp))
        sendCallSignalProto(sig, to: active.session.peerUserId)
        Log.info("Camera \(cameraOn ? "on" : "off") announced (call_id=\(active.session.id.prefix(8))…)", category: "Calls")
    }

    /// End the call identified by `callUUID`.
    ///
    /// - Parameter source: Origin of the end request. Logged so postmortems can
    ///   distinguish explicit UI actions from CallKit/system-driven termination.
    func end(callUUID: UUID, source: CallEndSource = .programmatic) {
        guard let active, active.session.uuid == callUUID else {
            Log.info("End for unknown call uuid=\(callUUID.uuidString.prefix(8))… source=\(source.rawValue) \(Self.currentAppContext())", category: "Calls")
            return
        }

        let wasRegisteredWithCallKit = active.callKitRegistered
        let context = describeEndContext(active: active)
        // Best-effort: open the signaling stream so the hangup also takes the fast relay path.
        // The hangup MUST be sent even if the stream can't open — it also goes E2EE — and
        // skipping it leaves the peer ringing until the server-side TTL.
        try? openStreamIfNeeded()
        // The machine says the reason (declined while ringing, normal after), the devices and the
        // paths, and ends the call.
        if let hangup = withMachine({ $0.hangUp(nowMs: Self.nowMs()) }) {
            Log.info("Call end requested source=\(source.rawValue) reason=\(hangup.reason) \(context)", category: "Calls")
            sendHangup(hangup)
            endActiveCall(reason: .hangup(CallRuleWire.proto(hangup.reason)), ended: hangup.ended, reportToCallKit: false)
        } else {
            Log.error("Call end requested source=\(source.rawValue) for a call the machine does not hold \(context)", category: "Calls")
            endActiveCall(reason: .local("Ended without a call"), reportToCallKit: false)
        }

        Task {
            #if os(iOS)
            // When the user ends the call from within the app, CallKit still thinks the
            // call is active. Requesting CXEndCallAction via the call controller causes
            // CallKit to dismiss the lock-screen call UI. The resulting onEnd callback
            // will call end() again, but active will be nil by then, so it's a no-op.
            if source != .callKit && wasRegisteredWithCallKit {
                await CallKitProvider.shared.requestEndCall(uuid: callUUID)
            }
            #endif
        }
    }

    // MARK: - Internals

    func begin(session: CallSession, initialState: CallState) {
        active?.close()
        // Start this call with a fresh signal-send chain. The chain only needs to order
        // signals WITHIN one call; carrying it across calls means a stalled send from the
        // previous call (e.g. a hung sendMessage response) would block this call's offer.
        // Nil (don't cancel) so any still-in-flight send from the old call can finish.
        callSignalSendChain = nil
        active = ActiveCall(session: session)
        video = CallVideoState()
        state = initialState
        PerformanceMetrics.shared.start(.callSetupStart, label: String(session.id.prefix(8)))
    }


    /// Tear the call down here. `ended`: the machine's end of it, when the caller already ended it
    /// there (`hangUp`, `hangupFrom`, a deadline); otherwise the machine ends it now for `reason`
    /// (`CallRuleWire.end`). The history row and its length are the machine's.
    ///
    /// A failure of ours (`.local`) is the machine's `fail`, which says whether the peer is told —
    /// here, so no failure path can end the call alone again: until construct-core 0.76.0 none
    /// told, and the other side sat in "connecting" or "calling" until a person hung up
    /// (2026-11-16, build 779: an ICE failure, a TURN fetch with the VEIL tunnel still down).
    func endActiveCall(reason: CallEndReason, ended: CallEnded? = nil, reportToCallKit: Bool = true) {
        guard let active else { return }
        if ended == nil, case .local(let what) = reason,
           let failure = withMachine({ $0.fail(nowMs: Self.nowMs()) }) {
            return endActiveCall(failure: failure, what: what, reportToCallKit: reportToCallKit)
        }
        let session = active.session
        let wasRegisteredWithCallKit = active.callKitRegistered
        let metricsLabel = String(session.id.prefix(8))
        let ended = ended ?? withMachine { CallRuleWire.end(reason, in: $0, nowMs: Self.nowMs()) }

        // A setup that never finished leaves its start pending (an answered call already ended
        // it; cancelling a finished one does nothing).
        PerformanceMetrics.shared.cancelStart(.callSetupStart, label: metricsLabel)
        PerformanceMetrics.shared.cancelStart(.callSignalOpenStart, label: metricsLabel)

        active.close()
        self.active = nil
        video = CallVideoState()
        clearIdentityKeyCache()
        // Return the signal-send chain to idle. sendHangup() above already chained this
        // call's hangup, whose Task keeps running after this nil (it still delivers); we
        // only drop the reference so the next call never awaits a stalled send from this one.
        callSignalSendChain = nil
        #if os(iOS)
        CallAudioController.shared.notifyTeardown()
        #endif
        state = .ended(session, reason)

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(NetworkTiming.Calls.endedAutoClearDelay))
            if case .ended = self.state { self.state = .idle }
        }

        // The history row, by the core's rule: none for a call taken on another of our devices —
        // that device records it; this one shows neither a missed call nor a second row.
        if let ended, let historyStatus = ended.history {
            CallHistoryService.shared.record(
                session: session,
                status: CallRuleWire.record(historyStatus),
                startedAt: Date(timeIntervalSince1970: Double(ended.startedAtMs) / 1000),
                durationSeconds: Int32(clamping: ended.durationSeconds)
            )
        } else if ended == nil {
            Log.error("Call \(session.id.prefix(8))… ended here but not in the call machine — no history row", category: "Calls")
        }

        #if os(iOS)
        if reportToCallKit && wasRegisteredWithCallKit {
            CallKitProvider.shared.reportCallEnded(uuid: session.uuid)
        }
        #endif
    }

    func sendRinging() {
        guard let active else { return }
        let msg = Self.makeRoutedSignal(
            callId: active.session.id,
            deviceId: Self.currentDeviceId(),
            signal: .ringing(Self.makeCallRinging(deviceId: Self.currentDeviceId(), timestampMs: Self.nowMs()))
        )
        active.stream?.send(msg)
    }

    /// Tell the signaling server the call is genuinely established (media is up).
    /// In the E2EE flow the answer SDP travels over encrypted messaging, so the server
    /// never sees an `.answer` on the signaling stream and `answered_at_ms` stays nil —
    /// leaving the call under the aggressive "ringing without answer" reaper. This
    /// non-SDP presence signal sets `answered_at_ms` server-side (note_connected), moving
    /// the call to the lenient 60s keepalive reaper.
    func sendConnected() {
        guard let active else { return }
        let msg = Self.makeRoutedSignal(
            callId: active.session.id,
            deviceId: Self.currentDeviceId(),
            signal: .connected(Self.makeCallConnected(deviceId: Self.currentDeviceId(), timestampMs: Self.nowMs()))
        )
        active.stream?.send(msg)
        Log.info("CallConnected presence sent (call_id=\(active.session.id.prefix(8))…)", category: "Calls")
    }


    /// Our hangup, as the machine decided it: its reason, its devices and its paths.
    func sendHangup(_ hangup: CallLocalHangup) {
        sendHangup(reason: CallRuleWire.proto(hangup.reason), route: hangup.route, targets: hangup.targets)
    }

    /// The call failed here and the machine has ended it: its hangup (`CONNECTION_FAILED`) first,
    /// while the stream and the targets are still in hand, then the teardown.
    func endActiveCall(failure: CallFailure, what: String, reportToCallKit: Bool = true) {
        if let hangup = failure.hangup {
            sendHangup(reason: CallRuleWire.proto(hangup.reason), route: hangup.route, targets: hangup.targets)
        }
        endActiveCall(reason: .local(what), ended: failure.ended, reportToCallKit: reportToCallKit)
    }

    /// A hangup on `route`: end to end to `targets` (none: the call's targets, else the pinned
    /// device), and on the signaling stream. The machine's `call_hangup_route` decides the route:
    /// ours goes both ways; one the peer sent only to the stream, so the server's occupancy
    /// clears (AC92380B) without encrypting into a session that may be gone (D858E6FE); "accepted
    /// elsewhere" never to the stream, where the server would end the call for the device that
    /// took it.
    func sendHangup(reason: Shared_Proto_Signaling_V1_HangupReason, route: CallHangupRoute, targets: [String]) {
        guard let active else { return }
        var e2eeSent = false
        var streamSent = false
        if route.e2ee {
            var sig = Shared_Proto_Signaling_V1_WebRTCSignal()
            sig.callID = active.session.id
            sig.senderDeviceID = Self.currentDeviceId()
            sig.timestamp = Self.nowMs()
            sig.signal = .hangup(Self.makeCallHangup(deviceId: Self.currentDeviceId(), timestampMs: Self.nowMs(), reason: reason))
            switch sendCallSignalProto(sig, to: active.session.peerUserId, devices: CallRuleWire.devices(targets)) {
            case .encrypted:
                e2eeSent = true
            case .sessionMissing, .failed:
                // Stream hangup still goes out below. Encrypting into a void is what
                // logged CALL_SIGNAL_ENCRYPT_FAILED on D858E6FE and then claimed
                // "Hangup sent (E2EE+stream)" anyway.
                Log.info(
                    "E2EE hangup not sent — no session or encrypt failed (call_id=\(active.session.id.prefix(8))…)",
                    category: "Calls"
                )
            }
        }
        if route.stream, let stream = active.stream {
            stream.send(Self.makeRoutedSignal(
                callId: active.session.id,
                deviceId: Self.currentDeviceId(),
                signal: .hangup(Self.makeCallHangup(deviceId: Self.currentDeviceId(), timestampMs: Self.nowMs(), reason: reason))
            ))
            streamSent = true
        }
        Log.info(
            "Hangup sent (e2ee=\(e2eeSent) stream=\(streamSent)) to \(active.session.peerUserId.prefix(8))… reason=\(reason)",
            category: "Calls"
        )
    }





    // MARK: - Message Builders

    static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000.0)
    }

    static func currentDeviceId() -> String {
        AuthSessionManager.shared.currentDeviceId ?? (KeychainManager.shared.loadDeviceID() ?? "")
    }

    /// Single source of truth for "what name do we show for an incoming call from
    /// `userId`?". Looks up the local `User` entity and returns its
    /// `resolvedDisplayName` (profile-shared real name → server username →
    /// deterministic generated fallback). Returns `nil` when the contact is
    /// completely unknown to this device.
    static func resolveContactDisplayName(userId: String) -> String? {
        (try? LocalRepositories.contacts.contact(userId))?.resolvedDisplayName
    }

    private func describeEndContext(active: ActiveCall) -> String {
        let now = Self.nowMs()
        let setupMs = machineCall.map { Int(now - $0.startedAtMs) } ?? -1
        let answerMs = machineCall?.answeredAtMs.map { Int(now - $0) }
        return [
            "call_id=\(active.session.id.prefix(8))…",
            "dir=\(active.session.direction.debugName)",
            "state=\(state.debugName)",
            "mediaConnected=\(machineCall?.mediaConnected ?? false)",
            "streamOpen=\(active.stream != nil)",
            "callKitRegistered=\(active.callKitRegistered)",
            "answered=\(machineCall?.answeredAtMs != nil)",
            "setupAgeMs=\(setupMs)",
            "answerAgeMs=\(answerMs.map(String.init) ?? "nil")",
            Self.currentAppContext()
        ].joined(separator: " ")
    }

    private static func currentAppContext() -> String {
        #if os(iOS)
        let app = UIApplication.shared
        let sceneStates = app.connectedScenes
            .map { $0.activationState.debugName }
            .sorted()
            .joined(separator: ",")
        return "appState=\(app.applicationState.debugName) protectedData=\(app.isProtectedDataAvailable) scenes=[\(sceneStates)]"
        #else
        return "appState=n/a"
        #endif
    }

    static func makePing(timestampMs: Int64) -> Shared_Proto_Signaling_V1_SignalRequest {
        var ping = Shared_Proto_Signaling_V1_SignalPing()
        ping.timestamp = timestampMs
        var req = Shared_Proto_Signaling_V1_SignalRequest()
        req.request = .ping(ping)
        return req
    }

    private static func makeRoutedSignal(
        callId: String,
        deviceId: String,
        signal: Shared_Proto_Signaling_V1_WebRTCSignal.OneOf_Signal
    ) -> Shared_Proto_Signaling_V1_SignalRequest {
        var rtc = Shared_Proto_Signaling_V1_WebRTCSignal()
        rtc.callID = callId
        rtc.senderDeviceID = deviceId
        rtc.timestamp = nowMs()
        rtc.signal = signal

        var routed = Shared_Proto_Signaling_V1_RoutedWebRtcSignal()
        routed.signal = rtc

        var req = Shared_Proto_Signaling_V1_SignalRequest()
        req.request = .routedSignal(routed)
        return req
    }

    private static func makeCallRinging(deviceId: String, timestampMs: Int64) -> Shared_Proto_Signaling_V1_CallRinging {
        var r = Shared_Proto_Signaling_V1_CallRinging()
        r.deviceID = deviceId
        r.ringingAt = timestampMs
        return r
    }

    private static func makeCallConnected(deviceId: String, timestampMs: Int64) -> Shared_Proto_Signaling_V1_CallConnected {
        var c = Shared_Proto_Signaling_V1_CallConnected()
        c.deviceID = deviceId
        c.connectedAt = timestampMs
        return c
    }

    static func makeCallHangup(
        deviceId: String,
        timestampMs: Int64,
        reason: Shared_Proto_Signaling_V1_HangupReason
    ) -> Shared_Proto_Signaling_V1_CallHangup {
        var h = Shared_Proto_Signaling_V1_CallHangup()
        h.reason = reason
        h.deviceID = deviceId
        h.hangupAt = timestampMs
        return h
    }
}

private extension CallState {
    var debugName: String {
        switch self {
        case .idle: return "idle"
        case .incoming: return "incoming"
        case .dialing: return "dialing"
        case .ringing: return "ringing"
        case .connecting: return "connecting"
        case .active: return "active"
        case .ended: return "ended"
        }
    }
}

private extension CallSession.Direction {
    var debugName: String {
        switch self {
        case .incoming: return "incoming"
        case .outgoing: return "outgoing"
        }
    }
}

#if os(iOS)
private extension UIApplication.State {
    var debugName: String {
        switch self {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown(\(rawValue))"
        }
    }
}

private extension UIScene.ActivationState {
    var debugName: String {
        switch self {
        case .foregroundActive: return "foregroundActive"
        case .foregroundInactive: return "foregroundInactive"
        case .background: return "background"
        case .unattached: return "unattached"
        @unknown default: return "unknown"
        }
    }
}
#endif
