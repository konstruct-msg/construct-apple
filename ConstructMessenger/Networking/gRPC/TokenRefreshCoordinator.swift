import Foundation

/// Serializes refresh-token requests so multiple concurrent RPCs that hit
/// `.unauthenticated` don't stampede the refresh endpoint.
actor TokenRefreshCoordinator {
    static let shared = TokenRefreshCoordinator()

    private var inFlight: Task<Void, Error>?

    /// Refreshes access token using the stored refresh token.
    /// - Returns: `true` if refresh succeeded and tokens were updated.
    @discardableResult
    func refreshIfPossible() async throws -> Bool {
        if let inFlight {
            try await inFlight.value
            return SessionManager.shared.sessionToken != nil && SessionManager.shared.isSessionValid
        }

        guard let refreshToken = SessionManager.shared.refreshToken, !refreshToken.isEmpty else {
            return false
        }

        let task = Task {
            let response = try await AuthServiceClient.shared.refreshToken(
                refreshToken: refreshToken,
                allowAuthRetry: false
            )

            let expiresIn: Int
            if let expiresAt = response.expiresAt {
                expiresIn = max(Int(expiresAt - Int64(Date().timeIntervalSince1970)), 0)
            } else {
                expiresIn = response.expiresIn ?? 3600
            }

            SessionManager.shared.saveTokens(
                accessToken: response.accessToken,
                refreshToken: response.refreshToken,
                expiresIn: expiresIn
            )
        }

        inFlight = task
        defer { inFlight = nil }
        try await task.value
        return SessionManager.shared.sessionToken != nil && SessionManager.shared.isSessionValid
    }
}

