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
        recipientBundle: (identityPublic: Data, signedPrekeyPublic: Data, signature: Data, verifyingKey: Data, suiteId: String),
        oneTimePreKeyPublic: Data? = nil,
        oneTimePreKeyId: UInt32? = nil,
        kyberPreKeyPublic: Data? = nil,
        kyberOneTimePreKeyPublic: Data? = nil,
        kyberOneTimePreKeyId: UInt32? = nil,
        spkUploadedAt: UInt64 = 0,
        spkRotationEpoch: UInt32 = 0,
        kyberSpkUploadedAt: UInt64 = 0,
        kyberSpkRotationEpoch: UInt32 = 0,
        core: OrchestratorCore?,
        archiveSession: (String, ArchiveReason) -> Void,
        saveSession: (String) -> Void
    ) throws -> (kemCiphertext: Data?, kyberOtpkId: UInt32) {  // Returns KEM ciphertext and Kyber OTPK ID used
        guard let core = core else {
            throw CryptoManagerError.coreNotInitialized
        }

        if core.hasSession(contactId: userId) {
            archiveSession(userId, .manualReset)
        }

        Log.debug("🔐 Session init bundle: identity=\(recipientBundle.identityPublic.count)B, signedPrekey=\(recipientBundle.signedPrekeyPublic.count)B, signature=\(recipientBundle.signature.count)B, verifyingKey=\(recipientBundle.verifyingKey.count)B, suiteId=\(recipientBundle.suiteId)", category: "CryptoManager")
        
        #if DEBUG
        Log.debug("🔐 INITIATOR RAW bundle from server:", category: "CryptoManager")
        Log.debug("   identityPublic: \(recipientBundle.identityPublic.prefix(16).map { String(format: "%02x", $0) }.joined())...", category: "CryptoManager")
        Log.debug("   signedPrekeyPublic: \(recipientBundle.signedPrekeyPublic.prefix(16).map { String(format: "%02x", $0) }.joined())...", category: "CryptoManager")
        Log.debug("   signature: \(recipientBundle.signature.prefix(16).map { String(format: "%02x", $0) }.joined())...", category: "CryptoManager")
        Log.debug("   verifyingKey: \(recipientBundle.verifyingKey.prefix(16).map { String(format: "%02x", $0) }.joined())...", category: "CryptoManager")
        Log.debug("   suiteId: \(recipientBundle.suiteId)", category: "CryptoManager")
        #endif

        guard let suiteID = UInt16(recipientBundle.suiteId) else {
            throw CryptoManagerError.invalidKeyData
        }

        var bundleDict: [String: Any] = [
            "identity_public": [UInt8](recipientBundle.identityPublic),
            "signed_prekey_public": [UInt8](recipientBundle.signedPrekeyPublic),
            "signature": [UInt8](recipientBundle.signature),
            "verifying_key": [UInt8](recipientBundle.verifyingKey),
            "suite_id": suiteID,
            // SPK freshness fields — Rust validates these in validate_bundle_freshness().
            // 0 = legacy server; Rust skips validation when 0.
            "spk_uploaded_at": spkUploadedAt,
            "spk_rotation_epoch": spkRotationEpoch,
            "kyber_spk_uploaded_at": kyberSpkUploadedAt,
            "kyber_spk_rotation_epoch": kyberSpkRotationEpoch,
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
            UserDefaults.standard.set(Int(suiteID), forKey: "construct.session.suite.\(userId)")
            saveSession(userId)

            // PQXDH: Prefer Kyber OTPK over SPK when available.
            // Use encapsulateAndDefer so that msg0 is encrypted with classic-only DR state.
            // The contribution is applied after msg0 is encrypted (in consumeKemCiphertext).
            var kemCiphertext: Data? = nil
            var kyberOtpkId: UInt32 = 0
            if let otpkPK = kyberOneTimePreKeyPublic, let otpkId = kyberOneTimePreKeyId, !otpkPK.isEmpty {
                do {
                    kemCiphertext = try PQCKeyManager.shared.encapsulateAndDefer(
                        kyberSPKPublic: otpkPK,
                        contactId: userId,
                        core: core
                    )
                    kyberOtpkId = otpkId
                    Log.info("🔐 PQC: PQXDH encapsulated (Kyber OTPK id=\(otpkId)) for initiator session with \(userId.prefix(8))... (deferred)", category: "CryptoManager")
                } catch {
                    Log.error("⚠️ PQC: PQXDH encapsulation (OTPK) failed (using classic X3DH): \(error)", category: "CryptoManager")
                }
            } else if let kyberPK = kyberPreKeyPublic, !kyberPK.isEmpty {
                do {
                    kemCiphertext = try PQCKeyManager.shared.encapsulateAndDefer(
                        kyberSPKPublic: kyberPK,
                        contactId: userId,
                        core: core
                    )
                    // kyberOtpkId stays 0 = SPK used
                    Log.info("🔐 PQC: PQXDH encapsulated (Kyber SPK) for initiator session with \(userId.prefix(8))... (deferred)", category: "CryptoManager")
                } catch {
                    Log.error("⚠️ PQC: PQXDH encapsulation (SPK) failed (using classic X3DH): \(error)", category: "CryptoManager")
                }
            }

            Log.info("✅ INITIATOR session created: \(sessionId.prefix(16))...", category: "CryptoManager")
            return (kemCiphertext: kemCiphertext, kyberOtpkId: kyberOtpkId)
        } catch {
            Log.error("❌ Rust core initSession failed: \(error)", category: "CryptoManager")
            throw CryptoManagerError.sessionInitializationFailed
        }
    }

    func initReceivingSession(
        for userId: String,
        recipientBundle: (identityPublic: Data, signedPrekeyPublic: Data, signature: Data, verifyingKey: Data, suiteId: String),
        firstMessage: ChatMessage,
        core: OrchestratorCore?,
        archiveSession: (String, ArchiveReason) -> Void,
        saveSession: (String) -> Void
    ) throws -> String {
        guard let core = core else {
            throw CryptoManagerError.coreNotInitialized
        }

        if core.hasSession(contactId: userId) {
            archiveSession(userId, .manualReset)
        }

        Log.debug("🔐 Receiving init bundle: identity=\(recipientBundle.identityPublic.count)B, signedPrekey=\(recipientBundle.signedPrekeyPublic.count)B, signature=\(recipientBundle.signature.count)B, verifyingKey=\(recipientBundle.verifyingKey.count)B, suiteId=\(recipientBundle.suiteId)", category: "CryptoManager")
        
        #if DEBUG
        Log.debug("🔐 RAW bundle from server:", category: "CryptoManager")
        Log.debug("   identityPublic: \(recipientBundle.identityPublic.prefix(16).map { String(format: "%02x", $0) }.joined())...", category: "CryptoManager")
        Log.debug("   signedPrekeyPublic: \(recipientBundle.signedPrekeyPublic.prefix(16).map { String(format: "%02x", $0) }.joined())...", category: "CryptoManager")
        Log.debug("   signature: \(recipientBundle.signature.prefix(16).map { String(format: "%02x", $0) }.joined())...", category: "CryptoManager")
        Log.debug("   verifyingKey: \(recipientBundle.verifyingKey.prefix(16).map { String(format: "%02x", $0) }.joined())...", category: "CryptoManager")
        Log.debug("   suiteId: \(recipientBundle.suiteId)", category: "CryptoManager")
        Log.debug("🔐 RAW first message from server:", category: "CryptoManager")
        Log.debug("   ephemeralPublicKey count: \(firstMessage.ephemeralPublicKey.count)", category: "CryptoManager")
        Log.debug("   content (padded): \(firstMessage.content.prefix(32))...", category: "CryptoManager")
        Log.debug("   messageNumber: \(firstMessage.messageNumber)", category: "CryptoManager")
        #endif

        guard let suiteID = UInt16(recipientBundle.suiteId) else {
            Log.error("❌ Invalid suiteId: \(recipientBundle.suiteId)", category: "CryptoManager")
            throw CryptoManagerError.invalidKeyData
        }
        
        Log.debug("🔐 Decoded bundle data:", category: "CryptoManager")
        Log.debug("   identityPublic: \(recipientBundle.identityPublic.count) bytes", category: "CryptoManager")
        Log.debug("   signedPrekeyPublic: \(recipientBundle.signedPrekeyPublic.count) bytes", category: "CryptoManager")
        Log.debug("   signature: \(recipientBundle.signature.count) bytes", category: "CryptoManager")
        Log.debug("   verifyingKey: \(recipientBundle.verifyingKey.count) bytes", category: "CryptoManager")
        Log.debug("   suiteId: \(suiteID)", category: "CryptoManager")

        let bundleDict: [String: Any] = [
            "identity_public": [UInt8](recipientBundle.identityPublic),
            "signed_prekey_public": [UInt8](recipientBundle.signedPrekeyPublic),
            "signature": [UInt8](recipientBundle.signature),
            "verifying_key": [UInt8](recipientBundle.verifyingKey),
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
            Log.debug("   localOtpkCount: \(core.oneTimePrekeyCount()) (must have ID \(firstMessage.oneTimePreKeyId) to succeed)", category: "CryptoManager")
            
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
                if let otpkId = messageJSON["one_time_prekey_id"] {
                    Log.debug("   one_time_prekey_id: \(otpkId)", category: "CryptoManager")
                }
            }
            #endif

            let result = try core.initReceivingSession(
                contactId: userId,
                recipientBundle: bundleBytes,
                firstMessage: messageBytes
            )

            Log.info("✅ Session initialized successfully, decrypted: \(result.decryptedMessage.prefix(50))...", category: "CryptoManager")

            UserDefaults.standard.set(Int(suiteID), forKey: "construct.session.suite.\(userId)")
            // NOTE: saveSession is intentionally deferred until AFTER PQXDH strengthening below.
            // Writing the session to Keychain before applying the KEM contribution would leave a
            // partially-initialised session on disk if the process crashes between the two steps.

            // PQXDH: If sender included a KEM ciphertext, decapsulate + strengthen session.
            // The INITIATOR has already applied the PQ contribution to their DR state,
            // so we MUST either apply the same contribution correctly, or skip PQ entirely
            // (both sides stay classic X3DH for msg0; msg1+ will diverge and trigger END_SESSION).
            if !firstMessage.kemCiphertext.isEmpty {
                do {
                    let kyberOtpkId = firstMessage.kyberOtpkId
                    if kyberOtpkId > 0 {
                        // Sender encapsulated with a Kyber OTPK
                        guard let otpkSecret = PQCKeyManager.kyberOtpkSecret(forKeyId: kyberOtpkId) else {
                            // OTPK secret missing — throw so session init fails and triggers
                            // END_SESSION + clean re-init. If we silently skipped PQ here,
                            // INITIATOR's DR root key would diverge from ours (they applied PQ,
                            // we didn't), causing every message from msg1+ to fail AEAD permanently.
                            // Failing fast forces both sides to negotiate a fresh session correctly.
                            Log.error("🚨 PQC: Kyber OTPK id=\(kyberOtpkId) secret MISSING for \(userId.prefix(8))… — failing session init to force clean re-init", category: "CryptoManager")
                            throw CryptoManagerError.pqxdhOtpkMissing(kyberOtpkId)
                        }
                        try PQCKeyManager.shared.decapsulateAndStrengthen(
                            kemCiphertext: firstMessage.kemCiphertext,
                            contactId: userId,
                            core: core,
                            secretKeyOverride: otpkSecret
                        )
                        PQCKeyManager.deleteKyberOtpk(keyId: kyberOtpkId)
                        Log.info("🔐 PQC: PQXDH Kyber OTPK id=\(kyberOtpkId) for \(userId.prefix(8))...", category: "CryptoManager")
                    } else {
                        // kyberOtpkId == 0 → sender used Kyber SPK
                        try PQCKeyManager.shared.decapsulateAndStrengthen(
                            kemCiphertext: firstMessage.kemCiphertext,
                            contactId: userId,
                            core: core
                        )
                        Log.info("🔐 PQC: PQXDH Kyber SPK for \(userId.prefix(8))...", category: "CryptoManager")
                    }
                } catch {
                    // PQ decapsulation failed. msg0 decrypted fine (classic X3DH), but the
                    // INITIATOR already applied PQ to their DR state — subsequent messages
                    // will fail to decrypt, triggering END_SESSION and clean re-init.
                    Log.error("🚨 PQC: PQXDH decapsulation FAILED for \(userId.prefix(8))...: \(error) — session stays classic X3DH, expect ratchet divergence on msg1+", category: "CryptoManager")
                    UserDefaults.standard.set(true, forKey: "construct.pqxdh.downgraded.\(userId)")
                }
            }

            // Single atomic Keychain write after the entire handshake (X3DH + PQXDH) is complete.
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
