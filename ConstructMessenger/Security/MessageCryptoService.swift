//
//  MessageCryptoService.swift
//  Construct Messenger
//
//  Extracted from CryptoManager (refactor)
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

    func encryptMessage(
        _ message: String,
        for userId: String,
        core: ClassicCryptoCore?,
        sessionStore: SessionStore,
        restoreSession: (String) -> Bool,
        saveSession: (String) -> Void,
        archiveSession: (String, ArchiveReason) -> Void
    ) throws -> EncryptedMessageComponents {
        guard let core = core else {
            throw CryptoManagerError.coreNotInitialized
        }

        if !sessionStore.hasSession(for: userId) {
            if !restoreSession(userId) {
                throw CryptoManagerError.sessionNotFound
            }
        }

        guard let sessionId = sessionStore.getSessionId(for: userId),
              let suiteId = sessionStore.getSuiteId(for: userId) else {
            throw CryptoManagerError.sessionNotFound
        }

        #if DEBUG
        Log.debug("🔐 ENCRYPT: Preparing to encrypt message", category: "CryptoManager")
        Log.debug("   userId: \(userId)", category: "CryptoManager")
        Log.debug("   sessionId: \(sessionId.prefix(16))...", category: "CryptoManager")
        Log.debug("   suiteId: \(suiteId)", category: "CryptoManager")
        Log.debug("   plaintext length: \(message.count) chars", category: "CryptoManager")
        Log.debug("   plaintext preview: \(message.prefix(50))...", category: "CryptoManager")
        #endif

        do {
            let rustComponents = try core.encryptMessage(sessionId: sessionId, plaintext: message)
            
            #if DEBUG
            Log.debug("🔐 ENCRYPT: Rust core returned components", category: "CryptoManager")
            Log.debug("   ephemeralPublicKey: \(rustComponents.ephemeralPublicKey.count) bytes", category: "CryptoManager")
            let ephemeralPreview = rustComponents.ephemeralPublicKey.prefix(16).map { String(format: "%02x", $0) }.joined()
            Log.debug("   ephemeralPublicKey preview: \(ephemeralPreview)...", category: "CryptoManager")
            Log.debug("   messageNumber: \(rustComponents.messageNumber)", category: "CryptoManager")
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
            archiveSession(userId, .decryptionFailed)
            throw CryptoManagerError.encryptionFailed
        }
    }

    func decryptMessage(
        _ message: ChatMessage,
        core: ClassicCryptoCore?,
        sessionStore: SessionStore,
        restoreSession: (String) -> Bool,
        saveSession: (String) -> Void,
        archiveSession: (String, ArchiveReason) -> Void,
        tryDecryptWithArchived: (ChatMessage) throws -> String
    ) throws -> String {
        guard let core = core else {
            throw CryptoManagerError.coreNotInitialized
        }

        if !sessionStore.hasSession(for: message.from) {
            if !restoreSession(message.from) {
                throw CryptoManagerError.sessionNotFound
            }
        }

        guard let sessionId = sessionStore.getSessionId(for: message.from) else {
            throw CryptoManagerError.sessionNotFound
        }

        do {
            let contentForDecrypt = MessagePadding.unpadCiphertextBase64(message.content)
            let plaintext = try core.decryptMessage(
                sessionId: sessionId,
                ephemeralPublicKey: [UInt8](message.ephemeralPublicKey),
                messageNumber: message.messageNumber,
                content: contentForDecrypt
            )
            saveSession(message.from)
            return plaintext
        } catch {
            if let plaintext = try? tryDecryptWithArchived(message) {
                return plaintext
            }
            archiveSession(message.from, .decryptionFailed)
            throw CryptoManagerError.decryptionFailed
        }
    }
}
