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
        if let cached = await turnCache.getIfValid() {
            return cached
        }

        let creds = try await GRPCChannelManager.shared.performRPC { grpcClient in
            let client = Shared_Proto_Signaling_V1_SignalingService.Client(wrapping: grpcClient)
            var req = Shared_Proto_Signaling_V1_GetTurnCredentialsRequest()
            if let callId { req.callID = callId }
            let resp = try await client.getTurnCredentials(request: .init(message: req))
            return resp.credentials
        }

        await turnCache.store(creds)
        return creds
    }

    // MARK: - Signal Stream

    /// Opens the bidirectional `Signal` stream.
    ///
    /// The returned handle owns its own gRPC client + runConnections() task and must be closed.
    func openSignalStream() throws -> SignalStream {
        let grpcClient = try GRPCChannelManager.shared.makeClient()
        let client = Shared_Proto_Signaling_V1_SignalingService.Client(wrapping: grpcClient)

        let (outbound, outboundContinuation) = AsyncStream<Shared_Proto_Signaling_V1_SignalRequest>.makeStream()
        let (incoming, incomingContinuation) = AsyncStream<Shared_Proto_Signaling_V1_SignalResponse>.makeStream()

        let request = StreamingClientRequest<Shared_Proto_Signaling_V1_SignalRequest>(
            metadata: [],
            producer: { writer in
                for await msg in outbound {
                    try await writer.write(msg)
                }
            }
        )

        let connectTask = Task {
            try await grpcClient.runConnections()
        }

        let streamTask = Task {
            do {
                try await client.signal(
                    request: request,
                    onResponse: { response in
                        let contents: StreamingClientResponse<Shared_Proto_Signaling_V1_SignalResponse>.Contents
                        switch response.accepted {
                        case .success(let c):
                            contents = c
                        case .failure(let error):
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
                incomingContinuation.finish()
            } catch {
                Log.error("📞 Signaling stream closed with error: \(error)", category: "Calls")
                incomingContinuation.finish()
                throw error
            }
        }

        return SignalStream(
            grpcClient: grpcClient,
            connectTask: connectTask,
            streamTask: streamTask,
            outboundContinuation: outboundContinuation,
            incoming: incoming
        )
    }
}

// MARK: - TURN Cache

private actor TurnCredentialsCache {
    private var creds: Shared_Proto_Signaling_V1_TurnCredentials?

    func getIfValid(skewSeconds: TimeInterval = 60) -> Shared_Proto_Signaling_V1_TurnCredentials? {
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

/// An owned signaling stream connection.
///
/// - NOTE: This is a minimal transport handle. Call lifecycle/WebRTC binding will be layered on top.
final class SignalStream: @unchecked Sendable {
    let incoming: AsyncStream<Shared_Proto_Signaling_V1_SignalResponse>

    private let grpcClient: GRPCClient<HTTP2ClientTransport.Posix>
    private let connectTask: Task<Void, Error>
    private let streamTask: Task<Void, Error>
    private let outboundContinuation: AsyncStream<Shared_Proto_Signaling_V1_SignalRequest>.Continuation

    init(
        grpcClient: GRPCClient<HTTP2ClientTransport.Posix>,
        connectTask: Task<Void, Error>,
        streamTask: Task<Void, Error>,
        outboundContinuation: AsyncStream<Shared_Proto_Signaling_V1_SignalRequest>.Continuation,
        incoming: AsyncStream<Shared_Proto_Signaling_V1_SignalResponse>
    ) {
        self.grpcClient = grpcClient
        self.connectTask = connectTask
        self.streamTask = streamTask
        self.outboundContinuation = outboundContinuation
        self.incoming = incoming
    }

    func send(_ message: Shared_Proto_Signaling_V1_SignalRequest) {
        outboundContinuation.yield(message)
    }

    func close() {
        outboundContinuation.finish()
        grpcClient.beginGracefulShutdown()
        streamTask.cancel()
        connectTask.cancel()
    }
}
