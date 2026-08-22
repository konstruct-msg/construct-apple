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

    private enum CallEndSource: String {
        case inAppEndButton = "ui_end_button"
        case inAppDeclineButton = "ui_decline_button"
        case callKit = "callkit"
        case programmatic = "programmatic"
    }

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

    private func hasRecentlyEnded(callId: String) -> Bool {
        guard let endedAt = endedCallIds[callId] else { return false }
        return Date().timeIntervalSince(endedAt) < Self.endedCallMemory
    }

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
        #endif
    }

    // MARK: - Outgoing (stub)

    func startOutgoingCall(to userId: String, displayName: String, hasVideo: Bool = false) async {
        guard CallsFeature.isEnabled else {
            Log.info("Calls disabled — ignoring outgoing call request", category: "Calls")
            return
        }

        // Client-authoritative mutuality (sealed-sender future): only local contacts.
        // Server reciprocity cannot survive when the server does not see the caller.
        let ctx = PersistenceController.shared.container.viewContext
        if !ContactPolicy.isCallableContact(userId, in: ctx) {
            Log.info(
                "SECURITY[call_gate]: outgoing call blocked — not a local contact \(userId.prefix(8))…",
                category: "Calls"
            )
            lastError = NSLocalizedString("call_error_not_contacts", comment: "")
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

        // Call metadata is nested under "construct_call" by the server
        // (ApnsPayload::voip_incoming_call) — read it from there, not the flat payload,
        // or call_id/caller_id are missing and we fall back to the random reportedUUID /
        // "Unknown" (the bug that made the callee's signaling use a call_id the server
        // never created). Keep the flat payload as a defensive fallback.
        let callData = (payload["construct_call"] as? [AnyHashable: Any]) ?? payload
        let callId  = (callData["call_id"]  as? String) ?? reportedUUID.uuidString
        let callerId = (callData["caller_id"] as? String) ?? "Unknown"

        // Client-side block + mutuality on the VoIP path. iOS already forced us to report the
        // call to CallKit synchronously in the PushKit delegate (or the app is terminated), so
        // we cannot simply drop it — instead report it ended immediately so a blocked /
        // non-contact never actually rings. See sealed-sender-authenticated-transitional.
        let pushCtx = PersistenceController.shared.container.viewContext
        if BlockedContacts.isBlocked(callerId, in: pushCtx)
            || !ContactPolicy.isCallableContact(callerId, in: pushCtx) {
            Log.info(
                "SECURITY[call_gate]: incoming push from non-callable \(callerId.prefix(8))… — reporting ended (callId=\(callId.prefix(8))…)",
                category: "Calls"
            )
            #if os(iOS)
            CallKitProvider.shared.reportCallEnded(uuid: reportedUUID)
            #endif
            return
        }

        let isBusyState: Bool = {
            switch state {
            case .active, .connecting, .dialing, .ringing: return true
            default: return false
            }
        }()
        switch incomingPushDisposition(
            hasActiveCall: active != nil,
            isBusyState: isBusyState,
            matchesTrackedCallId: active?.session.id == callId
        ) {
        case .declineBusy:
            // `begin()` would silently close the active call via active?.close() — don't let that happen.
            Log.info("Busy — declining second incoming push (uuid=\(reportedUUID.uuidString.prefix(8))…)", category: "Calls")
            #if os(iOS)
            // PushKit already reported this to CallKit synchronously; tell it the call ended.
            CallKitProvider.shared.reportCallEnded(uuid: reportedUUID)
            #endif
            return

        case .alreadyTracking:
            // The E2EE offer beat the push and this call already holds its SDP and whatever ICE
            // buffered behind it. `begin()` here would replace the ActiveCall and drop both.
            Log.info(
                "Push for a call we already track (callId=\(callId.prefix(8))…) — keeping the offer and its buffered ICE",
                category: "Calls"
            )
            PerformanceMetrics.shared.record(.incomingPushDuplicate, label: "offer_first")
            return

        case .beginNewCall:
            break
        }

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
                if let pendingSdp = self.active?.usableRemoteOfferSdp {
                    try await self.applyOfferAndAnswer(sdp: pendingSdp, for: active)
                    return
                }

                // No offer yet. The user has answered a call whose SDP has not arrived — the two
                // travel on different channels and the push can beat the offer by a wide margin.
                // Record that so the late offer can finish what this answer started, and bound the
                // wait so a call that never gets its SDP fails visibly instead of ringing forever.
                self.active?.awaitingOfferAfterAnswer = true
                try openStreamIfNeeded()
                sendRinging()
                Log.info("Answered before the offer arrived — waiting up to \(Int(Self.offerAfterAnswerTimeout))s for SDP (call_id=\(active.session.id.prefix(8))…)", category: "Calls")
                PerformanceMetrics.shared.record(.answerBeforeOffer, label: "wait")
                self.startOfferWaitTimeout(for: active)
            } catch {
                Log.error("Failed to accept call: \(error)", category: "Calls")
                endActiveCall(reason: .local("Accept failed"))
            }
        }
    }

    /// How long the callee waits for the SDP offer after answering. Generous on purpose: the offer
    /// rides the ordinary E2EE message stream and queues behind whatever else is on it — the
    /// 2026-08-05 case took 30 s behind a backlog. Past this the call is honestly failed rather
    /// than left ringing on both sides.
    static let offerAfterAnswerTimeout: TimeInterval = 45

    /// Apply a remote offer and send the answer. The single authority for that sequence: it runs
    /// both when the offer beat the user's tap and when it arrived after it, and those two used to
    /// be one implementation and one silent gap.
    private func applyOfferAndAnswer(sdp: String, for call: ActiveCall) async throws {
        guard let webrtc = active?.webrtc else {
            throw WebRTCSessionError.invalidState("WebRTC not ready after ensureWebRTC")
        }
        try await webrtc.setRemoteOffer(sdp: sdp)
        active?.pendingRemoteOfferSdp = nil
        active?.awaitingOfferAfterAnswer = false
        active?.offerWaitTimeout?.cancel()
        active?.offerWaitTimeout = nil
        Log.info("Applied pending E2EE offer SDP", category: "Calls")

        // Drain ICE candidates that arrived before the offer was applied.
        let buffered = active?.pendingIceCandidates ?? []
        if !buffered.isEmpty {
            Log.info("Draining \(buffered.count) buffered ICE candidate(s)", category: "Calls")
            for ice in buffered {
                try? await webrtc.addRemoteIceCandidate(ice)
            }
            active?.pendingIceCandidates = []
        }

        let answerSdp = try await webrtc.createAnswer()
        guard !answerSdp.isEmpty else {
            throw WebRTCSessionError.invalidState("createAnswer returned empty SDP")
        }
        guard active === call else {
            Log.info("Call changed during answer build — discarding stale answer", category: "Calls")
            return
        }
        sendAnswer(sdp: answerSdp)
        active?.answeredAt = Date()
        state = .active(call.session)
        Log.info("E2EE incoming call answered: SDP exchanged", category: "Calls")
        // Note: no reportOutgoingCallConnected here — this is the callee.
        // CallKit promotes an incoming call to connected via the fulfilled
        // CXAnswerCallAction. reportOutgoingCallConnected is for the caller.
        // Open stream so callee ICE candidates reach the caller via the
        // signaling relay instead of the E2EE fallback path.
        try? openStreamIfNeeded()
        // Server expects a ringing event on the signaling stream — without it
        // the call is reaped as `calleeOffline` ~7s after iceConnected, killing
        // an otherwise-working media tunnel. Send it even though the SDP answer
        // already went via E2EE; the server treats ringing as a presence beacon.
        sendRinging()
    }

    /// Fail the call if the SDP never arrives after the user answered.
    private func startOfferWaitTimeout(for call: ActiveCall) {
        call.offerWaitTimeout?.cancel()
        call.offerWaitTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.offerAfterAnswerTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard let self, self.active === call, call.awaitingOfferAfterAnswer else { return }
            Log.error("Answered call never received its SDP offer in \(Int(Self.offerAfterAnswerTimeout))s — ending (call_id=\(call.session.id.prefix(8))…)", category: "Calls")
            PerformanceMetrics.shared.record(.answerBeforeOffer, label: "timeout")
            self.endActiveCall(reason: .local("No offer received"))
        }
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

    /// Answer the current incoming call from in-app UI (bypasses CallKit transaction).
    func answerIncomingCall() {
        guard let active, case .incoming = state else { return }
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

    /// End the call identified by `callUUID`.
    ///
    /// - Parameter source: Origin of the end request. Logged so postmortems can
    ///   distinguish explicit UI actions from CallKit/system-driven termination.
    private func end(callUUID: UUID, source: CallEndSource = .programmatic) {
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
            sendHangup(reason: reason)
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
            guard case .accept = signalStreamAdmission(for: s.signal) else {
                Log.error(
                    "SECURITY[call_gate]: refused SDP on the signaling stream (call_id=\(session.id.prefix(8))…) — offers and answers arrive E2EE only",
                    category: "Calls"
                )
                return
            }
            switch s.signal {
            case .ringing(let r):
                Log.info("Ringing device=\(r.deviceID.prefix(8))…", category: "Calls")
                state = .ringing(session)
            case .busy:
                Log.info("Busy", category: "Calls")
                endActiveCall(reason: .hangup(.busy))
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

    private func scheduleIceRestartIfNeeded() {
        guard let active else { return }
        guard active.mediaConnected else { return }
        guard active.session.direction == .outgoing else {
            Log.info("ICE disconnected on callee side — waiting for caller-driven restart", category: "Calls")
            return
        }
        guard active.webrtc != nil else { return }
        guard !active.isIceRestartInFlight else { return }
        guard active.iceRestartTask == nil else { return }
        guard active.iceRestartAttempts < NetworkTiming.Calls.maxIceRestartAttempts else {
            Log.error("ICE restart cap reached for call_id=\(active.session.id.prefix(8))…", category: "Calls")
            return
        }

        let expectedSessionId = active.session.id
        active.iceRestartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.active?.session.id == expectedSessionId {
                    self.active?.iceRestartTask = nil
                }
            }
            try? await Task.sleep(for: .seconds(NetworkTiming.Calls.iceRestartGraceDelay))
            guard !Task.isCancelled else { return }
            guard let active = self.active, active.session.id == expectedSessionId else { return }
            guard self.callQuality == .reconnecting else { return }
            await self.performIceRestart(for: active)
        }
        Log.info("ICE disconnected — scheduling restart for call_id=\(active.session.id.prefix(8))…", category: "Calls")
    }

    private func performIceRestart(for active: ActiveCall) async {
        guard self.active === active else { return }
        guard !active.isIceRestartInFlight else { return }
        guard active.iceRestartAttempts < NetworkTiming.Calls.maxIceRestartAttempts else { return }

        active.isIceRestartInFlight = true
        active.iceRestartAttempts += 1
        defer {
            if self.active === active {
                active.isIceRestartInFlight = false
            }
        }

        do {
            try? openStreamIfNeeded()
            guard let sdp = try await active.webrtc?.restartIce(), !sdp.isEmpty else {
                throw WebRTCSessionError.invalidState("restartIce returned empty SDP")
            }
            guard self.active === active else { return }
            sendOffer(sdp: sdp, toUserId: active.session.peerUserId, isIceRestart: true)
            Log.info(
                "ICE restart offer sent (attempt \(active.iceRestartAttempts)/\(NetworkTiming.Calls.maxIceRestartAttempts)) call_id=\(active.session.id.prefix(8))…",
                category: "Calls"
            )
        } catch {
            Log.error("ICE restart failed for call_id=\(active.session.id.prefix(8))…: \(error)", category: "Calls")
        }
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
                self.active?.iceRestartTask?.cancel()
                self.active?.iceRestartTask = nil
                self.active?.isIceRestartInFlight = false
                self.active?.iceRestartAttempts = 0
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
                CallAudioController.shared.notifyMediaConnected(hasAnswered: self.active?.answeredAt != nil)
                #endif
            }
        }
        webrtc.onQualityChanged = { [weak self] q in
            Task { @MainActor in
                guard let self else { return }
                self.callQuality = q
                switch q {
                case .reconnecting:
                    self.scheduleIceRestartIfNeeded()
                case .good:
                    self.active?.iceRestartTask?.cancel()
                    self.active?.iceRestartTask = nil
                }
            }
        }
        callQuality = .good   // reset for a fresh call
        active.webrtc = webrtc
        Log.info("WebRTC session created (role=\(role), turn=\(active.turn != nil ? "yes" : "STUN-only"))", category: "Calls")
    }

    /// Hold an offer for a call the user has not answered. The SDP goes where `answer()` looks for
    /// it, so consent is what starts negotiation — see `remoteOfferDisposition`.
    ///
    /// `offer.sdp` is plaintext by the time it is here, and there is one way for it to arrive:
    /// `handleCallSignalProto`, after the whole `WebRTCSignal` came out of the Double Ratchet.
    /// Until 2026-08-21 this went through `decryptSdp`, which took an unprefixed value and returned
    /// it unchanged, so the three writers of `pendingRemoteOfferSdp` disagreed about whether what
    /// they stored was ciphertext or not and none of them could tell. `pendingRemoteOfferSdp` holds
    /// plaintext SDP, from every path that writes it.
    private func holdRemoteOffer(_ offer: Shared_Proto_Signaling_V1_CallOffer, for call: ActiveCall) {
        let sdp = offer.sdp
        // Same refusal as the message path: holding an empty offer is what made `answer()` and the
        // ICE paths disagree about whether an offer was present at all.
        guard offerSdpIsUsable(sdp) else {
            Log.error(
                "Held offer for call \(call.session.id.prefix(8))… carries no SDP — ending rather than waiting on it",
                category: "Calls"
            )
            endActiveCall(reason: .local("Offer handling failed"))
            return
        }
        call.pendingRemoteOfferSdp = sdp
        Log.info(
            "Holding offer for unanswered call \(call.session.id.prefix(8))… — negotiation waits for the user (sdp=\(sdp.utf8.count)b)",
            category: "Calls"
        )
        // Already waiting on an SDP because the user answered first? Then consent exists and the
        // answer can finish now. Same transition `.resumeAnswer` makes on the push-less path.
        guard call.awaitingOfferAfterAnswer else { return }
        Log.info("Offer arrived after the user answered — resuming the answer (call_id=\(call.session.id.prefix(8))…)", category: "Calls")
        PerformanceMetrics.shared.record(.answerBeforeOffer, label: "resumed")
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.applyOfferAndAnswer(sdp: sdp, for: call)
            } catch {
                Log.error("Failed to answer with the late offer: \(error)", category: "Calls")
                self.endActiveCall(reason: .local("Accept failed"))
            }
        }
    }

    private func handleRemoteOffer(_ offer: Shared_Proto_Signaling_V1_CallOffer, for session: CallSession) async {
        guard let active, active.session == session else { return }
        do {
            // Plaintext already: the only caller is `handleCallSignalProto`, past the ratchet.
            let sdp = offer.sdp
            // Renegotiation path. `setRemoteOffer("")` would fail deeper in WebRTC with an error
            // that names neither the call nor the offer, so refuse it where both are still in hand.
            guard offerSdpIsUsable(sdp) else {
                throw WebRTCSessionError.invalidState("remote offer carries no SDP")
            }
            Log.info("Remote offer for \(session.id.prefix(8))… sdp=\(sdp.utf8.count)b", category: "Calls")
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
            // Only ever a *first* answer for an outgoing/glare call. A renegotiation of a call the
            // user already answered must not re-stamp this — `answeredAt` is what call duration and
            // the completed/missed verdict are computed from, so restamping it on an ICE restart
            // would report a two-minute call as ten seconds.
            if active.answeredAt == nil {
                active.answeredAt = Date()
                PerformanceMetrics.shared.end(.callSetupStart, endEvent: .callSetupEnd, label: String(session.id.prefix(8)))
            }
            state = .active(session)
        } catch {
            Log.error("Failed to handle offer: \(error)", category: "Calls")
            endActiveCall(reason: .local("Offer handling failed"))
        }
    }

    private func handleRemoteIceCandidate(_ c: Shared_Proto_Signaling_V1_IceCandidate, for session: CallSession) async {
        guard let active, active.session == session else { return }
        do {
            let candidateSdp = try CallSignalCrypto.shared.decryptCandidate(c.candidate, from: session.peerUserId)
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
    ///
    /// Stealth/sealed sender (hiding caller from server) is applied **after** Rust encryption,
    /// by wrapping the encrypted payload in SealedInner when StealthPolicy allows it.
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

        // Call signaling is in-scope for stealth (hides caller identity from the construct).
        // We apply SealedInner here at the transport layer (after Rust E2EE encryption of the signal).
        //
        // The signal is wrapped in a single KNST frame carrying content type 12 in byte 5 — inside
        // the ciphertext, so nothing on the wire says "this is a call". `SealedInner.content_type`
        // and the outer envelope both stay UNSPECIFIED. One whole frame, never chunked: an SDP
        // offer can exceed `chunkPayloadSize` and this producer sends exactly one message.
        // (VoIP push is unaffected — it comes from signaling-service's own RPC, not from this
        // envelope's type.) See decisions/sealed-content-type-inside-the-plaintext-frame.md.
        let event = CfeIncomingEvent.outgoingCallSignal(
            contactId: peerUserId,
            messageId: messageId,
            protoBytes: ChunkedMessageCodec.frameWhole(
                protoData, contentType: 12, messageId: UUID(uuidString: messageId) ?? UUID()
            )
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

                        // Apply stealth/sealed sender for call signals when policy allows.
                        // Uses dedicated helper with cache + proper logging.
                        let sealedInnerBytes = await buildSealedForCallSignalIfNeeded(recipient: to, payload: payload)

                        // Fail-closed: while stealth is on a call signal is sealed or dropped — never
                        // sent identified. The signal carries the real senderId to the server; leaking
                        // it defeats sealed sender. Privacy over availability: a call that cannot be
                        // established anonymously fails rather than silently deanonymizing the caller.
                        // The identified `else` below is therefore reachable only when stealth is off.
                        if StealthPolicy.shared.shouldUseSealedSender() && sealedInnerBytes == nil {
                            Log.error("Call signal: cannot seal (recipient IK/cert unavailable) — NOT sent identified, dropped to=\(to.prefix(8))… callId=\(callId.prefix(8))…", category: "Calls")
                            PerformanceMetrics.shared.record(.stealthSealFailure, label: "callSignal-dropped")
                            return
                        }

                        do {
                            if let sealedInnerBytes {
                                // Sealed call signal with one-shot enforce recovery: fresh
                                // token + tag on privacy_pass rejection, DR payload reused.
                                // Never downgrades to identified (StealthSendRecovery invariant).
                                _ = try await StealthSendRecovery.sendSealed(sealedInnerBytes, rebuild: {
                                    await self.buildSealedForCallSignalIfNeeded(recipient: to, payload: payload)
                                }, send: { inner in
                                    if FeatureFlags.sealedSenderUnauthenticatedTransport {
                                        // stealth-sealed-sender-v2 Phase 2: dedicated unauthenticated RPC/channel.
                                        return try await MessagingServiceClient.shared.sendSealedMessage(sealedInner: inner)
                                    } else {
                                        return try await MessagingServiceClient.shared.sendMessage(
                                            messageId: msgId,
                                            recipientId: to,
                                            senderId: currentUserId,
                                            conversationId: "",
                                            encryptedPayload: payload,
                                            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                                            senderDeviceId: Self.currentDeviceId(),
                                            contentType: .unspecified,
                                            sealedInnerBytes: inner
                                        )
                                    }
                                })
                            } else {
                                _ = try await MessagingServiceClient.shared.sendMessage(
                                    messageId: msgId,
                                    recipientId: to,
                                    senderId: currentUserId,
                                    conversationId: "",
                                    encryptedPayload: payload,
                                    timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                                    senderDeviceId: Self.currentDeviceId(),
                                    contentType: .unspecified,
                                    sealedInnerBytes: nil
                                )
                            }
                            let sealedNote = sealedInnerBytes != nil ? " [STEALTH]" : ""
                            Log.info("WebRTCSignal sent via Rust E2EE\(sealedNote) to=\(to.prefix(8))… callId=\(callId.prefix(8))…", category: "Calls")
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

    // MARK: - Stealth helpers for calls

    /// Short-lived cache of recipient identity keys during active calls.
    /// Avoids repeated bundle fetches for multiple signals (offer, ICE candidates, etc.).
    private var identityKeyCache: [String: Data] = [:]

    private func fetchRecipientIdentityKey(for userId: String) async -> Data? {
        if let cached = identityKeyCache[userId] {
            return cached
        }
        do {
            // Same pattern as profile shares / edits.
            // Identity key only (stealth sealing for call signals) — no OTPK. Calls ride the
            // existing Double Ratchet session; nothing here runs X3DH.
            let bundle = try await KeyServiceClient.shared.getPreKeyBundle(userId: userId, consumeOneTimePrekey: false)
            let key = bundle.identityPublic
            identityKeyCache[userId] = key
            return key
        } catch {
            Log.error("Calls: failed to fetch identity key for stealth to \(userId.prefix(8))… : \(error)", category: "Calls")
            return nil
        }
    }

    private func buildSealedForCallSignalIfNeeded(recipient: String, payload: Data) async -> Data? {
        guard StealthPolicy.shared.shouldUseSealedSender() else {
            return nil
        }

        guard let ik = await fetchRecipientIdentityKey(for: recipient) else {
            Log.info("STEALTH: no identity key for call signal to \(recipient.prefix(8))… — sending in clear", category: "Calls")
            return nil
        }

        do {
            let sealed = try await StealthSenderService.buildSealedInner(
                recipientUserId: recipient,
                recipientIdentityKey: ik,
                encryptedPayload: payload,
                contentType: .generic
            )
            Log.debug("STEALTH: built SealedInner for call signal (payload \(payload.count)b)", category: "Calls")
            return sealed
        } catch {
            Log.error("STEALTH: buildSealedInner failed for call signal to \(recipient.prefix(8))…: \(error)", category: "Calls")
            PerformanceMetrics.shared.record(.stealthSealFailure, label: "callSignal")
            return nil
        }
    }

    /// Call at end of a call to drop cached keys (privacy + memory).
    private func clearIdentityKeyCache() {
        identityKeyCache.removeAll()
    }


    /// Handle a decrypted `WebRTCSignal` proto received via MessagingService.
    func handleCallSignalProto(from senderUserId: String, signal: Shared_Proto_Signaling_V1_WebRTCSignal) {
        Log.info("handleCallSignalProto type=\(signal.signal.map { "\($0)" } ?? "none") from=\(senderUserId.prefix(8))… callId=\(signal.callID.prefix(8))…", category: "Calls")
        // Note: if the original wire message was sealed, the real sender was already resolved
        // in MessageRouter before the Rust decrypt action produced this .callSignalDecrypted.
        Log.debug("STEALTH: call signal received (sender resolution happened upstream if sealed)", category: "Calls")

        // Client-side block + mutuality. Under sealed sender the server can't see the caller,
        // so it does not stop a non-contact from ringing you — drop every call signal here.
        let signalCtx = PersistenceController.shared.container.viewContext
        if BlockedContacts.isBlocked(senderUserId, in: signalCtx)
            || !ContactPolicy.isCallableContact(senderUserId, in: signalCtx) {
            Log.info(
                "SECURITY[call_gate]: dropped call signal from non-callable \(senderUserId.prefix(8))… (callId=\(signal.callID.prefix(8))…)",
                category: "Calls"
            )
            return
        }

        switch signal.signal {
        case .offer(let offer):
            if let active, active.session.id == signal.callID {
                switch remoteOfferDisposition(
                    isIncomingCall: { if case .incoming = active.session.direction { return true } else { return false } }(),
                    hasAnswered: active.answeredAt != nil
                ) {
                case .holdUntilAnswered:
                    holdRemoteOffer(offer, for: active)
                case .renegotiate:
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        await self.handleRemoteOffer(offer, for: active.session)
                    }
                }
            } else {
                // Note: `offer.callerUserID` is a UUID, not a display name. Resolve via
                // local CoreData like the PushKit path does.
                handleIncomingCallOffer(callId: signal.callID, callerUserId: senderUserId,
                                        callerName: nil,
                                        sdp: offer.sdp)
                _ = offer  // currently unused; reserved for future video-flag etc.
            }
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
                    // Finalize the setup metric and promote CallKit out of "connecting"
                    // (otherwise the caller's lock-screen call UI stays stuck connecting).
                    // This is the only answer path now — the signaling-stream twin it used to
                    // keep parity with was deleted on 2026-08-21.
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
            guard let candidateSdp = try? CallSignalCrypto.shared.decryptCandidate(ice.candidate, from: senderUserId) else {
                Log.error("Failed to decrypt E2EE ICE candidate from \(senderUserId.prefix(8))… — dropping", category: "Calls")
                return
            }
            let c = WebRTCIceCandidate(sdp: candidateSdp, sdpMid: ice.sdpMid, sdpMLineIndex: Int32(ice.sdpMLineIndex))
            // Buffer ICE candidates until the remote offer has been applied.
            // addRemoteIceCandidate silently fails when there's no remote description.
            if active.usableRemoteOfferSdp != nil {
                active.pendingIceCandidates.append(c)
                Log.debug("Buffered E2EE ICE candidate (pending SDP)", category: "Calls")
            } else {
                Task { try? await active.webrtc?.addRemoteIceCandidate(c) }
            }
        case .iceCandidates(let batch):
            guard let active, active.session.id == signal.callID else { return }
            var buffered = 0
            for ice in batch.candidates {
                guard let candidateSdp = try? CallSignalCrypto.shared.decryptCandidate(ice.candidate, from: senderUserId) else {
                    Log.error("Failed to decrypt E2EE ICE candidate (batch) from \(senderUserId.prefix(8))… — dropping", category: "Calls")
                    continue
                }
                let c = WebRTCIceCandidate(sdp: candidateSdp, sdpMid: ice.sdpMid, sdpMLineIndex: Int32(ice.sdpMLineIndex))
                if active.usableRemoteOfferSdp != nil {
                    active.pendingIceCandidates.append(c)
                    buffered += 1
                } else {
                    Task { try? await active.webrtc?.addRemoteIceCandidate(c) }
                }
            }
            if buffered > 0 {
                Log.debug("Buffered \(buffered)/\(batch.candidates.count) E2EE ICE candidates (pending SDP)", category: "Calls")
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
    ///
    /// `sdp` is plaintext, like every other writer of `pendingRemoteOfferSdp` — see
    /// `holdRemoteOffer` for what the removed `decryptSdp` hop was hiding.
    private func handleIncomingCallOffer(callId: String, callerUserId: String, callerName: String?, sdp: String) {
        // Refused here rather than stored: an unusable offer that gets filed rings CallKit for a
        // call that cannot be negotiated, and the caller learns nothing until a human hangs up.
        guard offerSdpIsUsable(sdp) else {
            Log.error(
                "Incoming offer from \(callerUserId.prefix(8))… carries no SDP — not ringing for a call that cannot connect (callId=\(callId.prefix(8))…)",
                category: "Calls"
            )
            return
        }
        Log.info(
            "Incoming offer SDP from \(callerUserId.prefix(8))… callId=\(callId.prefix(8))… sdp=\(sdp.utf8.count)b",
            category: "Calls"
        )
        let matchingIncoming: ActiveCall? = {
            guard let active, active.session.id == callId,
                  case .incoming = active.session.direction else { return nil }
            return active
        }()

        switch callOfferDisposition(
            hasRecentlyEnded: hasRecentlyEnded(callId: callId),
            matchesActiveIncomingCall: matchingIncoming != nil,
            awaitingOfferAfterAnswer: matchingIncoming?.awaitingOfferAfterAnswer ?? false
        ) {
        case .ignoreCallEnded:
            Log.info("Ignoring offer for already-ended call \(callId.prefix(8))… — not re-reporting to CallKit", category: "Calls")
            PerformanceMetrics.shared.record(.callSignalAfterEnd, label: "offer")
            return

        case .storeForAnswer:
            matchingIncoming?.pendingRemoteOfferSdp = sdp
            Log.info("Stored pending SDP for existing call callId=\(callId.prefix(8))…", category: "Calls")
            return

        case .resumeAnswer:
            guard let call = matchingIncoming else { return }
            call.pendingRemoteOfferSdp = sdp
            Log.info("Offer arrived after the user answered — resuming the answer (call_id=\(callId.prefix(8))…)", category: "Calls")
            PerformanceMetrics.shared.record(.answerBeforeOffer, label: "resumed")
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.applyOfferAndAnswer(sdp: sdp, for: call)
                } catch {
                    Log.error("Failed to answer with the late offer: \(error)", category: "Calls")
                    self.endActiveCall(reason: .local("Accept failed"))
                }
            }
            return

        case .reportNewCall:
            break  // falls through to the glare check and the new-call path below
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
        // Was `?? ""`, which turned "there is no WebRTC session" into "an offer carrying no SDP"
        // and sent it. The callee has no way to tell that apart from a real offer: it files the
        // empty string, buffers ICE against it, and fails 45 s later. `createAnswer` and
        // `restartIce` have both refused an empty SDP for a while; the first offer was the one
        // path out of the three without the check.
        guard let webrtc = active.webrtc else {
            throw WebRTCSessionError.invalidState("WebRTC not ready after ensureWebRTC")
        }
        let plainSdp = try await webrtc.createOffer()
        sendOffer(sdp: plainSdp, toUserId: toUserId, isIceRestart: false)
    }

    private func sendOffer(sdp plainSdp: String, toUserId: String, isIceRestart: Bool) {
        guard let active else { return }
        // The one place every offer leaves through, so the refusal belongs here rather than at
        // each producer. An offer with no SDP cannot be negotiated by anybody; sending it only
        // moves the failure to the far side, where it looks like a network problem.
        //
        // Ending the call is right for the *first* offer — there is no call yet to protect, and
        // failing now is what the caller's own catch already does. It is wrong for an ICE restart:
        // that runs on a call the user is in, and `restartIce` deliberately only logs its failures
        // so a recoverable blip does not become a dropped call. Same refusal, different remedy.
        guard offerSdpIsUsable(plainSdp) else {
            Log.error(
                "Refusing to send an offer with no SDP to \(toUserId.prefix(8))… "
                + "(iceRestart=\(isIceRestart), call_id=\(active.session.id.prefix(8))…)",
                category: "Calls"
            )
            if !isIceRestart {
                endActiveCall(reason: .local("Offer build failed"))
            }
            return
        }
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
        let kind = isIceRestart ? "ICE restart offer" : "Offer"
        // sdp=<bytes> because nothing on either side measured it. The 2026-08-17 call had to be
        // reconstructed from which of two disagreeing checks fired; one number on each boundary
        // would have named it outright.
        Log.info(
            "\(kind) (proto) sent via E2EE to \(toUserId.prefix(8))… call_id=\(active.session.id.prefix(8))… sdp=\(plainSdp.utf8.count)b",
            category: "Calls"
        )
    }

    /// ICE candidates are batched with a 200ms debounce before sending to stay under the
    /// server's 10/sec signal rate limit. A burst of 10 candidates uses 1 signal slot, not 10.
    private func sendIceCandidate(_ c: WebRTCIceCandidate) {
        guard let active else { return }
        let peerUserId = active.session.peerUserId
        var ice = Shared_Proto_Signaling_V1_IceCandidate()
        do {
            ice.candidate = try CallSignalCrypto.shared.encryptCandidate(c.sdp, for: peerUserId)
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

            // Split the flush into size-bounded signals: each candidate field is an
            // v3 `CallSignalFrame` that can carry a PQ-ratchet blob on suite-3 sessions, so one
            // burst can exceed the Rust E2EE padding cap of 65536 bytes (observed on
            // device: a 134KB batch → CALL_SIGNAL_ENCRYPT_FAILED → the whole batch
            // silently lost). Chunks stay well under the cap, leaving headroom for the
            // outer WebRTCSignal proto + DR overhead. A burst of 24 candidates becomes
            // ~2–4 signals — still far below the server's 10/sec signal rate limit.
            let maxSignalBytes = 40_000
            var chunks: [[Shared_Proto_Signaling_V1_IceCandidate]] = []
            var current: [Shared_Proto_Signaling_V1_IceCandidate] = []
            var currentBytes = 0
            for candidate in batch {
                let size = candidate.candidate.count + candidate.sdpMid.utf8.count + 16
                if !current.isEmpty, currentBytes + size > maxSignalBytes {
                    chunks.append(current)
                    current = []
                    currentBytes = 0
                }
                current.append(candidate)
                currentBytes += size
            }
            if !current.isEmpty { chunks.append(current) }

            for chunk in chunks {
                var sig = Shared_Proto_Signaling_V1_WebRTCSignal()
                sig.callID = active.session.id
                sig.senderDeviceID = Self.currentDeviceId()
                sig.timestamp = Self.nowMs()
                if chunk.count == 1 {
                    sig.signal = .iceCandidate(chunk[0])
                } else {
                    var candidates = Shared_Proto_Signaling_V1_IceCandidateBatch()
                    candidates.candidates = chunk
                    sig.signal = .iceCandidates(candidates)
                }
                self.sendCallSignalProto(sig, to: peerUserId)
            }
            Log.info("Flushed \(batch.count) ICE candidate(s) in \(chunks.count) signal(s) via E2EE (call_id=\(active.session.id.prefix(8))…)", category: "Calls")
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
