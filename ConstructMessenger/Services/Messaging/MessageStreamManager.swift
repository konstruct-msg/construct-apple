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
    case message(ChatMessage, cursor: String?)
    case deliveryReceipt([String], cursor: String?)    // message IDs confirmed delivered to recipient
    case keySyncRequest(String, cursor: String?)       // server-triggered X3DH re-init for userId
    case heartbeat(cursor: String?)                    // server heartbeat ack
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

    // MARK: - Transport (injectable for testing)

    let transport: any StreamTransport

    private init(transport: any StreamTransport = GRPCStreamTransport()) {
        self.transport = transport
    }

    deinit {
        MainActor.assumeIsolated {
            if let obs = serverChangedObserver {
                NotificationCenter.default.removeObserver(obs)
            }
            if let obs = networkPathChangedObserver {
                NotificationCenter.default.removeObserver(obs)
            }
        }
    }

    // MARK: - State

    var isConnected = false
    /// Set to the current time whenever a heartbeat ack is received from the server.
    var lastHeartbeatDate: Date?
    /// Transport protocol of the active stream connection ("H3" = QUIC, "H2" = HTTP/2, "" = not connected).
    var activeTransport: String = ""
    /// Last transport that was successfully used; persists across disconnects for display purposes.
    var lastActiveTransport: String = ""

    /// True when a connection attempt is actively in progress (not sleeping in backoff).
    /// When true, app-foreground force-reconnect should be skipped to avoid interrupting
    /// an ongoing VEIL failover path with a new competing direct-path attempt.
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
    /// True once the server has pushed *any* event since `openStream()` accept.
    /// Reset to false on each new openStream. Drives the first-event watchdog: if
    /// nothing has arrived from the server within `firstServerEventWatchdogH3` seconds
    /// (only on H3 — we don't watchdog H2/VEIL this tightly), we treat H3 as silently
    /// broken (DPI dropped UDP after handshake) and force fallback to H2.
    var firstServerEventReceived: Bool = false
    private var serverChangedObserver: NSObjectProtocol?
    private var networkPathChangedObserver: NSObjectProtocol?
    private var retryCount = 0
    private let maxRetryDelay: TimeInterval = NetworkTiming.Stream.maxRetryDelay
    /// When `true`, the next `openStream()` call uses H2 direct instead of H3.
    /// Set in connectLoop when H3 direct times out — gives H2 a chance on the same host
    /// before escalating to VEIL relay (H3 may be blocked/unsupported while H2 works fine).
    var shouldFallbackToH2Direct = false
    /// Records whether the most recent `openStream()` call attempted H3 transport.
    /// Used by connectLoop to decide whether to try H2 direct before activating VEIL.
    var lastStreamTransportWasH3 = false
    /// Counts consecutive H3 stream-open failures across reconnects and network changes.
    /// Not reset by forceDisconnect() so it survives network path switches.
    /// Cleared when H3 succeeds or the stream ends cleanly.
    var consecutiveH3OpenFailures = 0
    static let h3OpenFailureThreshold = 2
    /// Session-level suppression of the fast-UDP transport (native H3 / engine-QUIC) after it
    /// proves unhealthy on this network — e.g. QUIC connects then dies at the idle timeout every
    /// ~30s because DPI throttles UDP. Without this, each reconnect re-tries QUIC, dies, falls to
    /// H2, and (on a clean H2 end) resets the counter → endless QUIC thrash. While set in the
    /// future, `openStream()` goes straight to H2. Reset by an explicit transport toggle.
    var fastUdpUnhealthyUntil: Date?
    static let fastUdpCooldown: TimeInterval = 300
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

    // MARK: - Low-power degraded mode (P3: battery optimisation for prolonged offline)

    /// Wall-clock timestamp when the connect loop first entered a continuous-failure streak.
    /// Reset on any success, clean disconnect, or network path change.
    private var continuousFailureStreakStart: Date?

    /// After this many minutes of uninterrupted failures, the loop switches to low-power mode:
    /// skips `fetchMissedMessages`, skips VEIL `prepare()`, and uses a longer backoff.
    private let degradedModeThreshold: TimeInterval = 5 * 60  // 5 minutes

    /// Backoff used in degraded mode — longer sleep between retries to conserve battery.
    private let degradedModeBackoff: TimeInterval = 10 * 60  // 10 minutes

    /// Set to true when the loop is in low-power mode.
    private(set) var isInDegradedMode = false

    /// Whether the connect loop should skip expensive pre-stream operations.
    private var isInDegradedModeWindow: Bool {
        guard let start = continuousFailureStreakStart else { return false }
        return Date().timeIntervalSince(start) >= degradedModeThreshold
    }

    /// Called on network path change — resets degraded state and forces an immediate
    /// stream reconnect. Without the forced reconnect, the stream can stay bound to the
    /// old (dead) connection for up to a full heartbeat-watchdog interval (~90s).
    func onNetworkPathChanged() {
        continuousFailureStreakStart = nil
        isInDegradedMode = false
        // No stream running — degraded-mode clear is all that's needed.
        guard streamTask != nil || isConnected else {
            Log.info("Network path changed — cleared degraded mode (no active stream)", category: "MessageStream")
            return
        }
        let ids = subscriptionUserIds
        let cb = onMessageReceived
        guard let cb else {
            Log.info("Network path changed — no callback, not forcing reconnect", category: "MessageStream")
            return
        }
        Log.info("Network path changed — forcing stream reconnect", category: "MessageStream")
        forceDisconnect()
        connect(contactUserIds: ids, onMessageReceived: cb)
    }

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
            Log.info("Subscriptions changed (\(subscriptionUserIds.count)→\(contactUserIds.count)) — reconnecting stream", category: "MessageStream")
            forceDisconnect()
        }

        self.subscriptionUserIds = contactUserIds
        if isPaused { ConnectionStatusManager.shared.markStreamResumed() }
        isPaused = false

        // Already fully connected with up-to-date subscriptions.
        guard !isConnected else {
            Log.info("MessageStream already connected", category: "MessageStream")
            return
        }

        // connectLoop is already running (in backoff between retries) — don't stack tasks.
        guard streamTask == nil else {
            Log.info("MessageStream already reconnecting", category: "MessageStream")
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
                Log.info("gRPC server changed — reconnecting stream", category: "MessageStream")
                Task { @MainActor in
                    let ids = self.subscriptionUserIds
                    let cb = self.onMessageReceived
                    self.forceDisconnect()
                    if let cb { self.connect(contactUserIds: ids, onMessageReceived: cb) }
                }
            }
        }

        // Force stream reconnect on network path change. Guarded so repeated `connect()`
        // calls don't stack observers.
        if networkPathChangedObserver == nil {
            networkPathChangedObserver = NotificationCenter.default.addObserver(
                forName: .networkPathChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.onNetworkPathChanged() }
            }
        }

        Log.info("Starting MessageStream connection (subscribed to \(contactUserIds.count) contacts)", category: "MessageStream")
        connectStartTime = Date()
        streamTask = Task { [weak self] in
            await self?.connectLoop()
        }
    }

    /// Cancel any in-progress backoff/connection and start fresh immediately.
    /// Use when returning from background or recovering from a known-bad state.
    /// Re-open the stream using the stored subscriptions/handler so a transport change
    /// (toggling the engine-QUIC experiment in Settings → Network) takes effect immediately.
    /// Invalidates the persistent H2 + engine-QUIC channels first so the next open builds the
    /// newly-selected transport from scratch. The resulting active transport surfaces as the
    /// badge in NetworkSettingsView ("QUIC" vs "H2").
    func reconnectForTransportChange() {
        GRPCChannelManager.shared.invalidatePersistentClient()
#if os(iOS)
        GRPCChannelManager.shared.forceInvalidateEngineQuicConnection()
#endif
        let ids = subscriptionUserIds
        guard let cb = onMessageReceived else {
            Log.info("Transport toggle — no callback yet, nothing to reconnect", category: "MessageStream")
            return
        }
        // Explicit toggle = give the chosen transport a clean slate (clear QUIC suppression).
        fastUdpUnhealthyUntil = nil
        consecutiveH3OpenFailures = 0
        shouldFallbackToH2Direct = false
        Log.info("Transport toggle (engineQuic=\(FeatureFlags.engineQuicExperimental)) — forcing stream reconnect", category: "MessageStream")
        forceDisconnect()
        connect(contactUserIds: ids, onMessageReceived: cb)
    }

    func forceReconnect(contactUserIds: [String], onMessageReceived: @escaping (ChatMessage) -> Void) {
        // Don't downgrade an active subscription list to empty.
        // This happens when forceReconnect fires while CoreData hasn't settled yet (context
        // returns [] transiently). Tearing down the live stream and reconnecting with 0
        // subscriptions sends an empty subscribe request — the server never sends a heartbeat
        // for it, so the connectLoop times out and retries forever with subscriptions=[].
        // Mirrors the identical guard in ChatsViewModel.startMessageStream().
        guard !contactUserIds.isEmpty || subscriptionUserIds.isEmpty else {
            Log.debug("forceReconnect skipped — empty ids would clear \(subscriptionUserIds.count) active subscriptions", category: "MessageStream")
            return
        }
        Log.info("Force reconnecting stream", category: "MessageStream")
        // Finish the outbound stream BEFORE cancelling the task.
        // Cancelling the Task first while the producer is mid-write triggers an
        // assertionFailure inside GRPCStreamStateMachine ("Client is closed, cannot send a
        // message.") because NIO force-closes the stream before the write completes.
        // Finishing the continuation first lets the producer's `for await` drain naturally;
        // task cancellation then only aborts a sleeping backoff or an idle await point.
        isConnected = false
        activeTransport = ""
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

        shouldFallbackToH2Direct = false
        lastStreamTransportWasH3 = false
        consecutiveH3OpenFailures = 0
        continuousFailureStreakStart = nil
        isInDegradedMode = false
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
        activeTransport = ""
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

        shouldFallbackToH2Direct = false
        lastStreamTransportWasH3 = false
        continuousFailureStreakStart = nil
        isInDegradedMode = false
        Log.info("MessageStream disconnected", category: "MessageStream")
    }

    func pause() {
        guard !isPaused else { return }
        isPaused = true
        ConnectionStatusManager.shared.markStreamPaused()
        disconnect()
        Log.info("MessageStream paused", category: "MessageStream")
    }

    func resume(onMessageReceived: @escaping (ChatMessage) -> Void) {
        guard isPaused else { return }
        isPaused = false
        ConnectionStatusManager.shared.markStreamResumed()
        Log.info("MessageStream resuming", category: "MessageStream")
        connect(contactUserIds: subscriptionUserIds, onMessageReceived: onMessageReceived)
    }

    // MARK: - Send via Stream

    func sendHeartbeat() {
        var hb = Shared_Proto_Services_V1_Heartbeat()
        hb.timestamp = Int64(Date().timeIntervalSince1970)
        var req = Shared_Proto_Services_V1_MessageStreamRequest()
        req.request = .heartbeat(hb)
        if outboundContinuation != nil {
            outboundContinuation?.yield(req)
            Log.debug("Heartbeat sent (outbound stream alive)", category: "MessageStream")
        } else {
            Log.info("Heartbeat skipped — outbound stream is nil", category: "MessageStream")
        }
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
            Log.info("Receipt queued (stream not open): \(status) for \(messageIds.count) msg(s) → recipient=\(recipientUserId.prefix(8))…", category: "MessageStream")
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
        Log.info("Receipt sent: \(status) for \(messageIds.count) msg(s) → recipient=\(recipientUserId.prefix(8))…", category: "MessageStream")
    }

    // MARK: - Private: Connection Loop

    private func connectLoop() async {
        let host = GRPCChannelManager.shared.currentHost
        let port = GRPCChannelManager.shared.currentPort
        Log.info("MessageStream connectLoop started → \(host):\(port)", category: "MessageStream")

        while !Task.isCancelled {
            let attemptStart = Date()
            let routingKeyAtLoopStart = GRPCChannelManager.shared.currentRoutingKey
            // Cancel any background fetch left over from the previous iteration.
            backgroundFetchTask?.cancel()

            // Fetch messages that arrived while disconnected — skip in degraded mode
            // to avoid wasteful RPCs when the network is clearly down for a long time.
            if !isInDegradedMode {
                let fetchTask = Task { await self.fetchMissedMessages() }
                backgroundFetchTask = fetchTask

                // Advance to openStream after wall-clock cap OR when fetch completes,
                // whichever fires first. fetchTask is NOT cancelled — it continues as a
                // background task alongside the live stream.
                //
                // IMPORTANT: do NOT use withTaskGroup { await fetchTask.value } here.
                // task.value ignores cooperative cancellation of the caller — the group
                // would block for the full 30 s RPC timeout even after the cap fires.
                let fetchCapDuration = NetworkTiming.Stream.fetchMissedMessagesWallClockCap
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
                    Log.debug("fetchMissedMessages completed (cap=\(fetchCapDuration)s not reached) — opening stream", category: "MessageStream")
                } else {
                    Log.debug("fetchMissedMessages wall-clock cap reached (\(fetchCapDuration)s) — opening stream while fetch continues in background", category: "MessageStream")
                }
            } else {
                Log.debug("Skipping fetchMissedMessages — degraded mode", category: "MessageStream")
            }

            guard !Task.isCancelled else { break }

            Log.info("connectLoop: fetchMissedMessages done, isCancelled=\(Task.isCancelled) — opening stream", category: "MessageStream")

            // TransportRouter maintains VEIL state continuously; no explicit prepare needed.
            // We just read whatever the router has set as current routing.
            let routerSnapshot = await TransportRouter.shared.snapshot()
            do {
                try await openStream()
                // Stream ended cleanly — brief pause before reconnecting to avoid tight loop
                // (e.g. server closes stream when 0 topics are subscribed)
                Log.info("MessageStream ended cleanly, reconnecting in \(Int(NetworkTiming.Stream.cleanEndReconnectDelay))s", category: "MessageStream")
                // Report stream-level success to the router so the FSM moves to .veilActive
                // (or stays in .direct(0)). Latency is unknown for a stream lifecycle event;
                // we pass 0 — relay scoring should not penalise this case.
                let okTarget: TransportTarget
                if let port = GRPCChannelManager.shared.veilProxyPort(),
                   let addr = routerSnapshot.state.currentRelay {
                    okTarget = .veil(port: port, relay: addr)
                } else {
                    okTarget = .direct(.h2)
                }
                await TransportRouter.shared.send(.rpcSucceeded(via: okTarget, latencyMs: 0))
                retryCount = 0
                shouldFallbackToH2Direct = false
                lastStreamTransportWasH3 = false
                consecutiveH3OpenFailures = 0
                continuousFailureStreakStart = nil
                isInDegradedMode = false
                try await Task.sleep(for: .seconds(NetworkTiming.Stream.cleanEndReconnectDelay))
            } catch is CancellationError {
                Log.info("MessageStream cancelled — connectLoop exiting", category: "MessageStream")
                break
            } catch {
                guard !Task.isCancelled else { break }
                // If the stream was rejected due to expired token, refresh and retry immediately
                // (skip exponential backoff to reduce perceived downtime).
                if let rpcError = error as? RPCError, rpcError.code == .unauthenticated {
                    Log.info("MessageStream unauthenticated — attempting token refresh", category: "MessageStream")
                    var refreshError: Error?
                    do {
                        let refreshed = try await TokenRefreshCoordinator.shared.refreshIfPossible()
                        if refreshed {
                            retryCount = 0
                            continue
                        }
                    } catch {
                        refreshError = error
                        Log.error("Token refresh failed for MessageStream: \(error)", category: "MessageStream")
                    }
                    // Only wipe tokens if the server explicitly rejected the refresh token.
                    // Network errors mean the refresh was unreachable, not that the token is invalid.
                    let serverRejected: Bool
                    if let rpcErr = refreshError {
                        serverRejected = TokenRefreshCoordinator.isRefreshTokenPermanentlyInvalid(rpcErr)
                    } else {
                        serverRejected = refreshError == nil  // returned false = no refresh token
                    }
                    if serverRejected {
                        // Untrusted-relay gate: a hostile or broken VEIL relay can synthesise
                        // an UNAUTHENTICATED response indistinguishable from a real one. Only
                        // honor the rejection when the stream was opened over the direct path.
                        // On VEIL: rotate the relay and retry; if the rejection is real it will
                        // surface again on a clean relay (or on direct) and be honored there.
                        let streamWentThroughVEIL = GRPCChannelManager.shared.veilProxyPort() != nil
                            || routingKeyAtLoopStart.hasPrefix("ice:")
                        if streamWentThroughVEIL {
                            let snap = await TransportRouter.shared.snapshot()
                            let relayAddr = snap.state.currentRelay
                            Log.info("MessageStream refresh rejected over VEIL relay \(relayAddr ?? "?") — not wiping tokens, will rotate", category: "MessageStream")
                            if let port = GRPCChannelManager.shared.veilProxyPort(), let addr = relayAddr {
                                await TransportRouter.shared.send(
                                    .rpcFailed(kind: .tlsFingerprintBlocked,
                                               via: .veil(port: port, relay: addr),
                                               foreground: true)
                                )
                            }
                        } else {
                            Log.info("MessageStream refresh rejected by server — triggering device re-auth", category: "MessageStream")
                            AuthSessionManager.shared.invalidateTokensForReauth()
                        }
                    } else {
                        Log.info("MessageStream refresh failed (network error) — keeping tokens, will retry later", category: "MessageStream")
                    }
                }
                // Fast failover path: openStream() throws this sentinel to force an immediate
                // reconnect without exponential backoff.
                if let rpcError = error as? RPCError,
                   rpcError.code == .unavailable,
                   rpcError.message.contains("retrying with VEIL") {
                    // Route the failure through the FSM so it decides VEIL escalation / relay rotation.
                    let kind = RPCFailureClassifier.classify(rpcError)
                    let failTarget: TransportTarget = routingKeyAtLoopStart.hasPrefix("veil:")
                        ? .veil(port: GRPCChannelManager.shared.veilProxyPort() ?? 0,
                               relay: routerSnapshot.state.currentRelay ?? "")
                        : .direct(.h2)
                    await TransportRouter.shared.send(.rpcFailed(kind: kind, via: failTarget, foreground: true))
                    if lastStreamTransportWasH3 {
                        consecutiveH3OpenFailures += 1
                        Log.info("H3 open failure #\(consecutiveH3OpenFailures)/\(Self.h3OpenFailureThreshold)", category: "MessageStream")
                        if consecutiveH3OpenFailures >= Self.h3OpenFailureThreshold {
                            fastUdpUnhealthyUntil = Date().addingTimeInterval(Self.fastUdpCooldown)
                            Log.info("Fast-UDP (QUIC/H3) suppressed \(Int(Self.fastUdpCooldown))s — using H2", category: "MessageStream")
                        }
                    }
                    // H3→H2 fallback: if H3 failed on the direct path and VEIL isn't active yet,
                    // try H2 once before activating VEIL (H3 may be unsupported, not blocked).
                    let routingKeyNow = GRPCChannelManager.shared.currentRoutingKey
                    let nowUsingVEIL = await TransportRouter.shared.snapshot().state.prefersVEIL
                    if !nowUsingVEIL, routingKeyNow == routingKeyAtLoopStart,
                       routingKeyAtLoopStart.hasPrefix("direct:"), lastStreamTransportWasH3 {
                        shouldFallbackToH2Direct = true
                        Log.info("H3 direct timeout — trying H2 direct next", category: "MessageStream")
                    } else {
                        shouldFallbackToH2Direct = false
                        lastStreamTransportWasH3 = false
                    }
                    Log.info("MessageStream reconnecting immediately (VEIL=\(nowUsingVEIL))", category: "MessageStream")
                    backgroundFetchTask?.cancel()
                    retryCount = 0
                    continue
                }
                // Generic stream failure → feed to the FSM.
                let kind = RPCFailureClassifier.classify(error)
                let failTarget: TransportTarget = routingKeyAtLoopStart.hasPrefix("veil:")
                    ? .veil(port: GRPCChannelManager.shared.veilProxyPort() ?? 0,
                           relay: routerSnapshot.state.currentRelay ?? "")
                    : .direct(.h2)
                await TransportRouter.shared.send(.rpcFailed(kind: kind, via: failTarget, foreground: true))
                if lastStreamTransportWasH3 {
                    consecutiveH3OpenFailures += 1
                    Log.info("H3 failure #\(consecutiveH3OpenFailures)/\(Self.h3OpenFailureThreshold)", category: "MessageStream")
                    if consecutiveH3OpenFailures >= Self.h3OpenFailureThreshold {
                        fastUdpUnhealthyUntil = Date().addingTimeInterval(Self.fastUdpCooldown)
                        Log.info("Fast-UDP (QUIC/H3) suppressed \(Int(Self.fastUdpCooldown))s — DPI/idle death on this network, using H2", category: "MessageStream")
                    }
                }
                // Log full error details for diagnosis
                if let rpcError = error as? RPCError {
                    Log.error("""
                        MessageStream RPC error:
                           code    = \(rpcError.code)
                           message = \(rpcError.message)
                           host    = \(host):\(port)
                           attempt = #\(retryCount + 1)
                        """, category: "MessageStream")
                } else {
                    Log.error("MessageStream error (attempt #\(retryCount + 1)): \(error)", category: "MessageStream")
                }
                ConnectionStatusManager.shared.setLastError(error.localizedDescription)
            }

            guard !Task.isCancelled else { break }

            // Track continuous failure streak for degraded mode (P3).
            if continuousFailureStreakStart == nil {
                continuousFailureStreakStart = Date()
            }
            isInDegradedMode = isInDegradedModeWindow

            // Exponential backoff with ±30% jitter.
            // Wider spread than 25% reduces the thundering-herd effect: when many clients
            // disconnect simultaneously (server restart, network outage), their retries
            // are spread over a 60% window instead of bunching within 25% of the same delay.
            retryCount += 1
            let totalDelay: TimeInterval
            if isInDegradedMode {
                // Low-power mode: fixed long backoff to conserve battery during prolonged offline.
                totalDelay = NetworkTiming.jitter(degradedModeBackoff, fraction: 0.3)
                Log.info("MessageStream degraded mode — retrying in \(String(format: "%.0f", totalDelay))s (attempt #\(retryCount), streak: \(Int(Date().timeIntervalSince(continuousFailureStreakStart!)))s) → \(host):\(port)", category: "MessageStream")
            } else {
                let base: TimeInterval = NetworkTiming.Stream.backoffBaseDelay
                let delay = min(base * pow(2, Double(min(retryCount - 1, 5))), maxRetryDelay)
                totalDelay = max(0.1, NetworkTiming.jitter(delay, fraction: 0.3))
                let attemptMs = Int(Date().timeIntervalSince(attemptStart) * 1000)
                Log.info("MessageStream reconnecting in \(String(format: "%.1f", totalDelay))s (attempt #\(retryCount), took \(attemptMs)ms) → \(host):\(port)", category: "MessageStream")
            }
            do {
                try await Task.sleep(for: .seconds(totalDelay))
            } catch {
                // Task was cancelled during backoff sleep — exit immediately
                break
            }
        }
        Log.info("MessageStream connectLoop finished", category: "MessageStream")
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
            // INVARIANT: invalidatesConnectionOnFailure must remain false (default).
            // A fetch failure must not kill the live stream or penalise the current relay.
            let fetchResult: FetchResult = try await GRPCChannelManager.shared.performRPC(
                timeout: GRPCTimeouts.getPendingMessages
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
                Log.info("fetchMissedMessages: \(fetchResult.failed.count) undecryptable message(s) — will ACK as failed once stream opens", category: "MessageStream")
                pendingFailedAcks.append(contentsOf: fetchResult.failed)
            }

            if !fetchResult.messages.isEmpty {
                let fetchMs = Int(Date().timeIntervalSince(fetchStart) * 1000)
                Log.info("fetchMissedMessages: \(fetchMs)ms, \(fetchResult.messages.count) message(s) fetched", category: "MessageStream")
                for msg in fetchResult.messages {
                    onMessageReceived?(msg)
                }
            } else {
                let fetchMs = Int(Date().timeIntervalSince(fetchStart) * 1000)
                Log.debug("fetchMissedMessages: \(fetchMs)ms, no pending messages", category: "MessageStream")
            }
        } catch is CancellationError {
            // Task was cancelled during force-reconnect or backgrounding — expected, no log needed
            return
        } catch {
            if let rpcError = error as? RPCError {
                Log.error("fetchMissedMessages RPC error: code=\(rpcError.code) message=\"\(rpcError.message)\"", category: "MessageStream")
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

        Log.info("Heartbeat timeout (\(Int(elapsed))s) — restarting MessageStream", category: "MessageStream")
        guard let cb = onMessageReceived else { return }
        forceReconnect(contactUserIds: subscriptionUserIds, onMessageReceived: cb)
    }
}
