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
        guard let data = token.data(using: .utf8) else { return }
        save(data, forKey: APIConstants.sessionTokenKey, accessible: kSecAttrAccessibleAfterFirstUnlock)
    }

    func loadSessionToken() -> String? {
        guard let data = load(forKey: APIConstants.sessionTokenKey) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func deleteSessionToken() {
        delete(forKey: APIConstants.sessionTokenKey)
    }

    // MARK: - Private Key
    func savePrivateKey(_ keyData: Data) {
        save(keyData, forKey: APIConstants.privateKeyKey, accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
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

    // MARK: - User ID
    func saveUserId(_ userId: String) {
        guard let data = userId.data(using: .utf8) else { return }
        save(data, forKey: APIConstants.userIdKey, accessible: kSecAttrAccessibleAfterFirstUnlock)
    }

    func loadUserId() -> String? {
        guard let data = load(forKey: APIConstants.userIdKey) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    
    // MARK: - Username (for autofill convenience)
    // Note: We don't save passwords in Keychain - iOS Password AutoFill handles that securely
    func saveLastUsername(_ username: String) {
        guard let data = username.data(using: .utf8) else { return }
        save(data, forKey: APIConstants.lastUsernameKey, accessible: kSecAttrAccessibleAfterFirstUnlock)
    }
    
    func loadLastUsername() -> String? {
        guard let data = load(forKey: APIConstants.lastUsernameKey) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    
    func deleteLastUsername() {
        delete(forKey: APIConstants.lastUsernameKey)
    }
    
    func deleteAllKeys() {
        delete(forKey: "identity_key")
        delete(forKey: "signed_prekey")
        delete(forKey: "signing_key")
    }

    // MARK: - Generic Helpers
    private func save(_ data: Data, forKey key: String, accessible: CFString) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessible
        ]

        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    private func load(forKey key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return status == errSecSuccess ? result as? Data : nil
    }

    private func delete(forKey key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
