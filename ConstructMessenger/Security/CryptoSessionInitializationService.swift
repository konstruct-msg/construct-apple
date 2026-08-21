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
        supportsPqRatchet: Bool = false,
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
            kyberOneTimePrekeyId: kyberOneTimePreKeyId,
            supportsPqRatchet: supportsPqRatchet
        )

        do {
            let sessionId = allowStale
                ? try core.initSessionAllowingStale(contactId: userId, recipientBundle: bundle)
                : try core.initSession(contactId: userId, recipientBundle: bundle)
            // Persist the NEGOTIATED suite (suite 3 when both sides support the PQ
            // ratchet), not the bundle's crypto suite — the bundle only ever says 1/2.
            let negotiatedSuite = core.getSessionSuiteId(contactId: userId)
            KeychainManager.shared.saveSessionSuiteId(userId: userId, suiteId: negotiatedSuite > 0 ? negotiatedSuite : suiteID)
            saveSession(userId)
            Log.info("SESSION_STATE[suite_negotiated]: peer=\(userId.prefix(8))…, bundleSuite=\(suiteID), supportsPqRatchet=\(supportsPqRatchet), negotiated=\(negotiatedSuite)", category: "SessionInit")
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

        let sealedBox = firstMessage.content
        guard sealedBox.count >= 12 else {
            Log.error("First message sealed box too short (\(sealedBox.count) bytes)", category: "CryptoManager")
            throw CryptoManagerError.invalidKeyData
        }

        let initKind = SessionReducer.receivingInitKind(
            messageNumber: firstMessage.messageNumber,
            oneTimePreKeyId: firstMessage.oneTimePreKeyId,
            kemCiphertextBytes: firstMessage.kemCiphertext.count,
            pqMessageEpoch: firstMessage.pqMessageEpoch,
            isSessionResetInit: firstMessage.isSessionResetInit
        )
        guard initKind == .handshake else {
            Log.error(
                "SESSION_STATE[init_refused_not_handshake]: \(userId.prefix(8))… kind=\(initKind) msgNum=\(firstMessage.messageNumber) otpk=\(firstMessage.oneTimePreKeyId) kem=\(firstMessage.kemCiphertext.count)B epoch=\(firstMessage.pqMessageEpoch)",
                category: "CryptoManager"
            )
            throw SessionError.notAHandshakeCarrier
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
            kyberOneTimePrekeyId: nil,
            // Receiving path: the responder adopts the suite from the first
            // message's wire header, so the capability flag is irrelevant here.
            supportsPqRatchet: false
        )

        let firstMsg = BinaryFirstMessage(
            ephemeralPublicKey: [UInt8](firstMessage.ephemeralPublicKey),
            messageNumber: firstMessage.messageNumber,
            content: [UInt8](sealedBox),
            oneTimePrekeyId: firstMessage.oneTimePreKeyId,
            // Suite the INITIATOR encrypted with, taken from the wire header — the
            // responder must adopt it to rebuild the exact AEAD associated data
            // (suite 3 appends a pq_message_epoch tag). Dropping these was the outage.
            suiteId: firstMessage.suiteId,
            pqMessageEpoch: firstMessage.pqMessageEpoch,
            pqRatchetField: [UInt8](firstMessage.pqRatchetField)
        )

        do {
            let result = try core.initReceivingSession(
                contactId: userId,
                recipientBundle: bundle,
                firstMessage: firstMsg
            )

            let plaintext = result.decryptedMessage
            // Never log the decrypted body itself. Release is protected by os_log's private-by-
            // default `%@` and by LogCollector being off, but INTERNAL_TOOLS builds persist this
            // line to a rotating file the user can export via DiagnosticLogShare — message
            // plaintext must not be in it. Length alone is enough to diagnose an init.
            Log.info("Session initialized successfully, decrypted \(plaintext.count)B", category: "CryptoManager")

            KeychainManager.shared.saveSessionSuiteId(userId: userId, suiteId: suiteID)
            // NOTE: saveSession deferred until after PQXDH strengthening completes.

            if !firstMessage.kemCiphertext.isEmpty {
                do {
                    try PQCKeyManager.shared.applyIncomingContribution(
                        kemCiphertext: firstMessage.kemCiphertext,
                        kyberOtpkId: firstMessage.kyberOtpkId,
                        contactId: userId
                    )
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
            // Preserve the OTPK-unreproducible signal BEFORE the specific Rust message is dropped by
            // the generic rethrow below. The SessionCoordinator init-failure path only sees
            // `CryptoManagerError.sessionInitializationFailed` (message lost), so without this it
            // sends a plain END_SESSION and the sender loops 4-DH forever. Recording the hint here
            // (mirroring PublicKeyBundleHandler) lets SessionCoordinator ask the peer to re-init via
            // 3-DH instead. See device-link crypto storm postmortem.
            if "\(error)".contains("cannot reproduce") {
                Log.info("SESSION_STATE[otpk_unreproducible]: \(userId.prefix(8))… — will request 3-DH re-init via END_SESSION", category: "SessionInit")
                SessionReinitHintStore.shared.recordResponderOtpkUnreproducible(for: userId)
            }
            throw CryptoManagerError.sessionInitializationFailed
        }
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
