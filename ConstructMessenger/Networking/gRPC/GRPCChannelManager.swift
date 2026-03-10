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
    func recordICEFailure() {
        UserDefaults.standard.set(Date().timeIntervalSinceReferenceDate, forKey: Self.iceFailedAtKey)
        Log.warning("⚠️ ICE relay failure recorded — bypassing ICE for \(Int(Self.iceCooldown))s", category: "gRPC")
    }

    /// True if the ICE relay failed recently and we should fall back to direct TLS.
    private func isICEOnCooldown() -> Bool {
        let stored = UserDefaults.standard.double(forKey: Self.iceFailedAtKey)
        guard stored > 0 else { return false }
        let elapsed = Date().timeIntervalSinceReferenceDate - stored
        return elapsed < Self.iceCooldown
    }

    /// Returns the local proxy port if ICE is running AND the relay is not on cooldown, nil otherwise.
    private func iceProxyPort() -> UInt16? {
        guard ice_proxy_is_running() != 0 else { return nil }
        guard !isICEOnCooldown() else {
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
                transportSecurity: .plaintext
            )
            return GRPCClient(transport: transport, interceptors: [AuthInterceptor()])
        }

        let host = currentHost
        let port = currentPort
        Log.info("🔌 gRPC creating channel → \(host):\(port) TLS=true", category: "gRPC")

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
        _ operation: @Sendable @escaping (GRPCClient<HTTP2ClientTransport.Posix>) async throws -> Result
    ) async throws -> Result {
        let usingICE = iceProxyPort() != nil
        let client = try makeClient()

        do {
            return try await withThrowingTaskGroup(of: Result?.self) { group in
                group.addTask {
                    do {
                        try await client.runConnections()
                    } catch is CancellationError {
                        // Expected: cancelled after operation completes
                    } catch {
                        Log.error("⚠️ gRPC transport error: \(error)", category: "GRPCChannel")
                    }
                    return nil
                }

                group.addTask {
                    let result = try await operation(client)
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
            // If the call failed while routing through ICE, record the relay failure so the
            // next call skips ICE and goes directly over TLS while the relay is unreachable.
            if usingICE {
                recordICEFailure()
            }
            throw error
        }
    }
}

extension Notification.Name {
    static let grpcServerChanged = Notification.Name("grpcServerChanged")
}
