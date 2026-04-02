//
//  KeychainManager.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import Security
import Foundation

class KeychainManager {
    static let shared = KeychainManager()
    private init() {}

    // MARK: - Session Token
    func saveSessionToken(_ token: String) {
        guard let data = token.data(using: .utf8) else {
            Log.error("Failed to convert token to UTF-8 data", category: "Keychain")
            return
        }
        let success = save(data, forKey: APIConstants.sessionTokenKey, accessible: kSecAttrAccessibleAfterFirstUnlock)
        if !success {
            Log.error("Failed to save session token to Keychain", category: "Keychain")
        } else {
            Log.info("✅ Session token saved to Keychain (length: \(token.count))", category: "Keychain")
        }
    }

    func loadSessionToken() -> String? {
        guard let data = load(forKey: APIConstants.sessionTokenKey) else {
            Log.debug("No session token found in Keychain", category: "Keychain")
            return nil
        }
        guard let token = String(data: data, encoding: .utf8) else {
            Log.error("Failed to convert Keychain data to UTF-8 string", category: "Keychain")
            return nil
        }
        Log.debug("✅ Session token loaded from Keychain (length: \(token.count), prefix: \(token.prefix(30))...)", category: "Keychain")
        return token
    }

    func deleteSessionToken() {
        delete(forKey: APIConstants.sessionTokenKey)
    }
    
    // MARK: - Device-Based Auth Keys
    
    /// Save device ID (16 hex characters)
    func saveDeviceID(_ deviceId: String) {
        guard let data = deviceId.data(using: .utf8) else {
            Log.error("Failed to convert deviceId to UTF-8", category: "Keychain")
            return
        }
        let success = save(data, forKey: "deviceId", accessible: kSecAttrAccessibleAfterFirstUnlock)
        if success {
            Log.info("✅ Device ID saved to Keychain", category: "Keychain")
        }
    }
    
    /// Load device ID
    func loadDeviceID() -> String? {
        guard let data = load(forKey: "deviceId") else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
    
    /// Save device signing key (Ed25519 private key, 32 bytes)
    func saveDeviceSigningKey(_ key: Data) {
        let success = save(key, forKey: "deviceSigningKey", accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
        if success {
            Log.info("✅ Device signing key saved to Keychain", category: "Keychain")
        }
    }
    
    /// Load device signing key
    func loadDeviceSigningKey() -> Data? {
        return load(forKey: "deviceSigningKey")
    }
    
    /// Save device identity key (for E2EE)
    func saveDeviceIdentityKey(_ key: Data) {
        let success = save(key, forKey: "deviceIdentityKey", accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
        if success {
            Log.info("✅ Device identity key saved to Keychain", category: "Keychain")
        }
    }
    
    /// Load device identity key
    func loadDeviceIdentityKey() -> Data? {
        return load(forKey: "deviceIdentityKey")
    }
    
    /// Check if device is registered (has device ID and keys)
    func isDeviceRegistered() -> Bool {
        let deviceId = loadDeviceID()
        let signingKey = loadDeviceSigningKey()
        let identityKey = loadDeviceIdentityKey()
        
        let hasKeys = deviceId != nil && signingKey != nil && identityKey != nil
        
        if hasKeys {
            Log.debug("✅ Device keys found in Keychain", category: "Keychain")
            Log.debug("   deviceId: \(deviceId!.prefix(16))...", category: "Keychain")
            Log.debug("   signingKey: \(signingKey!.count) bytes", category: "Keychain")
            Log.debug("   identityKey: \(identityKey!.count) bytes", category: "Keychain")
        } else {
            Log.debug("❌ No device keys in Keychain", category: "Keychain")
            Log.debug("   deviceId: \(deviceId != nil ? "✓" : "✗")", category: "Keychain")
            Log.debug("   signingKey: \(signingKey != nil ? "✓" : "✗")", category: "Keychain")
            Log.debug("   identityKey: \(identityKey != nil ? "✓" : "✗")", category: "Keychain")
        }
        
        return hasKeys
    }
    
    /// Delete all device keys (for logout/reset)
    func deleteDeviceKeys() {
        delete(forKey: "deviceId")
        delete(forKey: "deviceSigningKey")
        delete(forKey: "deviceIdentityKey")
        Log.info("🗑️ Device keys deleted from Keychain", category: "Keychain")
    }
    
    // MARK: - User ID (from server)
    
    /// Save user ID from server (UUID)
    func saveUserID(_ userId: String) {
        guard let data = userId.data(using: .utf8) else {
            Log.error("Failed to convert userId to UTF-8 data", category: "Keychain")
            return
        }
        let success = save(data, forKey: "userId", accessible: kSecAttrAccessibleAfterFirstUnlock)
        if !success {
            Log.error("Failed to save userId to Keychain", category: "Keychain")
        } else {
            Log.info("✅ User ID saved to Keychain: \(userId.prefix(8))...", category: "Keychain")
        }
    }
    
    /// Load user ID from Keychain
    func loadUserID() -> String? {
        guard let data = load(forKey: "userId") else {
            Log.debug("No userId found in Keychain", category: "Keychain")
            return nil
        }
        guard let userId = String(data: data, encoding: .utf8) else {
            Log.error("Failed to convert userId data to string", category: "Keychain")
            return nil
        }
        Log.debug("✅ User ID loaded from Keychain: \(userId.prefix(8))...", category: "Keychain")
        return userId
    }
    
    /// Delete user ID from Keychain
    func deleteUserID() {
        delete(forKey: "userId")
        Log.info("🗑️ User ID deleted from Keychain", category: "Keychain")
    }
    
    // MARK: - Refresh Token
    
    func saveRefreshToken(_ token: String) {
        guard let data = token.data(using: .utf8) else {
            Log.error("Failed to convert refresh token to UTF-8 data", category: "Keychain")
            return
        }
        let success = save(data, forKey: "com.construct.refreshToken", accessible: kSecAttrAccessibleAfterFirstUnlock)
        if !success {
            Log.error("Failed to save refresh token to Keychain", category: "Keychain")
        } else {
            Log.info("✅ Refresh token saved to Keychain (length: \(token.count))", category: "Keychain")
        }
    }
    
    func loadRefreshToken() -> String? {
        guard let data = load(forKey: "com.construct.refreshToken") else {
            Log.debug("No refresh token found in Keychain", category: "Keychain")
            return nil
        }
        guard let token = String(data: data, encoding: .utf8) else {
            Log.error("Failed to convert refresh token Keychain data to UTF-8 string", category: "Keychain")
            return nil
        }
        Log.debug("✅ Refresh token loaded from Keychain (length: \(token.count))", category: "Keychain")
        return token
    }
    
    func deleteRefreshToken() {
        delete(forKey: "com.construct.refreshToken")
        Log.info("🗑️ Refresh token deleted from Keychain", category: "Keychain")
    }

    // MARK: - Private Key
    func savePrivateKey(_ keyData: Data) {
        let success = save(keyData, forKey: APIConstants.privateKeyKey, accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
        if !success {
            Log.error("Failed to save private key to Keychain", category: "Keychain")
        }
    }

    func loadPrivateKey() -> Data? {
        load(forKey: APIConstants.privateKeyKey)
    }
    
    func saveIdentityKey(_ data: Data) -> Bool {
        return save(data, forKey: "identity_key", accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
    }
    
    func loadIdentityKey() -> Data? {
        return load(forKey: "identity_key")
    }
    
    // Signed prekey (X25519)
    func saveSignedPrekey(_ data: Data) -> Bool {
        return save(data, forKey: "signed_prekey", accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
    }
    
    func loadSignedPrekey() -> Data? {
        return load(forKey: "signed_prekey")
    }
    
    // Signing key (Ed25519)
    func saveSigningKey(_ data: Data) -> Bool {
        return save(data, forKey: "signing_key", accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
    }
    
    func loadSigningKey() -> Data? {
        return load(forKey: "signing_key")
    }

    // MARK: - Private Keys JSON (for Rust persistence)

    /// Save all private keys as JSON string (from Rust export)
    func savePrivateKeysJson(_ jsonString: String) -> Bool {
        guard let data = jsonString.data(using: .utf8) else { return false }
        return save(data, forKey: "crypto_private_keys_json", accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
    }

    /// Load private keys JSON string (for Rust import)
    func loadPrivateKeysJson() -> String? {
        guard let data = load(forKey: "crypto_private_keys_json") else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Delete private keys JSON
    func deletePrivateKeysJson() {
        delete(forKey: "crypto_private_keys_json")
    }

    // CFE binary variants — use the SAME Keychain key for transparent migration.
    // Rust's importPrivateKeys() handles both CFE binary and legacy JSON automatically.

    /// Save private keys in CFE binary format.
    @discardableResult
    func savePrivateKeys(_ data: Data) -> Bool {
        return save(data, forKey: "crypto_private_keys_json", accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
    }

    /// Load raw private key bytes (CFE or legacy JSON) — format detection done in Rust.
    func loadPrivateKeysData() -> Data? {
        return load(forKey: "crypto_private_keys_json")
    }

    // MARK: - One-Time Prekeys (OTPK) persistence

    /// Persist the OTPK set (JSON from Rust exportOneTimePrekeysJson) so it survives app restarts.
    @discardableResult
    func saveOtpksJson(_ jsonString: String) -> Bool {
        guard let data = jsonString.data(using: .utf8) else { return false }
        return save(data, forKey: "crypto_otpks_json", accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
    }

    /// Load the persisted OTPK set JSON (nil if not yet saved).
    func loadOtpksJson() -> String? {
        guard let data = load(forKey: "crypto_otpks_json") else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Delete the OTPK set (call when replacing all keys on server).
    func deleteOtpksJson() {
        delete(forKey: "crypto_otpks_json")
    }

    // CFE binary variants — same Keychain key, format detection in Rust.

    /// Save OTPKs in CFE binary format.
    @discardableResult
    func saveOtpks(_ data: Data) -> Bool {
        return save(data, forKey: "crypto_otpks_json", accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
    }

    /// Load raw OTPK bytes (CFE or legacy JSON).
    func loadOtpksData() -> Data? {
        return load(forKey: "crypto_otpks_json")
    }
    func saveCustomServerURL(_ url: String) {
        guard let data = url.data(using: .utf8) else { return }
        // Use kSecAttrAccessibleAfterFirstUnlock to allow access after device unlock
        // This persists across app reinstalls when iCloud Keychain is enabled
        let success = save(data, forKey: APIConstants.customServerURLKey, accessible: kSecAttrAccessibleAfterFirstUnlock)
        if !success {
            Log.error("Failed to save custom server URL to Keychain", category: "Keychain")
        }
    }
    
    func loadCustomServerURL() -> String? {
        guard let data = load(forKey: APIConstants.customServerURLKey) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    
    func deleteCustomServerURL() {
        delete(forKey: APIConstants.customServerURLKey)
    }

    // MARK: - ICE Bridge Cert

    private let iceBridgeCertKey = "ice_bridge_cert"

    /// Save the ICE bridge cert (obfs4 server identity) to Keychain.
    /// Stored with `AfterFirstUnlock` so it survives device restarts.
    func saveIceBridgeCert(_ cert: String) {
        guard let data = cert.data(using: .utf8) else { return }
        let ok = save(data, forKey: iceBridgeCertKey, accessible: kSecAttrAccessibleAfterFirstUnlock)
        if !ok { Log.error("Failed to save ICE bridge cert to Keychain", category: "Keychain") }
    }

    /// Load the ICE bridge cert from Keychain. Returns nil if not yet stored.
    func loadIceBridgeCert() -> String? {
        guard let data = load(forKey: iceBridgeCertKey) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func deleteIceBridgeCert() {
        delete(forKey: iceBridgeCertKey)
    }
    
    func deleteAllKeys() {
        delete(forKey: "identity_key")
        delete(forKey: "signed_prekey")
        delete(forKey: "signing_key")
        delete(forKey: "userId")
        deletePrivateKeysJson()
        deleteAllSessions()
        Log.info("🗑️ All cryptographic keys and sessions deleted", category: "Keychain")
    }
    
    /// Delete all saved sessions (sessions are stored with keys like "session_<contactId>")
    /// Note: Keychain doesn't provide a way to list keys, so we delete by pattern
    /// This is called during account deletion to ensure clean state
    private func deleteAllSessions() {
        // Since we can't enumerate Keychain keys, we'll delete all items with kSecClass = kSecClassGenericPassword
        // and service matching our bundle identifier with "session_" prefix
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Bundle.main.bundleIdentifier ?? "dev.construct.messenger"
        ]
        
        // Get all items
        let queryWithReturnData = query.merging([
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]) { $1 }
        
        var result: AnyObject?
        let status = SecItemCopyMatching(queryWithReturnData as CFDictionary, &result)
        
        if status == errSecSuccess, let items = result as? [[String: Any]] {
            var deletedCount = 0
            for item in items {
                if let account = item[kSecAttrAccount as String] as? String,
                   account.hasPrefix("session_") {
                    delete(forKey: account)
                    deletedCount += 1
                }
            }
            if deletedCount > 0 {
                Log.info("🗑️ Deleted \(deletedCount) session(s) from Keychain", category: "Keychain")
            }
        }
    }

    // MARK: - Session Persistence

    /// Save a session JSON string for a specific contact
    /// - Parameters:
    ///   - sessionJson: JSON string of the serialized session
    ///   - contactId: The contact/user ID this session belongs to
    /// - Returns: true if saved successfully
    func saveSessionJson(_ sessionJson: String, for contactId: String) -> Bool {
        guard let data = sessionJson.data(using: .utf8) else { return false }
        let key = "session_\(contactId)"
        return save(data, forKey: key, accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
    }

    /// Load a session JSON string for a specific contact
    /// - Parameter contactId: The contact/user ID
    /// - Returns: JSON string of the serialized session, or nil if not found
    func loadSessionJson(for contactId: String) -> String? {
        let key = "session_\(contactId)"
        guard let data = load(forKey: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Save session in CFE binary format (same Keychain key — format detection in Rust).
    @discardableResult
    func saveSessionData(_ data: Data, for contactId: String) -> Bool {
        let key = "session_\(contactId)"
        // AfterFirstUnlockThisDeviceOnly: accessible in background after first unlock
        // (needed so incoming push notifications can decrypt messages while screen is locked).
        return save(data, forKey: key, accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
    }

    /// Load raw session bytes (CFE or legacy JSON).
    func loadSessionData(for contactId: String) -> Data? {
        let key = "session_\(contactId)"
        return load(forKey: key)
    }

    /// Delete a session for a specific contact
    /// - Parameter contactId: The contact/user ID
    func deleteSession(for contactId: String) {
        let key = "session_\(contactId)"
        delete(forKey: key)
    }

    /// Load all saved session IDs
    /// - Returns: Array of contact IDs that have saved sessions
    func loadAllSessionIds() -> [String] {
        // Note: Keychain doesn't have a direct way to list all keys
        // We'll need to track session IDs separately or use a different approach
        // For now, return empty array - we'll track sessions in Core Data
        return []
    }
    
    // MARK: - Generic Data Storage (for archived sessions, etc.)
    
    /// Save generic data to Keychain
    func saveData(_ data: Data, forKey key: String) -> Bool {
        return save(data, forKey: key, accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
    }
    
    /// Load generic data from Keychain
    func loadData(forKey key: String) -> Data? {
        return load(forKey: key)
    }
    
    /// Delete generic data from Keychain
    func deleteData(forKey key: String) {
        delete(forKey: key)
    }

    // MARK: - Generic Helpers
    private func save(_ data: Data, forKey key: String, accessible: CFString) -> Bool {
        guard !data.isEmpty else {
            // Treat empty-data saves as deletes to avoid silent Keychain corruption.
            delete(forKey: key)
            return true
        }

        let searchQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessible
        ]

        let updateStatus = SecItemUpdate(searchQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = searchQuery
            addQuery.merge(attributes) { $1 }
            return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
        }
        return updateStatus == errSecSuccess
    }

    private func load(forKey key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, !data.isEmpty else {
            return nil
        }
        return data
    }

    private func delete(forKey key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
