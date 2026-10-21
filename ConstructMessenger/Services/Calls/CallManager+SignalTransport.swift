//
//  CallManager+SignalTransport.swift
//  Construct Messenger
//
//  Part of CallManager: E2EE call-signal transport: sending signals, recipient identity key cache, sealed-sender wrapping, and handling received signals.
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
    // MARK: - E2EE Call Signal via MessagingService

    enum CallSignalEncryptResult {
        case encrypted
        case sessionMissing
        case failed
    }

    /// Send a `WebRTCSignal` proto to `peerUserId` via MessagingService (Double Ratchet E2EE).
    /// Feeds raw proto bytes into the Rust orchestrator via `OutgoingCallSignal` event.
    /// Rust encrypts + packs WirePayload and returns `SendEncryptedMessage` action,
    /// which is handled by `MessageRouter.executeRustActions`.
    ///
    /// Stealth/sealed sender (hiding caller from server) is applied **after** Rust encryption,
    /// by wrapping the encrypted payload in SealedInner when StealthPolicy allows it.
    ///
    /// The RPC send is still fire-and-forget (chained). Encrypt is synchronous — the
    /// result tells the caller whether Rust produced a send, or whether there is no
    /// session to encrypt under (D858E6FE logged success after CALL_SIGNAL_ENCRYPT_FAILED).
    ///
    /// One envelope per device the signal goes to, each encrypted on that device's ratchet and
    /// sealed to that device's key. `devices` names them; nil asks the call it belongs to
    /// (`callSignalTargets`). Encrypted if any device got it; otherwise a missing session wins
    /// over a failure, since that is the one the caller can wait out.
    @discardableResult
    func sendCallSignalProto(_ signal: Shared_Proto_Signaling_V1_WebRTCSignal, to peerUserId: String,
                             devices: [String]? = nil) -> CallSignalEncryptResult {
        let targets = devices ?? callSignalTargets(callId: signal.callID, peerUserId: peerUserId)
        guard !targets.isEmpty else {
            Log.error("Call signal: no device of \(peerUserId.prefix(8))… to send to — no pinned identity key", category: "Calls")
            return .failed
        }
        let results = targets.map { sendCallSignalProto(signal, to: peerUserId, device: $0) }
        if results.contains(.encrypted) { return .encrypted }
        return results.contains(.sessionMissing) ? .sessionMissing : .failed
    }

    /// The devices a signal of call `callId` goes to: the call's own device once it has one, the
    /// devices its offer went to before that, the pinned device for a call we do not hold.
    func callSignalTargets(callId: String, peerUserId: String) -> [String] {
        let call = active.flatMap { $0.session.id == callId ? $0 : nil }
        return CallDeviceRouting.targets(
            chosen: call?.peerDevice,
            offered: call?.offeredDevices ?? [],
            pinned: SessionAddressing.pinnedDevice(ofPeer: peerUserId)
        )
    }

    /// Tell `devices` that the call was taken on another device of theirs — E2EE only. Never on
    /// the signaling stream: the server ends the whole call on any callee hangup.
    func releaseDevices(_ devices: [String], callId: String, peerUserId: String) {
        guard !devices.isEmpty else { return }
        var sig = Shared_Proto_Signaling_V1_WebRTCSignal()
        sig.callID = callId
        sig.senderDeviceID = Self.currentDeviceId()
        sig.timestamp = Self.nowMs()
        sig.signal = .hangup(Self.makeCallHangup(deviceId: Self.currentDeviceId(), timestampMs: sig.timestamp, reason: .acceptedElsewhere))
        sendCallSignalProto(sig, to: peerUserId, devices: devices)
        Log.info("Released \(devices.count) other device(s) of \(peerUserId.prefix(8))… — taken elsewhere (call_id=\(callId.prefix(8))…)", category: "Calls")
    }

    private func sendCallSignalProto(_ signal: Shared_Proto_Signaling_V1_WebRTCSignal, to peerUserId: String,
                                     device peerContactId: String) -> CallSignalEncryptResult {
        guard let protoData = try? signal.serializedData() else {
            Log.error("Failed to serialize WebRTCSignal proto", category: "Calls")
            return .failed
        }
        guard CryptoManager.shared.orchestratorCore != nil else {
            Log.error("No orchestratorCore — cannot send call signal", category: "Calls")
            return .failed
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
        // Seam: the orchestrator keeps sessions under a device id like the rest of the core.
        //
        // One device: the caller of this function chose it (`decisions/a-call-rings-every-device.md`).
        let event = CfeIncomingEvent.outgoingCallSignal(
            contactId: peerContactId,
            messageId: messageId,
            protoBytes: ChunkedMessageCodec.frameWhole(
                protoData, contentType: 12, messageId: UUID(uuidString: messageId) ?? UUID()
            )
        )
        do {
            let actions = try CryptoManager.shared.handleOrchestratorEvent(event, tag: "outgoing_call_signal")
            // sendEncryptedMessage action is handled by MessageRouter.executeRustActions;
            // here we execute it directly since we're outside the normal message routing path.
            var encryptResult: CallSignalEncryptResult = .failed
            for action in actions {
                switch action {
                case .sendEncryptedMessage(_, let payload, let msgId, _):
                    // The orchestrator names the peer by device, because that is what it keeps the
                    // session under. The server addresses accounts, so everything below sends to
                    // `peerUserId` — the id this function was called with. Taking the action's
                    // `to` here would hand the transport a device id it has no route for.
                    let to = peerUserId
                    encryptResult = .encrypted
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
                        let sealedInnerBytes = await buildSealedForCallSignalIfNeeded(recipient: to, device: peerContactId, payload: payload)

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
                                _ = try await StealthSendRecovery.sendSealed(sealedInnerBytes, rebuild: { afterCredentialRejection in
                                    await self.buildSealedForCallSignalIfNeeded(
                                        recipient: to,
                                        device: peerContactId,
                                        payload: payload,
                                        afterCredentialRejection: afterCredentialRejection
                                    )
                                }, send: { inner in
                                    try await MessagingServiceClient.shared.sendMessage(
                                        messageId: msgId,
                                        recipientId: to,
                                        senderId: currentUserId,
                                        conversationId: "",
                                        encryptedPayload: payload,
                                        timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                                        recipientDeviceId: peerContactId,
                                        contentType: .unspecified,
                                        sealing: .sealed(inner)
                                    )
                                })
                            } else {
                                _ = try await MessagingServiceClient.shared.sendMessage(
                                    messageId: msgId,
                                    recipientId: to,
                                    senderId: currentUserId,
                                    conversationId: "",
                                    encryptedPayload: payload,
                                    timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                                    recipientDeviceId: peerContactId,
                                    contentType: .unspecified,
                                    sealing: .identified(.stealthDisabled)
                                )
                            }
                            let sealedNote = sealedInnerBytes != nil ? " [STEALTH]" : ""
                            Log.info("WebRTCSignal sent via Rust E2EE\(sealedNote) to=\(to.prefix(8))… callId=\(callId.prefix(8))…", category: "Calls")
                        } catch {
                            Log.error("Failed to send WebRTCSignal: \(error)", category: "Calls")
                        }
                    }
                case .saveToSecureStore(let slot, _):
                    // Persist updated session state after Rust encrypt. This branch held a fourth
                    // copy of the `session_` prefix rule and did nothing at all for every other
                    // slot — silently, because a string key has no case the compiler can miss.
                    if case .session(let contactId) = slot {
                        CryptoManager.shared.saveSessionToKeychain(forDevice: contactId)
                        CryptoManager.shared.saveOrchestratorStateCFE()
                    }
                case .notifyError(let code, let msg):
                    Log.error("Rust call signal error [\(code)]: \(msg)", category: "Calls")
                    if case .retryAfterSession = callSignalEncryptDisposition(code: code, message: msg) {
                        encryptResult = .sessionMissing
                    }
                default:
                    break
                }
            }
            return encryptResult
        } catch {
            Log.error("Rust handleEvent(outgoingCallSignal) failed: \(error)", category: "Calls")
            return .failed
        }
    }

    /// Decode `WebRTCSignal` proto from decrypted binary data returned by Rust `CallSignalDecrypted`.
    static func decodeSignalProto(from data: Data) -> Shared_Proto_Signaling_V1_WebRTCSignal? {
        try? Shared_Proto_Signaling_V1_WebRTCSignal(serializedBytes: data)
    }

    // MARK: - Stealth helpers for calls


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

    private func buildSealedForCallSignalIfNeeded(
        recipient: String,
        device: String,
        payload: Data,
        afterCredentialRejection: Bool = false
    ) async -> Data? {
        guard StealthPolicy.shared.shouldUseSealedSender() else {
            return nil
        }

        // Sealed to the device the payload is encrypted for. The account's bundle names one
        // device the server picks, and a seal to another device's key is one this device cannot
        // open — the fallback serves only a device whose key is not stored here yet.
        var ik = SessionAddressing.identityKey(ofDevice: device)
        if ik?.isEmpty != false { ik = await fetchRecipientIdentityKey(for: recipient) }
        return await sealCallSignal(recipient: recipient, ik: ik ?? Data(), payload: payload,
                                    afterCredentialRejection: afterCredentialRejection)
    }

    private func sealCallSignal(recipient: String, ik: Data, payload: Data, afterCredentialRejection: Bool) async -> Data? {
        guard !ik.isEmpty else {
            Log.info("STEALTH: no identity key for call signal to \(recipient.prefix(8))… — sending in clear", category: "Calls")
            return nil
        }

        do {
            let sealed = try await StealthSenderService.buildSealedInner(
                recipientUserId: recipient,
                recipientIdentityKey: ik,
                encryptedPayload: payload,
                contentType: .generic,
                afterCredentialRejection: afterCredentialRejection
            )
            Log.debug("STEALTH: built SealedInner for call signal (payload \(payload.count)b)", category: "Calls")
            return sealed
        } catch {
            Log.error("STEALTH: buildSealedInner failed for call signal to \(recipient.prefix(8))…: \(error)", category: "Calls")
            PerformanceMetrics.shared.record(.stealthSealFailure, label: "callSignal")
            return nil
        }
    }

    /// A hangup or busy from one of the peer's devices. A decline anywhere ends the call and
    /// releases the other devices; busy on one device only takes that one out while others ring;
    /// taken elsewhere ends this device's ringing without telling the server, which would end
    /// the call for the device that took it.
    private func endFromPeer(reason: Shared_Proto_Signaling_V1_HangupReason, device: String, callId: String, peerUserId: String) {
        guard let call = active, call.session.id == callId else { return }
        if reason == .acceptedElsewhere {
            endActiveCall(reason: .hangup(.acceptedElsewhere), reportToCallKit: true)
            return
        }
        switch CallDeviceRouting.onHangup(from: device, reason: reason, chosen: call.peerDevice, offered: call.offeredDevices) {
        case .ignore:
            return
        case .dropDevice(let remaining):
            call.offeredDevices = remaining
            Log.info("Device \(device.prefix(8))… is busy — \(remaining.count) still ringing (call_id=\(callId.prefix(8))…)", category: "Calls")
        case .end(let release):
            releaseDevices(release, callId: callId, peerUserId: peerUserId)
            // Occupancy lives on signaling-service. The peer already knows (they sent
            // this); tell the server so a callback in the next few seconds is not
            // "Callee is busy" (AC92380B).
            sendHangup(reason: reason, origin: .remote)
            endActiveCall(reason: .hangup(reason), reportToCallKit: true)
        }
    }

    /// Call at end of a call to drop cached keys (privacy + memory).
    func clearIdentityKeyCache() {
        identityKeyCache.removeAll()
    }


    /// Handle a decrypted `WebRTCSignal` proto received via MessagingService. `device`: the
    /// sender's device the core opened it under — the only device id here a sender cannot
    /// choose (`sender_device_id` it writes itself, and the server does not check it).
    func handleCallSignalProto(from senderUserId: String, device: String, signal: Shared_Proto_Signaling_V1_WebRTCSignal) {
        Log.info("handleCallSignalProto type=\(signal.signal.map { "\($0)" } ?? "none") from=\(senderUserId.prefix(8))… callId=\(signal.callID.prefix(8))…", category: "Calls")
        // Note: if the original wire message was sealed, the real sender was already resolved
        // in MessageRouter before the Rust decrypt action produced this .callSignalDecrypted.
        Log.debug("STEALTH: call signal received (sender resolution happened upstream if sealed)", category: "Calls")

        // Client-side block + mutuality. Under sealed sender the server can't see the caller,
        // so it does not stop a non-contact from ringing you — drop every call signal here.
        if BlockedContacts.isBlocked(senderUserId)
            || !ContactPolicy.isCallableContact(senderUserId) {
            Log.info(
                "SECURITY[call_gate]: dropped call signal from non-callable \(senderUserId.prefix(8))… (callId=\(signal.callID.prefix(8))…)",
                category: "Calls"
            )
            return
        }

        // Once the call has its device, its siblings do not move it.
        if let active, active.session.id == signal.callID,
           !CallDeviceRouting.admits(device, chosen: active.peerDevice) {
            if case .answer? = signal.signal {
                // A second device answered after the first: release it, below.
            } else {
                Log.info("Call signal from \(device.prefix(8))…, not this call's device — ignored (call_id=\(signal.callID.prefix(8))…)", category: "Calls")
                return
            }
        }

        switch signal.signal {
        case .offer(let offer):
            if let active, active.session.id == signal.callID {
                if active.peerDevice == nil { active.peerDevice = device }
                switch remoteOfferDisposition(
                    isIncomingCall: { if case .incoming = active.session.direction { return true } else { return false } }(),
                    hasAnswered: active.answeredAt != nil
                ) {
                case .holdUntilAnswered:
                    ringAsOffered(offer, for: active)
                    takeUpVideoCall(offer, for: active)
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
                                        sdp: offer.sdp,
                                        hasVideo: CallVideoSignal.answersWithCamera(
                                            offerCallType: offer.callType, videoEnabled: CallsFeature.isVideoEnabled),
                                        callerDevice: device)
                if let active, active.session.id == signal.callID {
                    takeUpVideoCall(offer, for: active)
                }
            }
        case .answer(let answer):
            guard let call = active, call.session.id == signal.callID else { return }
            switch CallDeviceRouting.onAnswer(from: device, chosen: call.peerDevice, offered: call.offeredDevices) {
            case .releaseLate(let late):
                Log.info("Late answer from \(late.prefix(8))… — another device took the call", category: "Calls")
                releaseDevices([late], callId: signal.callID, peerUserId: senderUserId)
                return
            case .accept(let chosen, let release):
                call.peerDevice = chosen
                call.offeredDevices = []
                releaseDevices(release, callId: signal.callID, peerUserId: senderUserId)
            }
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
            guard let candidateSdp = try? CallSignalCrypto.shared.decryptCandidate(ice.candidate, fromDevice: device) else {
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
                guard let candidateSdp = try? CallSignalCrypto.shared.decryptCandidate(ice.candidate, fromDevice: device) else {
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
            endFromPeer(reason: hangup.reason, device: device, callId: signal.callID, peerUserId: senderUserId)
        case .busy:
            endFromPeer(reason: .busy, device: device, callId: signal.callID, peerUserId: senderUserId)
        case .ringing:
            guard let active, active.session.id == signal.callID else { return }
            if case .dialing = state { state = .ringing(active.session) }
        case .mediaUpdate(let update):
            guard active?.session.id == signal.callID,
                  let on = CallVideoSignal.remoteCameraOn(after: update) else { return }
            video.remoteCameraOn = on
            Log.info("Peer camera \(on ? "on" : "off") (call_id=\(signal.callID.prefix(8))…)", category: "Calls")
        case .connected, nil:
            // .connected is a server-side presence marker forwarded over the signaling
            // stream (handled there); nothing to do on the E2EE path.
            break
        }
    }
}
