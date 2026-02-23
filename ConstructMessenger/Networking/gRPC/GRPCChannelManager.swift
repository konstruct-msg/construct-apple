import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2

/// Manages the gRPC channel shared by all service clients.
/// All services route through a single Envoy proxy endpoint.

final class GRPCChannelManager: Sendable {
    static let shared = GRPCChannelManager()

    private let host: String
    private let port: Int

    private init() {
        self.host = Bundle.main.object(forInfoDictionaryKey: "GRPC_HOST") as? String
            ?? "construct-server-staging.fly.dev"
        self.port = (Bundle.main.object(forInfoDictionaryKey: "GRPC_PORT") as? String)
            .flatMap(Int.init) ?? 443
    }

    /// Creates a new `GRPCClient` with TLS transport.
    /// Caller is responsible for running the client via `runConnections()` in a Task.
    func makeClient() throws -> GRPCClient<HTTP2ClientTransport.Posix> {
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
