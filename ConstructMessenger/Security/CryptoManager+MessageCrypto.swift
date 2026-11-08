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
            }
        )

        Log.debug("ENCRYPT: \(wire.count)-byte wire payload for \(deviceId.prefix(8))…", category: "CryptoManager")
        return wire
    }

    /// Decrypt a ChatMessage directly using clean API
    /// Uses clean API - Rust handles all MessagePack internally
    func decryptMessage(_ message: ChatMessage) throws -> MessageDecryptResult {
        try decryptMessage(message, contactIdOverride: nil)
    }

    func decryptMessage(
        _ message: ChatMessage,
        contactIdOverride: String?
    ) throws -> MessageDecryptResult {
        let logContactId = contactIdOverride ?? message.from
        Log.debug("Decrypting message \(message.id.prefix(8))... contactId=\(logContactId.prefix(16))...", category: "CryptoManager")
        Log.debug("messageNumber: \(message.messageNumber) payload: \(message.rawPayload.count)B", category: "CryptoManager")

        // No "already processed?" here. Whether a message was handled before is the core's answer
        // (`decisions/one-answer-to-already-processed.md`); the one caller left, `openSenderSync`,
        // is reached only after the router asked it for a SENDER_SYNC. Until 2026-11-08 a guard on
        // the ACK cache sat here, skipped by that caller's `claimedByThisHandler` and so read by
        // nothing in production; on 2026-08-27, before the flag, it dropped every SENDER_SYNC after
        // the first (todo/252).
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
    /// needed.
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
