//
//  SignalingServiceClient.swift
//  Construct Messenger
//
//  WebRTC signaling transport (gRPC) + TURN credentials helper.
//  Spec: CALLS_CLIENT_SPEC.md
//

import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2

/// Thin wrapper around `shared.proto.signaling.v1.SignalingService`.
///
/// This file intentionally does NOT implement WebRTC or CallKit yet.
/// It provides the transport primitives needed by the upcoming CallManager.
final class SignalingServiceClient: Sendable {
    static let shared = SignalingServiceClient()

    private let turnCache = TurnCredentialsCache()

    private init() {}

    // MARK: - TURN

    func getTurnCredentials(callId: String? = nil) async throws -> Shared_Proto_Signaling_V1_TurnCredentials {
        // TURN credentials are user-scoped, NOT call-scoped: the server derives them as
        // coturn-REST HMAC(secret, "<expiry>:<user_id>") — callId is not part of the
        // credential (see signaling-service turn.rs). So a still-valid credential is reusable
        // for any call until it expires. Reuse the cache across calls regardless of callId —
        // fetching fresh per call hammered the per-user TURN rate limiter, which returned
        // resourceExhausted on rapid back-to-back calls → STUN-only → failed/silent calls.
        if let cached = await turnCache.getIfValid() {
            return cached
        }

        let creds = try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.getTurnCredentials) { grpcClient in
            let client = Shared_Proto_Signaling_V1_SignalingService.Client(wrapping: grpcClient)
            var req = Shared_Proto_Signaling_V1_GetTurnCredentialsRequest()
            if let callId { req.callID = callId }
            let resp = try await client.getTurnCredentials(request: .init(message: req))
            return resp.credentials
        }

        await turnCache.store(creds)
        return creds
    }

    // MARK: - InitiateCall

    /// Registers a call attempt with the server. Must be called by the CALLER before
    /// sending the SDP offer. Server checks rate limits, mutual contacts and delivers
    /// IncomingCallNotification / VoIP push to the callee.
    ///
    /// - Returns: `calleeOnline` flag (true = callee has active Signal stream).
    @discardableResult
    func initiateCall(callId: String, calleeUserId: String, callerName: String, hasVideo: Bool) async throws -> Shared_Proto_Signaling_V1_InitiateCallResponse {
        return try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.initiateCall) { grpcClient in
            let client = Shared_Proto_Signaling_V1_SignalingService.Client(wrapping: grpcClient)
            var req = Shared_Proto_Signaling_V1_InitiateCallRequest()
            req.callID = callId
            req.calleeUserID = calleeUserId
            req.callerName = callerName
            req.callType = hasVideo ? .video : .audio
            let resp = try await client.initiateCall(request: .init(message: req))
            return resp
        }
    }

    // MARK: - Signal Stream

    /// Opens the bidirectional `Signal` stream using the shared persistent gRPC channel
    /// managed by `GRPCChannelManager`. The caller owns the returned handle and must
    /// call `close()` when the stream is no longer needed.
    ///
    /// Using the shared channel ensures the signaling stream:
    /// - shares the same HTTP/2 connection as message RPCs (no extra TLS handshake)
    /// - is automatically rerouted when the ICE relay changes (generation-based invalidation)
    /// - participates in the same failure tracking / cooldown logic as all other RPCs
    func openSignalStream() throws -> SignalStream {
        let grpcClient = try GRPCChannelManager.shared.acquireChannel()
        let client = Shared_Proto_Signaling_V1_SignalingService.Client(wrapping: grpcClient)

        let (outbound, outboundContinuation) = AsyncStream<Shared_Proto_Signaling_V1_SignalRequest>.makeStream()
        let (incoming, incomingContinuation) = AsyncStream<Shared_Proto_Signaling_V1_SignalResponse>.makeStream()
        let (accepted, acceptedContinuation) = AsyncStream<Void>.makeStream()

        let request = StreamingClientRequest<Shared_Proto_Signaling_V1_SignalRequest>(
            metadata: [],
            producer: { writer in
                for await msg in outbound {
                    try await writer.write(msg)
                }
            }
        )

        let streamTask = Task {
            do {
                try await client.signal(
                    request: request,
                    onResponse: { response in
                        let contents: StreamingClientResponse<Shared_Proto_Signaling_V1_SignalResponse>.Contents
                        switch response.accepted {
                        case .success(let c):
                            contents = c
                            acceptedContinuation.yield(())
                            acceptedContinuation.finish()
                        case .failure(let error):
                            acceptedContinuation.finish()
                            incomingContinuation.finish()
                            throw error
                        }

                        for try await part in contents.bodyParts {
                            switch part {
                            case .message(let msg):
                                incomingContinuation.yield(msg)
                            case .trailingMetadata:
                                break
                            }
                        }
                        incomingContinuation.finish()
                    }
                )
            } catch is CancellationError {
                acceptedContinuation.finish()
                incomingContinuation.finish()
            } catch {
                Log.error("Signaling stream closed with error: \(error)", category: "Calls")
                acceptedContinuation.finish()
                incomingContinuation.finish()
                throw error
            }
        }

        return SignalStream(
            streamTask: streamTask,
            outboundContinuation: outboundContinuation,
            accepted: accepted,
            incoming: incoming
        )
    }
}

// MARK: - TURN Cache

private actor TurnCredentialsCache {
    private var creds: Shared_Proto_Signaling_V1_TurnCredentials?

    func getIfValid(skewSeconds: TimeInterval = NetworkTiming.WebRTC.turnCredentialsSkewSeconds) -> Shared_Proto_Signaling_V1_TurnCredentials? {
        guard let creds else { return nil }
        guard creds.expiresAt > 0 else { return creds }
        let expiry = Date(timeIntervalSince1970: TimeInterval(creds.expiresAt) / 1000.0)
        if expiry.timeIntervalSinceNow > skewSeconds { return creds }
        return nil
    }

    func store(_ creds: Shared_Proto_Signaling_V1_TurnCredentials) {
        self.creds = creds
    }
}

// MARK: - Stream Handle

/// An owned signaling stream handle.
///
/// Uses the shared `GRPCChannelManager` persistent channel — the underlying HTTP/2
/// connection is NOT owned by this handle and must not be shut down here.
/// Closing the stream only finishes the outbound producer and cancels the stream RPC task.
///
/// - NOTE: This is a minimal transport handle. Call lifecycle/WebRTC binding will be layered on top.
final class SignalStream: @unchecked Sendable {
    let accepted: AsyncStream<Void>
    let incoming: AsyncStream<Shared_Proto_Signaling_V1_SignalResponse>

    private let streamTask: Task<Void, Error>
    private let outboundContinuation: AsyncStream<Shared_Proto_Signaling_V1_SignalRequest>.Continuation

    init(
        streamTask: Task<Void, Error>,
        outboundContinuation: AsyncStream<Shared_Proto_Signaling_V1_SignalRequest>.Continuation,
        accepted: AsyncStream<Void>,
        incoming: AsyncStream<Shared_Proto_Signaling_V1_SignalResponse>
    ) {
        self.streamTask = streamTask
        self.outboundContinuation = outboundContinuation
        self.accepted = accepted
        self.incoming = incoming
    }

    func send(_ message: Shared_Proto_Signaling_V1_SignalRequest) {
        outboundContinuation.yield(message)
    }

    func close() {
        // Finish outbound so the server receives a clean stream end.
        outboundContinuation.finish()
        // Cancel the stream RPC task (not the shared gRPC connection).
        streamTask.cancel()
    }
}
