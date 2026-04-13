//
//  MessageStreamManager.swift
//  Construct Messenger
//
//  Replaces LongPollingManager — uses gRPC bidirectional MessageStream
//  for real-time message delivery with auto-reconnect and heartbeat.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif
import GRPCCore
import GRPCNIOTransportHTTP2

/// Manages bidirectional gRPC MessageStream for real-time messaging

// MARK: - Stream Event

private enum StreamEvent: Sendable {
    case message(ChatMessage)
    case deliveryReceipt([String])    // message IDs confirmed delivered to recipient
    case keySyncRequest(String)       // server-triggered X3DH re-init for userId
    case heartbeat                    // server heartbeat ack
}

// MARK: - Stream Cursor Persistence

/// Persists the last Redis stream cursor so reconnects resume from the correct position.
private enum StreamCursorStore {
    private static let key = "construct.stream.cursor"

    static func save(_ cursor: String) {
        UserDefaults.standard.set(cursor, forKey: key)
    }

    static func load() -> String? {
        UserDefaults.standard.string(forKey: key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
@MainActor
@Observable
final class MessageStreamManager {

    static let shared = MessageStreamManager()

    deinit {
        MainActor.assumeIsolated {
            if let obs = serverChangedObserver {
                NotificationCenter.default.removeObserver(obs)
            }
        }
    }

    // MARK: - State

    private(set) var isConnected = false
    /// Set to the current time whenever a heartbeat ack is received from the server.
    private(set) var lastHeartbeatDate: Date?

    // MARK: - Callbacks

    private var onMessageReceived: ((ChatMessage) -> Void)?
    /// Called when a DeliveryReceipt arrives from the server.
    /// Provides the IDs of messages confirmed delivered to the recipient.
    var onDeliveryReceipt: (([String]) -> Void)?
    /// Called when server sends KEY_SYNC (contentType=22) — triggers X3DH re-init for userId.
    var onKeySyncReceived: ((String) -> Void)?

    // MARK: - Private State

    private var streamTask: Task<Void, Never>?
    private var backgroundFetchTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var heartbeatWatchdogTask: Task<Void, Never>?
    private var serverChangedObserver: NSObjectProtocol?
    private var retryCount = 0
    private let maxRetryDelay: TimeInterval = NetworkTiming.Stream.maxRetryDelay
    private(set) var isPaused = false
    private(set) var subscriptionUserIds: [String] = []
    private var lastPendingCursor: String = UserDefaults.standard.string(forKey: "construct.pendingCursor") ?? "" {
        didSet {
            UserDefaults.standard.set(lastPendingCursor, forKey: "construct.pendingCursor")
        }
    }

    /// Continuation for sending messages into the stream
    private var outboundContinuation: AsyncStream<Shared_Proto_Services_V1_MessageStreamRequest>.Continuation?

    /// Monotonically increasing token for stream lifetimes. Used to prevent a previous
    /// stream's teardown from clobbering state of a newer connection (race during reconnect).
    private var streamGeneration: UInt64 = 0
    private var activeStreamGeneration: UInt64 = 0

    /// Messages that failed decoding during fetchMissedMessages (before stream was open).
    /// Flushed as `.failed` receipts once the stream is established.
    private var pendingFailedAcks: [MessagingServiceClient.FailedMessage] = []

    /// Delivered receipts queued when the stream was not yet open.
    /// Flushed as `.delivered` receipts once the stream is established.
    private struct PendingDeliveredAck {
        let messageIds: [String]
        let recipientUserId: String
    }
    private var pendingDeliveredAcks: [PendingDeliveredAck] = []

    // MARK: - Configuration

    private let heartbeatInterval: TimeInterval = NetworkTiming.Stream.heartbeatInterval
    private let heartbeatTimeoutMultiplier: Double = 3.0
    private var lastWatchdogRestartAt: Date?
    private let watchdogMinRestartInterval: TimeInterval = NetworkTiming.Stream.watchdogMinRestartInterval

    // MARK: - Public API

    func connect(contactUserIds: [String] = [], onMessageReceived: @escaping (ChatMessage) -> Void) {
        self.onMessageReceived = onMessageReceived

        let subscriptionChanged = contactUserIds != subscriptionUserIds

        // If subscriptions changed and a loop is running, force reconnect so the
        // new contact's conversation ID is included in the subscribe request.
        if subscriptionChanged && (isConnected || streamTask != nil) {
            Log.info("📡 Subscriptions changed (\(subscriptionUserIds.count)→\(contactUserIds.count)) — reconnecting stream", category: "MessageStream")
            forceDisconnect()
        }

        self.subscriptionUserIds = contactUserIds
        isPaused = false

        // Already fully connected with up-to-date subscriptions.
        guard !isConnected else {
            Log.info("📡 MessageStream already connected", category: "MessageStream")
            return
        }

        // connectLoop is already running (in backoff between retries) — don't stack tasks.
        guard streamTask == nil else {
            Log.info("📡 MessageStream already reconnecting", category: "MessageStream")
            return
        }

        // Reconnect when server config changes
        if serverChangedObserver == nil {
            serverChangedObserver = NotificationCenter.default.addObserver(
                forName: .grpcServerChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                Log.info("🔄 gRPC server changed — reconnecting stream", category: "MessageStream")
                Task { @MainActor in
                    let ids = self.subscriptionUserIds
                    let cb = self.onMessageReceived
                    self.forceDisconnect()
                    if let cb { self.connect(contactUserIds: ids, onMessageReceived: cb) }
                }
            }
        }

        Log.info("📡 Starting MessageStream connection (subscribed to \(contactUserIds.count) contacts)", category: "MessageStream")
        ConnectionStatusManager.shared.markConnecting()
        streamTask = Task { [weak self] in
            await self?.connectLoop()
        }
    }

    /// Cancel any in-progress backoff/connection and start fresh immediately.
    /// Use when returning from background or recovering from a known-bad state.
    func forceReconnect(contactUserIds: [String], onMessageReceived: @escaping (ChatMessage) -> Void) {
        Log.info("🔁 Force reconnecting stream", category: "MessageStream")
        // Finish the outbound stream BEFORE cancelling the task.
        // Cancelling the Task first while the producer is mid-write triggers an
        // assertionFailure inside GRPCStreamStateMachine ("Client is closed, cannot send a
        // message.") because NIO force-closes the stream before the write completes.
        // Finishing the continuation first lets the producer's `for await` drain naturally;
        // task cancellation then only aborts a sleeping backoff or an idle await point.
        isConnected = false
        outboundContinuation?.finish()
        outboundContinuation = nil
        streamTask?.cancel()
        streamTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        heartbeatWatchdogTask?.cancel()
        heartbeatWatchdogTask = nil
        backgroundFetchTask?.cancel()
        backgroundFetchTask = nil
        retryCount = 0
        connect(contactUserIds: contactUserIds, onMessageReceived: onMessageReceived)
    }

    func disconnect() {
        if let obs = serverChangedObserver {
            NotificationCenter.default.removeObserver(obs)
            serverChangedObserver = nil
        }
        forceDisconnect()
    }

    /// Disconnect without removing the server-change observer (used for reconnects).
    private func forceDisconnect() {
        isConnected = false
        outboundContinuation?.finish()
        outboundContinuation = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        heartbeatWatchdogTask?.cancel()
        heartbeatWatchdogTask = nil
        backgroundFetchTask?.cancel()
        backgroundFetchTask = nil
        activeStreamGeneration = 0
        streamTask?.cancel()
        streamTask = nil
        retryCount = 0
        ConnectionStatusManager.shared.markStreamDisconnected()
        Log.info("📡 MessageStream disconnected", category: "MessageStream")
    }

    func pause() {
        guard !isPaused else { return }
        isPaused = true
        disconnect()
        Log.info("📱 MessageStream paused", category: "MessageStream")
    }

    func resume(onMessageReceived: @escaping (ChatMessage) -> Void) {
        guard isPaused else { return }
        isPaused = false
        Log.info("📱 MessageStream resuming", category: "MessageStream")
        connect(contactUserIds: subscriptionUserIds, onMessageReceived: onMessageReceived)
    }

    // MARK: - Send via Stream

    func sendHeartbeat() {
        var hb = Shared_Proto_Services_V1_Heartbeat()
        hb.timestamp = Int64(Date().timeIntervalSince1970)
        var req = Shared_Proto_Services_V1_MessageStreamRequest()
        req.request = .heartbeat(hb)
        outboundContinuation?.yield(req)
    }

    /// Send a delivery receipt for one or more messages via the live stream.
    /// - Parameters:
    ///   - messageIds: IDs of messages being acknowledged.
    ///   - recipientUserId: The original message sender — server uses this to route the receipt back without a DB lookup.
    ///   - status: `.delivered` after successful decrypt, `.failed` on unrecoverable decrypt error.
    func sendReceipt(_ messageIds: [String], to recipientUserId: String = "", status: Shared_Proto_Signaling_V1_ReceiptStatus) {
        guard !messageIds.isEmpty else { return }

        // If the live stream isn't open yet, queue delivered receipts for flush when it opens.
        // (outboundContinuation?.yield silently drops if nil — see sendReceipt guard below)
        if outboundContinuation == nil, status == .delivered {
            guard !pendingDeliveredAcks.contains(where: { $0.messageIds == messageIds && $0.recipientUserId == recipientUserId }) else {
                return  // already queued — dedup to prevent bloat during paging cycles
            }
            pendingDeliveredAcks.append(PendingDeliveredAck(messageIds: messageIds, recipientUserId: recipientUserId))
            Log.info("📨 Receipt queued (stream not open): \(status) for \(messageIds.count) msg(s) → recipient=\(recipientUserId.prefix(8))…", category: "MessageStream")
            return
        }

        var direct = Shared_Proto_Signaling_V1_DirectReceipt()
        direct.messageIds = messageIds
        direct.status = status
        direct.timestamp = Int64(Date().timeIntervalSince1970)
        direct.senderDeviceID = KeychainManager.shared.loadDeviceID() ?? ""
        direct.recipientUserID = recipientUserId

        var delivery = Shared_Proto_Signaling_V1_DeliveryReceipt()
        delivery.direct = direct

        var req = Shared_Proto_Services_V1_MessageStreamRequest()
        req.receipt = delivery
        outboundContinuation?.yield(req)
        Log.info("📨 Receipt sent: \(status) for \(messageIds.count) msg(s) → recipient=\(recipientUserId.prefix(8))…", category: "MessageStream")
    }

    // MARK: - Private: Connection Loop

    private func connectLoop() async {
        let host = GRPCChannelManager.shared.currentHost
        let port = GRPCChannelManager.shared.currentPort
        Log.info("🔄 MessageStream connectLoop started → \(host):\(port)", category: "MessageStream")

        while !Task.isCancelled {
            // Cancel any background fetch left over from the previous iteration.
            backgroundFetchTask?.cancel()

            // Fetch messages that arrived while disconnected. Run as an independent
            // Task so the wall-clock cap doesn't cancel it: pending messages live in
            // the server's queue and are NOT replayed via the live stream cursor.
            // The background task continues delivering them after openStream() starts.
            let fetchTask = Task { await self.fetchMissedMessages() }
            backgroundFetchTask = fetchTask

            await withTaskGroup(of: Void.self) { group in
                // Mirror the fetch's completion into the group without owning it.
                group.addTask { _ = await fetchTask.value }
                group.addTask {
                    try? await Task.sleep(for: .seconds(NetworkTiming.Stream.fetchMissedMessagesWallClockCap))
                    Log.debug("⏰ fetchMissedMessages wall-clock cap reached — proceeding to stream", category: "MessageStream")
                }
                _ = await group.next()
                // Cancels only the group child tasks — fetchTask is NOT in this
                // group and continues running alongside the live stream.
                group.cancelAll()
            }

            guard !Task.isCancelled else { break }

            Log.info("🔄 connectLoop: fetchMissedMessages done, isCancelled=\(Task.isCancelled) — opening stream", category: "MessageStream")
            ConnectionStatusManager.shared.markConnecting()
            do {
                try await openStream()
                // Stream ended cleanly — brief pause before reconnecting to avoid tight loop
                // (e.g. server closes stream when 0 topics are subscribed)
                Log.info("📡 MessageStream ended cleanly, reconnecting in \(Int(NetworkTiming.Stream.cleanEndReconnectDelay))s", category: "MessageStream")
                retryCount = 0
                try await Task.sleep(for: .seconds(NetworkTiming.Stream.cleanEndReconnectDelay))
            } catch is CancellationError {
                Log.info("🛑 MessageStream cancelled — connectLoop exiting", category: "MessageStream")
                break
            } catch {
                guard !Task.isCancelled else { break }
                // If the stream was rejected due to expired token, refresh and retry immediately
                // (skip exponential backoff to reduce perceived downtime).
                if let rpcError = error as? RPCError, rpcError.code == .unauthenticated {
                    Log.info("🔐 MessageStream unauthenticated — attempting token refresh", category: "MessageStream")
                    var refreshError: Error?
                    do {
                        let refreshed = try await TokenRefreshCoordinator.shared.refreshIfPossible()
                        if refreshed {
                            retryCount = 0
                            continue
                        }
                    } catch {
                        refreshError = error
                        Log.error("❌ Token refresh failed for MessageStream: \(error)", category: "MessageStream")
                    }
                    // Only wipe tokens if the server explicitly rejected the refresh token.
                    // Network errors mean the refresh was unreachable, not that the token is invalid.
                    let serverRejected: Bool
                    if let rpcErr = refreshError as? RPCError {
                        serverRejected = rpcErr.code == .unauthenticated || rpcErr.code == .permissionDenied
                    } else {
                        serverRejected = refreshError == nil  // returned false = no refresh token
                    }
                    if serverRejected {
                        Log.info("🔑 MessageStream refresh rejected by server — triggering device re-auth", category: "MessageStream")
                        SessionManager.shared.invalidateTokensForReauth()
                    } else {
                        Log.info("🔑 MessageStream refresh failed (network error) — keeping tokens, will retry later", category: "MessageStream")
                    }
                }
                // Fast ICE failover path: openStream() intentionally throws this sentinel
                // error to force an immediate reconnect without exponential backoff.
                if let rpcError = error as? RPCError,
                   rpcError.code == .unavailable,
                   rpcError.message.contains("retrying with ICE") {
                    Log.info("🧊 MessageStream switching routing — reconnecting immediately", category: "MessageStream")
                    retryCount = 0
                    continue
                }
                // Log full error details for diagnosis
                if let rpcError = error as? RPCError {
                    Log.error("""
                        ❌ MessageStream RPC error:
                           code    = \(rpcError.code)
                           message = \(rpcError.message)
                           host    = \(host):\(port)
                           attempt = #\(retryCount + 1)
                        """, category: "MessageStream")
                } else {
                    Log.error("❌ MessageStream error (attempt #\(retryCount + 1)): \(error)", category: "MessageStream")
                }
                ConnectionStatusManager.shared.markStreamDisconnected(error: error.localizedDescription)
            }

            guard !Task.isCancelled else { break }

            // Exponential backoff with jitter
            retryCount += 1
            let base: TimeInterval = NetworkTiming.Stream.backoffBaseDelay
            let delay = min(base * pow(2, Double(min(retryCount - 1, 5))), maxRetryDelay)
            let jitter = Double.random(in: 0...(delay * 0.25))
            let totalDelay = delay + jitter

            Log.info("⏳ MessageStream reconnecting in \(String(format: "%.1f", totalDelay))s (attempt #\(retryCount)) → \(host):\(port)", category: "MessageStream")
            do {
                try await Task.sleep(for: .seconds(totalDelay))
            } catch {
                // Task was cancelled during backoff sleep — exit immediately
                break
            }
        }
        Log.info("🏁 MessageStream connectLoop finished", category: "MessageStream")
    }

    private func fetchMissedMessages() async {
        // Drain ALL pending pages so the user sees every missed message on the first reconnect,
        // not just the first 50 (the previous single-fetch behaviour — bug B08).
        //
        // IMPORTANT: use a single gRPC channel for the entire paging loop to avoid creating
        // dozens of short-lived channels when there are many pending pages.
        do {
            struct FetchResult: Sendable {
                let messages: [ChatMessage]
                let failed: [MessagingServiceClient.FailedMessage]
                let nextCursor: String
            }

            let startCursor = lastPendingCursor
            let fetchResult: FetchResult = try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.getPendingMessages, fastICEFallback: true) { grpcClient in
                func withTimeout<T: Sendable>(
                    seconds: TimeInterval,
                    _ operation: @Sendable @escaping () async throws -> T
                ) async throws -> T {
                    try await withThrowingTaskGroup(of: T.self) { group in
                        group.addTask { try await operation() }
                        group.addTask {
                            try await Task.sleep(for: .seconds(seconds))
                            throw RPCError(code: .deadlineExceeded, message: "Request timed out")
                        }
                        let first = try await group.next()!
                        group.cancelAll()
                        return first
                    }
                }

                var cursor: String? = startCursor.isEmpty ? nil : startCursor
                var cursorToPersist: String = startCursor
                var messages: [ChatMessage] = []
                var failed: [MessagingServiceClient.FailedMessage] = []
                var failedIds: Set<String> = []
                var seenMessageIds: Set<String> = []

                while !Task.isCancelled {
                    // Snapshot the cursor for this iteration to avoid capturing a mutable var
                    // in a concurrently-executing (Swift 6) Sendable closure.
                    let cursorSnapshot = cursor
                    let page: MessagingServiceClient.PendingMessagesResult = try await withTimeout(
                        seconds: GRPCTimeouts.getPendingMessages
                    ) {
                        try await MessagingServiceClient.getPendingMessagesPage(
                            grpcClient: grpcClient,
                            sinceCursor: cursorSnapshot,
                            limit: 50
                        )
                    }

                    cursorToPersist = page.nextCursor

                    if !page.messages.isEmpty {
                        let pageIds = Set(page.messages.map(\.id))
                        let newIds = pageIds.subtracting(seenMessageIds)
                        if newIds.isEmpty {
                            // Server is cycling the same unACKed messages — receipts haven't been
                            // sent yet (stream not open). Stop paging; openStream() will flush ACKs.
                            break
                        }
                        seenMessageIds.formUnion(pageIds)
                        messages.append(contentsOf: page.messages)
                    }

                    if !page.failedMessages.isEmpty {
                        for item in page.failedMessages where !failedIds.contains(item.id) {
                            failedIds.insert(item.id)
                            failed.append(item)
                        }
                    }

                    cursor = page.nextCursor.isEmpty ? nil : page.nextCursor
                    if cursor == nil { break }
                }

                return FetchResult(messages: messages, failed: failed, nextCursor: cursorToPersist)
            }

            ConnectionStatusManager.shared.markRequestSucceeded()

            if !fetchResult.messages.isEmpty {
                for msg in fetchResult.messages {
                    onMessageReceived?(msg)
                }
            }

            lastPendingCursor = fetchResult.nextCursor

            if !fetchResult.failed.isEmpty {
                Log.info("⚠️ fetchMissedMessages: \(fetchResult.failed.count) undecryptable message(s) — will ACK as failed once stream opens", category: "MessageStream")
                pendingFailedAcks.append(contentsOf: fetchResult.failed)
            }

            if !fetchResult.messages.isEmpty {
                Log.info("📨 Fetched \(fetchResult.messages.count) missed message(s) after reconnect", category: "MessageStream")
            } else {
                Log.debug("📭 fetchMissedMessages: no pending messages", category: "MessageStream")
            }
        } catch is CancellationError {
            // Task was cancelled during force-reconnect or backgrounding — expected, no log needed
            return
        } catch {
            if let rpcError = error as? RPCError {
                Log.error("⚠️ fetchMissedMessages RPC error: code=\(rpcError.code) message=\"\(rpcError.message)\"", category: "MessageStream")
            } else {
                Log.debug("fetchMissedMessages failed: \(error)", category: "MessageStream")
            }
            return
        }
    }

    private func openStream() async throws {
        struct StreamAcceptTimeout: Error {}

        streamGeneration &+= 1
        let generation = streamGeneration
        activeStreamGeneration = generation

        let metricsLabel = GRPCChannelManager.shared.currentRoutingKey
        PerformanceMetrics.shared.start(.streamOpenStart, label: metricsLabel)

        let host = GRPCChannelManager.shared.currentHost
        let port = GRPCChannelManager.shared.currentPort
        Log.info("📡 openStream → \(host):\(port) subscriptions=[\(subscriptionUserIds.joined(separator: ", "))]", category: "MessageStream")

        // Reuse the shared persistent channel — do NOT call makeClient() here.
        // makeClient() opens a new TLS/HTTP-2 connection on every call; using the shared channel
        // means the stream reuses the same HTTP-2 connection across reconnects, which is what
        // the server expects (channel = singleton, stream can close/reopen freely).
        // When routing changes (ICE failover), GRPCChannelManager.invalidatePersistentClient()
        // is called externally, acquireChannel() creates a new channel, and the stream
        // reconnects naturally via the retry loop — exactly one new handshake per routing change.
        let grpcClient = try GRPCChannelManager.shared.acquireChannel()
        let msgClient = Shared_Proto_Services_V1_MessagingService.Client(wrapping: grpcClient)

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
            try await runMessageStream(
                client: msgClient,
                request: request,
                incomingContinuation: incomingContinuation,
                metricsLabel: metricsLabel
            )
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
                // 2) Timeout
                group.addTask {
                    try await Task.sleep(for: .seconds(NetworkTiming.GRPC.streamOpenAcceptTimeout))
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
            // If already accepted, ignore the timeout (race).
            if isConnected, activeStreamGeneration == generation {
                // Continue below to await the stream until it ends.
            } else {
                Log.info("🧊 MessageStream open timed out — attempting ICE fast-failover", category: "MessageStream")
                PerformanceMetrics.shared.record(.streamOpenFastFailover, label: metricsLabel)
                PerformanceMetrics.shared.cancelStart(.streamOpenStart, label: metricsLabel)
                streamTask.cancel()
                incomingContinuation.finish()
                // If ICE is running but on cooldown, clear cooldown: direct path is likely blocked.
                if IceProxyManager.shared.isRunning, IceProxyManager.shared.isOnCooldown {
                    IceProxyManager.shared.clearCooldown()
                } else if !IceProxyManager.shared.isRunning {
                    await IceProxyManager.shared.startEphemeralOnDemandIfNeeded()
                }
                // Force routing key refresh for the next acquireChannel().
                GRPCChannelManager.shared.invalidatePersistentClient()
                // Immediate retry: propagate an error to exit openStream() and let connectLoop retry.
                throw RPCError(code: .unavailable, message: "Stream open timed out — retrying with ICE")
            }
        }

        // Stream accepted — wait until it ends (disconnect, server close, etc.).
        try await streamTask.value
    }

    private nonisolated func runMessageStream(
        client: Shared_Proto_Services_V1_MessagingService.Client<HTTP2ClientTransport.Posix>,
        request: StreamingClientRequest<Shared_Proto_Services_V1_MessageStreamRequest>,
        incomingContinuation: AsyncStream<StreamEvent>.Continuation,
        metricsLabel: String
    ) async throws {
        try await client.messageStream(
            request: request,
            onResponse: { (response: StreamingClientResponse<Shared_Proto_Services_V1_MessageStreamResponse>) async throws -> Void in
                let contents: StreamingClientResponse<Shared_Proto_Services_V1_MessageStreamResponse>.Contents
                switch response.accepted {
                case .success(let c):
                    Task { @MainActor in
                        PerformanceMetrics.shared.end(.streamOpenStart, endEvent: .streamOpenEnd, label: metricsLabel)
                        ConnectionStatusManager.shared.markStreamConnected()
                        self.isConnected = true
                        self.lastHeartbeatDate = Date()
                        Log.info("✅ MessageStream RPC accepted — stream connected", category: "MessageStream")
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
                        if let msg = MessageStreamManager.convertStreamResponse(streamResponse) {
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

    // MARK: - Convert Response (nonisolated)

    private nonisolated static func convertStreamResponse(
        _ response: Shared_Proto_Services_V1_MessageStreamResponse
    ) -> StreamEvent? {
        switch response.response {
        case .message(let envelope):
            // KEY_SYNC: server-triggered re-key signal — no encrypted payload, route directly
            if envelope.contentType == .keySync {
                Log.info("🔑 KEY_SYNC envelope from \(envelope.sender.userID.prefix(8))…", category: "MessageStream")
                return .keySyncRequest(envelope.sender.userID)
            }
            // SESSION_RESET_INIT: atomic END_SESSION + new X3DH session init in one delivery.
            // Must be checked BEFORE the END_SESSION payload-size heuristic (it has a real payload).
            if envelope.contentType == .sessionResetInit {
                guard let decoded = try? WirePayloadCoder.decode(envelope.encryptedPayload) else {
                    Log.info("⚠️ Failed to decode SESSION_RESET_INIT payload for message \(envelope.messageID)", category: "MessageStream")
                    return nil
                }
                Log.info("🔄 SESSION_RESET_INIT from \(envelope.sender.userID.prefix(8))… id=\(envelope.messageID.prefix(8))…", category: "MessageStream")
                return .message(ChatMessage(
                    id: envelope.messageID,
                    from: envelope.sender.userID,
                    to: envelope.recipient.userID,
                    messageType: "SESSION_RESET_INIT",
                    ephemeralPublicKey: Data(decoded.ephemeralPublicKey),
                    messageNumber: decoded.messageNumber,
                    content: decoded.content,
                    suiteId: 1,
                    timestamp: UInt64(envelope.timestamp),
                    oneTimePreKeyId: decoded.oneTimePreKeyId,
                    kemCiphertext: decoded.kemCiphertext ?? Data(),
                    contentType: 24,
                    kyberOtpkId: decoded.kyberOtpkId,
                    rawPayload: envelope.encryptedPayload
                ))
            }
            // END_SESSION: detect by contentType OR by payload size.
            // Servers may strip contentType when relaying — fall back to payload size:
            // real WirePayload is always ≥ WirePayloadCoder.headerSize (46) bytes;
            // END_SESSION uses Data(count:16), so any non-empty payload < 46 bytes is a control sentinel.
            let isEndSession = envelope.contentType == .sessionReset ||
                (!envelope.encryptedPayload.isEmpty && envelope.encryptedPayload.count < WirePayloadCoder.headerSize)
            if isEndSession {
                let detected = envelope.contentType == .sessionReset ? "contentType" : "sentinel payload (\(envelope.encryptedPayload.count)b)"
                Log.info("🛑 END_SESSION from \(envelope.sender.userID.prefix(8))… id=\(envelope.messageID.prefix(8))… detected via \(detected)", category: "MessageStream")
                return .message(ChatMessage(
                    id: envelope.messageID,
                    from: envelope.sender.userID,
                    to: envelope.recipient.userID,
                    messageType: "CONTROL_MESSAGE",
                    ephemeralPublicKey: Data(),
                    messageNumber: 0,
                    content: "END_SESSION",
                    suiteId: 1,
                    timestamp: UInt64(envelope.timestamp),
                    kemCiphertext: Data(),
                    kyberOtpkId: 0
                ))
            }
            // SENDER_SYNC: copy of own outgoing message — decrypt with per-device session
            if envelope.contentType == .senderSync {
                guard let decoded = try? WirePayloadCoder.decode(envelope.encryptedPayload) else {
                    Log.info("⚠️ Failed to decode SENDER_SYNC payload for message \(envelope.messageID)", category: "MessageStream")
                    return nil
                }
                Log.info("🔄 SENDER_SYNC from device \(envelope.senderDevice.deviceID.prefix(8))… id=\(envelope.messageID.prefix(8))…", category: "MessageStream")
                return .message(ChatMessage(
                    id: envelope.messageID,
                    from: envelope.sender.userID,
                    to: envelope.recipient.userID,
                    messageType: "SENDER_SYNC",
                    ephemeralPublicKey: Data(decoded.ephemeralPublicKey),
                    messageNumber: decoded.messageNumber,
                    content: decoded.content,
                    suiteId: 1,
                    timestamp: UInt64(envelope.timestamp),
                    oneTimePreKeyId: decoded.oneTimePreKeyId,
                    kemCiphertext: decoded.kemCiphertext ?? Data(),
                    kyberOtpkId: decoded.kyberOtpkId,
                    senderDeviceId: envelope.senderDevice.deviceID,
                    conversationId: envelope.conversationID
                ))
            }
            // Unpack wire payload blob into crypto components
            guard let decoded = try? WirePayloadCoder.decode(envelope.encryptedPayload) else {
                Log.info("⚠️ Failed to decode encrypted_payload for message \(envelope.messageID)", category: "MessageStream")
                return nil
            }
            let msg = ChatMessage(
                id: envelope.messageID,
                from: envelope.sender.userID,
                to: envelope.recipient.userID,
                messageType: "DIRECT_MESSAGE",
                ephemeralPublicKey: Data(decoded.ephemeralPublicKey),
                messageNumber: decoded.messageNumber,
                content: decoded.content,
                suiteId: 1,
                timestamp: UInt64(envelope.timestamp),
                oneTimePreKeyId: decoded.oneTimePreKeyId,
                editsMessageId: envelope.editsMessageID,
                kemCiphertext: decoded.kemCiphertext ?? Data(),
                contentType: UInt8(envelope.contentType.rawValue),
                kyberOtpkId: decoded.kyberOtpkId,
                senderDeviceId: envelope.senderDevice.deviceID,
                conversationId: envelope.conversationID,
                replyToMessageId: envelope.replyToMessageID,
                rawPayload: envelope.encryptedPayload
            )
            PerformanceMetrics.shared.messageEnvelopeArrived(messageId: envelope.messageID)
            return .message(msg)
        case .receipt(let receipt):
            // Deliver receipt: extract confirmed message IDs and propagate
            if case .direct(let directReceipt) = receipt.receiptType,
               directReceipt.status == .delivered,
               !directReceipt.messageIds.isEmpty {
                return .deliveryReceipt(directReceipt.messageIds)
            }
            return nil
        case .typing(let indicator):
            Log.debug("✍️ Typing: \(indicator.userID) in \(indicator.conversationID)", category: "MessageStream")
            return nil
        case .ack(let ack):
            Log.debug("✅ Message ack: \(ack.messageID)", category: "MessageStream")
            return nil
        case .error(let error):
            Log.error("❌ Stream error: \(error.errorCode) - \(error.errorMessage)", category: "MessageStream")
            return nil
        case .presence(let update):
            Log.debug("👤 Presence: \(update.userID)", category: "MessageStream")
            return nil
        case .heartbeatAck(let ack):
            Log.debug("💓 Heartbeat ack: server=\(ack.serverTimestamp)", category: "MessageStream")
            Task { @MainActor in
                ConnectionStatusManager.shared.markStreamConnected()
            }
            return .heartbeat
        case .none:
            return nil
        }
    }

    private func checkHeartbeatAndReconnectIfStale() {
        guard isConnected else { return }
        guard let last = lastHeartbeatDate else { return }
        let timeout = heartbeatInterval * heartbeatTimeoutMultiplier
        let elapsed = Date().timeIntervalSince(last)
        guard elapsed > timeout else { return }

        if let lastRestartAt = lastWatchdogRestartAt,
           Date().timeIntervalSince(lastRestartAt) < watchdogMinRestartInterval {
            return
        }
        lastWatchdogRestartAt = Date()

        Log.info("💔 Heartbeat timeout (\(Int(elapsed))s) — restarting MessageStream", category: "MessageStream")
        guard let cb = onMessageReceived else { return }
        forceReconnect(contactUserIds: subscriptionUserIds, onMessageReceived: cb)
    }
}
