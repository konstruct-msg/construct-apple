//
//  MessageCryptoService.swift
//  Construct Messenger
//
//  Extracted from CryptoManager (refactor)
//  M4: Migrated from ClassicCryptoCore+SessionStore → OrchestratorCore
//

import Foundation

final class MessageCryptoService {
    struct DecryptResult {
        let plaintext: Data
        let storageKey: Data  // 32-byte random key — store in MessageKeyStore keyed by message_id
    }

    /// Encrypt one copy, for one device, and return the wire payload the core packed.
    ///
    /// The payload is sent as it is. This returned components until 2026-09-28, and whoever
    /// carried them rebuilt a payload from a list of fields — the call-signal frame dropped the PN
    /// field and would have dropped the answer to a KEM identity key
    /// (`decisions/responder-authenticates-initiator-by-kem.md`).
    ///
    /// **Takes a device id.** A ciphertext is produced by one ratchet and readable by one device,
    /// so there is no version of this that takes a person: a message to someone with two devices
    /// is two calls here, which is what `OutboundMessagePipeline` does. Until step 6 of
    /// `decisions/a-peer-is-a-set-of-devices.md` this resolved an account id to the pinned device
    /// and encrypted for that one — the copy addressed to the account's second device was sealed
    /// to the first device's ratchet, and the second device could not open it.
    func encryptMessage(
        _ message: String,
        forDevice deviceId: String,
        core: OrchestratorCore?,
        restoreSession: (String) -> Bool,
        saveSession: (String) -> Bool,
        archiveSession: (String, ArchiveReason) -> Void
    ) throws -> Data {
        guard let core = core else {
            throw CryptoManagerError.coreNotInitialized
        }

        guard let contactId = SessionAddressing.asDevice(deviceId) else {
            throw CryptoManagerError.sessionNotFound
        }

        if !core.hasSession(contactId: contactId) {
            if !restoreSession(contactId) {
                throw CryptoManagerError.sessionNotFound
            }
        }

        guard core.hasSession(contactId: contactId) else {
            throw CryptoManagerError.sessionNotFound
        }

        #if DEBUG
        Log.debug("ENCRYPT: \(message.count) chars for device \(contactId.prefix(8))…", category: "CryptoManager")
        #endif

        do {
            let wire = try core.encryptToWire(contactId: contactId, plaintext: Data(message.utf8))

            // Fail-closed durability: core.encryptToWire above already advanced the sending chain.
            // Calls share this DR session with messages, so releasing this signaling ciphertext when
            // the advance is not durable risks a message-number-reuse desync on a crash + stale
            // reload. Refuse; the caller treats it as a signaling failure and retries.
            guard saveSession(contactId) else {
                Log.error("encryptMessage: session persist FAILED for \(contactId.prefix(8))… — refusing to release ciphertext (prevents ratchet number reuse)", category: "CryptoManager")
                throw CryptoManagerError.encryptionFailed
            }
            return wire
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

        // `contactIdOverride` is the sender's device when the envelope named one; `message.from`
        // is a device on every path that reaches here, because the sealed-sender resolve and the
        // candidate walk both hand one down. An account id is a defect, and `asDevice` says so
        // rather than quietly decrypting against the pinned device — which is how a message from
        // a peer's second device used to be fed to the first device's ratchet, failing to open
        // and then archiving the healthy session it was never sent on.
        let peerId = contactIdOverride ?? message.from
        guard let contactId = SessionAddressing.asDevice(peerId) else {
            throw CryptoManagerError.sessionNotFound
        }

        if !core.hasSession(contactId: contactId) {
            if !restoreSession(contactId) {
                throw CryptoManagerError.sessionNotFound
            }
        }

        guard core.hasSession(contactId: contactId) else {
            throw CryptoManagerError.sessionNotFound
        }

        // The whole payload, as it arrived: the core reads every field from it. Rebuilt from the
        // parsed components, the PN field and the answer to our KEM identity key were lost.
        guard !message.rawPayload.isEmpty else {
            Log.error("decryptMessage: \(message.id.prefix(8))… has no wire payload", category: "CryptoManager")
            throw CryptoManagerError.decryptionFailed
        }
        do {
            let result = try core.decryptWirePayload(contactId: contactId, wirePayload: message.rawPayload)
            saveSession(contactId)
            return DecryptResult(plaintext: result.plaintext, storageKey: result.storageKey)
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
