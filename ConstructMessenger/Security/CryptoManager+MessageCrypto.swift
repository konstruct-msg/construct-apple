//
//  CryptoManager+MessageCrypto.swift
//  Construct Messenger
//
//  Message encryption/decryption and call-signal decryption.
//
//  Moved verbatim out of CryptoManager.swift (TODO 184); behaviour unchanged.
//

import Foundation
import CoreData
import os.log

extension CryptoManager {

    // MARK: - Encryption / Decryption

    /// Encrypts a plaintext message for **one device** of the recipient and returns the wire
    /// payload, sent as it is.
    ///
    /// One call, one copy, one ratchet — `OutboundMessagePipeline` loops the recipient's device
    /// set and calls this once per device. See `decisions/a-peer-is-a-set-of-devices.md`.
    func encryptMessage(_ message: String, forDevice deviceId: String) throws -> Data {
        // coreLock serializes Rust FFI calls so that a background task and the main
        // actor cannot advance the DR ratchet concurrently (would corrupt chain state).
        coreLock.lock()
        defer { coreLock.unlock() }
        let wire = try messageCrypto.encryptMessage(
            message,
            forDevice: deviceId,
            core: orchestratorCore,
            restoreSession: { [weak self] device in
                Log.info("Session not in memory, attempting restore: \(device)", category: "CryptoManager")
                return self?.restoreSession(for: device) ?? false
            },
            saveSession: { [weak self] device in
                self?.saveSessionToKeychain(forDevice: device) ?? false
            },
            archiveSession: { [weak self] device, reason in
                Log.debug("Archiving session for \(device) to allow reinitialization", category: "CryptoManager")
                self?.archiveSession(for: device, reason: reason)
            }
        )

        Log.debug("ENCRYPT: \(wire.count)-byte wire payload for \(deviceId.prefix(8))…", category: "CryptoManager")
        return wire
    }

    /// Decrypt a ChatMessage directly using clean API
    /// Uses clean API - Rust handles all MessagePack internally
    /// Now with Session Archive fallback support
    func decryptMessage(_ message: ChatMessage) throws -> MessageDecryptResult {
        try decryptMessage(message, contactIdOverride: nil)
    }

    /// - Parameter claimedByThisHandler: the caller has already marked this id processed **as part
    ///   of handling it right now**, and is asking which session opens it. The duplicate guard
    ///   below then has to be skipped: it would otherwise refuse a decrypt on the strength of the
    ///   caller's own claim, made moments earlier.
    ///
    ///   Only `openSenderSync` passes true, and it is the only caller that decrypts one message id
    ///   more than once — walking its own-device sessions to find which sibling sent it. See the
    ///   guard for what this cost.
    func decryptMessage(
        _ message: ChatMessage,
        contactIdOverride: String?,
        claimedByThisHandler: Bool = false
    ) throws -> MessageDecryptResult {
        let logContactId = contactIdOverride ?? message.from
        Log.debug("Decrypting message \(message.id.prefix(8))... contactId=\(logContactId.prefix(16))...", category: "CryptoManager")
        Log.debug("messageNumber: \(message.messageNumber) payload: \(message.rawPayload.count)B", category: "CryptoManager")

        // Last-resort duplicate guard: if this message was already processed in this launch,
        // the DR state has already advanced past it. Attempting to decrypt would fail and
        // incorrectly archive a healthy session — throw duplicateMessage instead so the caller
        // can skip silently without triggering session recovery.
        //
        // Since the two ACK caches were merged (2026-08-02) this also sees marks made by the
        // Rust decrypt path itself, which the old Swift-side cache never did. The previous
        // comment here named `routeIncomingMessage` as the writer; it never called `preemptACK`
        // — the only writer was `PublicKeyBundleHandler`, plus the warm-up after a durable ACK.
        //
        // **The guard cannot see a claim the caller made about the delivery it is still handling.**
        // `routeIncomingMessage` marks a SENDER_SYNC processed *before* calling its handler, to
        // close the redelivery window — and that handler then asks this function, once per
        // candidate session, which one opens the message. Every candidate was refused on the
        // strength of that claim, so `openSenderSync` concluded "no own-device session" and dropped
        // the message. Devices 0b4577bc…/b26a2cf8…, 2026-08-27: the first sync of a conversation
        // survived (messageNumber 0 takes the init path, which does not consult this guard) and
        // **every subsequent one was lost** — silently, on every multi-device account.
        if !claimedByThisHandler, PersistentACKStore.shared.isProcessedInMemory(message.id) {
            Log.info("CryptoManager: \(message.id.prefix(8))… already in ACK cache — skipping duplicate decrypt", category: "CryptoManager")
            throw CryptoManagerError.duplicateMessage
        }

        // coreLock serializes decrypt alongside encrypt — concurrent decrypts on the same
        // session advance the DR receive chain non-deterministically.
        coreLock.lock()
        defer { coreLock.unlock() }
        let decryptResult: MessageCryptoService.DecryptResult
        do {
            decryptResult = try messageCrypto.decryptMessage(
                message,
                contactIdOverride: contactIdOverride,
                core: orchestratorCore,
                restoreSession: { [weak self] userId in
                    Log.info("Session not in memory, attempting restore: \(userId)", category: "CryptoManager")
                    return self?.restoreSession(for: userId) ?? false
                },
                saveSession: { [weak self] deviceId in
                    self?.saveSessionToKeychain(forDevice: deviceId)
                },
                archiveSession: { [weak self] userId, reason in
                    // ERROR-level so this appears in exported logs even at INFO filter.
                    // The message ID is included so the log can be correlated with the
                    // BackgroundFetch / MessageStream event that triggered the archive.
                    Log.error("CryptoManager: archiving session for \(userId.prefix(8))… reason=\(reason) msgId=\(message.id.prefix(8))… msgNum=\(message.messageNumber)", category: "CryptoManager")
                    self?.archiveSession(for: userId, reason: reason)
                },
                tryDecryptWithArchived: { [weak self] message in
                    guard let self = self else {
                        throw CryptoManagerError.decryptionFailed
                    }
                    let plaintext = try self.tryDecryptWithArchivedSessions(message: message)
                    Log.info("Successfully decrypted with archived session!", category: "CryptoManager")
                    return plaintext
                }
            )
        } catch {
            Log.error("Rust core decryptMessage failed for \(message.id.prefix(8))… msgNum=\(message.messageNumber): \(error)", category: "CryptoManager")
            throw error
        }

        Log.info("Message decrypted successfully (messageNumber: \(message.messageNumber), plaintext: \(decryptResult.plaintext.count) bytes)", category: "CryptoManager")
        return MessageDecryptResult(plaintext: decryptResult.plaintext, storageKey: decryptResult.storageKey)
    }

    /// Decrypt a call-signal field — a wire payload the core packed (`encryptMessage(_:forDevice:)`).
    /// Returns UTF-8 (call signals are always valid UTF-8). Restores the session from Keychain if
    /// needed; does not try archived sessions.
    func decryptCallSignal(contactId: String, wirePayload: Data) throws -> String {
        coreLock.lock()
        defer { coreLock.unlock() }

        guard let core = orchestratorCore else {
            throw CryptoManagerError.coreNotInitialized
        }

        guard let resolved = SessionAddressing.asDevice(contactId) else {
            throw CryptoManagerError.sessionNotFound
        }
        if !core.hasSession(contactId: resolved) {
            if !restoreSession(for: resolved) {
                throw CryptoManagerError.sessionNotFound
            }
        }

        guard core.hasSession(contactId: resolved) else {
            throw CryptoManagerError.sessionNotFound
        }

        let result = try core.decryptWirePayload(contactId: resolved, wirePayload: wirePayload)
        saveSessionToKeychain(forDevice: resolved)
        return String(data: result.plaintext, encoding: .utf8) ?? ""
    }
}
