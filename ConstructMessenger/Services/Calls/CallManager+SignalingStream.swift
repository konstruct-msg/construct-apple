//
//  CallManager+SignalingStream.swift
//  Construct Messenger
//
//  Part of CallManager: Signaling stream: opening it, keepalive, and handling server responses.
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
    func openStreamIfNeeded() throws {
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

        receiveSignals(from: stream, for: active)

        Log.info("Signaling stream connecting (call_id=\(active.session.id.prefix(8))…)", category: "Calls")
    }

    /// The receive loop: one message at a time, each handled on the main actor and awaited before
    /// the next is taken. Nothing the peer sends can queue ahead of a local hang-up — `end` runs
    /// as its own task and closes the media without waiting on this loop or the network (the
    /// Signal defect of 2026-10, where a flood of call events kept the hang-up from being
    /// processed; `HangupUnderFloodTests`).
    func receiveSignals(from stream: SignalStream, for active: ActiveCall) {
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
                let canReconnect = active.mediaConnected
                    ? active.postMediaStreamReconnects < ActiveCall.maxPostMediaReconnects
                    : active.streamRetryCount < ActiveCall.maxStreamRetries
                switch signalingStreamClosedDisposition(
                    mediaConnected: active.mediaConnected,
                    awaitingOfferAfterAnswer: active.awaitingOfferAfterAnswer,
                    canReconnect: canReconnect
                ) {
                case .reconnect:
                    active.stream = nil
                    if active.mediaConnected {
                        active.postMediaStreamReconnects += 1
                        Log.info("Signaling stream closed but media is up — reconnecting (\(active.postMediaStreamReconnects)/\(ActiveCall.maxPostMediaReconnects)), keeping call", category: "Calls")
                    } else {
                        active.streamRetryCount += 1
                        Log.info("Signaling stream closed before media — retrying (\(active.streamRetryCount)/\(ActiveCall.maxStreamRetries)), call stays up", category: "Calls")
                    }
                    try? self.openStreamIfNeeded()
                case .keepOnMessagePath:
                    active.stream = nil
                    Log.info(
                        active.mediaConnected
                            ? "Signaling stream closed but media is up — reconnect cap reached, keeping call on E2EE-only path"
                            : "Signaling stream closed before media — E2EE-only until the \(Int(Self.offerAfterAnswerTimeout))s offer wait decides",
                        category: "Calls"
                    )
                case .endCall:
                    Log.error("Signaling stream gone before media and nothing else bounds this call — ending", category: "Calls")
                    self.endActiveCall(reason: .local("Signal stream closed"))
                }
            }
        }
    }

    func handleSignalResponse(_ response: Shared_Proto_Signaling_V1_SignalResponse, for session: CallSession) {
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
                // `call.callerName` is server-supplied and empty since 2026-10-01 — the name is
                // resolved from our own contacts, as on the push path.
                let callerName = Self.resolveContactDisplayName(userId: call.callerID)
                    ?? NSLocalizedString("call_incoming_audio", comment: "")
                #if os(iOS)
                let reportedUUID = CallKitProvider.shared.reportIncomingCall(
                    callId: call.callID,
                    callerId: call.callerID,
                    callerName: callerName,
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
                    peerName: callerName,
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
}
