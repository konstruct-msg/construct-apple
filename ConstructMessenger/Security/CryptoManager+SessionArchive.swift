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
        if core.hasSession(contactId: userId) { return true }
        guard let sessionData = KeychainManager.shared.loadSessionData(for: userId) else {
            Log.error("No session data in Keychain for \(userId) — session must be re-established", category: "CryptoManager")
            return false
        }
        do {
            _ = try core.importSession(contactId: userId, data: [UInt8](sessionData))
            Log.debug("Restored session (CFE): \(userId)", category: "CryptoManager")
            return true
        } catch {
            // Delete the corrupt/incompatible entry cleanly instead of writing empty bytes
            // (writing Data() followed by a failed SecItemAdd would silently delete the key).
            KeychainManager.shared.deleteSession(for: userId)
            Log.error("Session import FAILED for \(userId) (corrupt/incompatible — deleted): \(error)", category: "CryptoManager")
            return false
        }
    }

    func getSessionId(for userId: String) -> String? {
        return (orchestratorCore?.hasSession(contactId: userId) == true) ? userId : nil
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

        // 1. Export current session to CFE binary format and store archive.
        //    IMPORTANT: only proceed with deletion if export succeeded — otherwise the session
        //    would be permanently lost with no archive to restore from.
        do {
            let sessionData = Data(try core.exportSession(contactId: userId))

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
                KeychainManager.shared.deleteSessionSuiteId(userId: userId)
                _ = orchestratorCore?.removeSession(contactId: userId)
                KeychainManager.shared.deleteSession(for: userId)
                return
            }
            Log.error("Failed to export session for archiving — session NOT deleted to prevent data loss: \(error)", category: "CryptoManager")
            // Do not proceed with deletion: losing the session without an archive
            // would permanently break communication with this contact.
            return
        }

        // 2. Remove from active storage — only reached when archive is safely stored above.
        KeychainManager.shared.deleteSessionSuiteId(userId: userId)
        Log.info("Removed session suite ID from Keychain: \(userId)", category: "CryptoManager")

        let removed = (orchestratorCore?.removeSession(contactId: userId)) ?? false
        if removed {
            Log.info("Removed session from Rust core: \(userId)", category: "CryptoManager")
        } else {
            Log.info("Session not found in Rust core: \(userId)", category: "CryptoManager")
        }

        KeychainManager.shared.deleteSession(for: userId)
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
        KeychainManager.shared.deleteSession(for: contactId)
        KeychainManager.shared.deleteSessionSuiteId(userId: contactId)
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
            _ = try core.importSession(contactId: userId, data: [UInt8](latest.sessionData))
            // Use typed accessor — no JSON round-trip needed.
            let suiteId = core.getSessionSuiteId(contactId: userId)
            if suiteId > 0 {
                KeychainManager.shared.saveSessionSuiteId(userId: userId, suiteId: suiteId)
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
        let activeSessionSnapshot = try? Data(core.exportSession(contactId: message.from))

        for (index, archive) in archives.enumerated().reversed() {
            do {
                _ = try core.importSession(contactId: message.from, data: [UInt8](archive.sessionData))

                let rawContent = message.content
                let contentBytes = [UInt8](MessagePadding.unpadCiphertext(rawContent))
                let result = try core.decryptMessage(
                    contactId: message.from,
                    ephemeralPublicKey: [UInt8](message.ephemeralPublicKey),
                    messageNumber: message.messageNumber,
                    content: contentBytes
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
            _ = try? core.importSession(contactId: message.from, data: [UInt8](snap))
        }

        Log.info("All \(archives.count) archived sessions failed to decrypt", category: "CryptoManager")
        throw CryptoManagerError.decryptionFailed
    }
}
