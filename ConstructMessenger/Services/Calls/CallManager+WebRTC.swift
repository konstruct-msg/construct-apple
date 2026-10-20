//
//  CallManager+WebRTC.swift
//  Construct Messenger
//
//  Part of CallManager: WebRTC glue: ICE restart, WebRTC session setup, remote offer/candidates, sending answer/offer/ICE candidates.
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
    func scheduleIceRestartIfNeeded() {
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

    func performIceRestart(for active: ActiveCall) async {
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
            try sendOffer(sdp: sdp, toUserId: active.session.peerUserId, isIceRestart: true)
            Log.info(
                "ICE restart offer sent (attempt \(active.iceRestartAttempts)/\(NetworkTiming.Calls.maxIceRestartAttempts)) call_id=\(active.session.id.prefix(8))…",
                category: "Calls"
            )
        } catch {
            Log.error("ICE restart failed for call_id=\(active.session.id.prefix(8))…: \(error)", category: "Calls")
        }
    }

    // MARK: - WebRTC (Phase 3)

    func ensureWebRTC(role: WebRTCSessionRole) throws {
        guard let active else { throw RPCError(code: .failedPrecondition, message: "No active call") }
        if active.webrtc != nil { return }

        let webrtc = try WebRTCSession(role: role, turn: active.turn, video: CallsFeature.isVideoEnabled,
                                       veilOn: VeilProxyManager.shared.mode == .on)
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
                let firstConnect = self.active?.mediaConnected == false
                self.active?.mediaConnected = true
                self.active?.iceRestartTask?.cancel()
                self.active?.iceRestartTask = nil
                self.active?.isIceRestartInFlight = false
                self.active?.iceRestartAttempts = 0
                // Promote the call to "answered" server-side so the aggressive
                // ringing-without-answer reaper stops applying (E2EE answer never reaches
                // the signaling stream). Non-SDP presence signal; note_connected is idempotent.
                self.sendConnected()
                // The peer has assumed the camera is off; say otherwise. Again on every
                // reconnect, which costs one message and covers one lost on the way.
                if self.video.announcedCameraOn { self.sendMediaUpdate(cameraOn: true) }
                // Media is up — stop the ringback tone (its AVAudioEngine otherwise
                // holds the shared .playAndRecord playback bus and silences WebRTC's
                // voice-processing unit) and, as a safety net, enable audio if CallKit
                // never delivered didActivate. Idempotent — peerConnectionState may
                // bounce through .connected on reconnects.
                #if os(iOS)
                CallAudioController.shared.notifyMediaConnected(hasAnswered: self.active?.answeredAt != nil)
                if CallVideoAudio.movesToSpeakerWhenMediaConnects(
                    firstConnect: firstConnect,
                    isSending: self.video.canSend && self.video.localCameraOn,
                    outputIsEarpiece: Self.outputIsEarpiece()
                ) {
                    CallAudioController.setSpeaker(true)
                }
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
        // The caller's sender exists now; the callee's appears with the offer (`applyCamera`
        // again after `setRemoteOffer`). Through `setCameraOn`, so a video call asks for camera
        // access like the button does.
        if active.startsWithCamera { setCameraOn(true) } else { applyCamera() }
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
    func holdRemoteOffer(_ offer: Shared_Proto_Signaling_V1_CallOffer, for call: ActiveCall) {
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

    func handleRemoteOffer(_ offer: Shared_Proto_Signaling_V1_CallOffer, for session: CallSession) async {
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
            applyCamera()
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

    func handleRemoteIceCandidate(_ c: Shared_Proto_Signaling_V1_IceCandidate, for session: CallSession) async {
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

    func handleRemoteIceCandidateBatch(_ batch: Shared_Proto_Signaling_V1_IceCandidateBatch, for session: CallSession) async {
        for c in batch.candidates {
            await handleRemoteIceCandidate(c, for: session)
        }
    }

    func sendAnswer(sdp: String) {
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

    func sendOffer(toUserId: String) async throws {
        guard let active else { throw RPCError(code: .failedPrecondition, message: "No active call") }
        try await ensureSessionForOutgoingSignal(to: toUserId)
        guard self.active === active else {
            throw RPCError(code: .failedPrecondition, message: "Call replaced while waiting for session")
        }
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
        try sendOffer(sdp: plainSdp, toUserId: toUserId, isIceRestart: false)
    }

    func sendOffer(sdp plainSdp: String, toUserId: String, isIceRestart: Bool) throws {
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
                throw WebRTCSessionError.invalidState("Offer carries no SDP")
            }
            return
        }
        var offer = Shared_Proto_Signaling_V1_CallOffer()
        offer.sdp = plainSdp
        offer.callType = video.announcedCameraOn || active.startsWithCamera ? .video : .audio
        offer.callerDeviceID = Self.currentDeviceId()
        offer.callerUserID = AuthSessionManager.shared.currentUserId ?? ""
        offer.offeredAt = Self.nowMs()
        var sig = Shared_Proto_Signaling_V1_WebRTCSignal()
        sig.callID = active.session.id
        sig.senderDeviceID = Self.currentDeviceId()
        sig.timestamp = Self.nowMs()
        sig.signal = .offer(offer)
        let encrypt = sendCallSignalProto(sig, to: toUserId)
        let kind = isIceRestart ? "ICE restart offer" : "Offer"
        switch encrypt {
        case .encrypted:
            Log.info(
                "\(kind) (proto) sent via E2EE to \(toUserId.prefix(8))… call_id=\(active.session.id.prefix(8))… sdp=\(plainSdp.utf8.count)b",
                category: "Calls"
            )
        case .sessionMissing:
            Log.error(
                "\(kind) not encrypted — no session with \(toUserId.prefix(8))… (call_id=\(active.session.id.prefix(8))…)",
                category: "Calls"
            )
            if !isIceRestart {
                throw RPCError(code: .failedPrecondition, message: "No session with contact")
            }
        case .failed:
            Log.error(
                "\(kind) encrypt failed to \(toUserId.prefix(8))… (call_id=\(active.session.id.prefix(8))…)",
                category: "Calls"
            )
            if !isIceRestart {
                throw RPCError(code: .internalError, message: "Call offer encrypt failed")
            }
        }
    }

    /// ICE candidates are batched with a 200ms debounce before sending to stay under the
    /// server's 10/sec signal rate limit. A burst of 10 candidates uses 1 signal slot, not 10.
    func sendIceCandidate(_ c: WebRTCIceCandidate) {
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
            // `CallSignalFrame` carrying a whole wire payload (a PQ-ratchet blob on suite-3
            // sessions, a KEM identity answer until the peer proves itself), so one
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
}
