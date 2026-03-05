//
//  SessionInitializationService.swift
//  Construct Messenger
//
//  Extracted from CryptoManager (refactor)
//

import Foundation
import os.log

final class CryptoSessionInitializationService {
    func initializeSession(
        for userId: String,
        recipientBundle: (identityPublic: String, signedPrekeyPublic: String, signature: String, verifyingKey: String, suiteId: String),
        oneTimePreKeyPublic: Data? = nil,
        oneTimePreKeyId: UInt32? = nil,
        core: ClassicCryptoCore?,
        sessionStore: SessionStore,
        archiveSession: (String, ArchiveReason) -> Void,
        saveSession: (String) -> Void
    ) throws {
        guard let core = core else {
            throw CryptoManagerError.coreNotInitialized
        }

        if sessionStore.hasSession(for: userId) {
            archiveSession(userId, .manualReset)
        }

        Log.debug("🔐 Session init bundle lengths: identity=\(recipientBundle.identityPublic.count), signedPrekey=\(recipientBundle.signedPrekeyPublic.count), signature=\(recipientBundle.signature.count), verifyingKey=\(recipientBundle.verifyingKey.count), suiteId=\(recipientBundle.suiteId)", category: "CryptoManager")
        
        // Log RAW bundle data for INITIATOR session
        #if DEBUG
        Log.debug("🔐 INITIATOR RAW bundle from server:", category: "CryptoManager")
        Log.debug("   identityPublic (base64): \(recipientBundle.identityPublic.prefix(32))...", category: "CryptoManager")
        Log.debug("   signedPrekeyPublic (base64): \(recipientBundle.signedPrekeyPublic.prefix(32))...", category: "CryptoManager")
        Log.debug("   signature (base64): \(recipientBundle.signature.prefix(32))...", category: "CryptoManager")
        Log.debug("   verifyingKey (base64): \(recipientBundle.verifyingKey.prefix(32))...", category: "CryptoManager")
        Log.debug("   suiteId: \(recipientBundle.suiteId)", category: "CryptoManager")
        #endif

        guard let identityPublicData = Data(base64Encoded: recipientBundle.identityPublic) else {
            Log.error("❌ Invalid base64: identityPublic", category: "CryptoManager")
            throw CryptoManagerError.invalidKeyData
        }
        guard let signedPrekeyPublicData = Data(base64Encoded: recipientBundle.signedPrekeyPublic) else {
            Log.error("❌ Invalid base64: signedPrekeyPublic", category: "CryptoManager")
            throw CryptoManagerError.invalidKeyData
        }
        guard let signatureData = Data(base64Encoded: recipientBundle.signature) else {
            Log.error("❌ Invalid base64: signature", category: "CryptoManager")
            throw CryptoManagerError.invalidKeyData
        }
        guard let verifyingKeyData = Data(base64Encoded: recipientBundle.verifyingKey) else {
            Log.error("❌ Invalid base64: verifyingKey", category: "CryptoManager")
            throw CryptoManagerError.invalidKeyData
        }

        guard let suiteID = UInt16(recipientBundle.suiteId) else {
            throw CryptoManagerError.invalidKeyData
        }

        var bundleDict: [String: Any] = [
            "identity_public": [UInt8](identityPublicData),
            "signed_prekey_public": [UInt8](signedPrekeyPublicData),
            "signature": [UInt8](signatureData),
            "verifying_key": [UInt8](verifyingKeyData),
            "suite_id": suiteID,
        ]
        if let otpkPublic = oneTimePreKeyPublic, let otpkId = oneTimePreKeyId, otpkId > 0 {
            bundleDict["one_time_prekey_public"] = [UInt8](otpkPublic)
            bundleDict["one_time_prekey_id"] = otpkId
        }

        do {
            let bundleData = try JSONSerialization.data(withJSONObject: bundleDict)
            let bytes = [UInt8](bundleData)
            
            #if DEBUG
            Log.debug("🔐 Calling Rust initSession (INITIATOR):", category: "CryptoManager")
            Log.debug("   contactId: \(userId)", category: "CryptoManager")
            Log.debug("   recipientBundle: \(bytes.count) bytes JSON", category: "CryptoManager")
            
            if let bundleJSON = try? JSONSerialization.jsonObject(with: bundleData) as? [String: Any] {
                Log.debug("   Bundle JSON keys: \(bundleJSON.keys.sorted())", category: "CryptoManager")
                
                // Log first 16 bytes of each key component
                if let identity = bundleJSON["identity_public"] as? [UInt8] {
                    let preview = identity.prefix(16).map { String(format: "%02x", $0) }.joined()
                    Log.debug("   identity_public preview: \(preview)...", category: "CryptoManager")
                }
                if let prekey = bundleJSON["signed_prekey_public"] as? [UInt8] {
                    let preview = prekey.prefix(16).map { String(format: "%02x", $0) }.joined()
                    Log.debug("   signed_prekey_public preview: \(preview)...", category: "CryptoManager")
                }
            }
            #endif
            
            let sessionId = try core.initSession(contactId: userId, recipientBundle: bytes)
            sessionStore.setSession(userId: userId, sessionId: sessionId, suiteId: suiteID)
            saveSession(userId)
            
            Log.info("✅ INITIATOR session created: \(sessionId.prefix(16))...", category: "CryptoManager")
        } catch {
            Log.error("❌ Rust core initSession failed: \(error)", category: "CryptoManager")
            throw CryptoManagerError.sessionInitializationFailed
        }
    }

    func initReceivingSession(
        for userId: String,
        recipientBundle: (identityPublic: String, signedPrekeyPublic: String, signature: String, verifyingKey: String, suiteId: String),
        firstMessage: ChatMessage,
        core: ClassicCryptoCore?,
        sessionStore: SessionStore,
        archiveSession: (String, ArchiveReason) -> Void,
        saveSession: (String) -> Void
    ) throws -> String {
        guard let core = core else {
            throw CryptoManagerError.coreNotInitialized
        }

        if sessionStore.hasSession(for: userId) {
            archiveSession(userId, .manualReset)
        }

        Log.debug("🔐 Receiving init bundle lengths: identity=\(recipientBundle.identityPublic.count), signedPrekey=\(recipientBundle.signedPrekeyPublic.count), signature=\(recipientBundle.signature.count), verifyingKey=\(recipientBundle.verifyingKey.count), suiteId=\(recipientBundle.suiteId)", category: "CryptoManager")
        
        // Log RAW bundle data from server (first 32 chars of each)
        #if DEBUG
        Log.debug("🔐 RAW bundle from server:", category: "CryptoManager")
        Log.debug("   identityPublic (base64): \(recipientBundle.identityPublic.prefix(32))...", category: "CryptoManager")
        Log.debug("   signedPrekeyPublic (base64): \(recipientBundle.signedPrekeyPublic.prefix(32))...", category: "CryptoManager")
        Log.debug("   signature (base64): \(recipientBundle.signature.prefix(32))...", category: "CryptoManager")
        Log.debug("   verifyingKey (base64): \(recipientBundle.verifyingKey.prefix(32))...", category: "CryptoManager")
        Log.debug("   suiteId: \(recipientBundle.suiteId)", category: "CryptoManager")
        
        Log.debug("🔐 RAW first message from server:", category: "CryptoManager")
        Log.debug("   ephemeralPublicKey count: \(firstMessage.ephemeralPublicKey.count)", category: "CryptoManager")
        Log.debug("   content (padded): \(firstMessage.content.prefix(32))...", category: "CryptoManager")
        Log.debug("   messageNumber: \(firstMessage.messageNumber)", category: "CryptoManager")
        #endif

        guard let identityPublicData = Data(base64Encoded: recipientBundle.identityPublic) else {
            Log.error("❌ Invalid base64: identityPublic", category: "CryptoManager")
            Log.error("   Content: \(recipientBundle.identityPublic.prefix(100))...", category: "CryptoManager")
            throw CryptoManagerError.invalidKeyData
        }
        guard let signedPrekeyPublicData = Data(base64Encoded: recipientBundle.signedPrekeyPublic) else {
            Log.error("❌ Invalid base64: signedPrekeyPublic", category: "CryptoManager")
            Log.error("   Content: \(recipientBundle.signedPrekeyPublic.prefix(100))...", category: "CryptoManager")
            throw CryptoManagerError.invalidKeyData
        }
        guard let signatureData = Data(base64Encoded: recipientBundle.signature) else {
            Log.error("❌ Invalid base64: signature", category: "CryptoManager")
            Log.error("   Content: \(recipientBundle.signature.prefix(100))...", category: "CryptoManager")
            throw CryptoManagerError.invalidKeyData
        }
        guard let verifyingKeyData = Data(base64Encoded: recipientBundle.verifyingKey) else {
            Log.error("❌ Invalid base64: verifyingKey", category: "CryptoManager")
            Log.error("   Content: \(recipientBundle.verifyingKey.prefix(100))...", category: "CryptoManager")
            throw CryptoManagerError.invalidKeyData
        }

        guard let suiteID = UInt16(recipientBundle.suiteId) else {
            Log.error("❌ Invalid suiteId: \(recipientBundle.suiteId)", category: "CryptoManager")
            throw CryptoManagerError.invalidKeyData
        }
        
        Log.debug("🔐 Decoded bundle data:", category: "CryptoManager")
        Log.debug("   identityPublic: \(identityPublicData.count) bytes", category: "CryptoManager")
        Log.debug("   signedPrekeyPublic: \(signedPrekeyPublicData.count) bytes", category: "CryptoManager")
        Log.debug("   signature: \(signatureData.count) bytes", category: "CryptoManager")
        Log.debug("   verifyingKey: \(verifyingKeyData.count) bytes", category: "CryptoManager")
        Log.debug("   suiteId: \(suiteID)", category: "CryptoManager")

        let bundleDict: [String: Any] = [
            "identity_public": [UInt8](identityPublicData),
            "signed_prekey_public": [UInt8](signedPrekeyPublicData),
            "signature": [UInt8](signatureData),
            "verifying_key": [UInt8](verifyingKeyData),
            "suite_id": suiteID,
        ]

        // Rust expects content as a Base64 string (not raw bytes).
        // Unpad only — do NOT base64-decode; the string is passed directly to serde.
        let unpaddedContent = MessagePadding.unpadCiphertextBase64(firstMessage.content)

        // Validate the base64 (guard against malformed payloads)
        guard Data(base64Encoded: unpaddedContent) != nil else {
            Log.error("❌ Invalid base64: firstMessage.content", category: "CryptoManager")
            Log.error("   Original content length: \(firstMessage.content.count)", category: "CryptoManager")
            Log.error("   Unpadded content length: \(unpaddedContent.count)", category: "CryptoManager")
            Log.error("   Content preview: \(unpaddedContent.prefix(100))...", category: "CryptoManager")
            throw CryptoManagerError.invalidKeyData
        }

        Log.debug("🔐 First message details:", category: "CryptoManager")
        Log.debug("   ephemeralPublicKey: \(firstMessage.ephemeralPublicKey.count) bytes", category: "CryptoManager")
        Log.debug("   messageNumber: \(firstMessage.messageNumber)", category: "CryptoManager")
        Log.debug("   content: \(unpaddedContent.count) chars (base64, unpadded)", category: "CryptoManager")
        Log.debug("   suiteId: \(suiteID)", category: "CryptoManager")

        let messageDict: [String: Any] = [
            "ephemeral_public_key": [UInt8](firstMessage.ephemeralPublicKey),
            "message_number": firstMessage.messageNumber,
            "content": unpaddedContent,   // Base64 string — Rust serde deserializes as String
            "one_time_prekey_id": firstMessage.oneTimePreKeyId
        ]

        do {
            let bundleData = try JSONSerialization.data(withJSONObject: bundleDict)
            let bundleBytes = [UInt8](bundleData)
            let messageData = try JSONSerialization.data(withJSONObject: messageDict)
            let messageBytes = [UInt8](messageData)

            Log.debug("🔐 Calling Rust initReceivingSession:", category: "CryptoManager")
            Log.debug("   contactId: \(userId)", category: "CryptoManager")
            Log.debug("   recipientBundle: \(bundleBytes.count) bytes JSON", category: "CryptoManager")
            Log.debug("   firstMessage: \(messageBytes.count) bytes JSON", category: "CryptoManager")
            
            // Log JSON structure for debugging (only in debug builds)
            #if DEBUG
            if let bundleJSON = try? JSONSerialization.jsonObject(with: bundleData) as? [String: Any] {
                Log.debug("   Bundle JSON keys: \(bundleJSON.keys.sorted())", category: "CryptoManager")
                
                // Log first 16 bytes of each key component for verification
                if let identity = bundleJSON["identity_public"] as? [UInt8] {
                    let preview = identity.prefix(16).map { String(format: "%02x", $0) }.joined()
                    Log.debug("   identity_public preview: \(preview)...", category: "CryptoManager")
                }
                if let prekey = bundleJSON["signed_prekey_public"] as? [UInt8] {
                    let preview = prekey.prefix(16).map { String(format: "%02x", $0) }.joined()
                    Log.debug("   signed_prekey_public preview: \(preview)...", category: "CryptoManager")
                }
                if let sig = bundleJSON["signature"] as? [UInt8] {
                    let preview = sig.prefix(16).map { String(format: "%02x", $0) }.joined()
                    Log.debug("   signature preview: \(preview)...", category: "CryptoManager")
                }
            }
            if let messageJSON = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any] {
                Log.debug("   Message JSON keys: \(messageJSON.keys.sorted())", category: "CryptoManager")
                
                // Log first 16 bytes of ephemeral key
                if let ephemeral = messageJSON["ephemeral_public_key"] as? [UInt8] {
                    let preview = ephemeral.prefix(16).map { String(format: "%02x", $0) }.joined()
                    Log.debug("   ephemeral_public_key preview: \(preview)...", category: "CryptoManager")
                }
                if let content = messageJSON["content"] as? [UInt8] {
                    let preview = content.prefix(16).map { String(format: "%02x", $0) }.joined()
                    Log.debug("   content preview: \(preview)... (total: \(content.count) bytes)", category: "CryptoManager")
                }
                if let msgNum = messageJSON["message_number"] {
                    Log.debug("   message_number: \(msgNum)", category: "CryptoManager")
                }
            }
            #endif

            let result = try core.initReceivingSession(
                contactId: userId,
                recipientBundle: bundleBytes,
                firstMessage: messageBytes
            )

            Log.info("✅ Session initialized successfully, decrypted: \(result.decryptedMessage.prefix(50))...", category: "CryptoManager")
            
            sessionStore.setSession(userId: userId, sessionId: result.sessionId, suiteId: suiteID)
            saveSession(userId)
            return result.decryptedMessage
        } catch {
            Log.error("❌ Rust core initReceivingSession failed: \(error)", category: "CryptoManager")
            Log.error("   Error type: \(type(of: error))", category: "CryptoManager")
            Log.error("   userId: \(userId)", category: "CryptoManager")
            throw CryptoManagerError.sessionInitializationFailed
        }
    }
}
