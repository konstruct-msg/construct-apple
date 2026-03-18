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
        let content: String
        let suiteId: UInt16
        let oneTimePreKeyId: UInt32  // OTPK key_id used in X3DH (0 = no OTPK)
    }

    private static func suiteId(for userId: String) -> UInt16 {
        UInt16(UserDefaults.standard.integer(forKey: "construct.session.suite.\(userId)"))
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

        let suiteId = Self.suiteId(for: userId)

        #if DEBUG
        Log.debug("🔐 ENCRYPT: Preparing to encrypt message", category: "CryptoManager")
        Log.debug("   userId: \(userId)", category: "CryptoManager")
        Log.debug("   suiteId: \(suiteId)", category: "CryptoManager")
        Log.debug("   plaintext length: \(message.count) chars", category: "CryptoManager")
        Log.debug("   plaintext preview: \(message.prefix(50))...", category: "CryptoManager")
        #endif

        do {
            let rustComponents = try core.encryptMessage(contactId: userId, plaintext: message)

            #if DEBUG
            Log.debug("🔐 ENCRYPT: Rust core returned components", category: "CryptoManager")
            Log.debug("   ephemeralPublicKey: \(rustComponents.ephemeralPublicKey.count) bytes", category: "CryptoManager")
            let ephemeralPreview = rustComponents.ephemeralPublicKey.prefix(16).map { String(format: "%02x", $0) }.joined()
            Log.debug("   ephemeralPublicKey preview: \(ephemeralPreview)...", category: "CryptoManager")
            Log.debug("   messageNumber: \(rustComponents.messageNumber)", category: "CryptoManager")
            Log.debug("   oneTimePrekeyId: \(rustComponents.oneTimePrekeyId)", category: "CryptoManager")
            Log.debug("   content (before padding): \(rustComponents.content.count) chars", category: "CryptoManager")
            Log.debug("   content preview: \(rustComponents.content.prefix(32))...", category: "CryptoManager")
            #endif

            let components = EncryptedMessageComponents(
                ephemeralPublicKey: Data(rustComponents.ephemeralPublicKey),
                messageNumber: rustComponents.messageNumber,
                content: MessagePadding.padCiphertextBase64(rustComponents.content),
                suiteId: suiteId,
                oneTimePreKeyId: rustComponents.oneTimePrekeyId
            )

            #if DEBUG
            Log.debug("🔐 ENCRYPT: After padding", category: "CryptoManager")
            Log.debug("   content (after padding): \(components.content.count) chars", category: "CryptoManager")
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
        tryDecryptWithArchived: (ChatMessage) throws -> String
    ) throws -> String {
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
            let contentForDecrypt = MessagePadding.unpadCiphertextBase64(message.content)
            let plaintext = try core.decryptMessage(
                contactId: contactId,
                ephemeralPublicKey: [UInt8](message.ephemeralPublicKey),
                messageNumber: message.messageNumber,
                content: contentForDecrypt
            )
            saveSession(contactId)
            return plaintext
        } catch {
            if let plaintext = try? tryDecryptWithArchived(message) {
                return plaintext
            }
            archiveSession(contactId, .decryptionFailed)
            throw CryptoManagerError.decryptionFailed
        }
    }
}
