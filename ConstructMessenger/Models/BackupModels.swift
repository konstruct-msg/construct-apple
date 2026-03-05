//
//  BackupModels.swift
//  Construct Messenger
//
//  Data models for encrypted backups
//

import Foundation

// MARK: - Backup Content
/// Complete backup of user account and data
struct BackupContent: Codable {
    let version: String = "1.0"
    let createdAt: Date
    let account: AccountBackup
    let cryptoKeys: CryptoKeysBackup
    let sessions: [SessionBackup]
    let messages: [MessageBackup]?  // Optional, can be large
    let settings: AppSettingsBackup

    enum CodingKeys: String, CodingKey {
        case version
        case createdAt = "created_at"
        case account, cryptoKeys = "crypto_keys"
        case sessions, messages, settings
    }
}

// MARK: - Account Backup
struct AccountBackup: Codable {
    let userId: String
    let username: String
    let sessionToken: String?
    let serverURL: String?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case username
        case sessionToken = "session_token"
        case serverURL = "server_url"
    }
}

// MARK: - Crypto Keys Backup
struct CryptoKeysBackup: Codable {
    // These are exported from CryptoCore (Rust)
    let identitySecret: String  // Base64
    let signingSecret: String   // Base64
    let signedPrekeySecret: String  // Base64
    let prekeySignature: String  // Base64
    let suiteId: String

    enum CodingKeys: String, CodingKey {
        case identitySecret = "identity_secret"
        case signingSecret = "signing_secret"
        case signedPrekeySecret = "signed_prekey_secret"
        case prekeySignature = "prekey_signature"
        case suiteId = "suite_id"
    }
}

// MARK: - Session Backup
struct SessionBackup: Codable {
    let contactId: String
    let sessionJson: String  // Serialized DoubleRatchet session from Rust

    enum CodingKeys: String, CodingKey {
        case contactId = "contact_id"
        case sessionJson = "session_json"
    }
}

// MARK: - Message Backup
struct MessageBackup: Codable {
    let id: String
    let chatId: String
    let fromUserId: String
    let toUserId: String
    let content: String  // Decrypted text
    let timestamp: Date
    let isSentByMe: Bool
    let status: String  // MessageStatus rawValue

    enum CodingKeys: String, CodingKey {
        case id
        case chatId = "chat_id"
        case fromUserId = "from_user_id"
        case toUserId = "to_user_id"
        case content, timestamp
        case isSentByMe = "is_sent_by_me"
        case status
    }
}

// MARK: - App Settings Backup
struct AppSettingsBackup: Codable {
    let theme: String?
    let notificationsEnabled: Bool
    let backgroundFetchEnabled: Bool
    let trafficProtectionEnabled: Bool?  // Only in Debug

    enum CodingKeys: String, CodingKey {
        case theme
        case notificationsEnabled = "notifications_enabled"
        case backgroundFetchEnabled = "background_fetch_enabled"
        case trafficProtectionEnabled = "traffic_protection_enabled"
    }
}

// MARK: - Backup Manager Protocol
protocol BackupManagerProtocol {
    /// Creates a backup of all user data
    func createBackup(includeMessages: Bool) async throws -> BackupContent

    /// Exports backup as encrypted file
    func exportBackup(content: BackupContent, password: String) async throws -> URL

    /// Restores backup from encrypted file
    func restoreBackup(from fileURL: URL, password: String) async throws -> BackupContent

    /// Saves backup to iCloud
    func saveToiCloud(backup: BackupContent) async throws

    /// Loads backup from iCloud
    func loadFromiCloud() async throws -> BackupContent?

    /// Deletes all backups from iCloud
    func deleteFromiCloud() async throws
}
