//
//  CallManager.swift
//  Construct Messenger
//
//  Minimal scaffolding for calls (signaling + PushKit + CallKit).
//  Full WebRTC implementation will be layered in later.
//

import Foundation
import GRPCCore

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
    private var active: ActiveCall?

    private final class ActiveCall: @unchecked Sendable {
        let session: CallSession
        var stream: SignalStream?
        var turn: Shared_Proto_Signaling_V1_TurnCredentials?
        var webrtc: (any WebRTCSessionProtocol)?
        var keepaliveTask: Task<Void, Never>?
        var receiveTask: Task<Void, Never>?
        let startedAt: Date = Date()
        var answeredAt: Date? = nil

        init(session: CallSession) {
            self.session = session
        }

        func close() {
            keepaliveTask?.cancel()
            receiveTask?.cancel()
            webrtc?.close()
            webrtc = nil
            stream?.close()
            stream = nil
        }
    }

    private init() {
        #if os(iOS)
        VoIPPushManager.shared.onIncomingPush = { [weak self] payload in
            Task { @MainActor in self?.handleIncomingPush(payload) }
        }
        CallKitProvider.shared.onAnswer = { [weak self] uuid in
            Task { @MainActor in self?.answer(callUUID: uuid) }
        }
        CallKitProvider.shared.onEnd = { [weak self] uuid in
            Task { @MainActor in self?.end(callUUID: uuid) }
        }
        #endif
    }

    // MARK: - Outgoing (stub)

    func startOutgoingCall(to userId: String, displayName: String, hasVideo: Bool = false) async {
        guard CallsFeature.isEnabled else {
            Log.info("📞 Calls disabled — ignoring outgoing call request", category: "Calls")
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
            await CallKitProvider.shared.requestStartCall(
                uuid: uuid,
                calleeId: userId,
                calleeName: displayName,
                hasVideo: hasVideo
            )
            #endif

            let turn = try await SignalingServiceClient.shared.getTurnCredentials(callId: callId)
            active?.turn = turn
            Log.info("📞 TURN credentials ready for outgoing call (call_id=\(callId.prefix(8))…)", category: "Calls")

            try openStreamIfNeeded()

            try ensureWebRTC(role: .caller)
            try await sendOffer(toUserId: userId)
        } catch {
            Log.error("📞 Failed to fetch TURN credentials: \(error)", category: "Calls")
            endActiveCall(reason: .local("TURN credentials fetch failed"))
        }
    }

    // MARK: - Incoming (from PushKit)

    private func handleIncomingPush(_ payload: [AnyHashable: Any]) {
        guard CallsFeature.isEnabled else {
            Log.info("📞 Calls disabled — ignoring incoming VoIP push", category: "Calls")
            return
        }

        let callId = (payload["call_id"] as? String) ?? UUID().uuidString
        let callerId = (payload["caller_id"] as? String) ?? "Unknown"
        let callerName = (payload["caller_name"] as? String) ?? "Incoming Call"

        let uuid: UUID = {
            if let parsed = UUID(uuidString: callId) { return parsed }
            return UUID()
        }()

        let session = CallSession(
            id: callId,
            uuid: uuid,
            peerUserId: callerId,
            peerName: callerName,
            direction: .incoming
        )
        begin(session: session, initialState: .incoming(session))

        #if os(iOS)
        let reportedUUID = CallKitProvider.shared.reportIncomingCall(
            callId: callId,
            callerId: callerId,
            callerName: callerName,
            hasVideo: false
        )
        // Ensure we track the exact UUID CallKit uses even if call_id isn't a UUID string.
        active?.close()
        let adjusted = CallSession(
            id: callId,
            uuid: reportedUUID,
            peerUserId: callerId,
            peerName: callerName,
            direction: .incoming
        )
        active = ActiveCall(session: adjusted)
        state = .incoming(adjusted)
        #endif
    }

    // MARK: - CallKit Actions

    func answer(callUUID: UUID) {
        guard let active, active.session.uuid == callUUID else {
            Log.info("📞 Answer for unknown call uuid=\(callUUID.uuidString.prefix(8))…", category: "Calls")
            return
        }
        guard case .incoming = active.session.direction else { return }

        state = .connecting(active.session)

        Task {
            do {
                let turn = try await SignalingServiceClient.shared.getTurnCredentials(callId: active.session.id)
                self.active?.turn = turn
                try self.ensureWebRTC(role: .callee)
                try openStreamIfNeeded()
                sendRinging()
            } catch {
                Log.error("📞 Failed to accept call: \(error)", category: "Calls")
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

    func end(callUUID: UUID) {
        guard let active, active.session.uuid == callUUID else {
            Log.info("📞 End for unknown call uuid=\(callUUID.uuidString.prefix(8))…", category: "Calls")
            return
        }

        let reason: Shared_Proto_Signaling_V1_HangupReason
        if case .incoming = active.session.direction, case .incoming = state {
            reason = .declined
        } else {
            reason = .normal
        }

        Task {
            do {
                try openStreamIfNeeded()
                sendHangup(reason: reason)
            } catch {
                Log.error("📞 Failed to send hangup: \(error)", category: "Calls")
            }
            endActiveCall(reason: .hangup(reason), reportToCallKit: false)
        }
    }

    // MARK: - Internals

    private func begin(session: CallSession, initialState: CallState) {
        active?.close()
        active = ActiveCall(session: session)
        state = initialState
    }

    private func openStreamIfNeeded() throws {
        guard let active else { throw RPCError(code: .failedPrecondition, message: "No active call") }
        guard active.stream == nil else { return }

        let stream = try SignalingServiceClient.shared.openSignalStream()
        active.stream = stream

        // Keepalive ping every 25s (server closes idle streams).
        active.keepaliveTask?.cancel()
        active.keepaliveTask = Task { [weak active] in
            while !(Task.isCancelled) {
                try? await Task.sleep(nanoseconds: 25_000_000_000)
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
        }

        Log.info("📞 Signaling stream opened (call_id=\(active.session.id.prefix(8))…)", category: "Calls")
    }

    private func handleSignalResponse(_ response: Shared_Proto_Signaling_V1_SignalResponse, for session: CallSession) {
        switch response.response {
        case .pong:
            break
        case .error(let error):
            Log.error("📞 Signaling error: code=\(error.code) msg=\(error.message)", category: "Calls")
            endActiveCall(reason: .error(error.code))
        case .incomingCall(let call):
            // Fallback path if server delivers incoming-call notification while app is foreground.
            guard CallsFeature.isEnabled else { return }
            if case .idle = state {
                Log.info("📞 IncomingCallNotification received (call_id=\(call.callID.prefix(8))…)", category: "Calls")
                let payload: [AnyHashable: Any] = [
                    "call_id": call.callID,
                    "caller_id": call.callerID,
                    "caller_name": call.callerName
                ]
                handleIncomingPush(payload)
            }
        case .signal(let s):
            switch s.signal {
            case .offer(let offer):
                Task { @MainActor in
                    await self.handleRemoteOffer(offer, for: session)
                }
            case .ringing(let r):
                Log.info("📞 Ringing device=\(r.deviceID.prefix(8))…", category: "Calls")
                state = .ringing(session)
            case .busy:
                Log.info("📞 Busy", category: "Calls")
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
                Log.info("📞 Hangup reason=\(h.reason)", category: "Calls")
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
        state = .ended(session, reason)

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if case .ended = self.state { self.state = .idle }
        }

        CallHistoryService.shared.record(
            session: session,
            status: historyStatus,
            startedAt: startedAt,
            durationSeconds: duration
        )

        #if os(iOS)
        if reportToCallKit {
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
        let msg = Self.makeRoutedSignal(
            callId: active.session.id,
            deviceId: Self.currentDeviceId(),
            signal: .hangup(Self.makeCallHangup(deviceId: Self.currentDeviceId(), timestampMs: Self.nowMs(), reason: reason))
        )
        active.stream?.send(msg)
    }

    // MARK: - WebRTC (Phase 3)

    private func ensureWebRTC(role: WebRTCSessionRole) throws {
        guard let active else { throw RPCError(code: .failedPrecondition, message: "No active call") }
        if active.webrtc != nil { return }
        guard let turn = active.turn else { throw RPCError(code: .failedPrecondition, message: "Missing TURN credentials") }

        let webrtc = try WebRTCSession(role: role, turn: turn)
        webrtc.onLocalIceCandidate = { [weak self] c in
            Task { @MainActor in
                self?.sendIceCandidate(c)
            }
        }
        active.webrtc = webrtc
        Log.info("📞 WebRTC session created (role=\(role))", category: "Calls")
    }

    private func handleRemoteOffer(_ offer: Shared_Proto_Signaling_V1_CallOffer, for session: CallSession) async {
        guard let active, active.session == session else { return }
        do {
            let sdp = try CallSignalCrypto.shared.decryptField(offer.sdp, from: session.peerUserId)
            try ensureWebRTC(role: .callee)
            try await active.webrtc?.setRemoteOffer(sdp: sdp)
            let answerSdp = try await active.webrtc?.createAnswer() ?? ""
            sendAnswer(sdp: answerSdp)
            active.answeredAt = Date()
            state = .active(session)
        } catch {
            Log.error("📞 Failed to handle offer: \(error)", category: "Calls")
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
            #if os(iOS)
            CallKitProvider.shared.reportOutgoingCallConnected(uuid: session.uuid)
            #endif
        } catch {
            Log.error("📞 Failed to handle answer: \(error)", category: "Calls")
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
            Log.error("📞 Failed to add ICE candidate: \(error)", category: "Calls")
        }
    }

    private func handleRemoteIceCandidateBatch(_ batch: Shared_Proto_Signaling_V1_IceCandidateBatch, for session: CallSession) async {
        for c in batch.candidates {
            await handleRemoteIceCandidate(c, for: session)
        }
    }

    private func sendAnswer(sdp: String) {
        guard let active else { return }
        let peerUserId = active.session.peerUserId

        var answer = Shared_Proto_Signaling_V1_CallAnswer()
        do {
            answer.sdp = try CallSignalCrypto.shared.encryptField(sdp, for: peerUserId)
        } catch {
            Log.error("📞 Failed to encrypt answer SDP: \(error) — aborting send", category: "Calls")
            endActiveCall(reason: .local("Signal encryption failed"))
            return
        }
        answer.answererDeviceID = Self.currentDeviceId()
        answer.answererUserID = SessionManager.shared.currentUserId ?? ""
        answer.answeredAt = Self.nowMs()

        let msg = Self.makeRoutedSignal(
            callId: active.session.id,
            deviceId: Self.currentDeviceId(),
            signal: .answer(answer)
        )
        active.stream?.send(msg)
    }

    private func sendIceCandidate(_ c: WebRTCIceCandidate) {
        guard let active else { return }
        let peerUserId = active.session.peerUserId

        var ice = Shared_Proto_Signaling_V1_IceCandidate()
        do {
            ice.candidate = try CallSignalCrypto.shared.encryptField(c.sdp, for: peerUserId)
        } catch {
            Log.error("📞 Failed to encrypt ICE candidate: \(error) — dropping candidate", category: "Calls")
            return
        }
        ice.sdpMid = c.sdpMid
        ice.sdpMLineIndex = UInt32(max(0, c.sdpMLineIndex))

        let msg = Self.makeRoutedSignal(
            callId: active.session.id,
            deviceId: Self.currentDeviceId(),
            signal: .iceCandidate(ice)
        )
        active.stream?.send(msg)
    }

    private func sendOffer(toUserId: String) async throws {
        guard let active else { throw RPCError(code: .failedPrecondition, message: "No active call") }
        try ensureWebRTC(role: .caller)
        let plainSdp = try await active.webrtc?.createOffer() ?? ""
        let encryptedSdp = try CallSignalCrypto.shared.encryptField(plainSdp, for: toUserId)

        var offer = Shared_Proto_Signaling_V1_CallOffer()
        offer.sdp = encryptedSdp
        offer.callType = .audio
        offer.callerDeviceID = Self.currentDeviceId()
        offer.callerUserID = SessionManager.shared.currentUserId ?? ""
        offer.offeredAt = Self.nowMs()

        var rtc = Shared_Proto_Signaling_V1_WebRTCSignal()
        rtc.callID = active.session.id
        rtc.senderDeviceID = Self.currentDeviceId()
        rtc.timestamp = Self.nowMs()
        rtc.signal = .offer(offer)

        var route = Shared_Proto_Signaling_V1_SignalRoute()
        var user = Shared_Proto_Signaling_V1_UserTarget()
        user.userID = toUserId
        user.allDevices = true
        route.user = user

        var routed = Shared_Proto_Signaling_V1_RoutedWebRtcSignal()
        routed.signal = rtc
        routed.route = route

        var req = Shared_Proto_Signaling_V1_SignalRequest()
        req.request = .routedSignal(routed)

        active.stream?.send(req)
        Log.info("📞 Offer sent (to=\(toUserId.prefix(8))… call_id=\(active.session.id.prefix(8))…)", category: "Calls")
    }

    // MARK: - Message Builders

    private static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000.0)
    }

    private static func currentDeviceId() -> String {
        SessionManager.shared.currentDeviceId ?? (KeychainManager.shared.loadDeviceID() ?? "")
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
