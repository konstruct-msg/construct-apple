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

    private let key: String
    private let maxEntries = 200
    private let defaults: UserDefaults

    /// Production init — uses standard UserDefaults.
    convenience init() {
        self.init(suiteName: nil)
    }

    /// Isolated init for unit tests — pass a unique suiteName to avoid polluting
    /// the app's shared UserDefaults. Tear down with `removePersistentDomain`.
    init(suiteName: String?) {
        if let name = suiteName {
            self.defaults = UserDefaults(suiteName: name) ?? .standard
            self.key = "com.construct.failed_init_message_ids"
        } else {
            self.defaults = .standard
            self.key = "com.construct.failed_init_message_ids"
        }
    }

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
        defaults.stringArray(forKey: key) ?? []
    }

    private func save(_ ids: [String]) {
        defaults.set(ids, forKey: key)
    }
}
