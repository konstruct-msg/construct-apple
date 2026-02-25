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
        NotificationCenter.default.post(name: .grpcServerChanged, object: nil)
    }

    func resetToDefaultServer() {
        UserDefaults.standard.removeObject(forKey: Self.customHostKey)
        UserDefaults.standard.removeObject(forKey: Self.customPortKey)
        NotificationCenter.default.post(name: .grpcServerChanged, object: nil)
    }

    private init() {}

    /// Creates a new `GRPCClient` with TLS transport.
    /// Caller is responsible for running the client via `runConnections()` in a Task.
    func makeClient() throws -> GRPCClient<HTTP2ClientTransport.Posix> {
        let transport = try HTTP2ClientTransport.Posix(
            target: .dns(host: currentHost, port: currentPort),
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
    func performRPC<Result: Sendable>(
        _ operation: @Sendable @escaping (GRPCClient<HTTP2ClientTransport.Posix>) async throws -> Result
    ) async throws -> Result {
        let client = try makeClient()

        return try await withThrowingTaskGroup(of: Result.self) { group in
            group.addTask {
                try await client.runConnections()
                throw CancellationError()
            }

            group.addTask {
                let result = try await operation(client)
                client.beginGracefulShutdown()
                return result
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

extension Notification.Name {
    static let grpcServerChanged = Notification.Name("grpcServerChanged")
}
