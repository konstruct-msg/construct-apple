//
//  BackupEncryption.swift
//  Construct Messenger
//
//  Provides encryption/decryption for secure backups
//  Uses AES-256-GCM with PBKDF2 key derivation
//

import Foundation
import CryptoKit
import CommonCrypto

// MARK: - Backup Encryption Error
enum BackupEncryptionError: LocalizedError {
    case invalidPassword
    case encryptionFailed
    case decryptionFailed
    case invalidBackupFormat
    case keyDerivationFailed
    case dataCorrupted

    var errorDescription: String? {
        switch self {
        case .invalidPassword:
            return "Invalid password or corrupted backup"
        case .encryptionFailed:
            return "Failed to encrypt backup data"
        case .decryptionFailed:
            return "Failed to decrypt backup data"
        case .invalidBackupFormat:
            return "Invalid backup file format"
        case .keyDerivationFailed:
            return "Failed to derive encryption key"
        case .dataCorrupted:
            return "Backup data is corrupted or tampered"
        }
    }
}

// MARK: - Backup Encryption
struct BackupEncryption {

    // MARK: - Constants
    private static let kdfIterations: Int = 100_000  // PBKDF2 iterations (100k is reasonable for mobile)
    private static let saltLength: Int = 32  // 256-bit salt
    private static let keyLength: Int = 32   // 256-bit key for AES-256

    // MARK: - Encryption

    /// Encrypts data with a password
    /// - Parameters:
    ///   - data: Data to encrypt
    ///   - password: User's master password
    /// - Returns: Encrypted backup blob with metadata
    /// - Throws: BackupEncryptionError if encryption fails
    static func encrypt(data: Data, password: String) throws -> EncryptedBackup {
        // Generate random salt
        let salt = generateRandomBytes(count: saltLength)

        // Derive encryption key from password
        guard let key = deriveKey(from: password, salt: salt) else {
            throw BackupEncryptionError.keyDerivationFailed
        }

        // Compress data before encryption (saves space)
        let compressedData = try compress(data)

        // Encrypt using AES-256-GCM
        let symmetricKey = SymmetricKey(data: key)
        let nonce = AES.GCM.Nonce()

        guard let sealedBox = try? AES.GCM.seal(compressedData, using: symmetricKey, nonce: nonce) else {
            throw BackupEncryptionError.encryptionFailed
        }

        // Create encrypted backup structure
        let encryptedBackup = EncryptedBackup(
            version: "1.0",
            timestamp: Date().timeIntervalSince1970,
            algorithm: "AES-256-GCM",
            kdfType: "PBKDF2-HMAC-SHA256",
            kdfIterations: kdfIterations,
            salt: salt,
            nonce: Data(nonce),
            ciphertext: sealedBox.ciphertext,
            tag: sealedBox.tag
        )

        return encryptedBackup
    }

    /// Decrypts an encrypted backup
    /// - Parameters:
    ///   - backup: Encrypted backup data
    ///   - password: User's master password
    /// - Returns: Decrypted plaintext data
    /// - Throws: BackupEncryptionError if decryption fails
    static func decrypt(backup: EncryptedBackup, password: String) throws -> Data {
        // Derive decryption key from password and salt
        guard let key = deriveKey(from: password, salt: backup.salt) else {
            throw BackupEncryptionError.keyDerivationFailed
        }

        // Reconstruct sealed box
        let symmetricKey = SymmetricKey(data: key)
        guard let nonce = try? AES.GCM.Nonce(data: backup.nonce) else {
            throw BackupEncryptionError.invalidBackupFormat
        }

        guard let sealedBox = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: backup.ciphertext, tag: backup.tag) else {
            throw BackupEncryptionError.invalidBackupFormat
        }

        // Decrypt
        guard let compressedData = try? AES.GCM.open(sealedBox, using: symmetricKey) else {
            throw BackupEncryptionError.invalidPassword
        }

        // Decompress
        let plaintext = try decompress(compressedData)

        return plaintext
    }

    // MARK: - Key Derivation

    /// Derives a cryptographic key from password using PBKDF2
    /// - Parameters:
    ///   - password: User's password
    ///   - salt: Random salt
    /// - Returns: Derived key or nil if derivation fails
    private static func deriveKey(from password: String, salt: Data) -> Data? {
        guard let passwordData = password.data(using: .utf8) else {
            return nil
        }

        var derivedKey = Data(repeating: 0, count: keyLength)

        let result = derivedKey.withUnsafeMutableBytes { derivedKeyBytes in
            salt.withUnsafeBytes { saltBytes in
                passwordData.withUnsafeBytes { passwordBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                        passwordData.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(kdfIterations),
                        derivedKeyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        keyLength
                    )
                }
            }
        }

        return result == kCCSuccess ? derivedKey : nil
    }

    // MARK: - Compression

    /// Compresses data using zlib
    private static func compress(_ data: Data) throws -> Data {
        return try (data as NSData).compressed(using: .zlib) as Data
    }

    /// Decompresses data using zlib
    private static func decompress(_ data: Data) throws -> Data {
        return try (data as NSData).decompressed(using: .zlib) as Data
    }

    // MARK: - Random Generation

    /// Generates cryptographically secure random bytes
    private static func generateRandomBytes(count: Int) -> Data {
        var bytes = Data(count: count)
        _ = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        return bytes
    }
}

// MARK: - Encrypted Backup Model
struct EncryptedBackup: Codable {
    let version: String
    let timestamp: TimeInterval
    let algorithm: String
    let kdfType: String
    let kdfIterations: Int
    let salt: Data
    let nonce: Data
    let ciphertext: Data
    let tag: Data

    // Metadata (not encrypted, for info)
    var metadata: BackupMetadata?

    enum CodingKeys: String, CodingKey {
        case version, timestamp, algorithm
        case kdfType = "kdf_type"
        case kdfIterations = "kdf_iterations"
        case salt, nonce, ciphertext, tag, metadata
    }
}

// MARK: - Backup Metadata
struct BackupMetadata: Codable {
    let deviceModel: String
    let appVersion: String
    let messageCount: Int?
    let backupSizeBytes: Int64?

    static var current: BackupMetadata {
        return BackupMetadata(
            deviceModel: DeviceInfo.deviceModel,
            appVersion: AppConstants.appVersion,
            messageCount: nil,
            backupSizeBytes: nil
        )
    }
}
