//
//  CallManager+Outgoing.swift
//  Construct Messenger
//
//  Part of CallManager: Outgoing calls: waiting for a session, starting a call, TURN credential fetch.
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
    /// Wait for a live Double Ratchet session before encrypting an outgoing offer.
    /// Does not start INITIATOR init immediately — a SESSION_RESET_INIT may already
    /// be running as RESPONDER (D858E6FE). `reestablishSessionForQueuedOutbound`
    /// no-ops when an init is in flight or a session already exists.
    func ensureSessionForOutgoingSignal(to userId: String) async throws {
        // The device the offer will actually be encrypted for — the pinned one, as call
        // signalling still is. Asking about any device of the account would answer yes on a
        // session this send cannot use.
        let signalDevice = SessionAddressing.pinnedDevice(ofPeer: userId)
        let holds = { signalDevice.map { CryptoManager.shared.hasSession(for: $0) } ?? false }
        switch outgoingCallSessionDisposition(hasSession: holds()) {
        case .encryptNow:
            return
        case .waitThenInit:
            break
        }
        Log.info(
            "No DR session with \(userId.prefix(8))… — waiting up to \(Int(NetworkTiming.Calls.sessionReadyWait))s before sending call signal",
            category: "Calls"
        )
        SessionLifecycleController.shared.reestablishSessionForQueuedOutbound(to: userId)
        let deadline = Date().addingTimeInterval(NetworkTiming.Calls.sessionReadyWait)
        while Date() < deadline {
            if holds() {
                Log.info("DR session ready for call signal to \(userId.prefix(8))…", category: "Calls")
                return
            }
            try? await Task.sleep(for: .seconds(NetworkTiming.Calls.sessionReadyPoll))
            if Task.isCancelled { throw CancellationError() }
            guard active != nil else {
                throw RPCError(code: .cancelled, message: "Call ended while waiting for session")
            }
        }
        throw RPCError(code: .failedPrecondition, message: "No session with contact")
    }

    // MARK: - Outgoing (stub)

    func startOutgoingCall(to userId: String, displayName: String, hasVideo: Bool = false) async {
        guard CallsFeature.isEnabled else {
            Log.info("Calls disabled — ignoring outgoing call request", category: "Calls")
            return
        }

        // Client-authoritative mutuality (sealed-sender future): only local contacts.
        // Server reciprocity cannot survive when the server does not see the caller.
        if !ContactPolicy.isCallableContact(userId) {
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
        call.startsWithCamera = hasVideo && CallsFeature.isVideoEnabled
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
            if let rpcError = error as? RPCError {
                switch rpcError.code {
                case .permissionDenied:
                    lastError = NSLocalizedString("call_error_not_contacts", comment: "")
                case .failedPrecondition where rpcError.message.contains("No session"):
                    lastError = NSLocalizedString("call_error_setup_failed", comment: "")
                default:
                    break
                }
            }
            // InitiateCall may already have occupied the callee. Tear down on the
            // signaling stream so they are not left ringing / we are not left "busy".
            guard self.active === call else { return }
            try? openStreamIfNeeded()
            sendHangup(reason: .normal, origin: .local)
            endActiveCall(reason: .local("Call setup failed"))
        }
    }

    /// Fetch TURN credentials with quick retries before falling back to STUN-only.
    /// STUN-only is a near-guaranteed failure on mobile/symmetric NAT (no relay path →
    /// ICE can't connect or sustain), and a single getTurnCredentials over the shared
    /// gRPC channel fails transiently (channel churn / timeout). A bare `try?` silently
    /// degraded those transient failures into a doomed STUN-only call. Returns nil only
    /// after all attempts are exhausted.
    func fetchTurnWithRetry(
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
}
