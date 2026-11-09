import Foundation
import GRPCCore

/// Serializes refresh-token requests so multiple concurrent RPCs that hit
/// `.unauthenticated` don't stampede the refresh endpoint.
actor TokenRefreshCoordinator {
    static let shared = TokenRefreshCoordinator()

    /// Returns `true` when the error indicates the refresh token itself is
    /// permanently invalid (revoked, consumed, or explicitly rejected by the server).
    /// Callers should wipe stored tokens and trigger device re-auth on `true`.
    /// On `false` the error is a transient network/connectivity failure and the
    /// existing tokens should be kept for the next retry.
    static func isRefreshTokenPermanentlyInvalid(_ error: Error) -> Bool {
        guard let rpc = error as? RPCError else { return false }
        switch rpc.code {
        case .unauthenticated, .permissionDenied:
            return true
        case .internalError:
            // Server returns internalError for "Refresh token was already used or revoked"
            let msg = rpc.message.lowercased()
            return msg.contains("revoked") || msg.contains("already used")
        default:
            return false
        }
    }

    /// Max number of VEIL relay rotations to attempt before honoring an auth rejection
    /// as real. A rejection forwarded by a VEIL relay can't be trusted (a hostile relay
    /// could forge it), so we rotate and retry on a clean relay — but only this many times.
    /// Past it, the rejection is treated as genuine (wipe + device re-auth) so a truly dead
    /// token recovers instead of churning the relay forever.
    static let maxSuspectRotations = 2

    /// A refresh refused because the server deactivated this device's row: the access token held
    /// here is still within its local lifetime, but it names a device that no longer exists.
    /// Until 2026-11-09 nothing read this, and every caller's race guard (`isSessionValid`) saw a
    /// valid session, so the device-auth answer that wipes it was never asked for: a device removed
    /// while closed kept its data until the token expired (todo 265). `.removed` is permanent, so
    /// it is never a lost refresh race. The same rule as the wipe itself, including "direct TLS
    /// only": a relay that forges it only gets a device re-auth, which still decides on its own.
    static func refusalEndsHeldSession(_ error: Error, overDirectTLS: Bool) -> Bool {
        AuthViewModel.isRemovedDevice(DeviceRefusalReading.refusal(of: error), overDirectTLS: overDirectTLS)
    }

    private let performRefresh: @Sendable () async throws -> Bool
    private let isDirectPath: @Sendable () -> Bool
    private let endHeldSession: @Sendable () async -> Void

    init(
        performRefresh: @escaping @Sendable () async throws -> Bool = { try await TokenRefreshCoordinator.refreshWithStoredToken() },
        isDirectPath: @escaping @Sendable () -> Bool = { GRPCChannelManager.shared.veilProxyPort() == nil },
        // Dropping the tokens wakes `AuthViewModel` (`isSessionInvalidated`), which authenticates
        // the device and wipes it on the server's answer — the one path that decides a wipe.
        endHeldSession: @escaping @Sendable () async -> Void = {
            await MainActor.run { AuthSessionManager.shared.invalidateTokensForReauth() }
        }
    ) {
        self.performRefresh = performRefresh
        self.isDirectPath = isDirectPath
        self.endHeldSession = endHeldSession
    }

    private var inFlight: Task<Bool, Error>?
    // Set when the server permanently rejects the token (revoked / already used).
    // Prevents redundant network requests from concurrent callers after the first rejection.
    // Cleared by resetInvalidation() when new tokens are saved.
    private var permanentlyInvalid = false
    // Consecutive auth rejections received over a VEIL relay. Bounds suspect-relay rotation
    // (see maxSuspectRotations). Reset on any successful token save via resetInvalidation().
    private var suspectRejectionCount = 0

    func resetInvalidation() {
        permanentlyInvalid = false
        suspectRejectionCount = 0
    }

    /// Records one auth rejection seen over a VEIL relay and returns the running count.
    func recordSuspectRejection() -> Int {
        suspectRejectionCount += 1
        return suspectRejectionCount
    }

    /// Refreshes access token using the stored refresh token.
    /// - Returns: `true` if refresh succeeded and tokens were updated.
    @discardableResult
    func refreshIfPossible() async throws -> Bool {
        if permanentlyInvalid { return false }

        // Join an in-flight refresh if one is already running. The task is shared
        // by all concurrent callers so each gets the same success/failure outcome.
        if let inFlight {
            return try await inFlight.value
        }

        // Create + register the task synchronously, *before* any await. Otherwise a
        // second caller arriving at this actor during the suspension would also see
        // inFlight == nil and launch a parallel refresh — both would race on the
        // same stored refresh token and one would be rejected as "already used".
        let task = Task<Bool, Error> { [performRefresh, isDirectPath, endHeldSession] in
            let directBefore = isDirectPath()
            do {
                return try await performRefresh()
            } catch {
                // Inside the shared task, so the session is gone before any caller — this one or
                // one that joined — reaches its race guard.
                if Self.refusalEndsHeldSession(error, overDirectTLS: directBefore && isDirectPath()) {
                    Log.error("Refresh refused: the server removed this device — dropping the held session", category: "Auth")
                    await endHeldSession()
                }
                throw error
            }
        }
        inFlight = task

        defer { inFlight = nil }
        do {
            let ok = try await task.value
            // A successful refresh un-poisons any latched invalidation and clears the
            // suspect-rotation budget — the token is demonstrably good again.
            if ok {
                permanentlyInvalid = false
                suspectRejectionCount = 0
            }
            return ok
        } catch {
            if TokenRefreshCoordinator.isRefreshTokenPermanentlyInvalid(error) {
                permanentlyInvalid = true
            }
            throw error
        }
    }

    /// The refresh RPC with the stored refresh token; persists the new pair. `false` when there is
    /// no refresh token to present.
    private static func refreshWithStoredToken() async throws -> Bool {
        let storedRefreshToken = await MainActor.run { AuthSessionManager.shared.refreshToken }
        guard let storedRefreshToken, !storedRefreshToken.isEmpty else {
            return false
        }

        let response = try await AuthServiceClient.shared.refreshToken(
            refreshToken: storedRefreshToken,
            allowAuthRetry: false
        )

        let expiresIn: Int
        if let expiresAt = response.expiresAt {
            expiresIn = max(Int(expiresAt - Int64(Date().timeIntervalSince1970)), 0)
        } else {
            expiresIn = response.expiresIn ?? 3600
        }

        return await MainActor.run {
            AuthSessionManager.shared.saveTokens(
                accessToken: response.accessToken,
                refreshToken: response.refreshToken,
                expiresIn: expiresIn
            )
            return AuthSessionManager.shared.sessionToken != nil && AuthSessionManager.shared.isSessionValid
        }
    }
}


/// What a scheduled refresh does with its result. A pure decision so the rule "a failed refresh
/// never signs out" is a test, not a comment (`TokenRefreshOutcomeTests`).
enum TokenRefreshOutcome: Equatable {
    case refreshed
    /// The server refused the refresh token (revoked / already used / unauthenticated).
    case refused
    /// Network, timeout, relay — the token may still be good.
    case transient

    enum Action: Equatable {
        case reschedule
        case retry(after: TimeInterval)
        /// Sign the device in again with its own key: same identity, nothing wiped.
        case reauthenticateDevice
    }

    static let transientRetryDelay: TimeInterval = 60

    var action: Action {
        switch self {
        case .refreshed: return .reschedule
        case .transient: return .retry(after: Self.transientRetryDelay)
        case .refused: return .reauthenticateDevice
        }
    }
}
