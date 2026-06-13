//
//  CryptoTypes.swift
//  Construct Messenger
//

import Foundation

/// CryptoManager-specific errors (wraps UniFFI CryptoError)
enum CryptoManagerError: Error, LocalizedError, ApplicationLayerError {
    case coreNotInitialized
    case sessionNotFound
    case sessionInitializationFailed
    case encryptionFailed
    case decryptionFailed
    case invalidCiphertext
    case invalidKeyData
    /// Message was already processed by the foreground stream (in-memory ACK cache hit).
    /// The DR state has advanced past this message — attempting decryption would fail and
    /// incorrectly archive the healthy session. Callers should skip silently.
    case duplicateMessage
    /// Kyber OTPK secret is missing locally for the given key ID.
    /// Throwing this forces session init to fail, which triggers END_SESSION + clean re-init
    /// instead of silently establishing a PQ-diverged session that will break on msg1+.
    case pqxdhOtpkMissing(UInt32)
    case invalidSignature
    /// DR decryption failed in the background path. Session is NOT archived — the
    /// foreground stream will handle recovery when the app becomes active.
    case decryptionFailedNoArchive(reason: String)

    var errorDescription: String? {
        switch self {
        case .coreNotInitialized:                    return "Crypto core is not initialized"
        case .sessionNotFound:                       return "No session found for this user"
        case .sessionInitializationFailed:           return "Failed to initialize session"
        case .encryptionFailed:                      return "Failed to encrypt message"
        case .decryptionFailed:                      return "Failed to decrypt message"
        case .invalidCiphertext:                     return "Invalid ciphertext format"
        case .invalidKeyData:                        return "Invalid key data"
        case .duplicateMessage:                      return "Message already processed (ACK cache hit) — skipped to protect DR state"
        case .pqxdhOtpkMissing(let id):             return "Kyber OTPK id=\(id) not found locally — session init failed to prevent PQ root key divergence"
        case .invalidSignature:                      return "Invalid signature data from Rust core (expected base64)"
        case .decryptionFailedNoArchive(let reason): return "BG decrypt failed (session preserved): \(reason)"
        }
    }
}

/// Result of decrypting a message at the CryptoManager level.
/// `storageKey` is a 32-byte random key that the caller must store in `MessageKeyStore`
/// keyed by the message's persistent ID. Once MessageKeyStore is implemented (Phase 2),
/// callers use `storageKey` to re-encrypt `plaintext` at rest; until then it is discarded.
struct MessageDecryptResult {
    let plaintext: Data
    let storageKey: Data

    /// True only when decryption succeeded with an archived session — in that case
    /// a fresh storage key was NOT generated (no DR message key consumed).
    var isArchivedSessionDecrypt: Bool { storageKey.isEmpty }
}

/// Per-message result from `CryptoManager.decryptOfflineBatch`.
struct OfflineBatchDecryptResult {
    let message: ChatMessage
    let plaintext: Data?   // non-nil on success
    let error: Error?      // non-nil on failure; session is NOT archived
    let storageKey: Data   // 32-byte key; empty when error is non-nil
    var succeeded: Bool { plaintext != nil }
}
