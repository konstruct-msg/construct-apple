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
    /// (`reopenSession`); on any refusal it stays exactly as it was. The core keeps the replaced
    /// state as a previous one, for messages still in flight on it
    /// (`decisions/sessions-renew-by-sending.md`). A degraded (`allowStale`) open is the same.
    func initializeSession(
        for userId: String,
        bundle: PublicKeyBundleData,
        withoutOneTimePrekey: Bool = false,
        allowStale: Bool = false,
        core: OrchestratorCore?,
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
            switch (held, allowStale) {
            case (true, false):
                sessionId = try core.reopenSession(contactId: contactId, recipientBundle: binary)
            case (true, true):
                sessionId = try core.reopenSessionAllowingStale(contactId: contactId, recipientBundle: binary)
            case (false, false):
                sessionId = try core.initSession(contactId: contactId, recipientBundle: binary)
            case (false, true):
                sessionId = try core.initSessionAllowingStale(contactId: contactId, recipientBundle: binary)
            }
            // The NEGOTIATED suite (always 3 since PQXDH v2), not the bundle's: that only ever says 1/2.
            let negotiatedSuite = core.getSessionSuiteId(contactId: contactId)
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
        } catch CryptoError.PeerSpkStale(let ageSecs) {
            let ageDays = Double(ageSecs) / 86400.0
            Log.error("Peer SPK stale for \(userId.prefix(8))… — age ≈ \(String(format: "%.1f", ageDays))d", category: "CryptoManager")
            throw SessionError.peerSPKStale(ageDays: ageDays)
        } catch CryptoError.PeerSpkEpochRegressed(let received, let known) {
            // The core keeps the highest SPK rotation epoch per device and refused this bundle
            // before spending anything on it (core 0.53, TODO 176). Nothing was created; a held
            // session is still there.
            let detail = "epoch \(received) is below the \(known) already admitted"
            Log.error("SESSION_STATE[spk_replay_rejected]: \(contactId.prefix(8))… — \(detail)", category: "SessionInit")
            throw SessionError.staleSPKBundle(detail: detail)
        } catch CryptoError.PqRequired(let reason) {
            // Nothing was created, and a held session is still there. The reason names what the
            // bundle lacked; the peer is usually on a build from before PQXDH v2.
            Log.error("SESSION_STATE[pq_required]: \(contactId.prefix(8))… — \(reason)", category: "SessionInit")
            throw SessionError.peerNotPostQuantum(reason: reason)
        } catch {
            Log.error("Rust core initSession failed: \(error)", category: "CryptoManager")
            throw CryptoManagerError.sessionInitializationFailed
        }
    }

    /// Open a receiving session from `message` alone, with the key its sender certificate names —
    /// the core checks the certificate; nothing is fetched. For a message that does not wait in the
    /// core's queue (a sibling's SENDER_SYNC); everything else opens through `open_receiving`.
    func openReceiving(
        _ message: ChatMessage,
        core: OrchestratorCore?,
        saveSession: (String) -> Void
    ) throws -> (device: String, plaintext: Data) {
        guard let core else {
            throw CryptoManagerError.coreNotInitialized
        }
        guard let certificate = message.senderCertificate else {
            Log.error("SESSION_STATE[init_refused_unsealed]: \(message.id.prefix(8))… — no sender certificate to open from", category: "SessionInit")
            throw CryptoManagerError.invalidKeyData
        }
        let initKind = message.initKind
        guard initKind == .handshake else {
            Log.error(
                "SESSION_STATE[init_refused_not_handshake]: \(message.id.prefix(8))… kind=\(initKind) msgNum=\(message.messageNumber)",
                category: "SessionInit"
            )
            throw SessionError.notAHandshakeCarrier
        }
        guard !message.rawPayload.isEmpty else {
            Log.error("SESSION_STATE[init_refused_no_payload]: \(message.id.prefix(8))… — first message without its wire payload", category: "SessionInit")
            throw CryptoManagerError.invalidKeyData
        }

        // The device is the one the certificate names; the core refuses the open if its key does
        // not derive to it. What is held for that device now becomes a previous state in the
        // core — archiving it here, as this did until 2026-09-27, threw away what the sibling
        // still had in flight on it.

        do {
            let result = try core.initReceivingSessionFromWirePayload(
                senderCertificate: certificate,
                wirePayload: message.rawPayload
            )
            // The init burned a one-time Kyber key: persist the store now, or the key comes back
            // on the next launch and a replayed first message could open a second session on it.
            if let kyberPrekeys = result.kyberPrekeys {
                KyberPrekeyService.persist(blob: kyberPrekeys)
            }
            let device = result.sessionId
            saveSession(device)
            // Never log the body: INTERNAL_TOOLS builds persist this line to an exportable file.
            Log.info("SESSION_STATE[open_receiving_single]: \(device.prefix(8))… opened from \(message.id.prefix(8))…, \(result.decryptedMessage.count)B", category: "SessionInit")
            return (device, result.decryptedMessage)
        } catch {
            let reason = "\(error)"
            Log.error("SESSION_STATE[open_receiving_single_failed]: \(message.id.prefix(8))… — \(reason)", category: "SessionInit")
            throw CryptoManagerError.sessionInitializationFailed
        }
    }
}
