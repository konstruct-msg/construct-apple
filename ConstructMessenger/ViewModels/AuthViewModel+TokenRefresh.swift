//
//  AuthViewModel+TokenRefresh.swift
//  Construct Messenger
//
//  Part of AuthViewModel: access-token refresh scheduling and the timer-driven refresh.
//

import Foundation
import CoreData
import GRPCCore
#if canImport(UIKit)
import UIKit
#endif

extension AuthViewModel {
    // FIXED: Monitor token expiration (single scheduled refresh)
    func startTokenRefreshMonitoring() {
        scheduleTokenRefresh()
    }

    func scheduleTokenRefresh() {
        tokenRefreshTimer?.invalidate()

        guard isAuthenticated else { return }
        guard let expiresAt = AuthSessionManager.shared.sessionExpires else { return }

        let now = Date()
        let refreshTime = expiresAt.addingTimeInterval(-300) // refresh 5 minutes early
        let interval = max(refreshTime.timeIntervalSince(now), 5)

        tokenRefreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                Log.info("Token refresh timer fired", category: "Auth")
                await self?.refreshAccessToken()
            }
        }
    }
    
    /// The timer's refresh. Through the single-flight coordinator, like every other refresh: until
    /// 2026-10-16 this called `refreshToken` itself, and on 2026-10-15 it fired in the same second
    /// as the foreground restore's coordinator refresh. Both presented the one stored refresh
    /// token, the second was rejected as already used, and the rejection ran
    /// `handleSessionExpired` — which wiped the session *and the stream cursor* for an identity
    /// that was back a second later, so the stream replayed the whole backlog.
    ///
    /// A failure here never signs out. Transient: keep the tokens and try again shortly. A refresh
    /// token the server refuses: authenticate the device again — the same identity, no wipe.
    func refreshAccessToken() async {
        let outcome: TokenRefreshOutcome
        do {
            outcome = try await TokenRefreshCoordinator.shared.refreshIfPossible() ? .refreshed : .refused
        } catch {
            outcome = TokenRefreshCoordinator.isRefreshTokenPermanentlyInvalid(error) ? .refused : .transient
            Log.error("Token refresh failed: \(error.localizedDescription)", category: "Auth")
        }
        switch outcome.action {
        case .reschedule:
            Log.info("Access token refreshed (timer)", category: "Auth")
            scheduleTokenRefresh()
        case .retry(let after):
            Log.info("Token refresh will retry in \(Int(after))s; tokens kept", category: "Auth")
            tokenRefreshTimer?.invalidate()
            tokenRefreshTimer = Timer.scheduledTimer(withTimeInterval: after, repeats: false) { [weak self] _ in
                Task { @MainActor in await self?.refreshAccessToken() }
            }
        case .reauthenticateDevice:
            Log.info("Refresh token refused — authenticating the device again (no sign-out)", category: "Auth")
            await restoreOrAuthenticateDevice()
        }
    }
}
