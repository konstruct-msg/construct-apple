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
        let pqMessageEpoch: UInt32   // suite-3 per-message PQ epoch tag (0 otherwise)
        let pqRatchetField: Data     // suite-3 sparse PQ field, serialized (empty = none)
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
        saveSession: (String) -> Bool,
        archiveSession: (String, ArchiveReason) -> Void
    ) throws -> EncryptedMessageComponents {
        guard let core = core else {
            throw CryptoManagerError.coreNotInitialized
        }

        // Resolved once, at the top: a peer we cannot name has no session to encrypt with, and
        // the alternative — carrying the account id onwards — is what put an account id in the AD.
        guard let contactId = SessionAddressing.contactId(forPeer: userId) else {
            Log.info("encryptMessage: \(userId.prefix(8))… has no pinned key — no session to use", category: "CryptoManager")
            throw CryptoManagerError.sessionNotFound
        }

        if !core.hasSession(contactId: contactId) {
            if !restoreSession(userId) {
                throw CryptoManagerError.sessionNotFound
            }
        }

        guard core.hasSession(contactId: contactId) else {
            throw CryptoManagerError.sessionNotFound
        }

        // Read suiteId from the Rust core (authoritative) — NOT UserDefaults.
        // UserDefaults can be cleared by app data reset / iCloud restore while the
        // Keychain session survives, producing suiteId=0 and a protocol mismatch.
        var suiteId = core.getSessionSuiteId(contactId: contactId)
        if suiteId == 0 {
            // Rust core doesn't know the suiteId yet (session not fully loaded?) —
            // fall back to UserDefaults and log so we can investigate.
            suiteId = Self.suiteId(for: userId)
            if suiteId > 0 {
                Log.info("ENCRYPT: suiteId from Rust=0, falling back to UserDefaults=\(suiteId) for \(userId.prefix(8))…", category: "CryptoManager")
            }
        } else {
            // Keep Keychain in sync so the fallback path stays correct.
            KeychainManager.shared.saveSessionSuiteId(userId: contactId, suiteId: suiteId)
        }

        #if DEBUG
        Log.debug("ENCRYPT: Preparing to encrypt message", category: "CryptoManager")
        Log.debug("   userId: \(userId)", category: "CryptoManager")
        Log.debug("   suiteId: \(suiteId)", category: "CryptoManager")
        Log.debug("   plaintext length: \(message.count) chars", category: "CryptoManager")
        Log.debug("   plaintext preview: \(message.prefix(50))...", category: "CryptoManager")
        #endif

        do {
            let rustComponents = try core.encryptMessage(contactId: contactId, plaintext: Data(message.utf8))

            #if DEBUG
            Log.debug("ENCRYPT: Rust core returned components", category: "CryptoManager")
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
                content: rawContent,
                // Use the suite the core actually encrypted with (authoritative
                // per-message value), not the separately-looked-up session suite.
                suiteId: rustComponents.suiteId,
                oneTimePreKeyId: rustComponents.oneTimePrekeyId,
                storageKey: Data(rustComponents.storageKey),
                pqMessageEpoch: rustComponents.pqMessageEpoch,
                pqRatchetField: Data(rustComponents.pqRatchetField)
            )

            #if DEBUG
            Log.debug("ENCRYPT: After padding", category: "CryptoManager")
            Log.debug("   content (after padding): \(components.content.count) bytes", category: "CryptoManager")
            #endif

            // Fail-closed durability: core.encryptMessage above already advanced the sending chain.
            // Calls share this DR session with messages, so releasing this signaling ciphertext when
            // the advance is not durable risks a message-number-reuse desync on a crash + stale
            // reload. Refuse; the caller treats it as a signaling failure and retries.
            guard saveSession(userId) else {
                Log.error("encryptMessage: session persist FAILED for \(userId.prefix(8))… — refusing to release ciphertext (prevents ratchet number reuse)", category: "CryptoManager")
                throw CryptoManagerError.encryptionFailed
            }
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

        let peerId = contactIdOverride ?? message.from
        guard let contactId = SessionAddressing.contactId(forPeer: peerId) else {
            Log.info("decryptMessage: \(peerId.prefix(8))… has no pinned key — no session to try", category: "CryptoManager")
            throw CryptoManagerError.sessionNotFound
        }

        if !core.hasSession(contactId: contactId) {
            if !restoreSession(peerId) {
                throw CryptoManagerError.sessionNotFound
            }
        }

        guard core.hasSession(contactId: contactId) else {
            throw CryptoManagerError.sessionNotFound
        }

        do {
            let rawContent = message.content
            let contentForDecrypt = rawContent
            let result = try core.decryptMessage(
                contactId: contactId,
                ephemeralPublicKey: [UInt8](message.ephemeralPublicKey),
                messageNumber: message.messageNumber,
                content: [UInt8](contentForDecrypt),
                suiteId: message.suiteId,
                pqMessageEpoch: message.pqMessageEpoch,
                pqRatchetField: [UInt8](message.pqRatchetField)
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
