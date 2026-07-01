import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2

/// Executes gRPC RPCs with retry, auth refresh, client-side timeout, and VEIL failover.
///
/// Transport concerns (channel lifecycle, routing, VEIL health) remain in `GRPCChannelManager`.
/// This class owns the *policy*: how many attempts, what errors are retryable, when to rotate
/// relays, and when to invalidate the persistent connection vs. leaving it alive.
///
/// All service clients call `GRPCChannelManager.shared.performRPC(...)`, which forwards here.
final class GRPCCallExecutor: Sendable {
    static let shared = GRPCCallExecutor()
    private init() {}

    // MARK: - Public Entry Point

    func performRPC<Result: Sendable>(
        timeout: TimeInterval? = nil,
        allowAuthRetry: Bool = true,
        invalidatesConnectionOnFailure: Bool = false,
        _ operation: @Sendable @escaping (GRPCClient<HTTP2ClientTransport.TransportServices>) async throws -> Result
    ) async throws -> Result {
        let cm = GRPCChannelManager.shared
        var lastError: Error?

        for attempt in 0..<3 {
            let usingVEIL = cm.veilProxyPort() != nil
            let routerSnapshot = await TransportRouter.shared.snapshot()
            let veilRelayVerified: Bool = {
                if !usingVEIL { return true }
                if case .veilActive = routerSnapshot.state { return true }
                return false
            }()
            let capturedRelayAddr = usingVEIL ? routerSnapshot.state.currentRelay : nil
            let effectiveTimeout: TimeInterval? = {
                guard let timeout else { return nil }
                // Unverified VEIL relay: use a short timeout so DPI-blocked obfs4 tunnels
                // are detected in ~5s instead of 15–30s, enabling fast relay rotation.
                if usingVEIL, !veilRelayVerified {
                    return min(timeout, NetworkTiming.VEIL.unverifiedRelayTimeout)
                }
                return timeout
            }()

            // ------------------------------------------------------------------
            // Prefer the persistent connection (no TLS handshake on hot path).
            // Fall back to a per-call client only when persistence isn't available.
            // ------------------------------------------------------------------
            let usingPersistent: Bool
            var capturedGen: UInt64 = 0
            let client: GRPCClient<HTTP2ClientTransport.TransportServices>
            if let pc = try? cm.acquirePersistentClient() {
                client = pc
                usingPersistent = true
                // Capture generation AFTER acquiring so the catch block can skip invalidation
                // if routing changed while this RPC was in-flight.
                capturedGen = cm.captureConnectionGeneration()
            } else {
                client = try cm.makeClient()
                usingPersistent = false
            }

            let rpcStart = Date()
            do {
                let result = try await executeWithTimeout(
                    client: client,
                    usingPersistent: usingPersistent,
                    timeout: effectiveTimeout,
                    operation: operation
                )
                PerformanceMetrics.shared.end(.grpcConnectStart, endEvent: .grpcConnectEnd, label: cm.currentRoutingKey)
                let latencyMs = Int(Date().timeIntervalSince(rpcStart) * 1000)
                let target: TransportTarget
                if let port = cm.veilProxyPort(), let addr = capturedRelayAddr {
                    target = .veil(port: port, relay: addr)
                } else {
                    target = .direct(.h2)
                }
                await TransportRouter.shared.send(.rpcSucceeded(via: target, latencyMs: latencyMs))
                return result
            } catch {
                lastError = error
                handleConnectionCleanup(
                    error: error,
                    usingPersistent: usingPersistent,
                    capturedGen: capturedGen,
                    invalidatesConnectionOnFailure: invalidatesConnectionOnFailure,
                    client: client
                )

                // Classify the failure and feed it into the TransportRouter FSM.
                // The router decides on rotation / probe restart / cooldown via effects;
                // here we only decide whether to retry the local for-loop.
                let kind = RPCFailureClassifier.classify(error)
                let target: TransportTarget
                if usingVEIL, let port = cm.veilProxyPort(), let addr = capturedRelayAddr {
                    target = .veil(port: port, relay: addr)
                } else {
                    target = .direct(.h2)
                }
                // Pass the REAL foreground state. The FSM's rotate/escalate guards
                // (reduceActive / reduceDirect) intentionally ignore background failures: iOS
                // suspends the Rust VEIL runtime in the background and reclaims its local socket,
                // so a `staleLocalProxy` there is expected and restarting the proxy would just
                // churn (spin up a session that gets re-suspended seconds later). Hardcoding
                // `true` here defeated that guard; use the tracker instead.
                let isForeground = AppActivityState.shared.isForeground
                await TransportRouter.shared.send(.rpcFailed(kind: kind, via: target, foreground: isForeground))

                // On staleLocalProxy the FSM emits effects to rebuild VEIL; let the next
                // for-iteration use the freshly set port (or fall back to direct if rebuild failed).
                // Backgrounded, the FSM won't rebuild, so retrying the dead port is pointless —
                // bail out and let the caller (e.g. background fetch) fail gracefully.
                if kind == .staleLocalProxy {
                    if isForeground { continue } else { throw error }
                }

                // Auth retry on first attempt — only if no transport failure was already handled.
                var authRetryResult: AuthRetryResult = .networkOffline
                if let rpc = error as? RPCError,
                   rpc.code == .unauthenticated,
                   allowAuthRetry,
                   attempt == 0 {
                    authRetryResult = await handleAuthRetry(
                        rpcError: rpc,
                        usingVEIL: usingVEIL,
                        capturedRelayAddr: capturedRelayAddr
                    )
                    if case .retry = authRetryResult { continue }
                }

                // If the auth retry's own refresh RPC hit a transport failure, push it to the FSM
                // so the router can rotate the relay. We then propagate the original error.
                if usingVEIL, case .transportFailure(let reason) = authRetryResult {
                    let refreshKind = RPCFailureClassifier.classifyVEILReason(reason)
                    await TransportRouter.shared.send(
                        .rpcFailed(kind: refreshKind, via: target, foreground: isForeground)
                    )
                }

                // Auth rejection through an untrusted VEIL relay: rotate via FSM; tokens NOT wiped.
                if case .suspectRejection = authRetryResult {
                    await TransportRouter.shared.send(
                        .rpcFailed(kind: .tlsFingerprintBlocked, via: target, foreground: isForeground)
                    )
                    continue
                }

                throw error
            }
        }

        throw lastError ?? NetworkError.connectionFailed
    }

    // MARK: - Execution (timeout enforcement)

    private func executeWithTimeout<Result: Sendable>(
        client: GRPCClient<HTTP2ClientTransport.TransportServices>,
        usingPersistent: Bool,
        timeout: TimeInterval?,
        operation: @Sendable @escaping (GRPCClient<HTTP2ClientTransport.TransportServices>) async throws -> Result
    ) async throws -> Result {
        if usingPersistent {
            return try await executeOnPersistentClient(client: client, timeout: timeout, operation: operation)
        } else {
            return try await executeOnPerCallClient(client: client, timeout: timeout, operation: operation)
        }
    }

    /// Runs `operation` on a persistent client. `runConnections()` is already running in the
    /// background; we only need to enforce the client-side deadline.
    private func executeOnPersistentClient<Result: Sendable>(
        client: GRPCClient<HTTP2ClientTransport.TransportServices>,
        timeout: TimeInterval?,
        operation: @Sendable @escaping (GRPCClient<HTTP2ClientTransport.TransportServices>) async throws -> Result
    ) async throws -> Result {
        guard let timeout else { return try await operation(client) }

        // capSleep + watcher pattern: withThrowingTaskGroup blocks until ALL child tasks finish
        // even after one throws, and gRPC-Swift calls don't respond to cooperative cancellation
        // — the group would hang for the full server timeout (~30 s) instead of the configured
        // deadline. Task.sleep DOES honour cancellation, so we use it as the timer and cancel it
        // from a watcher when the RPC completes first.
        let opTask   = Task<Result, Error> { try await operation(client) }
        let capSleep = Task<Void,   Error> { try await Task.sleep(for: .seconds(timeout)) }
        Task { _ = try? await opTask.value; capSleep.cancel() }
        do {
            try await withTaskCancellationHandler {
                try await capSleep.value
            } onCancel: { capSleep.cancel() }
            // capSleep completed normally → deadline reached.
            opTask.cancel()
            throw GRPCClientError.clientSideTimeout
        } catch is CancellationError {
            if Task.isCancelled { opTask.cancel(); throw CancellationError() }
            // Watcher cancelled the timer → RPC finished first; fall through.
        }
        return try await opTask.value
    }

    /// Runs `operation` on a per-call client by co-running with `runConnections()` so a transport
    /// failure surfaces immediately instead of hanging until the server timeout.
    private func executeOnPerCallClient<Result: Sendable>(
        client: GRPCClient<HTTP2ClientTransport.TransportServices>,
        timeout: TimeInterval?,
        operation: @Sendable @escaping (GRPCClient<HTTP2ClientTransport.TransportServices>) async throws -> Result
    ) async throws -> Result {
        try await withThrowingTaskGroup(of: Result?.self) { group in
            group.addTask {
                do {
                    try await client.runConnections()
                    return nil
                } catch is CancellationError {
                    return nil
                } catch {
                    Log.error("gRPC transport error: \(error)", category: "GRPCChannel")
                    throw error
                }
            }

            group.addTask {
                let r: Result
                if let timeout {
                    let opTask   = Task<Result, Error> { try await operation(client) }
                    let capSleep = Task<Void,   Error> { try await Task.sleep(for: .seconds(timeout)) }
                    Task { _ = try? await opTask.value; capSleep.cancel() }
                    do {
                        try await withTaskCancellationHandler {
                            try await capSleep.value
                        } onCancel: { capSleep.cancel() }
                        opTask.cancel()
                        throw GRPCClientError.clientSideTimeout
                    } catch is CancellationError {
                        if Task.isCancelled { opTask.cancel(); throw CancellationError() }
                    }
                    r = try await opTask.value
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

    // MARK: - Connection Cleanup

    private func handleConnectionCleanup(
        error: Error,
        usingPersistent: Bool,
        capturedGen: UInt64,
        invalidatesConnectionOnFailure: Bool,
        client: GRPCClient<HTTP2ClientTransport.TransportServices>
    ) {
        if usingPersistent {
            // Only invalidate if routing hasn't changed since this RPC started.
            // Skip invalidation for client-side timeouts and cancellations —
            // the connection is not broken in those cases, only the request was abandoned.
            let isTransient = isTransientClientError(error)
            if invalidatesConnectionOnFailure, !isTransient {
                GRPCChannelManager.shared.invalidatePersistentClientIfGeneration(capturedGen)
            }
        } else {
            client.beginGracefulShutdown()
        }
    }

    // MARK: - Auth Retry

    /// Result of an auth retry attempt.
    enum AuthRetryResult: Sendable {
        /// Refresh succeeded — caller should retry the original RPC.
        case retry
        /// Server rejected the refresh token — trigger re-auth.
        case serverRejected
        /// Refresh RPC failed due to transport failure — caller should handle VEIL first.
        case transportFailure(VeilFailureReason)
        /// Network offline (unavailable, deadline) — keep tokens for retry when online.
        case networkOffline
        /// Rejection looks permanent at the protocol layer, but the response came through
        /// an VEIL relay that cannot be trusted to forward auth responses unmodified.
        /// Caller should rotate the relay and retry — DO NOT wipe tokens yet.
        case suspectRejection
    }

    /// Returns whether the RPC should be retried after a token refresh.
    /// - Parameter usingVEIL: whether the original RPC was routed through an VEIL relay.
    /// - Parameter capturedRelayAddr: the relay address active when the original RPC started.
    private func handleAuthRetry(
        rpcError: RPCError,
        usingVEIL: Bool,
        capturedRelayAddr: String?
    ) async -> AuthRetryResult {
        var refreshError: Error?
        do {
            let refreshed = try await TokenRefreshCoordinator.shared.refreshIfPossible()
            if refreshed { return .retry }
        } catch {
            refreshError = error
            Log.error("Token refresh failed during RPC retry: \(error)", category: "GRPCChannel")
        }

        // Classify the refresh error — transport failures must bubble up.
        if let refreshErr = refreshError, let reason = VeilFailurePolicy.classify(refreshErr) {
            return .transportFailure(reason)
        }

        // Wipe tokens only when the server explicitly rejected them.
        // Network errors (unavailable, deadline) mean the endpoint was unreachable —
        // keep the existing token so the user can retry when connectivity returns.
        let serverRejected: Bool
        if let rpcErr = refreshError {
            serverRejected = TokenRefreshCoordinator.isRefreshTokenPermanentlyInvalid(rpcErr)
        } else {
            serverRejected = refreshError == nil   // refreshIfPossible() returned false
        }
        if serverRejected {
            // Concurrent-refresh race guard: another caller may have already rotated to a
            // fresh, valid token while this attempt was using the now-consumed one. A server
            // "already used / revoked" then means *this* attempt lost the race, NOT that the
            // session is dead. If we now hold a valid session, retry with the new token instead
            // of wiping it — wiping here was the launch-time death spiral (good tokens nuked by
            // a stale racer). Applies to both transport paths.
            let haveValidSession = await MainActor.run {
                AuthSessionManager.shared.sessionToken != nil && AuthSessionManager.shared.isSessionValid
            }
            if haveValidSession {
                Log.info("Refresh rejected, but a concurrent refresh produced a valid session — retrying with the new token", category: "GRPCChannel")
                await TokenRefreshCoordinator.shared.resetInvalidation()
                return .retry
            }

            // A hostile or broken VEIL relay can synthesise an UNAUTHENTICATED / PERMISSION_DENIED
            // response that is indistinguishable from a real server rejection at the gRPC layer.
            // On the direct path the response is end-to-end TLS to our server, so trust it.
            // On the VEIL path we cannot tell — rotate the relay and retry, but only a bounded
            // number of times (maxSuspectRotations). With a single veil-front relay, rotation
            // restarts the same relay, so an unbounded loop would churn forever AND keep tearing
            // down the gRPC channel mid-RPC (killing device re-auth). Past the budget, honor the
            // rejection as real so a genuinely dead token can recover via device re-auth.
            if usingVEIL {
                let attempts = await TokenRefreshCoordinator.shared.recordSuspectRejection()
                if attempts <= TokenRefreshCoordinator.maxSuspectRotations {
                    Log.info("Refresh rejected over VEIL relay \(capturedRelayAddr ?? "?") (rotation \(attempts)/\(TokenRefreshCoordinator.maxSuspectRotations)) — not wiping tokens, will rotate", category: "GRPCChannel")
                    // Router rotation is requested by the caller of handleAuthRetry on .suspectRejection.
                    return .suspectRejection
                }
                Log.info("Refresh rejected across \(attempts) VEIL relay rotations — honoring as a real rejection, triggering device re-auth", category: "GRPCChannel")
                await TokenRefreshCoordinator.shared.resetInvalidation()
                await MainActor.run { AuthSessionManager.shared.invalidateTokensForReauth() }
                return .serverRejected
            }
            Log.info("Refresh rejected by server — triggering device re-auth", category: "GRPCChannel")
            await MainActor.run { AuthSessionManager.shared.invalidateTokensForReauth() }
            return .serverRejected
        } else {
            Log.info("Refresh failed (network error) — keeping tokens for retry when online", category: "GRPCChannel")
            return .networkOffline
        }
    }
    
    // MARK: - Error Classification

    /// True for errors that should NOT invalidate the persistent connection
    /// (client-side timeouts, user-initiated cancellations, gRPC `.cancelled`).
    private func isTransientClientError(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if error is GRPCClientError   { return true }
        if let rpc = error as? RPCError, rpc.code == .cancelled { return true }
        return false
    }
}
