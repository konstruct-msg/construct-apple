//
//  AuthViewModel.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import Foundation
import Combine
import CoreData

@MainActor
class AuthViewModel: ObservableObject {
    @Published var isAuthenticated = false
    @Published var currentUserId: String?
    
    // ✅ REFACTOR Phase 1.2: Single source of truth - Core Data User entity
    @Published var currentUser: User?
    
    // ✅ Computed properties for convenience (backwards compatibility)
    var currentUsername: String {
        currentUser?.username ?? ""
    }
    
    var currentDisplayName: String {
        currentUser?.displayName ?? currentUser?.username ?? ""
    }
    
    @Published var isLoading = false
    @Published var errorMessage: String?

    private var cancellables = Set<AnyCancellable>()
    private var sessionRestoreTimer: Timer?
    private var authOperationTimer: Timer?
    private let viewContext: NSManagedObjectContext

    // Timer for monitoring token expiration
    nonisolated(unsafe) private var tokenRefreshTimer: Timer?

    init(context: NSManagedObjectContext) {
        self.viewContext = context
        setupSubscribers()
        startTokenRefreshMonitoring()  // ✅ Monitor token expiration
        setupSessionExpiredListener()  // ✅ Listen for session expiration from REST API
        
        // ✅ Device-based auth: Try to restore session OR authenticate with device keys
        Task {
            await restoreOrAuthenticateDevice()
        }
    }
    
    // ✅ NEW: Listen for session expiration notifications from REST API
    private func setupSessionExpiredListener() {
        NotificationCenter.default.publisher(for: NSNotification.Name("SessionExpired"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleSessionExpired()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSNotification.Name("SessionInvalidated"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task {
                    await self?.restoreOrAuthenticateDevice()
                }
            }
            .store(in: &cancellables)
    }

    deinit {
        tokenRefreshTimer?.invalidate()
    }

    private func setupSubscribers() {
        // ✅ WebSocket removed - using REST API only
        // Session expiration is handled via setupSessionExpiredListener()
    }

    // MARK: - Session Management
    
    /// Restore existing session OR authenticate with device keys
    func restoreOrAuthenticateDevice() async {
        print("🔄 restoreOrAuthenticateDevice() called")
        
        // Step 1: Try to restore existing session token
        SessionManager.shared.loadSessionToken()
        
        if let _ = SessionManager.shared.sessionToken,
           let userId = SessionManager.shared.currentUserId {
            // We have session token - verify it's still valid
            print("✅ Found session token for user: \(userId)")
            await MainActor.run {
                self.currentUserId = userId
                self.isAuthenticated = true
                loadUserFromCoreData(userId: userId)
            }
            return
        }
        
        // Step 2: No session token - try device-based auth
        guard let deviceId = KeychainManager.shared.loadDeviceID(),
              let _ = KeychainManager.shared.loadDeviceSigningKey() else {
            print("❌ No device keys found - user needs to register")
            return
        }
        
        print("🔑 Device keys found - authenticating with device ID: \(deviceId)")
        
        do {
            // Create signature: Sign(device_id + timestamp)
            let timestamp = Int64(Date().timeIntervalSince1970)
            let message = "\(deviceId)\(timestamp)"
            guard let messageData = message.data(using: .utf8) else {
                throw NetworkError.encodingFailed
            }
            
            // TODO: Implement proper signing with Ed25519
            // For now, use base64 of message as placeholder
            let signature = messageData.base64EncodedString()
            
            let response: AuthResponse
            if #available(iOS 18.0, *) {
                response = try await AuthServiceClient.shared.authenticateDevice(
                    deviceId: deviceId,
                    timestamp: timestamp,
                    signature: signature
                )
            } else {
                throw NetworkError.connectionFailed
            }
            
            // Save tokens
            let expiresInSeconds: Int
            if let expiresAt = response.expiresAt {
                expiresInSeconds = max(Int(expiresAt - Int64(Date().timeIntervalSince1970)), 3600)
            } else if let expiresIn = response.expiresIn {
                expiresInSeconds = expiresIn
            } else {
                expiresInSeconds = 3600
            }
            
            SessionManager.shared.saveTokens(
                accessToken: response.accessToken,
                refreshToken: response.refreshToken,
                expiresIn: expiresInSeconds
            )
            
            await MainActor.run {
                self.currentUserId = response.userId
                self.isAuthenticated = true
                print("✅ Device-based authentication successful")
            }
            
            // Load user from Core Data
            loadUserFromCoreData(userId: response.userId)
            
        } catch {
            print("❌ Device authentication failed: \(error)")
            
            // ✅ If device auth fails (401 = device not registered on server)
            // Clear device keys so user sees OnboardingView
            await MainActor.run {
                Log.error("🗑️ Device auth failed - clearing device keys to show onboarding", category: "Auth")
                KeychainManager.shared.deleteDeviceKeys()
                NotificationCenter.default.post(name: NSNotification.Name("DeviceKeysDeleted"), object: nil)
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
            
            let response: AuthResponse
            if #available(iOS 18.0, *) {
                response = try await AuthServiceClient.shared.refreshToken(refreshToken: refreshToken)
            } else {
                throw NetworkError.connectionFailed
            }
            
            // Save new tokens
            await MainActor.run {
                let expiresIn: Int
                if let expiresAt = response.expiresAt {
                    expiresIn = max(Int(expiresAt - Int64(Date().timeIntervalSince1970)), 3600)
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

    func register(username: String, displayName: String?, password: String) {
        self.isLoading = true
        self.errorMessage = nil

        guard let registrationBundle = CryptoManager.shared.generateRegistrationBundle() else {
            self.errorMessage = "Failed to generate cryptographic keys."
            self.isLoading = false
            return
        }

        Task {
            do {
                // Step 1: Create BundleData using globally defined structs
                let isoFormatter = ISO8601DateFormatter()
                isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                
                guard let suiteID = UInt16(registrationBundle.suiteId) else {
                    throw NSError(domain: "AuthViewModel", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid suiteId format"])
                }

                let suite = SuiteKeyMaterial(
                    suiteId: suiteID,
                    identityKey: registrationBundle.identityPublic,
                    signedPrekey: registrationBundle.signedPrekeyPublic,
                    signedPrekeySignature: registrationBundle.signature,  // ✅ Include signature for signedPrekey
                    oneTimePrekeys: [] // One-time keys are optional for the initial bundle.
                )

                let bundleData = BundleData(
                    userId: "", // User ID is empty during registration.
                    timestamp: isoFormatter.string(from: Date()),
                    supportedSuites: [suite]
                )

                // Step 2: JSON-encode BundleData. This JSON string is what gets Base64-encoded into UploadableKeyBundle.bundleData.
                let jsonEncoder = JSONEncoder()
                jsonEncoder.outputFormatting = .sortedKeys
                let bundleDataJSON = try jsonEncoder.encode(bundleData)
                
                // Step 2.5: Sign the BundleData JSON with Ed25519 signing key
                // The signature from registrationBundle is for signed_prekey, not for BundleData
                // We need to create a new signature for the BundleData JSON string
                let bundleDataSignature = try CryptoManager.shared.signBundleData(bundleDataJSON)

                // Step 3: Create the final UploadableKeyBundle.
                let uploadableBundle = UploadableKeyBundle(
                    masterIdentityKey: registrationBundle.verifyingKey,
                    bundleData: bundleDataJSON.base64EncodedString(), // This is still Base64 encoded JSON string
                    signature: bundleDataSignature
                )

                // Step 4: Send to server via REST API (new approach)
                let result = try await AuthAPI.shared.register(
                    username: username,
                    password: password,
                    publicKey: uploadableBundle
                )
                
                    // Handle success on main thread
                    await MainActor.run {
                        handleAuthSuccess(
                            userId: result.userId,
                            username: result.username,
                            token: result.sessionToken,
                            refreshToken: result.refreshToken,
                            expires: result.expires
                        )
                        
                        // ✅ REMOVED: WebSocket connection - using REST API only
                    }
            } catch {
                await MainActor.run {
                    cancelTimeouts()
                    self.isLoading = false
                    self.errorMessage = "Registration failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func login(username: String, password: String) {
        self.isLoading = true
        self.errorMessage = nil

        Task {
            do {
                // Login via REST API (new approach)
                let result = try await AuthAPI.shared.login(
                    username: username,
                    password: password
                )
                
                    // Handle success on main thread
                    await MainActor.run {
                        handleAuthSuccess(
                            userId: result.userId,
                            username: result.username,
                            token: result.sessionToken,
                            refreshToken: result.refreshToken,
                            expires: result.expires
                        )
                        
                        // ✅ REMOVED: WebSocket connection - using REST API only
                    }
            } catch {
                await MainActor.run {
                    cancelTimeouts()
                    self.isLoading = false
                    self.errorMessage = "Login failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func finalizeDeviceRegistration(userId: String, username: String?) {
        currentUserId = userId
        isAuthenticated = true
        loadUserFromCoreData(userId: userId, username: username)
    }

    func logout() {
        Task {
            // 0. Send END_SESSION to all contacts (NEW!)
            let chatsVM = ChatsViewModel()
            await chatsVM.sendEndSessionToAllContacts(reason: "logout")
            Log.info("✅ END_SESSION sent to all contacts on logout", category: "Auth")
            
            // 1. Logout via gRPC
            if SessionManager.shared.sessionToken != nil {
                do {
                    if #available(iOS 18.0, *) {
                        try await AuthServiceClient.shared.logout()
                    }
                } catch {
                    Log.error("Logout API call failed: \(error.localizedDescription)", category: "Auth")
                    // Continue with local logout even if API call fails
                }
            }
            
            await MainActor.run {
                cancelTimeouts()
                SessionManager.shared.clearSession()
                
                // Note: We keep the username in Keychain for convenience on next login
                // If you want to clear it, uncomment the line below:
                // KeychainManager.shared.deleteLastUsername()
                
                isAuthenticated = false
                currentUserId = nil
                currentUser = nil  // ✅ REFACTOR Phase 1.2
            }
        }
    }
    
    func deleteAccount() {
        self.isLoading = true
        self.errorMessage = nil
        
        Log.info("🗑️ Requesting account deletion", category: "AuthViewModel")
        
        Task {
            do {
                try await deleteAccountWithDeviceSignature()
                
                await MainActor.run {
                    handleDeleteAccountSuccess()
                }
            } catch {
                await MainActor.run {
                    cancelTimeouts()
                    self.isLoading = false
                    self.errorMessage = "Account deletion failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func deleteAccountWithDeviceSignature() async throws {
        // Prefer gRPC UserService on iOS 18+
        if #available(iOS 18.0, *) {
            let response = try await UserServiceClient.shared.deleteAccount(
                confirmation: "DELETE",
                reason: "user_requested"
            )
            guard response.success else {
                throw NSError(domain: "AuthViewModel", code: 3, userInfo: [NSLocalizedDescriptionKey: response.message])
            }
            return
        }

        // Fallback: REST challenge-based flow
        guard let userId = SessionManager.shared.currentUserId else {
            throw NSError(domain: "AuthViewModel", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing userId"])
        }
        guard let deviceId = KeychainManager.shared.loadDeviceID() else {
            throw NSError(domain: "AuthViewModel", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing deviceId"])
        }

        let challenge = try await AuthAPI.shared.getDeleteChallenge()
        let ts = Int64(Date().timeIntervalSince1970)
        let canonical = "DELETE|\(userId)|\(deviceId)|\(challenge.challenge)|\(ts)"

        let signingSecret = try CryptoManager.shared.exportSigningSecretKey()
        let signature = try signInviteData(data: canonical, identitySecretKey: signingSecret)
        let signatureBase64 = Data(signature.signature).base64EncodedString()

        let request = DeleteDeviceRequest(
            deviceId: deviceId,
            challenge: challenge.challenge,
            signature: signatureBase64,
            ts: ts
        )

        try await AuthAPI.shared.confirmDeleteDevice(request: request)
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
            self.errorMessage = "Connection timeout. Please check your internet and try again."
            print("⏱️ Session restore timeout - showing login screen")
        }
    }

    private func cancelTimeouts() {
        authOperationTimer?.invalidate()
        authOperationTimer = nil
        sessionRestoreTimer?.invalidate()
        sessionRestoreTimer = nil
    }

    // MARK: - State Updaters
    // ✅ WebSocket message handling removed - using REST API only
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
            expiresIn: max(expiresIn, 3600)  // At least 1 hour
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
        
        // ✅ REFACTOR Phase 1.2: Load User entity and set currentUser
        // Pass username parameter so it gets saved to Core Data
        loadUserFromCoreData(userId: userId, username: username)
        
        // ✅ NEW: Request push notification permission after successful registration/login
        // This is done async to not block the auth flow
        Task {
            let granted = await PushNotificationManager.shared.requestPermission()
            if granted {
                Log.info("📱 Push notifications enabled for user", category: "Auth")
            } else {
                Log.info("📱 Push notifications declined by user", category: "Auth")
            }
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

        // ✅ REFACTOR Phase 1.2: Load User entity and set currentUser
        loadUserFromCoreData(userId: userId)
        print("✅ User authenticated successfully")
    }
    
    private func handleSessionExpired() {
        SessionManager.shared.clearSession()
        self.isAuthenticated = false
        self.errorMessage = "Session expired. Please login again."
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
        let context = PersistenceController.shared.container.viewContext
        
        // ✅ FIX: Check if persistent store coordinator is ready before accessing entities
        guard context.persistentStoreCoordinator != nil else {
            Log.info("⚠️ Core Data persistent store coordinator not ready, skipping data deletion", category: "AuthViewModel")
            // Continue with logout even if Core Data isn't ready
            isAuthenticated = false
            currentUserId = nil
            currentUser = nil  // ✅ REFACTOR Phase 1.2
            NotificationCenter.default.post(name: NSNotification.Name("AccountDeleted"), object: nil)
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
        
        // Notify UI that account was deleted
        NotificationCenter.default.post(name: NSNotification.Name("AccountDeleted"), object: nil)
        NotificationCenter.default.post(name: NSNotification.Name("DeviceKeysDeleted"), object: nil)
        
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
                        user.username = newUsername
                        // Also update displayName if it's empty or was same as old username
                        if user.displayName.isEmpty || user.displayName == user.username {
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
