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
        allowStale: Bool = false,
        core: OrchestratorCore?,
        archiveSession: (String, ArchiveReason) -> Void,
        saveSession: (String) -> Void
    ) throws {
        guard let core = core else {
            throw CryptoManagerError.coreNotInitialized
        }

        if core.hasSession(contactId: userId) {
            archiveSession(userId, .manualReset)
        }

        guard let suiteID = UInt16(recipientBundle.suiteId) else {
            throw CryptoManagerError.invalidKeyData
        }

        #if DEBUG
        Log.debug("INITIATOR bundle: ik=\(recipientBundle.identityPublic.count)B spk=\(recipientBundle.signedPrekeyPublic.count)B sig=\(recipientBundle.signature.count)B vk=\(recipientBundle.verifyingKey.count)B suite=\(suiteID)", category: "CryptoManager")
        Log.debug("ik_prefix: \(recipientBundle.identityPublic.prefix(8).hexString)", category: "CryptoManager")
        Log.debug("spk_prefix: \(recipientBundle.signedPrekeyPublic.prefix(8).hexString)", category: "CryptoManager")
        #endif

        let bundle = BinaryKeyBundle(
            identityPublic: [UInt8](recipientBundle.identityPublic),
            signedPrekeyPublic: [UInt8](recipientBundle.signedPrekeyPublic),
            signature: [UInt8](recipientBundle.signature),
            verifyingKey: [UInt8](recipientBundle.verifyingKey),
            suiteId: suiteID,
            oneTimePrekeyPublic: oneTimePreKeyPublic.map { [UInt8]($0) },
            oneTimePrekeyId: oneTimePreKeyId,
            spkUploadedAt: spkUploadedAt,
            spkRotationEpoch: spkRotationEpoch,
            kyberSpkUploadedAt: kyberSpkUploadedAt,
            kyberSpkRotationEpoch: kyberSpkRotationEpoch,
            kyberPreKeyPublic: kyberPreKeyPublic.map { [UInt8]($0) },
            kyberOneTimePrekeyPublic: kyberOneTimePreKeyPublic.map { [UInt8]($0) },
            kyberOneTimePrekeyId: kyberOneTimePreKeyId
        )

        do {
            let sessionId = allowStale
                ? try core.initSessionAllowingStale(contactId: userId, recipientBundle: bundle)
                : try core.initSession(contactId: userId, recipientBundle: bundle)
            KeychainManager.shared.saveSessionSuiteId(userId: userId, suiteId: suiteID)
            saveSession(userId)
            Log.info("INITIATOR session created\(allowStale ? " (degraded/at-risk)" : ""): \(sessionId.prefix(16))...", category: "CryptoManager")
        } catch CryptoError.PeerSpkStale(let message) {
            let ageSecs: UInt64
            if let range = message.range(of: "age_secs=") {
                ageSecs = UInt64(message[range.upperBound...].prefix(while: { $0.isNumber })) ?? 0
            } else {
                ageSecs = 0
            }
            let ageDays = Double(ageSecs) / 86400.0
            Log.error("Peer SPK stale for \(userId.prefix(8))… — age ≈ \(String(format: "%.1f", ageDays))d", category: "CryptoManager")
            throw SessionError.peerSPKStale(ageDays: ageDays)
        } catch {
            Log.error("Rust core initSession failed: \(error)", category: "CryptoManager")
            throw CryptoManagerError.sessionInitializationFailed
        }
    }

    func initReceivingSession(
        for userId: String,
        recipientBundle: (identityPublic: Data, signedPrekeyPublic: Data, signature: Data, verifyingKey: Data, suiteId: String),
        firstMessage: ChatMessage,
        spkUploadedAt: UInt64 = 0,
        spkRotationEpoch: UInt32 = 0,
        kyberSpkUploadedAt: UInt64 = 0,
        kyberSpkRotationEpoch: UInt32 = 0,
        core: OrchestratorCore?,
        archiveSession: (String, ArchiveReason) -> Void,
        saveSession: (String) -> Void
    ) throws -> Data {
        guard let core = core else {
            throw CryptoManagerError.coreNotInitialized
        }

        if core.hasSession(contactId: userId) {
            archiveSession(userId, .manualReset)
        }

        guard let suiteID = UInt16(recipientBundle.suiteId) else {
            Log.error("Invalid suiteId: \(recipientBundle.suiteId)", category: "CryptoManager")
            throw CryptoManagerError.invalidKeyData
        }

        let sealedBox = MessagePadding.unpadCiphertext(firstMessage.content)
        guard sealedBox.count >= 12 else {
            Log.error("First message sealed box too short (\(sealedBox.count) bytes)", category: "CryptoManager")
            throw CryptoManagerError.invalidKeyData
        }

        #if DEBUG
        Log.debug("RESPONDER bundle: ik=\(recipientBundle.identityPublic.count)B spk=\(recipientBundle.signedPrekeyPublic.count)B suite=\(suiteID)", category: "CryptoManager")
        Log.debug("ik_prefix: \(recipientBundle.identityPublic.prefix(8).hexString)", category: "CryptoManager")
        Log.debug("eph_prefix: \(firstMessage.ephemeralPublicKey.prefix(8).hexString)", category: "CryptoManager")
        Log.debug("msgNum: \(firstMessage.messageNumber) sealedBox: \(sealedBox.count)B oneTimePrekeyId: \(firstMessage.oneTimePreKeyId) kemCiphertext: \(firstMessage.kemCiphertext.count)B kyberOtpkId: \(firstMessage.kyberOtpkId)", category: "CryptoManager")
        #endif

        // Epoch replay-attack check for RESPONDER: same logic as INITIATOR path.
        // We are fetching the SENDER's bundle — reject it if epoch has not advanced.
        if spkRotationEpoch > 0 {
            let knownEpoch = KeychainManager.shared.loadSpkEpoch(for: userId)
            if spkRotationEpoch < knownEpoch {
                Log.error("SESSION_STATE[spk_replay_rejected_responder]: epoch=\(spkRotationEpoch) < known=\(knownEpoch) for \(userId.prefix(8))… — possible SPK replay attack", category: "SessionInit")
                throw SessionError.staleSPKBundle(epoch: spkRotationEpoch, knownEpoch: knownEpoch)
            }
            KeychainManager.shared.saveSpkEpoch(spkRotationEpoch, for: userId)
        }

        let bundle = BinaryKeyBundle(
            identityPublic: [UInt8](recipientBundle.identityPublic),
            signedPrekeyPublic: [UInt8](recipientBundle.signedPrekeyPublic),
            signature: [UInt8](recipientBundle.signature),
            verifyingKey: [UInt8](recipientBundle.verifyingKey),
            suiteId: suiteID,
            oneTimePrekeyPublic: nil,
            oneTimePrekeyId: nil,
            spkUploadedAt: spkUploadedAt,
            spkRotationEpoch: spkRotationEpoch,
            kyberSpkUploadedAt: kyberSpkUploadedAt,
            kyberSpkRotationEpoch: kyberSpkRotationEpoch,
            kyberPreKeyPublic: nil,
            kyberOneTimePrekeyPublic: nil,
            kyberOneTimePrekeyId: nil
        )

        let firstMsg = BinaryFirstMessage(
            ephemeralPublicKey: [UInt8](firstMessage.ephemeralPublicKey),
            messageNumber: firstMessage.messageNumber,
            content: [UInt8](sealedBox),
            oneTimePrekeyId: firstMessage.oneTimePreKeyId
        )

        do {
            let result = try core.initReceivingSession(
                contactId: userId,
                recipientBundle: bundle,
                firstMessage: firstMsg
            )

            let plaintext = result.decryptedMessage
            let plaintextPreview = String(bytes: plaintext.prefix(50), encoding: .utf8) ?? "<binary \(plaintext.count)B>"
            Log.info("Session initialized successfully, decrypted: \(plaintextPreview)...", category: "CryptoManager")

            KeychainManager.shared.saveSessionSuiteId(userId: userId, suiteId: suiteID)
            // NOTE: saveSession deferred until after PQXDH strengthening completes.

            if !firstMessage.kemCiphertext.isEmpty {
                do {
                    let kyberOtpkId = firstMessage.kyberOtpkId
                    if kyberOtpkId > 0 {
                        guard let otpkSecret = PQCKeyManager.kyberOtpkSecret(forKeyId: kyberOtpkId) else {
                            Log.error("PQC: Kyber OTPK id=\(kyberOtpkId) secret MISSING for \(userId.prefix(8))… — failing session init", category: "CryptoManager")
                            throw CryptoManagerError.pqxdhOtpkMissing(kyberOtpkId)
                        }
                        try PQCKeyManager.shared.decapsulateAndStrengthen(
                            kemCiphertext: firstMessage.kemCiphertext,
                            contactId: userId,
                            secretKeyOverride: otpkSecret
                        )
                        PQCKeyManager.deleteKyberOtpk(keyId: kyberOtpkId)
                        Log.info("PQC: PQXDH Kyber OTPK id=\(kyberOtpkId) for \(userId.prefix(8))...", category: "CryptoManager")
                    } else {
                        try PQCKeyManager.shared.decapsulateAndStrengthen(
                            kemCiphertext: firstMessage.kemCiphertext,
                            contactId: userId
                        )
                        Log.info("PQC: PQXDH Kyber SPK for \(userId.prefix(8))...", category: "CryptoManager")
                    }
                } catch {
                    Log.error("PQC: PQXDH decapsulation FAILED for \(userId.prefix(8))...: \(error)", category: "CryptoManager")
                    KeychainManager.shared.savePQXDHDowngradeFlag(for: userId)
                }
            }

            saveSession(userId)

            return Data(plaintext)
        } catch {
            Log.error("Rust core initReceivingSession failed: \(error)", category: "CryptoManager")
            Log.error("Error type: \(type(of: error))", category: "CryptoManager")
            Log.error("userId: \(userId)", category: "CryptoManager")
            throw CryptoManagerError.sessionInitializationFailed
        }
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
