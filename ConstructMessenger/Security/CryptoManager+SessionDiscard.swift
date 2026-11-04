//
//  CryptoManager+SessionDiscard.swift
//  Construct Messenger
//
//  Dropping, retiring, forgetting and restoring sessions with one device.
//

import CoreData
import Foundation

extension CryptoManager {

    // MARK: - Discard

    /// Drop **every** session we hold with a person.
    ///
    /// The account-shaped counterpart to `discardSession(for:)`, which names one device. Three
    /// callers mean the person and not a device — a redeemed invite retiring what came before, a
    /// deleted chat, a deleted contact — and each of them retired whichever single device
    /// `pinnedDevice(ofPeer:)` happened to name, leaving the other N−1 ratchets in the Keychain.
    ///
    /// The comment on the contact-deletion site already described that as the worse half of the
    /// defect: "the contact is gone from every list and its ratchet is still in the Keychain, ready
    /// to be picked up by the next pairing with the same person." With a multi-device peer it was
    /// not one ratchet left behind but all of them bar one.
    ///
    /// Deliberately **not** for inbound END_SESSION or SESSION_RESET_INIT. Those say one device
    /// wants to restart, and dropping the account would destroy healthy sessions with devices that
    /// never asked.
    ///
    /// Returns how many devices were dropped, so a caller can log the difference between "nothing
    /// to do" and "we could not name anyone".
    @discardableResult
    func discardAllSessions(ofPeer peerId: String) -> Int {
        var dropped = 0
        for device in SessionAddressing.deviceIds(ofPeer: peerId) {
            guard hasStoredSessionState(for: device) else { continue }
            discardSession(for: device)
            dropped += 1
        }
        return dropped
    }

    /// Whether we hold a session with **any** of a person's devices.
    ///
    /// The guard that belongs in front of `discardAllSessions`: asking
    /// `hasStoredSessionState(for: accountId)` answers about one device, so a peer whose pinned
    /// device has no session but whose second device does would be skipped entirely.
    func hasStoredSessionStateForAnyDevice(ofPeer peerId: String) -> Bool {
        SessionAddressing.deviceIds(ofPeer: peerId).contains { hasStoredSessionState(for: $0) }
    }

    /// Forget everything we hold about one **device** of a contact we have deleted.
    ///
    /// The completion of `remove_session`, which is only the ratchet. The core also holds an
    /// archive and its timestamp, a prekey counter, a heal record, a PQ contribution, an init
    /// lock, a cooldown, a pending END_SESSION, a prewarm mark, an active-chat mark and the
    /// router's queued carriers for that contact — none of it reachable from here until
    /// `forget_contact_state` was exported (core 0.16.0). Until then "delete this contact" removed
    /// the ratchet and the next add for the same device was steered by the leftovers of a contact
    /// the platform had already forgotten.
    ///
    /// Silent on the wire, and deliberately: this is a local deletion boundary, not a protocol
    /// reset. A caller that wants the peer told does that first — `pruneContact` announces before
    /// it forgets, because the announcement needs the very rows the forget destroys.
    ///
    /// The Keychain half stays here: the core owns its own state, this app owns the four entries
    /// hanging off the same device id.
    func forgetContactState(for deviceId: String) {
        coreLock.lock()
        defer { coreLock.unlock() }
        guard !deviceId.isEmpty else { return }
        orchestratorCore?.forgetContactState(contactId: deviceId)
        KeychainManager.shared.deleteSession(for: deviceId)
        KeychainManager.shared.deleteSessionSuiteId(userId: deviceId)
        KeychainManager.shared.deleteSessionAtRiskFlag(forDevice: deviceId)
    }

    /// Retire the current state with `deviceId` — the person reset the session, or the server
    /// refused a ciphertext we wrote on it. The core keeps it as a previous state (what the peer
    /// still sends on it decrypts) and the next send opens a new one; nothing is sent now. True
    /// when there was a current state to retire.
    @MainActor @discardableResult
    func retireSession(device deviceId: String) -> Bool {
        let actions: [CfeAction] = {
            coreLock.lock()
            defer { coreLock.unlock() }
            guard !deviceId.isEmpty, let core = orchestratorCore else { return [] }
            return core.retireSession(contactId: deviceId)
        }()
        guard !actions.isEmpty else { return false }
        OutboundSessionService.shared.executeStorageActions(actions)
        return true
    }

    @MainActor
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
    func restoreSession(for deviceId: String) -> Bool {
        coreLock.lock()
        defer { coreLock.unlock() }
        guard let core = orchestratorCore else { return false }
        // Keychain session entries are keyed by device, so there is nothing on file under any
        // other name to look for.
        guard let contactId = SessionAddressing.asDevice(deviceId) else { return false }
        if core.hasSession(contactId: contactId) { return true }
        guard let sessionData = KeychainManager.shared.loadSessionData(for: contactId) else {
            // Not an error: a chat can exist with no session on file — never messaged, or the
            // session was legitimately archived by END_SESSION / SESSION_RESET_INIT. Every caller
            // treats `false` as "establish one", and the bulk path reports the aggregate below.
            // This was ERROR until 2026-08-03 and fired on every launch for such contacts, which
            // is noise in the one signal a release run is judged by.
            Log.info("No stored session for \(contactId.prefix(8))… — will be established on demand", category: "CryptoManager")
            return false
        }
        do {
            _ = try core.importSession(contactId: contactId, data: sessionData)
            Log.debug("Restored session (CFE): \(contactId)", category: "CryptoManager")
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
            KeychainManager.shared.deleteSession(for: contactId)
            Log.error("Session import FAILED for \(contactId) (unusable — deleted): \(error)", category: "CryptoManager")
            return false
        }
    }

    // MARK: - Discard one device

    /// Drop the current session with one device: from the core and from the Keychain.
    ///
    /// Nothing is kept beside it. Until 2026-11-04 this exported the session into an archive of
    /// this app's own (`session_archives_<device>`), for a fallback decrypt that tried each archive
    /// when the core could not read a message. That fallback was a second carrier of what the core
    /// already keeps — previous states, newest first, the one that decrypts promoted
    /// (`session_lifecycle.rs`, `MAX_PREVIOUS_STATES`) — and it never read an archive: its only
    /// caller was the SENDER_SYNC walk, where `message.from` is our own account, so the lookup
    /// failed on the account id before reaching one. See
    /// `decisions/the-core-keeps-previous-states-the-app-keeps-no-archive.md`.
    ///
    /// The import step the archive needed is gone with it: an on-disk-only session does not have
    /// to be loaded to be deleted.
    func discardSession(for deviceId: String) {
        coreLock.lock()
        defer { coreLock.unlock() }
        guard let contactId = SessionAddressing.asDevice(deviceId) else { return }
        let removed = orchestratorCore?.removeSession(contactId: contactId) ?? false
        KeychainManager.shared.deleteSessionSuiteId(userId: contactId)
        KeychainManager.shared.deleteSession(for: contactId)
        Log.info(
            "Discarded session for \(contactId.prefix(8))… (in core: \(removed))",
            category: "CryptoManager"
        )
    }
}
