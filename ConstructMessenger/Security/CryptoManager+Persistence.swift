//
//  CryptoManager+Persistence.swift
//  Construct Messenger
//
//  Session and orchestrator-state persistence: Keychain save/reload,
//  CFE load/save and the ACK dedup cache plumbing.
//
//  Moved verbatim out of CryptoManager.swift (TODO 184); behaviour unchanged.
//

import Foundation
import CoreData
import os.log

extension CryptoManager {

    // MARK: - Session Persistence

    /// Save session to Keychain after state change.
    /// Includes verify-after-write: reads back the blob to confirm integrity.
    /// Persists the DR session (sending/receiving chains) for `userId`, with verify-after-write.
    /// Returns `true` iff the session was durably written and verified. The sender encrypt path
    /// (`MessageCryptoService.encryptMessage`) gates the release of a ciphertext on this so an
    /// un-persisted sending-chain advance never reaches the peer (message-number-reuse desync).
    @discardableResult
    func saveSessionToKeychain(forDevice deviceId: String) -> Bool {
        coreLock.lock()
        defer { coreLock.unlock() }
        guard let core = orchestratorCore else { return false }
        do {
            guard let contactId = SessionAddressing.asDevice(deviceId) else { return false }
            let sessionData = try core.exportSession(contactId: contactId)
            var saved = false
            for attempt in 1...3 {
                saved = KeychainManager.shared.saveSessionData(sessionData, for: contactId)
                guard saved else {
                    Log.error("Keychain write failed (attempt \(attempt)/3): \(contactId)", category: "CryptoManager")
                    continue
                }
                // Verify round-trip: read back and compare byte count.
                if let readBack = KeychainManager.shared.loadSessionData(for: contactId),
                   readBack.count == sessionData.count {
                    Log.debug("Session saved+verified (\(sessionData.count)B): \(contactId)", category: "CryptoManager")
                    return true
                }
                Log.error("Session verify-after-write mismatch (attempt \(attempt)/3): \(contactId)", category: "CryptoManager")
            }
            Log.error("Failed to save session to Keychain after 3 attempts: \(contactId)", category: "CryptoManager")
            return false
        } catch {
            Log.error("Session export failed: \(error)", category: "CryptoManager")
            return false
        }
    }

    /// Persist the current Rust core private key state to Keychain.
    ///
    /// Call after in-core mutations (e.g., SPK rotation via `rotateSignedPrekey()`)
    /// so the updated state survives app restarts.
    /// Persist the current Rust core state (private keys incl. SPK) to Keychain.
    ///
    /// - Returns: `true` if the Keychain write succeeded; `false` on any failure.
    ///   Callers that MUST NOT proceed with a stale Keychain (e.g. SPK rotation)
    ///   should check the return value and roll back if `false`.
    @discardableResult
    func persistCoreState() -> Bool {
        coreLock.lock()
        defer { coreLock.unlock() }
        guard let core = orchestratorCore else {
            Log.error("persistCoreState: core not initialized", category: "CryptoManager")
            return false
        }
        do {
            let data = try core.exportPrivateKeys()
            let saved = KeychainManager.shared.savePrivateKeys(data)
            if saved {
                Log.info("Persisted Rust core state (CFE) to Keychain", category: "CryptoManager")
            } else {
                Log.error("Failed to persist Rust core state — Keychain save returned false", category: "CryptoManager")
            }
            return saved
        } catch {
            Log.error("persistCoreState: export failed: \(error)", category: "CryptoManager")
            return false
        }
    }

    /// Reload the Rust core from Keychain, discarding any in-memory mutations.
    ///
    /// Call after a failed SPK rotation to roll back the in-memory state change
    /// made by `rotateSignedPrekey()`, ensuring the core stays in sync with the
    /// Keychain (and thus with what the server has).
    func reloadCoreFromKeychain() {
        coreLock.lock()
        defer { coreLock.unlock() }
        guard _cachedUserId != nil else {
            Log.error("reloadCoreFromKeychain: no cached userId — cannot recreate OrchestratorCore", category: "CryptoManager")
            return
        }
        guard let keysData = KeychainManager.shared.loadPrivateKeysData() else {
            Log.error("reloadCoreFromKeychain: failed to reload — Keychain state unavailable", category: "CryptoManager")
            return
        }
        let cryptoId = cryptoLocalUserId
        do {
            let newCore = try createOrchestratorCoreFromKeys(keysData: keysData, myUserId: cryptoId)
            if let otpksData = KeychainManager.shared.loadOtpksData() {
                do {
                    try newCore.importOneTimePrekeys(data: otpksData)
                    Log.debug("Imported OTPKs on core reload (\(newCore.oneTimePrekeyCount()) keys)", category: "CryptoManager")
                } catch {
                    // CFE decode of the persisted OTPK blob failed → the core's private OTPK
                    // store comes up EMPTY while the server still holds OTPKs whose private keys
                    // we just lost. Left silent, this desyncs local↔server and every inbound X3DH
                    // that used one of those OTPKs fails ("OTPK id not found"), driving the
                    // session-init reset storm (see otpk-session-init-deadlock). Force a single
                    // consistent replace-all on the next upload so counter/store/server reconverge.
                    Log.fault("Failed to import OTPKs on core reload — forcing full OTPK replacement: \(error)", category: "CryptoManager")
                    needsFullOtpkReplacement = true
                }
            }
            if !KyberPrekeyService.restore(into: newCore) {
                needsFullOtpkReplacement = true
            }
            loadOrchestratorStateCFE(into: newCore)
            orchestratorCore = newCore
            Log.info("Rust core reloaded from Keychain (CFE)", category: "CryptoManager")
        } catch {
            Log.error("reloadCoreFromKeychain: OrchestratorCore init failed: \(error)", category: "CryptoManager")
        }
    }

    // MARK: - Orchestrator State CFE Persistence

    static let orchestratorStateCFEKey = "construct.orchestrator_state"

    /// Save the full orchestrator coordination state (ACK cache, healing queue,
    /// init locks, archive index) to Keychain as a CFE blob.
    /// Call after any significant state change in the orchestrator.
    /// Persists the orchestrator coordination state to the Keychain.
    /// Returns `true` iff the state was durably written. Callers on the send path
    /// (`OutboundSessionService.executeStorageActions` → `encryptOutgoing`) gate the release of a
    /// ciphertext on this: a failed save must not let an un-persisted ratchet advance reach the peer.
    @discardableResult
    func saveOrchestratorStateCFE() -> Bool {
        coreLock.lock()
        defer { coreLock.unlock() }
        guard let core = orchestratorCore else { return false }
        do {
            let blob = try core.exportOrchestratorState()
            // AfterFirstUnlock (not WhenUnlocked): the Double Ratchet state advances during
            // background push-driven decrypt while the device is locked. A WhenUnlocked save
            // fails there → the advanced ratchet is never persisted → desync on next launch.
            let ok = KeychainManager.shared.saveData(
                Data(blob),
                forKey: Self.orchestratorStateCFEKey,
                accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            )
            if ok {
                Log.debug("Orchestrator state saved (CFE, \(blob.count)B)", category: "CryptoManager")
            } else {
                Log.error("Orchestrator state CFE save failed (Keychain write error)", category: "CryptoManager")
            }
            return ok
        } catch {
            Log.error("Orchestrator state CFE export failed: \(error)", category: "CryptoManager")
            return false
        }
    }

    /// Restore the orchestrator coordination state into `core` from Keychain.
    /// Called during `reloadCoreFromKeychain` and `setLocalUserId`.
    func loadOrchestratorStateCFE(into core: OrchestratorCore) {
        // One-time migration: older builds stored this under WhenUnlockedThisDeviceOnly, which
        // fails to save during background/locked push decrypt → the advanced ratchet is lost →
        // session desync on next launch. SecItemUpdate can't change accessibility, so re-add the
        // item once. Runs here (foreground restore, device unlocked); the flag is set only after
        // a confirmed re-add so a locked/absent read retries on the next launch.
        let migrationFlag = "construct.orchestrator_state.afu_migrated.v1"
        if !UserDefaults.standard.bool(forKey: migrationFlag) {
            if KeychainManager.shared.migrateAccessibility(
                forKey: Self.orchestratorStateCFEKey,
                to: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ) {
                UserDefaults.standard.set(true, forKey: migrationFlag)
                Log.info("Migrated orchestrator state Keychain accessibility → AfterFirstUnlock", category: "CryptoManager")
            }
        }
        guard let data = KeychainManager.shared.loadData(forKey: Self.orchestratorStateCFEKey) else {
            Log.debug("No orchestrator state CFE found in Keychain (first launch or cleared)", category: "CryptoManager")
            // Fresh orchestrator: next_otpk_id resets to 1,000,000. Any OTPKs on the server
            // from a previous partial upload share those IDs but have different key material.
            // Force a replace-all on the next OTPK upload to eliminate the stale server keys.
            needsFullOtpkReplacement = true
            return
        }
        do {
            try core.importOrchestratorState(data: data)
            Log.info("Orchestrator state restored (CFE, \(data.count)B)", category: "CryptoManager")
        } catch {
            Log.error("Orchestrator state CFE import failed: \(error) — starting fresh", category: "CryptoManager")
        }
    }

    /// Delete the persisted orchestrator state (e.g., on full account reset).
    func clearOrchestratorStateCFE() {
        KeychainManager.shared.deleteData(forKey: Self.orchestratorStateCFEKey)
        Log.debug("Orchestrator state CFE cleared", category: "CryptoManager")
    }

    // MARK: - ACK dedup cache
    //
    // There is exactly **one** in-memory ACK cache: the orchestrator's `lifecycle.ack_store`.
    // `PersistentACKStore` used to own a second, independent `RustAckStore`, so the same
    // question ("was this message processed?") had two answers that were written by different
    // call sites and never reconciled — see decisions/one-ack-cache-one-durable-store.md.
    //
    // This cache does **not** survive a restart. `export_orchestrator_state_cfe` writes an
    // empty `processed_ids` on purpose (snapshotting it grew the blob without bound), so the
    // durable owner of dedup state is Core Data `ProcessedMessage`, and a cache miss after
    // launch falls through to it via `Action::CheckAckInDb`.

    /// Whether the orchestrator core exists, i.e. whether the ACK cache can be written at all.
    var isOrchestratorCoreUp: Bool {
        coreLock.lock()
        defer { coreLock.unlock() }
        return orchestratorCore != nil
    }

    /// Ask the orchestrator's ACK cache about `messageId`.
    ///
    /// Returns `nil` when the core is not up (pre-login, tests) — the caller must then treat
    /// the question as unanswered and consult Core Data, which is the durable owner anyway.
    func ackIsProcessedInOrchestrator(messageId: String) -> AckCheckResult? {
        coreLock.lock()
        defer { coreLock.unlock() }
        return orchestratorCore?.ackIsProcessed(messageId: messageId)
    }

    /// Mark an ACK as processed in the orchestrator's ACK cache (serialized).
    func markAckProcessedInOrchestrator(messageId: String) {
        coreLock.lock()
        defer { coreLock.unlock() }
        orchestratorCore?.ackMarkProcessed(messageId: messageId)
    }
}
