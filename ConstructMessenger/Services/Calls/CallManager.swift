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

@MainActor
@Observable
final class CallManager {
    static let shared = CallManager()

    enum CallState: Equatable {
        case idle
        case incoming(CallSession)
        case dialing(CallSession)
        case ringing(CallSession)
        case connecting(CallSession)
        case active(CallSession)
        case ended(CallSession, EndReason)
    }

    struct CallSession: Equatable {
        enum Direction: Equatable { case incoming, outgoing }
        let id: String
        let uuid: UUID
        let peerUserId: String
        let peerName: String
        let direction: Direction
    }

    enum EndReason: Equatable {
        case hangup(Shared_Proto_Signaling_V1_HangupReason)
        case error(Shared_Proto_Signaling_V1_SignalErrorCode)
        case local(String)
    }

    private(set) var state: CallState = .idle
    private(set) var lastError: String? = nil

    func clearLastError() { lastError = nil }

    private var active: ActiveCall?

    private final class ActiveCall {
        let session: CallSession
        var stream: SignalStream?
        var turn: Shared_Proto_Signaling_V1_TurnCredentials?
        var webrtc: (any WebRTCSessionProtocol)?
        var keepaliveTask: Task<Void, Never>?
        var receiveTask: Task<Void, Never>?
        var acceptTask: Task<Void, Never>?
        let startedAt: Date = Date()
        var answeredAt: Date? = nil
        /// SDP offer received via MessagingService before the user answered.
        var pendingRemoteOfferSdp: String? = nil
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
        var pendingOutgoingIce: [Shared_Proto_Signaling_V1_IceCandidate] = []
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
            webrtc?.close()
            webrtc = nil
            stream?.close()
            stream = nil
        }
    }

    private init() {
        #if os(iOS)
        VoIPPushManager.shared.onIncomingPush = { [weak self] payload, reportedUUID in
            Task { @MainActor in self?.handleIncomingPush(payload, reportedUUID: reportedUUID) }
        }
        CallKitProvider.shared.onAnswer = { [weak self] uuid in
            Task { @MainActor in self?.answer(callUUID: uuid) }
        }
        CallKitProvider.shared.onEnd = { [weak self] uuid in
            Task { @MainActor in self?.end(callUUID: uuid, fromCallKit: true) }
        }
        CallKitProvider.shared.onAudioActivated = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // CallKit has activated the audio session — configure it now.
                // This is the correct place per Apple's CallKit documentation.
                // WebRTCSession.configureAudioSession() sets category but defers
                // setActive; CallKit calls this when it's safe to use audio.
                let avSession = AVAudioSession.sharedInstance()
                try? avSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
                try? avSession.setActive(true)
                // Play dial tone only on outgoing calls (dialing or ringing state).
                switch self.state {
                case .dialing, .ringing: DialTonePlayer.shared.start()
                default: break
                }
            }
        }
        CallKitProvider.shared.onAudioDeactivated = {
            Task { @MainActor in DialTonePlayer.shared.stop() }
        }
        #endif
    }

    // MARK: - Outgoing (stub)

    func startOutgoingCall(to userId: String, displayName: String, hasVideo: Bool = false) async {
        guard CallsFeature.isEnabled else {
            Log.info("Calls disabled — ignoring outgoing call request", category: "Calls")
            return
        }

        // Use UUID string for call_id so it round-trips through CallKit cleanly.
        let uuid = UUID()
        let callId = uuid.uuidString

        let session = CallSession(
            id: callId,
            uuid: uuid,
            peerUserId: userId,
            peerName: displayName,
            direction: .outgoing
        )
        begin(session: session, initialState: .dialing(session))

        do {
            #if os(iOS)
            try await CallKitProvider.shared.requestStartCall(
                uuid: uuid,
                calleeId: userId,
                calleeName: displayName,
                hasVideo: hasVideo
            )
            active?.callKitRegistered = true
            #endif

            // Notify server: checks rate limits, delivers push/stream notification to callee.
            let initResp = try await SignalingServiceClient.shared.initiateCall(
                callId: callId,
                calleeUserId: userId,
                callerName: AuthSessionManager.shared.currentDisplayName,
                hasVideo: hasVideo
            )
            // calleeOnline=false is normal: idle users never have a signal stream open.
            // The server sends a VoIP push to wake the callee in this case.
            // Continue the call regardless — it will ring until the callee answers or
            // the server TTL expires (server sends an error signal when the call times out).
            Log.info("InitiateCall: calleeOnline=\(initResp.calleeOnline) (call_id=\(callId.prefix(8))…)", category: "Calls")

            let turn = try? await SignalingServiceClient.shared.getTurnCredentials(callId: callId)
            if let turn {
                active?.turn = turn
                Log.info("TURN credentials ready for outgoing call (call_id=\(callId.prefix(8))…)", category: "Calls")
            } else {
                Log.info("TURN unavailable — proceeding STUN-only (call_id=\(callId.prefix(8))…)", category: "Calls")
            }

            try openStreamIfNeeded()

            try ensureWebRTC(role: .caller)
            try await sendOffer(toUserId: userId)
        } catch {
            Log.error("Outgoing call setup failed: \(error)", category: "Calls")
            if let rpcError = error as? RPCError, rpcError.code == .permissionDenied {
                lastError = NSLocalizedString("call_error_not_contacts", comment: "")
            }
            endActiveCall(reason: .local("Call setup failed"))
        }
    }

    // MARK: - Incoming (from PushKit)

    private func handleIncomingPush(_ payload: [AnyHashable: Any], reportedUUID: UUID) {
        guard CallsFeature.isEnabled else {
            Log.info("Calls disabled — ignoring incoming VoIP push", category: "Calls")
            return
        }

        // Busy guard: decline new incoming calls when already in a call.
        // `begin()` would silently close the active call via active?.close() — don't let that happen.
        if active != nil {
            switch state {
            case .active, .connecting, .dialing, .ringing:
                Log.info("Busy — declining second incoming push (uuid=\(reportedUUID.uuidString.prefix(8))…)", category: "Calls")
                #if os(iOS)
                // PushKit already reported this to CallKit synchronously; tell it the call ended.
                CallKitProvider.shared.reportCallEnded(uuid: reportedUUID)
                #endif
                return
            default:
                break
            }
        }

        let callId  = (payload["call_id"]  as? String) ?? reportedUUID.uuidString
        let callerId = (payload["caller_id"] as? String) ?? "Unknown"
        // Privacy: do NOT use caller_name from push payload (exposed to APNs infrastructure).
        // Look up display name from local CoreData; fall back to generic app name.
        let callerName: String = {
            let ctx = PersistenceController.shared.container.viewContext
            let req = User.fetchRequest()
            req.predicate = NSPredicate(format: "id == %@", callerId)
            req.fetchLimit = 1
            if let user = (try? ctx.fetch(req))?.first {
                return user.displayName
            }
            return NSLocalizedString("construct_app_name", comment: "")
        }()

        // reportedUUID was already passed to CallKit synchronously inside PushKit's delegate
        // callback (iOS 13+ requirement). Do not call reportIncomingCall again.
        let session = CallSession(
            id: callId,
            uuid: reportedUUID,
            peerUserId: callerId,
            peerName: callerName,
            direction: .incoming
        )
        begin(session: session, initialState: .incoming(session))

        #if os(iOS)
        // Update CallKit with the resolved caller name from local CoreData
        // (we reported with app name initially to meet the sync deadline).
        if callerName != NSLocalizedString("construct_app_name", comment: "") {
            Task { @MainActor in
                CallKitProvider.shared.updateCallInfo(uuid: reportedUUID, callerName: callerName)
            }
        }
        active = ActiveCall(session: session)
        active?.callKitRegistered = true
        state = .incoming(session)
        #endif
    }

    // MARK: - CallKit Actions

    func answer(callUUID: UUID) {
        guard let active, active.session.uuid == callUUID else {
            Log.info("Answer for unknown call uuid=\(callUUID.uuidString.prefix(8))…", category: "Calls")
            return
        }
        guard case .incoming = active.session.direction else { return }

        #if os(iOS)
        DialTonePlayer.shared.stop()
        #endif
        state = .connecting(active.session)

        Task { [weak self] in
            guard let self else { return }
            do {
                let turn = try? await SignalingServiceClient.shared.getTurnCredentials(callId: active.session.id)
                if let turn {
                    self.active?.turn = turn
                    Log.info("TURN ready for incoming call", category: "Calls")
                } else {
                    Log.info("TURN unavailable — proceeding STUN-only (incoming)", category: "Calls")
                }
                try self.ensureWebRTC(role: .callee)

                // If the offer arrived via E2EE before the user answered, apply it now
                // and immediately send back an answer so the caller can proceed with ICE.
                if let pendingSdp = self.active?.pendingRemoteOfferSdp, !pendingSdp.isEmpty {
                    guard let webrtc = self.active?.webrtc else {
                        throw WebRTCSessionError.invalidState("WebRTC not ready after ensureWebRTC")
                    }
                    try await webrtc.setRemoteOffer(sdp: pendingSdp)
                    self.active?.pendingRemoteOfferSdp = nil
                    Log.info("Applied pending E2EE offer SDP", category: "Calls")

                    // Drain ICE candidates that arrived before the offer was applied.
                    let buffered = self.active?.pendingIceCandidates ?? []
                    if !buffered.isEmpty {
                        Log.info("Draining \(buffered.count) buffered ICE candidate(s)", category: "Calls")
                        for ice in buffered {
                            try? await webrtc.addRemoteIceCandidate(ice)
                        }
                        self.active?.pendingIceCandidates = []
                    }

                    let answerSdp = try await webrtc.createAnswer()
                    guard !answerSdp.isEmpty else {
                        throw WebRTCSessionError.invalidState("createAnswer returned empty SDP")
                    }
                    sendAnswer(sdp: answerSdp)
                    self.active?.answeredAt = Date()
                    self.state = .active(active.session)
                    Log.info("E2EE incoming call answered: SDP exchanged", category: "Calls")
                    #if os(iOS)
                    CallKitProvider.shared.reportOutgoingCallConnected(uuid: active.session.uuid)
                    #endif
                    // Open stream so callee ICE candidates reach the caller via the
                    // signaling relay instead of the E2EE fallback path.
                    try? self.openStreamIfNeeded()
                    // Server expects a ringing event on the signaling stream — without it
                    // the call is reaped as `calleeOffline` ~7s after iceConnected, killing
                    // an otherwise-working media tunnel. Send it even though the SDP answer
                    // already went via E2EE; the server treats ringing as a presence beacon.
                    sendRinging()
                    return
                }

                // No pending E2EE offer → signal stream path: open stream, wait for offer.
                try openStreamIfNeeded()
                sendRinging()
            } catch {
                Log.error("Failed to accept call: \(error)", category: "Calls")
                endActiveCall(reason: .local("Accept failed"))
            }
        }
    }

    // MARK: - Convenience UI actions

    /// End the active call (for in-app end-call button).
    func endCall() {
        guard let active else { return }
        end(callUUID: active.session.uuid)
    }

    /// Answer the current incoming call from in-app UI (bypasses CallKit transaction).
    func answerIncomingCall() {
        guard let active, case .incoming = state else { return }
        answer(callUUID: active.session.uuid)
    }

    /// Decline the current incoming call from in-app UI.
    func declineIncomingCall() {
        guard let active, case .incoming = state else { return }
        end(callUUID: active.session.uuid)
    }

    /// Mute or unmute the local microphone.
    func setMuted(_ muted: Bool) {
        active?.webrtc?.setMuted(muted)
    }

    /// Enable or disable loudspeaker.
    func setSpeaker(_ enabled: Bool) {
        active?.webrtc?.setSpeaker(enabled)
    }

    /// End the call identified by `callUUID`.
    ///
    /// - Parameter fromCallKit: Pass `true` when called from the `CXEndCallAction`
    ///   delegate (`onEnd` callback) — CallKit already knows the call is ending, so
    ///   no `requestEndCall` is needed. Pass `false` (default) when called from in-app
    ///   UI (End/Decline buttons), which requires us to tell CallKit via
    ///   `requestEndCall` so the lock-screen call UI is dismissed.
    func end(callUUID: UUID, fromCallKit: Bool = false) {
        guard let active, active.session.uuid == callUUID else {
            Log.info("End for unknown call uuid=\(callUUID.uuidString.prefix(8))…", category: "Calls")
            return
        }

        let reason: Shared_Proto_Signaling_V1_HangupReason
        if case .incoming = active.session.direction, case .incoming = state {
            reason = .declined
        } else {
            reason = .normal
        }

        let wasRegisteredWithCallKit = active.callKitRegistered

        Task {
            do {
                try openStreamIfNeeded()
                sendHangup(reason: reason)
            } catch {
                Log.error("Failed to send hangup: \(error)", category: "Calls")
            }
            endActiveCall(reason: .hangup(reason), reportToCallKit: false)
            #if os(iOS)
            // When the user ends the call from within the app, CallKit still thinks the
            // call is active. Requesting CXEndCallAction via the call controller causes
            // CallKit to dismiss the lock-screen call UI. The resulting onEnd callback
            // will call end() again, but active will be nil by then, so it's a no-op.
            if !fromCallKit && wasRegisteredWithCallKit {
                await CallKitProvider.shared.requestEndCall(uuid: callUUID)
            }
            #endif
        }
    }

    // MARK: - Internals

    private func begin(session: CallSession, initialState: CallState) {
        active?.close()
        active = ActiveCall(session: session)
        state = initialState
        PerformanceMetrics.shared.start(.callSetupStart, label: String(session.id.prefix(8)))
    }

    private func openStreamIfNeeded() throws {
        guard let active else { throw RPCError(code: .failedPrecondition, message: "No active call") }
        guard active.stream == nil else { return }

        let stream = try SignalingServiceClient.shared.openSignalStream()
        active.stream = stream

        let metricsLabel = String(active.session.id.prefix(8))
        PerformanceMetrics.shared.start(.callSignalOpenStart, label: metricsLabel)

        // Wait until the server accepts the stream; on timeout, try an ICE fast-fallback.
        active.acceptTask?.cancel()
        active.acceptTask = Task { @MainActor [weak self, weak active] in
            struct AcceptTimeout: Error {}
            guard let self, let active else { return }
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for await _ in stream.accepted { return }
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(NetworkTiming.Calls.signalingStreamOpenAcceptTimeout))
                        throw AcceptTimeout()
                    }
                    _ = try await group.next()
                    group.cancelAll()
                }

                PerformanceMetrics.shared.end(.callSignalOpenStart, endEvent: .callSignalOpenEnd, label: metricsLabel)
                Log.info("Signaling stream accepted (call_id=\(metricsLabel)…)", category: "Calls")
            } catch is AcceptTimeout {
                PerformanceMetrics.shared.cancelStart(.callSignalOpenStart, label: metricsLabel)
                Log.info("Signaling stream open timed out — attempting ICE fast-failover (call_id=\(metricsLabel)…)", category: "Calls")

                // If ICE is running but on cooldown, clear cooldown: direct path is likely blocked.
                if VeilProxyManager.shared.isRunning, VeilProxyManager.shared.isOnCooldown {
                    VeilProxyManager.shared.clearCooldown()
                }

                // Only restart if this stream is still the active one.
                guard self.active === active, active.stream === stream else { return }
                active.stream?.close()
                active.stream = nil
                active.streamRetryCount += 1
                if active.streamRetryCount <= ActiveCall.maxStreamRetries {
                    Log.info("Retrying signal stream (attempt \(active.streamRetryCount)/\(ActiveCall.maxStreamRetries))", category: "Calls")
                    try? self.openStreamIfNeeded()
                } else {
                    Log.error("Signal stream failed after \(ActiveCall.maxStreamRetries) retries — falling back to E2EE-only mode", category: "Calls")
                }
            } catch is CancellationError {
                PerformanceMetrics.shared.cancelStart(.callSignalOpenStart, label: metricsLabel)
            } catch {
                PerformanceMetrics.shared.cancelStart(.callSignalOpenStart, label: metricsLabel)
            }
        }

        // Keepalive ping every 25s (server closes idle streams).
        active.keepaliveTask?.cancel()
        active.keepaliveTask = Task { [weak active] in
            while !(Task.isCancelled) {
                try? await Task.sleep(for: .seconds(NetworkTiming.Calls.signalingKeepaliveInterval))
                guard let active else { return }
                let ping = Self.makePing(timestampMs: Self.nowMs())
                await MainActor.run {
                    active.stream?.send(ping)
                }
            }
        }

        // Receive loop
        active.receiveTask?.cancel()
        active.receiveTask = Task { [weak self, weak active] in
            guard let self else { return }
            guard let active else { return }
            for await msg in stream.incoming {
                await MainActor.run {
                    self.handleSignalResponse(msg, for: active.session)
                }
            }
            // Stream closed — end call only if this stream is still the active one.
            // If openStreamIfNeeded() replaced the stream during a retry, `active.stream`
            // will point to the new stream, and this old receiveTask must NOT tear down
            // the call that the new stream is serving.
            await MainActor.run { [weak self, weak active] in
                guard let self, let active else { return }
                if self.active === active, active.stream === stream {
                    Log.error("Signaling stream closed unexpectedly", category: "Calls")
                    self.endActiveCall(reason: .local("Signal stream closed"))
                }
            }
        }

        Log.info("Signaling stream connecting (call_id=\(active.session.id.prefix(8))…)", category: "Calls")
    }

    private func handleSignalResponse(_ response: Shared_Proto_Signaling_V1_SignalResponse, for session: CallSession) {
        switch response.response {
        case .pong:
            break
        case .error(let error):
            Log.error("Signaling error: code=\(error.code) msg=\(error.message)", category: "Calls")
            switch error.code {
            case .rateLimited:
                // ICE candidate was dropped server-side; WebRTC will retransmit or use other candidates.
                // Do NOT end the call — this is a transient error from ICE burst at call start.
                break
            default:
                endActiveCall(reason: .error(error.code))
            }
        case .incomingCall(let call):
            // Fallback path: server delivers incoming-call notification while app is foreground
            // (device is online, no PushKit wake needed). Report to CallKit directly.
            guard CallsFeature.isEnabled else { return }
            if case .idle = state {
                Log.info("IncomingCallNotification received (call_id=\(call.callID.prefix(8))…)", category: "Calls")
                #if os(iOS)
                let reportedUUID = CallKitProvider.shared.reportIncomingCall(
                    callId: call.callID,
                    callerId: call.callerID,
                    callerName: call.callerName,
                    hasVideo: false
                )
                let payload: [AnyHashable: Any] = [
                    "call_id": call.callID,
                    "caller_id": call.callerID
                ]
                handleIncomingPush(payload, reportedUUID: reportedUUID)
                #else
                // macOS: no PushKit/CallKit; show incoming call UI directly.
                let session = CallSession(
                    id: call.callID,
                    uuid: UUID(),
                    peerUserId: call.callerID,
                    peerName: call.callerName,
                    direction: .incoming
                )
                begin(session: session, initialState: .incoming(session))
                #endif
            }
        case .signal(let s):
            switch s.signal {
            case .offer(let offer):
                Task { @MainActor in
                    await self.handleRemoteOffer(offer, for: session)
                }
            case .ringing(let r):
                Log.info("Ringing device=\(r.deviceID.prefix(8))…", category: "Calls")
                state = .ringing(session)
            case .busy:
                Log.info("Busy", category: "Calls")
                endActiveCall(reason: .hangup(.busy))
            case .answer(let answer):
                Task { @MainActor in
                    await self.handleRemoteAnswer(answer, for: session)
                }
            case .iceCandidate(let c):
                Task { @MainActor in
                    await self.handleRemoteIceCandidate(c, for: session)
                }
            case .iceCandidates(let batch):
                Task { @MainActor in
                    await self.handleRemoteIceCandidateBatch(batch, for: session)
                }
            case .hangup(let h):
                Log.info("Hangup reason=\(h.reason)", category: "Calls")
                endActiveCall(reason: .hangup(h.reason))
            default:
                break
            }
        case .none:
            break
        }
    }

    private func endActiveCall(reason: EndReason, reportToCallKit: Bool = true) {
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
        let historyStatus: CTCallRecord.Status
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
        #if os(iOS)
        DialTonePlayer.shared.stop()
        #endif
        state = .ended(session, reason)

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(NetworkTiming.Calls.endedAutoClearDelay))
            if case .ended = self.state { self.state = .idle }
        }

        #if os(iOS)
        CallHistoryService.shared.record(
            session: session,
            status: historyStatus,
            startedAt: startedAt,
            durationSeconds: duration
        )
        #endif

        #if os(iOS)
        if reportToCallKit && wasRegisteredWithCallKit {
            CallKitProvider.shared.reportCallEnded(uuid: session.uuid)
        }
        #endif
    }

    private func sendRinging() {
        guard let active else { return }
        let msg = Self.makeRoutedSignal(
            callId: active.session.id,
            deviceId: Self.currentDeviceId(),
            signal: .ringing(Self.makeCallRinging(deviceId: Self.currentDeviceId(), timestampMs: Self.nowMs()))
        )
        active.stream?.send(msg)
    }

    private func sendHangup(reason: Shared_Proto_Signaling_V1_HangupReason) {
        guard let active else { return }
        var sig = Shared_Proto_Signaling_V1_WebRTCSignal()
        sig.callID = active.session.id
        sig.senderDeviceID = Self.currentDeviceId()
        sig.timestamp = Self.nowMs()
        sig.signal = .hangup(Self.makeCallHangup(deviceId: Self.currentDeviceId(), timestampMs: Self.nowMs(), reason: reason))
        if let stream = active.stream {
            stream.send(Self.makeRoutedSignal(callId: active.session.id, deviceId: Self.currentDeviceId(), signal: .hangup(Self.makeCallHangup(deviceId: Self.currentDeviceId(), timestampMs: Self.nowMs(), reason: reason))))
        } else {
            // Stream not available (E2EE-only call path) — send hangup via DR-encrypted message.
            sendCallSignalProto(sig, to: active.session.peerUserId)
            Log.info("Hangup sent via E2EE (no stream) to \(active.session.peerUserId.prefix(8))…", category: "Calls")
        }
    }

    // MARK: - WebRTC (Phase 3)

    private func ensureWebRTC(role: WebRTCSessionRole) throws {
        guard let active else { throw RPCError(code: .failedPrecondition, message: "No active call") }
        if active.webrtc != nil { return }

        let webrtc = try WebRTCSession(role: role, turn: active.turn)
        webrtc.onLocalIceCandidate = { [weak self] c in
            Task { @MainActor in
                self?.sendIceCandidate(c)
            }
        }
        webrtc.onConnectionFailed = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                Log.error("WebRTC connection failed — ending call", category: "Calls")
                self.endActiveCall(reason: .local("ICE connection failed"))
            }
        }
        webrtc.onConnected = { [weak self] in
            Task { @MainActor in
                guard self != nil else { return }
                // The dial tone is an AVAudioEngine holding the shared
                // .playAndRecord session's playback bus. Until it stops, WebRTC's
                // voice-processing audio unit produces no audible output. Idempotent —
                // peerConnectionState may bounce through .connected on reconnects.
                #if os(iOS)
                DialTonePlayer.shared.stop()
                #endif
            }
        }
        active.webrtc = webrtc
        Log.info("WebRTC session created (role=\(role), turn=\(active.turn != nil ? "yes" : "STUN-only"))", category: "Calls")
    }

    private func handleRemoteOffer(_ offer: Shared_Proto_Signaling_V1_CallOffer, for session: CallSession) async {
        guard let active, active.session == session else { return }
        do {
            let sdp = try CallSignalCrypto.shared.decryptField(offer.sdp, from: session.peerUserId)
            try ensureWebRTC(role: .callee)
            guard let webrtc = active.webrtc else {
                throw WebRTCSessionError.invalidState("WebRTC nil after ensureWebRTC")
            }
            try await webrtc.setRemoteOffer(sdp: sdp)
            let answerSdp = try await webrtc.createAnswer()
            guard !answerSdp.isEmpty else {
                throw WebRTCSessionError.invalidState("createAnswer returned empty SDP")
            }
            sendAnswer(sdp: answerSdp)
            active.answeredAt = Date()
            state = .active(session)
            PerformanceMetrics.shared.end(.callSetupStart, endEvent: .callSetupEnd, label: String(session.id.prefix(8)))
        } catch {
            Log.error("Failed to handle offer: \(error)", category: "Calls")
            endActiveCall(reason: .local("Offer handling failed"))
        }
    }

    private func handleRemoteAnswer(_ answer: Shared_Proto_Signaling_V1_CallAnswer, for session: CallSession) async {
        guard let active, active.session == session else { return }
        do {
            let sdp = try CallSignalCrypto.shared.decryptField(answer.sdp, from: session.peerUserId)
            try ensureWebRTC(role: .caller)
            try await active.webrtc?.setRemoteAnswer(sdp: sdp)
            active.answeredAt = Date()
            state = .active(session)
            PerformanceMetrics.shared.end(.callSetupStart, endEvent: .callSetupEnd, label: String(session.id.prefix(8)))
            #if os(iOS)
            CallKitProvider.shared.reportOutgoingCallConnected(uuid: session.uuid)
            #endif
        } catch {
            Log.error("Failed to handle answer: \(error)", category: "Calls")
            endActiveCall(reason: .local("Answer handling failed"))
        }
    }

    private func handleRemoteIceCandidate(_ c: Shared_Proto_Signaling_V1_IceCandidate, for session: CallSession) async {
        guard let active, active.session == session else { return }
        do {
            let candidateSdp = try CallSignalCrypto.shared.decryptField(c.candidate, from: session.peerUserId)
            try ensureWebRTC(role: active.session.direction == .outgoing ? .caller : .callee)
            let ice = WebRTCIceCandidate(sdp: candidateSdp, sdpMid: c.sdpMid, sdpMLineIndex: Int32(c.sdpMLineIndex))
            try await active.webrtc?.addRemoteIceCandidate(ice)
        } catch {
            Log.error("Failed to add ICE candidate: \(error)", category: "Calls")
        }
    }

    private func handleRemoteIceCandidateBatch(_ batch: Shared_Proto_Signaling_V1_IceCandidateBatch, for session: CallSession) async {
        for c in batch.candidates {
            await handleRemoteIceCandidate(c, for: session)
        }
    }

    // MARK: - E2EE Call Signal via MessagingService

    /// Send a `WebRTCSignal` proto to `peerUserId` via MessagingService (Double Ratchet E2EE).
    /// Feeds raw proto bytes into the Rust orchestrator via `OutgoingCallSignal` event.
    /// Rust encrypts + packs WirePayload and returns `SendEncryptedMessage` action,
    /// which is handled by `MessageRouter.executeRustActions`.
    private func sendCallSignalProto(_ signal: Shared_Proto_Signaling_V1_WebRTCSignal, to peerUserId: String) {
        guard let protoData = try? signal.serializedData() else {
            Log.error("Failed to serialize WebRTCSignal proto", category: "Calls")
            return
        }
        guard CryptoManager.shared.orchestratorCore != nil else {
            Log.error("No orchestratorCore — cannot send call signal", category: "Calls")
            return
        }
        let messageId = UUID().uuidString
        let event = CfeIncomingEvent.outgoingCallSignal(
            contactId: peerUserId,
            messageId: messageId,
            protoBytes: protoData
        )
        do {
            let actions = try CryptoManager.shared.handleOrchestratorEvent(event, tag: "outgoing_call_signal")
            // sendEncryptedMessage action is handled by MessageRouter.executeRustActions;
            // here we execute it directly since we're outside the normal message routing path.
            for action in actions {
                switch action {
                case .sendEncryptedMessage(let to, let payload, let msgId, _):
                    let currentUserId = AuthSessionManager.shared.currentUserId ?? ""
                    Task {
                        do {
                            _ = try await MessagingServiceClient.shared.sendMessage(
                                messageId: msgId,
                                recipientId: to,
                                senderId: currentUserId,
                                conversationId: "",
                                encryptedPayload: payload,
                                timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                                senderDeviceId: Self.currentDeviceId(),
                                contentType: .callSignal
                            )
                            Log.info("WebRTCSignal sent via Rust E2EE to=\(to.prefix(8))… callId=\(signal.callID.prefix(8))…", category: "Calls")
                        } catch {
                            Log.error("Failed to send WebRTCSignal: \(error)", category: "Calls")
                        }
                    }
                case .saveSessionToSecureStore(let key, _):
                    // Persist updated session state after Rust encrypt.
                    if key.hasPrefix("session_") {
                        let contactId = String(key.dropFirst("session_".count))
                        CryptoManager.shared.saveSessionToKeychain(for: contactId)
                        CryptoManager.shared.saveOrchestratorStateCFE()
                    }
                case .notifyError(let code, let msg):
                    Log.error("Rust call signal error [\(code)]: \(msg)", category: "Calls")
                default:
                    break
                }
            }
        } catch {
            Log.error("Rust handleEvent(outgoingCallSignal) failed: \(error)", category: "Calls")
        }
    }

    /// Decode `WebRTCSignal` proto from decrypted binary data returned by Rust `CallSignalDecrypted`.
    static func decodeSignalProto(from data: Data) -> Shared_Proto_Signaling_V1_WebRTCSignal? {
        try? Shared_Proto_Signaling_V1_WebRTCSignal(serializedBytes: data)
    }

    /// Handle a decrypted `WebRTCSignal` proto received via MessagingService.
    func handleCallSignalProto(from senderUserId: String, signal: Shared_Proto_Signaling_V1_WebRTCSignal) {
        Log.info("handleCallSignalProto type=\(signal.signal.map { "\($0)" } ?? "none") from=\(senderUserId.prefix(8))… callId=\(signal.callID.prefix(8))…", category: "Calls")

        switch signal.signal {
        case .offer(let offer):
            handleIncomingCallOffer(callId: signal.callID, callerUserId: senderUserId,
                                    callerName: offer.callerUserID.isEmpty ? nil : offer.callerUserID,
                                    sdp: offer.sdp)
        case .answer(let answer):
            guard let active, active.session.id == signal.callID else { return }
            let sdp = answer.sdp
            Task {
                do {
                    Log.info("Received E2EE answer SDP, setting remote description", category: "Calls")
                    try await active.webrtc?.setRemoteAnswer(sdp: sdp)
                    await MainActor.run { [weak self] in
                        guard let self, let active = self.active, active.session.id == signal.callID else { return }
                        self.state = .active(active.session)
                        active.answeredAt = Date()
                    }
                } catch {
                    Log.error("Failed to set remote answer: \(error)", category: "Calls")
                }
            }
        case .iceCandidate(let ice):
            guard let active, active.session.id == signal.callID else { return }
            // ICE candidate SDP is always CallSignalCrypto-encrypted before sending.
            // Decrypt it here (stream path decrypts in handleRemoteIceCandidate).
            guard let candidateSdp = try? CallSignalCrypto.shared.decryptField(ice.candidate, from: senderUserId) else {
                Log.error("Failed to decrypt E2EE ICE candidate from \(senderUserId.prefix(8))… — dropping", category: "Calls")
                return
            }
            let c = WebRTCIceCandidate(sdp: candidateSdp, sdpMid: ice.sdpMid, sdpMLineIndex: Int32(ice.sdpMLineIndex))
            // Buffer ICE candidates until the remote offer has been applied.
            // addRemoteIceCandidate silently fails when there's no remote description.
            if active.pendingRemoteOfferSdp != nil {
                active.pendingIceCandidates.append(c)
                Log.debug("Buffered E2EE ICE candidate (pending SDP)", category: "Calls")
            } else {
                Task { try? await active.webrtc?.addRemoteIceCandidate(c) }
            }
        case .iceCandidates(let batch):
            guard let active, active.session.id == signal.callID else { return }
            for ice in batch.candidates {
                guard let candidateSdp = try? CallSignalCrypto.shared.decryptField(ice.candidate, from: senderUserId) else {
                    Log.error("Failed to decrypt E2EE ICE candidate (batch) from \(senderUserId.prefix(8))… — dropping", category: "Calls")
                    continue
                }
                let c = WebRTCIceCandidate(sdp: candidateSdp, sdpMid: ice.sdpMid, sdpMLineIndex: Int32(ice.sdpMLineIndex))
                if active.pendingRemoteOfferSdp != nil {
                    active.pendingIceCandidates.append(c)
                } else {
                    Task { try? await active.webrtc?.addRemoteIceCandidate(c) }
                }
            }
            if active.pendingRemoteOfferSdp != nil {
                Log.debug("Buffered \(batch.candidates.count) E2EE ICE candidates (pending SDP)", category: "Calls")
            }
        case .hangup(let hangup):
            guard active?.session.id == signal.callID else { return }
            endActiveCall(reason: .hangup(hangup.reason), reportToCallKit: true)
        case .busy:
            guard active?.session.id == signal.callID else { return }
            endActiveCall(reason: .hangup(.busy), reportToCallKit: true)
        case .ringing:
            guard let active, active.session.id == signal.callID else { return }
            if case .dialing = state { state = .ringing(active.session) }
        case .mediaUpdate, nil:
            break
        }
    }

    /// Handle an incoming call offer (SDP received via E2EE message before user answers).
    private func handleIncomingCallOffer(callId: String, callerUserId: String, callerName: String?, sdp: String) {
        // If we already have a call from VoIP push, attach SDP to it.
        if let active, active.session.id == callId, case .incoming = active.session.direction {
            active.pendingRemoteOfferSdp = sdp
            Log.info("Stored pending SDP for existing call callId=\(callId.prefix(8))…", category: "Calls")
            return
        }
        // No existing call — create from message-based offer.
        let uuid = UUID()
        let name = callerName ?? "Incoming Call"
        let session = CallSession(id: callId, uuid: uuid, peerUserId: callerUserId, peerName: name, direction: .incoming)
        begin(session: session, initialState: .incoming(session))
        active?.pendingRemoteOfferSdp = sdp
        Log.info("Incoming call via E2EE offer from \(callerUserId.prefix(8))… callId=\(callId.prefix(8))…", category: "Calls")
        #if os(iOS)
        let reportedUUID = CallKitProvider.shared.reportIncomingCall(
            callId: callId, callerId: callerUserId, callerName: name, hasVideo: false
        )
        active?.close()
        let adjusted = CallSession(id: callId, uuid: reportedUUID, peerUserId: callerUserId, peerName: name, direction: .incoming)
        active = ActiveCall(session: adjusted)
        active?.pendingRemoteOfferSdp = sdp
        state = .incoming(adjusted)
        #endif
    }

    private func sendAnswer(sdp: String) {
        guard let active else { return }
        var answer = Shared_Proto_Signaling_V1_CallAnswer()
        answer.sdp = sdp
        answer.answererDeviceID = Self.currentDeviceId()
        answer.answererUserID = AuthSessionManager.shared.currentUserId ?? ""
        answer.answeredAt = Self.nowMs()
        var sig = Shared_Proto_Signaling_V1_WebRTCSignal()
        sig.callID = active.session.id
        sig.senderDeviceID = Self.currentDeviceId()
        sig.timestamp = Self.nowMs()
        sig.signal = .answer(answer)
        sendCallSignalProto(sig, to: active.session.peerUserId)
        Log.info("Answer (proto) sent via E2EE to \(active.session.peerUserId.prefix(8))…", category: "Calls")
    }

    private func sendOffer(toUserId: String) async throws {
        guard let active else { throw RPCError(code: .failedPrecondition, message: "No active call") }
        try ensureWebRTC(role: .caller)
        let plainSdp = try await active.webrtc?.createOffer() ?? ""
        var offer = Shared_Proto_Signaling_V1_CallOffer()
        offer.sdp = plainSdp
        offer.callType = .audio
        offer.callerDeviceID = Self.currentDeviceId()
        offer.callerUserID = AuthSessionManager.shared.currentUserId ?? ""
        offer.offeredAt = Self.nowMs()
        var sig = Shared_Proto_Signaling_V1_WebRTCSignal()
        sig.callID = active.session.id
        sig.senderDeviceID = Self.currentDeviceId()
        sig.timestamp = Self.nowMs()
        sig.signal = .offer(offer)
        sendCallSignalProto(sig, to: toUserId)
        Log.info("Offer (proto) sent via E2EE to \(toUserId.prefix(8))… call_id=\(active.session.id.prefix(8))…", category: "Calls")
    }

    /// ICE candidates are batched with a 200ms debounce before sending to stay under the
    /// server's 10/sec signal rate limit. A burst of 10 candidates uses 1 signal slot, not 10.
    private func sendIceCandidate(_ c: WebRTCIceCandidate) {
        guard let active else { return }
        let peerUserId = active.session.peerUserId
        var ice = Shared_Proto_Signaling_V1_IceCandidate()
        do {
            ice.candidate = try CallSignalCrypto.shared.encryptField(c.sdp, for: peerUserId)
        } catch {
            Log.error("Failed to encrypt ICE candidate: \(error) — dropping", category: "Calls")
            return
        }
        ice.sdpMid = c.sdpMid
        ice.sdpMLineIndex = UInt32(max(0, c.sdpMLineIndex))

        if active.stream != nil {
            // Queue and flush as a batch after 200ms debounce.
            active.pendingOutgoingIce.append(ice)
            active.iceFlushTask?.cancel()
            active.iceFlushTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled, let self, let active = self.active else { return }
                let batch = active.pendingOutgoingIce
                guard !batch.isEmpty else { return }
                active.pendingOutgoingIce.removeAll()
                active.iceFlushTask = nil
                if let stream = active.stream {
                    if batch.count == 1 {
                        stream.send(Self.makeRoutedSignal(callId: active.session.id, deviceId: Self.currentDeviceId(), signal: .iceCandidate(batch[0])))
                    } else {
                        var candidates = Shared_Proto_Signaling_V1_IceCandidateBatch()
                        candidates.candidates = batch
                        stream.send(Self.makeRoutedSignal(callId: active.session.id, deviceId: Self.currentDeviceId(), signal: .iceCandidates(candidates)))
                    }
                    Log.debug("Flushed \(batch.count) ICE candidate(s) via stream (call_id=\(active.session.id.prefix(8))…)", category: "Calls")
                } else {
                    // Stream closed before flush — send via E2EE.
                    for candidate in batch {
                        var sig = Shared_Proto_Signaling_V1_WebRTCSignal()
                        sig.callID = active.session.id
                        sig.senderDeviceID = Self.currentDeviceId()
                        sig.timestamp = Self.nowMs()
                        sig.signal = .iceCandidate(candidate)
                        self.sendCallSignalProto(sig, to: peerUserId)
                    }
                }
            }
        } else {
            // No stream (E2EE-only call path) — send ICE via DR-encrypted message.
            var sig = Shared_Proto_Signaling_V1_WebRTCSignal()
            sig.callID = active.session.id
            sig.senderDeviceID = Self.currentDeviceId()
            sig.timestamp = Self.nowMs()
            sig.signal = .iceCandidate(ice)
            sendCallSignalProto(sig, to: peerUserId)
        }
    }

    // MARK: - Message Builders

    private static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000.0)
    }

    private static func currentDeviceId() -> String {
        AuthSessionManager.shared.currentDeviceId ?? (KeychainManager.shared.loadDeviceID() ?? "")
    }

    private static func makePing(timestampMs: Int64) -> Shared_Proto_Signaling_V1_SignalRequest {
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

    private static func makeCallHangup(
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
