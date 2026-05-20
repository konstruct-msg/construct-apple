//
//  SessionManager.swift
//  Construct Messenger
//
//  Device-based session management (single device, no multi-account)
//

import Foundation

@MainActor
@Observable
class SessionManager {
    static let shared = SessionManager()
    private init() {}

    // ✅ Session token for API authentication
    private(set) var sessionToken: String?
    
    // ✅ Refresh token for automatic token renewal
    private(set) var refreshToken: String?
    
    // ✅ User ID from server (UUID)
    private(set) var userId: String?

    // Signals that the session was invalidated and device re-auth is needed.
    // Set when tokens expire/are rejected server-side AND token refresh fails.
    private(set) var isSessionInvalidated: Bool = false

    func resetSessionInvalidated() {
        isSessionInvalidated = false
    }

    /// Update the in-memory userId and persist it to Keychain without touching tokens or expiry.
    /// Use this when the userId is recovered from a JWT claim or an auth response,
    /// and the session token itself does not need to change.
    func updateUserId(_ uid: String) {
        guard !uid.isEmpty else { return }
        KeychainManager.shared.saveUserID(uid)
        self.userId = uid
        syncAuthCache()
    }

    /// Clears stored tokens so restoreOrAuthenticateDevice() will fall through to device
    /// signing-key auth. Does NOT remove device keys, userId, or deviceId — identity is preserved.
    func invalidateTokensForReauth() {
        KeychainManager.shared.deleteSessionToken()
        KeychainManager.shared.deleteRefreshToken()
        UserDefaults.standard.removeObject(forKey: UserDefaultsKey.sessionExpires.key)
        self.sessionToken = nil
        self.refreshToken = nil
        isSessionInvalidated = true
        GRPCAuthCache.shared.invalidate()
        Log.info("🔑 Tokens invalidated — device re-auth will be triggered", category: "SessionManager")
    }
    
    // ✅ Get userId (prefer stored userId, fallback to deviceId for compatibility)
    var currentUserId: String? {
        if let userId = userId, !userId.isEmpty {
            return userId
        }
        // Fallback to userId from Keychain
        if let savedUserId = KeychainManager.shared.loadUserID(), !savedUserId.isEmpty {
            return savedUserId
        }
        return nil
    }

    // ✅ Get deviceId from Keychain (stable for lifetime of the Keychain)
    var currentDeviceId: String? {
        KeychainManager.shared.loadDeviceID()
    }

    /// Cached local display name. Updated by AuthViewModel after login/restore.
    var currentDisplayName: String {
        UserDefaults.standard.string(forKey: "local_display_name") ?? ""
    }

    func saveDisplayName(_ name: String) {
        UserDefaults.standard.set(name, forKey: "local_display_name")
    }

    // ✅ Get session expiration timestamp
    var sessionExpires: Date? {
        guard let timestamp = UserDefaults.standard.object(forKey: UserDefaultsKey.sessionExpires.key) as? TimeInterval else {
            return nil
        }
        return Date(timeIntervalSince1970: timestamp)
    }

    // ✅ Check if session is valid (not expired)
    var isSessionValid: Bool {
        guard sessionToken != nil else { return false }

        // Check expiration (with 5-minute buffer)
        guard let expires = sessionExpires else { return false }
        let bufferTime: TimeInterval = 5 * 60  // 5 minutes
        return Date().addingTimeInterval(bufferTime) < expires
    }

    // ✅ Load token from keychain on init or when needed
    func loadSessionToken() {
        sessionToken = KeychainManager.shared.loadSessionToken()
        refreshToken = KeychainManager.shared.loadRefreshToken()
        userId = KeychainManager.shared.loadUserID()

        if let token = sessionToken,
           let alg = JWTUtils.headerAlgorithm(from: token),
           alg != "RS256" {
            Log.error("❌ Unsupported JWT alg in cached token: \(alg). Clearing session.", category: "SessionManager")
            clearSession()
            isSessionInvalidated = true
            return
        }
        syncAuthCache()
    }
    
    // ✅ Save both access and refresh tokens with expiration and userId
    func saveTokens(accessToken: String, refreshToken: String, expiresIn: Int, userId: String? = nil) {
        // Save tokens to keychain
        KeychainManager.shared.saveSessionToken(accessToken)
        KeychainManager.shared.saveRefreshToken(refreshToken)
        
        // Save userId if provided
        if let userId = userId {
            KeychainManager.shared.saveUserID(userId)
            self.userId = userId
            Log.info("✅ User ID saved: \(userId.prefix(8))...", category: "SessionManager")
        }
        
        // Calculate expiration (expiresIn is in seconds)
        let expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
        UserDefaults.standard.set(expiresAt.timeIntervalSince1970, forKey: UserDefaultsKey.sessionExpires.key)
        
        // Update published properties
        self.sessionToken = accessToken
        self.refreshToken = refreshToken
        
        Log.info("✅ Tokens saved - expires in: \(expiresIn / 60) minutes", category: "SessionManager")
        syncAuthCache()
    }

    func clearSession() {
        KeychainManager.shared.deleteSessionToken()
        KeychainManager.shared.deleteRefreshToken()
        KeychainManager.shared.deleteUserID()
        UserDefaults.standard.removeObject(forKey: UserDefaultsKey.sessionExpires.key)
        
        // Clear published properties
        self.sessionToken = nil
        self.refreshToken = nil
        self.userId = nil
        syncAuthCache()
    }

    // MARK: - Auth cache sync

    /// Snapshots the current session state into `GRPCAuthCache` so `AuthInterceptor`
    /// can read auth credentials without a MainActor hop on every RPC call.
    /// Must be called after any mutation to session token, userId, or expiry.
    private func syncAuthCache() {
        GRPCAuthCache.shared.update(AuthSnapshot(
            token: sessionToken,
            userId: currentUserId,
            deviceId: currentDeviceId,
            expiresAt: sessionExpires
        ))
    }
}
