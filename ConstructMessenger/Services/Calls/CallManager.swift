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
final class CallManager: CallUIManaging {
    static let shared = CallManager()

    private(set) var state: CallState = .idle
    private(set) var lastError: String? = nil
    /// Coarse network health for the active call. `good` is the normal
    /// state; flips to `reconnecting` while WebRTC sees `iceConnectionState
    /// .disconnected` (transient network blip). Resets to `good` on every
    /// new call so a stale value from a previous call never leaks into the UI.
    private(set) var callQuality: CallQuality = .good

    func clearLastError() { lastError = nil }

    private var active: ActiveCall?

    /// Serializes outgoing E2EE call-signal RPC sends so they reach the server in the
    /// order the orchestrator encrypted them (see `sendCallSignalProto`). Without this,
    /// rapid transitions (offer → candidates → hangup) spawn independent send Tasks that
    /// can race and deliver out of order (e.g. hangup before offer). Reset to `nil` at each
    /// call boundary (`begin`/`endActiveCall`) so it orders signals only within one call —
    /// a stalled send from a previous call must never block the next call's signaling.
    private var callSignalSendChain: Task<Void, Never>?

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
        /// True once WebRTC media (ICE/DTLS) has connected at least once. After this, a
        /// signaling-stream close must NOT tear down the call — media is P2P/TURN and
        /// independent of the signaling stream. The call ends only on iceConnectionState
        /// = failed (onConnectionFailed) or explicit hangup.
        var mediaConnected: Bool = false
        /// Signaling-stream reconnect attempts made *after* media was already connected.
        /// Capped to avoid a tight reconnect loop if the server keeps closing the stream.
        var postMediaStreamReconnects: Int = 0
        static let maxPostMediaReconnects = 5

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
            Task { @MainActor in self?.end(callUUID: uuid, fromCallKit: true) }
        }
        // Audio session lifecycle is owned by CallAudioController; CallKit's
        // didActivate/didDeactivate forward to it directly (see CallKitProvider).
        #endif
    }

    // MARK: - Outgoing (stub)

    func startOutgoingCall(to userId: String, displayName: String, hasVideo: Bool = false) async {
        guard CallsFeature.isEnabled else {
            Log.info("Calls disabled — ignoring outgoing call request", category: "Calls")
            return
        }

        // Busy / glare guard. Without this, `begin()` → `active?.close()` would tear down
        // an existing call to start the new outgoing one, and the subsequent
        // CXStartCallAction fails with maximumCallGroupsReached (Code 7) — orphaning the
        // original call in CallKit ("Answer for unknown call"). Mirrors the guard in
        // `handleIncomingPush`, which `startOutgoingCall` was missing.
        if let active {
            // Glare: the same peer is already calling us → answer their call instead of
            // starting a competing outgoing one.
            if case .incoming = active.session.direction, active.session.peerUserId == userId {
                Log.info("Glare: outgoing request to \(userId.prefix(8))… while incoming from same peer — answering instead", category: "Calls")
                answer(callUUID: active.session.uuid)
                return
            }
            Log.info("Busy — ignoring outgoing call to \(userId.prefix(8))… (a call is already active)", category: "Calls")
            lastError = NSLocalizedString("call_error_busy", comment: "")
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
        guard let call = active else { return }
        #if os(iOS)
        // Arm the ringback tone; it starts once CallKit activates audio.
        CallAudioController.shared.notifyDialing()
        #endif

        // The setup below has several awaits. A simultaneous incoming offer from the
        // same peer (glare) replaces `active` with the incoming call via
        // handleIncomingCallOffer's tie-break-lose branch. Re-check `self.active === call`
        // after each await so we never apply TURN/stream/offer of this outgoing call to
        // the call that replaced it; bail out silently if it changed.
        do {
            #if os(iOS)
            try await CallKitProvider.shared.requestStartCall(
                uuid: uuid,
                calleeId: userId,
                calleeName: displayName,
                hasVideo: hasVideo
            )
            guard self.active === call else { Log.info("Call replaced during CallKit start — aborting outgoing setup", category: "Calls"); return }
            call.callKitRegistered = true
            #endif

            // Notify server: checks rate limits, delivers push/stream notification to callee.
            let initResp = try await SignalingServiceClient.shared.initiateCall(
                callId: callId,
                calleeUserId: userId,
                callerName: AuthSessionManager.shared.currentDisplayName,
                hasVideo: hasVideo
            )
            guard self.active === call else { Log.info("Call replaced during initiateCall — aborting outgoing setup", category: "Calls"); return }
            // calleeOnline=false is normal: idle users never have a signal stream open.
            // The server sends a VoIP push to wake the callee in this case.
            // Continue the call regardless — it will ring until the callee answers or
            // the server TTL expires (server sends an error signal when the call times out).
            Log.info("InitiateCall: calleeOnline=\(initResp.calleeOnline) (call_id=\(callId.prefix(8))…)", category: "Calls")

            let turn = await fetchTurnWithRetry(callId: callId)
            guard self.active === call else { Log.info("Call replaced during TURN fetch — aborting outgoing setup", category: "Calls"); return }
            if let turn {
                call.turn = turn
                Log.info("TURN credentials ready for outgoing call (call_id=\(callId.prefix(8))…)", category: "Calls")
            } else {
                Log.info("TURN unavailable after retries — proceeding STUN-only (call_id=\(callId.prefix(8))…)", category: "Calls")
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

    /// Fetch TURN credentials with quick retries before falling back to STUN-only.
    /// STUN-only is a near-guaranteed failure on mobile/symmetric NAT (no relay path →
    /// ICE can't connect or sustain), and a single getTurnCredentials over the shared
    /// gRPC channel fails transiently (channel churn / timeout). A bare `try?` silently
    /// degraded those transient failures into a doomed STUN-only call. Returns nil only
    /// after all attempts are exhausted.
    private func fetchTurnWithRetry(
        callId: String,
        attempts: Int = 3
    ) async -> Shared_Proto_Signaling_V1_TurnCredentials? {
        for attempt in 1...attempts {
            do {
                let turn = try await SignalingServiceClient.shared.getTurnCredentials(callId: callId)
                if !turn.urls.isEmpty { return turn }
                Log.info("TURN fetch \(attempt)/\(attempts): empty urls (call_id=\(callId.prefix(8))…)", category: "Calls")
            } catch {
                Log.error("TURN fetch \(attempt)/\(attempts) failed (call_id=\(callId.prefix(8))…): \(error)", category: "Calls")
                // Rate limit is not a transient error — retrying immediately only burns the
                // per-user budget faster. Bail to STUN-only now (cached creds, when present,
                // are served before we ever reach this helper).
                if let rpc = error as? RPCError, rpc.code == .resourceExhausted {
                    Log.info("TURN rate-limited — not retrying (call_id=\(callId.prefix(8))…)", category: "Calls")
                    break
                }
            }
            if attempt < attempts {
                try? await Task.sleep(nanoseconds: 400_000_000 * UInt64(attempt))
            }
        }
        return nil
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

        // Call metadata is nested under "construct_call" by the server
        // (ApnsPayload::voip_incoming_call) — read it from there, not the flat payload,
        // or call_id/caller_id are missing and we fall back to the random reportedUUID /
        // "Unknown" (the bug that made the callee's signaling use a call_id the server
        // never created). Keep the flat payload as a defensive fallback.
        let callData = (payload["construct_call"] as? [AnyHashable: Any]) ?? payload
        let callId  = (callData["call_id"]  as? String) ?? reportedUUID.uuidString
        let callerId = (callData["caller_id"] as? String) ?? "Unknown"
        // Privacy: do NOT use caller_name from push payload (exposed to APNs infrastructure).
        // Resolve from local CoreData via `resolvedDisplayName` (profile-shared name →
        // server username → deterministic generated fallback). Never shows raw UUID.
        let callerName = Self.resolveContactDisplayName(userId: callerId)
            ?? NSLocalizedString("construct_app_name", comment: "")

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
        // begin() already created the ActiveCall and set state; just flag CallKit.
        active?.callKitRegistered = true
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
                let turn = await self.fetchTurnWithRetry(callId: active.session.id)
                // The call may have ended (hangup) or been replaced by a new call during
                // the TURN fetch await. Without this re-check the continuation would set
                // TURN/WebRTC and state on the wrong call (stale captured `active`).
                guard self.active === active else {
                    Log.info("Call changed during TURN fetch — aborting answer for \(callUUID.uuidString.prefix(8))…", category: "Calls")
                    return
                }
                if let turn {
                    self.active?.turn = turn
                    Log.info("TURN ready for incoming call", category: "Calls")
                } else {
                    Log.info("TURN unavailable after retries — proceeding STUN-only (incoming)", category: "Calls")
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
                    guard self.active === active else {
                        Log.info("Call changed during answer build — discarding stale answer", category: "Calls")
                        return
                    }
                    sendAnswer(sdp: answerSdp)
                    self.active?.answeredAt = Date()
                    self.state = .active(active.session)
                    Log.info("E2EE incoming call answered: SDP exchanged", category: "Calls")
                    // Note: no reportOutgoingCallConnected here — this is the callee.
                    // CallKit promotes an incoming call to connected via the fulfilled
                    // CXAnswerCallAction. reportOutgoingCallConnected is for the caller.
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

    /// Dismiss the post-call `.ended` overlay immediately, before the auto-clear
    /// timer (`endedAutoClearDelay`) fires. The in-call full-screen cover is
    /// driven by call state; transitioning back to `.idle` here lets it dismiss
    /// on tap instead of leaving the user staring at a phantom screen.
    func dismissEndedCall() {
        if case .ended = state { state = .idle }
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
            // Best-effort: open the signaling stream so the hangup also takes the fast
            // relay path. The hangup MUST be sent even if the stream can't open — it is
            // also sent via E2EE (sendHangup uses both), and skipping it leaves the peer
            // ringing until the server-side TTL.
            try? openStreamIfNeeded()
            sendHangup(reason: reason)
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
        // Start this call with a fresh signal-send chain. The chain only needs to order
        // signals WITHIN one call; carrying it across calls means a stalled send from the
        // previous call (e.g. a hung sendMessage response) would block this call's offer.
        // Nil (don't cancel) so any still-in-flight send from the old call can finish.
        callSignalSendChain = nil
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
                guard self.active === active, active.stream === stream else { return }
                if active.mediaConnected {
                    // Media (WebRTC/TURN) is P2P and independent of the signaling stream.
                    // Closing the call here was the ~30s drop: the server closes the idle
                    // signaling stream and this teardown killed an otherwise-healthy call.
                    // Keep the call alive and reconnect the stream in the background (needed
                    // only for renegotiation/hangup; hangup also rides the E2EE path). The
                    // call ends only on iceConnectionState=failed (onConnectionFailed) or an
                    // explicit hangup. Capped to avoid a tight loop on repeated closes.
                    active.stream = nil
                    if active.postMediaStreamReconnects < ActiveCall.maxPostMediaReconnects {
                        active.postMediaStreamReconnects += 1
                        Log.info("Signaling stream closed but media is up — reconnecting (\(active.postMediaStreamReconnects)/\(ActiveCall.maxPostMediaReconnects)), keeping call", category: "Calls")
                        try? self.openStreamIfNeeded()
                    } else {
                        Log.info("Signaling stream closed but media is up — reconnect cap reached, keeping call on E2EE-only path", category: "Calls")
                    }
                } else {
                    Log.error("Signaling stream closed before media connected — ending call", category: "Calls")
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

    private func endActiveCall(reason: CallEndReason, reportToCallKit: Bool = true) {
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

    /// Tell the signaling server the call is genuinely established (media is up).
    /// In the E2EE flow the answer SDP travels over encrypted messaging, so the server
    /// never sees an `.answer` on the signaling stream and `answered_at_ms` stays nil —
    /// leaving the call under the aggressive "ringing without answer" reaper. This
    /// non-SDP presence signal sets `answered_at_ms` server-side (note_connected), moving
    /// the call to the lenient 60s keepalive reaper.
    private func sendConnected() {
        guard let active else { return }
        let msg = Self.makeRoutedSignal(
            callId: active.session.id,
            deviceId: Self.currentDeviceId(),
            signal: .connected(Self.makeCallConnected(deviceId: Self.currentDeviceId(), timestampMs: Self.nowMs()))
        )
        active.stream?.send(msg)
        Log.info("CallConnected presence sent (call_id=\(active.session.id.prefix(8))…)", category: "Calls")
    }

    private func sendHangup(reason: Shared_Proto_Signaling_V1_HangupReason) {
        guard let active else { return }
        var sig = Shared_Proto_Signaling_V1_WebRTCSignal()
        sig.callID = active.session.id
        sig.senderDeviceID = Self.currentDeviceId()
        sig.timestamp = Self.nowMs()
        sig.signal = .hangup(Self.makeCallHangup(deviceId: Self.currentDeviceId(), timestampMs: Self.nowMs(), reason: reason))
        // Send over BOTH channels. After media connects either side may have closed its idle
        // signaling stream (the call survives on the E2EE media path), so a stream-only hangup
        // is silently dropped and the peer stays "in call" — the user then has to hang up on
        // both ends. The E2EE messaging path is always connected (offers/answers ride it too);
        // the signaling stream is a best-effort fast path. The peer's hangup handler is
        // idempotent, so receiving it twice is a no-op.
        sendCallSignalProto(sig, to: active.session.peerUserId)
        if let stream = active.stream {
            stream.send(Self.makeRoutedSignal(callId: active.session.id, deviceId: Self.currentDeviceId(), signal: .hangup(Self.makeCallHangup(deviceId: Self.currentDeviceId(), timestampMs: Self.nowMs(), reason: reason))))
        }
        Log.info("Hangup sent (E2EE\(active.stream != nil ? "+stream" : "")) to \(active.session.peerUserId.prefix(8))… reason=\(reason)", category: "Calls")
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
                guard let self else { return }
                // Media path is up — from now on the call survives signaling-stream drops
                // (see receive-loop close handler in openStreamIfNeeded).
                self.active?.mediaConnected = true
                // Promote the call to "answered" server-side so the aggressive
                // ringing-without-answer reaper stops applying (E2EE answer never reaches
                // the signaling stream). Non-SDP presence signal; note_connected is idempotent.
                self.sendConnected()
                // Media is up — stop the ringback tone (its AVAudioEngine otherwise
                // holds the shared .playAndRecord playback bus and silences WebRTC's
                // voice-processing unit) and, as a safety net, enable audio if CallKit
                // never delivered didActivate. Idempotent — peerConnectionState may
                // bounce through .connected on reconnects.
                #if os(iOS)
                CallAudioController.shared.notifyMediaConnected()
                #endif
            }
        }
        webrtc.onQualityChanged = { [weak self] q in
            Task { @MainActor in self?.callQuality = q }
        }
        callQuality = .good   // reset for a fresh call
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
            // The call may have ended/changed during the awaits above (hangup, or a new
            // call). Don't apply a stale answer or clobber the current call's state.
            guard self.active === active else {
                Log.info("Call changed during offer handling — discarding stale answer", category: "Calls")
                return
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
            // The call may have ended/changed during setRemoteAnswer.
            guard self.active === active else {
                Log.info("Call changed during answer handling — discarding stale state update", category: "Calls")
                return
            }
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
                    let callId = signal.callID
                    // Chain onto the previous send so the RPCs reach the server in the
                    // order the orchestrator encrypted them. The Task hops to @MainActor,
                    // so reads/writes of `callSignalSendChain` are serialized; `await
                    // previous?.value` enforces FIFO across the async sends.
                    let previous = self.callSignalSendChain
                    self.callSignalSendChain = Task { @MainActor in
                        await previous?.value
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
                            Log.info("WebRTCSignal sent via Rust E2EE to=\(to.prefix(8))… callId=\(callId.prefix(8))…", category: "Calls")
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
            // Note: `offer.callerUserID` is a UUID, not a display name. Resolve via
            // local CoreData like the PushKit path does.
            handleIncomingCallOffer(callId: signal.callID, callerUserId: senderUserId,
                                    callerName: nil,
                                    sdp: offer.sdp)
            _ = offer  // currently unused; reserved for future video-flag etc.
        case .answer(let answer):
            guard active?.session.id == signal.callID else { return }
            let sdp = answer.sdp
            let callId = signal.callID
            // Re-fetch `active` inside the @MainActor task rather than capturing it, so
            // setRemoteAnswer is applied to the CURRENT call's WebRTC (not a stale one if
            // the call changed between dispatch and execution), then re-guard after the
            // await before mutating state.
            Task { @MainActor [weak self] in
                guard let self, let active = self.active, active.session.id == callId else { return }
                do {
                    Log.info("Received E2EE answer SDP, setting remote description", category: "Calls")
                    try await active.webrtc?.setRemoteAnswer(sdp: sdp)
                    guard self.active === active else {
                        Log.info("Call changed during E2EE answer — discarding stale state update", category: "Calls")
                        return
                    }
                    self.state = .active(active.session)
                    active.answeredAt = Date()
                    // Parity with the stream-path handleRemoteAnswer: finalize the
                    // setup metric and promote CallKit out of "connecting" (otherwise
                    // the caller's lock-screen call UI stays stuck connecting).
                    PerformanceMetrics.shared.end(.callSetupStart, endEvent: .callSetupEnd, label: String(active.session.id.prefix(8)))
                    #if os(iOS)
                    CallKitProvider.shared.reportOutgoingCallConnected(uuid: active.session.uuid)
                    #endif
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
        case .connected, .mediaUpdate, nil:
            // .connected is a server-side presence marker forwarded over the signaling
            // stream (handled there); nothing to do on the E2EE path.
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
        // Glare: we have an OUTGOING call to the same peer and now receive THEIR offer
        // (both sides dialed simultaneously, each with its own callId). Deterministic
        // tie-break mirrors session init (higher userId stays INITIATOR): the higher
        // userId keeps its outgoing call and ignores the incoming offer; the lower userId
        // yields and answers. Without this both sides tear down their outgoing call and
        // the call never establishes.
        if let active, case .outgoing = active.session.direction, active.session.peerUserId == callerUserId {
            let myUserId = AuthSessionManager.shared.currentUserId ?? ""
            if myUserId > callerUserId {
                Log.info("Glare: keeping our outgoing call to \(callerUserId.prefix(8))… (tie-break win) — ignoring their offer", category: "Calls")
                return
            }
            Log.info("Glare: yielding our outgoing call to \(callerUserId.prefix(8))… (tie-break lose) — accepting their offer", category: "Calls")
            // End our outgoing call in CallKit before begin() replaces it. begin() →
            // active.close() only tears down WebRTC/stream, NOT the CallKit call. With
            // maximumCallGroups=1 the stale outgoing UUID would otherwise stay "active",
            // blocking the next CXStartCallAction with maximumCallGroupsReached and
            // leaving a phantom call on the lock screen.
            #if os(iOS)
            if active.callKitRegistered {
                CallKitProvider.shared.reportCallEnded(uuid: active.session.uuid)
            }
            #endif
            // fall through: begin() below closes our outgoing call and creates the incoming one.
        }
        // No existing call — create from message-based offer. Caller name is resolved
        // from local CoreData (profile-shared name → username → generated fallback);
        // never surface the raw UUID.
        let name = callerName
            ?? Self.resolveContactDisplayName(userId: callerUserId)
            ?? NSLocalizedString("call_incoming_audio", comment: "")
        // Report to CallKit FIRST so the session uses CallKit's UUID from the start —
        // avoids creating a provisional ActiveCall and immediately closing/recreating it.
        // callKitRegistered lets endActiveCall call reportCallEnded for this UUID, so the
        // next outgoing CXStartCallAction doesn't fail with maximumCallGroupsReached.
        #if os(iOS)
        let uuid = CallKitProvider.shared.reportIncomingCall(
            callId: callId, callerId: callerUserId, callerName: name, hasVideo: false
        )
        #else
        let uuid = UUID()
        #endif
        let session = CallSession(id: callId, uuid: uuid, peerUserId: callerUserId, peerName: name, direction: .incoming)
        begin(session: session, initialState: .incoming(session))
        active?.pendingRemoteOfferSdp = sdp
        #if os(iOS)
        active?.callKitRegistered = true
        #endif
        Log.info("Incoming call via E2EE offer from \(callerUserId.prefix(8))… callId=\(callId.prefix(8))…", category: "Calls")
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

        // Trickle candidates over E2EE (MessagingService) — the same reliable, queued
        // path the offer/answer/hangup use. The signaling-stream relay is real-time
        // with NO buffering: the two peers' signaling streams join the call at
        // different times (the callee's opens only when it answers), so candidates
        // flushed before the peer joined were dropped server-side → neither side ever
        // received the other's candidates → ICE stuck at `checking` → medialess,
        // silent call. E2EE delivery is persisted/queued, so it arrives regardless of
        // join order. Batch with a 200ms debounce to coalesce the initial burst.
        active.pendingOutgoingIce.append(ice)
        active.iceFlushTask?.cancel()
        active.iceFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self, let active = self.active else { return }
            let batch = active.pendingOutgoingIce
            guard !batch.isEmpty else { return }
            active.pendingOutgoingIce.removeAll()
            active.iceFlushTask = nil
            var sig = Shared_Proto_Signaling_V1_WebRTCSignal()
            sig.callID = active.session.id
            sig.senderDeviceID = Self.currentDeviceId()
            sig.timestamp = Self.nowMs()
            if batch.count == 1 {
                sig.signal = .iceCandidate(batch[0])
            } else {
                var candidates = Shared_Proto_Signaling_V1_IceCandidateBatch()
                candidates.candidates = batch
                sig.signal = .iceCandidates(candidates)
            }
            self.sendCallSignalProto(sig, to: peerUserId)
            Log.info("Flushed \(batch.count) ICE candidate(s) via E2EE (call_id=\(active.session.id.prefix(8))…)", category: "Calls")
        }
    }

    // MARK: - Message Builders

    private static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000.0)
    }

    private static func currentDeviceId() -> String {
        AuthSessionManager.shared.currentDeviceId ?? (KeychainManager.shared.loadDeviceID() ?? "")
    }

    /// Single source of truth for "what name do we show for an incoming call from
    /// `userId`?". Looks up the local `User` entity and returns its
    /// `resolvedDisplayName` (profile-shared real name → server username →
    /// deterministic generated fallback). Returns `nil` when the contact is
    /// completely unknown to this device.
    private static func resolveContactDisplayName(userId: String) -> String? {
        let ctx = PersistenceController.shared.container.viewContext
        let req = User.fetchRequest()
        req.predicate = NSPredicate(format: "id == %@", userId)
        req.fetchLimit = 1
        return (try? ctx.fetch(req))?.first?.resolvedDisplayName
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

    private static func makeCallConnected(deviceId: String, timestampMs: Int64) -> Shared_Proto_Signaling_V1_CallConnected {
        var c = Shared_Proto_Signaling_V1_CallConnected()
        c.deviceID = deviceId
        c.connectedAt = timestampMs
        return c
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
