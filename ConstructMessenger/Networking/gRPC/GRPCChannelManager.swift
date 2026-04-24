import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2

/// Manages the gRPC channel shared by all service clients.
/// All services route through a single Envoy proxy endpoint.

final class GRPCChannelManager: Sendable {
    static let shared = GRPCChannelManager()

    static let customHostKey = "grpcCustomHost"
    static let customPortKey = "grpcCustomPort"

    // ICE relay health tracking: avoid routing through a dead relay.
    // Stores the Date.timeIntervalSinceReferenceDate of the last relay failure.
    static let iceFailedAtKey = "iceRelayLastFailedAt"
    private static let iceCooldown: TimeInterval = NetworkTiming.ICE.relayCooldown
    /// Exposed for IceProxyManager to restore cooldown on app launch.
    static let iceCooldownDuration: TimeInterval = iceCooldown

    private static let defaultHost: String = {
        Bundle.main.object(forInfoDictionaryKey: "GRPC_HOST") as? String ?? "ams.konstruct.cc"
    }()
    private static let defaultPort: Int = {
        (Bundle.main.object(forInfoDictionaryKey: "GRPC_PORT") as? String).flatMap(Int.init) ?? 443
    }()

    var currentHost: String {
        UserDefaults.standard.string(forKey: Self.customHostKey) ?? Self.defaultHost
    }

    var currentPort: Int {
        let stored = UserDefaults.standard.integer(forKey: Self.customPortKey)
        return stored > 0 ? stored : Self.defaultPort
    }

    var isUsingCustomServer: Bool {
        UserDefaults.standard.string(forKey: Self.customHostKey) != nil
    }

    func setCustomServer(host: String, port: Int) {
        UserDefaults.standard.set(host, forKey: Self.customHostKey)
        UserDefaults.standard.set(port, forKey: Self.customPortKey)
        invalidatePersistentClient()
        NotificationCenter.default.post(name: .grpcServerChanged, object: nil)
    }

    func resetToDefaultServer() {
        UserDefaults.standard.removeObject(forKey: Self.customHostKey)
        UserDefaults.standard.removeObject(forKey: Self.customPortKey)
        invalidatePersistentClient()
        NotificationCenter.default.post(name: .grpcServerChanged, object: nil)
    }

    /// Record that the ICE relay just failed. Subsequent calls will bypass ICE for `iceCooldown` seconds.
    /// Also triggers a background reconnect attempt: fresh cert fetch → primary → relay fallback.
    ///
    /// - Parameter failedAddress: The relay address that failed, captured by the caller before any
    ///   `await` suspension points. Avoids a race where `activeRelay` is cleared on MainActor by a
    ///   concurrent `networkPathChanged` before this Task runs.
    func recordICEFailure(failedAddress: String? = nil) {
        UserDefaults.standard.set(Date().timeIntervalSinceReferenceDate, forKey: Self.iceFailedAtKey)
        invalidatePersistentClient()  // routing will change (ICE → direct)
        Log.info("⚠️ ICE relay failure recorded — bypassing ICE for \(Int(Self.iceCooldown))s", category: "gRPC")
        Task { @MainActor [weak self] in
            guard self != nil else { return }
            // Use the pre-captured address when available; fall back to the current relay only if
            // the caller didn't supply one (old call sites without a captured address).
            let addr = failedAddress ?? IceProxyManager.shared.activeRelay?.address
            if let addr {
                IceProxyManager.shared.recordRelayFailure(address: addr)
            }
            // Notify IceProxyManager so the UI reflects cooldown state immediately.
            IceProxyManager.shared.enterCooldown(duration: Self.iceCooldown)
            // Try to recover by switching endpoints (cert refresh + relay fallback).
            let recovered = await IceProxyManager.shared.refreshCertAndRestart()
            if recovered {
                // Successfully switched to a different relay (e.g. MSK after AMS failure).
                // Clear the cooldown immediately so gRPC routes through the new relay —
                // without this, iceProxyPort() keeps returning nil for the full 60s cooldown
                // even though a working relay is now running.
                IceProxyManager.shared.clearCooldown()
                // No invalidatePersistentClient() here — acquirePersistentClient() detects the
                // routing key change (ice:newPort vs direct:host:port) automatically on the
                // next RPC/stream reconnect. An extra invalidation here would create a third
                // TLS handshake in rapid succession during failure→recovery cycling.
                Log.info("🧊 ICE recovered via relay failover — cooldown cleared, routing via new relay", category: "gRPC")
                NotificationCenter.default.post(name: .iceRelayRecovered, object: nil)
            }
        }
    }

    /// True if the ICE relay failed recently and we should fall back to direct TLS.
    var isICEOnCooldown: Bool { isICEOnCooldownInternal() }

    private func isICEOnCooldownInternal() -> Bool {
        let stored = UserDefaults.standard.double(forKey: Self.iceFailedAtKey)
        guard stored > 0 else { return false }
        let elapsed = Date().timeIntervalSinceReferenceDate - stored
        return elapsed < Self.iceCooldown
    }

    /// Returns the local proxy port if ICE is running AND should be used for routing, nil otherwise.
    /// Mode-aware:
    ///   `.off`  → always nil (no ICE routing)
    ///   `.auto` → only when DPI confirmed this session (prevents EU users on ICE)
    ///   `.on`   → always returns port when proxy running
    private func iceProxyPort() -> UInt16? {
        guard ice_proxy_is_running() != 0 else { return nil }
        // Read mode from UserDefaults for fast nonisolated access.
        let rawMode = UserDefaults.standard.string(forKey: IceMode.defaultsKey) ?? IceMode.platformDefault.rawValue
        let mode = IceMode(rawValue: rawMode) ?? .auto
        switch mode {
        case .off:
            return nil
        case .auto:
            // Only route through ICE when DPI was confirmed this session.
            // Read the legacy key which is kept in sync by isEnabled setter.
            guard UserDefaults.standard.bool(forKey: "ice_enabled") else { return nil }
        case .on:
            break // Always route through ICE
        }
        guard !isICEOnCooldownInternal() else {
            Log.debug("🧊 ICE on cooldown — using direct TLS", category: "gRPC")
            return nil
        }
        let port = ice_proxy_port()
        return port > 0 ? port : nil
    }

    /// Polls `ice_proxy_is_running()` and `ice_proxy_port()` until the Rust goroutine signals
    /// it is fully ready, or the timeout elapses.
    ///
    /// `ice_proxy_start_tls()` binds the TCP port synchronously and returns, but the Rust goroutine
    /// that sets the "is_running" flag runs asynchronously. Without this wait, the immediate
    /// `iceProxyPort()` check after startOnDemandIfNeeded() / restartAfterCrash() sees 0 and
    /// falls back to a direct channel — defeating ICE entirely.
    ///
    /// In practice the Rust goroutine initializes in <50 ms when ICE is already running (Rust flag
    /// set after port bind). When ICE starts cold from scratch (full WebTunnel TCP+TLS handshake),
    /// the tunnel may take 3–8 s to establish — hence the 10-second default.
    func waitForProxyReady(timeout: TimeInterval = NetworkTiming.ICE.proxyReadyWaitTimeout) async {
        // ICE OFF: proxy will never start — return immediately, no polling.
        let rawMode = UserDefaults.standard.string(forKey: IceMode.defaultsKey) ?? IceMode.platformDefault.rawValue
        guard (IceMode(rawValue: rawMode) ?? .auto) != .off else { return }
        // On WiFi the proxy typically starts in <500 ms; the full 15 s cellular timeout
        // wastes 10+ s in failure paths on fast networks.
        let effectiveTimeout = NetworkReachabilityManager.shared.connectionType == .cellular
            ? timeout
            : min(timeout, NetworkTiming.ICE.proxyReadyWaitTimeoutWiFi)
        let deadline = Date().addingTimeInterval(effectiveTimeout)
        while Date() < deadline {
            if ice_proxy_is_running() != 0, ice_proxy_port() > 0 { return }
            try? await Task.sleep(nanoseconds: 50_000_000) // 50 ms
        }
        Log.debug("🧊 waitForProxyReady: timed out after \(Int(effectiveTimeout * 1000)) ms", category: "gRPC")
    }

    private init() {
        // Invalidate the persistent connection whenever the network path changes
        // (cellular ↔ WiFi switch, VPN on/off, etc.).  The old TCP connection is dead
        // after a path change; proactively evicting it prevents the first post-switch
        // RPC from failing before a retry can create a fresh connection.
        NotificationCenter.default.addObserver(
            forName: .networkPathChanged,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Log.info("🔌 Network path changed — invalidating persistent gRPC connection", category: "gRPC")
            self.invalidatePersistentClient()
        }
    }

    // MARK: - Persistent Connection
    //
    // grpc-swift v2 opens a new TLS/HTTP-2 connection for every `makeClient()` call.
    // Handshake + TCP round-trips add 100–500 ms per message on a good network.
    // We solve this by keeping a single `GRPCClient` alive whose `runConnections()`
    // task runs in the background.  Subsequent RPCs reuse the established connection
    // with zero handshake overhead.
    //
    // The persistent connection is invalidated (and recreated on the next RPC) when:
    //   • the routing config changes  (ICE enabled/disabled, custom server, etc.)
    //   • the underlying transport throws a fatal error

    private struct PersistentConn: @unchecked Sendable {
        let client: GRPCClient<HTTP2ClientTransport.TransportServices>
        let task:   Task<Void, Never>
        let key:    String   // routing identity — "ice:<port>" or "direct:<host>:<port>"
    }

    // nonisolated(unsafe) is correct here: all mutations are serialised through _connLock.
    private nonisolated(unsafe) var _conn: PersistentConn?
    // Monotonically increasing generation counter.  Bumped on every invalidation (both
    // explicit and implicit).  The runConnections() task captures the generation at
    // creation time and bails if the generation has advanced by the time it starts —
    // this prevents the "clientIsStopped" crash that occurs when beginGracefulShutdown()
    // races with a not-yet-started runConnections() call.
    private nonisolated(unsafe) var _connGeneration: UInt64 = 0
    private let _connLock = NSLock()

    private func routingKey() -> String {
        if let icePort = iceProxyPort() { return "ice:\(icePort)" }
        return "direct:\(currentHost):\(currentPort)"
    }

    /// Exposes the current routing key for debug metrics and logging.
    var currentRoutingKey: String { routingKey() }

    /// True when a valid persistent connection exists for the current routing key.
    /// Used by performRPC to decide whether to use the hot path or a cold race.
    private var hasPersistentConnection: Bool {
        _connLock.withLock {
            guard let conn = _conn else { return false }
            return conn.key == routingKey() && !conn.task.isCancelled
        }
    }

    /// Returns a reusable persistent client, creating/replacing it when routing changes.
    private func acquirePersistentClient() throws -> GRPCClient<HTTP2ClientTransport.TransportServices> {
        _connLock.lock()
        defer { _connLock.unlock() }

        let key = routingKey()
        if let conn = _conn, conn.key == key, !conn.task.isCancelled {
            return conn.client
        }

        // Tear down stale connection gracefully.
        // beginGracefulShutdown() signals "no new RPCs"; runConnections() exits naturally.
        // Do NOT call task.cancel() — it force-closes NIO streams and causes the fatalError
        // in GRPCStreamStateMachine when a concurrent in-flight RPC is mid-write.
        _conn?.client.beginGracefulShutdown()
        _conn = nil
        // Bump generation so the old connection's task sees it is no longer current.
        _connGeneration &+= 1
        let gen = _connGeneration

        let client = try makeClient()
        PerformanceMetrics.shared.start(.grpcConnectStart, label: key)
        let task = Task.detached { [weak self, gen] in
            // Guard against the race where invalidatePersistentClient() fires after the
            // task is created but before runConnections() is called.  If the generation
            // has advanced, this client was already shut down — calling runConnections()
            // here would throw "clientIsStopped".
            guard let self else { return }
            let valid = self._connLock.withLock { self._connGeneration == gen }
            guard valid else {
                Log.debug("🔌 Persistent client gen=\(gen) already superseded — skipping runConnections()", category: "GRPCChannel")
                return
            }
            do {
                try await client.runConnections()
            } catch is CancellationError {
                // Normal shutdown.
            } catch {
                Log.error("⚠️ Persistent gRPC connection closed: \(error)", category: "GRPCChannel")
                self.invalidatePersistentClient()
            }
        }
        _conn = PersistentConn(client: client, task: task, key: key)
        Log.debug("🔌 Persistent gRPC connection created (key=\(key) gen=\(gen))", category: "GRPCChannel")
        return client
    }

    /// Invalidates the persistent connection so the next RPC gets a fresh one.
    /// Only calls beginGracefulShutdown() — does NOT cancel the task immediately.
    /// task.cancel() on a live connection triggers the fatalError in GRPCStreamStateMachine
    /// when a concurrent in-flight RPC tries to write after the shutdown signal.
    /// Graceful shutdown signals "no new RPCs"; the runConnections() task exits naturally
    /// once all existing streams drain (typically <100 ms for unary calls).
    func invalidatePersistentClient() {
        _connLock.lock()
        defer { _connLock.unlock() }
        _conn?.client.beginGracefulShutdown()
        // Do NOT call task.cancel() here — let runConnections() exit naturally.
        _conn = nil
        // Bump generation so any pending runConnections() task knows it is stale.
        _connGeneration &+= 1
        Log.debug("🔌 Persistent gRPC connection invalidated (gen=\(_connGeneration))", category: "GRPCChannel")
    }

    /// Returns the shared persistent channel, creating it if needed.
    /// Long-lived streaming RPCs (MessageStream) should use this instead of makeClient()
    /// so the HTTP/2 connection is NOT torn down on every stream reconnect.
    /// The stream itself can close/reopen freely; the channel stays alive.
    func acquireChannel() throws -> GRPCClient<HTTP2ClientTransport.TransportServices> {
        try acquirePersistentClient()
    }

    /// Creates a new `GRPCClient` with TLS transport.
    /// Caller is responsible for running the client via `runConnections()` in a Task.
    func makeClient() throws -> GRPCClient<HTTP2ClientTransport.TransportServices> {
        // ICE mode: connect to local proxy with plaintext, proxy handles obfs4 to relay
        if let icePort = iceProxyPort() {
            Log.info("🧊 gRPC via ICE proxy → 127.0.0.1:\(icePort)", category: "gRPC")
            let transport = try HTTP2ClientTransport.TransportServices(
                target: .ipv4(address: "127.0.0.1", port: Int(icePort)),
                transportSecurity: .plaintext,
                config: .defaults {
                    // Keepalive is essential on cellular: carrier NAT drops idle TCP connections
                    // after ~30-60s. Without keepalive pings the tunnel dies silently.
                    $0.connection = .init(
                        maxIdleTime: .seconds(NetworkTiming.GRPC.maxIdleTimeSeconds),
                        keepalive: .init(
                            time: .seconds(NetworkTiming.GRPC.keepaliveTimeIceSeconds),
                            timeout: .seconds(NetworkTiming.GRPC.keepaliveTimeoutSeconds),
                            allowWithoutCalls: true
                        )
                    )
                }
            )
            return GRPCClient(transport: transport, interceptors: [AuthInterceptor()])
        }

        let host = currentHost
        let port = currentPort
        Log.debug("🔌 gRPC creating channel → \(host):\(port) TLS=true", category: "gRPC")

        let transport = try HTTP2ClientTransport.TransportServices(
            target: .dns(host: host, port: port),
            transportSecurity: .tls,
            config: .defaults {
                $0.connection = .init(
                    maxIdleTime: .seconds(NetworkTiming.GRPC.maxIdleTimeSeconds),
                    keepalive: .init(
                        time: .seconds(NetworkTiming.GRPC.keepaliveTimeDirectSeconds),
                        timeout: .seconds(NetworkTiming.GRPC.keepaliveTimeoutSeconds),
                        // true: send keepalive pings even between calls so the TCP connection
                        // (used by the long-lived message stream) stays alive through NAT tables.
                        allowWithoutCalls: true
                    )
                )
            }
        )

        return GRPCClient(
            transport: transport,
            interceptors: [AuthInterceptor()]
        )
    }

    // MARK: - Happy Eyeballs helpers

    /// Returns the secondary (plain-obfs4) proxy port when running in dual-proxy mode, or nil.
    func secondaryICEProxyPort() -> UInt16? {
        guard !isICEOnCooldownInternal() else { return nil }
        let port = ice_proxy_port_plain()
        return port > 0 ? port : nil
    }

    /// Creates a one-shot gRPC client targeting the Construct server directly over TLS.
    /// Used for the "direct" leg of a happy-eyeballs 3-way race.
    func makeDirectClient() throws -> GRPCClient<HTTP2ClientTransport.TransportServices> {
        let host = currentHost
        let port = currentPort
        let transport = try HTTP2ClientTransport.TransportServices(
            target: .dns(host: host, port: port),
            transportSecurity: .tls,
            config: .defaults {
                $0.connection = .init(
                    maxIdleTime: .seconds(NetworkTiming.GRPC.maxIdleTimeSeconds),
                    keepalive: .init(
                        time: .seconds(NetworkTiming.GRPC.keepaliveTimeDirectSeconds),
                        timeout: .seconds(NetworkTiming.GRPC.keepaliveTimeoutSeconds),
                        allowWithoutCalls: true
                    )
                )
            }
        )
        return GRPCClient(transport: transport, interceptors: [AuthInterceptor()])
    }

    /// Creates a one-shot gRPC client targeting a local ICE proxy port over plaintext.
    /// Used for the ICE legs of a happy-eyeballs 3-way race.
    func makeICEClient(port: UInt16) throws -> GRPCClient<HTTP2ClientTransport.TransportServices> {
        let transport = try HTTP2ClientTransport.TransportServices(
            target: .ipv4(address: "127.0.0.1", port: Int(port)),
            transportSecurity: .plaintext,
            config: .defaults {
                $0.connection = .init(
                    maxIdleTime: .seconds(NetworkTiming.GRPC.maxIdleTimeSeconds),
                    keepalive: .init(
                        time: .seconds(NetworkTiming.GRPC.keepaliveTimeIceSeconds),
                        timeout: .seconds(NetworkTiming.GRPC.keepaliveTimeoutSeconds),
                        allowWithoutCalls: true
                    )
                )
            }
        )
        return GRPCClient(transport: transport, interceptors: [AuthInterceptor()])
    }

    /// Executes `operation` via a 3-way happy-eyeballs race:
    ///   1. Direct gRPC (TLS to Construct server)
    ///   2. ICE-TLS proxy (primary relay, AMS)                  [250 ms staggered start]
    ///   3. ICE-plain proxy (secondary relay, e.g. MSK)         [450 ms staggered start]
    ///
    /// The first leg to succeed wins; the others are cancelled.  After the race, the
    /// persistent connection is committed to the winning path so subsequent RPCs reuse it
    /// without repeating the race.
    ///
    /// Requires both proxy ports to already be running (or starting).
    /// Use `IceProxyManager.startBothRelaysForHappyEyeballs()` first.
    func happyEyeballsRace<Result: Sendable>(
        _ operation: @Sendable @escaping (GRPCClient<HTTP2ClientTransport.TransportServices>) async throws -> Result
    ) async throws -> Result {
        let iceTLSPort  = ice_proxy_port_tls()
        let icePlainPort = ice_proxy_port_plain()
        let raceLegs = 1 + (iceTLSPort  > 0 ? 1 : 0)
                         + (icePlainPort > 0 ? 1 : 0)
        Log.info("🏁 Happy-eyeballs race: \(raceLegs) leg(s) (direct + ICE-TLS:\(iceTLSPort) + ICE-plain:\(icePlainPort))", category: "gRPC")
        PerformanceMetrics.shared.start(.grpcConnectStart, label: "race:\(raceLegs)-legs")

        typealias LegResult = (label: String, value: Result)

        let raceResult: LegResult = try await withThrowingTaskGroup(of: LegResult.self) { group in
            // Leg 1: direct TLS
            let directClient = try makeDirectClient()
            group.addTask {
                let connTask = Task { try await directClient.runConnections() }
                defer {
                    directClient.beginGracefulShutdown()
                    // Do NOT connTask.cancel() — let runConnections() drain gracefully.
                    _ = connTask  // suppress unused warning; task released when client drains
                }
                let r = try await operation(directClient)
                return ("direct", r)
            }

            // Leg 2: ICE-TLS (staggered by happyEyeballsICEStaggerMs)
            if iceTLSPort > 0 {
                let iceTLSClient = try makeICEClient(port: iceTLSPort)
                group.addTask {
                    try await Task.sleep(nanoseconds: NetworkTiming.ICE.happyEyeballsICEStaggerMs * 1_000_000)
                    let connTask = Task { try await iceTLSClient.runConnections() }
                    defer {
                        iceTLSClient.beginGracefulShutdown()
                        _ = connTask
                    }
                    let r = try await operation(iceTLSClient)
                    return ("ice-tls:\(iceTLSPort)", r)
                }
            }

            // Leg 3: ICE-plain (staggered further)
            if icePlainPort > 0 {
                let icePlainClient = try makeICEClient(port: icePlainPort)
                group.addTask {
                    let stagger = NetworkTiming.ICE.happyEyeballsICEStaggerMs + NetworkTiming.ICE.happyEyeballsRelayStaggerMs
                    try await Task.sleep(nanoseconds: stagger * 1_000_000)
                    let connTask = Task { try await icePlainClient.runConnections() }
                    defer {
                        icePlainClient.beginGracefulShutdown()
                        _ = connTask
                    }
                    let r = try await operation(icePlainClient)
                    return ("ice-plain:\(icePlainPort)", r)
                }
            }

            // Wait for the first SUCCESS — ignore individual leg failures so a broken relay
            // doesn't cancel a still-running direct leg (and vice versa).
            // Only fail the whole race when every leg has reported failure.
            var lastError: Error = RPCError(code: .unavailable, message: "All transport legs failed")
            while let result = await group.nextResult() {
                switch result {
                case .success(let legResult):
                    group.cancelAll()
                    return legResult
                case .failure(let error):
                    if !(error is CancellationError) { lastError = error }
                }
            }
            throw lastError
        }

        PerformanceMetrics.shared.end(.grpcConnectStart, endEvent: .grpcConnectEnd, label: "race:\(raceLegs)-legs")
        Log.info("🏁 Happy-eyeballs race winner: \(raceResult.label)", category: "gRPC")

        // Commit the winning routing to the persistent connection:
        // - If ICE won: iceProxyPort() is already non-nil → acquirePersistentClient() will
        //   route through ICE on the next call. No action needed.
        // - If direct won: ICE proxy may still be running (auto-mode warm-up). Invalidate
        //   the persistent connection so the next acquirePersistentClient() re-evaluates routing.
        //   (iceProxyPort() routing is based on ICE mode + cooldown; direct win means DPI is
        //   not active so the ICE auto-start task can be discarded.)
        if raceResult.label == "direct" {
            // Clear any ICE auto-warm that started in the background — direct is faster.
            await IceProxyManager.shared.stopEphemeral()
            invalidatePersistentClient()
        }

        return raceResult.value
    }

    /// Execute a gRPC operation with automatic client lifecycle management.
    /// Creates a client, runs connections in background, executes the operation, then shuts down.
    /// If the operation fails while ICE is active, records the failure so future calls bypass ICE.
    func performRPC<Result: Sendable>(
        timeout: TimeInterval? = nil,
        allowAuthRetry: Bool = true,
        fastICEFallback: Bool = false,
        _ operation: @Sendable @escaping (GRPCClient<HTTP2ClientTransport.TransportServices>) async throws -> Result
    ) async throws -> Result {
        func shouldRecordIceFailure(_ error: Error) -> Bool {
            if error is CancellationError { return false }
            if let rpc = error as? RPCError {
                switch rpc.code {
                // These are application-level errors — the relay delivered the response fine.
                case .unauthenticated, .permissionDenied, .invalidArgument, .notFound,
                     .alreadyExists, .resourceExhausted, .cancelled,
                     .internalError:
                    return false
                case .unimplemented:
                    // "Unexpected non-200 HTTP Status Code" is NOT an app-level error when ICE
                    // is active — it means the relay→upstream HTTP path is broken (the relay
                    // accepted the obfs4 connection but returned a non-200 HTTP response instead
                    // of proxying gRPC). This is a relay failure and must trigger relay rotation.
                    // Other .unimplemented errors (real missing RPC methods) are app-level — skip.
                    let msg = rpc.message.lowercased()
                    if msg.contains("non-200") || msg.contains("http status code") ||
                       msg.contains("unexpected") && msg.contains("http") {
                        return true
                    }
                    return false
                case .unavailable, .deadlineExceeded, .unknown:
                    // Distinguish relay failures (TCP/TLS errors) from non-relay failures
                    // (server-side closes or our own connection invalidation).
                    // "Stream unexpectedly closed" / "channel is closed" / "CancellationError"
                    // all indicate the relay itself was not the problem.
                    let msg = rpc.message.lowercased()
                    if msg.contains("stream") && msg.contains("closed") { return false }
                    if msg.contains("channel is closed")                 { return false }
                    if msg.contains("cancellation")                      { return false }
                    if msg.contains("cancelled")                         { return false }
                    // "The server accepted the TCP connection but closed the connection before
                    // completing the HTTP/2 connection preface."
                    // When this function is called, usingICE is always true (call-site guard).
                    // This error occurs because the local ICE proxy accepted the gRPC socket but
                    // immediately dropped it when the remote relay refused the connection.
                    // That IS a relay failure — record it so the relay gets blacklisted.
                    // (On the direct path this would mean the gRPC server itself reset the
                    // connection, but shouldRecordIceFailure is never called on the direct path.)
                    return true
                default:
                    return true
                }
            }
            return true
        }

        /// Network-level errors that suggest DPI interference — worth retrying through ICE.
        /// Only true for errors that look like network-level blocking (timeouts, TLS resets).
        /// False for server-side issues, auth errors, and client-side channel state problems.
        /// Always returns false in `.off` mode (user explicitly disabled ICE).
        func shouldTryICEFallback(_ error: Error) -> Bool {
            // Respect user's explicit choice: OFF means no fallback.
            let rawMode = UserDefaults.standard.string(forKey: IceMode.defaultsKey) ?? IceMode.platformDefault.rawValue
            if IceMode(rawValue: rawMode) == .off { return false }

            if error is CancellationError { return false }
            if let rpc = error as? RPCError {
                switch rpc.code {
                case .unavailable:
                    let msg = rpc.message.lowercased()
                    // "connection preface" on the DIRECT path means DPI: the middlebox accepted
                    // TCP but reset before HTTP/2 handshake — exactly when ICE is needed.
                    // (isRelayFailure() also checks this string, but there it means the relay
                    //  itself worked fine and the remote server reset — different context.)
                    // Client-side channel lifecycle — not a network error.
                    if msg.contains("channel is closed") { return false }
                    // Server port not listening — server down, not DPI.
                    if msg.contains("connection refused") { return false }
                    // DNS failure — resolver issue, not DPI.
                    if msg.contains("name resolution") || msg.contains("dns") { return false }
                    // Local ICE proxy died — handled by isStaleLocalProxy().
                    if msg.contains("127.0.0.1") { return false }
                    return true
                case .deadlineExceeded:
                    return true
                default:
                    return false
                }
            }
            // Raw NIO transport error — only treat as DPI if it's a genuine connection failure,
            // not a client-side state issue (closed channel, cancelled, etc.)
            let desc = String(describing: error).lowercased()
            if desc.contains("cancelled") || desc.contains("channel") || desc.contains("closed")
                || desc.contains("refused") { return false }
            return true
        }

        /// True when the error is ECONNREFUSED on the local ICE proxy port (127.0.0.1).
        /// This means the Rust proxy process died but Swift state was not updated.
        /// Distinct from a relay failure — no cooldown should be entered, just restart the process.
        func isStaleLocalProxy(_ error: Error) -> Bool {
            guard let rpc = error as? RPCError, rpc.code == .unavailable else { return false }
            return rpc.message.contains("127.0.0.1")
        }

        /// True when the error is a DNS resolution failure on the direct TLS path.
        /// Typically occurs when VPN routes all traffic through a DNS server that
        /// doesn't know about the Construct server hostname.
        func isDNSResolutionFailure(_ error: Error) -> Bool {
            guard let rpc = error as? RPCError, rpc.code == .unavailable else { return false }
            let msg = rpc.message
            return msg.contains("Failed to resolve") || msg.contains("nodename nor servname")
        }

        /// True when the error is "WebTunnel blocked by a carrier transparent HTTP proxy":
        /// the proxy intercepted the WebSocket UPGRADE and returned a non-101 response.
        /// obfs4 is a binary protocol that transparent HTTP proxies cannot interpret.
        func isWebTunnelBlocked(_ error: Error) -> Bool {
            guard let rpc = error as? RPCError, rpc.code == .unimplemented else { return false }
            let msg = rpc.message.lowercased()
            return msg.contains("non-200") || msg.contains("http status code") ||
                   (msg.contains("unexpected") && msg.contains("http"))
        }

        var lastError: Error?
        var iceAutoStartedThisCall = false   // true once we DPI-auto-started ICE in this call

        // Happy Eyeballs pre-warm: only in AUTO mode. In OFF mode, no ICE at all.
        // In ON mode, ICE is already running from app launch.
        // Fire ICE startup concurrently at t=0 while the direct attempt is in flight.
        if fastICEFallback, iceProxyPort() == nil {
            let currentMode = IceMode(rawValue: UserDefaults.standard.string(forKey: IceMode.defaultsKey) ?? "") ?? .auto
            if currentMode == .auto {
                Task {
                    let hasCert = await IceProxyManager.shared.hasCert
                    if hasCert {
                        await IceProxyManager.shared.startEphemeralOnDemandIfNeeded()
                    }
                }
            }
        }

        // True happy-eyeballs race: fire all available paths simultaneously on cold start.
        // Conditions:
        //   1. fastICEFallback is enabled (caller requests ICE fallback support)
        //   2. No persistent connection exists yet (cold start or after reconnect)
        //   3. ICE proxy is already warm (port > 0) — at least one leg has started
        //   4. Auto mode — in .on mode ICE is always preferred; no need to race direct
        // The first path to return a result wins; all others are cancelled.
        // On direct win: the ephemeral ICE pre-warm is stopped (no confirmed DPI).
        // On ICE win: persistent routing switches to ICE automatically via iceProxyPort().
        if fastICEFallback, !hasPersistentConnection {
            let iceTLSPort  = ice_proxy_port_tls()
            let icePlainPort = ice_proxy_port_plain()
            let rawMode = UserDefaults.standard.string(forKey: IceMode.defaultsKey) ?? IceMode.platformDefault.rawValue
            let iceMode = IceMode(rawValue: rawMode) ?? .auto
            if iceMode == .auto, iceTLSPort > 0 || icePlainPort > 0 {
                do {
                    Log.info("🏁 Cold start — entering happy-eyeballs race (ICE-TLS:\(iceTLSPort) ICE-plain:\(icePlainPort))", category: "gRPC")
                    return try await happyEyeballsRace(operation)
                } catch {
                    Log.info("🏁 Happy-eyeballs race failed — falling through to sequential retry: \(error)", category: "gRPC")
                    lastError = error
                }
            }
        }

        for attempt in 0..<3 {
            let usingICE = iceProxyPort() != nil
            let iceRelayVerified = usingICE ? await IceProxyManager.shared.isCurrentRelayVerified : true
            let effectiveTimeout: TimeInterval? = {
                guard let timeout else { return nil }
                // Unverified ICE relay: use a short timeout so DPI-blocked obfs4 tunnels
                // are detected in ~5s instead of 15–30s, enabling fast relay rotation.
                if usingICE, !iceRelayVerified {
                    return min(timeout, NetworkTiming.ICE.unverifiedRelayTimeout)
                }
                // "Happy eyeballs" for routing: on the first direct attempt, prefer a short
                // deadline so we can quickly try ICE instead of waiting 20-30 seconds.
                // Skip this cap when ICE is OFF — no fallback exists, so the direct attempt
                // must use the full caller timeout to avoid artificial connection failures.
                guard fastICEFallback, !usingICE, attempt == 0 else { return timeout }
                let rawModeForTimeout = UserDefaults.standard.string(forKey: IceMode.defaultsKey) ?? IceMode.platformDefault.rawValue
                guard (IceMode(rawValue: rawModeForTimeout) ?? .auto) != .off else { return timeout }
                // Only shorten the timeout when ICE is actually ready to take over.
                // If the relay hasn't connected yet (port == 0, e.g. all relays blacklisted),
                // the direct path has no fallback — use the full timeout to avoid a false
                // deadlineExceeded → false DPI-confirmed cascade.
                guard ice_proxy_port_tls() > 0 else { return timeout }
                // 4 seconds is enough for TCP+TLS on healthy networks, but short enough to
                // avoid UI stalls on DPI-blocked paths.
                return min(timeout, NetworkTiming.GRPC.fastFallbackDirectTimeout)
            }()

            if fastICEFallback, !usingICE, attempt == 0, let effectiveTimeout {
                PerformanceMetrics.shared.record(
                    .rpcFastICEFallbackArmed,
                    label: routingKey(),
                    value: effectiveTimeout * 1000
                )
            }

            // ------------------------------------------------------------------
            // Prefer the persistent connection (no TLS handshake on hot path).
            // Fall back to a per-call client only when persistence isn't available.
            // ------------------------------------------------------------------
            let usingPersistent: Bool
            let client: GRPCClient<HTTP2ClientTransport.TransportServices>
            if let pc = try? acquirePersistentClient() {
                client = pc
                usingPersistent = true
            } else {
                client = try makeClient()
                usingPersistent = false
            }

            do {
                let result: Result

                if usingPersistent {
                    // runConnections() is already running in a background task.
                    // Execute the operation directly; timeout is still enforced.
                    if let effectiveTimeout {
                        result = try await withThrowingTaskGroup(of: Result.self) { inner in
                            inner.addTask { try await operation(client) }
                            inner.addTask {
                                try await Task.sleep(for: .seconds(effectiveTimeout))
                                throw RPCError(code: .deadlineExceeded, message: "Request timed out")
                            }
                            let first = try await inner.next()!
                            inner.cancelAll()
                            return first
                        }
                    } else {
                        result = try await operation(client)
                    }
                } else {
                    // Per-call client: co-run with runConnections() so a transport
                    // failure fails the RPC promptly instead of hanging.
                    result = try await withThrowingTaskGroup(of: Result?.self) { group in
                        group.addTask {
                            do {
                                try await client.runConnections()
                                return nil
                            } catch is CancellationError {
                                return nil
                            } catch {
                                Log.error("⚠️ gRPC transport error: \(error)", category: "GRPCChannel")
                                throw error
                            }
                        }

                        group.addTask {
                            let r: Result
                            if let effectiveTimeout {
                                r = try await withThrowingTaskGroup(of: Result.self) { inner in
                                    inner.addTask { try await operation(client) }
                                    inner.addTask {
                                        try await Task.sleep(for: .seconds(effectiveTimeout))
                                        throw RPCError(code: .deadlineExceeded, message: "Request timed out")
                                    }
                                    let first = try await inner.next()!
                                    inner.cancelAll()
                                    return first
                                }
                            } else {
                                r = try await operation(client)
                            }
                            client.beginGracefulShutdown()
                            return r
                        }

                        while let next = try await group.next() {
                            if let r = next {
                                group.cancelAll()
                                return r
                            }
                        }
                        group.cancelAll()
                        throw NetworkError.connectionFailed
                    }
                }

                PerformanceMetrics.shared.end(.grpcConnectStart, endEvent: .grpcConnectEnd, label: routingKey())
                if usingICE, !iceRelayVerified {
                    await IceProxyManager.shared.markCurrentRelayVerified()
                }
                return result
            } catch {
                lastError = error

                if usingPersistent {
                    // Persistent connection failed — invalidate so next attempt gets a fresh one.
                    invalidatePersistentClient()
                } else {
                    client.beginGracefulShutdown()
                }

                if let rpc = error as? RPCError,
                   rpc.code == .unauthenticated,
                   allowAuthRetry,
                   attempt == 0 {
                    // Try to refresh access token once, then retry the RPC.
                    var refreshError: Error?
                    do {
                        let refreshed = try await TokenRefreshCoordinator.shared.refreshIfPossible()
                        if refreshed {
                            continue
                        }
                    } catch {
                        refreshError = error
                        Log.error("⚠️ Token refresh failed during RPC retry: \(error)", category: "GRPCChannel")
                    }
                    // Only wipe the refresh token if the server explicitly rejected it
                    // (unauthenticated / permission denied = token is genuinely invalid).
                    // Network errors (unavailable, deadline) mean the refresh endpoint was
                    // unreachable — the existing token may still be valid once connectivity
                    // returns, so keep it rather than forcing a full device re-auth offline.
                    let serverRejected: Bool
                    if let rpcErr = refreshError as? RPCError {
                        serverRejected = rpcErr.code == .unauthenticated || rpcErr.code == .permissionDenied
                    } else {
                        // refreshIfPossible() returned false (no refresh token stored).
                        serverRejected = refreshError == nil
                    }
                    if serverRejected {
                        Log.info("🔑 Refresh rejected by server — triggering device re-auth", category: "GRPCChannel")
                        SessionManager.shared.invalidateTokensForReauth()
                    } else {
                        Log.info("🔑 Refresh failed (network error) — keeping tokens for retry when online", category: "GRPCChannel")
                    }
                }

                // If the call failed while routing through ICE, record relay failure only for
                // network-ish failures. Don't disable ICE due to auth/validation errors.
                // Also skip cooldown when ICE was just auto-started this call — a warm-up
                // failure doesn't mean the relay itself is broken.
                if usingICE, isStaleLocalProxy(error) {
                    // ECONNREFUSED on 127.0.0.1 — local proxy died in background.
                    // Restart immediately; do NOT enter cooldown (this is a process crash, not relay failure).
                    Log.info("🧊 ICE proxy port dead (ECONNREFUSED) — restarting proxy", category: "gRPC")
                    await IceProxyManager.shared.restartAfterCrash()
                    await waitForProxyReady()
                    if iceProxyPort() != nil {
                        continue
                    }
                } else if usingICE, !iceAutoStartedThisCall, shouldRecordIceFailure(error) {
                    // Relay tunnel broken (DPI-blocked or unreachable). Before rotating,
                    // check if this is a WebTunnel-specific failure (carrier transparent
                    // proxy intercepted the WebSocket UPGRADE). obfs4 is a binary protocol
                    // that such proxies cannot inspect — try the same relay in obfs4 mode.
                    let failedAddr = await IceProxyManager.shared.activeRelay?.address
                    let webTunnelActive = await IceProxyManager.shared.isWebTunnelActive
                    if isWebTunnelBlocked(error), webTunnelActive {
                        Log.info("🧊 WebTunnel blocked (non-200) — retrying relay via obfs4", category: "gRPC")
                        // Pass failedAddr as hint: networkPathChanged may have reset activeRelay
                        // between the read above and the actual retry call (race condition on MainActor).
                        let obfs4OK = await IceProxyManager.shared.retryCurrentRelayAsObfs4(hintAddress: failedAddr)
                        if obfs4OK {
                            invalidatePersistentClient()
                            await waitForProxyReady()
                            Log.info("🧊 ICE obfs4 fallback active — retrying via same relay", category: "gRPC")
                            continue
                        }
                        // obfs4 also failed — blacklist the relay (activeRelay is nil now,
                        // use the address captured above) and rotate to the next one.
                        if let addr = failedAddr { await IceProxyManager.shared.recordRelayFailure(address: addr) }
                    } else {
                        if let addr = failedAddr { await IceProxyManager.shared.recordRelayFailure(address: addr) }
                    }
                    // Rotate INLINE so the retry loop can use the new relay immediately.
                    let rotated = await IceProxyManager.shared.rotateToNextRelay()
                    if rotated {
                        // If every known relay was recently blacklisted, we've just restarted the
                        // least-bad one. Cycling immediately fills the relay's per-IP connection
                        // limit (8 concurrent), making every new attempt fail at the TCP layer.
                        // A 30 s pause lets old connections drain before we create new ones.
                        if await IceProxyManager.shared.allRelaysRecentlyFailed {
                            Log.info("🧊 All relays blacklisted — waiting 30s to let connections drain", category: "gRPC")
                            try? await Task.sleep(for: .seconds(30))
                        }
                        invalidatePersistentClient()
                        await waitForProxyReady()
                        Log.info("🧊 Relay rotated inline — retrying via new relay", category: "gRPC")
                        continue
                    }
                    // All relays exhausted — enter cooldown for direct fallback.
                    recordICEFailure(failedAddress: failedAddr)
                }

                // VPN DNS failure: when direct TLS can't resolve the server name, try routing through
                // ICE which bypasses DNS entirely (connects to 127.0.0.1 locally, relay resolves upstream).
                // Skip entirely when ICE is OFF — the user has explicitly disabled it.
                if !usingICE, isDNSResolutionFailure(error) {
                    let dnsIceRawMode = UserDefaults.standard.string(forKey: IceMode.defaultsKey) ?? IceMode.platformDefault.rawValue
                    let dnsIceMode = IceMode(rawValue: dnsIceRawMode) ?? .auto
                    if dnsIceMode != .off {
                        let hasCert = await IceProxyManager.shared.hasCert
                        if hasCert {
                            Log.info("🧊 DNS failure on direct path — forcing ICE routing (VPN?)", category: "gRPC")
                            await IceProxyManager.shared.forceStartIgnoringCooldown()
                            await waitForProxyReady()
                            if iceProxyPort() != nil {
                                continue
                            }
                            // waitForProxyReady timed out — clear stuck state so next attempt restarts.
                            await IceProxyManager.shared.resetIfStuck()
                        }
                    }
                }

                // DPI auto-fallback: when direct connection fails with a network error on the
                // first attempt, try starting ICE proxy and retrying through the obfs4 relay.
                // Also fires when ICE is running but on cooldown — startOnDemandIfNeeded() clears
                // the cooldown in that case, so iceProxyPort() becomes non-nil after the call.
                // Skip entirely when ICE is OFF — startOnDemandIfNeeded() would return immediately
                // but waitForProxyReady() would still block for up to 5-15s.
                let dpiRawMode = UserDefaults.standard.string(forKey: IceMode.defaultsKey) ?? IceMode.platformDefault.rawValue
                let dpiIceMode = IceMode(rawValue: dpiRawMode) ?? .auto
                if !usingICE, attempt == 0, dpiIceMode != .off, shouldTryICEFallback(error) {
                    if fastICEFallback {
                        PerformanceMetrics.shared.record(.rpcFastICEFallbackTriggered, label: routingKey())
                    }
                    Log.info("🧊 Direct connection failed — auto-starting ICE (DPI detected) error=\(error)", category: "GRPCChannel")
                    await IceProxyManager.shared.startOnDemandIfNeeded()
                    await waitForProxyReady()
                    if iceProxyPort() != nil {
                        // The failed connection was already invalidated at the top of this catch block.
                        // No extra invalidation needed — just retry; acquirePersistentClient() will
                        // open a fresh channel routed through the ICE proxy port.
                        iceAutoStartedThisCall = true
                        Log.info("🧊 ICE proxy active — retrying RPC through relay", category: "GRPCChannel")
                        continue
                    }
                    // waitForProxyReady timed out — clear stuck state so next attempt restarts fresh.
                    await IceProxyManager.shared.resetIfStuck()
                }

                throw error
            }
        }

        throw lastError ?? NetworkError.connectionFailed
    }
}

extension Notification.Name {
    static let grpcServerChanged = Notification.Name("grpcServerChanged")
    /// Posted when the ICE relay recovers after a cooldown (routing switches back from direct → relay).
    /// Observers should retry any startup RPCs that may have timed out during the direct-routing window.
    static let iceRelayRecovered = Notification.Name("iceRelayRecovered")
}
