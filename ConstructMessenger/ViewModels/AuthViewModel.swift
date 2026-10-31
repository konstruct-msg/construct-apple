//
//  AuthViewModel.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import Foundation
import CoreData
import CryptoKit
import GRPCCore
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

    /// True when the server deterministically rejected this device as unregistered
    /// (gRPC UNAUTHENTICATED / "device not found"). The crypto keys are still present
    /// locally, so we do NOT wipe them — instead we route to the recovery screen and let
    /// the user retry (transient server hiccup), recover with a seed phrase, or start fresh.
    /// Replaces the old silent destructive wipe on device rejection.
    var deviceDeregistered = false

    /// True while RegistrationFlowView is active. Prevents restoreOrAuthenticateDevice()
    /// from interfering with an ongoing registration (the stream's UNAUTHENTICATED errors
    /// would otherwise trigger auth re-attempts every few seconds).
    var isRegistrationInProgress = false

    /// Drives post-link history sync UI (receive on desktop, send on phone).
    var deviceLinkPhase: DeviceLinkPhase = .idle

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
    
    /// Our own profile, read when asked. It is written in several places (settings, profile
    /// sharing, this model's login) and a copy held here would go stale after the first of them;
    /// the managed `User` this replaces stayed current by being refreshed under us.
    var currentUser: OwnProfileRecord? {
        #if DEBUG
        if let previewProfile { return previewProfile }
        #endif
        guard let currentUserId else { return nil }
        return try? LocalRepositories.ownProfile.profile(accountId: currentUserId)
    }
    #if DEBUG
    private var previewProfile: OwnProfileRecord?
    #endif
    
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
    var tokenRefreshTimer: Timer?

    private var restoreInFlight = false
    private var lastRestoreAttemptAt: Date?

    init(context: NSManagedObjectContext, startRuntime: Bool? = nil) {
        self.viewContext = context
        let shouldStartRuntime = startRuntime ?? !PreviewDetector.isRunningInPreview
        guard shouldStartRuntime else {
            refreshDeviceKeyState()
            return
        }
        beginRuntime()
    }

    private var runtimeStarted = false

    /// The runtime of a model created with `startRuntime: false` — on iOS once the store import
    /// at launch has finished (`StoreImportView`): nothing may write to Core Data while it copies.
    /// Idempotent.
    func startDeferredRuntime() {
        beginRuntime()
    }

    private func beginRuntime() {
        guard !runtimeStarted else { return }
        runtimeStarted = true
        // Back to Splash while the session restores, as on a launch that started it at once.
        hasRegisteredDeviceKeys = nil
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

    func finishAuthenticatedSession(userId: String, reason: String) {
        // Upgrade path, and it is load-bearing: every device installed before the ownership
        // marker existed has unlabelled data plus a valid identity. Claiming here — while
        // that identity is still authenticated and long before registration is reachable —
        // is what stops `LocalStoreOwnership` from wiping the history of every user who
        // updates. Removing this line does not fail a build; it deletes people's chats.
        if LocalStoreOwnership.claimIfUnowned(userId) {
            Log.info("Local store claimed by \(userId.prefix(8))… (first run after upgrade)", category: "Auth")
        } else {
            enforceLocalStoreOwnership(for: userId)
        }

        currentUserId = userId
        isAuthenticated = true
        deviceDeregistered = false
        scheduleTokenRefresh()
        CryptoManager.shared.setLocalUserId(userId)
        loadUserFromCoreData(userId: userId)
        runPostAuthMaintenance(userId: userId, reason: reason)
        // The link copies the username once. A fetch that failed, or a Desktop that was linked
        // before the name was set, would otherwise show an empty profile forever: nothing else
        // asks the server again. The name and the photo are not on the server; our other device
        // sends those.
        Task { await refreshOwnUsernameFromServer() }
    }


    // MARK: - Session Management
    
    /// Restore existing session OR authenticate with device keys
    func restoreOrAuthenticateDevice() async {
        // Registration or a join request is in progress — don't interfere. The stream's
        // UNAUTHENTICATED errors would otherwise fire repeated re-auth attempts every few seconds,
        // and a join request's keys read as "Device not found" until the phone approves them.
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

        // One-time: migrate crypto key material to AfterFirstUnlock accessibility so a
        // push-driven decrypt while the device is locked can read the keys and build
        // OrchestratorCore (otherwise → coreNotInitialized → spurious END_SESSION/desync).
        // Self-guards: a locked read is a no-op and retries on the next foreground launch.
        KeychainManager.shared.migrateCryptoKeysAccessibility()

        // Step 1: Try to restore existing session token
        AuthSessionManager.shared.loadSessionToken()

        // Helper: recover userId from the session token when the Keychain entry is missing.
        // The server puts the user ID in the `sub` claim of every token it issues.
        // Only touches userId — does NOT re-save tokens or overwrite session expiry.
        func recoverUserIdFromToken() -> String? {
            guard let token = AuthSessionManager.shared.sessionToken,
                  let uid = TokenUtils.extractUserId(from: token),
                  !uid.isEmpty else { return nil }
            AuthSessionManager.shared.updateUserId(uid)
            Log.info("[Auth] userId recovered from the token's sub claim and re-saved to Keychain: \(uid.prefix(8))...", category: "Auth")
            return uid
        }

        // Resolve userId — prefer in-memory/Keychain, fall back to the token's `sub`.
        func resolvedUserId() -> String? {
            if let uid = AuthSessionManager.shared.currentUserId { return uid }
            return recoverUserIdFromToken()
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
                    finishAuthenticatedSession(userId: userId, reason: "session_restore")
                } else {
                    handleLostDeviceKeys(userId: userId, reason: "keys missing after session token restore")
                }
                return
            }
            finishAuthenticatedSession(userId: userId, reason: "session_restore")
            return
        }

        // Step 1.5: Token exists but is expired/near-expired — refresh using refresh token first.
        // This is faster and less error-prone than full device auth, and keeps the gRPC stream stable.
        if AuthSessionManager.shared.sessionToken != nil,
           let userId = resolvedUserId(),
           AuthSessionManager.shared.refreshToken != nil {
            do {
                Log.info("Session token expired — attempting refresh (via coordinator)", category: "Auth")
                // Route through the single-flight coordinator instead of calling refreshToken
                // directly. At launch several components hit .unauthenticated at once; a direct
                // call here raced the coordinator on the same stored refresh token, one side got
                // "already used / revoked", and the rejection wiped the freshly-rotated good
                // tokens. Sharing the coordinator's in-flight task makes every caller observe the
                // same outcome and use the same rotated token. The coordinator persists the new
                // access+refresh+expiry on success.
                let refreshed = try await TokenRefreshCoordinator.shared.refreshIfPossible()
                guard refreshed else {
                    Log.info("Coordinator refresh did not yield a valid session — falling back to device auth", category: "Auth")
                    throw NetworkError.connectionFailed
                }
                // saveTokens(userId:) inside the coordinator is called with nil userId (refresh
                // doesn't change identity); ensure the resolved userId is persisted/in-memory.
                AuthSessionManager.shared.updateUserId(userId)

                if !CryptoManager.shared.isInitialized {
                    self.currentUserId = userId
                    self.isAuthenticated = true
                    scheduleTokenRefresh()
                    CryptoManager.shared.setLocalUserId(userId)
                    if CryptoManager.shared.isInitialized {
                        finishAuthenticatedSession(userId: userId, reason: "token_refresh")
                    } else {
                        handleLostDeviceKeys(userId: userId, reason: "keys missing after token refresh")
                    }
                    return
                }
                finishAuthenticatedSession(userId: userId, reason: "token_refresh")
                Log.info("Session refreshed successfully", category: "Auth")
                return
            } catch {
                Log.error("Session refresh failed, falling back to device auth: \(error)", category: "Auth")
            }
        }
        
        // Step 2: No session token — device-based auth via single-flight coordinator
        // (shared with gRPC auth-retry / MessageStream so push/VoIP join the same mint).
        Log.info("Attempting device-based authentication (via DeviceAuthCoordinator)", category: "Auth")
        let outcome = await DeviceAuthCoordinator.shared.authenticateIfPossible()
        switch outcome {
        case .success(let userId):
            Log.info("Device-based authentication successful", category: "Auth")
            finishAuthenticatedSession(userId: userId, reason: "device_auth")
        case .noDeviceKeys:
            Log.info("No device keys found - user needs to register")
            hasRegisteredDeviceKeys = false
        case .keysUnreadable(let detail):
            // The identity is probably still on this device — the Keychain just would not hand
            // it over (locked before first unlock, protected data unavailable). Routing to
            // onboarding here is how an account resets itself: see the 2026-08-09 incident and
            // `DeviceKeyAvailability`. Send it to the same recovery screen the token-refresh
            // path has always used.
            handleLostDeviceKeys(userId: currentUserId ?? "", reason: "device auth: \(detail)")
        case .failed(let description, let overDirectTLS, let refusal):
            Log.info("Device authentication failed: \(description)", category: "Auth")

            // Only wipe device keys when the server explicitly rejects this device
            // (unauthenticated / permission-denied gRPC codes = device not registered).
            // Transient network errors, timeouts, or server outages must NOT delete keys —
            // that would permanently log out the user on a bad Wi-Fi reconnect.
            let lower = description.lowercased()
            let isDeviceRejected = description.contains("unauthenticated")
                || description.contains("permission_denied")
                || description.contains("UNAUTHENTICATED")
                || description.contains("PERMISSION_DENIED")
                || description.contains("error 16")   // gRPC UNAUTHENTICATED
                || description.contains("error 7")    // gRPC PERMISSION_DENIED
                || lower.contains("device is inactive")
                || lower.contains("device inactive")
                || lower.contains("device not found")

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
                    } else if Self.isRemovedDevice(refusal, overDirectTLS: overDirectTLS) {
                        // Another device of the account removed this one, or it signed out
                        // elsewhere: the server deactivates the row and never reactivates it.
                        // Everything the account left here goes (`LocalDataWipe`).
                        Log.error("Server says this device was removed — wiping it", category: "Auth")
                        performLocalSignOut()
                        ErrorRouter.shared.presentNotice(
                            NSLocalizedString("device_removed_notice", comment: ""),
                            autoDismissAfter: 10
                        )
                    } else {
                        // Server says this device is unregistered, but we still hold valid
                        // crypto keys. Do NOT wipe — a wipe would silently destroy the identity
                        // (and orphan the account if recovery isn't set up) on what might be a
                        // transient server error. Route to the recovery screen: the user can
                        // retry, recover via seed phrase (preserves userId), or start fresh.
                        Log.error("Server rejected device as unregistered — routing to recovery (keys preserved)", category: "Auth")
                        deviceDeregistered = true
                    }
                }
            } else {
                Log.error("Device auth failed (transient error) — keeping keys: \(description)", category: "Auth")
            }
        }
    }
    
    /// The server's answer for a device whose row it deactivated — `RevokeDevice`, or `Logout` from
    /// this device's own session elsewhere — and nothing else. Deactivation is permanent, so this is
    /// the one rejection that may wipe. `.notFound` is not it: an unapproved join request answers
    /// that too, and so would a server that lost its rows.
    ///
    /// The number, never the status text (`DeviceRefusalReading`). A server older than the number
    /// sends none, and then nothing wipes — the safe side of the two.
    ///
    /// Only over a direct TLS connection to our server. Through VEIL the client speaks plaintext
    /// gRPC to the relay, and a relay able to forge this answer would be able to erase the device.
    /// A removed device reached only through VEIL keeps its data until it connects directly.
    nonisolated static func isRemovedDevice(
        _ refusal: Shared_Proto_Services_V1_DeviceRefusal, overDirectTLS: Bool
    ) -> Bool {
        overDirectTLS && refusal == .removed
    }

    /// Legacy method - kept for backward compatibility
    func restoreSession() {
        Task { [weak self] in
            await self?.restoreOrAuthenticateDevice()
        }
    }



    func finalizeDeviceRegistration(userId: String, username: String?) {
        // Before this identity is shown anything: the store may still hold the previous one's
        // contacts and transcripts. On 2026-08-09 a freshly registered account came up with
        // twelve inherited contacts. Registration is the one moment a *different* identity
        // takes over a device, so the gate belongs here.
        enforceLocalStoreOwnership(for: userId)
        // The same moment for the address: a new account has no recovery key yet, and one left
        // from an account this device used to be went into every invite (the server refused them:
        // "address does not match the account's recovery key") and told the provisioner the key
        // already existed (2026-10-21).
        KeychainManager.shared.deleteOwnAccountAddress()

        currentUserId = userId
        isAuthenticated = true
        hasRegisteredDeviceKeys = true
        // New identity: ensure orientation is not skipped due to a previous identity
        // that already finished the guide on this device (per-user store handles this;
        // no global reset needed — new userId is simply absent from the completed set).
        scheduleTokenRefresh()
        loadUserFromCoreData(userId: userId, username: username)
        Log.info(
            "Registration finalized userId=\(userId.prefix(8))… orientationPending=\(!OrientationStore.isCompleted(for: userId, rawList: UserDefaults.standard.string(forKey: OrientationStore.completedUserIdsKey) ?? ""))",
            category: "Auth"
        )
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

    /// Called from KeysRecoveryView "Try Again" button in the `.deviceDeregistered` mode —
    /// re-attempts device authentication (the rejection may have been a transient server
    /// error). Clears `deviceDeregistered` on success via finishAuthenticatedSession().
    func retryDeviceAuthentication() {
        Task { [weak self] in
            await self?.restoreOrAuthenticateDevice()
        }
    }

    /// Called from KeysRecoveryView "Create New Account" button — explicit user action.
    /// Wipes ALL local crypto state so the user goes through fresh onboarding.
    /// Core Data (message history, contacts) is intentionally preserved.
    func wipeAndReregister() {
        Log.info("[Auth] User chose to wipe and re-register", category: "Auth")
        cancelTimeouts()
        AuthSessionManager.shared.clearSession()
        StealthSenderService.shared.clearCertCache()   // drop the old identity's sealed-sender cert

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
        deviceDeregistered = false
        isAuthenticated = false
        hasRegisteredDeviceKeys = false
        currentUserId = nil
        OrientationStore.reset()
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

    func cancelTimeouts() {
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
        // Restore / device-link reach a session the same way registration does, and a
        // device that got here through a voucher is on a 45-minute B2. The capability
        // pipeline is JWT-gated, so this is the first moment it can do anything.
        VeilProxyManager.shared.ensureCapabilitiesForActiveRelay()

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
        Log.info("   Username: \(Log.presence(username))")

        currentUserId = userId
        isAuthenticated = true
        scheduleTokenRefresh()

        // Load User entity and set currentUser
        loadUserFromCoreData(userId: userId)
        Log.info("User authenticated successfully")
    }
    
    func handleDeleteAccountSuccess() {
        Log.info("Account deletion successful", category: "AuthViewModel")
        cancelTimeouts()
        self.isLoading = false
        
        // Clear all user data
        AuthSessionManager.shared.clearSession()
        StealthSenderService.shared.clearCertCache()   // drop the old identity's sealed-sender cert
        CryptoManager.shared.deleteAllCryptoKeys()
        KeychainManager.shared.deleteDeviceKeys()
        KeychainManager.shared.deleteOtpks()

        // Rows, files, defaults — `LocalDataWipe`. It replaces the batch delete that stood here,
        // which left the deleted rows' bytes in the SQLite file and never touched media.
        LocalDataWipe.run(reason: "account_deleted")

        // Reset auth state
        isAuthenticated = false
        currentUserId = nil
        hasRegisteredDeviceKeys = false

        // The store is now empty and unowned. Leaving the old owner recorded would make the
        // next identity's gate compare against a ghost.
        UserDefaults.standard.removeObject(forKey: LocalStoreOwnership.ownerKey)

        Log.info("Account deletion complete - user logged out", category: "AuthViewModel")
    }
    
    // MARK: - Core Data Integration
    
    /// Finds or creates the User entity and loads local data into the AuthViewModel
    /// - Parameters:
    ///   - userId: The user ID to load data for
    ///   - username: Optional username to update/set (from login response)
    func loadUserFromCoreData(userId: String, username: String? = nil) {
        // Check if persistent store coordinator is ready before accessing entities
        guard viewContext.persistentStoreCoordinator != nil else {
            Log.info("Core Data persistent store coordinator not ready yet, skipping user load")
            return
        }
        
        Log.info("loadUserFromCoreData: Searching for userId: \(userId)")
        if username != nil {
            Log.info("   Username from parameter: set")
        }

        do {
            let profiles = LocalRepositories.ownProfile
            if var me = try profiles.profile(accountId: userId) {
                Log.info("Found existing user in Core Data")
                if let newUsername = username, let filled = me.fillingUsername(from: newUsername) {
                    Log.info("Updating username")
                    me = filled
                    try profiles.save(me)
                    NotificationCenter.default.post(name: .ownProfileDidChange, object: nil)
                    Log.info("Saved user changes to Core Data")
                }
            } else {
                Log.info("No user found, creating new user...")
                // First login on this device: our row.
                try profiles.save(OwnProfileRecord(
                    accountId: userId, username: username ?? "", displayName: username ?? "",
                    avatar: nil, profileEditedAtMs: 0
                ))
                Log.info("Created new user in Core Data for ID: \(userId)")
                Log.info("   username: \(Log.presence(username))")
            }
            guard let user = try profiles.profile(accountId: userId) else {
                throw NSError(domain: "AuthViewModel", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "own profile \(userId.prefix(8))… not written"])
            }

            self.currentUserId = user.accountId
            CryptoManager.shared.setLocalUserId(user.accountId)
            AuthSessionManager.shared.saveDisplayName(user.displayName.isEmpty ? (user.username.isEmpty ? "" : user.username) : user.displayName)
            
            Log.info("Restored user data from Core Data:")
            Log.info("   userId: \(user.accountId)")
            Log.info("   username: \(Log.presence(user.username)), displayName: \(Log.presence(user.displayName))")
            
        } catch {
            Log.info("Failed to fetch or create user from Core Data: \(error)")
        }
    }

    /// The username lives on the account server. Asked again whenever a session starts, and when
    /// settings open: the one copy at link time is how a Desktop ended up with the field empty
    /// after the phone had set it. Does not publish a profile version — see `fillingUsername`.
    func refreshOwnUsernameFromServer() async {
        guard let userId = currentUserId else { return }
        do {
            let remote = try await UserServiceClient.shared.getUserProfile(userId: userId)
            let username = remote.username.isEmpty ? nil : remote.username
            loadUserFromCoreData(userId: userId, username: username)
        } catch {
            Log.debug("Own username refresh failed (non-fatal): \(error)", category: "Auth")
        }
    }
}

// MARK: - Preview Helpers

#if DEBUG
extension AuthViewModel {
    static func makePreview(
        context: NSManagedObjectContext,
        username: String = "john_doe",
        displayName: String = "John Doe"
    ) -> AuthViewModel {
        let viewModel = AuthViewModel(context: context, startRuntime: false)
        viewModel.configureMockAuth(username: username, displayName: displayName)
        return viewModel
    }
    
    /// Configures AuthViewModel for previews with mock data
    func configureMockAuth(username: String = "john_doe", displayName: String = "John Doe") {
        self.isAuthenticated = true
        let id = UUID().uuidString
        self.currentUserId = id
        self.hasRegisteredDeviceKeys = true
        self.previewProfile = OwnProfileRecord(
            accountId: id, username: username, displayName: displayName, avatar: nil, profileEditedAtMs: 0
        )
    }
}
#endif
