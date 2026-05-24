//
//  MessageStreamTransport.swift
//  Construct Messenger
//
//  gRPC stream transport layer: opens the bidirectional MessageStream RPC,
//  drives the producer/consumer loop, and bridges responses to MainActor.
//

import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2

extension MessageStreamManager {

    func openStream() async throws {
        struct StreamAcceptTimeout: Error {}

        streamGeneration &+= 1
        let generation = streamGeneration
        activeStreamGeneration = generation

        // Consume the one-shot H2 fallback flag (set when the previous H3 attempt timed out
        // on a direct path). Resetting before transport selection ensures subsequent iterations
        // restart with H3 regardless of what happens in this openStream() call.
        let useH2Fallback = shouldFallbackToH2Direct
        shouldFallbackToH2Direct = false

        let metricsLabel = GRPCChannelManager.shared.currentRoutingKey
        PerformanceMetrics.shared.start(.streamOpenStart, label: metricsLabel)

        let host = GRPCChannelManager.shared.currentHost
        let port = GRPCChannelManager.shared.currentPort
        Log.info("📡 openStream → \(host):\(port) subscriptions=[\(subscriptionUserIds.joined(separator: ", "))]", category: "MessageStream")

        // Use the shared persistent channel for the stream transport.
        // On iOS 16+ with a direct (non-ICE) path, prefer HTTP/3 (QUIC) for connection
        // migration across WiFi↔cellular switches and head-of-line blocking elimination.
        // H3 is never used over ICE — obfs4 tunnels terminate at an H2 proxy.
        // Fall back to H2 when ICE is active, on older OS, or when useH2Fallback is set
        // (previous H3 attempt timed out — trying H2 direct before escalating to ICE).
        let transportLabel: String
#if canImport(Network)
        if #available(iOS 16.0, macOS 13.0, *), !useH2Fallback, GRPCChannelManager.shared.iceProxyPort() == nil {
            transportLabel = "H3"
        } else {
            transportLabel = "H2"
        }
#else
        transportLabel = "H2"
#endif
        lastStreamTransportWasH3 = (transportLabel == "H3")
        Log.debug("🔌 openStream transport=\(transportLabel) → \(host):\(port)", category: "MessageStream")

        // Create outbound stream
        let (outboundStream, continuation) = AsyncStream<Shared_Proto_Services_V1_MessageStreamRequest>.makeStream()
        self.outboundContinuation = continuation
        Log.info("⏳ MessageStream opening to \(host):\(port)", category: "MessageStream")

        // Send initial subscribe — include last-known Redis stream cursor so the server
        // resumes from the correct position instead of re-reading from the beginning.
        var subscribeReq = Shared_Proto_Services_V1_MessageStreamRequest()
        var subscribe = Shared_Proto_Services_V1_SubscribeRequest()
        subscribe.conversationIds = subscriptionUserIds
        subscribe.includePresence = true
        if let cursor = StreamCursorStore.load() {
            subscribe.sinceCursor = cursor
            Log.debug("📤 MessageStream subscribe with cursor=\(cursor.prefix(16))…", category: "MessageStream")
        }
        subscribeReq.request = .subscribe(subscribe)
        continuation.yield(subscribeReq)
        Log.debug("📤 MessageStream subscribe sent: \(subscriptionUserIds.count) conversation(s)", category: "MessageStream")

        // Flush any ACKs for messages that failed decoding before the stream was open
        if !pendingFailedAcks.isEmpty {
            let toFlush = pendingFailedAcks
            pendingFailedAcks.removeAll()
            let bySender = Dictionary(grouping: toFlush, by: \.senderId)
            for (senderId, entries) in bySender {
                sendReceipt(entries.map(\.id), to: senderId, status: .failed)
            }
            Log.info("📤 Flushed \(toFlush.count) failed ACK(s) for undecryptable pending message(s)", category: "MessageStream")
        }

        // Flush delivered receipts that were queued while the stream was closed
        if !pendingDeliveredAcks.isEmpty {
            let toFlush = pendingDeliveredAcks
            pendingDeliveredAcks.removeAll()
            for ack in toFlush {
                sendReceipt(ack.messageIds, to: ack.recipientUserId, status: .delivered)
            }
            Log.info("📤 Flushed \(toFlush.count) pending delivered receipt(s)", category: "MessageStream")
        }

        // Start heartbeat
        let hbInterval = self.heartbeatInterval
        let hbTask = Task { [weak self] () -> Void in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(hbInterval))
                await MainActor.run { self?.sendHeartbeat() }
            }
        }
        self.heartbeatTask = hbTask

        // Heartbeat watchdog: reconnect if we stop receiving heartbeat acks.
        let watchdogTask = Task { [weak self] () -> Void in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(hbInterval))
                await MainActor.run {
                    self?.checkHeartbeatAndReconnectIfStale()
                }
            }
        }
        self.heartbeatWatchdogTask = watchdogTask

        let request = StreamingClientRequest<Shared_Proto_Services_V1_MessageStreamRequest>(
            metadata: [],
            producer: { writer in
                for await msg in outboundStream {
                    // Guard against writing to a stream that's being torn down. Task
                    // cancellation propagates into this producer task; checking it before
                    // write prevents the assertionFailure in GRPCStreamStateMachine when
                    // the underlying NIO client is already in a closed state.
                    guard !Task.isCancelled else { return }
                    do {
                        try await writer.write(msg)
                    } catch {
                        // Stream was closed mid-write (release builds throw instead of
                        // assertionFailure). Exit producer cleanly.
                        return
                    }
                }
            }
        )

        // NOTE: No local runConnections() task — the shared channel's runConnections() loop is
        // already running in GRPCChannelManager. Cancelling the outer streamTask propagates
        // cancellation into runMessageStream() (via its await point), which closes the stream RPC.
        // The shared channel itself stays alive so the next openStream() reuses it without a
        // TLS handshake.

        defer {
            hbTask.cancel()
            watchdogTask.cancel()
            // Close the outbound AsyncStream so the producer closure exits cleanly.
            // Do NOT call grpcClient.beginGracefulShutdown() — the shared channel must stay alive
            // for subsequent streams and unary RPCs. Task cancellation (via streamTask.cancel())
            // propagates into runMessageStream() and closes the streaming RPC naturally.
            continuation.finish()
            // Only tear down shared state if this is still the active stream.
            if self.activeStreamGeneration == generation {
                self.isConnected = false
                self.outboundContinuation = nil
                self.heartbeatTask = nil
                self.heartbeatWatchdogTask = nil
                Log.info("🔌 MessageStream disconnected from \(host):\(port)", category: "MessageStream")
            } else {
                Log.info("🔌 MessageStream disconnected (stale generation) from \(host):\(port)", category: "MessageStream")
            }
        }

        // Use an async stream to bridge responses back to MainActor
        let (incomingStream, incomingContinuation) = AsyncStream<StreamEvent>.makeStream()

        // Process incoming events on MainActor
        let processingTask = Task { [weak self] in
            for await event in incomingStream {
                switch event {
                case .message(let msg):
                    Log.debug("📩 MessageStream received message from=\(msg.from) id=\(msg.id)", category: "MessageStream")
                    self?.onMessageReceived?(msg)
                case .deliveryReceipt(let ids):
                    Log.info("📬 MessageStream receipt: \(ids.count) message(s) delivered → \(ids.joined(separator: ", "))", category: "MessageStream")
                    self?.onDeliveryReceipt?(ids)
                case .keySyncRequest(let userId):
                    Log.info("🔑 KEY_SYNC received — re-keying session for \(userId.prefix(8))…", category: "MessageStream")
                    self?.onKeySyncReceived?(userId)
                case .heartbeat:
                    self?.lastHeartbeatDate = Date()
                }
            }
        }

        defer { processingTask.cancel() }

        let streamTask = Task {
            // Acquire the appropriate persistent channel inside the Task.
            // Both branches call the generic `runMessageStream<Transport>` — Swift specialises it.
#if canImport(Network)
            if #available(iOS 16.0, macOS 13.0, *), !useH2Fallback, GRPCChannelManager.shared.iceProxyPort() == nil {
                let h3Client = GRPCChannelManager.shared.acquireH3Channel()
                let msgClient = Shared_Proto_Services_V1_MessagingService.Client(wrapping: h3Client)
                try await runMessageStream(
                    client: msgClient,
                    request: request,
                    incomingContinuation: incomingContinuation,
                    metricsLabel: metricsLabel,
                    transportLabel: "H3"
                )
            } else {
                let grpcClient = try GRPCChannelManager.shared.acquireChannel()
                let msgClient = Shared_Proto_Services_V1_MessagingService.Client(wrapping: grpcClient)
                try await runMessageStream(
                    client: msgClient,
                    request: request,
                    incomingContinuation: incomingContinuation,
                    metricsLabel: metricsLabel,
                    transportLabel: "H2"
                )
            }
#else
            let grpcClient = try GRPCChannelManager.shared.acquireChannel()
            let msgClient = Shared_Proto_Services_V1_MessagingService.Client(wrapping: grpcClient)
            try await runMessageStream(
                client: msgClient,
                request: request,
                incomingContinuation: incomingContinuation,
                metricsLabel: metricsLabel,
                transportLabel: "H2"
            )
#endif
        }
        // Ensure the inner (unstructured) runMessageStream task is always cancelled
        // when openStream() exits — whether cleanly, via error, or via outer task
        // cancellation.  Without this, a stale stream outlives the connectLoop
        // iteration and can still hold a gRPC writer open; rapid forceReconnect()
        // calls then race against it, producing the "Client is closed, cannot send
        // a message" assertionFailure in GRPCStreamStateMachine.
        defer { streamTask.cancel() }

        // Fast ICE failover for stream open: if the RPC isn't accepted quickly, we retry
        // through ICE instead of waiting for long TCP/TLS timeouts on DPI-blocked networks.
        let isH3Transport = lastStreamTransportWasH3
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                // 1) Accepted watcher
                group.addTask { [weak self] in
                    while let self, !Task.isCancelled {
                        let accepted = await MainActor.run {
                            self.isConnected && self.activeStreamGeneration == generation
                        }
                        if accepted { return }
                        try await Task.sleep(for: .seconds(NetworkTiming.GRPC.streamOpenAcceptPollInterval))
                    }
                }
                // 2) Timeout — two tiers:
                //   · H3 direct → 1.5s  (QUIC fails fast when not supported; tighter window)
                //   · H2 / ICE  → 2.0s  (TCP+TLS needs one extra round-trip; relay may be high-latency)
                group.addTask {
                    let timeout: TimeInterval = isH3Transport
                        ? NetworkTiming.GRPC.streamOpenAcceptTimeoutH3
                        : NetworkTiming.GRPC.streamOpenAcceptTimeout
                    try await Task.sleep(for: .seconds(timeout))
                    throw StreamAcceptTimeout()
                }
                // 3) Early stream failure (before accepted)
                group.addTask {
                    try await streamTask.value
                }

                _ = try await group.next()
                group.cancelAll()
            }
        } catch is StreamAcceptTimeout {
            // If already accepted, ignore the timeout (race) — fall through to await stream end.
            if isConnected, activeStreamGeneration == generation {
                // Stream was accepted while the timeout fired; continue below to await it.
            } else {
                Log.info("🧊 MessageStream open timed out — reconnecting", category: "MessageStream")
                PerformanceMetrics.shared.record(.streamOpenFastFailover, label: metricsLabel)
                PerformanceMetrics.shared.cancelStart(.streamOpenStart, label: metricsLabel)
                streamTask.cancel()
                incomingContinuation.finish()
                // Always invalidate the persistent client on stream timeout.
                // If the underlying TCP connection was RST'd (server keepalive timeout, NAT expiry,
                // etc.) the gRPC runConnections() error handler fires asynchronously. Without this
                // invalidation the immediate retry calls acquireChannel() before that async cleanup
                // completes, gets the dead connection back, and GRPCStreamStateMachine asserts
                // "Client is closed: can't send metadata" — a fatalError that kills the app.
                GRPCChannelManager.shared.invalidatePersistentClient()
                throw RPCError(code: .unavailable, message: "Stream open timed out — retrying with ICE")
            }
        }

        // Wait until the stream ends (disconnect, server close, etc.).
        try await streamTask.value
    }

    nonisolated func runMessageStream<Transport: ClientTransport & Sendable>(
        client: Shared_Proto_Services_V1_MessagingService.Client<Transport>,
        request: StreamingClientRequest<Shared_Proto_Services_V1_MessageStreamRequest>,
        incomingContinuation: AsyncStream<StreamEvent>.Continuation,
        metricsLabel: String,
        transportLabel: String = "H2"
    ) async throws {
        try await client.messageStream(
            request: request,
            onResponse: { (response: StreamingClientResponse<Shared_Proto_Services_V1_MessageStreamResponse>) async throws -> Void in
                let contents: StreamingClientResponse<Shared_Proto_Services_V1_MessageStreamResponse>.Contents
                switch response.accepted {
                case .success(let c):
                    Task { @MainActor in
                        let streamMs = PerformanceMetrics.shared.end(.streamOpenStart, endEvent: .streamOpenEnd, label: metricsLabel)
                        ConnectionStatusManager.shared.markStreamConnected()
                        self.isConnected = true
                        self.activeTransport = transportLabel
                        self.lastActiveTransport = transportLabel
                        self.lastHeartbeatDate = Date()
                        // The background fetch was a best-effort catch-up for messages missed
                        // while disconnected. Now that the stream is live the server will push
                        // everything from the cursor, so the in-flight fetch is no longer needed.
                        // Cancelling it prevents a stale fetch failure from later killing the
                        // persistent connection (same-gen invalidation race).
                        self.backgroundFetchTask?.cancel()
                        self.backgroundFetchTask = nil
                        let streamMsStr = streamMs.map { String(format: "%.0f", $0) } ?? "?"
                        if let start = self.connectStartTime {
                            let totalMs = Int(Date().timeIntervalSince(start) * 1000)
                            Log.info("✅ MessageStream connected — stream: \(streamMsStr)ms, total: \(totalMs)ms via \(metricsLabel)", category: "MessageStream")
                            self.connectStartTime = nil
                        } else {
                            Log.info("✅ MessageStream connected — stream: \(streamMsStr)ms via \(metricsLabel)", category: "MessageStream")
                        }
                    }
                    contents = c
                case .failure(let error):
                    incomingContinuation.finish()
                    PerformanceMetrics.shared.cancelStart(.streamOpenStart, label: metricsLabel)
                    throw error
                }

                for try await part in contents.bodyParts {
                    switch part {
                    case .message(let streamResponse):
                        // Persist the cursor on every response so reconnects resume cleanly.
                        if streamResponse.hasStreamCursor {
                            StreamCursorStore.save(streamResponse.streamCursor)
                        }
                        if let msg = MessageStreamParser.parse(streamResponse) {
                            incomingContinuation.yield(msg)
                        }
                    case .trailingMetadata:
                        break
                    }
                }
                incomingContinuation.finish()
            }
        )
    }
}
