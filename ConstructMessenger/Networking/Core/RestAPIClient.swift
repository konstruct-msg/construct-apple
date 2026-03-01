//
//  RestAPIClient.swift
//  Construct Messenger
//
//  Core REST API client - shared networking infrastructure
//  Created on 26.01.2026 (Phase 2.1 refactoring)
//

import Foundation

/// Base REST API client providing shared networking infrastructure
/// Handles session management, server fallback, and request execution
class RestAPIClient {
    static let shared = RestAPIClient()

    private let session: URLSession
    private let longPollingSession: URLSession
    
    private var baseURL: String {
        APIConstants.activeServerURL
    }

    // Track which server URL is currently working
    private var workingServerURL: String?

    // Reference to connection status manager
    private let connectionStatusManager = ConnectionStatusManager.shared

    private init() {
        // Regular session for standard requests
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = APIConstants.connectionTimeout
        config.timeoutIntervalForResource = APIConstants.connectionTimeout * 2
        self.session = URLSession(configuration: config)
        
        // Separate session for long polling with increased timeouts
        let longPollingConfig = URLSessionConfiguration.default
        longPollingConfig.timeoutIntervalForRequest = APIConstants.longPollingTimeout
        longPollingConfig.timeoutIntervalForResource = APIConstants.longPollingResourceTimeout
        self.longPollingSession = URLSession(configuration: longPollingConfig)
    }
    
    // MARK: - Server Fallback Logic
    
    /// Get list of server URLs to try (with fallback)
    private func getServerURLsToTry() -> [String] {
        // If we have a working URL, try it first
        if let working = workingServerURL {
            var urls = [working]
            // Add other URLs as fallbacks
            for url in ServerConfig.serverURLs where url != working {
                urls.append(url)
            }
            return urls
        }
        // Otherwise try all URLs in order
        return ServerConfig.serverURLs
    }
    
    // MARK: - Core Request Method
    
    /// Perform HTTP request with automatic server fallback and error handling
    /// - Parameters:
    ///   - endpoint: API endpoint path (e.g., "/api/v1/auth/login")
    ///   - method: HTTP method (GET, POST, DELETE, etc.)
    ///   - body: Optional request body as dictionary (will be JSON encoded)
    ///   - requiresAuth: Whether to include Bearer token in Authorization header
    ///   - timeout: Optional custom timeout (for long-polling)
    ///   - isLongPolling: Whether this is a long-polling request (uses separate session)
    ///   - maxRetries: Maximum number of retry attempts for transient failures (default: 0)
    /// - Returns: Decoded response of type T
    func performRequest<T: Decodable>(
        endpoint: String,
        method: String,
        body: [String: Any]? = nil,
        requiresAuth: Bool = false,
        timeout: TimeInterval? = nil,
        isLongPolling: Bool = false,
        maxRetries: Int = 0
    ) async throws -> T {
        // Retry loop for transient failures
        var retryAttempt = 0
        let totalAttempts = maxRetries + 1  // Initial attempt + retries
        
        while retryAttempt < totalAttempts {
            do {
                // Try to perform the request
                let result: T = try await performSingleRequest(
                    endpoint: endpoint,
                    method: method,
                    body: body,
                    requiresAuth: requiresAuth,
                    timeout: timeout,
                    isLongPolling: isLongPolling,
                    attemptNumber: retryAttempt + 1,
                    totalAttempts: totalAttempts
                )
                
                // Success! Return result
                if retryAttempt > 0 {
                    Log.info("✅ Request succeeded after \(retryAttempt) retries", category: "Network")
                }
                return result
                
            } catch let error as NetworkError {
                // Check if this is a retryable error
                let isRetryable = shouldRetry(error: error)
                
                if isRetryable && retryAttempt < maxRetries {
                    retryAttempt += 1
                    let delay = calculateBackoff(attempt: retryAttempt)
                    Log.info("🔄 Retry \(retryAttempt)/\(maxRetries) after \(delay)s delay (error: \(error))", category: "Network")
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } else {
                    // Not retryable or out of retries
                    if maxRetries > 0 && !isRetryable {
                        Log.error("❌ Error not retryable: \(error)", category: "Network")
                    }
                    throw error
                }
                
            } catch {
                // Non-NetworkError - don't retry
                throw error
            }
        }
        
        // Should never reach here
        throw NetworkError.connectionFailed
    }
    
    /// Calculate exponential backoff delay
    private func calculateBackoff(attempt: Int) -> TimeInterval {
        // Exponential backoff: 1s, 2s, 4s, 8s...
        let baseDelay = APIConstants.retryBaseDelay
        let delay = baseDelay * pow(2.0, Double(attempt - 1))
        return min(delay, 10.0)  // Cap at 10 seconds
    }
    
    /// Determine if an error is retryable
    private func shouldRetry(error: NetworkError) -> Bool {
        switch error {
        case .serverError(let message, _):
            // Retry timeout and connectivity errors
            if message.contains("timedOut") || 
               message.contains("Cannot connect") ||
               message.contains("timeout") {
                return true
            }
            // Retry 5xx server errors (temporary)
            if message.contains("Server error (status: 5") {
                return true
            }
            return false
        case .connectionFailed:
            return true
        case .disconnected:
            return true  // Retry on connection loss
        case .notConnected:
            return false  // No internet - don't retry
        case .decodingFailed, .encodingFailed, .invalidMessage:
            return false  // Permanent errors
        }
    }
    
    /// Perform a single request attempt (without retry logic)
    private func performSingleRequest<T: Decodable>(
        endpoint: String,
        method: String,
        body: [String: Any]?,
        requiresAuth: Bool,
        timeout: TimeInterval?,
        isLongPolling: Bool,
        attemptNumber: Int,
        totalAttempts: Int
    ) async throws -> T {
        let serverURLs = getServerURLsToTry()
        var lastError: Error?
        
        // Try each server URL until one works
        for (index, serverURL) in serverURLs.enumerated() {
            let fullURL = serverURL + endpoint
            
            let retryPrefix = totalAttempts > 1 ? "[Retry \(attemptNumber)/\(totalAttempts)] " : ""
            Log.info("🌐 \(retryPrefix)REST API \(method) \(endpoint) (server \(index + 1)/\(serverURLs.count))", category: "Network")
            Log.info("   Server URL: \(serverURL)", category: "Network")
            Log.info("   Full URL: \(fullURL)", category: "Network")
            
            guard let url = URL(string: fullURL) else {
                Log.error("❌ Invalid URL: \(fullURL)", category: "Network")
                lastError = NetworkError.connectionFailed
                continue
            }
            
            var request = URLRequest(url: url)
            request.httpMethod = method
            
            // Set timeout if provided (for long polling)
            if let timeout = timeout {
                request.timeoutInterval = timeout
            }
            
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
            
            // Set Host header explicitly to help with DNS resolution
            if let host = url.host {
                request.setValue(host, forHTTPHeaderField: "Host")
                Log.info("📋 Host header: \(host)", category: "Network")
            }
            
            // Add authentication header if required
            if requiresAuth {
                if let token = SessionManager.shared.sessionToken {
                    let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
                    
                    if trimmedToken != token {
                        Log.info("⚠️ Token had whitespace, trimmed (original: \(token.count), trimmed: \(trimmedToken.count))", category: "Network")
                    }
                    
                    let tokenPreview = if trimmedToken.count > 40 {
                        "\(trimmedToken.prefix(20))...\(trimmedToken.suffix(20))"
                    } else {
                        trimmedToken
                    }
                    Log.info("🔐 Token preview: \(tokenPreview)", category: "Network")
                    Log.info("   Token length: \(trimmedToken.count) characters", category: "Network")
                    
                    let authHeader = "Bearer \(trimmedToken)"
                    request.setValue(authHeader, forHTTPHeaderField: "Authorization")
                    Log.info("✅ Authorization header set", category: "Network")
                    
                    // Log token expiration status
                    if let expires = SessionManager.shared.sessionExpires {
                        let timeUntilExpiry = expires.timeIntervalSinceNow
                        if timeUntilExpiry > 0 {
                            Log.info("   Token expires in: \(Int(timeUntilExpiry / 60)) minutes", category: "Network")
                        } else {
                            Log.info("⚠️ Token has already expired! (expired \(Int(-timeUntilExpiry / 60)) minutes ago)", category: "Network")
                        }
                    } else {
                        Log.info("⚠️ No expiration info for token", category: "Network")
                    }
                } else {
                    Log.error("❌ No session token available for authenticated request", category: "Network")
                    throw NetworkError.notConnected
                }
            } else {
                Log.info("ℹ️ Public endpoint - no Authorization header", category: "Network")
            }
            
            // Add request body if provided
            if let body = body {
                do {
                    let bodyData = try JSONSerialization.data(withJSONObject: body, options: .prettyPrinted)
                    request.httpBody = bodyData
                    
                    // Log request body for debugging
                    if let bodyString = String(data: bodyData, encoding: .utf8) {
                        Log.info("📤 Request body:\n\(bodyString)", category: "Network")
                    }
                } catch {
                    Log.error("❌ Failed to serialize request body: \(error)", category: "Network")
                    throw NetworkError.encodingFailed
                }
            }
            
            do {
                // Use appropriate session based on request type
                let activeSession = isLongPolling ? longPollingSession : session
                let (data, response) = try await activeSession.data(for: request)
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    lastError = NetworkError.connectionFailed
                    continue
                }
                
                Log.info("📡 Response status: \(httpResponse.statusCode) from \(serverURL)", category: "Network")
                
                // Handle error responses
                if httpResponse.statusCode >= 400 {
                    let errorResponse = try? JSONDecoder().decode(ErrorResponse.self, from: data)
                    let errorMessage = errorResponse?.message ?? errorResponse?.error ?? "Server error (status: \(httpResponse.statusCode))"
                    let responseBody = String(data: data, encoding: .utf8)
                    
                    // Log response body for debugging
                    if httpResponse.statusCode == 422 {
                        Log.error("❌ Validation error (422): \(errorMessage)", category: "Network")
                        if let body = responseBody {
                            Log.error("📥 Response body: \(body)", category: "Network")
                        }
                    }
                    
                    // Handle 401 Unauthorized - token expired or invalid
                    if httpResponse.statusCode == 401 {
                        Log.error("❌ Authentication failed (401): \(errorMessage)", category: "Network")
                        
                        let shouldClearSession: Bool
                        if let expires = SessionManager.shared.sessionExpires {
                            shouldClearSession = Date() >= expires
                            if shouldClearSession {
                                Log.info("⚠️ Token has expired (expired at: \(expires))", category: "Network")
                            } else {
                                Log.info("⚠️ Got 401 but token is not expired yet. May be a server issue.", category: "Network")
                            }
                        } else {
                            shouldClearSession = true
                            Log.info("⚠️ Got 401 and no expiration info available", category: "Network")
                        }
                        
                        if shouldClearSession {
                            DispatchQueue.main.async {
                                SessionManager.shared.clearSession()
                                NotificationCenter.default.post(name: NSNotification.Name("SessionExpired"), object: nil)
                            }
                            throw NetworkError.serverError(message: "Session expired. Please login again.", responseBody: responseBody)
                        } else {
                            throw NetworkError.serverError(message: "Authentication failed: \(errorMessage)", responseBody: responseBody)
                        }
                    }
                    
                    // For other 4xx errors, don't try fallback
                    if httpResponse.statusCode < 500 {
                        throw NetworkError.serverError(message: errorMessage, responseBody: responseBody)
                    }
                    
                    // For 5xx errors, try next server
                    lastError = NetworkError.serverError(message: errorMessage, responseBody: responseBody)
                    continue
                }
                
                // Success! Remember this working server URL
                workingServerURL = serverURL
                Log.info("✅ Successfully connected to: \(serverURL)", category: "Network")

                // Update connection status
                Task { @MainActor in connectionStatusManager.markRequestSucceeded() }
                
                // Decode successful response
                do {
                    let decoder = JSONDecoder()
                    // Handle empty response
                    if data.isEmpty {
                        if T.self == EmptyResponse.self, let response = EmptyResponse() as? T {
                            return response
                        }
                    }
                    return try decoder.decode(T.self, from: data)
                } catch {
                    Log.error("❌ Failed to decode response: \(error)", category: "Network")
                    if let responseString = String(data: data, encoding: .utf8) {
                        Log.error("   Response body: \(responseString)", category: "Network")
                    }
                    throw NetworkError.decodingFailed
                }
            } catch let error as NetworkError {
                // Don't retry on certain errors
                if case .decodingFailed = error {
                    throw error
                }
                if case .encodingFailed = error {
                    throw error
                }
                if case .notConnected = error {
                    throw error
                }
                lastError = error
                continue
            } catch let urlError as URLError {
                Log.error("❌ URL Error for \(serverURL): \(urlError.localizedDescription)", category: "Network")
                Log.error("   Code: \(urlError.code.rawValue)", category: "Network")
                
                // SPECIAL CASE: Long-polling timeout is NORMAL
                if isLongPolling && urlError.code == .timedOut {
                    Log.debug("⏱️ Long-polling timeout (normal behavior) - no new messages", category: "Network")
                    Task { @MainActor in connectionStatusManager.markRequestSucceeded() }
                    if T.self == PollMessagesResponse.self {
                        guard let emptyResponse = PollMessagesResponse(messages: [], nextSince: nil, hasMore: false) as? T else {
                            // This should never happen, but handle gracefully
                            Log.error("Failed to cast PollMessagesResponse to generic type", category: "Network")
                            throw urlError
                        }
                        return emptyResponse
                    }
                    throw urlError
                }
                
                // Check if this is a connectivity error that might be fixed by trying another server
                switch urlError.code {
                case .cannotFindHost, .cannotConnectToHost, .timedOut:
                    lastError = urlError
                    if index < serverURLs.count - 1 {
                        Log.info("🔄 Trying fallback server...", category: "Network")
                        continue
                    }
                    let message = "Cannot connect to any server. Tried:\n\(serverURLs.map { "- \($0)" }.joined(separator: "\n"))\n\nError: \(urlError.localizedDescription)"
                    throw NetworkError.serverError(message: message, responseBody: nil)
                case .notConnectedToInternet:
                    throw NetworkError.serverError(message: "No internet connection available.", responseBody: nil)
                default:
                    lastError = urlError
                    if index < serverURLs.count - 1 {
                        continue
                    }
                    throw NetworkError.serverError(message: "Network error: \(urlError.localizedDescription)", responseBody: nil)
                }
            } catch {
                Log.error("❌ Network request failed: \(error.localizedDescription)", category: "Network")
                lastError = error
                if index < serverURLs.count - 1 {
                    continue
                }
                throw NetworkError.connectionFailed
            }
        }
        
        // All servers failed
        Task { @MainActor in connectionStatusManager.markRequestFailed(error: "Failed to connect to server", isCritical: true) }

        if let lastError = lastError {
            throw lastError
        }
        throw NetworkError.connectionFailed
    }
}

// MARK: - Response Types

/// Server response format for auth endpoints
struct AuthResponse: Codable {
    let userId: String
    let accessToken: String
    let refreshToken: String
    let expiresAt: Int64?      // Old format: Unix timestamp
    let expiresIn: Int?        // New format: Seconds from now
    
    // ✅ At least one must be present
    // expiresAt = Unix timestamp (1738227600)
    // expiresIn = Seconds (3600 = 1 hour)
}

/// Empty response for endpoints that return no data
struct EmptyResponse: Codable {
    init() {}
}

/// Error response from server
struct ErrorResponse: Codable {
    let code: String?
    let error: String?
    let message: String?
}

/// Response from username availability endpoint
struct UsernameAvailabilityResponse: Decodable {
    let available: Bool

    enum CodingKeys: String, CodingKey {
        case available
        case isAvailable
        case exists
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try container.decodeIfPresent(Bool.self, forKey: .available) {
            available = value
            return
        }
        if let value = try container.decodeIfPresent(Bool.self, forKey: .isAvailable) {
            available = value
            return
        }
        if let exists = try container.decodeIfPresent(Bool.self, forKey: .exists) {
            available = !exists
            return
        }
        throw DecodingError.keyNotFound(
            CodingKeys.available,
            DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "No availability field found")
        )
    }
}

// MARK: - Messaging Response Types

/// Response from sending a message
struct SendMessageResponse: Codable {
    let messageId: String
    let status: String

    enum CodingKeys: String, CodingKey {
        case messageId = "messageId"  // Server uses camelCase
        case status
    }
}

/// Response from polling messages
struct PollMessagesResponse: Codable {
    let messages: [ChatMessageResponse]
    let nextSince: String?
    let hasMore: Bool?
    
    enum CodingKeys: String, CodingKey {
        case messages
        case nextSince  // Server sends camelCase
        case hasMore    // Server sends camelCase
    }
    
    func toChatMessages() throws -> [ChatMessage] {
        try messages.map { try $0.toChatMessage() }
    }
}

/// Chat message in REST API response format
struct ChatMessageResponse: Codable {
    let id: String
    let from: String
    let to: String
    let messageType: String?  // ← NEW: "CONTROL_MESSAGE" | "DIRECT_MESSAGE"
    let ephemeralPublicKey: String?
    let messageNumber: UInt32?
    let content: String
    let suiteId: UInt16
    let timestamp: UInt64
    
    enum CodingKeys: String, CodingKey {
        case id, from, to, content, suiteId, timestamp
        case messageType = "messageType"
        case ephemeralPublicKey = "ephemeralPublicKey"
        case messageNumber = "messageNumber"
    }
    
    var isControlMessage: Bool {
        messageType == "CONTROL_MESSAGE"
    }
    
    func toChatMessage() throws -> ChatMessage {
        let ephemeralKeyData: Data
        if let ephemeralKeyString = ephemeralPublicKey, !ephemeralKeyString.isEmpty {
            guard let keyData = Data(base64Encoded: ephemeralKeyString) else {
                Log.error("❌ Failed to decode ephemeralPublicKey from base64", category: "Network")
                throw NetworkError.decodingFailed
            }
            ephemeralKeyData = keyData
        } else {
            // Control messages or legacy messages may not have ephemeralPublicKey
            ephemeralKeyData = Data()
            if isControlMessage {
                Log.debug("ℹ️ Control message has no ephemeralPublicKey (expected)", category: "Network")
            } else {
                Log.debug("ℹ️ Message has no ephemeralPublicKey, using empty data", category: "Network")
            }
        }
        
        return ChatMessage(
            id: id,
            from: from,
            to: to,
            messageType: messageType,  // ← NEW: Pass messageType
            ephemeralPublicKey: ephemeralKeyData,
            messageNumber: messageNumber ?? 0,
            content: content,
            suiteId: suiteId,
            timestamp: timestamp
        )
    }
}

/// Response from sending END_SESSION control message
struct EndSessionResponse: Codable {
    let status: String
    let messageId: String
    let type: String
    
    enum CodingKeys: String, CodingKey {
        case status
        case messageId  // Server sends camelCase
        case type
    }
}

// MARK: - Key Management Response Types

/// Response from getting public key - API returns array: [KeyBundle, username]
struct PublicKeyBundleArrayResponse: Codable {
    let keyBundle: KeyBundleObject
    let username: String
    let verifyingKey: String

    init(from decoder: Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: CodingKeys.self) {
            self.keyBundle = try keyed.decode(KeyBundleObject.self, forKey: .keyBundle)
            self.username = try keyed.decode(String.self, forKey: .username)
            self.verifyingKey = try keyed.decode(String.self, forKey: .verifyingKey)
            return
        }

        var container = try decoder.unkeyedContainer()
        self.keyBundle = try container.decode(KeyBundleObject.self)
        self.username = try container.decode(String.self)
        self.verifyingKey = self.keyBundle.masterIdentityKey
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keyBundle, forKey: .keyBundle)
        try container.encode(username, forKey: .username)
        try container.encode(verifyingKey, forKey: .verifyingKey)
    }

    private enum CodingKeys: String, CodingKey {
        case keyBundle
        case username
        case verifyingKey
    }
}

/// Key bundle object from API response
struct KeyBundleObject: Codable {
    let bundleData: String?
    let masterIdentityKey: String
    let signature: String
}

/// Decoded content from bundleData
struct KeyBundleContent: Codable {
    let userId: String
    let timestamp: String
    let supportedSuites: [KeyBundleSuite]
}

/// Suite data inside bundleData
struct KeyBundleSuite: Codable {
    let suiteId: Int
    let identityKey: String
    let signedPrekey: String
    let signedPrekeySignature: String
}

// MARK: - Media Response Types

// MARK: - Push Notifications Response Types

/// Response from device token registration
struct DeviceTokenResponse: Codable {
    let success: Bool
    let message: String?
}
