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
            Log.info("Session token saved to Keychain (length: \(token.count))", category: "Keychain")
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
        Log.debug("Session token loaded from Keychain (length: \(token.count), prefix: \(token.prefix(30))...)", category: "Keychain")
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
            Log.info("Device ID saved to Keychain", category: "Keychain")
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
            Log.info("Device signing key saved to Keychain", category: "Keychain")
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
            Log.info("Device identity key saved to Keychain", category: "Keychain")
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
            Log.debug("Device keys found in Keychain", category: "Keychain")
            Log.debug("deviceId: \(deviceId?.prefix(16) ?? "<nil>")...", category: "Keychain")
            Log.debug("signingKey: \(signingKey?.count ?? 0) bytes", category: "Keychain")
            Log.debug("identityKey: \(identityKey?.count ?? 0) bytes", category: "Keychain")
        } else {
            Log.debug("No device keys in Keychain", category: "Keychain")
            Log.debug("deviceId: \(deviceId != nil ? "✓" : "✗")", category: "Keychain")
            Log.debug("signingKey: \(signingKey != nil ? "✓" : "✗")", category: "Keychain")
            Log.debug("identityKey: \(identityKey != nil ? "✓" : "✗")", category: "Keychain")
        }
        
        return hasKeys
    }
    
    /// Delete all device keys (for logout/reset)
    func deleteDeviceKeys() {
        delete(forKey: "deviceId")
        delete(forKey: "deviceSigningKey")
        delete(forKey: "deviceIdentityKey")
        Log.info("Device keys deleted from Keychain", category: "Keychain")
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
            Log.info("User ID saved to Keychain: \(userId.prefix(8))...", category: "Keychain")
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
        Log.debug("User ID loaded from Keychain: \(userId.prefix(8))...", category: "Keychain")
        return userId
    }
    
    /// Delete user ID from Keychain
    func deleteUserID() {
        delete(forKey: "userId")
        Log.info("User ID deleted from Keychain", category: "Keychain")
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
            Log.info("Refresh token saved to Keychain (length: \(token.count))", category: "Keychain")
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
        Log.debug("Refresh token loaded from Keychain (length: \(token.count))", category: "Keychain")
        return token
    }
    
    func deleteRefreshToken() {
        delete(forKey: "com.construct.refreshToken")
        Log.info("Refresh token deleted from Keychain", category: "Keychain")
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

    // Hybrid PQ identity signing private key (Ed25519 + ML-DSA-65), 2016 bytes.
    // Local-only and never transmitted; the 1984-byte public key is derived on demand.
    @discardableResult
    func saveHybridSigPrivateKey(_ data: Data) -> Bool {
        return save(data, forKey: "hybrid_sig_private_key", accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
    }

    func loadHybridSigPrivateKey() -> Data? {
        return load(forKey: "hybrid_sig_private_key")
    }

    func deleteHybridSigPrivateKey() {
        delete(forKey: "hybrid_sig_private_key")
    }

    // MARK: - Private Keys JSON (for Rust persistence)

    /// Save private keys in CFE binary format.
    @discardableResult
    func savePrivateKeys(_ data: Data) -> Bool {
        return save(data, forKey: "crypto_private_keys", accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
    }

    /// Load raw private key bytes (CFE binary).
    func loadPrivateKeysData() -> Data? {
        load(forKey: "crypto_private_keys")
    }

    /// Delete private keys CFE blob.
    func deletePrivateKeys() {
        delete(forKey: "crypto_private_keys")
    }

    // MARK: - One-Time Prekeys (OTPK) persistence

    /// Save OTPKs in CFE binary format.
    @discardableResult
    func saveOtpks(_ data: Data) -> Bool {
        return save(data, forKey: "crypto_otpks", accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
    }

    /// Load raw OTPK bytes (CFE binary).
    func loadOtpksData() -> Data? {
        load(forKey: "crypto_otpks")
    }

    /// Delete the OTPK set.
    func deleteOtpks() {
        delete(forKey: "crypto_otpks")
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

    // MARK: - VEIL Bridge Cert

    private let veilBridgeCertKey = "veil_bridge_cert"

    /// Save the VEIL bridge cert (obfs4 server identity) to Keychain.
    /// Stored with `AfterFirstUnlock` so it survives device restarts.
    func saveVEILBridgeCert(_ cert: String) {
        guard let data = cert.data(using: .utf8) else { return }
        let ok = save(data, forKey: veilBridgeCertKey, accessible: kSecAttrAccessibleAfterFirstUnlock)
        if !ok { Log.error("Failed to save VEIL bridge cert to Keychain", category: "Keychain") }
    }

    /// Load the VEIL bridge cert from Keychain. Returns nil if not yet stored.
    func loadVEILBridgeCert() -> String? {
        guard let data = load(forKey: veilBridgeCertKey) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func deleteVEILBridgeCert() {
        delete(forKey: veilBridgeCertKey)
    }
    
    func deleteAllKeys() {
        delete(forKey: "identity_key")
        delete(forKey: "signed_prekey")
        delete(forKey: "signing_key")
        delete(forKey: "userId")
        deleteHybridSigPrivateKey()
        deletePrivateKeys()
        deleteAllSessions()
        Log.info("All cryptographic keys and sessions deleted", category: "Keychain")
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
                Log.info("Deleted \(deletedCount) session(s) from Keychain", category: "Keychain")
            }
        }
    }

    // MARK: - Session Persistence

    /// Persist a Double Ratchet session as CFE binary bytes for `contactId`.
    /// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` so push-driven decrypt
    /// works while the screen is locked.
    @discardableResult
    func saveSessionData(_ data: Data, for contactId: String) -> Bool {
        let key = "session_\(contactId)"
        return save(data, forKey: key, accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
    }

    /// Load the CFE session bytes previously written by `saveSessionData`.
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
    
    /// Save generic data to Keychain.
    ///
    /// `accessible` defaults to `WhenUnlockedThisDeviceOnly`. Crypto state that must be
    /// persisted/loaded during background push-driven decrypt (the Double Ratchet
    /// orchestrator state) MUST pass `AfterFirstUnlockThisDeviceOnly` — otherwise a
    /// locked-device save fails ("Keychain write error"), the just-advanced ratchet is
    /// lost, and the session desyncs on the next launch.
    func saveData(_ data: Data, forKey key: String,
                  accessible: CFString = kSecAttrAccessibleWhenUnlockedThisDeviceOnly) -> Bool {
        return save(data, forKey: key, accessible: accessible)
    }
    
    /// Load generic data from Keychain
    func loadData(forKey key: String) -> Data? {
        return load(forKey: key)
    }
    
    /// Delete generic data from Keychain
    func deleteData(forKey key: String) {
        delete(forKey: key)
    }

    // MARK: - Session Suite ID
    // Fallback store for suiteId when the Rust in-memory session returns 0.
    // Uses kSecAttrAccessibleAfterFirstUnlock so it survives app background/restart
    // and is atomic with the rest of the Keychain — unlike UserDefaults which can be
    // cleared independently from Keychain on reinstall or data-reset.

    private func suiteIdKey(for userId: String) -> String {
        "construct.session.suite.\(userId)"
    }

    func saveSessionSuiteId(userId: String, suiteId: UInt16) {
        var value = suiteId
        let data = Data(bytes: &value, count: MemoryLayout<UInt16>.size)
        _ = save(data, forKey: suiteIdKey(for: userId), accessible: kSecAttrAccessibleAfterFirstUnlock)
    }

    func loadSessionSuiteId(userId: String) -> UInt16? {
        guard let data = load(forKey: suiteIdKey(for: userId)),
              data.count == MemoryLayout<UInt16>.size else { return nil }
        return data.withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
    }

    func deleteSessionSuiteId(userId: String) {
        delete(forKey: suiteIdKey(for: userId))
    }

    // MARK: - SPK Rotation Epoch (per-peer anti-replay)
    // Tracks the highest observed SPK rotation epoch for each peer contact.
    // Security-relevant: if this were in UserDefaults and wiped, SPK replay
    // attacks would go undetected until the peer rotates again.

    private func spkEpochKey(for userId: String) -> String {
        "construct.spk_epoch.\(userId)"
    }

    func saveSpkEpoch(_ epoch: UInt32, for userId: String) {
        var value = epoch
        let data = Data(bytes: &value, count: MemoryLayout<UInt32>.size)
        _ = save(data, forKey: spkEpochKey(for: userId), accessible: kSecAttrAccessibleAfterFirstUnlock)
    }

    func loadSpkEpoch(for userId: String) -> UInt32 {
        guard let data = load(forKey: spkEpochKey(for: userId)),
              data.count == MemoryLayout<UInt32>.size else { return 0 }
        return data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    }

    func deleteSpkEpoch(for userId: String) {
        delete(forKey: spkEpochKey(for: userId))
    }

    // MARK: - PQXDH Downgrade Flag (per-peer)
    // Tracks whether PQXDH key agreement was degraded to classical-only for a contact.
    // Security-relevant: stored in Keychain (not UserDefaults) so it survives reinstall.
    // An attacker who can clear UserDefaults before app launch could otherwise force
    // a re-attempt of PQ strengthening that already failed, leaking that it failed.

    private func pqxdhDowngradedKey(for userId: String) -> String {
        "construct.pqxdh.downgraded.\(userId)"
    }

    func savePQXDHDowngradeFlag(for userId: String) {
        var value: UInt8 = 1
        let data = Data(bytes: &value, count: 1)
        _ = save(data, forKey: pqxdhDowngradedKey(for: userId), accessible: kSecAttrAccessibleAfterFirstUnlock)
    }

    func loadPQXDHDowngradeFlag(for userId: String) -> Bool {
        guard let data = load(forKey: pqxdhDowngradedKey(for: userId)),
              data.count == 1 else { return false }
        return data[0] != 0
    }

    func deletePQXDHDowngradeFlag(for userId: String) {
        delete(forKey: pqxdhDowngradedKey(for: userId))
    }

    // MARK: - Contact Request Mappings
    //
    // Stores requestId → toUserId so User A can create a contact after acceptance.
    // Lives in Keychain (not UserDefaults) to survive app reinstall.
    // All entries stored as a single JSON-encoded [String: String] dict for easy bulk delete.

    private static let contactRequestMappingsKey = "cr_request_mappings"

    func saveContactRequestMapping(requestId: String, toUserId: String) {
        var mappings = loadAllContactRequestMappings()
        mappings[requestId] = toUserId
        persistContactRequestMappings(mappings)
    }

    func loadContactRequestMapping(requestId: String) -> String? {
        loadAllContactRequestMappings()[requestId]
    }

    func deleteContactRequestMapping(requestId: String) {
        var mappings = loadAllContactRequestMappings()
        mappings.removeValue(forKey: requestId)
        persistContactRequestMappings(mappings)
    }

    func deleteAllContactRequestMappings() {
        delete(forKey: Self.contactRequestMappingsKey)
    }

    private func loadAllContactRequestMappings() -> [String: String] {
        guard let data = loadRawData(forKey: Self.contactRequestMappingsKey),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return dict
    }

    private func persistContactRequestMappings(_ mappings: [String: String]) {
        if mappings.isEmpty {
            delete(forKey: Self.contactRequestMappingsKey)
            return
        }
        guard let data = try? JSONEncoder().encode(mappings) else { return }
        saveRawData(data, forKey: Self.contactRequestMappingsKey)
    }

    // MARK: - Generic Data Storage (for non-crypto app data that needs Keychain protection)

    @discardableResult
    func saveRawData(_ data: Data, forKey key: String) -> Bool {
        save(data, forKey: key, accessible: kSecAttrAccessibleAfterFirstUnlock)
    }

    func loadRawData(forKey key: String) -> Data? {
        load(forKey: key)
    }

    func deleteRawData(forKey key: String) {
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
