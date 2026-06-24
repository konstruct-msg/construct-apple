import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2

/// Manages the gRPC channel shared by all service clients.
/// All services route through a single Envoy proxy endpoint.

final class GRPCChannelManager: Sendable {
    static let shared = GRPCChannelManager()

    static let customHostKey = "grpcCustomHost"
    static let customPortKey = "grpcCustomPort"

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

    /// Sets the VEIL proxy port managed by `ConnectionLoop`.
    /// When non-nil, `veilProxyPort()` returns this value and gRPC routes through the proxy.
    /// Pass `nil` to clear VEIL routing (direct path).
    func setDirectProxyPort(_ port: UInt16?) {
        let changed = _overrideProxyPortLock.withLock { () -> Bool in
            let old = _overrideProxyPort
            _overrideProxyPort = port
            return old != port
        }
        guard changed else { return }
        invalidatePersistentClientIfRoutingChanged()
    }

    /// Returns the local proxy port when VEIL is active, nil for direct routing.
    /// Set by `ConnectionLoop.prepare()` via `setDirectProxyPort()`.
    func veilProxyPort() -> UInt16? {
        _overrideProxyPortLock.withLock { _overrideProxyPort }
    }

    private init() {
        // Resolve GeoIP in the background so relay region preference is ready
        // before the first connection attempt. Idempotent — uses cached UserDefaults
        // result on subsequent launches.
        Task { await GeoIPManager.shared.resolve() }

        // Invalidate the persistent connection whenever the network path changes
        // (cellular ↔ WiFi switch, VPN on/off, etc.).  The old TCP connection is dead
        // after a path change; proactively evicting it prevents the first post-switch
        // RPC from failing before a retry can create a fresh connection.
        NotificationCenter.default.addObserver(
            forName: .networkPathChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Log.info("Network path changed — invalidating persistent gRPC connection", category: "gRPC")
            self.invalidatePersistentClient()
            Task {
                await GeoIPManager.shared.invalidate()
                await GeoIPManager.shared.resolve()
                let reachable = NetworkReachabilityManager.shared.isReachable
                let censored = CensoredNetworkDetector.isCensored
                let mode = VeilProxyStore.loadMode()
                await TransportRouter.shared.send(
                    .networkPathChanged(reachable: reachable, censored: censored, mode: mode)
                )
            }
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

    // H3 persistent connection — stored as Any? because types guarded with #if canImport(Network)
    // cannot be stored properties when the guard is conditional.
    private nonisolated(unsafe) var _h3connBox: Any? = nil
    private nonisolated(unsafe) var _h3connGeneration: UInt64 = 0
    private let _h3connLock = NSLock()

#if canImport(Network)
    private struct PersistentConnH3: @unchecked Sendable {
        let client: GRPCClient<HTTP3ClientTransport>
        let task:   Task<Void, Never>
        let key:    String   // always "direct:<host>:<port>" — H3 never used over ICE
    }
#endif

    // Experimental engine-QUIC persistent connection (construct-transport Rust stack).
    // Stored as Any? for the same #if-guard reason as the H3 box.
    private nonisolated(unsafe) var _eqConnBox: Any? = nil
    private nonisolated(unsafe) var _eqConnGeneration: UInt64 = 0
    private let _eqConnLock = NSLock()

#if os(iOS)
    private struct PersistentConnEngineQuic: @unchecked Sendable {
        let client: GRPCClient<QuicClientTransport>
        let task:   Task<Void, Never>
        let key:    String   // "engine-quic:<host>:<port>" — direct path only, never over VEIL
    }
#endif

    // Set by ConnectionLoop.prepare() via setDirectProxyPort(). veilProxyPort() returns this value.
    private nonisolated(unsafe) var _overrideProxyPort: UInt16? = nil
    private let _overrideProxyPortLock = NSLock()

    private func routingKey() -> String {
        if let veilPort = veilProxyPort() { return "ice:\(veilPort)" }
        return "direct:\(currentHost):\(currentPort)"
    }

    /// Exposes the current routing key for debug metrics and logging.
    var currentRoutingKey: String { routingKey() }

    /// Returns a reusable persistent client, creating/replacing it when routing changes.
    func acquirePersistentClient() throws -> GRPCClient<HTTP2ClientTransport.TransportServices> {
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
                Log.debug("Persistent client gen=\(gen) already superseded — skipping runConnections()", category: "GRPCChannel")
                return
            }
            do {
                try await client.runConnections()
            } catch is CancellationError {
                // Normal shutdown.
            } catch {
                Log.error("Persistent gRPC connection closed: \(error)", category: "GRPCChannel")
                self.invalidatePersistentClient()
            }
        }
        _conn = PersistentConn(client: client, task: task, key: key)
        Log.debug("Persistent gRPC connection created (key=\(key) gen=\(gen))", category: "GRPCChannel")
        return client
    }

    /// Invalidates the persistent connection only if the routing key has actually changed.
    ///
    /// Use this instead of `invalidatePersistentClient()` for VEIL lifecycle events (proxy restart,
    /// relay rotation, cooldown entry) that do not affect the direct path. If the connection is
    /// already on the direct path and VEIL reports a background failure, routing hasn't changed —
    /// there is nothing to invalidate and calling this is a no-op.
    ///
    /// Only tears down the connection when the new routing key differs from the key the connection
    /// was created with (e.g. "ice:1234" → "direct:host:443"). Avoids the cascade where an VEIL
    /// failure disrupts a working direct connection.
    func invalidatePersistentClientIfRoutingChanged() {
        // Compute routing key outside the lock — routingKey() acquires _iceModeLock and
        // _iceStandbyLock but never _connLock, so this ordering is safe.
        let newKey = routingKey()
        var didInvalidate = false
        var oldKey = ""
        _connLock.lock()
        if let conn = _conn, conn.key != newKey {
            conn.client.beginGracefulShutdown()
            oldKey = conn.key
            _conn = nil
            _connGeneration &+= 1
            didInvalidate = true
        }
        _connLock.unlock()
        guard didInvalidate else { return }
        Log.debug("Persistent gRPC connection invalidated (routing: \(oldKey) → \(newKey), gen=\(_connLock.withLock { _connGeneration }))", category: "GRPCChannel")
#if canImport(Network)
        invalidateH3Connection()
#endif
        // Notify subscribers (MessageStreamManager etc.) that routing changed so they can
        // force-reconnect long-lived streams. Without this, a stream bound to the old H3/H2
        // connection sits silently until heartbeat-watchdog catches it (~60-90s).
        NotificationCenter.default.post(name: .grpcServerChanged, object: nil)
    }

    /// Invalidates the persistent connection so the next RPC gets a fresh one.
    /// Only calls beginGracefulShutdown() — does NOT cancel the task immediately.
    /// task.cancel() on a live connection triggers the fatalError in GRPCStreamStateMachine
    /// when a concurrent in-flight RPC tries to write after the shutdown signal.
    /// Graceful shutdown signals "no new RPCs"; the runConnections() task exits naturally
    /// once all existing streams drain (typically <100 ms for unary calls).
    func invalidatePersistentClient() {
        var didInvalidate = false
        _connLock.lock()
        // Guard against multiple concurrent RPC failures all calling this simultaneously.
        // Only the first call does real work; subsequent calls with _conn == nil are no-ops.
        if _conn != nil {
            _conn?.client.beginGracefulShutdown()
            // Do NOT call task.cancel() here — let runConnections() exit naturally.
            _conn = nil
            // Bump generation so any pending runConnections() task knows it is stale.
            _connGeneration &+= 1
            didInvalidate = true
        }
        _connLock.unlock()
        guard didInvalidate else { return }
        Log.debug("Persistent gRPC connection invalidated (gen=\(_connGeneration))", category: "GRPCChannel")
        // H3 is only valid on the direct path. Any routing change that kills H2 also kills H3.
#if canImport(Network)
        invalidateH3Connection()
#endif
    }

    /// Invalidates only if the current connection generation matches `gen`.
    /// Used in GRPCCallExecutor so a background RPC that started on an old connection
    /// (e.g., fetchMissedMessages on direct gen=1) does not kill the current
    /// connection (e.g., VEIL gen=3) when routing changed while it was in-flight.
    func invalidatePersistentClientIfGeneration(_ gen: UInt64) {
        _connLock.lock()
        defer { _connLock.unlock() }
        guard _connGeneration == gen, _conn != nil else { return }
        _conn?.client.beginGracefulShutdown()
        _conn = nil
        _connGeneration &+= 1
        Log.debug("Persistent gRPC connection invalidated (gen=\(_connGeneration))", category: "GRPCChannel")
    }

    /// Returns the shared persistent channel, creating it if needed.
    /// Long-lived streaming RPCs (MessageStream) should use this instead of makeClient()
    /// so the HTTP/2 connection is NOT torn down on every stream reconnect.
    /// The stream itself can close/reopen freely; the channel stays alive.
    func acquireChannel() throws -> GRPCClient<HTTP2ClientTransport.TransportServices> {
        try acquirePersistentClient()
    }

    /// Captures the current connection generation counter for generation-aware invalidation.
    /// The caller captures this *after* acquiring a client; GRPCCallExecutor uses the captured
    /// value to skip invalidation when routing has already changed by the time an RPC fails.
    func captureConnectionGeneration() -> UInt64 {
        _connLock.withLock { _connGeneration }
    }

    /// Creates a new `GRPCClient` with TLS transport.
    /// Caller is responsible for running the client via `runConnections()` in a Task.
    func makeClient() throws -> GRPCClient<HTTP2ClientTransport.TransportServices> {
        // VEIL mode: connect to local proxy with plaintext, proxy handles obfs4 to relay.
        // The :authority pseudo-header MUST be the logical server hostname (currentHost) —
        // upstream HTTP routers (e.g. Traefik Host(...) rule) match on :authority and would
        // 404 if it was the transport address (127.0.0.1).
        if let veilPort = veilProxyPort() {
            Log.info("gRPC via VEIL proxy → 127.0.0.1:\(veilPort)", category: "gRPC")
            let logicalAuthority = currentHost
            let transport = try HTTP2ClientTransport.TransportServices(
                target: .ipv4(address: "127.0.0.1", port: Int(veilPort)),
                transportSecurity: .plaintext,
                config: .defaults {
                    $0.http2.authority = logicalAuthority
                    // Keepalive is essential on cellular: carrier NAT drops idle TCP connections
                    // after ~30-60s. Without keepalive pings the tunnel dies silently.
                    $0.connection = .init(
                        maxIdleTime: .seconds(NetworkTiming.GRPC.maxIdleTimeSeconds),
                        keepalive: .init(
                            time: .seconds(NetworkTiming.GRPC.keepaliveTimeVEILSeconds),
                            timeout: .seconds(NetworkTiming.GRPC.keepaliveTimeoutVEILSeconds),
                            allowWithoutCalls: true
                        )
                    )
                }
            )
            return GRPCClient(transport: transport, interceptors: [AuthInterceptor()])
        }

        let host = currentHost
        let port = currentPort
        Log.debug("gRPC creating channel → \(host):\(port) TLS=true", category: "gRPC")

        // MPTCP TODO: grpc-swift-nio-transport does not expose NIOTSChannelOptions.multipathServiceType
        // in its public Config API (verified up to v2.7.0). Once the library adds a channelOptions
        // field, add: `NIOTSChannelOptions.multipathServiceType → .handover` here.
        // The MPTCP entitlement is already present in ConstructMessenger.entitlements.
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

#if canImport(Network)
    /// Creates a gRPC client using the HTTP/3 (QUIC/Network.framework) transport.
    /// Only called for direct-path connections — never over VEIL/obfs4 proxy.
    func makeClientH3() -> GRPCClient<HTTP3ClientTransport> {
        let host = currentHost
        let port = currentPort
        Log.debug("gRPC creating HTTP/3 channel → \(host):\(port)", category: "gRPC")
        let transport = HTTP3ClientTransport(host: host, port: UInt16(clamping: port))
        return GRPCClient(transport: transport, interceptors: [AuthInterceptor()])
    }

    /// Returns (or lazily creates) the shared persistent H3 channel.
    /// Only valid on the direct path — callers must check `veilProxyPort() == nil` before calling.
    /// Analogous to `acquirePersistentClient()` for the H2 path.
    func acquireH3Channel() -> GRPCClient<HTTP3ClientTransport> {
        _h3connLock.lock()
        defer { _h3connLock.unlock() }

        let key = "direct:\(currentHost):\(currentPort)"
        if let conn = _h3connBox as? PersistentConnH3, conn.key == key, !conn.task.isCancelled {
            return conn.client
        }

        // Tear down stale connection gracefully.
        if let old = _h3connBox as? PersistentConnH3 {
            old.client.beginGracefulShutdown()
        }
        _h3connBox = nil
        _h3connGeneration &+= 1
        let gen = _h3connGeneration

        let client = makeClientH3()
        let task = Task.detached { [weak self, gen] in
            guard let self else { return }
            let valid = self._h3connLock.withLock { self._h3connGeneration == gen }
            guard valid else {
                Log.debug("H3 client gen=\(gen) already superseded — skipping runConnections()", category: "GRPCChannel")
                return
            }
            do {
                try await client.runConnections()
            } catch is CancellationError {
                // Normal shutdown.
            } catch {
                Log.error("H3 persistent connection closed: \(error)", category: "GRPCChannel")
                self.invalidateH3Connection()
            }
        }
        let conn = PersistentConnH3(client: client, task: task, key: key)
        _h3connBox = conn
        Log.debug("H3 persistent connection created (key=\(key) gen=\(gen))", category: "GRPCChannel")
        return client
    }

    /// Gracefully shuts down the H3 persistent connection.
    /// Called automatically from `invalidatePersistentClient()` and on H3 transport errors.
    func invalidateH3Connection() {
        _h3connLock.lock()
        defer { _h3connLock.unlock() }
        guard let conn = _h3connBox as? PersistentConnH3 else { return }
        conn.client.beginGracefulShutdown()
        _h3connBox = nil
        _h3connGeneration &+= 1
        Log.debug("H3 persistent connection invalidated (gen=\(_h3connGeneration))", category: "GRPCChannel")
    }

    /// Force-cancels the H3 persistent connection by cancelling the runConnections() task.
    /// Unlike `invalidateH3Connection()` (graceful shutdown), this immediately closes the
    /// underlying NWConnection — necessary when a QUIC handshake is stuck and doesn't
    /// respond to Swift task cancellation or `beginGracefulShutdown()`.
    func forceInvalidateH3Connection() {
        _h3connLock.lock()
        defer { _h3connLock.unlock() }
        guard let conn = _h3connBox as? PersistentConnH3 else { return }
        conn.task.cancel()
        conn.client.beginGracefulShutdown()
        _h3connBox = nil
        _h3connGeneration &+= 1
        Log.debug("H3 persistent connection force-invalidated (gen=\(_h3connGeneration))", category: "GRPCChannel")
    }
#endif

#if os(iOS)
    /// Resolves the experimental engine-QUIC gateway config, or `nil` when the
    /// experiment is off or the pinned gateway certificate is not bundled.
    /// The gateway is the native quinn+h3 service (`quic.konstruct.cc:443`), separate
    /// from the Envoy/Traefik H2 endpoint.
    private func engineQuicConfig() -> QuicClientTransport.Config? {
        guard FeatureFlags.engineQuicExperimental else { return nil }
        let host = QuicGatewayConfig.host
        let port = QuicGatewayConfig.port
        // Self-signed gateway cert (DER), pinned. Bundled as `quic_gateway.der`.
        guard let url = Bundle.main.url(forResource: "quic_gateway", withExtension: "der"),
              let cert = try? Data(contentsOf: url) else {
            Log.error("engine-QUIC enabled but quic_gateway.der is not bundled — cannot pin gateway cert", category: "GRPCChannel")
            return nil
        }
        // Production ships PLAIN QUIC (decisions/quic-plain-vs-obfuscated.md): the gateway runs
        // plain, so the client must too. Salamander obfuscation is a DEBUG-only experiment — even
        // if a stale `engineQuicObfuscated=true` is left in UserDefaults from an older build, a
        // release build never requests obf (it couldn't handshake the plain gateway anyway).
        var obfPsk: Data?
        #if DEBUG
        if FeatureFlags.engineQuicObfuscated {
            obfPsk = QuicObfPskStore.psk(for: host) ?? QuicGatewayConfig.bundledObfPsk
            if obfPsk == nil {
                Log.info("engine-QUIC obfuscation enabled but no Salamander PSK available for \(host) — using plain QUIC", category: "GRPCChannel")
            }
        }
        #endif
        return QuicClientTransport.Config(host: host, port: port, serverName: host, trustCert: cert, obfPsk: obfPsk)
    }

    /// Creates a gRPC client over the experimental engine-QUIC transport, or `nil`
    /// when the experiment/cert is unavailable. Direct path only — never over VEIL.
    func makeClientEngineQuic() -> GRPCClient<QuicClientTransport>? {
        guard let config = engineQuicConfig() else { return nil }
        Log.debug("gRPC creating engine-QUIC channel → \(config.host):\(config.port)", category: "gRPC")
        let transport = QuicClientTransport(config: config)
        return GRPCClient(transport: transport, interceptors: [AuthInterceptor()])
    }

    /// Returns (or lazily creates) the shared persistent engine-QUIC channel, or `nil`
    /// when the experiment is off. Mirrors `acquireH3Channel()`; callers MUST fall back
    /// to the H2 path (`acquirePersistentClient()`) on `nil` or on any RPC failure.
    func acquireEngineQuicChannel() -> GRPCClient<QuicClientTransport>? {
        _eqConnLock.lock()
        defer { _eqConnLock.unlock() }

        // Key includes obf-active state so toggling obfuscation (or provisioning a PSK)
        // changes the identity → the stale connection is replaced on the next acquire.
        // Mirrors engineQuicConfig(): obf is DEBUG-only, release is always plain.
        #if DEBUG
        let obfActive = FeatureFlags.engineQuicObfuscated
            && (QuicObfPskStore.psk(for: QuicGatewayConfig.host) != nil || QuicGatewayConfig.bundledObfPsk != nil)
        let obfSuffix = obfActive ? "obf" : "plain"
        #else
        let obfSuffix = "plain"
        #endif
        let key = "engine-quic:\(currentHost):\(currentPort):\(obfSuffix)"
        if let conn = _eqConnBox as? PersistentConnEngineQuic, conn.key == key, !conn.task.isCancelled {
            return conn.client
        }

        if let old = _eqConnBox as? PersistentConnEngineQuic {
            old.client.beginGracefulShutdown()
        }
        _eqConnBox = nil
        _eqConnGeneration &+= 1
        let gen = _eqConnGeneration

        guard let client = makeClientEngineQuic() else { return nil }
        let task = Task.detached { [weak self, gen] in
            guard let self else { return }
            let valid = self._eqConnLock.withLock { self._eqConnGeneration == gen }
            guard valid else {
                Log.debug("engine-QUIC client gen=\(gen) already superseded — skipping runConnections()", category: "GRPCChannel")
                return
            }
            do {
                try await client.runConnections()
            } catch is CancellationError {
                // Normal shutdown.
            } catch {
                Log.error("engine-QUIC persistent connection closed: \(error)", category: "GRPCChannel")
                self.invalidateEngineQuicConnection()
            }
        }
        _eqConnBox = PersistentConnEngineQuic(client: client, task: task, key: key)
        Log.debug("engine-QUIC persistent connection created (key=\(key) gen=\(gen))", category: "GRPCChannel")
        return client
    }

    /// Gracefully shuts down the engine-QUIC persistent connection.
    func invalidateEngineQuicConnection() {
        _eqConnLock.lock()
        defer { _eqConnLock.unlock() }
        guard let conn = _eqConnBox as? PersistentConnEngineQuic else { return }
        conn.client.beginGracefulShutdown()
        _eqConnBox = nil
        _eqConnGeneration &+= 1
        Log.debug("engine-QUIC persistent connection invalidated (gen=\(_eqConnGeneration))", category: "GRPCChannel")
    }

    /// Force-cancels the engine-QUIC connection: cancels the runConnections() task and
    /// begins graceful shutdown. Mirrors forceInvalidateH3Connection() for the silent-UDP
    /// fast-failover path (a QUIC handshake that passed but is being dropped at the UDP layer).
    func forceInvalidateEngineQuicConnection() {
        _eqConnLock.lock()
        defer { _eqConnLock.unlock() }
        guard let conn = _eqConnBox as? PersistentConnEngineQuic else { return }
        conn.task.cancel()
        conn.client.beginGracefulShutdown()
        _eqConnBox = nil
        _eqConnGeneration &+= 1
        Log.debug("engine-QUIC persistent connection force-invalidated (gen=\(_eqConnGeneration))", category: "GRPCChannel")
    }
#endif

    /// Execute a gRPC operation with automatic retry, auth refresh, and VEIL failover.
    /// Delegates to `GRPCCallExecutor` — all RPC policy logic lives there.
    func performRPC<Result: Sendable>(
        timeout: TimeInterval? = nil,
        allowAuthRetry: Bool = true,
        /// When `false`, a failure will not invalidate the shared persistent connection.
        /// Default is `false` — transport-level cleanup is handled by `runConnections()` and relay
        /// rotation. Only set `true` for interactive flows where you want immediate channel teardown.
        invalidatesConnectionOnFailure: Bool = false,
        _ operation: @Sendable @escaping (GRPCClient<HTTP2ClientTransport.TransportServices>) async throws -> Result
    ) async throws -> Result {
        try await GRPCCallExecutor.shared.performRPC(
            timeout: timeout,
            allowAuthRetry: allowAuthRetry,
            invalidatesConnectionOnFailure: invalidatesConnectionOnFailure,
            operation
        )
    }
}

extension Notification.Name {
    static let grpcServerChanged = Notification.Name("grpcServerChanged")
    /// Posted when VEIL recovers and routing switches back to a relay.
    static let veilRelayRecovered = Notification.Name("veilRelayRecovered")
}
