//
//  CallManager+Incoming.swift
//  Construct Messenger
//
//  Part of CallManager: Incoming calls: PushKit push, CallKit answer, offer-after-answer and unanswered timeouts, E2EE offer intake.
//  Moved verbatim from CallManager.swift (TODO 183); stored state lives there.
//

import Foundation
import AVFoundation
import CoreData
import GRPCCore
import SwiftProtobuf
#if os(iOS)
import UIKit
#endif

extension CallManager {
    // MARK: - Incoming (from PushKit)

    func handleIncomingPush(_ payload: [AnyHashable: Any], reportedUUID: UUID) {
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
        if BlockedContacts.isBlocked(callerId)
            || !ContactPolicy.isCallableContact(callerId) {
            Log.info(
                "SECURITY[call_gate]: incoming push from non-callable \(callerId.prefix(8))… — reporting ended (callId=\(callId.prefix(8))…)",
                category: "Calls"
            )
            #if os(iOS)
            CallKitProvider.shared.reportCallEnded(uuid: reportedUUID)
            #endif
            return
        }

        switch incomingPushDisposition(
            hasActiveCall: active != nil,
            isBusyState: callStateIsBusy(state),
            matchesTrackedCallId: active?.session.id == callId,
            isGlareWithCaller: isOutgoingCall(to: callerId)
        ) {
        case .declineBusy:
            // `begin()` would silently close the active call via active?.close() — don't let that happen.
            Log.info("Busy — declining second incoming push (uuid=\(reportedUUID.uuidString.prefix(8))…)", category: "Calls")
            #if os(iOS)
            // PushKit already reported this to CallKit synchronously; tell it the call ended.
            CallKitProvider.shared.reportCallEnded(uuid: reportedUUID)
            #endif
            declineAsBusy(callId: callId, callerUserId: callerId)
            return

        case .deferToGlareTieBreak:
            Log.info("Push from \(callerId.prefix(8))… while our call to them is up — the offer's tie-break decides", category: "Calls")
            #if os(iOS)
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
            pullMissedCallSignalsIfNeeded()
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
        video.ringsAsVideo = CallVideoSignal.pushRingsAsVideo(callData, videoEnabled: CallsFeature.isVideoEnabled)
        pullMissedCallSignalsIfNeeded()

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
                // The offer is already on the server more often than not (7CDE9769: sent
                // the same second as the VoIP push). Don't wait for a zombie stream to
                // die — pull the backlog now.
                self.pullMissedCallSignalsIfNeeded()
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
    func applyOfferAndAnswer(sdp: String, for call: ActiveCall) async throws {
        guard let webrtc = active?.webrtc else {
            throw WebRTCSessionError.invalidState("WebRTC not ready after ensureWebRTC")
        }
        try await webrtc.setRemoteOffer(sdp: sdp)
        applyCamera()
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

    /// End an incoming call that is still ringing after `unansweredIncomingTimeout`.
    ///
    /// Nothing else ends it. The callee opens its signaling stream only on answer, so the server's
    /// reaper — which sends `ErrorToCaller` at 45 s without ringing, and `HangupBoth` only over a
    /// stream — never reaches a callee that has not answered. The caller's E2EE hangup usually does;
    /// a caller that crashed or lost the network sends none, and the call rang on — and now that
    /// `.incoming` counts as busy, it would refuse every later caller. Android ends it at 90 s with
    /// TIMEOUT; the
    /// same value here, so both platforms give up on one schedule.
    func startUnansweredTimeout(for call: ActiveCall) {
        call.unansweredTimeout?.cancel()
        call.unansweredTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(NetworkTiming.Calls.unansweredIncomingTimeout))
            guard !Task.isCancelled, let self, self.active === call, case .incoming = self.state else { return }
            Log.info("Incoming call unanswered for \(Int(NetworkTiming.Calls.unansweredIncomingTimeout))s — ending (call_id=\(call.session.id.prefix(8))…)", category: "Calls")
            self.sendHangup(reason: .timeout, origin: .local)
            self.endActiveCall(reason: .hangup(.timeout), reportToCallKit: true)
        }
    }

    /// Handle an incoming call offer (SDP received via E2EE message before user answers).
    ///
    /// `sdp` is plaintext, like every other writer of `pendingRemoteOfferSdp` — see
    /// `holdRemoteOffer` for what the removed `decryptSdp` hop was hiding.
    func handleIncomingCallOffer(callId: String, callerUserId: String, callerName: String?, sdp: String, hasVideo: Bool) {
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

        let isBusyWithAnotherCall = active.map { $0.session.id != callId } == true
            && callStateIsBusy(state)
            && !isOutgoingCall(to: callerUserId)

        switch callOfferDisposition(
            hasRecentlyEnded: hasRecentlyEnded(callId: callId),
            matchesActiveIncomingCall: matchingIncoming != nil,
            awaitingOfferAfterAnswer: matchingIncoming?.awaitingOfferAfterAnswer ?? false,
            isBusyWithAnotherCall: isBusyWithAnotherCall
        ) {
        case .declineBusy:
            Log.info("Busy — declining offer for a second call from \(callerUserId.prefix(8))… (callId=\(callId.prefix(8))…)", category: "Calls")
            declineAsBusy(callId: callId, callerUserId: callerUserId)
            return

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
            callId: callId, callerId: callerUserId, callerName: name, hasVideo: hasVideo
        )
        #else
        let uuid = UUID()
        #endif
        let session = CallSession(id: callId, uuid: uuid, peerUserId: callerUserId, peerName: name, direction: .incoming)
        begin(session: session, initialState: .incoming(session))
        video.ringsAsVideo = hasVideo
        active?.pendingRemoteOfferSdp = sdp
        #if os(iOS)
        active?.callKitRegistered = true
        #endif
        Log.info("Incoming call via E2EE offer from \(callerUserId.prefix(8))… callId=\(callId.prefix(8))…", category: "Calls")
    }
}
