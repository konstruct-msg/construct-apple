import Foundation
import Synchronization

/// Tracks message IDs that have permanently failed `initReceivingSession`.
///
/// Used to prevent the orphaned-init exception in `MessageRouter` from re-processing
/// a stale message on every reconnect after OTPK exhaustion or an unrecoverable
/// decryption failure. Persists across app launches via UserDefaults.
///
/// Lifecycle: entries are cheap (UUID strings) and self-pruning at 200 entries.
/// `@unchecked`: `UserDefaults` is thread-safe but not annotated in this SDK; `lock` serialises `add`.
final class FailedInitMessageStore: @unchecked Sendable {
    static let shared = FailedInitMessageStore()

    private let key: String
    private let maxEntries = 200
    private let defaults: UserDefaults
    /// `add` reads, appends and writes back; two adds racing would drop one id.
    private let lock = Mutex(())

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
        lock.withLock { _ in
            var current = load()
            guard !current.contains(messageId) else { return }
            current.append(messageId)
            if current.count > maxEntries {
                current = Array(current.suffix(maxEntries / 2))
            }
            save(current)
        }
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
