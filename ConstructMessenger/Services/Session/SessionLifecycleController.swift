import CoreData

@MainActor
final class SessionLifecycleController {
    static let shared = SessionLifecycleController()

    /// Underlying coordinator that owns all session state.
    /// Exposed for `ChatsViewModel` wiring; external callers must use the
    /// typed facade methods above.
    let coordinator: SessionCoordinator

    private init() {
        self.coordinator = SessionCoordinator()
    }

    // MARK: - Setup

    func configure(streamManager: MessageStreamManager) {
        coordinator.configure(streamManager: streamManager)
    }

    func setContext(_ context: NSManagedObjectContext) {
        coordinator.setContext(context)
    }

    /// Callback needed when the stream layer requires an ephemeral subscription
    /// for a user (e.g., after a tie-break loss).
    ///
    /// **Set once during composition** (by `ChatsViewModel.init`). Do not reassign —
    /// the setter overwrites the previous value, which would silently break routing
    /// if called a second time.
    var onEphemeralSubscriptionNeeded: ((String) -> Void)? {
        didSet {
            coordinator.onEphemeralSubscriptionNeeded = onEphemeralSubscriptionNeeded
        }
    }

    var onE2EDeliveryReceiptDecrypted: (([String]) -> Void)? {
        didSet {
            coordinator.onE2EDeliveryReceiptDecrypted = onE2EDeliveryReceiptDecrypted
        }
    }

    // MARK: - Incoming message routing

    /// Route an incoming message through the session pipeline.
    /// Call this from the stream layer for every incoming message.
    func routeIncomingMessage(_ message: ChatMessage, in context: NSManagedObjectContext) {
        coordinator.routeIncomingMessage(message, in: context)
    }

    // MARK: - Session lifecycle (user-facing)

    /// Proactively initialize an E2E session as INITIATOR.
    /// Used when opening a chat, creating a new contact, etc.
    func prewarmSessions(for contactIds: [String], skipEndSessionNotification: Bool = false) {
        coordinator.prewarmSessions(for: contactIds, skipEndSessionNotification: skipEndSessionNotification)
    }

    /// Re-establish a session for a purely-outbound peer that has queued messages but no live
    /// session (the "zombie session"). Forces the INITIATOR role to break the deadlock where we
    /// are the natural RESPONDER and nothing else ever triggers an init. Called from
    /// `MessageRetryManager` when a queued flush finds no session and the core is ready.
    func reestablishSessionForQueuedOutbound(to userId: String) {
        coordinator.reestablishSessionForQueuedOutbound(to: userId)
    }

    /// Send END_SESSION to a specific contact and archive local state.
    func sendEndSession(to userId: String, reason: String = "manual_reset") async throws {
        try await coordinator.sendEndSession(to: userId, reason: reason)
    }

    /// Broadcast END_SESSION to all active sessions (used on logout).
    func sendEndSessionToAllContacts(reason: String = "logout") async {
        await coordinator.sendEndSessionToAllContacts(reason: reason)
    }

    // MARK: - Key sync

    /// Re-key the sending session when the peer's public keys changed.
    func handleKeySyncRequest(for userId: String) {
        coordinator.handleKeySyncRequest(for: userId)
    }

    // MARK: - Session state query (for UI gating)

    /// Whether an active E2E session exists for the contact.
    /// Do NOT use this to make protocol decisions; it is for UI state only.
    func hasActiveSession(for userId: String) -> Bool {
        return CryptoManager.shared.hasSession(for: userId)
    }
}
