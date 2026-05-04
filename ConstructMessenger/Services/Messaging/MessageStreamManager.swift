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

enum StreamEvent: Sendable {
    case message(ChatMessage)
    case deliveryReceipt([String])    // message IDs confirmed delivered to recipient
    case keySyncRequest(String)       // server-triggered X3DH re-init for userId
    case heartbeat                    // server heartbeat ack
}

// MARK: - Stream Cursor Persistence

/// Persists the last Redis stream cursor so reconnects resume from the correct position.
enum StreamCursorStore {
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

    var isConnected = false
    /// Set to the current time whenever a heartbeat ack is received from the server.
    var lastHeartbeatDate: Date?

    /// True when a connection attempt is actively in progress (not sleeping in backoff).
    /// When true, app-foreground force-reconnect should be skipped to avoid interrupting
    /// an ongoing ICE failover path with a new competing direct-path attempt.
    var isActivelyConnecting: Bool { streamTask != nil && !isConnected && retryCount == 0 }

    // MARK: - Callbacks

    var onMessageReceived: ((ChatMessage) -> Void)?
    /// Called when a DeliveryReceipt arrives from the server.
    /// Provides the IDs of messages confirmed delivered to the recipient.
    var onDeliveryReceipt: (([String]) -> Void)?
    /// Called when server sends KEY_SYNC (contentType=22) — triggers X3DH re-init for userId.
    var onKeySyncReceived: ((String) -> Void)?

    // MARK: - Private State

    private var streamTask: Task<Void, Never>?
    var backgroundFetchTask: Task<Void, Never>?
    var heartbeatTask: Task<Void, Never>?
    var heartbeatWatchdogTask: Task<Void, Never>?
    private var serverChangedObserver: NSObjectProtocol?
    private var retryCount = 0
    private let maxRetryDelay: TimeInterval = NetworkTiming.Stream.maxRetryDelay
    /// Counts consecutive stream-open timeouts where the ICE routing key did NOT change
    /// (relay reachable at TCP level but streaming RPCs failing). After 2 consecutive
    /// unchanged-routing timeouts the current relay is blacklisted and rotation is forced.
    private var consecutiveRoutingUnchangedTimeouts = 0
    private(set) var isPaused = false
    private(set) var subscriptionUserIds: [String] = []
    private var lastPendingCursor: String = UserDefaults.standard.string(forKey: "construct.pendingCursor") ?? "" {
        didSet {
            UserDefaults.standard.set(lastPendingCursor, forKey: "construct.pendingCursor")
        }
    }

    /// Continuation for sending messages into the stream
    var outboundContinuation: AsyncStream<Shared_Proto_Services_V1_MessageStreamRequest>.Continuation?

    /// Monotonically increasing token for stream lifetimes. Used to prevent a previous
    /// stream's teardown from clobbering state of a newer connection (race during reconnect).
    var streamGeneration: UInt64 = 0
    var activeStreamGeneration: UInt64 = 0

    /// Messages that failed decoding during fetchMissedMessages (before stream was open).
    /// Flushed as `.failed` receipts once the stream is established.
    var pendingFailedAcks: [MessagingServiceClient.FailedMessage] = []

    /// Delivered receipts queued when the stream was not yet open.
    /// Flushed as `.delivered` receipts once the stream is established.
    struct PendingDeliveredAck {
        let messageIds: [String]
        let recipientUserId: String
    }
    var pendingDeliveredAcks: [PendingDeliveredAck] = []

    // MARK: - Configuration

    let heartbeatInterval: TimeInterval = NetworkTiming.Stream.heartbeatInterval
    private let heartbeatTimeoutMultiplier: Double = 3.0
    private var lastWatchdogRestartAt: Date?
    private let watchdogMinRestartInterval: TimeInterval = NetworkTiming.Stream.watchdogMinRestartInterval

    /// Timestamp of the latest connection attempt — used to compute total connect latency in logs.
    var connectStartTime: Date?

    // MARK: - Public API

    func connect(contactUserIds: [String] = [], onMessageReceived: @escaping (ChatMessage) -> Void) {
        self.onMessageReceived = onMessageReceived

        // Use Set comparison: currentConversationIds() builds from Array(Set) whose order is
        // non-deterministic across calls, so the same 3 IDs may arrive in a different order on
        // each reconnect attempt.  An order-sensitive != would trigger a spurious forceDisconnect()
        // even when the actual subscription set hasn't changed, causing the stream to loop.
        let subscriptionChanged = Set(contactUserIds) != Set(subscriptionUserIds)

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
        connectStartTime = Date()
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
    ///
    /// **Receipt semantics contract** — use the wrong status and you will loop forever:
    ///
    /// - `.delivered`: the message reached this device. The server advances its Redis stream
    ///   consumer-group cursor so the message is **never re-delivered**. Use this for ALL
    ///   session-layer failures (OTPK exhausted, AEAD failure, UTF-8 decode, session not found,
    ///   init_receiving_session failure, heal exhausted). The device handles recovery itself via
    ///   END_SESSION; it does NOT need the server to retry.
    ///
    /// - `.failed`: the server should **retry delivery later** (message stays in queue).
    ///   Reserve exclusively for genuine transport failures — e.g. the gRPC stream dropped
    ///   before the message was processed at all. Never use for crypto/session errors.
    ///
    /// - Parameters:
    ///   - messageIds: IDs of messages being acknowledged.
    ///   - recipientUserId: The original message sender — server uses this to route the receipt back without a DB lookup.
    ///   - status: `.delivered` to advance cursor; `.failed` for transport-only retry.
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
            let attemptStart = Date()
            let routingKeyAtLoopStart = GRPCChannelManager.shared.currentRoutingKey
            // Cancel any background fetch left over from the previous iteration.
            backgroundFetchTask?.cancel()

            // Fetch messages that arrived while disconnected. Run as an independent
            // Task so the wall-clock cap doesn't cancel it: pending messages live in
            // the server's queue and are NOT replayed via the live stream cursor.
            // The background task continues delivering them after openStream() starts.
            let fetchTask = Task { await self.fetchMissedMessages() }
            backgroundFetchTask = fetchTask

            // Advance to openStream after wall-clock cap OR when fetch completes,
            // whichever fires first. fetchTask is NOT cancelled — it continues as a
            // background task alongside the live stream.
            //
            // IMPORTANT: do NOT use withTaskGroup { await fetchTask.value } here.
            // task.value ignores cooperative cancellation of the caller — the group
            // would block for the full 30 s RPC timeout even after the cap fires.
            //
            // Use the shorter cap when the relay is already verified: its RPC latency
            // is ≤1 RTT (≈100ms for AMS), so 0.5s is more than enough.
            let fetchCapDuration = IceProxyManager.shared.isCurrentRelayVerified
                ? NetworkTiming.Stream.fetchMissedMessagesWallClockCapVerified
                : NetworkTiming.Stream.fetchMissedMessagesWallClockCap
            let capSleep = Task<Void, any Error> {
                try await Task.sleep(for: .seconds(fetchCapDuration))
            }
            // Cancel the sleep early once fetch completes so we don't wait the full cap.
            var fetchCompletedBeforeCap = false
            Task { [capSleep] in _ = await fetchTask.value; fetchCompletedBeforeCap = true; capSleep.cancel() }
            // Also cancel if the outer connectLoop task is cancelled.
            await withTaskCancellationHandler {
                try? await capSleep.value
            } onCancel: {
                capSleep.cancel()
            }
            guard !Task.isCancelled else { break }
            if fetchCompletedBeforeCap {
                Log.debug("📬 fetchMissedMessages completed (cap=\(fetchCapDuration)s not reached) — opening stream", category: "MessageStream")
            } else {
                Log.debug("⏰ fetchMissedMessages wall-clock cap reached (\(fetchCapDuration)s) — opening stream while fetch continues in background", category: "MessageStream")
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
                consecutiveRoutingUnchangedTimeouts = 0
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
                    // Check whether the routing key actually changed during the failover
                    // attempt inside openStream(). "Unchanged" means the relay is reachable
                    // at TCP level but streaming RPCs are silently failing (e.g. relay v0.3.3
                    // obfs4 session corruption bug).
                    let routingKeyNow = GRPCChannelManager.shared.currentRoutingKey
                    if routingKeyNow == routingKeyAtLoopStart {
                        consecutiveRoutingUnchangedTimeouts += 1
                        if consecutiveRoutingUnchangedTimeouts >= 1,
                           routingKeyAtLoopStart.hasPrefix("ice:"),
                           let failedAddr = IceProxyManager.shared.activeRelay?.address {
                            // ICE path: streaming keeps failing on this relay → blacklist + rotate.
                            Log.error("🧊 \(consecutiveRoutingUnchangedTimeouts) consecutive stream timeouts on same relay \(failedAddr) — blacklisting and forcing rotation", category: "MessageStream")
                            IceProxyManager.shared.recordRelayFailure(address: failedAddr)
                            let rotated = await IceProxyManager.shared.rotateToNextRelay()
                            if rotated {
                                GRPCChannelManager.shared.invalidatePersistentClient()
                            }
                            consecutiveRoutingUnchangedTimeouts = 0
                        } else if IceProxyManager.shared.mode == .auto,
                                  routingKeyAtLoopStart.hasPrefix("direct:"),
                                  consecutiveRoutingUnchangedTimeouts >= 2 {
                            // Direct path + .auto mode: consecutive failures suggest DPI blocking.
                            // Threshold = 2: each cycle ~4s, so 2 cycles ≈ 8s total before ICE.
                            Log.info("🧊 \(consecutiveRoutingUnchangedTimeouts) direct stream timeouts in .auto mode — DPI suspected, activating ICE", category: "MessageStream")
                            await IceProxyManager.shared.activateDPIAutoMode()
                            if GRPCChannelManager.shared.iceProxyPort() != nil {
                                GRPCChannelManager.shared.invalidatePersistentClient()
                            }
                            consecutiveRoutingUnchangedTimeouts = 0
                        }
                    } else {
                        consecutiveRoutingUnchangedTimeouts = 0
                    }
                    Log.info("🧊 MessageStream switching routing — reconnecting immediately", category: "MessageStream")
                    // Cancel the background fetch started on the previous routing path.
                    // It would otherwise outlive the routing change and eventually kill
                    // the new connection when it times out (gen-mismatch guard catches it,
                    // but early cancellation avoids the wasted network traffic entirely).
                    backgroundFetchTask?.cancel()
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

            // Exponential backoff with ±30% jitter.
            // Wider spread than 25% reduces the thundering-herd effect: when many clients
            // disconnect simultaneously (server restart, network outage), their retries
            // are spread over a 60% window instead of bunching within 25% of the same delay.
            retryCount += 1
            let base: TimeInterval = NetworkTiming.Stream.backoffBaseDelay
            let delay = min(base * pow(2, Double(min(retryCount - 1, 5))), maxRetryDelay)
            let jitter = Double.random(in: -(delay * 0.3)...(delay * 0.3))
            let totalDelay = max(0.1, delay + jitter)
            let attemptMs = Int(Date().timeIntervalSince(attemptStart) * 1000)

            Log.info("⏳ MessageStream reconnecting in \(String(format: "%.1f", totalDelay))s (attempt #\(retryCount), took \(attemptMs)ms) → \(host):\(port)", category: "MessageStream")
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
        let fetchStart = Date()
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
            let fetchResult: FetchResult = try await GRPCChannelManager.shared.performRPC(
                timeout: GRPCTimeouts.getPendingMessages,
                // fetchMissedMessages only runs while the stream is not open (inside connectLoop,
                // before openStream). Allowing ICE rotation here is safe — there is no live stream
                // channel to kill, and it lets us escape a dead relay before openStream is called.
                invalidatesConnectionOnFailure: true
            ) { grpcClient in
                var cursor: String? = startCursor.isEmpty ? nil : startCursor
                var cursorToPersist: String = startCursor
                var messages: [ChatMessage] = []
                var failed: [MessagingServiceClient.FailedMessage] = []
                var failedIds: Set<String> = []
                var seenMessageIds: Set<String> = []

                while !Task.isCancelled {
                    // Snapshot the cursor to avoid capturing a mutable var across a suspension point.
                    let cursorSnapshot = cursor
                    let page: MessagingServiceClient.PendingMessagesResult = try await MessagingServiceClient.getPendingMessagesPage(
                        grpcClient: grpcClient,
                        sinceCursor: cursorSnapshot,
                        limit: 50
                    )

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

            lastPendingCursor = fetchResult.nextCursor

            if !fetchResult.failed.isEmpty {
                Log.info("⚠️ fetchMissedMessages: \(fetchResult.failed.count) undecryptable message(s) — will ACK as failed once stream opens", category: "MessageStream")
                pendingFailedAcks.append(contentsOf: fetchResult.failed)
            }

            if !fetchResult.messages.isEmpty {
                let fetchMs = Int(Date().timeIntervalSince(fetchStart) * 1000)
                Log.info("📨 fetchMissedMessages: \(fetchMs)ms, \(fetchResult.messages.count) message(s) fetched", category: "MessageStream")
                for msg in fetchResult.messages {
                    onMessageReceived?(msg)
                }
            } else {
                let fetchMs = Int(Date().timeIntervalSince(fetchStart) * 1000)
                Log.debug("📭 fetchMissedMessages: \(fetchMs)ms, no pending messages", category: "MessageStream")
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

    func checkHeartbeatAndReconnectIfStale() {
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
