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

    private var inFlight: Task<Bool, Error>?
    // Set when the server permanently rejects the token (revoked / already used).
    // Prevents redundant network requests from concurrent callers after the first rejection.
    // Cleared by resetInvalidation() when new tokens are saved via device re-auth.
    private var permanentlyInvalid = false

    func resetInvalidation() {
        permanentlyInvalid = false
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
        let task = Task<Bool, Error> {
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
        inFlight = task

        defer { inFlight = nil }
        do {
            return try await task.value
        } catch {
            if TokenRefreshCoordinator.isRefreshTokenPermanentlyInvalid(error) {
                permanentlyInvalid = true
            }
            throw error
        }
    }
}

