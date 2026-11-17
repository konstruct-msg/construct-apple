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

        // Busy / glare guard, by the machine (`dial`). Without it, `begin()` → `active?.close()`
        // would tear down an existing call to start the new outgoing one, and the subsequent
        // CXStartCallAction fails with maximumCallGroupsReached (Code 7) — orphaning the
        // original call in CallKit ("Answer for unknown call").
        // Use UUID string for call_id so it round-trips through CallKit cleanly.
        let uuid = UUID()
        let callId = uuid.uuidString
        switch withMachine({ $0.dial(callId: callId, peerUserId: userId, nowMs: Self.nowMs()) }) {
        case .answerInstead:
            // Glare: the same peer is already calling us → answer their call instead of
            // starting a competing outgoing one.
            Log.info("Glare: outgoing request to \(userId.prefix(8))… while incoming from same peer — answering instead", category: "Calls")
            if let active { answer(callUUID: active.session.uuid) }
            return
        case .busy:
            Log.info("Busy — ignoring outgoing call to \(userId.prefix(8))… (a call is already active)", category: "Calls")
            lastError = NSLocalizedString("call_error_busy", comment: "")
            return
        case .start:
            break
        }

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
        // the offer's `.replaceOutgoing` (glare, tie-break lost). Re-check `self.active === call`
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
                Log.info("TURN unavailable after retries — no relay for this call (call_id=\(callId.prefix(8))…)", category: "Calls")
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
            // InitiateCall may already have occupied the callee. The failure's hangup tells them
            // and the server (`endActiveCall`), on the stream too once it is open, so they are not
            // left ringing and we are not left "busy".
            guard self.active === call else { return }
            try? openStreamIfNeeded()
            endActiveCall(reason: .local("Call setup failed"))
        }
    }

    /// Fetch TURN credentials with quick retries. A single getTurnCredentials over the shared gRPC
    /// channel fails transiently (channel churn / timeout), and without TURN there is no call
    /// (`CallIcePlan`: never direct). Returns nil only after all attempts are exhausted.
    ///
    /// With VEIL `on` and the tunnel still coming up — a callee woken by its VoIP push — every try
    /// got `VeilTunnelNotUp`, and all three were spent in two seconds: the answer failed with no
    /// relay while the tunnel came up seconds later (2026-11-16, build 779: push 13:41:55, three
    /// failures by 13:42:00, the offer through the tunnel at 13:42:04). Now the fetch waits for the
    /// route once, as a token registration does, bounded by the machine's wait for an answered
    /// call's offer; the wait is not an attempt.
    func fetchTurnWithRetry(
        callId: String,
        attempts: Int = 3,
        fetch: (String) async throws -> Shared_Proto_Signaling_V1_TurnCredentials = {
            try await SignalingServiceClient.shared.getTurnCredentials(callId: $0)
        },
        waitForRoute: () async -> Bool = {
            await VeilTunnelWait.untilRouted(limit: TimeInterval(callTimings().offerWaitMs) / 1000)
        }
    ) async -> Shared_Proto_Signaling_V1_TurnCredentials? {
        var attempt = 1
        var waitedForRoute = false
        while attempt <= attempts {
            do {
                let turn = try await fetch(callId)
                if !turn.urls.isEmpty { return turn }
                Log.info("TURN fetch \(attempt)/\(attempts): empty urls (call_id=\(callId.prefix(8))…)", category: "Calls")
            } catch is VeilTunnelNotUp where !waitedForRoute {
                waitedForRoute = true
                Log.info("TURN fetch: waiting for the VEIL tunnel (call_id=\(callId.prefix(8))…)", category: "Calls")
                guard await waitForRoute() else {
                    Log.error("TURN fetch: the VEIL tunnel did not come up (call_id=\(callId.prefix(8))…)", category: "Calls")
                    return nil
                }
                continue
            } catch {
                Log.error("TURN fetch \(attempt)/\(attempts) failed (call_id=\(callId.prefix(8))…): \(error)", category: "Calls")
                // Rate limit is not a transient error — retrying immediately only burns the
                // per-user budget faster (cached creds, when present, are served before we ever
                // reach this helper).
                if let rpc = error as? RPCError, rpc.code == .resourceExhausted {
                    Log.info("TURN rate-limited — not retrying (call_id=\(callId.prefix(8))…)", category: "Calls")
                    break
                }
            }
            if attempt < attempts {
                try? await Task.sleep(nanoseconds: 400_000_000 * UInt64(attempt))
            }
            attempt += 1
        }
        return nil
    }
}
