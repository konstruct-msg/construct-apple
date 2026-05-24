import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2

/// Executes gRPC RPCs with retry, auth refresh, client-side timeout, and ICE failover.
///
/// Transport concerns (channel lifecycle, routing, ICE health) remain in `GRPCChannelManager`.
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
            let usingICE = cm.iceProxyPort() != nil
            let iceRelayVerified = usingICE ? await IceProxyManager.shared.isCurrentRelayVerified : true
            let capturedRelayAddr = usingICE ? await IceProxyManager.shared.activeRelay?.address : nil
            let effectiveTimeout: TimeInterval? = {
                guard let timeout else { return nil }
                // Unverified ICE relay: use a short timeout so DPI-blocked obfs4 tunnels
                // are detected in ~5s instead of 15–30s, enabling fast relay rotation.
                if usingICE, !iceRelayVerified {
                    return min(timeout, NetworkTiming.ICE.unverifiedRelayTimeout)
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
                if usingICE, let addr = capturedRelayAddr {
                    let latency = Date().timeIntervalSince(rpcStart)
                    await IceProxyManager.shared.recordRelaySuccess(address: addr, latency: latency)
                }
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

                // ICE failover FIRST — transport errors classified before auth retry.
                if usingICE {
                    if let reason = IceFailurePolicy.classify(error) {
                        let action = await handleICEFailure(
                            reason: reason,
                            error: error,
                            invalidatesConnectionOnFailure: invalidatesConnectionOnFailure
                        )
                        switch action {
                        case .retry:
                            continue
                        case .propagate:
                            break
                        }
                    }
                }

                // Auth retry on first attempt — only if no transport failure was already handled.
                var authRetryResult: AuthRetryResult = .networkOffline
                if let rpc = error as? RPCError,
                   rpc.code == .unauthenticated,
                   allowAuthRetry,
                   attempt == 0 {
                    authRetryResult = await handleAuthRetry(rpcError: rpc)
                    if case .retry = authRetryResult { continue }
                }

                // If the auth retry's own refresh RPC hit a transport failure, handle ICE now.
                // This catches the case where the original error was unauthenticated (masked),
                // but the refresh over the same broken tunnel also failed for a transport reason.
                if usingICE, case .transportFailure(let reason) = authRetryResult {
                    let action = await handleICEFailure(
                        reason: reason,
                        error: error,
                        invalidatesConnectionOnFailure: invalidatesConnectionOnFailure
                    )
                    if case .retry = action { continue }
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
                    Log.error("⚠️ gRPC transport error: \(error)", category: "GRPCChannel")
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
        /// Refresh RPC failed due to transport failure — caller should handle ICE first.
        case transportFailure(IceFailureReason)
        /// Network offline (unavailable, deadline) — keep tokens for retry when online.
        case networkOffline
    }

    /// Returns whether the RPC should be retried after a token refresh.
    private func handleAuthRetry(rpcError: RPCError) async -> AuthRetryResult {
        var refreshError: Error?
        do {
            let refreshed = try await TokenRefreshCoordinator.shared.refreshIfPossible()
            if refreshed { return .retry }
        } catch {
            refreshError = error
            Log.error("⚠️ Token refresh failed during RPC retry: \(error)", category: "GRPCChannel")
        }
        
        // Classify the refresh error — transport failures must bubble up.
        if let refreshErr = refreshError, let reason = IceFailurePolicy.classify(refreshErr) {
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
            Log.info("🔑 Refresh rejected by server — triggering device re-auth", category: "GRPCChannel")
            await MainActor.run { SessionManager.shared.invalidateTokensForReauth() }
            return .serverRejected
        } else {
            Log.info("🔑 Refresh failed (network error) — keeping tokens for retry when online", category: "GRPCChannel")
            return .networkOffline
        }
    }
    
    // MARK: - ICE Failover

    enum ICEAction: Equatable { case retry, propagate }

    func handleICEFailure(reason: IceFailureReason, error: Error, invalidatesConnectionOnFailure: Bool) async -> ICEAction {
        let cm = GRPCChannelManager.shared
        let connectionLoopActive = cm.isConnectionLoopActive

        if reason == .staleLocalProxy {
            // ECONNREFUSED on 127.0.0.1 — local proxy died.
            // Restart immediately; do NOT enter cooldown (process crash, not relay failure).
            Log.info("🧊 ICE proxy port dead (ECONNREFUSED) — restarting proxy", category: "gRPC")
            if connectionLoopActive {
                // IceProxy.ensure() detects isAlive()==false and restarts cleanly.
                // Do NOT call recordFailure() here — staleLocalProxy is a local crash,
                // not a relay quality issue, so the relay must not be penalised.
                _ = try? await ConnectionLoop.shared.prepare()
            } else {
                await IceProxyManager.shared.restartAfterCrash()
                await cm.waitForProxyReady()
            }
            if cm.iceProxyPort() != nil { return .retry }
            return .propagate
        }

        // ── ConnectionLoop path ───────────────────────────────────────────────────────────
        // When ConnectionLoop owns the proxy, delegate all relay lifecycle decisions to it.
        // Calling IceProxyManager.rotateToNextRelay() / scheduleRotation() would invoke
        // runtime.stop() on the same Rust globals that ConnectionLoop.IceProxy manages,
        // causing proxy ownership conflicts and ping-pong restarts.
        if connectionLoopActive {
            await ConnectionLoop.shared.recordFailure(error)
            if invalidatesConnectionOnFailure {
                if (try? await ConnectionLoop.shared.prepare()) != nil {
                    cm.invalidatePersistentClient()
                    return .retry
                }
            }
            // Background RPC: RelayPool updated, proxy untouched — live stream may be healthy.
            return .propagate
        }

        // ── Legacy path: IceProxyManager owns the proxy ───────────────────────────────────
        let failedAddr = await IceProxyManager.shared.activeRelay?.address

        if invalidatesConnectionOnFailure {
            // Relay tunnel broken. Check for WebTunnel-specific failure first:
            // try alternate SNIs then obfs4 before rotating to a new relay.
            let webTunnelActive = await IceProxyManager.shared.isWebTunnelActive
            if reason == .webTunnelBlocked, webTunnelActive {
                Log.info("🧊 WebTunnel blocked (non-200) — retrying relay via alternate SNI or obfs4", category: "gRPC")
                let obfs4OK = await IceProxyManager.shared.retryCurrentRelayAsObfs4(hintAddress: failedAddr)
                if obfs4OK {
                    cm.invalidatePersistentClient()
                    await cm.waitForProxyReady()
                    Log.info("🧊 ICE obfs4 fallback active — retrying via same relay", category: "gRPC")
                    return .retry
                }
                if let addr = failedAddr {
                    let type = IceFailurePolicy.relayFailureType(for: reason)
                    await IceProxyManager.shared.recordRelayFailure(address: addr, type: type)
                }
            } else if reason == .tlsCertExpired {
                // Expired TLS cert — fetch fresh config + cert from .well-known and restart.
                Log.info("🧊 TLS cert expired on relay — refreshing cert + config", category: "gRPC")
                let refreshed = await IceProxyManager.shared.refreshCertAndRestart()
                if refreshed {
                    cm.invalidatePersistentClient()
                    await cm.waitForProxyReady()
                    return .retry
                }
                if let addr = failedAddr {
                    let type = IceFailurePolicy.relayFailureType(for: reason)
                    await IceProxyManager.shared.recordRelayFailure(address: addr, type: type)
                }
            } else if reason == .tlsFingerprintBlocked {
                // TLS alert 40: relay fingerprint detected by DPI — rotate to different relay quickly.
                Log.info("🧊 TLS fingerprint blocked (alert 40) on relay — rotating", category: "gRPC")
                if let addr = failedAddr {
                    let type = IceFailurePolicy.relayFailureType(for: reason)
                    await IceProxyManager.shared.recordRelayFailure(address: addr, type: type)
                }
            } else {
                // General transport failure — map reason to TTL.
                if let addr = failedAddr {
                    let type = IceFailurePolicy.relayFailureType(for: reason)
                    await IceProxyManager.shared.recordRelayFailure(address: addr, type: type)
                }
            }

            let rotated = await IceProxyManager.shared.rotateToNextRelay()
            if rotated {
                // If all relays were recently blacklisted, we just restarted the least-bad one.
                // Wait 30 s so old TCP connections drain before we create new ones.
                if await IceProxyManager.shared.allRelaysRecentlyFailed {
                    Log.info("🧊 All relays blacklisted — waiting 30s to let connections drain", category: "gRPC")
                    try? await Task.sleep(for: .seconds(30))
                }
                cm.invalidatePersistentClient()
                await cm.waitForProxyReady()
                Log.info("🧊 Relay rotated inline — retrying via new relay", category: "gRPC")
                return .retry
            }
            // All relays exhausted — enter cooldown for direct fallback.
            cm.recordICEFailure(failedAddress: failedAddr)
        } else {
            // Background RPC: record relay failure so future connections avoid it,
            // but do NOT rotate or invalidate — that would kill any live stream.
            if let addr = failedAddr {
                let type = IceFailurePolicy.relayFailureType(for: reason)
                await IceProxyManager.shared.recordRelayFailure(address: addr, type: type)
            }

            // EXCEPTION: WebTunnel-blocked and TLS-fingerprint-blocked are definitive
            // transport failures — the tunnel is dead even if the stream doesn't know yet.
            // Trigger coalesced rotation so the next RPC sees a fresh relay.
            if reason == .webTunnelBlocked || reason == .tlsFingerprintBlocked {
                await IceProxyManager.shared.scheduleRotation(reason: reason)
            }
        }
        return .propagate
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
