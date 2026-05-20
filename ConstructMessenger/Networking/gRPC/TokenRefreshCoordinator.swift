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

    private var inFlight: Task<Void, Error>?

    /// Refreshes access token using the stored refresh token.
    /// - Returns: `true` if refresh succeeded and tokens were updated.
    @discardableResult
    func refreshIfPossible() async throws -> Bool {
        if let inFlight {
            try await inFlight.value
            return await MainActor.run { SessionManager.shared.sessionToken != nil && SessionManager.shared.isSessionValid }
        }

        let storedRefreshToken = await MainActor.run { SessionManager.shared.refreshToken }
        guard let storedRefreshToken, !storedRefreshToken.isEmpty else {
            return false
        }

        let task = Task {
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

            await MainActor.run {
                SessionManager.shared.saveTokens(
                    accessToken: response.accessToken,
                    refreshToken: response.refreshToken,
                    expiresIn: expiresIn
                )
            }
        }

        inFlight = task
        defer { inFlight = nil }
        try await task.value
        return await MainActor.run { SessionManager.shared.sessionToken != nil && SessionManager.shared.isSessionValid }
    }
}

