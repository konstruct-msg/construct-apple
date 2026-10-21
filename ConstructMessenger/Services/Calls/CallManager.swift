// swiftlint:disable file_length
//
//  CallManager.swift
//  Construct Messenger
//
//  Minimal scaffolding for calls (signaling + PushKit + CallKit).
//  Full WebRTC implementation will be layered in later.
//
//  macOS uses CallManagerStub.swift instead.
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

    /// Call ids that have already ended, with the instant they did.
    ///
    /// A call's signals outlive it: the offer travels the ordinary E2EE message stream and can be
    /// delivered long after both sides gave up. On 2026-08-05 an offer landed 8 s after its call
    /// had been ended and `handleIncomingCallOffer`, finding no active call, took the "no existing
    /// call" branch and rang CallKit again for a call nobody was making — a ghost incoming call
    /// with the same uuid the log had just reported ended.
    private var endedCallIds: [String: Date] = [:]
    /// How long an ended call id is remembered. Only needs to outlive in-flight signals for the
    /// call that just ended, not to be a durable record.
    private static let endedCallMemory: TimeInterval = 120

    private func rememberEnded(callId: String) {
        let now = Date()
        endedCallIds[callId] = now
        endedCallIds = endedCallIds.filter { now.timeIntervalSince($0.value) < Self.endedCallMemory }
    }

    func hasRecentlyEnded(callId: String) -> Bool {
        guard let endedAt = endedCallIds[callId] else { return false }
        return Date().timeIntervalSince(endedAt) < Self.endedCallMemory
    }

    /// Our outgoing call to `userId` is the one in progress — a call from them now is glare, which
    /// the offer's tie-break resolves, not a second caller to refuse.
    func isOutgoingCall(to userId: String) -> Bool {
        guard let active, case .outgoing = active.session.direction else { return false }
        return active.session.peerUserId == userId
    }

    /// Refuse a second call while one is in progress: hangup BUSY to its caller over E2EE, and the
    /// id remembered as ended, so the push and the offer — whichever comes second — find it ended
    /// instead of ringing. The call in progress is not touched. Not over the signaling stream: that
    /// stream belongs to the call in progress; the caller's client tells the server when it ends.
    func declineAsBusy(callId: String, callerUserId: String, callerDevice: String? = nil) {
        rememberEnded(callId: callId)
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
        /// Asked for with the video button: the camera comes on as soon as there is a sender.
        var startsWithCamera = false
        /// Answered with "without video": a video offer that arrives after the answer does not
        /// turn the camera on.
        var answeredWithoutCamera = false
        var keepaliveTask: Task<Void, Never>?
        var receiveTask: Task<Void, Never>?
        var acceptTask: Task<Void, Never>?
        let startedAt: Date = Date()
        var answeredAt: Date? = nil
        /// The peer's device this call talks to: the one that sent the offer (incoming), or the
        /// one whose answer came first (outgoing). Known from the session the core opened its
        /// signal under, never from `sender_device_id`. Nil until then.
        var peerDevice: String?
        /// The peer's devices our offer went to (outgoing, before an answer).
        var offeredDevices: [String] = []
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
        /// The user answered before the SDP offer arrived, and `answer()` has already run to
        /// completion with nothing to apply.
        ///
        /// The two facts "there is an incoming call" and "here is its SDP" travel on separate
        /// channels — the VoIP push (fast, call id only) and the E2EE offer (slow, carries the
        /// SDP) — and CallKit is driven by the first. On 2026-08-05 the push rang at 10:02:56, the
        /// user answered at 10:02:58, and the offer arrived at **10:03:26**, thirty seconds later.
        /// `handleIncomingCallOffer` stored it against a consumer that had already returned, so
        /// nothing ever built the answer: the callee sat in `.connecting` and the caller in
        /// `dialing` until both gave up by hand.
        ///
        /// This flag is what lets the late offer finish the job the answer started.
        var awaitingOfferAfterAnswer: Bool = false
        /// Bounds that wait. Without it the callee waits forever on an offer that may never come.
        var offerWaitTimeout: Task<Void, Never>?
        /// Ends an incoming call nobody answers. See `startUnansweredTimeout`.
        var unansweredTimeout: Task<Void, Never>?
        /// ICE candidates received via E2EE before the remote offer was applied.
        /// Applied automatically when pendingRemoteOfferSdp is consumed in answer().
        var pendingIceCandidates: [WebRTCIceCandidate] = []
        /// Whether CallKit successfully registered this call (requestStartCall succeeded).
        /// Only true calls should have reportCallEnded called on them.
        var callKitRegistered: Bool = false
        /// Number of signaling stream reconnect attempts (timeout-triggered). Capped at maxStreamRetries.
        var streamRetryCount: Int = 0
        static let maxStreamRetries = 3
        /// ICE candidates waiting to be flushed as a batch to stay under 10/sec signal rate limit.
        /// Our candidates waiting for the debounce, in the clear: each is encrypted per target
        /// device at the flush, because which devices those are can change before it runs.
        var pendingOutgoingIce: [WebRTCIceCandidate] = []
        /// Task that fires after a short debounce to flush pendingOutgoingIce.
        var iceFlushTask: Task<Void, Never>? = nil
        /// True once WebRTC media (ICE/DTLS) has connected at least once. After this, a
        /// signaling-stream close must NOT tear down the call — media is P2P/TURN and
        /// independent of the signaling stream. The call ends only on iceConnectionState
        /// = failed (onConnectionFailed) or explicit hangup.
        var mediaConnected: Bool = false
        /// Signaling-stream reconnect attempts made *after* media was already connected.
        /// Capped to avoid a tight reconnect loop if the server keeps closing the stream.
        var postMediaStreamReconnects: Int = 0
        static let maxPostMediaReconnects = 5
        /// Debounced restart task fired after `.disconnected` if the call does not
        /// self-heal. Cancelled as soon as ICE returns to `.connected/.completed`.
        var iceRestartTask: Task<Void, Never>?
        /// True while we have already generated and sent an ICE-restart offer and are
        /// waiting for the connection to recover or for the peer's answer.
        var isIceRestartInFlight: Bool = false
        /// Count caller-driven ICE restart attempts for this call.
        var iceRestartAttempts: Int = 0

        init(session: CallSession) {
            self.session = session
        }

        @MainActor
        func close() {
            keepaliveTask?.cancel()
            receiveTask?.cancel()
            acceptTask?.cancel()
            iceFlushTask?.cancel()
            iceRestartTask?.cancel()
            offerWaitTimeout?.cancel()
            unansweredTimeout?.cancel()
            iceFlushTask = nil
            iceRestartTask = nil
            offerWaitTimeout = nil
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
            Task { @MainActor in self?.handleIncomingPush(payload, reportedUUID: reportedUUID) }
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

    /// Mute or unmute the local microphone.
    func setMuted(_ muted: Bool) {
        active?.webrtc?.setMuted(muted)
    }

    // MARK: - Camera

    /// Turn the camera on or off. Asks for camera access the first time; a refusal leaves the
    /// camera off and says why.
    func setCameraOn(_ on: Bool) {
        guard CallsFeature.isVideoEnabled, active != nil else { return }
        #if os(iOS)
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
        #endif
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
        guard let announce, let active, active.mediaConnected else { return }
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

        let reason: Shared_Proto_Signaling_V1_HangupReason
        if case .incoming = active.session.direction, case .incoming = state {
            reason = .declined
        } else {
            reason = .normal
        }

        let wasRegisteredWithCallKit = active.callKitRegistered
        Log.info(
            "Call end requested source=\(source.rawValue) reason=\(reason) \(describeEndContext(active: active))",
            category: "Calls"
        )

        Task {
            // Best-effort: open the signaling stream so the hangup also takes the fast
            // relay path. The hangup MUST be sent even if the stream can't open — it is
            // also sent via E2EE (sendHangup uses both), and skipping it leaves the peer
            // ringing until the server-side TTL.
            try? openStreamIfNeeded()
            sendHangup(reason: reason, origin: .local)
            endActiveCall(reason: .hangup(reason), reportToCallKit: false)
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
        if case .incoming = initialState, let active { startUnansweredTimeout(for: active) }
        PerformanceMetrics.shared.start(.callSetupStart, label: String(session.id.prefix(8)))
    }


    func endActiveCall(reason: CallEndReason, reportToCallKit: Bool = true) {
        guard let active else { return }
        let session = active.session
        let startedAt = active.startedAt
        let answeredAt = active.answeredAt
        let wasRegisteredWithCallKit = active.callKitRegistered
        let metricsLabel = String(session.id.prefix(8))

        // If we never reached "active", clean up pending metric starts.
        if answeredAt == nil {
            PerformanceMetrics.shared.cancelStart(.callSetupStart, label: metricsLabel)
        }
        PerformanceMetrics.shared.cancelStart(.callSignalOpenStart, label: metricsLabel)

        // Determine call status for history
        let historyStatus: CallRecord.Status
        switch reason {
        case .hangup(let r):
            switch r {
            case .declined: historyStatus = session.direction == .incoming ? .declined : .missed
            case .busy:     historyStatus = .missed
            default:        historyStatus = answeredAt != nil ? .completed : .missed
            }
        case .error, .local:
            historyStatus = answeredAt != nil ? .completed : .failed
        }

        let duration: Int32 = answeredAt.map { Int32(Date().timeIntervalSince($0)) } ?? 0

        active.close()
        self.active = nil
        video = CallVideoState()
        rememberEnded(callId: session.id)
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

        #if os(iOS)
        // Taken on another of our devices: that device records the call; this one neither shows
        // a missed call nor a second entry for it.
        if reason != .hangup(.acceptedElsewhere) {
            CallHistoryService.shared.record(
                session: session,
                status: historyStatus,
                startedAt: startedAt,
                durationSeconds: duration
            )
        }
        #endif

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


    func sendHangup(
        reason: Shared_Proto_Signaling_V1_HangupReason,
        origin: CallHangupOrigin
    ) {
        guard let active else { return }
        let channels = callHangupChannels(origin: origin)
        var e2eeSent = false
        var streamSent = false
        if channels.contains(.e2ee) {
            var sig = Shared_Proto_Signaling_V1_WebRTCSignal()
            sig.callID = active.session.id
            sig.senderDeviceID = Self.currentDeviceId()
            sig.timestamp = Self.nowMs()
            sig.signal = .hangup(Self.makeCallHangup(deviceId: Self.currentDeviceId(), timestampMs: Self.nowMs(), reason: reason))
            switch sendCallSignalProto(sig, to: active.session.peerUserId) {
            case .encrypted:
                e2eeSent = true
            case .sessionMissing, .failed:
                // Stream hangup still goes out below. Encrypting into a void is what
                // logged CALL_SIGNAL_ENCRYPT_FAILED on D858E6FE and then claimed
                // "Hangup sent (E2EE+stream)" anyway.
                Log.info(
                    "E2EE hangup not sent (\(origin)) — no session or encrypt failed (call_id=\(active.session.id.prefix(8))…)",
                    category: "Calls"
                )
            }
        }
        if channels.contains(.signalingStream), let stream = active.stream {
            stream.send(Self.makeRoutedSignal(
                callId: active.session.id,
                deviceId: Self.currentDeviceId(),
                signal: .hangup(Self.makeCallHangup(deviceId: Self.currentDeviceId(), timestampMs: Self.nowMs(), reason: reason))
            ))
            streamSent = true
        }
        Log.info(
            "Hangup sent (e2ee=\(e2eeSent) stream=\(streamSent) origin=\(origin)) to \(active.session.peerUserId.prefix(8))… reason=\(reason)",
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
        let setupMs = Int(Date().timeIntervalSince(active.startedAt) * 1000)
        let answerMs = active.answeredAt.map { Int(Date().timeIntervalSince($0) * 1000) }
        return [
            "call_id=\(active.session.id.prefix(8))…",
            "dir=\(active.session.direction.debugName)",
            "state=\(state.debugName)",
            "mediaConnected=\(active.mediaConnected)",
            "streamOpen=\(active.stream != nil)",
            "callKitRegistered=\(active.callKitRegistered)",
            "answered=\(active.answeredAt != nil)",
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
