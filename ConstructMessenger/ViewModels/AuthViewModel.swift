//
//  AuthViewModel.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import Foundation
import Combine

@MainActor
class AuthViewModel: ObservableObject {
    @Published var isAuthenticated = false
    @Published var currentUserId: String?
    @Published var currentUsername: String?
    @Published var currentDisplayName: String?
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let wsManager = WebSocketManager.shared
    private var cancellables = Set<AnyCancellable>()
    private var sessionRestoreTimer: Timer?
    private var authOperationTimer: Timer?

    // Timer for monitoring token expiration
    nonisolated(unsafe) private var tokenRefreshTimer: Timer?

    init() {
        setupSubscribers()
        startTokenRefreshMonitoring()  // ✅ FIXED: Monitor token expiration
    }

    deinit {
        tokenRefreshTimer?.invalidate()
    }

    private func setupSubscribers() {
        wsManager.messagePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                self?.handleServerMessage(message)
            }
            .store(in: &cancellables)

        wsManager.errorPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                self?.handleConnectionError(error)
            }
            .store(in: &cancellables)
    }

    // MARK: - Session Management
    func restoreSession() {
        print("🔄 restoreSession() called")

        guard let token = SessionManager.shared.sessionToken else {
            print("❌ No session token found - user needs to login")
            return
        }

        guard let userId = SessionManager.shared.currentUserId else {
            print("❌ No current user ID found")
            return
        }

        print("✅ Found session token for user: \(userId)")

        // ✅ FIXED: Check if token is still valid
        guard SessionManager.shared.isSessionValid else {
            print("⚠️ Stored session token has expired")
            SessionManager.shared.clearSession()
            return
        }

        print("✅ Session token is valid, attempting restore...")

        isLoading = true

        print("🔌 Connecting to WebSocket...")
        wsManager.connect()

        print("📤 Sending Connect message with token: \(token.prefix(20))...")
        wsManager.send(.connect(ConnectData(sessionToken: token)))

        startSessionRestoreTimeout()
        print("✅ Session restore initiated, waiting for ConnectSuccess")
    }

    // ✅ FIXED: Monitor token expiration
    private func startTokenRefreshMonitoring() {
        // Check every minute
        tokenRefreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.checkTokenExpiration()
        }
    }

    // ✅ FIXED: Check if token needs refresh
    private func checkTokenExpiration() {
        guard isAuthenticated else { return }

        if !SessionManager.shared.isSessionValid {
            print("⚠️ Session token expired or expiring soon")
            handleSessionExpired()
        }
    }

    func register(username: String, displayName: String?, password: String) {
        isLoading = true
        errorMessage = nil

        guard let registrationBundle = CryptoManager.shared.generateRegistrationBundle() else {
            errorMessage = "Failed to generate cryptographic keys."
            isLoading = false
            return
        }

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

            // Step 3: Create the final UploadableKeyBundle.
            let uploadableBundle = UploadableKeyBundle(
                masterIdentityKey: registrationBundle.verifyingKey,
                bundleData: bundleDataJSON.base64EncodedString(), // This is still Base64 encoded JSON string
                signature: registrationBundle.signature
            )

            // Step 4: Send to server. The publicKey is now the native UploadableKeyBundle object, and displayName is removed.
            wsManager.connect()
            wsManager.send(.register(RegisterData(username: username, password: password, publicKey: uploadableBundle)))
            startAuthTimeout()
        } catch {
            errorMessage = "Failed to prepare registration data: \(error.localizedDescription)"
            isLoading = false
        }
    }

    func login(username: String, password: String) {
        isLoading = true
        errorMessage = nil



        wsManager.connect()
        wsManager.send(.login(LoginData(username: username, password: password)))
        startAuthTimeout()
    }

    func logout() {
        if let token = SessionManager.shared.sessionToken {
            wsManager.send(.logout(LogoutData(sessionToken: token)))
        }
        
        cancelTimeouts()
        SessionManager.shared.clearSession()
        
        isAuthenticated = false
        currentUserId = nil
        currentUsername = nil
        // Removed currentDisplayName = nil
        
        wsManager.disconnect()
    }

    // MARK: - Timeout Helpers
    private func startAuthTimeout() {
        authOperationTimer?.invalidate()
        authOperationTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: false) { [weak self] _ in
            self?.handleTimeout()
        }
    }
    
    private func startSessionRestoreTimeout() {
        sessionRestoreTimer?.invalidate()
        sessionRestoreTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { [weak self] _ in
            self?.handleTimeout()
        }
    }
    
    private func handleTimeout() {
        if isLoading && !isAuthenticated {
            isLoading = false
            errorMessage = "Connection timeout. Please check your internet and try again."
            wsManager.disconnect()
        }
    }

    private func cancelTimeouts() {
        authOperationTimer?.invalidate()
        authOperationTimer = nil
        sessionRestoreTimer?.invalidate()
        sessionRestoreTimer = nil
    }

    // MARK: - Message & Error Handling
    private func handleServerMessage(_ message: ServerMessage) {
        cancelTimeouts()
        isLoading = false
        
        switch message {
        case .registerSuccess(let data):
            handleAuthSuccess(userId: data.userId, username: data.username, token: data.sessionToken, expires: data.expires)

        case .loginSuccess(let data):
            handleAuthSuccess(userId: data.userId, username: data.username, token: data.sessionToken, expires: data.expires)

        case .connectSuccess(let data):
            handleConnectSuccess(userId: data.userId, username: data.username)

        case .sessionExpired:
            handleSessionExpired()

        case .error(let data):
            errorMessage = "Error (\(data.code)): \(data.message)"
            
        case .logoutSuccess:
            // Client-side logout already handled
            break

        default:
            // Other messages are not handled by this view model
            break
        }
    }
    
    private func handleConnectionError(_ error: Error) {
        cancelTimeouts()
        errorMessage = error.localizedDescription
        isLoading = false
    }

    // MARK: - State Updaters
    private func handleAuthSuccess(userId: String, username: String, token: String, expires: Int64) {
        // ✅ FIXED: Pass expires timestamp to SessionManager
        SessionManager.shared.saveSession(userId: userId, token: token, expires: expires)
        currentUserId = userId
        currentUsername = username
        currentDisplayName = nil // Set to nil explicitly if not received from server
        isAuthenticated = true
    }

    private func handleConnectSuccess(userId: String, username: String) {
        print("✅ ConnectSuccess received!")
        print("   User ID: \(userId)")
        print("   Username: \(username)")

        currentUserId = userId
        currentUsername = username
        currentDisplayName = nil // Set to nil explicitly if not received from server
        isAuthenticated = true

        print("✅ User authenticated successfully")
    }
    
    private func handleSessionExpired() {
        SessionManager.shared.clearSession()
        isAuthenticated = false
        errorMessage = "Session expired. Please login again."
    }
}
