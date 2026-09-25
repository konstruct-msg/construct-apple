//
//  SessionInitializationService.swift
//  Construct Messenger
//
//  Extracted from CryptoManager (refactor)
//

import Foundation
import os.log

final class CryptoSessionInitializationService {
    /// Open a session with the device `bundle` names, as INITIATOR.
    ///
    /// A session already held with that device is replaced only once the new one is built
    /// (`reopenSession`); on any refusal it stays exactly as it was. The replaced ratchet is then
    /// archived, as before, for messages still in flight on it.
    ///
    /// The one exception is a degraded (`allowStale`) init over a held session: the core's reopen
    /// has no stale variant, so that path archives first and inits, as every init did before.
    func initializeSession(
        for userId: String,
        bundle: PublicKeyBundleData,
        withoutOneTimePrekey: Bool = false,
        allowStale: Bool = false,
        core: OrchestratorCore?,
        archiveSession: (String, ArchiveReason) -> Void,
        archiveReplacedSession: (String, Data, ArchiveReason) -> Void,
        saveSession: (String) -> Void
    ) throws {
        guard let core = core else {
            throw CryptoManagerError.coreNotInitialized
        }

        // The peer's device is named by the key in this bundle, not by what the contact list
        // knows: at first contact there is no pinned key yet, and first contact is when X3DH runs.
        // A bundle with no usable identity key names nobody, and a session cannot be opened with
        // nobody — better to fail here than to open one under an account id.
        guard let contactId = SessionAddressing.cryptoIdentity(ofIdentityKey: bundle.identityPublic)
            ?? SessionAddressing.pinnedDevice(ofPeer: userId) else {
            Log.error("Session init: cannot name a device for \(userId.prefix(8))… — bundle carries no usable identity key", category: "CryptoManager")
            throw CryptoManagerError.invalidKeyData
        }

        #if DEBUG
        Log.debug("INITIATOR bundle: ik=\(bundle.identityPublic.count)B spk=\(bundle.signedPrekeyPublic.count)B vk=\(bundle.verifyingKey.count)B kyberSpk=\(bundle.kyberPreKeyPublic?.count ?? 0)B kyberOtpk=\(bundle.kyberOneTimePreKeyPublic?.count ?? 0)B hybrid=\(bundle.hybridIdentityKey?.count ?? 0)B suite=\(bundle.suiteId)", category: "CryptoManager")
        #endif

        let binary = bundle.binaryKeyBundle(withoutOneTimePrekey: withoutOneTimePrekey)
        // `contactId`, not `userId`: the question is about **this** device. Passed the account,
        // an archive resolves through the pinned key and reaches a different device of the same
        // peer — or, right after a prune, none at all (measured 2026-09-06 12:29:37).
        let held = core.hasSession(contactId: contactId)

        do {
            let sessionId: String
            if held && !allowStale {
                // Exported before the reopen: afterwards the core holds only the new session.
                let replaced = try? Data(core.exportSession(contactId: contactId))
                sessionId = try core.reopenSession(contactId: contactId, recipientBundle: binary)
                if let replaced {
                    archiveReplacedSession(contactId, replaced, .manualReset)
                }
            } else {
                if held { archiveSession(contactId, .manualReset) }
                sessionId = allowStale
                    ? try core.initSessionAllowingStale(contactId: contactId, recipientBundle: binary)
                    : try core.initSession(contactId: contactId, recipientBundle: binary)
            }
            // Persist the NEGOTIATED suite (always 3 since PQXDH v2), not the bundle's crypto
            // suite — the bundle only ever says 1/2.
            let negotiatedSuite = core.getSessionSuiteId(contactId: contactId)
            KeychainManager.shared.saveSessionSuiteId(userId: contactId, suiteId: negotiatedSuite > 0 ? negotiatedSuite : bundle.suiteId)
            // `contactId`, for the reason this whole function names a device rather than an
            // account: the session was opened under the key in the bundle, and `saveSession`
            // exports by the name it is given. Handed `userId` it resolves through the pinned
            // key, asks the core for a session that device does not have, and writes nothing —
            // `Session export failed: SessionNotFound` — while every log line around it says the
            // init succeeded. Measured 2026-09-06 on three of three inits that opened against a
            // device other than the pinned one, and on none of the inits that did not.
            saveSession(contactId)
            Log.info("SESSION_STATE[suite_negotiated]: peer=\(userId.prefix(8))…, bundleSuite=\(bundle.suiteId), negotiated=\(negotiatedSuite)\(held ? ", replaced held session" : "")", category: "SessionInit")
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
        } catch CryptoError.SessionInitializationFailed(let message) where message.hasPrefix("PQ_REQUIRED") {
            // Nothing was created, and a held session is still there. The reason names what the
            // bundle lacked; the peer is usually on a build from before PQXDH v2.
            Log.error("SESSION_STATE[pq_required]: \(contactId.prefix(8))… — \(message)", category: "SessionInit")
            throw SessionError.peerNotPostQuantum(reason: message)
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

        // The peer's device is named by the key in this bundle, not by what the contact list
        // knows: at first contact there is no pinned key yet, and first contact is when X3DH runs.
        // A bundle with no usable identity key names nobody, and a session cannot be opened with
        // nobody — better to fail here than to open one under an account id.
        guard let contactId = SessionAddressing.cryptoIdentity(ofIdentityKey: recipientBundle.identityPublic)
            ?? SessionAddressing.pinnedDevice(ofPeer: userId) else {
            Log.error("Session init: cannot name a device for \(userId.prefix(8))… — bundle carries no usable identity key", category: "CryptoManager")
            throw CryptoManagerError.invalidKeyData
        }

        if core.hasSession(contactId: contactId) {
            // `contactId`, not `userId`: the line above asked about **this** device and this is
            // what puts its answer away. Passed the account instead, the archive resolves through
            // the pinned key and reaches a different device of the same peer — or, right after a
            // prune, none at all (`archiveSession: … has no pinned key — nothing addressed to
            // archive`, measured 2026-09-06 12:29:37 while the core held the session it was
            // being asked about).
            archiveSession(contactId, .manualReset)
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
            // The sender's Kyber keys play no part in a responder init: the KEM ran against
            // *our* Kyber prekey, which the message names by id.
            kyberPreKeyPublic: nil,
            kyberOneTimePrekeyPublic: nil,
            kyberOneTimePrekeyId: nil
        )

        // The first message as the envelope carried it. The core unpacks it, so the PQXDH v2
        // flag, the Kyber prekey id, the KEM ciphertext and the suite-3 tags all reach the
        // responder init; none of them is copied here. (Dropping two of those in a copy was the
        // suite-3 outage, and v2 would have added three more to the copy.)
        guard !firstMessage.rawPayload.isEmpty else {
            Log.error("SESSION_STATE[init_refused_no_payload]: \(userId.prefix(8))… — first message without its wire payload", category: "CryptoManager")
            throw CryptoManagerError.invalidKeyData
        }

        do {
            let result = try core.initReceivingSessionFromWirePayload(
                contactId: contactId,
                recipientBundle: bundle,
                wirePayload: [UInt8](firstMessage.rawPayload)
            )
            // The init burned a one-time Kyber key: persist the store now, or the key comes back
            // on the next launch and a replayed first message could open a second session on it.
            if let kyberPrekeys = result.kyberPrekeys {
                KyberPrekeyService.persist(blob: kyberPrekeys)
            }

            let plaintext = result.decryptedMessage
            // Never log the decrypted body itself. Release is protected by os_log's private-by-
            // default `%@` and by LogCollector being off, but INTERNAL_TOOLS builds persist this
            // line to a rotating file the user can export via DiagnosticLogShare — message
            // plaintext must not be in it. Length alone is enough to diagnose an init.
            Log.info("Session initialized successfully, decrypted \(plaintext.count)B", category: "CryptoManager")

            // The negotiated suite (3), which the core took from the message header.
            let negotiatedSuite = core.getSessionSuiteId(contactId: contactId)
            KeychainManager.shared.saveSessionSuiteId(userId: contactId, suiteId: negotiatedSuite > 0 ? negotiatedSuite : suiteID)

            // `contactId`, for the reason this whole function names a device rather than an
            // account: the session was opened under the key in the bundle, and `saveSession`
            // exports by the name it is given. Handed `userId` it resolves through the pinned
            // key, asks the core for a session that device does not have, and writes nothing —
            // `Session export failed: SessionNotFound` — while every log line around it says the
            // init succeeded. Measured 2026-09-06 on three of three inits that opened against a
            // device other than the pinned one, and on none of the inits that did not.
            //
            // The suite id above was already written under `contactId`. That is how far apart
            // the two halves of one fact had drifted.
            saveSession(contactId)

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
            let reason = "\(error)"
            if reason.contains("PQXDH_REQUIRED") {
                // A first message without the v2 handshake: the sender's build predates the
                // cutover. Nothing to repair on our side.
                Log.error("SESSION_STATE[pqxdh_required]: \(userId.prefix(8))… — sender is not on PQXDH v2", category: "SessionInit")
            } else if reason.contains("PQXDH_KEY_UNAVAILABLE") {
                // The Kyber prekey it names is gone (a one-time key already used, a signed prekey
                // past its 14 days). The sender's next init fetches a fresh bundle, so the plain
                // teardown the caller sends is the repair; the 3-DH hint below is about the
                // classic one-time key and does not apply.
                Log.error("SESSION_STATE[pqxdh_key_unavailable]: \(userId.prefix(8))… — \(reason)", category: "SessionInit")
            }
            if reason.contains("cannot reproduce") {
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
