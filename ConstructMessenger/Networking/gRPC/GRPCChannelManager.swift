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
    private static let iceFailedAtKey = "iceRelayLastFailedAt"
    private static let iceCooldown: TimeInterval = 60.0

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
        NotificationCenter.default.post(name: .grpcServerChanged, object: nil)
    }

    func resetToDefaultServer() {
        UserDefaults.standard.removeObject(forKey: Self.customHostKey)
        UserDefaults.standard.removeObject(forKey: Self.customPortKey)
        NotificationCenter.default.post(name: .grpcServerChanged, object: nil)
    }

    /// Record that the ICE relay just failed. Subsequent calls will bypass ICE for `iceCooldown` seconds.
    /// Also triggers a background reconnect attempt: fresh cert fetch → primary → relay fallback.
    func recordICEFailure() {
        UserDefaults.standard.set(Date().timeIntervalSinceReferenceDate, forKey: Self.iceFailedAtKey)
        Log.info("⚠️ ICE relay failure recorded — bypassing ICE for \(Int(Self.iceCooldown))s", category: "gRPC")
        // Try to recover by switching endpoints (cert refresh + relay fallback).
        // If MSK relay is up while primary is blocked, we'll reconnect through it.
        Task { @MainActor in
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

    private init() {}

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
                        allowWithoutCalls: false
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

        var lastError: Error?
        for attempt in 0..<2 {
            let usingICE = iceProxyPort() != nil
            let client = try makeClient()

            do {
                return try await withThrowingTaskGroup(of: Result?.self) { group in
                    group.addTask {
                        do {
                            try await client.runConnections()
                            return nil
                        } catch is CancellationError {
                            // Expected: cancelled after operation completes
                            return nil
                        } catch {
                            // If the transport dies before the RPC completes, don't hang forever.
                            // Propagate the error to fail the RPC promptly.
                            Log.error("⚠️ gRPC transport error: \(error)", category: "GRPCChannel")
                            throw error
                        }
                    }

                    group.addTask {
                        let result: Result
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
                        client.beginGracefulShutdown()
                        return result
                    }

                    while let next = try await group.next() {
                        if let result = next {
                            group.cancelAll()
                            return result
                        }
                    }
                    group.cancelAll()
                    throw NetworkError.connectionFailed
                }
            } catch {
                lastError = error
                client.beginGracefulShutdown()

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
                if usingICE, shouldRecordIceFailure(error) {
                    recordICEFailure()
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
