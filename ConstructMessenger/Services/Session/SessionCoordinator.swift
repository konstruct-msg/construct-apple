//
//  SessionCoordinator.swift
//  Construct Messenger
//
//  Owns the entire session lifecycle for all peers:
//  – Receiving session init (RECEIVER role via X3DH)
//  – Sending END_SESSION (manual reset, logout, heal-exhausted)
//  – Session healing (re-key on messageNumber=0 decrypt failure)
//  – KEY_SYNC handling (re-key sending session on server request)
//  – OTPK replenishment after session init / heal exhaustion
//  – Pending message queue (messages that arrived before a session was ready)
//
//  ChatsViewModel owns stream lifecycle; SessionCoordinator owns session lifecycle.
//

import Foundation
import CoreData

/// Formal session lifecycle state for a single peer contact.
/// Used by `SessionCoordinator.sessionStates` to replace the ad-hoc
/// `usersInitializingSession: Set<String>` + `sessionEstablishedAt: [String: UInt64]` pair.
private enum ContactSessionState: Equatable {
    /// Session init (X3DH, heal, key-sync, fallback) is in flight.
    case initializing
    /// Session is established. `establishedAt` is Unix seconds.
    case active(establishedAt: UInt64)
}

@MainActor
final class SessionCoordinator {

    // MARK: - Owned services

    private let messageRouter = MessageRouter()
    private let publicKeyBundleHandler = PublicKeyBundleHandler()
    private let sessionInitService = SessionInitializationService.shared
    private let initMessageReassembler = ChunkedMessageReassembler()

    // MARK: - State

    /// Messages that arrived before their sender's session was established.
    /// Keyed by sender userId; ordered by arrival (first element = lowest messageNumber).
    private var pendingFirstMessages: [String: [ChatMessage]] = [:]

    /// Tracks when we last sent END_SESSION to each peer to prevent loop storms.
    private var endSessionSentAt: [String: Date] = [:]
    private let endSessionCooldown: TimeInterval = 30.0

    /// Tracks when we last attempted an automatic resend after receiving END_SESSION from a peer.
    /// Prevents resend loops when both sides reset simultaneously.
    private var resendAttemptedAt: [String: Date] = [:]
    private let resendCooldown: TimeInterval = 10.0
    private let resendWindow: TimeInterval = 5 * 60 // 5 minutes

    /// Watchdog tasks started after a tie-break WIN.
    /// If the RESPONDER (loser) does not reply within the timeout, re-sends the session ping
    /// so they can become RESPONDER even after a brief network outage.
    private var tieBreakWatchdogs: [String: Task<Void, Never>] = [:]
    private let tieBreakWatchdogTimeout: TimeInterval = 30.0

    /// Fallback tasks started when we are the natural RESPONDER (lower deviceId) and receive
    /// END_SESSION from the INITIATOR. If the INITIATOR does not send a new session init within
    /// the timeout, we override the natural ordering and proactively initialize ourselves.
    /// This prevents a permanent session deadlock when the INITIATOR is itself broken/offline.
    private var responderFallbackTasks: [String: Task<Void, Never>] = [:]
    private let responderFallbackTimeout: TimeInterval = 20.0

    /// Timer that periodically evicts expired entries from cooldown dicts so they don't grow unboundedly.
    private var cooldownPurgeTimer: Timer?
    private let cooldownPurgeInterval: TimeInterval = 5 * 60 // every 5 minutes

    /// Formal session state machine for each peer contact.
    /// Replaces both `usersInitializingSession: Set<String>` and `sessionEstablishedAt: [String: UInt64]`.
    private var sessionStates: [String: ContactSessionState] = [:]

    /// Returns true if a session init (or heal) is currently in progress for `userId`.
    private func isInitializing(_ userId: String) -> Bool {
        if case .initializing = sessionStates[userId] { return true }
        return false
    }

    /// Mark `userId` as initializing and return a `defer` block that clears the state.
    @discardableResult
    private func beginInit(_ userId: String) -> () -> Void {
        sessionStates[userId] = .initializing
        return { [weak self] in
            // Only clear if still in .initializing — don't clobber .active set by a success path.
            if case .initializing = self?.sessionStates[userId] {
                self?.sessionStates[userId] = nil
            }
        }
    }

    /// Mark `userId` as having an active session established right now.
    private func markActive(_ userId: String) {
        sessionStates[userId] = .active(establishedAt: UInt64(Date().timeIntervalSince1970))
    }

    /// Return the timestamp (Unix seconds) when the active session for `userId` was established,
    /// or nil if there is no active session record.
    private func establishedAt(for userId: String) -> UInt64? {
        if case .active(let t) = sessionStates[userId] { return t }
        return nil
    }

    // MARK: - Injected references

    private var viewContext: NSManagedObjectContext?
    private weak var streamManager: MessageStreamManager?

    // MARK: - Setup

    func setContext(_ context: NSManagedObjectContext) {
        viewContext = context
        messageRouter.setContext(context)
        publicKeyBundleHandler.setContext(context)
    }

    /// Call once after init to bind MessageRouter callbacks and the stream manager reference.
    func configure(streamManager: MessageStreamManager) {
        self.streamManager = streamManager
        setupMessageRouterCallbacks()
        startCooldownPurgeTimer()
    }

    // MARK: - Public entry points

    /// Route a single incoming message through MessageRouter.
    func routeIncomingMessage(_ message: ChatMessage, in context: NSManagedObjectContext) {
        messageRouter.routeIncomingMessage(message, in: context, pendingMessages: &pendingFirstMessages)
    }

    /// Called when the stream receives a KEY_SYNC control message.
    func handleKeySyncRequest(for userId: String) {
        guard !isInitializing(userId) else {
            Log.info("⏸️ KEY_SYNC skipped — session init already in progress for \(userId.prefix(8))…", category: "SessionInit")
            return
        }
        let endInit = beginInit(userId)
        Log.info("🔑 SESSION_STATE[key_sync]: re-keying sending session for \(userId.prefix(8))…", category: "SessionInit")
        Task { [weak self] in
            guard let self else { return }
            defer { endInit() }
            do {
                let bundle = try await publicKeyBundleHandler.fetchPublicKeyWithRetry(userId: userId)
                try sessionInitService.initializeSession(userId: userId, bundle: bundle, deleteExisting: true)
                Log.info("✅ SESSION_STATE[key_sync_success]: session re-keyed for \(userId.prefix(8))…", category: "SessionInit")
            } catch {
                Log.error("❌ SESSION_STATE[key_sync_failed]: \(error.localizedDescription) for \(userId.prefix(8))…", category: "SessionInit")
            }
        }
    }

    /// Send END_SESSION to a peer and archive + clear the local session.
    func sendEndSession(to userId: String, reason: String = "manual_reset") async throws {
        Log.info("🔄 Sending END_SESSION to \(userId): \(reason)", category: "ChatsViewModel")
        do {
            let response = try await MessagingServiceClient.shared.sendEndSession(to: userId, reason: reason)
            Log.info("✅ END_SESSION sent successfully: \(response.messageId)", category: "ChatsViewModel")
        } catch {
            Log.error("❌ Failed to send END_SESSION: \(error)", category: "ChatsViewModel")
            throw error
        }
        CryptoManager.shared.archiveSession(for: userId, reason: .manualReset)
        CryptoManager.shared.clearArchivedSessions(for: userId)
        Log.info("✅ END_SESSION complete: session archived and cleared", category: "ChatsViewModel")
    }

    /// Broadcast END_SESSION to all peers that have an active session (e.g., on logout).
    /// Pre-warm sessions for contacts where we are the natural INITIATOR (higher deviceId).
    /// Called once per app launch after stream connects. Ensures first messages are instant.
    func prewarmSessions(for contactIds: [String], skipEndSessionNotification: Bool = false) {
        let myId = SessionManager.shared.currentUserId ?? ""
        guard !myId.isEmpty else { return }

        let toPrewarm = contactIds.filter {
            DeviceIdOrdering.isNaturalInitiator(myId: myId, peerId: $0) && !CryptoManager.shared.hasSession(for: $0)
        }
        guard !toPrewarm.isEmpty else { return }

        Log.info("🔥 Session prewarm: \(toPrewarm.count) contact(s) need sessions", category: "SessionInit")
        Task {
            for contactId in toPrewarm {
                // Guard against both a session that appeared since we built toPrewarm
                // AND against a parallel prewarm Task for the same peer.
                // We insert into usersInitializingSession here (not inside
                // initializeSessionProactively) so that a second concurrent Task that
                // also reaches this point sees the flag and skips — otherwise both tasks
                // would slip past the guard, race through fetchBundle, and the second
                // would delete the session just created by the first.
                guard !CryptoManager.shared.hasSession(for: contactId),
                      !isInitializing(contactId) else {
                    Log.info("⏸️ Prewarm skipped — session exists or init in progress for \(contactId.prefix(8))…", category: "SessionInit")
                    continue
                }
                let endInit = beginInit(contactId)
                defer { endInit() }

                // Notify the peer that our session is missing ONLY when this prewarm
                // was triggered proactively (startup / stream-connect). When triggered
                // by onEndSessionReceived the peer has already sent us END_SESSION —
                // they already know their session with us needs reset. Sending another
                // END_SESSION in that path creates a ping-pong loop where each side
                // continuously triggers the other's END_SESSION handler.
                if !skipEndSessionNotification {
                    do {
                        try await sendEndSession(to: contactId, reason: "session_missing_restart")
                        endSessionSentAt[contactId] = Date()
                        Log.info("🔥 Prewarm: notified \(contactId.prefix(8))… of missing session before fresh init", category: "SessionInit")
                    } catch {
                        Log.error("⚠️ Prewarm: END_SESSION to \(contactId.prefix(8))… failed (proceeding with prewarm): \(error.localizedDescription)", category: "SessionInit")
                    }
                }

                await sessionInitService.initializeSessionProactively(
                    userId: contactId,
                    onSuccess: { Log.info("🔥 Prewarm ✅ \(contactId.prefix(8))…", category: "SessionInit") },
                    onFailure: { err in Log.info("🔥 Prewarm ❌ \(contactId.prefix(8))…: \(err.localizedDescription)", category: "SessionInit") }
                )
            }
        }
    }

    func sendEndSessionToAllContacts(reason: String = "logout") async {
        Log.info("🔄 Sending END_SESSION to all contacts: \(reason)", category: "ChatsViewModel")
        let sessionUserIds = CryptoManager.shared.getAllSessionUserIds()
        Log.info("📋 Found \(sessionUserIds.count) active sessions", category: "ChatsViewModel")
        var successCount = 0
        var failCount = 0
        for userId in sessionUserIds {
            do {
                try await sendEndSession(to: userId, reason: reason)
                successCount += 1
            } catch {
                Log.error("❌ Failed to send END_SESSION to \(userId): \(error)", category: "ChatsViewModel")
                failCount += 1
            }
        }
        Log.info("✅ END_SESSION broadcast: \(successCount) sent, \(failCount) failed", category: "ChatsViewModel")
    }

    // MARK: - MessageRouter callbacks

    private func setupMessageRouterCallbacks() {
        messageRouter.onReceiptNeeded = { [weak self] messageIds, recipientUserId, status in
            self?.streamManager?.sendReceipt(messageIds, to: recipientUserId, status: status)
        }

        messageRouter.onPublicKeyBundleNeeded = { [weak self] userId, message in
            guard let self else { return }
            Task { @MainActor in
                await self.handlePublicKeyBundleNeeded(userId: userId, message: message)
            }
        }

        messageRouter.onUsernameUpdateNeeded = { [weak self] userId in
            guard let self else { return }
            Task {
                do {
                    let bundle = try await self.publicKeyBundleHandler.fetchPublicKeyWithRetry(userId: userId)
                    await MainActor.run {
                        _ = self.publicKeyBundleHandler.handlePublicKeyBundle(bundle)
                    }
                } catch {
                    Log.error("❌ Failed to fetch public key for username update: \(error.localizedDescription)", category: "ChatsViewModel")
                }
            }
        }

        messageRouter.onEndSessionNeeded = { [weak self] userId in
            guard let self else { return }
            Task {
                let now = Date()
                if let lastSent = self.endSessionSentAt[userId],
                   now.timeIntervalSince(lastSent) < self.endSessionCooldown {
                    Log.info("⏸️ END_SESSION cooldown active for \(userId.prefix(8))..., skipping", category: "ChatsViewModel")
                    return
                }
                self.endSessionSentAt[userId] = now
                Log.info("🔄 Sending END_SESSION to \(userId.prefix(8))... (session out of sync)", category: "ChatsViewModel")
                do {
                    try await self.sendEndSession(to: userId, reason: "session_out_of_sync")
                } catch {
                    Log.error("⚠️ Failed to send END_SESSION to \(userId.prefix(8))...: \(error)", category: "SessionCoordinator")
                }
            }
        }

        messageRouter.onSessionHealNeeded = { [weak self] userId, failedMessage in
            guard let self else { return }
            Task { @MainActor in
                await self.handleSessionHealNeeded(userId: userId, failedMessage: failedMessage)
            }
        }

        // Filter out stale END_SESSION messages that predate the currently-established session.
        // This prevents server re-deliveries of old END_SESSIONs from tearing down healthy sessions.
        messageRouter.isEndSessionStale = { [weak self] userId, endSessionTimestamp in
            guard let self else { return false }
            guard let establishedAt = self.establishedAt(for: userId) else { return false }
            // Allow a 5-second grace window to handle near-simultaneous END_SESSION + session init.
            return endSessionTimestamp + 5 < establishedAt
        }

        // When we receive END_SESSION from a peer, prewarm if we are the natural INITIATOR
        // (higher deviceId). This ensures the session re-establishes without user action,
        // and prevents the RESPONDER from incorrectly acting as INITIATOR with stale OTPKs.
        messageRouter.onEndSessionReceived = { [weak self] userId, endSessionTimestamp in
            guard let self else { return }
            let myId = SessionManager.shared.currentUserId ?? ""
            guard !myId.isEmpty else { return }

            // Only the natural INITIATOR (higher deviceId) auto-resends and re-prewarms.
            // If the END_SESSION came from a higher deviceId it means they are the tie-break
            // winner and have already restored their INITIATOR session — do NOT re-prewarm
            // or resend here; doing so would restart the tie-break loop.
            guard DeviceIdOrdering.isNaturalInitiator(myId: myId, peerId: userId) else {
                Log.info("🔇 END_SESSION from natural INITIATOR \(userId.prefix(8))… — waiting as RESPONDER (no resend, no prewarm)", category: "SessionInit")
                startResponderFallback(for: userId)
                return
            }

            self.resendUnconfirmedOutgoingMessagesIfNeeded(to: userId)
            Log.info("🔥 END_SESSION received — re-prewarming as natural INITIATOR for \(userId.prefix(8))…", category: "SessionInit")
            Task {
                // Brief delay so END_SESSION processing (archive, queue clear) finishes first.
                try? await Task.sleep(nanoseconds: 300_000_000) // 300 ms
                // Do NOT send session_missing_restart here: the peer just sent us END_SESSION,
                // which means they already know they need to reset. Sending another END_SESSION
                // in response would cause them to restart their own onEndSessionReceived path,
                // creating a ping-pong loop. Our X3DH init message implicitly signals the new
                // session — that's all the peer needs to become RESPONDER.
                self.prewarmSessions(for: [userId], skipEndSessionNotification: true)
            }
        }

        // When this device wins the tie-break, send SESSION_RESET_INIT — a single atomic
        // message that carries both END_SESSION signal and the new X3DH init payload.
        // Eliminates the 200 ms ordering hack from the old two-step sequence.
        messageRouter.onTieBreakWin = { [weak self] userId in
            guard let self else { return }
            let suiteIdAtWin = Int(KeychainManager.shared.loadSessionSuiteId(userId: userId) ?? 0)
            Log.info("🏆 SESSION_STATE[tie_break_outcome]: INITIATOR role confirmed, peer=\(userId.prefix(8))… suiteId=\(suiteIdAtWin), sending SESSION_RESET_INIT", category: "SessionInit")
            Task {
                // Re-initialize from scratch: fetch RESPONDER's bundle → new outgoing session
                // (msgNum=0). SESSION_RESET_INIT then carries that X3DH init payload atomically.
                await self.sessionInitService.initializeSessionProactively(
                    userId: userId,
                    onSuccess: { },
                    onFailure: { err in
                        Log.error("❌ SESSION_STATE[tie_break_reinit_fail]: \(err.localizedDescription)", category: "SessionInit")
                    }
                )
                // Single atomic message: RESPONDER archives old session + inits in one pass.
                await self.sendSessionResetInit(to: userId)
                // Phase 1 of two-phase handshake: session is now "unconfirmed" until
                // RESPONDER sends back __session_ready__. ChatViewModel will buffer any
                // outgoing messages as .queued until confirmation is received.
                SessionConfirmationTracker.shared.markPending(userId)
                let suiteIdAfter = Int(KeychainManager.shared.loadSessionSuiteId(userId: userId) ?? 0)
                Log.info("🔄 SESSION_STATE[tie_break_sri_sent]: peer=\(userId.prefix(8))… suiteId=\(suiteIdAfter)", category: "SessionInit")
            }
            // Start watchdog: if RESPONDER has not replied within timeout, re-send ping.
            self.startTieBreakWatchdog(for: userId)
        }
    }

    // MARK: - RECEIVER session init

    private func handlePublicKeyBundleNeeded(userId: String, message: ChatMessage) async {
        if isInitializing(userId) {
            Log.info("⏸️ Session init already in progress for \(userId.prefix(8))..., skipping duplicate attempt", category: "SessionInit")
            return
        }
        let endInit = beginInit(userId)
        Log.debug("🔒 Locked session init for \(userId.prefix(8))...", category: "SessionInit")

        do {
            let fetchStart = Date()
            let bundle = try await publicKeyBundleHandler.fetchPublicKeyWithRetry(userId: userId)
            Log.info("🔐 SESSION_STATE[bundle_fetched]: userId=\(userId.prefix(8))..., duration=\(String(format: "%.2f", Date().timeIntervalSince(fetchStart)))s", category: "SessionInit")

            let success = publicKeyBundleHandler.handlePublicKeyBundleForIncomingMessage(
                bundle,
                message: message
            ) { [weak self] chat, msg, decryptedContent in
                self?.saveMessage(for: chat, with: msg, decryptedContent: decryptedContent)
            }

            if success {
                // New session established — reset END_SESSION cooldown so future failures are handled.
                endSessionSentAt.removeValue(forKey: userId)

                // ACK only after we successfully decrypted + persisted the first message.
                // This prevents message loss when initReceivingSession fails mid-flight.
                streamManager?.sendReceipt([message.id], to: userId, status: .delivered)
                if let context = viewContext {
                    PersistentACKStore.shared.markProcessed(message.id, senderId: userId, in: context)
                }

                // Notify Rust orchestrator that RESPONDER-side session init completed.
                // Rust clears its init_lock for this contactId. We ignore returned
                // SaveSessionToSecureStore actions — the session was already persisted
                // by initReceivingSession above.
                if let sessionBytes = try? CryptoManager.shared.exportSession(contactId: userId) {
                    let event = CfeIncomingEvent.sessionInitCompleted(
                        contactId: userId,
                        sessionData: Data(sessionBytes)
                    )
                    try? CryptoManager.shared.handleOrchestratorEvent(event, tag: "session_init_completed_responder")
                }

                // Replenish OTPKs — Bob consumed one OTPK for this X3DH session init.
                Task {
                    let deviceId = KeychainManager.shared.loadDeviceID() ?? ""
                    await OtpkReplenishmentService.replenishIfNeeded(deviceId: deviceId)
                }
                // Transition to .active — records establishment time for stale END_SESSION filtering.
                markActive(userId)
                drainPendingQueue(for: userId, skippingFirst: true)
                // Re-send messages that were re-queued on prior END_SESSION receipt.
                sendSessionQueuedMessages(for: userId)
                // Phase 2 of two-phase handshake: notify INITIATOR that RESPONDER
                // session is established. INITIATOR cancels its watchdog and flushes
                // any buffered outgoing messages.
                Task { await self.sendSessionReady(to: userId) }
            } else {
                // initReceivingSession failed — prekey exhausted or invalid.
                Log.info("🔄 initReceivingSession failed — clearing queue, sending END_SESSION to \(userId.prefix(8))...", category: "SessionInit")
                // Do NOT ACK as delivered: we failed to decrypt. Mark as failed so the sender
                // is forced to reset and re-send under a fresh session.
                streamManager?.sendReceipt([message.id], to: userId, status: .failed)
                // Mark as permanently processed so re-deliveries on reconnect are silently ignored
                // instead of triggering a cascade of new failed session inits.
                if let context = viewContext {
                    PersistentACKStore.shared.markProcessed(message.id, senderId: userId, in: context)
                }
                pendingFirstMessages.removeValue(forKey: userId)
                Task {
                    try? await sendEndSession(to: userId, reason: "session_init_failed")
                    await uploadFreshOtpks(reason: "init_failed")
                }
            }
        } catch {
            Log.error("🔐 SESSION_STATE[bundle_fetch_failed]: userId=\(userId.prefix(8))..., error=\(error.localizedDescription)", category: "SessionInit")
        }

        endInit()
        Log.debug("🔓 Unlocked session init for \(userId.prefix(8))...", category: "SessionInit")
    }

    // MARK: - Session healing

    private func handleSessionHealNeeded(userId: String, failedMessage: ChatMessage) async {
        if isInitializing(userId) {
            Log.info("⏸️ Heal skipped — session init already in progress for \(userId.prefix(8))…", category: "SessionInit")
            return
        }
        let endInit = beginInit(userId)
        Log.info("🩹 SESSION_STATE[heal_start]: fetching fresh bundle for \(userId.prefix(8))…", category: "SessionInit")

        defer {
            endInit()
            Log.debug("🔓 Heal lock released for \(userId.prefix(8))…", category: "SessionInit")
        }

        guard let context = viewContext else { return }

        let canContinue = SessionHealingService.shared.recordAttempt(
            for: failedMessage.id, in: context
        )

        do {
            let bundle = try await publicKeyBundleHandler.fetchPublicKeyWithRetry(userId: userId)

            let healed = publicKeyBundleHandler.handlePublicKeyBundleForIncomingMessage(
                bundle,
                message: failedMessage
            ) { [weak self] chat, msg, decryptedContent in
                self?.saveMessage(for: chat, with: msg, decryptedContent: decryptedContent)
            }

            if healed {
                Log.info("✅ SESSION_STATE[heal_success]: session healed for \(userId.prefix(8))…", category: "SessionInit")
                SessionHealingService.shared.removeRecord(for: failedMessage.id, in: context)

                // We can now decrypt the previously-failed X3DH init message: ACK it as delivered.
                streamManager?.sendReceipt([failedMessage.id], to: userId, status: .delivered)
                PersistentACKStore.shared.markProcessed(failedMessage.id, senderId: userId, in: context)

                drainPendingQueue(for: userId, skippingFirst: true)
            } else {
                Log.error("❌ SESSION_STATE[heal_failed]: initReceivingSession still failing for \(userId.prefix(8))…", category: "SessionInit")
                if !canContinue {
                    Log.info("⛔ Heal exhausted — sending END_SESSION to \(userId.prefix(8))…", category: "SessionInit")
                    // Heal is impossible, so do NOT report delivered. Report failed to force a reset.
                    streamManager?.sendReceipt([failedMessage.id], to: userId, status: .failed)
                    // Mark permanently so re-deliveries on reconnect don't restart the cascade.
                    PersistentACKStore.shared.markProcessed(failedMessage.id, senderId: userId, in: context)
                    pendingFirstMessages.removeValue(forKey: userId)
                    SessionHealingService.shared.clearQueue(for: userId, in: context)
                    try? await sendEndSession(to: userId, reason: "heal_exhausted")
                    await uploadFreshOtpks(reason: "heal_exhausted")
                }
                // Otherwise leave HealingMessage in CoreData; next reconnect retries.
            }
        } catch {
            Log.error("❌ SESSION_STATE[heal_bundle_error]: \(error.localizedDescription) for \(userId.prefix(8))…", category: "SessionInit")
            if !canContinue {
                pendingFirstMessages.removeValue(forKey: userId)
                SessionHealingService.shared.clearQueue(for: userId, in: context)
                try? await sendEndSession(to: userId, reason: "heal_bundle_unreachable")
            }
        }
    }

    // MARK: - Helpers

    /// Drain the pending queue for a peer after session init / heal succeeds.
    private func drainPendingQueue(for userId: String, skippingFirst: Bool) {
        let queued = pendingFirstMessages[userId] ?? []
        pendingFirstMessages.removeValue(forKey: userId)
        let toProcess = skippingFirst ? queued.dropFirst() : queued[...]
        guard !toProcess.isEmpty, let context = viewContext else { return }
        Log.info("🔐 Decrypting \(toProcess.count) queued message(s) for \(userId.prefix(8))...", category: "SessionInit")
        for queuedMsg in toProcess {
            messageRouter.routeIncomingMessage(queuedMsg, in: context, pendingMessages: &pendingFirstMessages)
        }
    }

    /// Re-sends any outgoing messages that were marked `.queued` by `requeueUndeliveredOutgoing`
    /// after receiving END_SESSION (i.e. messages encrypted under the now-replaced session).
    private func sendSessionQueuedMessages(for userId: String) {
        // Session is now established — cancel any pending RESPONDER fallback.
        cancelResponderFallback(for: userId)
        guard let context = viewContext,
              let myId = SessionManager.shared.currentUserId, !myId.isEmpty else { return }
        let chatFetch = Chat.fetchRequest()
        chatFetch.predicate = NSPredicate(format: "otherUser.id == %@", userId)
        guard let chat = (try? context.fetch(chatFetch))?.first else { return }
        MessageRetryManager.shared.sendQueuedMessages(
            for: chat,
            recipientId: userId,
            currentUserId: myId,
            context: context
        )
    }

    /// Upload a fresh batch of OTPKs after session-init or heal failure.
    private func uploadFreshOtpks(reason: String) async {
        let deviceId = KeychainManager.shared.loadDeviceID() ?? ""
        guard !deviceId.isEmpty else { return }
        Log.info("🔑 Force-uploading \(OtpkReplenishmentService.replenishBatchSize) fresh OTPKs (\(reason))", category: "OTPK")
        do {
            try await OtpkReplenishmentService.generateAndUpload(
                count: OtpkReplenishmentService.replenishBatchSize,
                deviceId: deviceId,
                replaceExisting: true
            )
        } catch {
            Log.error("Failed to upload fresh OTPKs (\(reason)): \(error)", category: "OTPK")
        }
    }

    /// Start a repeating timer that evicts expired entries from cooldown dicts.
    /// Prevents unbounded growth when contacts are frequently reset (e.g. during testing).
    private func startCooldownPurgeTimer() {
        cooldownPurgeTimer?.invalidate()
        cooldownPurgeTimer = Timer.scheduledTimer(withTimeInterval: cooldownPurgeInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.purgeStaleCooldowns()
            }
        }
    }

    private func purgeStaleCooldowns() {
        let now = Date()
        // Cooldown entries older than 2× their window are safe to remove
        let endSessionTTL = endSessionCooldown * 2
        let resendTTL = resendCooldown * 2

        let beforeES = endSessionSentAt.count
        endSessionSentAt = endSessionSentAt.filter { now.timeIntervalSince($0.value) < endSessionTTL }
        let beforeRA = resendAttemptedAt.count
        resendAttemptedAt = resendAttemptedAt.filter { now.timeIntervalSince($0.value) < resendTTL }

        let removedES = beforeES - endSessionSentAt.count
        let removedRA = beforeRA - resendAttemptedAt.count
        if removedES + removedRA > 0 {
            Log.debug("🧹 Purged \(removedES) endSession + \(removedRA) resend cooldown entries", category: "SessionInit")
        }
    }

    // MARK: - Tie-break session establishment ping

    /// Encrypt and send an invisible session establishment ping to `userId`.
    /// Called after a tie-break WIN so the loser (lower deviceId) can immediately
    /// call `initReceivingSession` and become RESPONDER without waiting for user action.
    /// The receiver's `saveMessage` filters out the ping content so it is never shown in chat.
    /// Retries up to `pingMaxAttempts` times with exponential back-off on network failure.
    private let pingMaxAttempts = 3
    private let pingRetryBaseDelay: UInt64 = 1_000_000_000 // 1 s

    /// Send SESSION_RESET_INIT — atomic replacement for `sendEndSession` + `sendSessionPing`.
    ///
    /// Encodes the X3DH init payload (`msgNum=0`) with `contentType: .sessionResetInit`.
    /// RESPONDER atomically archives old session and inits as RESPONDER in one `handleEvent` pass,
    /// eliminating the 200 ms ordering window from the legacy two-step tie-break sequence.
    ///
    /// Falls back to the legacy two-step sequence if all attempts fail (backward compat).
    private func sendSessionResetInit(to userId: String) async {
        guard CryptoManager.shared.hasSession(for: userId) else {
            Log.info("⚠️ SESSION_STATE[sri_skip]: no INITIATOR session for \(userId.prefix(8))…", category: "SessionInit")
            return
        }
        guard let myId = SessionManager.shared.currentUserId, !myId.isEmpty else { return }

        for attempt in 1...pingMaxAttempts {
            do {
                let sriContent = "__session_reset_init_\(UUID().uuidString)__"
                let sriId = UUID().uuidString.lowercased()
                let _ = try await MessagingServiceClient.shared.sendMessage(
                    messageId: sriId,
                    recipientId: userId,
                    senderId: myId,
                    conversationId: ConversationId.direct(myUserId: myId, theirUserId: userId),
                    encryptedPayload: try MessageRouter.shared.encryptSessionControl(
                        plaintext: sriContent,
                        messageId: sriId,
                        recipientId: userId
                    ),
                    timestamp: UInt64(Date().timeIntervalSince1970),
                    contentType: .sessionResetInit
                )
                Log.info("🔄 SESSION_STATE[sri_sent]: SESSION_RESET_INIT to \(userId.prefix(8))… (attempt \(attempt))", category: "SessionInit")
                return
            } catch {
                Log.error("❌ SESSION_STATE[sri_fail]: attempt \(attempt)/\(pingMaxAttempts): \(error.localizedDescription) for \(userId.prefix(8))…", category: "SessionInit")
                if attempt < pingMaxAttempts {
                    try? await Task.sleep(nanoseconds: pingRetryBaseDelay * UInt64(attempt))
                } else {
                    Log.info("⚠️ SESSION_STATE[sri_fallback]: SESSION_RESET_INIT exhausted, falling back to two-step for \(userId.prefix(8))…", category: "SessionInit")
                    let _ = try? await MessagingServiceClient.shared.sendEndSession(to: userId, reason: "sri_fallback")
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    await sendSessionPing(to: userId)
                }
            }
        }
    }

    private func sendSessionPing(to userId: String) async {
        guard CryptoManager.shared.hasSession(for: userId) else {
            Log.info("⚠️ SESSION_STATE[tie_break_ping_skip]: no INITIATOR session for \(userId.prefix(8))…", category: "SessionInit")
            return
        }
        guard let myId = SessionManager.shared.currentUserId, !myId.isEmpty else { return }

        for attempt in 1...pingMaxAttempts {
            do {
                let pingContent = "__session_ping_\(UUID().uuidString)__"
                let pingId = UUID()
                let pingMessageId = pingId.uuidString.lowercased()
                let _ = try await MessagingServiceClient.shared.sendMessage(
                    messageId: pingMessageId,
                    recipientId: userId,
                    senderId: myId,
                    conversationId: ConversationId.direct(myUserId: myId, theirUserId: userId),
                    encryptedPayload: try MessageRouter.shared.encryptSessionControl(
                        plaintext: pingContent,
                        messageId: pingMessageId,
                        recipientId: userId
                    ),
                    timestamp: UInt64(Date().timeIntervalSince1970)
                )
                Log.info("🏓 SESSION_STATE[tie_break_ping]: sent to \(userId.prefix(8))… (attempt \(attempt)) — loser can now init as RESPONDER", category: "SessionInit")
                return
            } catch {
                Log.error("❌ SESSION_STATE[tie_break_ping_fail]: attempt \(attempt)/\(pingMaxAttempts): \(error.localizedDescription) for \(userId.prefix(8))…", category: "SessionInit")
                if attempt < pingMaxAttempts {
                    // Exponential back-off: 1s, 2s
                    try? await Task.sleep(nanoseconds: pingRetryBaseDelay * UInt64(attempt))
                } else {
                    Log.error("❌ SESSION_STATE[tie_break_ping_exhausted]: loser \(userId.prefix(8))… must re-initiate manually", category: "SessionInit")
                }
            }
        }
    }

    // MARK: - Session ready signal (RESPONDER → INITIATOR, phase 2 of two-phase handshake)

    /// Sent by the RESPONDER after a successful `initReceivingSession`.
    /// Signals to the INITIATOR that both sides have established matching sessions,
    /// allowing them to cancel the watchdog and flush any buffered outgoing messages.
    private func sendSessionReady(to userId: String) async {
        guard CryptoManager.shared.hasSession(for: userId) else {
            Log.info("⚠️ SESSION_STATE[session_ready_skip]: no RESPONDER session for \(userId.prefix(8))…", category: "SessionInit")
            return
        }
        guard let myId = SessionManager.shared.currentUserId, !myId.isEmpty else { return }

        do {
            let readyContent = "__session_ready_\(UUID().uuidString)__"
            let readyMessageId = UUID().uuidString.lowercased()
            let _ = try await MessagingServiceClient.shared.sendMessage(
                messageId: readyMessageId,
                recipientId: userId,
                senderId: myId,
                conversationId: ConversationId.direct(myUserId: myId, theirUserId: userId),
                encryptedPayload: try MessageRouter.shared.encryptSessionControl(
                    plaintext: readyContent,
                    messageId: readyMessageId,
                    recipientId: userId
                ),
                timestamp: UInt64(Date().timeIntervalSince1970)
            )
            Log.info("🤝 SESSION_STATE[session_ready_sent]: RESPONDER notified INITIATOR \(userId.prefix(8))…", category: "SessionInit")
        } catch {
            Log.error("❌ SESSION_STATE[session_ready_fail]: \(error.localizedDescription) for \(userId.prefix(8))…", category: "SessionInit")
        }
    }

    // MARK: - Tie-break watchdog

    /// Start a watchdog Task that re-sends the session ping if the RESPONDER has not
    /// replied within `tieBreakWatchdogTimeout` seconds.  Cancels any prior watchdog
    /// for the same peer so multiple tie-breaks don't stack up.
    private func startTieBreakWatchdog(for userId: String) {
        tieBreakWatchdogs[userId]?.cancel()
        tieBreakWatchdogs[userId] = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: UInt64(self.tieBreakWatchdogTimeout * 1_000_000_000))
            } catch {
                return // Task was cancelled — RESPONDER replied in time
            }
            guard !Task.isCancelled else { return }
            // RESPONDER has not replied — reinitialize session so the retry ping
            // is a fresh X3DH init (msgNum=0) that RESPONDER can accept.
            Log.info("⏰ SESSION_STATE[tie_break_watchdog]: timeout — re-prewarming for \(userId.prefix(8))…", category: "SessionInit")
            await self.sessionInitService.initializeSessionProactively(
                userId: userId,
                onSuccess: { },
                onFailure: { err in
                    Log.error("❌ SESSION_STATE[watchdog_reinit_fail]: \(err.localizedDescription)", category: "SessionInit")
                }
            )
            await self.sendSessionResetInit(to: userId)
        }
    }

    /// Cancel the tie-break watchdog for `userId` once communication is confirmed.
    func cancelTieBreakWatchdog(for userId: String) {
        tieBreakWatchdogs[userId]?.cancel()
        tieBreakWatchdogs.removeValue(forKey: userId)
    }

    // MARK: - Responder fallback

    /// Starts a fallback task: if the natural INITIATOR hasn't sent a new session init within
    /// `responderFallbackTimeout` seconds, we override the ordering and init ourselves.
    private func startResponderFallback(for userId: String) {
        responderFallbackTasks[userId]?.cancel()
        responderFallbackTasks[userId] = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.responderFallbackTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard !CryptoManager.shared.hasSession(for: userId),
                      !self.isInitializing(userId) else {
                    Log.debug("⏸️ RESPONDER fallback: session already established for \(userId.prefix(8))… — skipping", category: "SessionInit")
                    return
                }
                Log.info("⚡ RESPONDER fallback: no init from \(userId.prefix(8))… after \(Int(self.responderFallbackTimeout))s — taking INITIATOR role", category: "SessionInit")
                let endInit = self.beginInit(userId)
                Task {
                    defer { Task { @MainActor in endInit() } }
                    await self.sessionInitService.initializeSessionProactively(
                        userId: userId,
                        onSuccess: { Log.info("⚡ RESPONDER fallback ✅ \(userId.prefix(8))…", category: "SessionInit") },
                        onFailure: { err in Log.error("⚡ RESPONDER fallback ❌ \(userId.prefix(8))…: \(err.localizedDescription)", category: "SessionInit") }
                    )
                }
            }
        }
    }

    /// Cancels any pending RESPONDER fallback task for `userId`.
    private func cancelResponderFallback(for userId: String) {
        responderFallbackTasks[userId]?.cancel()
        responderFallbackTasks.removeValue(forKey: userId)
    }

    // MARK: - Message persistence (session-init path only)

    private func saveMessage(for chat: Chat, with messageData: ChatMessage, decryptedContent: String) {
        guard let context = viewContext else { return }

        // Unwrap KNST1 chunk envelope to get actual plaintext
        let plaintext: String
        switch initMessageReassembler.process(decryptedText: decryptedContent) {
        case .legacy(let text), .assembled(let text, _):
            plaintext = text
        case .incomplete:
            Log.debug("⏳ Session-init message is a partial chunk — will be reassembled later", category: "SessionCoordinator")
            return
        case .invalid(let reason):
            Log.error("❌ Session-init message envelope invalid: \(reason) — saving raw", category: "SessionCoordinator")
            plaintext = decryptedContent
        }

        // Silently discard SESSION_RESET_INIT control payloads — they are sent as the X3DH
        // carrier for an atomic session reset and must never appear as chat bubbles.
        // iOS format: "__session_reset_init_<UUID>__"; other clients may omit the markers.
        if plaintext.hasPrefix("__session_reset_init") || plaintext.hasPrefix("session_reset_init_") {
            Log.info("🔄 SESSION_RESET_INIT payload discarded (not user-visible)", category: "SessionCoordinator")
            cancelTieBreakWatchdog(for: messageData.from)
            cancelResponderFallback(for: messageData.from)
            return
        }

        // Silently discard session establishment pings — they are sent after a tie-break win
        // purely to trigger RESPONDER session init on the peer and must not appear in chat.
        // Format: "__session_ping_<UUID>__" (legacy: "__session_ping__").
        if plaintext.hasPrefix("__session_ping") && plaintext.hasSuffix("__") {
            Log.info("🏓 SESSION_STATE[ping_received]: session established as RESPONDER (ping discarded)", category: "SessionCoordinator")
            // Cancel any watchdog or fallback for this peer — they proved they have an active session.
            cancelTieBreakWatchdog(for: messageData.from)
            cancelResponderFallback(for: messageData.from)
            return
        }

        // Phase 2 of two-phase handshake: RESPONDER sends __session_ready__ after its
        // initReceivingSession succeeds. We are the INITIATOR receiving confirmation.
        // Also handle legacy format without __ markers (older client versions).
        if plaintext.hasPrefix("__session_ready") || plaintext.hasPrefix("session_ready_") {
            let peerId = messageData.from
            Log.info("🤝 SESSION_STATE[session_ready_received]: RESPONDER \(peerId.prefix(8))… confirmed — session established both sides", category: "SessionCoordinator")
            // Cancel watchdog or fallback — RESPONDER proved they have a working session.
            cancelTieBreakWatchdog(for: peerId)
            cancelResponderFallback(for: peerId)
            // Transition to .active — records establishment time for stale END_SESSION filtering.
            markActive(peerId)
            // Mark session as confirmed so ChatViewModel stops buffering.
            SessionConfirmationTracker.shared.markConfirmed(peerId)
            // Flush any messages that were buffered while session was unconfirmed.
            sendSessionQueuedMessages(for: peerId)
            return
        }

        let fetchRequest = Message.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", messageData.id)

        if let existing = try? context.fetch(fetchRequest).first {
            if existing.decryptedContent == nil {
                existing.decryptedContent = plaintext
                context.saveAndLog()
            }
            return
        }

        let message = Message(context: context)
        message.id = messageData.id
        message.fromUserId = messageData.from
        message.toUserId = messageData.to
        message.encryptedContent = messageData.content
        message.decryptedContent = plaintext
        message.timestamp = Date(timeIntervalSince1970: TimeInterval(messageData.timestamp))
        message.isSentByMe = false
        message.deliveryStatus = .delivered
        message.retryCount = 0
        message.chat = chat

        chat.lastMessageText = Chat.formatPreviewText(plaintext)
        chat.lastMessageTime = message.timestamp

        context.saveAndLog()
    }

    // MARK: - Auto-resend After END_SESSION (sender-side recovery)

    /// If we receive END_SESSION from a peer, it usually means they couldn't decrypt something we sent
    /// (or their local session state was reset). In that case, resend recent unconfirmed messages
    /// under a fresh session to avoid silent message loss.
    private func resendUnconfirmedOutgoingMessagesIfNeeded(to userId: String) {
        guard let context = viewContext else { return }
        guard let myId = SessionManager.shared.currentUserId, !myId.isEmpty else { return }

        let now = Date()
        if let last = resendAttemptedAt[userId], now.timeIntervalSince(last) < resendCooldown {
            Log.info("⏸️ Auto-resend cooldown active for \(userId.prefix(8))..., skipping", category: "SessionInit")
            return
        }
        resendAttemptedAt[userId] = now

        let cutoff = now.addingTimeInterval(-resendWindow) as NSDate
        // Include .failed in addition to .sending/.sent: when the receiver sends a "failed" receipt
        // (decryption failure), the sender marks the message as .failed. Without this, those
        // messages would be silently excluded from auto-resend after the session heals.
        let statusPredicate = NSCompoundPredicate(orPredicateWithSubpredicates: [
            NSPredicate(format: "deliveryStatusRaw == %d", DeliveryStatus.sending.rawValue),
            NSPredicate(format: "deliveryStatusRaw == %d", DeliveryStatus.sent.rawValue),
            NSPredicate(format: "deliveryStatusRaw == %d", DeliveryStatus.failed.rawValue)
        ])

        let fetch = Message.fetchRequest()
        fetch.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "isSentByMe == YES"),
            NSPredicate(format: "fromUserId == %@", myId),
            NSPredicate(format: "toUserId == %@", userId),
            NSPredicate(format: "timestamp >= %@", cutoff),
            NSPredicate(format: "retryCount == 0"),
            statusPredicate
        ])
        fetch.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
        fetch.fetchLimit = 20

        guard let candidates = try? context.fetch(fetch), !candidates.isEmpty else {
            return
        }

        Log.info("🔁 END_SESSION recovery: attempting auto-resend of \(candidates.count) message(s) to \(userId.prefix(8))...", category: "SessionInit")

        Task { @MainActor in
            do {
                try await ensureSendingSession(for: userId)
            } catch {
                Log.error("❌ Auto-resend: session init failed for \(userId.prefix(8))…: \(error.localizedDescription)", category: "SessionInit")
                return
            }

            for msg in candidates {
                guard let plaintext = msg.decryptedContent else { continue }

                msg.deliveryStatus = .sending
                msg.retryCount += 1
                context.saveAndLog()

                do {
                    let messageUUID = UUID(uuidString: msg.id) ?? UUID()
                    let plan = ChunkedMessageSender.shared.buildPlan(plaintext: Data(plaintext.utf8), messageId: messageUUID)
                    guard !plan.payloads.isEmpty else {
                        Log.error("❌ Auto-resend: message too large to build chunk plan: \(msg.id.prefix(8))…", category: "SessionInit")
                        msg.deliveryStatus = .failed
                        context.saveAndLog()
                        continue
                    }

                    let responses = try await ChunkedMessageSender.shared.sendChunks(
                        plan: plan,
                        senderId: myId,
                        recipientId: userId,
                        conversationId: ConversationId.direct(myUserId: myId, theirUserId: userId),
                        timestamp: UInt64(msg.timestamp.timeIntervalSince1970)
                    )

                    let response = responses.first ?? SendMessageResponse(messageId: msg.id, status: "sent")
                    let newStatus: DeliveryStatus
                    switch response.status.lowercased() {
                    case "delivered": newStatus = .delivered
                    case "queued": newStatus = .queued
                    case "failed": newStatus = .failed
                    default: newStatus = .sent
                    }
                    msg.deliveryStatus = newStatus
                    context.saveAndLog()
                    Log.info("✅ Auto-resend: message \(msg.id.prefix(8))… status=\(newStatus)", category: "SessionInit")
                } catch {
                    msg.deliveryStatus = .failed
                    context.saveAndLog()
                    Log.error("❌ Auto-resend failed for \(msg.id.prefix(8))…: \(error.localizedDescription)", category: "SessionInit")
                }
            }
        }
    }

    private func ensureSendingSession(for userId: String) async throws {
        if CryptoManager.shared.hasSession(for: userId) {
            return
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            Task { @MainActor in
                await sessionInitService.initializeSessionProactively(
                    userId: userId,
                    onSuccess: { cont.resume(returning: ()) },
                    onFailure: { cont.resume(throwing: $0) }
                )
            }
        }
    }
}
