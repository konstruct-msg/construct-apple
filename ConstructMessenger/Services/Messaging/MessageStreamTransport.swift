//
//  MessageStreamTransport.swift
//  Construct Messenger
//
//  Defines the gRPC transport layer for the message stream.
//  GRPCStreamTransport is injectable so tests can replace it with a mock
//  without touching real networking code.
//

import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2

// MARK: - Protocol

/// Abstracts gRPC channel acquisition and stream execution from lifecycle management.
///
/// Inject `MockStreamTransport` in tests; use `GRPCStreamTransport` in production.
protocol StreamTransport: AnyObject, Sendable {
    /// Opens a bidirectional gRPC stream.
    ///
    /// - `outbound`: async sequence of request messages produced by the caller.
    /// - `metricsLabel`: routing key used for performance metric tagging.
    /// - `useH2Fallback`: when true, skip H3 and go straight to H2 (previous H3 timed out).
    /// - `onAccepted`: called with transport label ("H2"/"H3") when the server accepts the stream.
    /// - `events`: continuation to yield parsed `StreamEvent`s; finished on completion or error.
    func open(
        outbound: AsyncStream<Shared_Proto_Services_V1_MessageStreamRequest>,
        metricsLabel: String,
        useH2Fallback: Bool,
        onAccepted: @Sendable @escaping (String) -> Void,
        events: AsyncStream<StreamEvent>.Continuation
    ) async throws
}

// MARK: - Production implementation

/// Production `StreamTransport` backed by `GRPCChannelManager`.
/// Selects H3 (QUIC) vs H2 based on OS version, VEIL proxy state, and `useH2Fallback`.
final class GRPCStreamTransport: StreamTransport {

    func open(
        outbound: AsyncStream<Shared_Proto_Services_V1_MessageStreamRequest>,
        metricsLabel: String,
        useH2Fallback: Bool,
        onAccepted: @Sendable @escaping (String) -> Void,
        events: AsyncStream<StreamEvent>.Continuation
    ) async throws {
        // Wrap the outbound AsyncStream into a gRPC producer.
        // The producer task cancellation check mirrors the original: prevents writing to a
        // stream that is being torn down, which would assertionFailure in GRPCStreamStateMachine.
        let request = StreamingClientRequest<Shared_Proto_Services_V1_MessageStreamRequest>(
            metadata: [],
            producer: { writer in
                for await msg in outbound {
                    guard !Task.isCancelled else { return }
                    do { try await writer.write(msg) } catch { return }
                }
            }
        )

#if os(iOS)
        // Experimental engine-QUIC (construct-transport Rust stack). Direct path only,
        // gated by FeatureFlags.engineQuicExperimental. `acquireEngineQuicChannel()` returns
        // nil when the flag is off or the pinned gateway cert is missing → fall through to
        // the H3/H2 selection below (never a silent native-H3 attempt — see h3Enabled guard).
        if !useH2Fallback, GRPCChannelManager.shared.veilProxyPort() == nil,
           let eq = GRPCChannelManager.shared.acquireEngineQuicChannel() {
            let client = Shared_Proto_Services_V1_MessagingService.Client(wrapping: eq)
            try await runStream(client: client, request: request, events: events,
                                metricsLabel: metricsLabel, label: "QUIC", onAccepted: onAccepted)
            return
        }
#endif
#if canImport(Network)
        if !useH2Fallback, FeatureFlags.h3Enabled, GRPCChannelManager.shared.veilProxyPort() == nil {
            let h3 = GRPCChannelManager.shared.acquireH3Channel()
            let client = Shared_Proto_Services_V1_MessagingService.Client(wrapping: h3)
            try await runStream(client: client, request: request, events: events,
                                metricsLabel: metricsLabel, label: "H3", onAccepted: onAccepted)
        } else {
            let h2 = try GRPCChannelManager.shared.acquireChannel()
            let client = Shared_Proto_Services_V1_MessagingService.Client(wrapping: h2)
            try await runStream(client: client, request: request, events: events,
                                metricsLabel: metricsLabel, label: "H2", onAccepted: onAccepted)
        }
#else
        let h2 = try GRPCChannelManager.shared.acquireChannel()
        let client = Shared_Proto_Services_V1_MessagingService.Client(wrapping: h2)
        try await runStream(client: client, request: request, events: events,
                            metricsLabel: metricsLabel, label: "H2", onAccepted: onAccepted)
#endif
    }

    private func runStream<T: ClientTransport & Sendable>(
        client: Shared_Proto_Services_V1_MessagingService.Client<T>,
        request: StreamingClientRequest<Shared_Proto_Services_V1_MessageStreamRequest>,
        events: AsyncStream<StreamEvent>.Continuation,
        metricsLabel: String,
        label: String,
        onAccepted: @Sendable @escaping (String) -> Void
    ) async throws {
        try await client.messageStream(
            request: request,
            onResponse: { response async throws -> Void in
                switch response.accepted {
                case .success(let contents):
                    onAccepted(label)
                    for try await part in contents.bodyParts {
                        switch part {
                        case .message(let resp):
                            if let event = MessageStreamParser.parse(resp) { events.yield(event) }
                        case .trailingMetadata:
                            break
                        }
                    }
                    events.finish()
                case .failure(let error):
                    events.finish()
                    PerformanceMetrics.shared.cancelStart(.streamOpenStart, label: metricsLabel)
                    throw error
                }
            }
        )
    }
}

// MARK: - openStream (stream lifecycle coordinator)

extension MessageStreamManager {

    func openStream() async throws {
        struct StreamAcceptTimeout: Error {}

        streamGeneration &+= 1
        let generation = streamGeneration
        activeStreamGeneration = generation
        // Reset for the first-event watchdog (see below).
        firstServerEventReceived = false

        // Consume the one-shot H2 fallback flag (set when the previous H3 attempt timed out
        // on a direct path). Also check the failure counter: after the number of consecutive
        // failures this network is allowed (QuicSuppressionPolicy — two on an unknown network,
        // one on a network that has already proved it), switch to H2 until QUIC delivers data.
        //
        // Global H3 disable: `FeatureFlags.h3Enabled` short-circuits everything when H3 is
        // turned off project-wide (see flag's docs for the 2026-05-29 disable reason).
        // Experimental engine-QUIC (construct-transport Rust stack) reuses the H3 "fast UDP"
        // slot: when on, it suppresses the H2-only short-circuit so the QUIC branch in
        // GRPCStreamTransport.open() is reached. It shares the same silent-UDP failover and
        // open-failure counter as native H3 (consecutiveH3OpenFailures / shouldFallbackToH2Direct).
        let experimentalQuic = FeatureFlags.engineQuicExperimental
        // Session cooldown: if the fast-UDP transport was flagged unhealthy (QUIC kept dying on
        // this network), stay on H2 until the cooldown expires rather than re-trying QUIC.
        let fastUdpInCooldown = (fastUdpUnhealthyUntil.map { $0 > Date() }) ?? false
        // Same predicate the suppression ladder uses to decide it has seen enough — read from one
        // place so "stop probing" and "arm the cooldown" cannot disagree about how many failures
        // this network is allowed.
        let failuresAllowed = QuicSuppressionPolicy.failuresBeforeSuppressing(strikes: quicSuppressionStrikes)
        let useH2Fallback = (!FeatureFlags.h3Enabled && !experimentalQuic)
            || shouldFallbackToH2Direct
            || consecutiveH3OpenFailures >= failuresAllowed
            || fastUdpInCooldown
        if consecutiveH3OpenFailures >= failuresAllowed {
            Log.info("Fast-UDP disabled — \(consecutiveH3OpenFailures) consecutive failures, using H2 direct", category: "MessageStream")
        }
        shouldFallbackToH2Direct = false

        let metricsLabel = GRPCChannelManager.shared.currentRoutingKey
        PerformanceMetrics.shared.start(.streamOpenStart, label: metricsLabel)

        let host = GRPCChannelManager.shared.currentHost
        let port = GRPCChannelManager.shared.currentPort
        Log.info("openStream → \(host):\(port) subscriptions=[\(subscriptionUserIds.joined(separator: ", "))]", category: "MessageStream")

        // Determine transport label early for logging and accept-timeout calculation.
        // Actual channel selection happens inside GRPCStreamTransport.open().
        // Use the shared persistent channel for the stream transport.
        // On iOS 16+ with a direct (non-VEIL) path, prefer HTTP/3 (QUIC) for connection
        // migration across WiFi↔cellular switches and head-of-line blocking elimination.
        // H3 is never used over VEIL — obfs4 tunnels terminate at an H2 proxy.
        // Fall back to H2 when VEIL is active or when useH2Fallback is set
        // (previous H3 attempt timed out — trying H2 direct before escalating to VEIL).
        let transportLabel: String
        let directPath = GRPCChannelManager.shared.veilProxyPort() == nil
#if os(iOS)
        if !useH2Fallback, directPath, experimentalQuic {
            transportLabel = "QUIC"
        } else if !useH2Fallback, directPath, FeatureFlags.h3Enabled {
            transportLabel = "H3"
        } else {
            transportLabel = "H2"
        }
#elseif canImport(Network)
        if !useH2Fallback, directPath, FeatureFlags.h3Enabled {
            transportLabel = "H3"
        } else {
            transportLabel = "H2"
        }
#else
        transportLabel = "H2"
#endif
        // "QUIC" and "H3" are both fast-UDP transports for the silent-drop failover below.
        lastStreamTransportWasH3 = (transportLabel == "H3" || transportLabel == "QUIC")
        Log.debug("openStream transport=\(transportLabel) → \(host):\(port)", category: "MessageStream")

        // Create outbound stream
        let (outboundStream, outboundCont) = AsyncStream<Shared_Proto_Services_V1_MessageStreamRequest>.makeStream()
        self.outboundContinuation = outboundCont
        Log.info("MessageStream opening to \(host):\(port)", category: "MessageStream")

        // Fresh connection: drop in-flight cursor tracking. The persisted cursor below is the
        // source of truth for since_cursor; re-delivery from it re-tracks any un-advanced entries.
        StreamCursorTracker.shared.reset()

        // Send initial subscribe — include last-known Redis stream cursor so the server
        // resumes from the correct position instead of re-reading from the beginning.
        var subscribeReq = Shared_Proto_Services_V1_MessageStreamRequest()
        var subscribe = Shared_Proto_Services_V1_SubscribeRequest()
        subscribe.conversationIds = subscriptionUserIds
        subscribe.includePresence = true
        let resumeCursor = StreamCursorStore.load()
        if let resumeCursor {
            subscribe.sinceCursor = resumeCursor
            Log.debug("MessageStream subscribe with cursor=\(resumeCursor.prefix(16))…", category: "MessageStream")
        }
        StreamReplayAudit.shared.streamOpened(sinceCursor: resumeCursor)
        subscribeReq.request = .subscribe(subscribe)
        outboundCont.yield(subscribeReq)
        Log.debug("MessageStream subscribe sent: \(subscriptionUserIds.count) conversation(s)", category: "MessageStream")

        // (Receipt flushes on stream-open used to live here — removed with `sendReceipt`
        // on 2026-08-02. E2E receipts go through the normal queued send path instead.)

        // Start heartbeat sender.
        //
        // The first one goes out immediately — see StreamHeartbeatSchedule. A gRPC
        // server-streaming handler flushes no response headers until it has something to send, so
        // a client that subscribes and then stays quiet for 25s is not accepted for 25s, and the
        // 2.0s direct accept timeout kills a perfectly healthy stream. Speaking first turns
        // "accepted" back into a fact about the transport rather than about whether the server
        // happened to have mail waiting.
        let hbInterval = self.heartbeatInterval
        let hbTask = Task { [weak self] () -> Void in
            var index = 0
            while !Task.isCancelled {
                let delay = StreamHeartbeatSchedule.delayBeforeHeartbeat(index: index, interval: hbInterval)
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.sendHeartbeat() }
                index += 1
            }
        }
        self.heartbeatTask = hbTask

        // Heartbeat watchdog: reconnect if we stop receiving heartbeat acks
        let watchdogTask = Task { [weak self] () -> Void in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(hbInterval))
                await MainActor.run { self?.checkHeartbeatAndReconnectIfStale() }
            }
        }
        self.heartbeatWatchdogTask = watchdogTask

        defer {
            hbTask.cancel()
            watchdogTask.cancel()
            // Close the outbound AsyncStream so the producer closure exits cleanly.
            // Do NOT call grpcClient.beginGracefulShutdown() — the shared channel must stay alive
            // for subsequent streams and unary RPCs. Task cancellation (via streamTask.cancel())
            // propagates into the transport and closes the streaming RPC naturally.
            outboundCont.finish()
            // Only tear down shared state if this is still the active stream.
            if self.activeStreamGeneration == generation {
                self.isConnected = false
                self.outboundContinuation = nil
                self.heartbeatTask = nil
                self.heartbeatWatchdogTask = nil
                StreamReplayAudit.shared.streamClosed()
                Log.info("MessageStream disconnected from \(host):\(port)", category: "MessageStream")
            } else {
                Log.info("MessageStream disconnected (stale generation) from \(host):\(port)", category: "MessageStream")
            }
        }

        // Use an async stream to bridge responses back to MainActor
        let (incomingStream, incomingCont) = AsyncStream<StreamEvent>.makeStream()

        // Process incoming events — callbacks are invoked on the task's actor context (main)
        let processingTask = Task { [weak self] in
            for await event in incomingStream {
                guard let self else { return }
                // Drop everything from a superseded stream so dual-accept during VEIL
                // failover cannot double-fire receipts / messages into the UI pipeline.
                guard self.activeStreamGeneration == generation else { break }
                // Any server-pushed event proves the connection is live end-to-end
                // (not just at TLS layer). Sets the watchdog-cancel flag below.
                // On fast-UDP this is also the only evidence that clears the suppression ladder:
                // an accept proves the handshake, data proves the network.
                if !self.firstServerEventReceived, self.lastStreamTransportWasH3 {
                    self.noteFastUdpProvenHealthy()
                }
                self.firstServerEventReceived = true
                switch event {
                case .message(let msg, let cursor):
                    Log.debug("MessageStream received message from=\(msg.from) id=\(msg.id)", category: "MessageStream")
                    StreamReplayAudit.shared.delivery(messageId: msg.id, cursor: cursor)
                    if let handler = self.onMessageReceived {
                        // Track BEFORE handling so the cursor only advances once the pipeline
                        // reports a durable outcome (StreamCursorTracker.report inside
                        // routeIncomingMessage). A queued (no-session) message stays deferred
                        // and holds the watermark until it is drained or discarded.
                        if let cursor { StreamCursorTracker.shared.track(messageId: msg.id, cursor: cursor) }
                        handler(msg)
                    } else {
                        Log.error("MessageStream has no onMessageReceived handler — not advancing cursor for \(msg.id.prefix(8))…", category: "MessageStream")
                    }
                case .deliveryReceipt(let ids, let cursor):
                    Log.info("MessageStream receipt: \(ids.count) message(s) delivered → \(ids.joined(separator: ", "))", category: "MessageStream")
                    self.onDeliveryReceipt?(ids)
                    // Receipts carry no recoverable user data and are handled synchronously —
                    // resolve immediately, but still through the tracker so the receipt's cursor
                    // can't leapfrog an earlier still-deferred message in the FIFO.
                    if let cursor {
                        StreamCursorTracker.shared.track(messageId: cursor, cursor: cursor)
                        StreamCursorTracker.shared.resolve(messageId: cursor)
                    }
                case .keySyncRequest(let userId, let cursor):
                    Log.info("KEY_SYNC received — re-keying session for \(userId.prefix(8))…", category: "MessageStream")
                    self.onKeySyncReceived?(userId)
                    if let cursor {
                        StreamCursorTracker.shared.track(messageId: cursor, cursor: cursor)
                        StreamCursorTracker.shared.resolve(messageId: cursor)
                    }
                case .heartbeat:
                    // A heartbeat is NOT a Redis stream entry — it must never advance the
                    // resume cursor. The server now trims the offline stream by the client's
                    // acked cursor (since_cursor), so advancing it past a non-message event
                    // would tell the server to delete messages the client never received.
                    // (The server already sends no cursor on heartbeats; this is defensive.)
                    self.lastHeartbeatDate = Date()
                    // Data-plane liveness → TransportRouter (UI heartbeat SLO / health).
                    self.reportStreamHealthyToRouter()
                }
            }
        }
        defer { processingTask.cancel() }

        // Capture connect start time before the async boundary so it's available in the
        // onAccepted closure without crossing actor isolation on a mutable property.
        let capturedConnectStart = connectStartTime

        // Called by the transport when the server accepts the stream.
        // All @MainActor state updates go here, keeping GRPCStreamTransport free of
        // knowledge about MessageStreamManager internals.
        let onAccepted: @Sendable (String) -> Void = { [weak self] label in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // VEIL failover routinely leaves a late-accepted direct/prior stream racing
                // a newer openStream. Without this guard both log "connected" and both pump
                // receipts (device logs: two accepts + receipt storm + stale generation).
                guard self.activeStreamGeneration == generation else {
                    Log.info(
                        "MessageStream accept ignored (stale generation \(generation), active=\(self.activeStreamGeneration)) via \(metricsLabel)",
                        category: "MessageStream"
                    )
                    return
                }
                let streamMs = PerformanceMetrics.shared.end(.streamOpenStart, endEvent: .streamOpenEnd, label: metricsLabel)
                ConnectionStatusManager.shared.markRequestSucceeded()
                self.isConnected = true
                self.activeTransport = label
                self.lastActiveTransport = label
                self.activeRoutingKey = metricsLabel
                self.lastHeartbeatDate = Date()
                if self.lastStreamTransportWasH3 { self.consecutiveH3OpenFailures = 0 }
                // The background fetch was a best-effort catch-up for messages missed
                // while disconnected. Now that the stream is live the server will push
                // everything from the cursor, so the in-flight fetch is no longer needed.
                // Cancelling it prevents a stale fetch failure from later killing the
                // persistent connection (same-gen invalidation race).
                self.backgroundFetchTask?.cancel()
                self.backgroundFetchTask = nil
                let streamMsStr = streamMs.map { String(format: "%.0f", $0) } ?? "?"
                if let start = capturedConnectStart {
                    let totalMs = Int(Date().timeIntervalSince(start) * 1000)
                    Log.info("MessageStream connected — stream: \(streamMsStr)ms, total: \(totalMs)ms via \(metricsLabel)", category: "MessageStream")
                    self.connectStartTime = nil
                } else {
                    Log.info("MessageStream connected — stream: \(streamMsStr)ms via \(metricsLabel)", category: "MessageStream")
                }
                // Data plane is up — router must see this (clears direct fail streak).
                self.reportStreamOpenedToRouter(transportLabel: label, metricsLabel: metricsLabel)
            }
        }

        // NOTE: No local runConnections() task — the shared channel's runConnections() loop is
        // already running in GRPCChannelManager. Cancelling the outer streamTask propagates
        // cancellation into the transport, which closes the stream RPC. The shared channel itself
        // stays alive so the next openStream() reuses it without a TLS handshake.
        let streamTask = Task {
            try await transport.open(
                outbound: outboundStream,
                metricsLabel: metricsLabel,
                useH2Fallback: useH2Fallback,
                onAccepted: onAccepted,
                events: incomingCont
            )
        }
        // Ensure the transport task is always cancelled when openStream() exits — whether
        // cleanly, via error, or via outer task cancellation. Without this, a stale stream
        // outlives the connectLoop iteration and can still hold a gRPC writer open; rapid
        // forceReconnect() calls then race against it, producing "Client is closed" panics.
        defer { streamTask.cancel() }

        // Fast VEIL failover for stream open: if the RPC isn't accepted quickly, we retry
        // through VEIL instead of waiting for long TCP/TLS timeouts on DPI-blocked networks.
        // "Fast UDP" = native H3 or experimental engine-QUIC; both share the silent-drop
        // failover. isQuicTransport only picks which connection the force-invalidator tears down.
        let isH3Transport = (transportLabel == "H3" || transportLabel == "QUIC")
        let isQuicTransport = (transportLabel == "QUIC")
        let invalidateFastUdpConnection: @Sendable () -> Void = {
#if os(iOS)
            if isQuicTransport {
                GRPCChannelManager.shared.forceInvalidateEngineQuicConnection()
                return
            }
#endif
            GRPCChannelManager.shared.forceInvalidateH3Connection()
        }
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
                // 2) Timeout — three tiers:
                //   · H3 direct → 1.5s  (QUIC fails fast when not supported; tighter window)
                //   · H2 direct → 2.0s  (TCP+TLS needs one extra round-trip)
                //   · H2 / VEIL  → 6.0s  (obfs4/WebTunnel + relay→server hop on a censored network
                //                        easily eats 3-5s; tighter timeout was rotating healthy relays)
                let usingVEIL = GRPCChannelManager.shared.veilProxyPort() != nil
                group.addTask {
                    let timeout: TimeInterval
                    if isH3Transport {
                        timeout = NetworkTiming.GRPC.streamOpenAcceptTimeoutH3
                    } else if usingVEIL {
                        timeout = NetworkTiming.GRPC.streamOpenAcceptTimeoutVEIL
                    } else {
                        timeout = NetworkTiming.GRPC.streamOpenAcceptTimeout
                    }
                    try await Task.sleep(for: .seconds(timeout))
                    throw StreamAcceptTimeout()
                }
                // 3) Early stream failure (before accepted)
                //
                // Must NOT be a bare `try await streamTask.value`. That ignores this child's
                // cancellation, and a group waits for every child before it can return — so the
                // accept timeouts above became advisory: they fired on time and then sat here
                // until quinn's own connection timeout released them, 29s later (2026-08-10
                // 07:34:13 → 07:34:44, "took 31740ms"). See UnstructuredWait.
                //
                // The non-cancelling variant is required: on the *success* path the body calls
                // `group.cancelAll()`, and `cancellingValue` would reach through and tear down
                // the stream that was just accepted.
                group.addTask {
                    try await UnstructuredWait.value(of: streamTask)
                }
                // 4) Hard H3 deadline — safety net for NWConnections that ignore the soft 1.5s
                //    timeout.  Apple's Network.framework QUIC handshake runs on a DispatchQueue and
                //    does not check Swift task cancellation; the connection stays alive until a ~70s
                //    system timeout.  Explicitly cancelling the runConnections() Task (via
                //    forceInvalidateH3Connection) closes the NWConnection so streamTask fails within
                //    ~200ms rather than 70s.  Fires only when the 1.5s task did not cancel first.
                if isH3Transport {
                    group.addTask {
                        try await Task.sleep(for: .seconds(NetworkTiming.GRPC.streamOpenAcceptTimeoutH3Hard))
                        invalidateFastUdpConnection()
                        throw StreamAcceptTimeout()
                    }
                }

                _ = try await group.next()
                group.cancelAll()
            }
        } catch is StreamAcceptTimeout {
            // If already accepted, ignore the timeout (race) — fall through to await stream end.
            // onAccepted queues `Task { @MainActor self.isConnected = true }` from a non-isolated
            // context; that task may be in the MainActor queue but not yet executed when the timeout
            // fires. Yielding lets any pending MainActor tasks drain before we read isConnected.
            await Task.yield()
            if isConnected, activeStreamGeneration == generation {
                // Stream was accepted while the timeout fired; continue below to await it.
            } else {
                Log.info("MessageStream open timed out — reconnecting", category: "MessageStream")
                PerformanceMetrics.shared.record(.streamOpenFastFailover, label: metricsLabel)
                PerformanceMetrics.shared.cancelStart(.streamOpenStart, label: metricsLabel)
                streamTask.cancel()
                incomingCont.finish()
                // For H3/QUIC: force-cancel the runConnections() task so the NWConnection closes
                // immediately.  beginGracefulShutdown() (used by invalidatePersistentClient) does
                // not close a stuck QUIC handshake — task cancellation does.
                if isH3Transport {
                    // The stream rode the engine-QUIC / H3 connection, NOT the shared H2 client.
                    // Tear down only that fast-UDP connection. Invalidating the H2 persistent
                    // client here (as this path used to, unconditionally) yanks it out from under
                    // concurrent unary RPCs (VoIP register, END_SESSION, OTPK), which then fail
                    // "channel is closed" and — reported via GRPCCallExecutor — falsely escalate
                    // auto-mode direct → VEIL even though H2-direct is healthy. See
                    // sessions/2026-07-18-veil-false-escalation-channel-invalidation.
                    invalidateFastUdpConnection()
                } else {
                    // H2 stream timeout: the underlying TCP may have been RST'd (server keepalive
                    // timeout, NAT expiry). The gRPC runConnections() error handler fires
                    // asynchronously; without invalidating here the immediate retry calls
                    // acquireChannel() before that async cleanup completes, gets the dead
                    // connection back, and GRPCStreamStateMachine asserts "Client is closed: can't
                    // send metadata" — a fatalError that kills the app. Only the H2 path can hit
                    // this, so only the H2 path invalidates the H2 client.
                    GRPCChannelManager.shared.invalidatePersistentClient()
                }
                throw RPCError(code: .unavailable, message: "Stream open timed out — retrying with VEIL")
            }
        }

        // First-event watchdog. By the time we get here the server has accepted the stream
        // (TLS handshake done, subscribe acknowledged). But on RU/IR networks H3/QUIC is
        // commonly let through the handshake and then silently dropped at the UDP layer —
        // the connection looks alive but no data flows back. The heartbeat watchdog will
        // eventually catch this (~60-90s), but that's a brutal UX. This task forces a
        // fast fallback: if no server event arrives in `firstServerEventWatchdogH3` seconds,
        // mark H3 as broken on this network and trigger immediate H2 reconnect.
        //
        // Runs only for H3 — H2 has its own (slower) backpressure path and over VEIL the
        // additional relay latency makes a 5s watchdog too aggressive.
        //
        // NOTE: until the UnstructuredWait fix above, this watchdog could never fire. The task
        // group held the whole stream's lifetime, so this task was created only after the stream
        // had already ended, and its `activeStreamGeneration == generation` guard then failed
        // against the next generation. Device logs bear that out: zero occurrences of "silent
        // for … after accept" across every session. It is live for the first time now.
        // Not a risk in the observed traffic — every QUIC accept in those logs was followed by a
        // server heartbeat ack inside the same second, well under the 5s window — but if healthy
        // QUIC streams start reporting "DPI likely dropping UDP", this is the change that armed it.
        if isH3Transport {
            let firstEventWatchdog = Task { [weak self] in
                try? await Task.sleep(for: .seconds(NetworkTiming.Stream.firstServerEventWatchdogH3))
                guard !Task.isCancelled else { return }
                let shouldFallback: Bool = await MainActor.run { [weak self] in
                    guard let self,
                          self.activeStreamGeneration == generation,
                          !self.firstServerEventReceived
                    else { return false }
                    Log.info("MessageStream H3 silent for \(Int(NetworkTiming.Stream.firstServerEventWatchdogH3))s after accept — DPI likely dropping UDP, forcing H2 fallback", category: "MessageStream")
                    self.shouldFallbackToH2Direct = true
                    // Accepted-then-silent is the *most* conclusive failure this transport has —
                    // the handshake was allowed through and the data was not. It goes through the
                    // same ladder as an open timeout rather than bumping the raw counter, which
                    // left this path unable to ever arm a suppression on its own.
                    self.noteFastUdpOpenFailure(context: "silent_after_accept")
                    return true
                }
                guard shouldFallback else { return }
                // Tear down H3 hard. forceInvalidateH3Connection closes the NWConnection
                // immediately; streamTask.cancel propagates to the gRPC client. The outer
                // connectLoop sees a CancellationError and re-enters openStream with
                // shouldFallbackToH2Direct=true, which routes to H2.
                invalidateFastUdpConnection()
                streamTask.cancel()
            }
            defer { firstEventWatchdog.cancel() }
            // Cancelling variant here: cancellation of openStream means "tear this stream down",
            // which is what the `defer { streamTask.cancel() }` above already intends — it just
            // could not run while a bare `.value` await was ignoring the cancellation.
            try await UnstructuredWait.cancellingValue(of: streamTask)
            return
        }

        // Wait until the stream ends (disconnect, server close, etc.)
        try await UnstructuredWait.cancellingValue(of: streamTask)
    }
}
