//
//  AuthViewModel.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import Foundation
import CoreData
import CryptoKit
#if canImport(UIKit)
import UIKit
#endif

@MainActor
@Observable
class AuthViewModel {
    var isAuthenticated = false
    var currentUserId: String?

    /// Tracks whether device keys are registered in Keychain (drives ContentView routing)
    var hasRegisteredDeviceKeys: Bool? = nil

    /// True when the user is authenticated but device crypto keys couldn't be loaded
    /// from Keychain. Drives a dedicated recovery screen instead of the main app.
    var deviceKeysUnavailable = false

    /// True while RegistrationFlowView is active. Prevents restoreOrAuthenticateDevice()
    /// from interfering with an ongoing registration (the stream's UNAUTHENTICATED errors
    /// would otherwise trigger auth re-attempts every few seconds).
    var isRegistrationInProgress = false

    func refreshDeviceKeyState() {
        // If already authenticated, don't re-read Keychain — it may be temporarily
        // inaccessible (WhenUnlockedThisDeviceOnly items while device is locked via
        // SecurityGateView / biometrics). Returning false here would incorrectly
        // show OnboardingView for an authenticated user.
        if isAuthenticated {
            hasRegisteredDeviceKeys = true
            return
        }
        // Use only deviceId (kSecAttrAccessibleAfterFirstUnlock) as the routing signal.
        // signingKey / identityKey use kSecAttrAccessibleWhenUnlockedThisDeviceOnly and
        // are unavailable when the app is woken in the background (notifications, background
        // fetch) while the device is locked — causing a spurious flash to OnboardingView.
        // Crypto key health is verified by restoreOrAuthenticateDevice(); if keys are missing
        // or corrupted it sets deviceKeysUnavailable = true and shows KeysRecoveryView.
        hasRegisteredDeviceKeys = KeychainManager.shared.loadDeviceID() != nil
    }
    
    // ✅ REFACTOR Phase 1.2: Single source of truth - Core Data User entity
    var currentUser: User?
    
    // ✅ Computed properties for convenience (backwards compatibility)
    var currentUsername: String {
        currentUser?.username ?? ""
    }
    
    var currentDisplayName: String {
        currentUser?.displayName ?? currentUser?.username ?? ""
    }
    
    var isLoading = false
    /// Set to true when a server-side account deletion fails, enabling the local-only fallback button.
    var deleteAccountFailed = false

    private var sessionRestoreTimer: Timer?
    private var authOperationTimer: Timer?
    private let viewContext: NSManagedObjectContext
    private var sessionExpiredTask: Task<Void, Never>?
    private var tokenObserverTask: Task<Void, Never>?

    // Timer for monitoring token expiration
    private var tokenRefreshTimer: Timer?

    private var restoreInFlight = false
    private var lastRestoreAttemptAt: Date?

    init(context: NSManagedObjectContext) {
        self.viewContext = context
        setupSubscribers()
        startTokenRefreshMonitoring()
        setupSessionExpiredListener()
        // hasRegisteredDeviceKeys intentionally left nil so SplashView renders while
        // the async auth task runs. It is set by restoreOrAuthenticateDevice() in all
        // exit paths; refreshDeviceKeyState() is the fallback for unexpected returns.
        Task { [weak self] in
            await self?.restoreOrAuthenticateDevice()
            // Safety net: if the async task returned without resolving the routing state,
            // fall back to a synchronous Keychain read so the app never stays on SplashView.
            if self?.hasRegisteredDeviceKeys == nil {
                self?.refreshDeviceKeyState()
            }
        }
    }
    
    // Subscribe to session invalidation from AuthSessionManager
    private func setupSessionExpiredListener() {
        sessionExpiredTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = AuthSessionManager.shared.isSessionInvalidated
                    } onChange: {
                        continuation.resume()
                    }
                }
                guard !Task.isCancelled else { break }
                if AuthSessionManager.shared.isSessionInvalidated {
                    AuthSessionManager.shared.resetSessionInvalidated()
                    await self.restoreOrAuthenticateDevice()
                }
            }
        }
    }

    isolated deinit {
        tokenRefreshTimer?.invalidate()
        authOperationTimer?.invalidate()
        sessionRestoreTimer?.invalidate()
        sessionExpiredTask?.cancel()
        tokenObserverTask?.cancel()
    }

    private func setupSubscribers() {
        // ✅ Using gRPC for all messaging
        // Session expiration is handled via setupSessionExpiredListener()
        // Keep the token refresh timer in sync even if tokens are refreshed outside AuthViewModel
        // (e.g. on-demand refresh after an `.unauthenticated` gRPC error).
        tokenObserverTask?.cancel()
        tokenObserverTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = AuthSessionManager.shared.sessionToken
                        _ = AuthSessionManager.shared.sessionExpires
                    } onChange: {
                        continuation.resume()
                    }
                }
                guard !Task.isCancelled else { break }
                if self.isAuthenticated {
                    self.scheduleTokenRefresh()
                }
            }
        }
    }

    // MARK: - Session Management
    
    /// Restore existing session OR authenticate with device keys
    func restoreOrAuthenticateDevice() async {
        // Registration is in progress — don't interfere. The stream's UNAUTHENTICATED
        // errors would otherwise fire repeated re-auth attempts every few seconds.
        if isRegistrationInProgress { return }
        // Coalesce repeated calls (scenePhase, permission prompts, etc.)
        if restoreInFlight { return }
        // When no device keys exist the app is in first-run registration mode.
        // Use a 30-second window to prevent the stream reconnect loop from
        // hammering this path (it retries at 2 / 4 / 8 / 16 / 32 s intervals).
        let debounceWindow: TimeInterval = KeychainManager.shared.isDeviceRegistered() ? 2 : 30
        if let last = lastRestoreAttemptAt, Date().timeIntervalSince(last) < debounceWindow {
            return
        }
        lastRestoreAttemptAt = Date()
        restoreInFlight = true
        defer { restoreInFlight = false }

        Log.info("restoreOrAuthenticateDevice() called")
        
        // Step 1: Try to restore existing session token
        AuthSessionManager.shared.loadSessionToken()

        // Helper: recover userId from JWT payload when Keychain entry is missing.
        // The server embeds the user ID in the `sub` claim of every issued JWT.
        // Only touches userId — does NOT re-save tokens or overwrite session expiry.
        func recoverUserIdFromToken() -> String? {
            guard let token = AuthSessionManager.shared.sessionToken,
                  let uid = JWTUtils.extractUserId(from: token),
                  !uid.isEmpty else { return nil }
            AuthSessionManager.shared.updateUserId(uid)
            Log.info("[Auth] userId recovered from JWT sub claim and re-saved to Keychain: \(uid.prefix(8))...", category: "Auth")
            return uid
        }

        // Resolve userId — prefer in-memory/Keychain, fall back to JWT extraction.
        func resolvedUserId() -> String? {
            if let uid = AuthSessionManager.shared.currentUserId { return uid }
            return recoverUserIdFromToken()
        }

        // Common setup after any successful auth path: schedules token refresh,
        // wires up CryptoCore, loads user profile, and starts SPK rotation check
        // in the background so it completes before the user can share a QR code.
        func finishAuth(userId: String) {
            self.currentUserId = userId
            self.isAuthenticated = true
            scheduleTokenRefresh()
            CryptoManager.shared.setLocalUserId(userId)
            loadUserFromCoreData(userId: userId)
            #if !os(macOS)
            // Engine manages SPK rotation on macOS.
            Task { [weak self] in
                guard self != nil else { return }
                let deviceId = KeychainManager.shared.loadDeviceID() ?? ""
                await PreKeyRotationService.shared.rotateIfNeeded(deviceId: deviceId)
            }
            #endif
            Task { [weak self] in
                guard self != nil else { return }
                await ServerKeyManager.shared.prefetch()
            }
        }

        if let _ = AuthSessionManager.shared.sessionToken,
           let userId = resolvedUserId(),
           AuthSessionManager.shared.isSessionValid {
            // We have session token - verify it's still valid
            Log.info("Found session token for user: \(userId)")
            if !CryptoManager.shared.isInitialized {
                self.currentUserId = userId
                self.isAuthenticated = true
                scheduleTokenRefresh()
                CryptoManager.shared.setLocalUserId(userId)
                if CryptoManager.shared.isInitialized {
                    finishAuth(userId: userId)
                } else {
                    handleLostDeviceKeys(userId: userId, reason: "keys missing after session token restore")
                }
                return
            }
            finishAuth(userId: userId)
            return
        }

        // Step 1.5: Token exists but is expired/near-expired — refresh using refresh token first.
        // This is faster and less error-prone than full device auth, and keeps the gRPC stream stable.
        if AuthSessionManager.shared.sessionToken != nil,
           let userId = resolvedUserId(),
           let refresh = AuthSessionManager.shared.refreshToken {
            do {
                Log.info("Session token expired — attempting refresh", category: "Auth")
                let response = try await AuthServiceClient.shared.refreshToken(refreshToken: refresh)

                let expiresIn: Int
                if let expiresAt = response.expiresAt {
                    expiresIn = max(Int(expiresAt - Int64(Date().timeIntervalSince1970)), 0)
                } else {
                    expiresIn = response.expiresIn ?? 3600
                }

                // Preserve userId even if the refresh response doesn't include it.
                let refreshedUserId = response.userId.isEmpty ? userId : response.userId
                AuthSessionManager.shared.saveTokens(
                    accessToken: response.accessToken,
                    refreshToken: response.refreshToken,
                    expiresIn: expiresIn,
                    userId: refreshedUserId
                )

                if !CryptoManager.shared.isInitialized {
                    self.currentUserId = userId
                    self.isAuthenticated = true
                    scheduleTokenRefresh()
                    CryptoManager.shared.setLocalUserId(userId)
                    if CryptoManager.shared.isInitialized {
                        finishAuth(userId: userId)
                    } else {
                        handleLostDeviceKeys(userId: userId, reason: "keys missing after token refresh")
                    }
                    return
                }
                finishAuth(userId: userId)
                Log.info("Session refreshed successfully", category: "Auth")
                return
            } catch {
                Log.error("Session refresh failed, falling back to device auth: \(error)", category: "Auth")
            }
        }
        
        // Step 2: No session token - try device-based auth
        guard let deviceId = KeychainManager.shared.loadDeviceID(),
              let rawSigningKey = KeychainManager.shared.loadDeviceSigningKey() else {
            Log.info("No device keys found - user needs to register")
            // Definitively mark as unregistered so ContentView routes to OnboardingView.
            // refreshDeviceKeyState() uses only deviceId (AfterFirstUnlock) which may have
            // been nil at init time; this async confirmation is the source of truth.
            hasRegisteredDeviceKeys = false
            return
        }
        
        Log.info("Device keys found - authenticating with device ID: \(deviceId)")
        
        do {
            // Create signature: Sign("{device_id}{timestamp}") with Ed25519 — must match server format
            let timestamp = Int64(Date().timeIntervalSince1970)
            let message = "\(deviceId)\(timestamp)"
            guard let messageData = message.data(using: .utf8) else {
                throw NetworkError.encodingFailed
            }

            // Prefer CryptoCore signing; fall back to raw Keychain key when core is not yet
            // initialized (e.g. CFE snapshot lost but device keys still in Keychain).
            let signingKeyBytes: [UInt8]
            do {
                signingKeyBytes = try CryptoManager.shared.exportSigningSecretKey()
            } catch {
                Log.info("[Auth] CryptoCore unavailable for signing — using raw Keychain key: \(error)", category: "Auth")
                signingKeyBytes = [UInt8](rawSigningKey)
            }
            let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(signingKeyBytes))
            let signatureData = try privateKey.signature(for: messageData)
            
            let response = try await AuthServiceClient.shared.authenticateDevice(
                    deviceId: deviceId,
                    timestamp: timestamp,
                    signature: signatureData
                )
            
            // Save tokens
            let expiresInSeconds: Int
            if let expiresAt = response.expiresAt {
                expiresInSeconds = max(Int(expiresAt - Int64(Date().timeIntervalSince1970)), 0)
            } else if let expiresIn = response.expiresIn {
                expiresInSeconds = expiresIn
            } else {
                expiresInSeconds = 3600
            }
            
            AuthSessionManager.shared.saveTokens(
                accessToken: response.accessToken,
                refreshToken: response.refreshToken,
                expiresIn: expiresInSeconds,
                userId: response.userId
            )
            
            VeilProxyManager.shared.configureFromServer(cert: response.iceBridgeCert ?? "")
            Log.info("Device-based authentication successful")
            finishAuth(userId: response.userId)
            
        } catch {
            Log.info("Device authentication failed: \(error)")

            // Only wipe device keys when the server explicitly rejects this device
            // (unauthenticated / permission-denied gRPC codes = device not registered).
            // Transient network errors, timeouts, or server outages must NOT delete keys —
            // that would permanently log out the user on a bad Wi-Fi reconnect.
            let description = "\(error)"
            let isDeviceRejected = description.contains("unauthenticated")
                || description.contains("permission_denied")
                || description.contains("UNAUTHENTICATED")
                || description.contains("PERMISSION_DENIED")
                || description.contains("error 16")   // gRPC UNAUTHENTICATED
                || description.contains("error 7")    // gRPC PERMISSION_DENIED

            if isDeviceRejected {
                // If we have a pending registration bundle, the keys were saved before
                // the registration RPC could complete. Show the registration screen so the
                // user can retry (the bundle + keys are already in Keychain / UserDefaults).
                let hasPendingBundle = PendingRegistrationStore.hasPendingBundle()
                await MainActor.run {
                    if hasPendingBundle {
                        Log.info("Device not registered yet — routing back to registration (pending bundle found)", category: "Auth")
                        // Keep keys; RegistrationFlowView will pick them up and retry.
                        hasRegisteredDeviceKeys = false
                    } else {
                        Log.error("🗑️ Server rejected device (401/403) — clearing keys to show onboarding", category: "Auth")
                        KeychainManager.shared.deleteDeviceKeys()
                        hasRegisteredDeviceKeys = false
                    }
                }
            } else {
                Log.error("Device auth failed (transient error) — keeping keys: \(error)", category: "Auth")
            }
        }
    }
    
    /// Legacy method - kept for backward compatibility
    func restoreSession() {
        Task { [weak self] in
            await self?.restoreOrAuthenticateDevice()
        }
    }

    // FIXED: Monitor token expiration (single scheduled refresh)
    private func startTokenRefreshMonitoring() {
        scheduleTokenRefresh()
    }

    private func scheduleTokenRefresh() {
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
    
    /// Refresh access token automatically
    private func refreshAccessToken() async {
        guard let refreshToken = AuthSessionManager.shared.refreshToken else {
            Log.error("No refresh token available - forcing logout", category: "Auth")
            await MainActor.run {
                handleSessionExpired()
            }
            return
        }
        
        do {
            Log.info("Attempting to refresh access token", category: "Auth")
            
            let response = try await AuthServiceClient.shared.refreshToken(refreshToken: refreshToken)
            
            // Save new tokens
            await MainActor.run {
                let expiresIn: Int
                if let expiresAt = response.expiresAt {
                    expiresIn = max(Int(expiresAt - Int64(Date().timeIntervalSince1970)), 0)
                } else {
                    expiresIn = response.expiresIn ?? 3600
                }
                AuthSessionManager.shared.saveTokens(
                    accessToken: response.accessToken,
                    refreshToken: response.refreshToken,
                    expiresIn: expiresIn
                )
                
                Log.info("Access token refreshed successfully (expires in: \(expiresIn / 60) min)", category: "Auth")
                self.scheduleTokenRefresh()
            }
            
        } catch {
            Log.error("Token refresh failed: \(error.localizedDescription)", category: "Auth")
            
            // If refresh fails, logout user
            await MainActor.run {
                handleSessionExpired()
            }
        }
    }


    func finalizeDeviceRegistration(userId: String, username: String?) {
        currentUserId = userId
        isAuthenticated = true
        scheduleTokenRefresh()
        loadUserFromCoreData(userId: userId, username: username)
    }

    /// Handles the critical case where the user is authenticated (has a session token) but
    /// device crypto keys couldn't be loaded from Keychain (partial state or iOS Keychain bug).
    ///
    /// We do NOT wipe keys automatically — they may be temporarily inaccessible (iOS beta bugs,
    /// device locked at launch, etc.). Instead we set `deviceKeysUnavailable` which routes to a
    /// dedicated recovery screen giving the user three options:
    ///   1. Retry — re-read Keychain (handles transient accessibility issues)
    ///   2. Recover with seed phrase — preserves userId, generates new device keys
    ///   3. Create new account — explicit user choice, then we wipe and re-register
    private func handleLostDeviceKeys(userId: String, reason: String) {
        Log.error("[Auth] Device keys unavailable — showing recovery screen. Reason: \(reason). userId: \(userId.prefix(8))", category: "Auth")
        // kSecAttrAccessibleWhenUnlockedThisDeviceOnly items are inaccessible when the
        // device is locked and the app is woken by a push notification. This is a transient
        // condition — the keys haven't been wiped; they just can't be read right now.
        // Skip the recovery screen in this case; restoreOrAuthenticateDevice() will be
        // retried when the user brings the app to the foreground.
        #if canImport(UIKit)
        guard UIApplication.shared.applicationState != .background else {
            Log.info("[Auth] Keys inaccessible in background (device locked) — deferring recovery to foreground", category: "Auth")
            return
        }
        #endif
        deviceKeysUnavailable = true
    }

    /// Called from KeysRecoveryView "Try Again" button — re-reads Keychain and attempts
    /// to recreate OrchestratorCore. Clears `deviceKeysUnavailable` on success.
    func retryLoadingDeviceKeys() {
        guard let userId = currentUserId else { return }
        CryptoManager.shared.setLocalUserId(userId)
        if CryptoManager.shared.isInitialized {
            Log.info("[Auth] Keys recovered on retry — core initialized", category: "Auth")
            deviceKeysUnavailable = false
        } else {
            Log.error("[Auth] Keys still unavailable on retry", category: "Auth")
        }
    }

    /// Called from KeysRecoveryView "Create New Account" button — explicit user action.
    /// Wipes ALL local crypto state so the user goes through fresh onboarding.
    /// Core Data (message history, contacts) is intentionally preserved.
    func wipeAndReregister() {
        Log.info("[Auth] User chose to wipe and re-register", category: "Auth")
        cancelTimeouts()
        AuthSessionManager.shared.clearSession()

        // Nullify in-memory cores before Keychain deletions so no stale reference survives.
        CryptoManager.shared.deleteAllCryptoKeys()

        // Delete device registration keys, OTPKs, and Kyber SPK — must come after
        // deleteAllCryptoKeys() so the orchestrator core is already nil.
        KeychainManager.shared.deleteDeviceKeys()
        KeychainManager.shared.deleteOtpks()
        KeychainManager.shared.deleteData(forKey: "construct.kyber.spk.public")
        KeychainManager.shared.deleteData(forKey: "construct.kyber.spk.secret")
        KeychainManager.shared.deleteData(forKey: "construct.kyber.spk.id")

        deviceKeysUnavailable = false
        isAuthenticated = false
        hasRegisteredDeviceKeys = false
        currentUserId = nil
        currentUser = nil
    }

    func logout() {
        Task { [weak self] in
            guard let self else { return }
            await SessionLifecycleController.shared.sendEndSessionToAllContacts(reason: "logout")
            Log.info("END_SESSION sent to all contacts on logout", category: "Auth")
            
            // 1. Logout via gRPC
            if AuthSessionManager.shared.sessionToken != nil {
                do {
                    try await AuthServiceClient.shared.logout()
                } catch {
                    Log.error("Logout API call failed: \(error.localizedDescription)", category: "Auth")
                    // Continue with local logout even if API call fails
                }
            }
            
            await MainActor.run {
                self.cancelTimeouts()
                AuthSessionManager.shared.clearSession()
                UserDefaults.standard.removeObject(forKey: "recovery_is_setup")
                UserDefaults.standard.removeObject(forKey: "recovery_banner_dismissed")
                KeychainManager.shared.deleteAllContactRequestMappings()
                UserDefaults.standard.removeObject(forKey: "cr_pending_nav_user_ids")

                // Note: We keep the username in Keychain for convenience on next login
                // If you want to clear it, uncomment the line below:
                // KeychainManager.shared.deleteLastUsername()

                self.isAuthenticated = false
                self.currentUserId = nil
                self.currentUser = nil  // REFACTOR Phase 1.2
            }
            await MediaSendCache.shared.clear()
        }
    }

    /// Signs out of ALL devices simultaneously (invalidates all refresh tokens server-side),
    /// then performs local logout. Use when a device may have been compromised.
    func logoutAllDevices() {
        Task { [weak self] in
            guard let self else { return }
            if AuthSessionManager.shared.sessionToken != nil {
                do {
                    try await AuthServiceClient.shared.logout(allDevices: true)
                    Log.info("Signed out of all devices", category: "Auth")
                } catch {
                    Log.error("logoutAllDevices API call failed: \(error.localizedDescription)", category: "Auth")
                }
            }
            await MainActor.run {
                self.cancelTimeouts()
                AuthSessionManager.shared.clearSession()
                UserDefaults.standard.removeObject(forKey: "recovery_is_setup")
                UserDefaults.standard.removeObject(forKey: "recovery_banner_dismissed")
                self.isAuthenticated = false
                self.currentUserId = nil
                self.currentUser = nil
            }
        }
    }
    
    func deleteAccount() {
        self.isLoading = true
        
        Log.info("Requesting account deletion", category: "AuthViewModel")
        
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.deleteAccountWithDeviceSignature()
                await MainActor.run { self.handleDeleteAccountSuccess() }
            } catch {
                Log.error("deleteAccount raw error: \(error)", category: "AuthViewModel")
                await MainActor.run {
                    self.cancelTimeouts()
                    self.isLoading = false
                    self.deleteAccountFailed = true
                    ErrorRouter.shared.report(.unknown(Self.friendlyDeleteError(error)))
                }
            }
        }
    }

    private static func friendlyDeleteError(_ error: Error) -> String {
        let desc = error.localizedDescription
        // Only hide real error for unimplemented (code 12) — server endpoint not ready yet
        if desc.contains("unimplemented") || desc == "GRPCCore.RPCError error 12" {
            return NSLocalizedString("delete_account_not_available", comment: "")
        }
        return String(format: NSLocalizedString("delete_account_failed", comment: ""), desc)
    }

    /// Deletes all local data without contacting the server.
    /// Used as a fallback when the server is unreachable (e.g. blocked by censorship).
    func deleteAccountLocally() {
        Log.info("Deleting account locally only (server unreachable)", category: "AuthViewModel")
        handleDeleteAccountSuccess()
    }

    /// Called when duress PIN is entered on the lock screen.
    /// Immediately wipes all local data; attempts server deletion best-effort in background.
    func triggerDuressWipe() {
        Log.info("Duress PIN triggered — initiating silent wipe", category: "AuthViewModel")
        Task { [weak self] in
            guard self != nil else { return }
            do {
                _ = try await UserServiceClient.shared.deleteAccount(
                    confirmation: "DELETE",
                    reason: "duress"
                )
            } catch {
                Log.error("Duress wipe: remote delete failed: \(error.localizedDescription)", category: "AuthViewModel")
            }
        }
        handleDeleteAccountSuccess()
    }

    private func deleteAccountWithDeviceSignature() async throws {
        let response = try await UserServiceClient.shared.deleteAccount(
            confirmation: "DELETE",
            reason: "user_requested"
        )
        guard response.success else {
            throw NSError(domain: "AuthViewModel", code: 3, userInfo: [NSLocalizedDescriptionKey: response.message])
        }
    }

    // MARK: - Timeout Helpers
    private func startAuthTimeout() {
        authOperationTimer?.invalidate()
        authOperationTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.handleTimeout()
            }
        }
    }
    
    private func startSessionRestoreTimeout() {
        sessionRestoreTimer?.invalidate()
        sessionRestoreTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.handleTimeout()
            }
        }
    }
    
    private func handleTimeout() {
        if self.isLoading && !self.isAuthenticated {
            self.isLoading = false
            ErrorRouter.shared.report(.network(.connectionFailed), recovery: { [weak self] in
                self?.restoreSession()
            })
            Log.info("Session restore timeout - showing login screen")
        }
    }

    private func cancelTimeouts() {
        authOperationTimer?.invalidate()
        authOperationTimer = nil
        sessionRestoreTimer?.invalidate()
        sessionRestoreTimer = nil
        tokenRefreshTimer?.invalidate()
        tokenRefreshTimer = nil
    }

    // MARK: - State Updaters
    // Using gRPC for all messaging
    private func handleAuthSuccess(userId: String, username: String, token: String, refreshToken: String, expires: Int64) {
        Log.info("Saving session tokens (access token length: \(token.count))", category: "Auth")
        
        // Calculate expiresIn from expiresAt timestamp
        let expiresDate = Date(timeIntervalSince1970: TimeInterval(expires))
        let expiresIn = Int(expiresDate.timeIntervalSinceNow)
        
        AuthSessionManager.shared.saveTokens(
            accessToken: token,
            refreshToken: refreshToken,
            expiresIn: max(expiresIn, 0),  // Don't clamp negative (already-expired) TTL to 1 hour
            userId: userId
        )
        
        if let savedToken = AuthSessionManager.shared.sessionToken {
            if savedToken == token {
                Log.info("Access token saved and verified correctly", category: "Auth")
            } else {
                Log.error("Token mismatch! Original length: \(token.count), Saved length: \(savedToken.count)", category: "Auth")
            }
        } else {
            Log.error("Token not found after saving!", category: "Auth")
        }
        
        if AuthSessionManager.shared.refreshToken != nil {
            Log.info("Refresh token saved successfully", category: "Auth")
        } else {
            Log.error("Refresh token not saved!", category: "Auth")
        }
        
        currentUserId = userId
        isAuthenticated = true
        scheduleTokenRefresh()
        CryptoManager.shared.setLocalUserId(userId)
        // Pass username parameter so it gets saved to Core Data
        loadUserFromCoreData(userId: userId, username: username)
        
        // Request push permission (first login) or ensure the token is on the server
        // (subsequent logins where permission is already granted). Both paths end with
        // the device token reliably registered in the backend DB.
        Task { [weak self] in
            guard self != nil else { return }
            #if canImport(UIKit)
            let granted = await PushNotificationManager.shared.requestPermission()
            if granted {
                Log.info("Push notifications enabled for user", category: "Auth")
            } else {
                Log.info("Push notifications declined by user", category: "Auth")
            }
            await PushNotificationManager.shared.ensureTokenRegistered()
            #endif
        }
        
        // Long polling will start automatically when sessionToken is published
    }

    private func handleConnectSuccess(userId: String, username: String) {
        Log.info("ConnectSuccess received!")
        Log.info("   User ID: \(userId)")
        Log.info("   Username: \(username)")

        currentUserId = userId
        isAuthenticated = true
        scheduleTokenRefresh()

        // Load User entity and set currentUser
        loadUserFromCoreData(userId: userId)
        Log.info("User authenticated successfully")
    }
    
    private func handleSessionExpired() {
        AuthSessionManager.shared.clearSession()
        self.isAuthenticated = false
        ErrorRouter.shared.report(.sessionExpired)
    }
    
    private func handleDeleteAccountSuccess() {
        Log.info("Account deletion successful", category: "AuthViewModel")
        cancelTimeouts()
        self.isLoading = false
        
        // Clear all user data
        AuthSessionManager.shared.clearSession()
        CryptoManager.shared.deleteAllCryptoKeys()
        KeychainManager.shared.deleteDeviceKeys()
        
        // Clear all UserDefaults keys
        let userDefaultsKeys: [String] = [
            "biometricEnabled",
            "pinLength",
            "is_discoverable",
            "recovery_is_setup",
            "recovery_banner_dismissed",
            UserDefaultsKey.veilEnabled.rawValue,
            UserDefaultsKey.veilMode.rawValue,
            UserDefaultsKey.trafficProtectionEnabled.rawValue,
            UserDefaultsKey.backgroundFetchEnabled.rawValue,
            UserDefaultsKey.backgroundFetchIntervalMinutes.rawValue,
            UserDefaultsKey.sessionExpires.rawValue,
            "construct.lastMessageId",
            "construct.spk.lastRotationTimestamp",
            "construct.spk.uploadTimestamp",
        ]
        userDefaultsKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        // Remove all construct.contact_request_seen.* keys
        UserDefaults.standard.dictionaryRepresentation().keys
            .filter { $0.hasPrefix("construct.contact_request_seen.") }
            .forEach { UserDefaults.standard.removeObject(forKey: $0) }
        
        // Clear CoreData - delete all user's data
        let context = viewContext
        
        guard context.persistentStoreCoordinator != nil else {
            Log.info("Core Data persistent store coordinator not ready, skipping data deletion", category: "AuthViewModel")
            isAuthenticated = false
            currentUserId = nil
            currentUser = nil
            hasRegisteredDeviceKeys = false
            return
        }
        
        // Delete all entities using batch delete for efficiency
        let entityNames = ["Message", "HealingMessage", "ProcessedMessage", "CallRecord", "Chat", "User"]
        for entityName in entityNames {
            let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: entityName)
            let batchDelete = NSBatchDeleteRequest(fetchRequest: fetchRequest)
            batchDelete.resultType = .resultTypeObjectIDs
            do {
                let result = try context.execute(batchDelete) as? NSBatchDeleteResult
                if let objectIDs = result?.result as? [NSManagedObjectID], !objectIDs.isEmpty {
                    NSManagedObjectContext.mergeChanges(
                        fromRemoteContextSave: [NSDeletedObjectsKey: objectIDs],
                        into: [context]
                    )
                }
            } catch {
                Log.error("Failed to delete \(entityName) from CoreData: \(error)", category: "AuthViewModel")
            }
        }
        Log.info("All user data deleted from CoreData", category: "AuthViewModel")

        // Reset auth state
        isAuthenticated = false
        currentUserId = nil
        currentUser = nil
        hasRegisteredDeviceKeys = false

        Log.info("Account deletion complete - user logged out", category: "AuthViewModel")
    }
    
    // MARK: - Core Data Integration
    
    /// Finds or creates the User entity and loads local data into the AuthViewModel
    /// - Parameters:
    ///   - userId: The user ID to load data for
    ///   - username: Optional username to update/set (from login response)
    private func loadUserFromCoreData(userId: String, username: String? = nil) {
        // Check if persistent store coordinator is ready before accessing entities
        guard viewContext.persistentStoreCoordinator != nil else {
            Log.info("Core Data persistent store coordinator not ready yet, skipping user load")
            return
        }
        
        // No more multi-account filtering
        let fetchRequest = User.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", userId)
        
        Log.info("loadUserFromCoreData: Searching for userId: \(userId)")
        if let username = username {
            Log.info("   Username from parameter: \(username)")
        }
        
        do {
            let user: User
            var needsSave = false
            
            if let existingUser = try viewContext.fetch(fetchRequest).first {
                user = existingUser
                Log.info("Found existing user in Core Data: \(user.displayName)")
                
                // Update username if provided and different
                if let newUsername = username, !newUsername.isEmpty {
                    if user.username.isEmpty || user.username != newUsername {
                        Log.info("Updating username: '\(user.username)' -> '\(newUsername)'")
                        let oldUsername = user.username
                        user.username = newUsername
                        // Also update displayName if it's empty or was same as old username
                        if user.displayName.isEmpty || user.displayName == oldUsername {
                            user.displayName = newUsername
                        }
                        needsSave = true
                    }
                }
            } else {
                Log.info("No user found, creating new user...")
                // First login on this device, create a new User entity
                user = User(context: viewContext)
                user.id = userId
                user.username = username ?? ""
                user.displayName = username ?? ""
                user.isSharingWithMe = false
                user.isBlocked = false
                user.amISharingWith = false
                needsSave = true
                Log.info("Created new user in Core Data for ID: \(userId)")
                Log.info("   username: \(user.username)")
            }
            
            // Save if needed
            if needsSave {
                try viewContext.save()
                Log.info("Saved user changes to Core Data")
            }
            
            // Set currentUser - single source of truth!
            self.currentUserId = user.id
            self.currentUser = user
            CryptoManager.shared.setLocalUserId(user.id)
            AuthSessionManager.shared.saveDisplayName(user.displayName.isEmpty ? (user.username.isEmpty ? "" : user.username) : user.displayName)
            
            Log.info("Restored user data from Core Data:")
            Log.info("   userId: \(user.id)")
            Log.info("   username: \(user.username)")
            Log.info("   displayName: \(user.displayName)")
            
        } catch {
            Log.info("Failed to fetch or create user from Core Data: \(error)")
        }
    }
}

// MARK: - Preview Helpers

#if DEBUG
extension AuthViewModel {
    /// Creates a mock User for SwiftUI previews
    static func createMockUser(context: NSManagedObjectContext, username: String = "john_doe", displayName: String = "John Doe") -> User {
        let user = User(context: context)
        user.id = UUID().uuidString
        user.username = username
        user.displayName = displayName
        return user
    }
    
    /// Configures AuthViewModel for previews with mock data
    func configureMockAuth(username: String = "john_doe", displayName: String = "John Doe") {
        self.isAuthenticated = true
        self.currentUserId = UUID().uuidString
        self.currentUser = AuthViewModel.createMockUser(context: viewContext, username: username, displayName: displayName)
    }
}
#endif
