import Foundation

/// Tracks per-contact message activity and schedules proactive session health checks.
///
/// Two layers of protection:
/// 1. **Auto-heartbeat** — if silence > 12 hours and a session is active, sends a silent
///    `HEARTBEAT` (content_type=13) to exercise the ratchet before the user's next real message.
/// 2. **Pre-flight health check** — before the first real message after 6h of silence,
///    queries `getSessionHealth()` and triggers proactive re-init if the session looks stale.
@MainActor
final class SessionActivityTracker {

    static let shared = SessionActivityTracker()

    // MARK: - Constants

    /// If last activity was more than this long ago, run a session health pre-flight.
    private let prefightThreshold: TimeInterval = 6 * 3600        // 6 hours

    /// If last activity was more than this long ago, send a proactive heartbeat.
    private let heartbeatThreshold: TimeInterval = 12 * 3600      // 12 hours

    /// Skipped-keys count above this triggers proactive reinit.
    private let skippedKeysDangerThreshold: UInt32 = 500

    private let defaults = UserDefaults.standard
    private let keyPrefix = "session_last_activity_"

    // MARK: - Activity Recording

    /// Call after every successful message send **or** receive for `contactId`.
    func recordActivity(for contactId: String) {
        defaults.set(Date().timeIntervalSince1970, forKey: keyPrefix + contactId)
    }

    /// Seconds since the last recorded activity for `contactId`.
    /// Returns `nil` if we have no record (treat as "very long ago").
    func secondsSinceLastActivity(for contactId: String) -> TimeInterval? {
        let ts = defaults.double(forKey: keyPrefix + contactId)
        guard ts > 0 else { return nil }
        return Date().timeIntervalSince1970 - ts
    }

    // MARK: - Pre-flight Check

    /// Run before encrypting a user-visible message to `contactId`.
    ///
    /// - Returns: `true` if the session is healthy and the caller may proceed with encryption.
    ///   `false` if the session was unhealthy and a proactive reinit was triggered (caller
    ///   should wait for the new `NotifySessionCreated` event before retrying).
    func preflight(for contactId: String) async -> Bool {
        guard let age = secondsSinceLastActivity(for: contactId),
              age > prefightThreshold else {
            return true  // Recent activity → skip check
        }
        guard let health = CryptoManager.shared.getSessionHealth(for: contactId) else {
            // No session in memory yet — nothing to validate.
            return true
        }

        let ratchetAge = Date().timeIntervalSince1970 - TimeInterval(health.lastRatchetAt)
        let skippedKeysDanger = health.skippedKeysCount >= skippedKeysDangerThreshold

        if skippedKeysDanger {
            Log.error(
                "Pre-flight: \(contactId.prefix(8))… skipped_keys=\(health.skippedKeysCount) ≥ \(skippedKeysDangerThreshold) — proactive reinit",
                category: "SessionActivityTracker"
            )
            return false
        }

        Log.debug(
            "Pre-flight OK: \(contactId.prefix(8))… sent=\(health.messagesSent) recv=\(health.messagesReceived) skipped=\(health.skippedKeysCount) ratchet_age=\(Int(ratchetAge))s pq=\(health.isPqStrengthened)",
            category: "SessionActivityTracker"
        )
        return true
    }

    // MARK: - Auto-heartbeat

    /// Check all active sessions and send a heartbeat to contacts that have been
    /// silent for more than `heartbeatThreshold`.
    ///
    /// Call on app foreground and optionally from a background task.
    func sendStaleSessionHeartbeats() async {
        let contactIds = CryptoManager.shared.getAllSessionUserIds()
        for contactId in contactIds {
            guard let age = secondsSinceLastActivity(for: contactId) else {
                // No activity record — might be a very old session; skip.
                continue
            }
            guard age > heartbeatThreshold else { continue }

            Log.info(
                "Auto-heartbeat: \(contactId.prefix(8))… silent for \(Int(age / 3600))h",
                category: "SessionActivityTracker"
            )
            await OutboundSessionService.shared.sendSessionHeartbeat(to: contactId)
            // Record the heartbeat as activity so we don't spam.
            recordActivity(for: contactId)
        }
    }

    // MARK: - Session Audit

    /// Log a full health summary for all active sessions (debug/diagnostics only).
    func logSessionHealthSummary() {
        let contactIds = CryptoManager.shared.getAllSessionUserIds()
        guard !contactIds.isEmpty else {
            Log.debug("Session health: no active sessions", category: "SessionActivityTracker")
            return
        }
        Log.info("Session health summary (\(contactIds.count) sessions):", category: "SessionActivityTracker")
        for contactId in contactIds {
            if let health = CryptoManager.shared.getSessionHealth(for: contactId) {
                let ratchetAge = Int(Date().timeIntervalSince1970 - TimeInterval(health.lastRatchetAt))
                let activityAge = secondsSinceLastActivity(for: contactId).map { Int($0) }
                Log.info(
                    "\(contactId.prefix(8))… sent=\(health.messagesSent) recv=\(health.messagesReceived) skipped=\(health.skippedKeysCount) ratchet_age=\(ratchetAge)s activity_age=\(activityAge.map { "\($0)s" } ?? "unknown") pq=\(health.isPqStrengthened)",
                    category: "SessionActivityTracker"
                )
            } else {
                Log.error("\(contactId.prefix(8))… — health unavailable (session not in memory?)", category: "SessionActivityTracker")
            }
        }
    }
}
