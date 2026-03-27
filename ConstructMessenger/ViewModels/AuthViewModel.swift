//
//  AuthViewModel.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import Foundation
import CoreData
import CryptoKit

@MainActor
@Observable
class AuthViewModel {
    var isAuthenticated = false
    var currentUserId: String?

    /// Tracks whether device keys are registered in Keychain (drives ContentView routing)
    var hasRegisteredDeviceKeys: Bool? = nil

    func refreshDeviceKeyState() {
        hasRegisteredDeviceKeys = KeychainManager.shared.isDeviceRegistered()
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
        startTokenRefreshMonitoring()  // ✅ Monitor token expiration
        setupSessionExpiredListener()  // Subscribe to session invalidation
        refreshDeviceKeyState()        // Sync Keychain state into @Published
        
        // ✅ Device-based auth: Try to restore session OR authenticate with device keys
        Task {
            await restoreOrAuthenticateDevice()
        }
    }
    
    // Subscribe to session invalidation from SessionManager
    private func setupSessionExpiredListener() {
        sessionExpiredTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = SessionManager.shared.isSessionInvalidated
                    } onChange: {
                        continuation.resume()
                    }
                }
                guard !Task.isCancelled else { break }
                if SessionManager.shared.isSessionInvalidated {
                    SessionManager.shared.resetSessionInvalidated()
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
                        _ = SessionManager.shared.sessionToken
                        _ = SessionManager.shared.sessionExpires
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
        // Coalesce repeated calls (scenePhase, permission prompts, etc.)
        if restoreInFlight { return }
        if let last = lastRestoreAttemptAt, Date().timeIntervalSince(last) < 2 {
            return
        }
        lastRestoreAttemptAt = Date()
        restoreInFlight = true
        defer { restoreInFlight = false }

        print("🔄 restoreOrAuthenticateDevice() called")
        
        // Step 1: Try to restore existing session token
        SessionManager.shared.loadSessionToken()
        
        if let _ = SessionManager.shared.sessionToken,
           let userId = SessionManager.shared.currentUserId,
           SessionManager.shared.isSessionValid {
            // We have session token - verify it's still valid
            print("✅ Found session token for user: \(userId)")
            self.currentUserId = userId
            self.isAuthenticated = true
            scheduleTokenRefresh()
            CryptoManager.shared.setLocalUserId(userId)
            loadUserFromCoreData(userId: userId)
            return
        }

        // Step 1.5: Token exists but is expired/near-expired — refresh using refresh token first.
        // This is faster and less error-prone than full device auth, and keeps the gRPC stream stable.
        if SessionManager.shared.sessionToken != nil,
           let userId = SessionManager.shared.currentUserId,
           let refresh = SessionManager.shared.refreshToken {
            do {
                Log.info("🔄 Session token expired — attempting refresh", category: "Auth")
                let response = try await AuthServiceClient.shared.refreshToken(refreshToken: refresh)

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

                self.currentUserId = userId
                self.isAuthenticated = true
                scheduleTokenRefresh()
                CryptoManager.shared.setLocalUserId(userId)
                loadUserFromCoreData(userId: userId)
                Log.info("✅ Session refreshed successfully", category: "Auth")
                return
            } catch {
                Log.error("❌ Session refresh failed, falling back to device auth: \(error)", category: "Auth")
            }
        }
        
        // Step 2: No session token - try device-based auth
        guard let deviceId = KeychainManager.shared.loadDeviceID(),
              let _ = KeychainManager.shared.loadDeviceSigningKey() else {
            print("❌ No device keys found - user needs to register")
            return
        }
        
        print("🔑 Device keys found - authenticating with device ID: \(deviceId)")
        
        do {
            // Create signature: Sign("KonstruktAuth-v1\n{device_id}\n{timestamp}") with Ed25519
            let timestamp = Int64(Date().timeIntervalSince1970)
            let message = "KonstruktAuth-v1\n\(deviceId)\n\(timestamp)"
            guard let messageData = message.data(using: .utf8) else {
                throw NetworkError.encodingFailed
            }

            let signingKeyBytes = try CryptoManager.shared.exportSigningSecretKey()
            let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(signingKeyBytes))
            let signatureData = try privateKey.signature(for: messageData)
            let signature = signatureData.base64EncodedString()
            
            let response = try await AuthServiceClient.shared.authenticateDevice(
                    deviceId: deviceId,
                    timestamp: timestamp,
                    signature: signature
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
            
            SessionManager.shared.saveTokens(
                accessToken: response.accessToken,
                refreshToken: response.refreshToken,
                expiresIn: expiresInSeconds,
                userId: response.userId
            )
            
            self.currentUserId = response.userId
            self.isAuthenticated = true
            scheduleTokenRefresh()
            CryptoManager.shared.setLocalUserId(response.userId)
            IceProxyManager.shared.configureFromServer(cert: response.iceBridgeCert ?? "")
            print("✅ Device-based authentication successful")
            
            // Load user from Core Data
            loadUserFromCoreData(userId: response.userId)
            
        } catch {
            print("❌ Device authentication failed: \(error)")
            
            // ✅ If device auth fails (401 = device not registered on server)
            // Clear device keys so user sees OnboardingView
            await MainActor.run {
                Log.error("🗑️ Device auth failed - clearing device keys to show onboarding", category: "Auth")
                KeychainManager.shared.deleteDeviceKeys()
                hasRegisteredDeviceKeys = false
            }
        }
    }
    
    /// Legacy method - kept for backward compatibility
    func restoreSession() {
        Task {
            await restoreOrAuthenticateDevice()
        }
    }

    // ✅ FIXED: Monitor token expiration (single scheduled refresh)
    private func startTokenRefreshMonitoring() {
        scheduleTokenRefresh()
    }

    private func scheduleTokenRefresh() {
        tokenRefreshTimer?.invalidate()

        guard isAuthenticated else { return }
        guard let expiresAt = SessionManager.shared.sessionExpires else { return }

        let now = Date()
        let refreshTime = expiresAt.addingTimeInterval(-300) // refresh 5 minutes early
        let interval = max(refreshTime.timeIntervalSince(now), 5)

        tokenRefreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                Log.info("⚠️ Token refresh timer fired", category: "Auth")
                await self?.refreshAccessToken()
            }
        }
    }
    
    /// Refresh access token automatically
    private func refreshAccessToken() async {
        guard let refreshToken = SessionManager.shared.refreshToken else {
            Log.error("❌ No refresh token available - forcing logout", category: "Auth")
            await MainActor.run {
                handleSessionExpired()
            }
            return
        }
        
        do {
            Log.info("🔄 Attempting to refresh access token", category: "Auth")
            
            let response = try await AuthServiceClient.shared.refreshToken(refreshToken: refreshToken)
            
            // Save new tokens
            await MainActor.run {
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
                
                Log.info("✅ Access token refreshed successfully (expires in: \(expiresIn / 60) min)", category: "Auth")
                self.scheduleTokenRefresh()
            }
            
        } catch {
            Log.error("❌ Token refresh failed: \(error.localizedDescription)", category: "Auth")
            
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

    func logout() {
        Task {
            // 0. Send END_SESSION to all contacts
            await SessionCoordinator().sendEndSessionToAllContacts(reason: "logout")
            Log.info("✅ END_SESSION sent to all contacts on logout", category: "Auth")
            
            // 1. Logout via gRPC
            if SessionManager.shared.sessionToken != nil {
                do {
                    try await AuthServiceClient.shared.logout()
                } catch {
                    Log.error("Logout API call failed: \(error.localizedDescription)", category: "Auth")
                    // Continue with local logout even if API call fails
                }
            }
            
            await MainActor.run {
                cancelTimeouts()
                SessionManager.shared.clearSession()
                UserDefaults.standard.removeObject(forKey: "recovery_is_setup")
                UserDefaults.standard.removeObject(forKey: "recovery_banner_dismissed")
                
                // Note: We keep the username in Keychain for convenience on next login
                // If you want to clear it, uncomment the line below:
                // KeychainManager.shared.deleteLastUsername()
                
                isAuthenticated = false
                currentUserId = nil
                currentUser = nil  // ✅ REFACTOR Phase 1.2
            }
        }
    }

    /// Signs out of ALL devices simultaneously (invalidates all refresh tokens server-side),
    /// then performs local logout. Use when a device may have been compromised.
    func logoutAllDevices() {
        Task {
            await SessionCoordinator().sendEndSessionToAllContacts(reason: "logout")
            if SessionManager.shared.sessionToken != nil {
                do {
                    try await AuthServiceClient.shared.logout(allDevices: true)
                    Log.info("✅ Signed out of all devices", category: "Auth")
                } catch {
                    Log.error("logoutAllDevices API call failed: \(error.localizedDescription)", category: "Auth")
                }
            }
            await MainActor.run {
                cancelTimeouts()
                SessionManager.shared.clearSession()
                UserDefaults.standard.removeObject(forKey: "recovery_is_setup")
                UserDefaults.standard.removeObject(forKey: "recovery_banner_dismissed")
                isAuthenticated = false
                currentUserId = nil
                currentUser = nil
            }
        }
    }
    
    func deleteAccount() {
        self.isLoading = true
        
        Log.info("🗑️ Requesting account deletion", category: "AuthViewModel")
        
        Task {
            do {
                try await deleteAccountWithDeviceSignature()
                await MainActor.run { handleDeleteAccountSuccess() }
            } catch {
                Log.error("🗑️ deleteAccount raw error: \(error)", category: "AuthViewModel")
                await MainActor.run {
                    cancelTimeouts()
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
        Log.info("🗑️ Deleting account locally only (server unreachable)", category: "AuthViewModel")
        handleDeleteAccountSuccess()
    }

    /// Called when duress PIN is entered on the lock screen.
    /// Immediately wipes all local data; attempts server deletion best-effort in background.
    func triggerDuressWipe() {
        Log.info("🚨 Duress PIN triggered — initiating silent wipe", category: "AuthViewModel")
        Task {
            _ = try? await UserServiceClient.shared.deleteAccount(
                confirmation: "DELETE",
                reason: "duress"
            )
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
            print("⏱️ Session restore timeout - showing login screen")
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
    // ✅ Using gRPC for all messaging (WebSocket removed)
    private func handleAuthSuccess(userId: String, username: String, token: String, refreshToken: String, expires: Int64) {
        // ✅ DEBUG: Log token before saving
        Log.info("💾 Saving session tokens (access token length: \(token.count))", category: "Auth")
        
        // ✅ NEW: Use saveTokens() method with expiresIn
        // Calculate expiresIn from expiresAt timestamp
        let expiresDate = Date(timeIntervalSince1970: TimeInterval(expires))
        let expiresIn = Int(expiresDate.timeIntervalSinceNow)
        
        SessionManager.shared.saveTokens(
            accessToken: token,
            refreshToken: refreshToken,
            expiresIn: max(expiresIn, 0),  // Don't clamp negative (already-expired) TTL to 1 hour
            userId: userId
        )
        
        // ✅ DEBUG: Verify token was saved correctly
        if let savedToken = SessionManager.shared.sessionToken {
            if savedToken == token {
                Log.info("✅ Access token saved and verified correctly", category: "Auth")
            } else {
                Log.error("❌ Token mismatch! Original length: \(token.count), Saved length: \(savedToken.count)", category: "Auth")
            }
        } else {
            Log.error("❌ Token not found after saving!", category: "Auth")
        }
        
        if SessionManager.shared.refreshToken != nil {
            Log.info("✅ Refresh token saved successfully", category: "Auth")
        } else {
            Log.error("❌ Refresh token not saved!", category: "Auth")
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
        Task {
            #if canImport(UIKit)
            let granted = await PushNotificationManager.shared.requestPermission()
            if granted {
                Log.info("📱 Push notifications enabled for user", category: "Auth")
            } else {
                Log.info("📱 Push notifications declined by user", category: "Auth")
            }
            // requestPermission() may return immediately if already granted without
            // triggering a new APNs token delivery, so explicitly ensure registration.
            await PushNotificationManager.shared.ensureTokenRegistered()
            #endif
        }
        
        // ✅ REMOVED: NotificationCenter - now using Combine reactive approach
        // Long polling will start automatically when sessionToken is published
    }

    private func handleConnectSuccess(userId: String, username: String) {
        print("✅ ConnectSuccess received!")
        print("   User ID: \(userId)")
        print("   Username: \(username)")

        currentUserId = userId
        isAuthenticated = true
        scheduleTokenRefresh()

        // ✅ REFACTOR Phase 1.2: Load User entity and set currentUser
        loadUserFromCoreData(userId: userId)
        print("✅ User authenticated successfully")
    }
    
    private func handleSessionExpired() {
        SessionManager.shared.clearSession()
        self.isAuthenticated = false
        ErrorRouter.shared.report(.sessionExpired)
    }
    
    private func handleDeleteAccountSuccess() {
        Log.info("✅ Account deletion successful", category: "AuthViewModel")
        cancelTimeouts()
        self.isLoading = false
        
        // Clear all user data
        SessionManager.shared.clearSession()
        CryptoManager.shared.deleteAllCryptoKeys()
        KeychainManager.shared.deleteDeviceKeys()
        
        // Clear CoreData - delete all user's data
        let context = viewContext
        
        // ✅ FIX: Check if persistent store coordinator is ready before accessing entities
        guard context.persistentStoreCoordinator != nil else {
            Log.info("⚠️ Core Data persistent store coordinator not ready, skipping data deletion", category: "AuthViewModel")
            // Continue with logout even if Core Data isn't ready
            isAuthenticated = false
            currentUserId = nil
            currentUser = nil  // ✅ REFACTOR Phase 1.2
            hasRegisteredDeviceKeys = false
            return
        }
        
        // Delete all chats and messages
        let chatFetchRequest: NSFetchRequest<Chat> = Chat.fetchRequest()
        if let chats = try? context.fetch(chatFetchRequest) {
            for chat in chats {
                context.delete(chat)
            }
        }
        
        // Delete all users
        let userFetchRequest: NSFetchRequest<User> = User.fetchRequest()
        if let users = try? context.fetch(userFetchRequest) {
            for user in users {
                context.delete(user)
            }
        }
        
        // Save changes
        do {
            try context.save()
            Log.info("✅ All user data deleted from CoreData", category: "AuthViewModel")
        } catch {
            Log.error("❌ Failed to delete user data from CoreData: \(error)", category: "AuthViewModel")
        }

        // Reset auth state
        isAuthenticated = false
        currentUserId = nil
        currentUser = nil  // ✅ REFACTOR Phase 1.2
        hasRegisteredDeviceKeys = false

        Log.info("✅ Account deletion complete - user logged out", category: "AuthViewModel")
    }
    
    // MARK: - Core Data Integration
    
    /// Finds or creates the User entity and loads local data into the AuthViewModel
    /// - Parameters:
    ///   - userId: The user ID to load data for
    ///   - username: Optional username to update/set (from login response)
    private func loadUserFromCoreData(userId: String, username: String? = nil) {
        // ✅ FIX: Check if persistent store coordinator is ready before accessing entities
        guard viewContext.persistentStoreCoordinator != nil else {
            print("⚠️ Core Data persistent store coordinator not ready yet, skipping user load")
            return
        }
        
        // ✅ SIMPLIFIED: No more multi-account filtering
        let fetchRequest = User.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", userId)
        
        print("🔍 loadUserFromCoreData: Searching for userId: \(userId)")
        if let username = username {
            print("   Username from parameter: \(username)")
        }
        
        do {
            let user: User
            var needsSave = false
            
            if let existingUser = try viewContext.fetch(fetchRequest).first {
                user = existingUser
                print("👤 Found existing user in Core Data: \(user.displayName)")
                
                // ✅ UPDATE: Update username if provided and different
                if let newUsername = username, !newUsername.isEmpty {
                    if user.username.isEmpty || user.username != newUsername {
                        print("🔄 Updating username: '\(user.username)' -> '\(newUsername)'")
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
                print("✨ No user found, creating new user...")
                // First login on this device, create a new User entity
                user = User(context: viewContext)
                user.id = userId
                user.username = username ?? ""
                user.displayName = username ?? ""
                user.isSharingWithMe = false
                user.isBlocked = false
                user.amISharingWith = false
                needsSave = true
                print("✨ Created new user in Core Data for ID: \(userId)")
                print("   username: \(user.username)")
            }
            
            // Save if needed
            if needsSave {
                try viewContext.save()
                print("💾 Saved user changes to Core Data")
            }
            
            // ✅ REFACTOR Phase 1.2: Set currentUser - single source of truth!
            self.currentUserId = user.id
            self.currentUser = user
            CryptoManager.shared.setLocalUserId(user.id)
            
            print("✅ Restored user data from Core Data:")
            print("   userId: \(user.id)")
            print("   username: \(user.username)")
            print("   displayName: \(user.displayName)")
            
        } catch {
            print("❌ Failed to fetch or create user from Core Data: \(error)")
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
