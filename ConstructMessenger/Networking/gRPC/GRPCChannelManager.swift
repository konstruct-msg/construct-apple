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
    private static let iceCooldown: TimeInterval = 60.0
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
    func recordICEFailure() {
        UserDefaults.standard.set(Date().timeIntervalSinceReferenceDate, forKey: Self.iceFailedAtKey)
        invalidatePersistentClient()  // routing will change (ICE → direct)
        Log.info("⚠️ ICE relay failure recorded — bypassing ICE for \(Int(Self.iceCooldown))s", category: "gRPC")
        Task { @MainActor in
            // Notify IceProxyManager so the UI reflects cooldown state immediately
            // and auto-clears after the cooldown period (drives NetworkSettingsView re-render).
            IceProxyManager.shared.enterCooldown(duration: Self.iceCooldown)
            // Try to recover by switching endpoints (cert refresh + relay fallback).
            await IceProxyManager.shared.refreshCertAndRestart()
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

    /// Returns the local proxy port if ICE is running AND the relay is not on cooldown, nil otherwise.
    private func iceProxyPort() -> UInt16? {
        guard ice_proxy_is_running() != 0 else { return nil }
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
    /// In practice the Rust goroutine initializes in <50 ms; the 2-second timeout is generous.
    private func waitForProxyReady(timeout: TimeInterval = 2.0) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if ice_proxy_is_running() != 0, ice_proxy_port() > 0 { return }
            try? await Task.sleep(nanoseconds: 50_000_000) // 50 ms
        }
        Log.debug("🧊 waitForProxyReady: timed out after \(Int(timeout * 1000)) ms", category: "gRPC")
    }

    private init() {}

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
        let client: GRPCClient<HTTP2ClientTransport.Posix>
        let task:   Task<Void, Never>
        let key:    String   // routing identity — "ice:<port>" or "direct:<host>:<port>"
    }

    // nonisolated(unsafe) is correct here: all mutations are serialised through _connLock.
    private nonisolated(unsafe) var _conn: PersistentConn?
    private let _connLock = NSLock()

    private func routingKey() -> String {
        if let icePort = iceProxyPort() { return "ice:\(icePort)" }
        return "direct:\(currentHost):\(currentPort)"
    }

    /// Returns a reusable persistent client, creating/replacing it when routing changes.
    private func acquirePersistentClient() throws -> GRPCClient<HTTP2ClientTransport.Posix> {
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

        let client = try makeClient()
        let task = Task.detached { [weak self] in
            do {
                try await client.runConnections()
            } catch is CancellationError {
                // Normal shutdown.
            } catch {
                Log.error("⚠️ Persistent gRPC connection closed: \(error)", category: "GRPCChannel")
                self?.invalidatePersistentClient()
            }
        }
        _conn = PersistentConn(client: client, task: task, key: key)
        Log.debug("🔌 Persistent gRPC connection created (key=\(key))", category: "GRPCChannel")
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
        Log.debug("🔌 Persistent gRPC connection invalidated", category: "GRPCChannel")
    }

    /// Creates a new `GRPCClient` with TLS transport.
    /// Caller is responsible for running the client via `runConnections()` in a Task.
    func makeClient() throws -> GRPCClient<HTTP2ClientTransport.Posix> {
        // ICE mode: connect to local proxy with plaintext, proxy handles obfs4 to relay
        if let icePort = iceProxyPort() {
            Log.info("🧊 gRPC via ICE proxy → 127.0.0.1:\(icePort) (obfs4 → relay)", category: "gRPC")
            let transport = try HTTP2ClientTransport.Posix(
                target: .ipv4(address: "127.0.0.1", port: Int(icePort)),
                transportSecurity: .plaintext,
                config: .defaults {
                    // Keepalive is essential on cellular: carrier NAT drops idle TCP connections
                    // after ~30-60s. Without keepalive pings the tunnel dies silently.
                    $0.connection = .init(
                        maxIdleTime: .seconds(300),
                        keepalive: .init(
                            time: .seconds(25),
                            timeout: .seconds(10),
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

        let transport = try HTTP2ClientTransport.Posix(
            target: .dns(host: host, port: port),
            transportSecurity: .tls,
            config: .defaults {
                $0.connection = .init(
                    maxIdleTime: .seconds(300),
                    keepalive: .init(
                        time: .seconds(30),
                        timeout: .seconds(10),
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

    /// Execute a gRPC operation with automatic client lifecycle management.
    /// Creates a client, runs connections in background, executes the operation, then shuts down.
    /// If the operation fails while ICE is active, records the failure so future calls bypass ICE.
    func performRPC<Result: Sendable>(
        timeout: TimeInterval? = nil,
        allowAuthRetry: Bool = true,
        _ operation: @Sendable @escaping (GRPCClient<HTTP2ClientTransport.Posix>) async throws -> Result
    ) async throws -> Result {
        func shouldRecordIceFailure(_ error: Error) -> Bool {
            if let rpc = error as? RPCError {
                switch rpc.code {
                case .unavailable, .deadlineExceeded:
                    return true
                case .unauthenticated, .permissionDenied, .invalidArgument:
                    return false
                default:
                    return true
                }
            }
            if error is CancellationError { return false }
            return true
        }

        /// Network-level errors that suggest DPI interference — worth retrying through ICE.
        func shouldTryICEFallback(_ error: Error) -> Bool {
            if error is CancellationError { return false }
            if let rpc = error as? RPCError {
                switch rpc.code {
                case .unavailable, .deadlineExceeded:
                    return true
                default:
                    return false
                }
            }
            // Raw connection failure (NIO transport error) — not an RPC-level response
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

        var lastError: Error?
        var iceAutoStartedThisCall = false   // true once we DPI-auto-started ICE in this call
        for attempt in 0..<3 {
            let usingICE = iceProxyPort() != nil

            // ------------------------------------------------------------------
            // Prefer the persistent connection (no TLS handshake on hot path).
            // Fall back to a per-call client only when persistence isn't available.
            // ------------------------------------------------------------------
            let usingPersistent: Bool
            let client: GRPCClient<HTTP2ClientTransport.Posix>
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
                    if let timeout {
                        result = try await withThrowingTaskGroup(of: Result.self) { inner in
                            inner.addTask { try await operation(client) }
                            inner.addTask {
                                try await Task.sleep(for: .seconds(timeout))
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
                            if let timeout {
                                r = try await withThrowingTaskGroup(of: Result.self) { inner in
                                    inner.addTask { try await operation(client) }
                                    inner.addTask {
                                        try await Task.sleep(for: .seconds(timeout))
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
                    do {
                        let refreshed = try await TokenRefreshCoordinator.shared.refreshIfPossible()
                        if refreshed {
                            continue
                        }
                    } catch {
                        // Fall through to throw the original unauthenticated error.
                        Log.error("⚠️ Token refresh failed during RPC retry: \(error)", category: "GRPCChannel")
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
                    recordICEFailure()
                }

                // VPN DNS failure: when direct TLS can't resolve the server name, try routing through
                // ICE which bypasses DNS entirely (connects to 127.0.0.1 locally, relay resolves upstream).
                if !usingICE, isDNSResolutionFailure(error) {
                    let hasCert = await IceProxyManager.shared.hasCert
                    if hasCert {
                        Log.info("🧊 DNS failure on direct path — forcing ICE routing (VPN?)", category: "gRPC")
                        await IceProxyManager.shared.forceStartIgnoringCooldown()
                        await waitForProxyReady()
                        if iceProxyPort() != nil {
                            continue
                        }
                    }
                }

                // DPI auto-fallback: when direct connection fails with a network error on the
                // first attempt, try starting ICE proxy and retrying through the obfs4 relay.
                // Also fires when ICE is running but on cooldown — startOnDemandIfNeeded() clears
                // the cooldown in that case, so iceProxyPort() becomes non-nil after the call.
                if !usingICE, attempt == 0, shouldTryICEFallback(error) {
                    Log.info("🧊 Direct connection failed — auto-starting ICE (DPI detected)", category: "GRPCChannel")
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
                }

                throw error
            }
        }

        throw lastError ?? NetworkError.connectionFailed
    }
}

extension Notification.Name {
    static let grpcServerChanged = Notification.Name("grpcServerChanged")
}
