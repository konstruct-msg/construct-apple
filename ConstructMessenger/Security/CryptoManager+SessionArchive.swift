//
//  CryptoManager+SessionArchive.swift
//  Construct Messenger
//
//  Session archive CRUD extracted from CryptoManager:
//  archive, restore, cleanup, and fallback-decrypt with archived sessions.
//

import Foundation

extension CryptoManager {

    // MARK: - Archive Management

    func clearArchivedSessions(for userId: String) {
        archiveManager.clearArchives(for: userId)
        Log.info("Cleared all archived sessions for \(userId)", category: "CryptoManager")
    }

    func cleanupArchivedSessions() {
        let totalRemoved = archiveManager.cleanupExpiredArchives()
        if totalRemoved > 0 {
            Log.info("Garbage collection complete: removed \(totalRemoved) expired session archives", category: "CryptoManager")
        } else {
            Log.debug("Garbage collection: no expired archives found", category: "CryptoManager")
        }
    }

    func restoreRecentSessions(limit: Int = 10) {
        guard orchestratorCore != nil else {
            Log.error("Cannot restore sessions - core not initialized", category: "CryptoManager")
            return
        }

        var restoredCount = 0
        var failedCount = 0

        sessionRestoreService.restoreRecentSessions(limit: limit) { [weak self] contactId in
            guard let self = self else { return false }
            if self.restoreSession(for: contactId) {
                restoredCount += 1
                return true
            } else {
                failedCount += 1
                return false
            }
        }

        Log.info("Session restore: \(restoredCount) restored, \(failedCount) failed", category: "CryptoManager")
    }

    @discardableResult
    func restoreSession(for userId: String) -> Bool {
        coreLock.lock()
        defer { coreLock.unlock() }
        guard let core = orchestratorCore else { return false }
        if core.hasSession(contactId: SessionAddressing.contactId(forPeer: userId)) { return true }
        guard let sessionData = KeychainManager.shared.loadSessionData(for: SessionAddressing.contactId(forPeer: userId)) else {
            // Not an error: a chat can exist with no session on file — never messaged, or the
            // session was legitimately archived by END_SESSION / SESSION_RESET_INIT. Every caller
            // treats `false` as "establish one", and the bulk path reports the aggregate below.
            // This was ERROR until 2026-08-03 and fired on every launch for such contacts, which
            // is noise in the one signal a release run is judged by.
            Log.info("No stored session for \(userId.prefix(8))… — will be established on demand", category: "CryptoManager")
            return false
        }
        do {
            _ = try core.importSession(contactId: SessionAddressing.contactId(forPeer: userId), data: [UInt8](sessionData))
            Log.debug("Restored session (CFE): \(userId)", category: "CryptoManager")
            return true
        } catch {
            // Three causes reach here, and the error text distinguishes them: a corrupt blob, a
            // format the core no longer reads, and — since 2026-08-26 — an identity mismatch,
            // where the record names a contact or an author other than the one we are loading it
            // as. The entry is deleted in every case: an unusable blob left on disk is what let a
            // stale session resurrect on the next invite redeem (2026-08-17). A mismatch in
            // particular is a defect in whoever chose the storage key, not damaged data, so the
            // full error is logged rather than summarised.
            //
            // Delete cleanly rather than writing empty bytes (writing Data() followed by a failed
            // SecItemAdd would silently delete the key).
            KeychainManager.shared.deleteSession(for: SessionAddressing.contactId(forPeer: userId))
            Log.error("Session import FAILED for \(userId) (unusable — deleted): \(error)", category: "CryptoManager")
            return false
        }
    }

    func getSessionId(for userId: String) -> String? {
        return (orchestratorCore?.hasSession(contactId: SessionAddressing.contactId(forPeer: userId)) == true) ? userId : nil
    }

    // MARK: - Archive Write

    func archiveSession(for userId: String, reason: ArchiveReason) {
        coreLock.lock()
        defer { coreLock.unlock() }
        guard let core = orchestratorCore else {
            Log.error("Cannot archive session: Core not initialized", category: "CryptoManager")
            return
        }

        Log.info("Archiving session for \(userId), reason: \(reason.rawValue)", category: "CryptoManager")

        // A session lives in two places — the core's memory and the Keychain — and only the first
        // is loaded eagerly. `restoreRecentSessions` imports the recent ones at launch; a contact
        // nobody has messaged this run has its session on disk only, and `hasSession(for:)` says
        // no for it. Callers guarded on that answer, so deleting such a contact archived nothing
        // and deleted nothing: the Keychain entry outlived the contact.
        //
        // It then came back. On 2026-08-17 annie re-added a contact by QR; the redeem path called
        // `restoreSession`, the orphan was imported as if healthy, and her first message was
        // encrypted with a ratchet the peer had discarded when he deleted her. He could not
        // decrypt it — `All 1 prekey(s) failed` — and it was never resent.
        //
        // Import it here rather than making every caller ask twice. If the entry is unusable the
        // import throws, the branch below reports nothing to archive, and `restoreSession` deletes
        // it the next time anything reaches for it — so an entry that cannot be imported also
        // cannot resurrect a session.
        if core.hasSession(contactId: SessionAddressing.contactId(forPeer: userId)) == false,
           let stored = KeychainManager.shared.loadSessionData(for: SessionAddressing.contactId(forPeer: userId)) {
            do {
                _ = try core.importSession(contactId: SessionAddressing.contactId(forPeer: userId), data: [UInt8](stored))
                Log.info(
                    "archiveSession: imported on-disk session for \(userId.prefix(8))… before archiving",
                    category: "CryptoManager"
                )
            } catch {
                Log.error(
                    "archiveSession: stored session for \(userId.prefix(8))… could not be imported: \(error)",
                    category: "CryptoManager"
                )
            }
        }

        // 1. Export current session to CFE binary format and store archive.
        //    IMPORTANT: only proceed with deletion if export succeeded — otherwise the session
        //    would be permanently lost with no archive to restore from.
        do {
            let sessionData = Data(try core.exportSession(contactId: SessionAddressing.contactId(forPeer: userId)))

            let archive = SessionArchive(
                sessionData: sessionData,
                archivedAt: Date(),
                reason: reason
            )
            archiveManager.storeArchive(archive, for: userId)
            let count = archiveManager.loadArchives(for: userId)?.count ?? 0
            Log.info("Session archived (\(count) total for user)", category: "CryptoManager")
        } catch {
            // If the session is already gone from Rust (SessionNotFound) and we already have
            // an archive (e.g. Rust archived it when we received END_SESSION first), treat
            // this as a successful archive-by-other-means and just clean up.
            let existingCount = archiveManager.loadArchives(for: userId)?.count ?? 0
            if existingCount > 0 {
                Log.info("archiveSession: session already archived via Rust for \(userId.prefix(8))… (reason: \(reason.rawValue)), cleaning up", category: "CryptoManager")
                KeychainManager.shared.deleteSessionSuiteId(userId: SessionAddressing.contactId(forPeer: userId))
                _ = orchestratorCore?.removeSession(contactId: SessionAddressing.contactId(forPeer: userId))
                KeychainManager.shared.deleteSession(for: SessionAddressing.contactId(forPeer: userId))
                return
            }
            // Third case, previously folded into the failure above: there was never a session
            // here to archive. `archiveSession` is reached from teardown paths that do not
            // check first — a fresh invite redeem calls it one line after logging "No stored
            // session for <peer>" — and the outcome was an error-level line claiming deletion
            // was withheld "to prevent data loss" for something that never existed. A device
            // log from 2026-08-17 shows that pair one second after a QR was scanned.
            //
            // The export attempt stays the authority on whether an archive was written, so the
            // outcome is unchanged in every case: both branches return without deleting. Only
            // the severity moves, and only when the core agrees nothing is there.
            if core.hasSession(contactId: SessionAddressing.contactId(forPeer: userId)) == false {
                Log.info(
                    "archiveSession: nothing to archive for \(userId.prefix(8))… (reason: \(reason.rawValue))",
                    category: "CryptoManager"
                )
                return
            }
            Log.error("Failed to export session for archiving — session NOT deleted to prevent data loss: \(error)", category: "CryptoManager")
            // Do not proceed with deletion: losing the session without an archive
            // would permanently break communication with this contact.
            return
        }

        // 2. Remove from active storage — only reached when archive is safely stored above.
        KeychainManager.shared.deleteSessionSuiteId(userId: SessionAddressing.contactId(forPeer: userId))
        Log.info("Removed session suite ID from Keychain: \(userId)", category: "CryptoManager")

        let removed = (orchestratorCore?.removeSession(contactId: SessionAddressing.contactId(forPeer: userId))) ?? false
        if removed {
            Log.info("Removed session from Rust core: \(userId)", category: "CryptoManager")
        } else {
            Log.info("Session not found in Rust core: \(userId)", category: "CryptoManager")
        }

        KeychainManager.shared.deleteSession(for: SessionAddressing.contactId(forPeer: userId))
        Log.info("Removed session from Keychain: \(userId)", category: "CryptoManager")
    }

    /// Store a session archive produced by Rust's `lifecycle.archive_session` and clear the
    /// Keychain hot entry so `restoreSession()` cannot reimport stale state.
    ///
    /// Rust has already removed the session from memory — do NOT call `exportSession` here.
    func acceptSessionTerminated(contactId: String, archiveBytes: Data) {
        guard !archiveBytes.isEmpty else {
            Log.error("acceptSessionTerminated: empty archive for \(contactId.prefix(8))…", category: "CryptoManager")
            return
        }
        let archive = SessionArchive(sessionData: archiveBytes, archivedAt: Date(), reason: .endSessionReceived)
        archiveManager.storeArchive(archive, for: contactId)
        let count = archiveManager.loadArchives(for: contactId)?.count ?? 0
        Log.info("acceptSessionTerminated: archived session for \(contactId.prefix(8))… (\(count) total)", category: "CryptoManager")
        KeychainManager.shared.deleteSession(for: SessionAddressing.contactId(forPeer: contactId))
        KeychainManager.shared.deleteSessionSuiteId(userId: SessionAddressing.contactId(forPeer: contactId))
    }

    // MARK: - Archive Restore

    /// Used for tie-breaking when we are the INITIATOR in a dual-INITIATOR clash:
    /// after a failed decrypt the INITIATOR session was just moved to archives —
    /// this undoes that and makes it active again so we keep the INITIATOR role.
    @discardableResult
    func restoreLatestArchive(for userId: String) -> Bool {
        coreLock.lock()
        defer { coreLock.unlock() }
        guard let core = orchestratorCore,
              let archives = archiveManager.loadArchives(for: userId),
              !archives.isEmpty else { return false }
        let idx = archives.count - 1
        let latest = archives[idx]
        do {
            let suiteIdBefore = KeychainManager.shared.loadSessionSuiteId(userId: userId) ?? 0
            _ = try core.importSession(contactId: SessionAddressing.contactId(forPeer: userId), data: [UInt8](latest.sessionData))
            // Use typed accessor — no JSON round-trip needed.
            let suiteId = core.getSessionSuiteId(contactId: SessionAddressing.contactId(forPeer: userId))
            if suiteId > 0 {
                KeychainManager.shared.saveSessionSuiteId(userId: SessionAddressing.contactId(forPeer: userId), suiteId: suiteId)
                Log.info("SESSION_STATE[restore_suite_id]: peer=\(userId.prefix(8))… suiteId \(suiteIdBefore) → \(suiteId)", category: "SessionInit")
            } else {
                Log.error("SESSION_STATE[restore_suite_id_failed]: peer=\(userId.prefix(8))… suiteId_before=\(suiteIdBefore) — getSessionSuiteId returned 0 after import; remote decrypt will likely fail", category: "CryptoManager")
            }
            saveSessionToKeychain(for: userId)
            archiveManager.restoreArchiveToCurrent(for: userId, index: idx)
            Log.info("Restored INITIATOR session from archive for \(userId.prefix(8))… (tie-break)", category: "CryptoManager")
            return true
        } catch {
            Log.error("restoreLatestArchive failed for \(userId.prefix(8))…: \(error)", category: "CryptoManager")
            return false
        }
    }

    // MARK: - Fallback Decrypt

    /// Try to decrypt message with archived sessions.
    /// Returns raw plaintext bytes if successful, throws if all archives fail.
    func tryDecryptWithArchivedSessions(message: ChatMessage) throws -> Data {
        coreLock.lock()
        defer { coreLock.unlock() }
        guard let core = orchestratorCore else {
            throw CryptoManagerError.coreNotInitialized
        }

        let archives = archiveManager.loadArchives(for: message.from)

        guard let archives = archives, !archives.isEmpty else {
            Log.debug("No archived sessions available for \(message.from)", category: "CryptoManager")
            throw CryptoManagerError.sessionNotFound
        }

        Log.info("Trying \(archives.count) archived sessions for \(message.from)", category: "CryptoManager")

        // Snapshot the active session so we can restore it if all archives fail.
        let activeSessionSnapshot = try? Data(core.exportSession(contactId: SessionAddressing.contactId(forPeer: message.from)))

        for (index, archive) in archives.enumerated().reversed() {
            do {
                _ = try core.importSession(contactId: SessionAddressing.contactId(forPeer: message.from), data: [UInt8](archive.sessionData))

                let rawContent = message.content
                let contentBytes = [UInt8](rawContent)
                let result = try core.decryptMessage(
                    contactId: SessionAddressing.contactId(forPeer: message.from),
                    ephemeralPublicKey: [UInt8](message.ephemeralPublicKey),
                    messageNumber: message.messageNumber,
                    content: contentBytes,
                    suiteId: message.suiteId,
                    pqMessageEpoch: message.pqMessageEpoch,
                    pqRatchetField: [UInt8](message.pqRatchetField)
                )

                Log.info("Decrypted with archived session #\(index) (archived at: \(archive.archivedAt))", category: "CryptoManager")
                saveSessionToKeychain(for: message.from)
                archiveManager.restoreArchiveToCurrent(for: message.from, index: index)
                Log.info("Restored archived session as current", category: "CryptoManager")
                return Data(result.plaintext)

            } catch {
                Log.debug("Archive #\(index) failed: \(error)", category: "CryptoManager")
                continue
            }
        }

        if let snap = activeSessionSnapshot {
            _ = try? core.importSession(contactId: SessionAddressing.contactId(forPeer: message.from), data: [UInt8](snap))
        }

        Log.info("All \(archives.count) archived sessions failed to decrypt", category: "CryptoManager")
        throw CryptoManagerError.decryptionFailed
    }
}
