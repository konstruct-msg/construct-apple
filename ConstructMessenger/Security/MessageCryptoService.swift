//
//  MessageCryptoService.swift
//  Construct Messenger
//
//  Extracted from CryptoManager (refactor)
//  M4: Migrated from ClassicCryptoCore+SessionStore → OrchestratorCore
//

import Foundation

final class MessageCryptoService {
    struct EncryptedMessageComponents {
        let ephemeralPublicKey: Data
        let messageNumber: UInt32
        let content: Data           // raw bytes: nonce || ciphertext_with_tag (optionally padded)
        let suiteId: UInt16
        let oneTimePreKeyId: UInt32  // OTPK key_id used in X3DH (0 = no OTPK)
        let storageKey: Data         // 32-byte random key — store in MessageKeyStore keyed by message_id
    }

    struct DecryptResult {
        let plaintext: Data
        let storageKey: Data  // 32-byte random key — store in MessageKeyStore keyed by message_id
    }

    private static func suiteId(for userId: String) -> UInt16 {
        KeychainManager.shared.loadSessionSuiteId(userId: userId) ?? 0
    }

    func encryptMessage(
        _ message: String,
        for userId: String,
        core: OrchestratorCore?,
        restoreSession: (String) -> Bool,
        saveSession: (String) -> Void,
        archiveSession: (String, ArchiveReason) -> Void
    ) throws -> EncryptedMessageComponents {
        guard let core = core else {
            throw CryptoManagerError.coreNotInitialized
        }

        if !core.hasSession(contactId: userId) {
            if !restoreSession(userId) {
                throw CryptoManagerError.sessionNotFound
            }
        }

        guard core.hasSession(contactId: userId) else {
            throw CryptoManagerError.sessionNotFound
        }

        // Read suiteId from the Rust core (authoritative) — NOT UserDefaults.
        // UserDefaults can be cleared by app data reset / iCloud restore while the
        // Keychain session survives, producing suiteId=0 and a protocol mismatch.
        var suiteId = core.getSessionSuiteId(contactId: userId)
        if suiteId == 0 {
            // Rust core doesn't know the suiteId yet (session not fully loaded?) —
            // fall back to UserDefaults and log so we can investigate.
            suiteId = Self.suiteId(for: userId)
            if suiteId > 0 {
                Log.info("⚠️ ENCRYPT: suiteId from Rust=0, falling back to UserDefaults=\(suiteId) for \(userId.prefix(8))…", category: "CryptoManager")
            }
        } else {
            // Keep Keychain in sync so the fallback path stays correct.
            KeychainManager.shared.saveSessionSuiteId(userId: userId, suiteId: suiteId)
        }

        #if DEBUG
        Log.debug("🔐 ENCRYPT: Preparing to encrypt message", category: "CryptoManager")
        Log.debug("   userId: \(userId)", category: "CryptoManager")
        Log.debug("   suiteId: \(suiteId)", category: "CryptoManager")
        Log.debug("   plaintext length: \(message.count) chars", category: "CryptoManager")
        Log.debug("   plaintext preview: \(message.prefix(50))...", category: "CryptoManager")
        #endif

        do {
            let rustComponents = try core.encryptMessage(contactId: userId, plaintext: Data(message.utf8))

            #if DEBUG
            Log.debug("🔐 ENCRYPT: Rust core returned components", category: "CryptoManager")
            Log.debug("   ephemeralPublicKey: \(rustComponents.ephemeralPublicKey.count) bytes", category: "CryptoManager")
            let ephemeralPreview = rustComponents.ephemeralPublicKey.prefix(16).map { String(format: "%02x", $0) }.joined()
            Log.debug("   ephemeralPublicKey preview: \(ephemeralPreview)...", category: "CryptoManager")
            Log.debug("   messageNumber: \(rustComponents.messageNumber)", category: "CryptoManager")
            Log.debug("   oneTimePrekeyId: \(rustComponents.oneTimePrekeyId)", category: "CryptoManager")
            Log.debug("   content (before padding): \(rustComponents.content.count) bytes", category: "CryptoManager")
            #endif

            let rawContent = Data(rustComponents.content)
            let components = EncryptedMessageComponents(
                ephemeralPublicKey: Data(rustComponents.ephemeralPublicKey),
                messageNumber: rustComponents.messageNumber,
                content: MessagePadding.padCiphertext(rawContent),
                suiteId: suiteId,
                oneTimePreKeyId: rustComponents.oneTimePrekeyId,
                storageKey: Data(rustComponents.storageKey)
            )

            #if DEBUG
            Log.debug("🔐 ENCRYPT: After padding", category: "CryptoManager")
            Log.debug("   content (after padding): \(components.content.count) bytes", category: "CryptoManager")
            #endif

            saveSession(userId)
            return components
        } catch {
            throw CryptoManagerError.encryptionFailed
        }
    }

    func decryptMessage(
        _ message: ChatMessage,
        contactIdOverride: String? = nil,
        core: OrchestratorCore?,
        restoreSession: (String) -> Bool,
        saveSession: (String) -> Void,
        archiveSession: (String, ArchiveReason) -> Void,
        tryDecryptWithArchived: (ChatMessage) throws -> Data
    ) throws -> DecryptResult {
        guard let core = core else {
            throw CryptoManagerError.coreNotInitialized
        }

        let contactId = contactIdOverride ?? message.from

        if !core.hasSession(contactId: contactId) {
            if !restoreSession(contactId) {
                throw CryptoManagerError.sessionNotFound
            }
        }

        guard core.hasSession(contactId: contactId) else {
            throw CryptoManagerError.sessionNotFound
        }

        do {
            let rawContent = message.content
            let contentForDecrypt = MessagePadding.unpadCiphertext(rawContent)
            let result = try core.decryptMessage(
                contactId: contactId,
                ephemeralPublicKey: [UInt8](message.ephemeralPublicKey),
                messageNumber: message.messageNumber,
                content: [UInt8](contentForDecrypt)
            )
            saveSession(contactId)
            return DecryptResult(plaintext: Data(result.plaintext), storageKey: Data(result.storageKey))
        } catch {
            if let plaintext = try? tryDecryptWithArchived(message) {
                // Archived session decrypt — no storage key available; caller handles appropriately
                return DecryptResult(plaintext: plaintext, storageKey: Data())
            }
            archiveSession(contactId, .decryptionFailed)
            throw CryptoManagerError.decryptionFailed
        }
    }
}
