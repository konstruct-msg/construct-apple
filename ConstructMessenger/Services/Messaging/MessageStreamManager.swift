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
            routingReconnectDebounce?.cancel()
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
    /// Routing key (`direct:host:port` / `ice:PORT`) of the stream that last reached `onAccepted`.
    /// Used to skip `serverChanged` reconnects when the live stream already rides the new route
    /// (VEIL failover storm: connectLoop opens ice:port, then debounced reconnect tears it down).
    /// Writable from `MessageStreamTransport` (same type, other file).
    var activeRoutingKey: String = ""

    /// True when a connectLoop is running and the stream is not yet live — includes backoff sleep.
    ///
    /// Build 587 heated the phone by treating only `retryCount == 0` as "connecting": after the
    /// first open failure the loop was still alive (sleeping or mid-open) but foreground settle
    /// saw `isActivelyConnecting == false` and called `forceReconnect`, killing the in-flight
    /// loop and starting another. Pure form: ``isActivelyConnecting(hasStreamTask:isConnected:)``.
    var isActivelyConnecting: Bool {
        Self.isActivelyConnecting(hasStreamTask: streamTask != nil, isConnected: isConnected)
    }

    /// Pure form of ``isActivelyConnecting`` — any live connectLoop owns the stream until accept.
    nonisolated static func isActivelyConnecting(hasStreamTask: Bool, isConnected: Bool) -> Bool {
        hasStreamTask && !isConnected
    }

    /// What to do after `openStream` throws the open-timeout sentinel (`retrying with VEIL`).
    enum OpenTimeoutDisposition: Equatable, Sendable {
        /// H3 on direct timed out — hop to H2 once without sleeping.
        case immediateTransportFailover
        /// Same path / already H2 / VEIL path — exponential backoff (no tight immediate loop).
        case exponentialBackoff
    }

    /// Build 587 log: `open timed out — reconnecting` → `reconnecting immediately (VEIL=false)`
    /// on every timeout, including same-path H2, while the app flapped active/background.
    /// Immediate continue is only for the H3→H2 transport hop; everything else must backoff.
    nonisolated static func openTimeoutDisposition(
        lastTransportWasH3: Bool,
        prefersVEIL: Bool,
        routingKeyUnchanged: Bool,
        wasDirectRouting: Bool
    ) -> OpenTimeoutDisposition {
        if !prefersVEIL, routingKeyUnchanged, wasDirectRouting, lastTransportWasH3 {
            return .immediateTransportFailover
        }
        return .exponentialBackoff
    }

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
    /// Coalesces bursty routing events (`grpcServerChanged`, network path) into one reconnect.
    private var routingReconnectDebounce: Task<Void, Never>?
    private static let routingReconnectDebounceDelay: Duration = .seconds(2)
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
    /// Which rung of `QuicSuppressionPolicy.ladder` this network sits on. Persisted, and — unlike
    /// the window — **not** cleared when the window lapses: an expired suppression is permission
    /// to probe again, not permission to forget what the probe found last time.
    var quicSuppressionStrikes = 0
    /// Session-level suppression of the fast-UDP transport (native H3 / engine-QUIC) after it
    /// proves unhealthy on this network — e.g. QUIC connects then dies at the idle timeout every
    /// ~30s because DPI throttles UDP. Without this, each reconnect re-tries QUIC, dies, falls to
    /// H2, and (on a clean H2 end) resets the counter → endless QUIC thrash. While set in the
    /// future, `openStream()` goes straight to H2. Reset by an explicit transport toggle.
    ///
    /// **Persisted across cold starts** (write-through, keyed by the network fingerprint): on a
    /// censored network the old in-memory-only suppression meant every launch re-probed QUIC and
    /// paid the "open → die at idle → fall to H2" tax before going sticky-H2. Persisting the window
    /// (scoped to the same network) skips that on relaunch. A genuine network change clears it
    /// (`resetDegradedModeOnNetworkChange` sets nil → write-through removes it; restore also requires
    /// a fingerprint match).
    private var _fastUdpUnhealthyUntil: Date?
    var fastUdpUnhealthyUntil: Date? {
        get { _fastUdpUnhealthyUntil }
        set {
            _fastUdpUnhealthyUntil = newValue
            Self.persistQuicSuppression(until: newValue, strikes: quicSuppressionStrikes)
        }
    }

    // v3: one record **per network** (`QuicSuppressionLedger`) instead of a single slot tagged with
    // the network it came from. v2 held one record, and `resetDegradedModeOnNetworkChange` cleared
    // it on every path switch — so leaving a network erased what the device had learned about it,
    // and coming back started from rung 0. On a phone that is several times an hour. Old v1/v2 keys
    // are ignored rather than migrated: a single record cannot say which network it described once
    // the identity has moved on.
    private static let quicLedgerKey = "quic_suppression_ledger_v3"
    private static let quicLedgerSaltKey = "quic_suppression_ledger_salt_v3"

    /// Per-install salt for the ledger's network keys. Random, local, and never leaves the device —
    /// see QuicSuppressionLedger on why the identities themselves are not written down.
    private static func ledgerSalt() -> Data {
        let d = UserDefaults.standard
        if let existing = d.data(forKey: quicLedgerSaltKey), existing.count == 16 { return existing }
        let fresh = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        d.set(fresh, forKey: quicLedgerSaltKey)
        return fresh
    }

    private static func loadLedger() -> [String: QuicSuppressionLedger.Record] {
        guard let data = UserDefaults.standard.data(forKey: quicLedgerKey),
              let decoded = try? JSONDecoder().decode([String: QuicSuppressionLedger.Record].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func saveLedger(_ ledger: [String: QuicSuppressionLedger.Record]) {
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        UserDefaults.standard.set(data, forKey: quicLedgerKey)
    }

    /// Ledger key for the network the device is on right now, or "" when the monitor has not
    /// reported yet (in which case nothing is stored or restored — an unattributed record is worse
    /// than none, because it would be applied to whatever network comes next).
    private static func currentLedgerKey() -> String {
        QuicSuppressionLedger.key(
            for: NetworkReachabilityManager.shared.currentNetworkIdentity,
            salt: ledgerSalt()
        )
    }
    /// One-shot guard so the persisted suppression is restored at most once per launch (at the first
    /// connect, by when the network monitor has reported a fingerprint).
    private var didRestoreQuicSuppression = false

    /// Write-through the suppression window **and the ladder rung** to `UserDefaults`, tagged with
    /// the current network identity. Clearing the window keeps the rung: the two are separate
    /// facts, and conflating them is what made this unable to converge.
    private static func persistQuicSuppression(until: Date?, strikes: Int) {
        let key = currentLedgerKey()
        guard !key.isEmpty else { return }
        let effectiveUntil = (until.map { $0 > Date() } ?? false) ? until : nil
        saveLedger(
            QuicSuppressionLedger.remembering(
                loadLedger(),
                network: key,
                strikes: strikes,
                suppressedUntil: effectiveUntil,
                now: Date()
            )
        )
    }

    /// Load what this device already knows about the network it is on now.
    ///
    /// Used both at launch and on every path change. The path change is the important one: the
    /// ladder is deliberately re-evaluated when you move, and before the ledger that re-evaluation
    /// could only ever mean "forget everything", so returning to a network you had already judged
    /// cost the full probe again.
    private func adoptLadderForCurrentNetwork(reason: String) {
        let key = Self.currentLedgerKey()
        let state = QuicSuppressionLedger.stateOnArrival(
            at: key,
            store: Self.loadLedger(),
            now: Date()
        )
        quicSuppressionStrikes = state.strikes
        _fastUdpUnhealthyUntil = state.suppressedUntil   // read back from storage; do not re-persist
        consecutiveH3OpenFailures = 0
        if let until = state.suppressedUntil {
            Log.info("QUIC suppression adopted (\(reason), rung \(state.strikes), \(Int(until.timeIntervalSinceNow))s left) — starting on H2", category: "MessageStream")
        } else if state.strikes > 0 {
            Log.info("QUIC suppression lapsed (\(reason), rung \(state.strikes)) — probing once; another failure suppresses for \(Int(QuicSuppressionPolicy.window(afterStrikes: state.strikes) / 60))min", category: "MessageStream")
        } else {
            Log.info("QUIC ladder clear (\(reason)) — this network has taught us nothing yet, probing", category: "MessageStream")
        }
    }

    /// Restore the persisted QUIC record once per launch, for this network only.
    ///
    /// Two things come back, and they expire differently: the window (still in force → start on H2
    /// without probing) and the rung (survives expiry → the next failure escalates instead of
    /// restarting the ladder). A different or unknown network restores neither — what we learned
    /// is a claim about a network, not about the device.
    private func restoreQuicSuppressionOnceIfNeeded() {
        guard !didRestoreQuicSuppression else { return }
        didRestoreQuicSuppression = true
        adoptLadderForCurrentNetwork(reason: "launch")
    }

    /// One authority for "the fast-UDP transport failed to open". Both failure paths in
    /// `connectLoop` used to carry their own copy of the threshold test and the cooldown
    /// arithmetic; they had already drifted apart (only one of them set `shouldFallbackToH2Direct`).
    func noteFastUdpOpenFailure(context: String) {
        consecutiveH3OpenFailures += 1
        let needed = QuicSuppressionPolicy.failuresBeforeSuppressing(strikes: quicSuppressionStrikes)
        Log.info("Fast-UDP open failure #\(consecutiveH3OpenFailures)/\(needed) [\(context)] (network rung \(quicSuppressionStrikes))", category: "MessageStream")
        guard consecutiveH3OpenFailures >= needed else { return }
        let window = QuicSuppressionPolicy.window(afterStrikes: quicSuppressionStrikes)
        quicSuppressionStrikes += 1
        fastUdpUnhealthyUntil = Date().addingTimeInterval(window)   // setter persists rung + window
        PerformanceMetrics.shared.record(.quicSuppressed, label: "rung\(quicSuppressionStrikes)")
        Log.info("Fast-UDP (QUIC/H3) suppressed \(Int(window))s on this network — using H2 (rung \(quicSuppressionStrikes))", category: "MessageStream")
        // Router must see suppressions (ADR transport-connection-health-and-escalation).
        let ttl = Int(window.rounded(.up))
        Task {
            await TransportRouter.shared.send(.streamSuppressed(method: .quic, ttlSeconds: ttl))
        }
    }

    /// QUIC carried real server data on this network — the only evidence that actually clears the
    /// ladder. Deliberately NOT the stream *accept*: on DPI'd networks the handshake is allowed
    /// through and the connection then goes silent, so clearing on accept would reset the rung on
    /// exactly the networks the ladder exists for, and the device would oscillate at rung 1 forever.
    func noteFastUdpProvenHealthy() {
        consecutiveH3OpenFailures = 0
        guard quicSuppressionStrikes > 0 || _fastUdpUnhealthyUntil != nil else { return }
        Log.info("QUIC delivered data on this network — clearing suppression ladder (was rung \(quicSuppressionStrikes))", category: "MessageStream")
        quicSuppressionStrikes = 0
        fastUdpUnhealthyUntil = nil
    }
    /// Debounce for `reconnectForTransportChange`. A transport toggle does a full teardown +
    /// reconnect; toggling rapidly (or SwiftUI firing `.onChange` twice) stacks teardowns and
    /// creates connect→immediate-invalidate races. We coalesce bursts into a single reconnect to
    /// the final transport selection after a short settle delay.
    private var transportToggleDebounce: Task<Void, Never>?
    static let transportToggleDebounceNs: UInt64 = 500_000_000
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

    // `pendingFailedAcks` / `pendingDeliveredAcks` were removed on 2026-08-02 together with
    // `sendReceipt`. Both existed only to buffer plaintext stream receipts until the stream
    // opened; receipts are now E2E and go through the normal (queued, offline-durable) message
    // path, so there is nothing left to hold in process memory.

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

    /// Clears prolonged-offline backoff state AND the fast-UDP (QUIC/H3) suppression ladder when the
    /// network interface changes. A genuine path switch (WiFi↔cellular, VPN on/off, region change)
    /// invalidates the "QUIC is blocked on this network" conclusion — UDP/443 may be throttled on
    /// one network and clean on another — so the next `openStream()` must re-probe QUIC instead of
    /// staying sticky-H2 until app restart. This is the correct re-enable trigger: a real
    /// path-change event, not a timer. It fires only on `.networkPathChanged`, which
    /// `NetworkReachabilityManager` gates on an actual interface/topology change, so a
    /// still-QUIC-blocked network is re-probed at most once per switch — never on every reconnect
    /// (the per-reconnect thrash the suppression ladder itself exists to stop). Mirrors the clear an
    /// explicit transport toggle does in `performTransportReconnect`.
    /// Reconnect is owned by `scheduleReconnectAfterRoutingChange` (StreamLifecycle + grpcServerChanged).
    func resetDegradedModeOnNetworkChange() {
        continuousFailureStreakStart = nil
        isInDegradedMode = false
        // Re-evaluate fast-UDP for the network we just arrived on: it may not block QUIC even if
        // the old one did (and vice-versa). We re-probe when you move, not when you relaunch.
        //
        // This used to zero the ladder outright, which was half right. Re-probing an *unfamiliar*
        // network is correct; forgetting a familiar one is not. Since there was a single persisted
        // slot, zeroing it also deleted the only record — so a phone bouncing Wi-Fi↔cellular could
        // never accumulate a rung, and every return to a QUIC-hostile network paid two failed opens
        // and a pair of stream timeouts again (device, 2026-08-11 06:27→06:38). The ledger keeps
        // one record per network, so arriving somewhere now *adopts* what that network taught us —
        // and an unknown network still yields rung 0, which is the re-probe this reset was for.
        adoptLadderForCurrentNetwork(reason: "network change")
        shouldFallbackToH2Direct = false
    }

    /// Single entry for routing-driven reconnects. Bursts (network flap + VEIL port + invalidate)
    /// coalesce into one teardown after `routingReconnectDebounceDelay`.
    func scheduleReconnectAfterRoutingChange(reason: String) {
        routingReconnectDebounce?.cancel()
        routingReconnectDebounce = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.routingReconnectDebounceDelay)
            guard !Task.isCancelled, let self else { return }
            self.performRoutingReconnect(reason: reason)
        }
        Log.debug("Routing reconnect coalesced — reason=\(reason)", category: "MessageStream")
    }

    private func performRoutingReconnect(reason: String) {
        routingReconnectDebounce = nil
        guard !isPaused else {
            Log.debug("Routing reconnect skipped — stream paused (reason=\(reason))", category: "MessageStream")
            return
        }
        guard let cb = onMessageReceived else {
            Log.debug("Routing reconnect skipped — no message callback (reason=\(reason))", category: "MessageStream")
            return
        }
        guard streamTask != nil || isConnected else {
            Log.debug("Routing reconnect skipped — no active stream (reason=\(reason))", category: "MessageStream")
            return
        }
        // VEIL probe → setVeilPort posts grpcServerChanged even when connectLoop already
        // opened (or is opening) on the new ice:port. Tearing that stream down for a
        // second connect is the dual-accept / receipt storm seen in device logs.
        let currentKey = GRPCChannelManager.shared.currentRoutingKey
        if isConnected, !activeRoutingKey.isEmpty, activeRoutingKey == currentKey {
            Log.info(
                "Routing reconnect skipped — already live on \(currentKey) (reason=\(reason))",
                category: "MessageStream"
            )
            return
        }
        let ids = subscriptionUserIds
        guard !ids.isEmpty || subscriptionUserIds.isEmpty else {
            Log.debug(
                "Routing reconnect skipped — empty ids would clear \(subscriptionUserIds.count) subscriptions (reason=\(reason))",
                category: "MessageStream"
            )
            return
        }
        Log.info("Routing reconnect executing — reason=\(reason)", category: "MessageStream")
        forceDisconnect(reason: reason)
        connect(contactUserIds: ids, trigger: reason, onMessageReceived: cb)
    }

    // MARK: - Public API

    func connect(contactUserIds: [String] = [], trigger: String = "?", onMessageReceived: @escaping (ChatMessage) -> Void) {
        self.onMessageReceived = onMessageReceived

        // Restore a prior-session QUIC suppression (same network only) before the first transport
        // decision, so a cold start on a still-blocked network goes straight to H2 instead of
        // re-paying the QUIC open-then-die tax.
        restoreQuicSuppressionOnceIfNeeded()

        // Use Set comparison: currentConversationIds() builds from Array(Set) whose order is
        // non-deterministic across calls, so the same 3 IDs may arrive in a different order on
        // each reconnect attempt.  An order-sensitive != would trigger a spurious forceDisconnect()
        // even when the actual subscription set hasn't changed, causing the stream to loop.
        let oldSet = Set(subscriptionUserIds)
        let newSet = Set(contactUserIds)
        let subscriptionChanged = newSet != oldSet

        // If subscriptions changed and a loop is running, force reconnect so the
        // new contact's conversation ID is included in the subscribe request.
        if subscriptionChanged && (isConnected || streamTask != nil) {
            // Diagnostic: log exactly which subscription IDs flapped. A reconnect storm
            // during active messaging means the set is churning (e.g. a contact added/removed
            // as its session is established) — added/removed pinpoints the source.
            let added = newSet.subtracting(oldSet)
            let removed = oldSet.subtracting(newSet)
            Log.info("Subscriptions changed (\(oldSet.count)→\(newSet.count)) — reconnecting stream. added=\(Array(added)) removed=\(Array(removed))", category: "MessageStream")
            forceDisconnect(reason: "subscriptionChanged")
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

        // Reconnect when gRPC routing changes (VEIL port, custom server). Network path
        // reconnects are scheduled by StreamLifecycleCoordinator — both funnel here.
        if serverChangedObserver == nil {
            serverChangedObserver = NotificationCenter.default.addObserver(
                forName: .grpcServerChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.scheduleReconnectAfterRoutingChange(reason: "serverChanged")
                }
            }
        }

        Log.info("Starting MessageStream connection (trigger=\(trigger), subscribed to \(contactUserIds.count) contacts)", category: "MessageStream")
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
        // Coalesce rapid toggles: cancel any pending reconnect and reschedule. Reading
        // FeatureFlags.engineQuicExperimental at FIRE time (not now) means a burst of toggles
        // settles on the final selection with exactly one teardown + reconnect.
        transportToggleDebounce?.cancel()
        transportToggleDebounce = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.transportToggleDebounceNs)
            } catch {
                return  // superseded by a newer toggle
            }
            guard let self, !Task.isCancelled else { return }
            self.performTransportReconnect()
        }
    }

    private func performTransportReconnect() {
        GRPCChannelManager.shared.invalidatePersistentClient()
#if os(iOS)
        GRPCChannelManager.shared.forceInvalidateEngineQuicConnection()
#endif
        let ids = subscriptionUserIds
        guard let cb = onMessageReceived else {
            Log.info("Transport toggle — no callback yet, nothing to reconnect", category: "MessageStream")
            return
        }
        // Explicit toggle = give the chosen transport a clean slate (clear QUIC suppression ladder).
        quicSuppressionStrikes = 0
        fastUdpUnhealthyUntil = nil
        consecutiveH3OpenFailures = 0
        shouldFallbackToH2Direct = false
        Log.info("Transport toggle (engineQuic=\(FeatureFlags.engineQuicExperimental)) — forcing stream reconnect", category: "MessageStream")
        forceDisconnect(reason: "transportToggle")
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
        activeRoutingKey = ""
        outboundContinuation?.finish()
        outboundContinuation = nil
        // Invalidate any in-flight accept/event pump before starting a new connectLoop.
        streamGeneration &+= 1
        activeStreamGeneration = 0
        streamTask?.cancel()
        streamTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        heartbeatWatchdogTask?.cancel()
        heartbeatWatchdogTask = nil
        backgroundFetchTask?.cancel()
        backgroundFetchTask = nil
        retryCount = 0

        // Preserve QUIC/H3 health signals across force-reconnect.
        // Resetting consecutiveH3OpenFailures / shouldFallbackToH2Direct here forced a fresh
        // QUIC handshake every time polling/status scheduled forceReconnect mid-open — device
        // logs showed openStream QUIC → forceReconnect → QUIC again → double timeout → only
        // then H2. fastUdpUnhealthyUntil was already preserved; keep the rest of the ladder too.
        continuousFailureStreakStart = nil
        isInDegradedMode = false
        connect(contactUserIds: contactUserIds, trigger: "forceReconnect", onMessageReceived: onMessageReceived)
    }

    func disconnect() {
        routingReconnectDebounce?.cancel()
        routingReconnectDebounce = nil
        if let obs = serverChangedObserver {
            NotificationCenter.default.removeObserver(obs)
            serverChangedObserver = nil
        }
        forceDisconnect(reason: "disconnect")
    }

    /// Disconnect without removing the server-change observer (used for reconnects).
    /// `reason` is logged so a reconnect storm can be traced to its trigger.
    private func forceDisconnect(reason: String = "unknown") {
        Log.info("forceDisconnect — reason=\(reason)", category: "MessageStream")
        isConnected = false
        activeTransport = ""
        activeRoutingKey = ""
        outboundContinuation?.finish()
        outboundContinuation = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        heartbeatWatchdogTask?.cancel()
        heartbeatWatchdogTask = nil
        backgroundFetchTask?.cancel()
        backgroundFetchTask = nil
        // Bump generation so any in-flight openStream (onAccepted / event pump) is
        // immediately stale — setting 0 alone left a race where a late accept still
        // marked isConnected and dual streams both delivered receipts.
        streamGeneration &+= 1
        activeStreamGeneration = 0
        streamTask?.cancel()
        streamTask = nil
        retryCount = 0

        // Do not clear consecutiveH3OpenFailures / shouldFallbackToH2Direct /
        // fastUdpUnhealthyUntil — UDP health is network-session state, not stream-instance state.
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
        // Experimental engine-QUIC keeps a Rust runConnections() task alive independently of
        // the H2 stream; without this it can spin for tens of minutes after background pause
        // (observed: QUIC TimedOut at foreground while channel stayed open → sustained CPU).
        // Engine-QUIC channel APIs are iOS-only today (GRPCChannelManager #if os(iOS)).
        #if os(iOS)
        GRPCChannelManager.shared.invalidateEngineQuicConnection()
        #endif
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

    // `sendReceipt` was removed on 2026-08-02. It wrote a plaintext `DirectReceipt` onto the
    // authenticated stream carrying `recipientUserID` — the *original sender* — in the clear.
    // On a sealed envelope the server sets `sender_id` to empty on purpose, so this receipt was
    // the server's only source for the sender↔recipient link, and `receipts.rs` logged it
    // unhashed on the "fast path". It bought nothing: the Redis trim runs off
    // `Subscribe.since_cursor` alone, and `.failed` never triggered a retry (the peer's parser
    // discards anything that is not `.delivered`).
    //
    // Receipts are now E2E only — `OutboundSessionService.sendDeliveryReceipt`.
    // Receiving a relayed receipt is still supported (`MessageStreamParser`): reading one leaks
    // nothing, and peers on older builds may still send them.

    // MARK: - Private: Connection Loop

    /// Poll transport state until VEIL leaves `.veilProbing`, or `timeoutSeconds` elapses.
    /// Returns `true` only when the FSM lands on `.veilActive`.
    private func waitWhileVeilProbing(timeoutSeconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if Task.isCancelled { return false }
            let state = await TransportRouter.shared.snapshot().state
            switch state {
            case .veilProbing:
                try? await Task.sleep(for: .milliseconds(200))
            case .veilActive:
                return true
            default:
                return false
            }
        }
        return false
    }

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
                // Only clear the fast-UDP failure counter when the stream that just ended cleanly
                // actually ran over fast-UDP (H3/QUIC). Clearing it on a clean *H2* end (H2 was
                // chosen because QUIC failed to open) re-arms QUIC for the next reconnect, so
                // networks that block QUIC via DPI (e.g. RU — FR/AU connect over QUIC fine) re-probe
                // dead QUIC on every reconnect and pay the ~3s handshake-timeout tax before falling
                // back. That is the endless thrash this counter + fastUdpUnhealthyUntil cooldown
                // were meant to stop; the unconditional reset here defeated them. A QUIC-good
                // network leaves lastStreamTransportWasH3 == true, so QUIC is still cleared normally.
                if lastStreamTransportWasH3 {
                    consecutiveH3OpenFailures = 0
                }
                lastStreamTransportWasH3 = false
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
                            Log.info("MessageStream refresh rejected by server — device re-auth", category: "MessageStream")
                            AuthSessionManager.shared.invalidateTokensForReauth()
                            let outcome = await DeviceAuthCoordinator.shared.authenticateIfPossible()
                            if case .success = outcome {
                                Log.info("MessageStream: device re-auth recovered session — reconnecting", category: "MessageStream")
                                retryCount = 0
                                continue
                            }
                            Log.error("MessageStream: device re-auth failed after dead refresh — \(String(describing: outcome))", category: "MessageStream")
                        }
                    } else {
                        Log.info("MessageStream refresh failed (network error) — keeping tokens, will retry later", category: "MessageStream")
                    }
                }
                // Open-timeout sentinel from openStream(). Immediate retry is only for the
                // H3→H2 transport hop; same-path timeouts use exponential backoff below.
                if let rpcError = error as? RPCError,
                   rpcError.code == .unavailable,
                   rpcError.message.contains("retrying with VEIL") {
                    // Route the failure through the FSM so it decides VEIL escalation / relay rotation.
                    let kind = RPCFailureClassifier.classify(rpcError)
                    let failTarget: TransportTarget = routingKeyAtLoopStart.hasPrefix("veil:")
                        ? .veil(port: GRPCChannelManager.shared.veilProxyPort() ?? 0,
                               relay: routerSnapshot.state.currentRelay ?? "")
                        : .direct(.h2)
                    await reportStreamTransportFailureIfNeeded(
                        kind: kind,
                        via: failTarget,
                        routingKeyAtLoopStart: routingKeyAtLoopStart,
                        error: rpcError
                    )
                    if lastStreamTransportWasH3 {
                        noteFastUdpOpenFailure(context: "accept_timeout")
                    }
                    let routingKeyNow = GRPCChannelManager.shared.currentRoutingKey
                    let nowUsingVEIL = await TransportRouter.shared.snapshot().state.prefersVEIL
                    let disposition = Self.openTimeoutDisposition(
                        lastTransportWasH3: lastStreamTransportWasH3,
                        prefersVEIL: nowUsingVEIL,
                        routingKeyUnchanged: routingKeyNow == routingKeyAtLoopStart,
                        wasDirectRouting: routingKeyAtLoopStart.hasPrefix("direct:")
                    )
                    switch disposition {
                    case .immediateTransportFailover:
                        shouldFallbackToH2Direct = true
                        Log.info("H3 direct timeout — trying H2 direct next (immediate failover)", category: "MessageStream")
                        backgroundFetchTask?.cancel()
                        retryCount = 0
                        // If grpcServerChanged already scheduled a debounced reconnect, do not
                        // open another stream in this loop — that is the dual-connect storm
                        // (connectLoop open + forceDisconnect/connect 2s later).
                        if routingReconnectDebounce != nil {
                            Log.info(
                                "MessageStream fast-failover deferred to pending routing reconnect",
                                category: "MessageStream"
                            )
                            break
                        }
                        // VEIL probe in flight: wait for active (or timeout) so the next
                        // openStream uses ice:port instead of racing a doomed direct open.
                        if case .veilProbing = await TransportRouter.shared.snapshot().state {
                            let becameActive = await waitWhileVeilProbing(timeoutSeconds: 8)
                            if routingReconnectDebounce != nil {
                                Log.info(
                                    "MessageStream VEIL wait ended with pending routing reconnect — yielding",
                                    category: "MessageStream"
                                )
                                break
                            }
                            if !becameActive {
                                Log.info(
                                    "MessageStream VEIL probe did not become active within timeout — continuing openStream",
                                    category: "MessageStream"
                                )
                            }
                        }
                        continue
                    case .exponentialBackoff:
                        // Same path already timed out (often H2 after flaky network / app thrash).
                        // Fall through to the shared backoff sleep — do not tight-loop openStream.
                        shouldFallbackToH2Direct = false
                        lastStreamTransportWasH3 = false
                        Log.info(
                            "MessageStream open timed out on same path (VEIL=\(nowUsingVEIL)) — applying backoff",
                            category: "MessageStream"
                        )
                    }
                } else {
                    // Generic stream failure → feed to the FSM.
                    let kind = RPCFailureClassifier.classify(error)
                    let failTarget: TransportTarget = routingKeyAtLoopStart.hasPrefix("veil:")
                        ? .veil(port: GRPCChannelManager.shared.veilProxyPort() ?? 0,
                               relay: routerSnapshot.state.currentRelay ?? "")
                        : .direct(.h2)
                    await reportStreamTransportFailureIfNeeded(
                        kind: kind,
                        via: failTarget,
                        routingKeyAtLoopStart: routingKeyAtLoopStart,
                        error: error
                    )
                    if lastStreamTransportWasH3 {
                        // First open failure → next connectLoop iteration uses H2 immediately
                        // (shouldFallbackToH2Direct), without waiting for a second full QUIC
                        // handshake timeout (often 3s each) before the stream is usable.
                        shouldFallbackToH2Direct = true
                        noteFastUdpOpenFailure(context: "stream_failure")
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
                // These used to be flushed as `.failed` stream receipts, which the peer's parser
                // discarded and the server never retried on — the ACK was inert. Count them so
                // undecryptable backlog stays visible.
                Log.error("fetchMissedMessages: \(fetchResult.failed.count) undecryptable message(s)", category: "MessageStream")
                PerformanceMetrics.shared.record(
                    .undeliveredNoReceipt,
                    label: "fetch_undecryptable"
                )
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

    /// Report data-plane death to `TransportRouter` for **every** carrier (H2 and QUIC).
    ///
    /// Previously QUIC/H3 failures were swallowed ("experimental — not reported to router"),
    /// so auto mode never escalated to VEIL when only the long-lived stream died on DPI
    /// networks while short HTTPS still worked. See
    /// `decisions/transport-connection-health-and-escalation.md`.
    private func reportStreamTransportFailureIfNeeded(
        kind: RPCFailureKind,
        via: TransportTarget,
        routingKeyAtLoopStart: String,
        error: Error? = nil
    ) async {
        let method = streamMethod(
            wasH3: lastStreamTransportWasH3 || routingKeyAtLoopStart.hasPrefix("engine-quic:"),
            routingKey: routingKeyAtLoopStart,
            via: via
        )
        // Prefer .direct(.h3) when the failed stream was QUIC so diagnostics match reality.
        let reportVia: TransportTarget
        if case .veil = via {
            reportVia = via
        } else if method == .quic {
            reportVia = .direct(.h3)
        } else {
            reportVia = via
        }
        let streamKind = Self.mapStreamFailureKind(rpcKind: kind, error: error, wasConnected: isConnected)
        Log.info(
            "Stream transport failure → router method=\(method.shortLabel) kind=\(streamKind) (rpcKind=\(kind))",
            category: "MessageStream"
        )
        await TransportRouter.shared.send(
            .streamFailed(method: method, kind: streamKind, via: reportVia)
        )
    }

    private func streamMethod(wasH3: Bool, routingKey: String, via: TransportTarget) -> StreamMethod {
        if via.isVEIL || routingKey.hasPrefix("veil:") || routingKey.hasPrefix("ice:") {
            return .veil
        }
        if wasH3 {
            return .quic
        }
        return .h2
    }

    /// Map legacy RPC classification + error text into stream-specific kinds for the FSM.
    static func mapStreamFailureKind(
        rpcKind: RPCFailureKind,
        error: Error?,
        wasConnected: Bool
    ) -> StreamFailureKind {
        let text = (error as? RPCError)?.message
            ?? error?.localizedDescription
            ?? ""
        let lower = text.lowercased()
        if lower.contains("write failed") {
            return .writeFailed
        }
        if lower.contains("timeout") || rpcKind == .streamTimeout {
            return wasConnected ? .midSessionTimeout : .openTimeout
        }
        if lower.contains("closed") || lower.contains("cancel") {
            // `wasConnected` used to be consulted only on the timeout branch above, so a stream
            // that had been live for 25s and died with "Stream unexpectedly closed" reached the
            // router as a plain `.closed` — indistinguishable from a stream that never opened.
            // The fact was computed and then discarded one line before the decision that needed it
            // (device 2026-08-11: `router method=h2 kind=closed` after a 25s-old stream).
            return wasConnected ? .midSessionClosed : .closed
        }
        return wasConnected ? .midSessionUnknown : .transportUnknown
    }

    /// Notify router that MessageStream is live (call from onAccepted).
    func reportStreamOpenedToRouter(transportLabel: String, metricsLabel: String) {
        let method: StreamMethod
        let via: TransportTarget
        if metricsLabel.hasPrefix("veil:") || metricsLabel.hasPrefix("ice:")
            || GRPCChannelManager.shared.veilProxyPort() != nil {
            method = .veil
            let port = GRPCChannelManager.shared.veilProxyPort() ?? 0
            // currentRelay may be nil briefly; empty string is still tagged veil for the FSM.
            let relay = TransportRouterMirror.shared.state.currentRelay ?? ""
            via = .veil(port: port, relay: relay)
        } else if transportLabel == "QUIC" || transportLabel == "H3" {
            method = .quic
            via = .direct(.h3)
        } else {
            method = .h2
            via = .direct(.h2)
        }
        Task {
            await TransportRouter.shared.send(.streamOpened(method: method, via: via))
        }
    }

    /// Periodic proof of data-plane liveness (heartbeat ack).
    func reportStreamHealthyToRouter() {
        let method: StreamMethod
        switch activeTransport {
        case "QUIC", "H3": method = .quic
        case "H2": method = .h2
        default:
            method = GRPCChannelManager.shared.veilProxyPort() != nil ? .veil : .h2
        }
        let ageMs: Int
        if let last = lastHeartbeatDate {
            ageMs = max(0, Int(Date().timeIntervalSince(last) * 1000))
        } else {
            ageMs = 0
        }
        Task {
            await TransportRouter.shared.send(
                .streamHealthy(method: method, heartbeatAgeMs: ageMs)
            )
        }
    }
}
