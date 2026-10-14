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
    func prewarmSessions(for contactIds: [String]) {
        coordinator.prewarmSessions(for: contactIds)
    }

    /// Re-establish a session for a purely-outbound peer that has queued messages but no live
    /// session (the "zombie session"). Forces the INITIATOR role to break the deadlock where we
    /// are the natural RESPONDER and nothing else ever triggers an init. Called from
    /// `MessageRetryManager` when a queued flush finds no session and the core is ready.
    func reestablishSessionForQueuedOutbound(to userId: String) {
        coordinator.reestablishSessionForQueuedOutbound(to: userId)
    }

    /// The server refused a ciphertext we wrote for some of `userId`'s devices: retire our current
    /// state with each of `devices` (every device of the peer when `nil`). Local only — the next
    /// send opens a new state and the peer opens it from the header beside its own. Until
    /// 2026-09-27 this sent END_SESSION. There is no user-facing reset: a session renews by
    /// sending, and a state the peer cannot read is retired by its DECRYPTION_ERROR (2026-09-28).
    func resetSession(with userId: String, devices: [String]? = nil, reason: String) {
        let targets = devices ?? SessionAddressing.deviceIds(ofPeer: userId)
        var retired = 0
        for device in targets {
            if CryptoManager.shared.retireSession(device: device) { retired += 1 }
        }
        Log.info("SESSION_STATE[reset]: \(userId.prefix(8))… — retired \(retired)/\(targets.count) device session(s) (\(reason))", category: "SessionInit")
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
        return CryptoManager.shared.hasSessionWithAnyDevice(ofPeer: userId)
    }
}
