import Foundation

/// Tracks message IDs that have permanently failed `initReceivingSession`.
///
/// Used to prevent the orphaned-init exception in `MessageRouter` from re-processing
/// a stale message on every reconnect after OTPK exhaustion or an unrecoverable
/// decryption failure. Persists across app launches via UserDefaults.
///
/// Lifecycle: entries are cheap (UUID strings) and self-pruning at 200 entries.
final class FailedInitMessageStore {
    static let shared = FailedInitMessageStore()
    private init() {}

    private let key = "com.construct.failed_init_message_ids"
    private let maxEntries = 200

    // MARK: - Public API

    func add(_ messageId: String) {
        var current = load()
        guard !current.contains(messageId) else { return }
        current.append(messageId)
        if current.count > maxEntries {
            current = Array(current.suffix(maxEntries / 2))
        }
        save(current)
    }

    func contains(_ messageId: String) -> Bool {
        load().contains(messageId)
    }

    // MARK: - Private

    private func load() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    private func save(_ ids: [String]) {
        UserDefaults.standard.set(ids, forKey: key)
    }
}
