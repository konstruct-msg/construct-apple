//
//  FanoutRetryQueue.swift
//  Construct Messenger
//
//  Devices still owed a copy of a message the sender considers sent.
//

import Foundation

/// The other half of §C: a fan-out that failed is recoverable rather than merely counted.
///
/// ## Why a queue of its own
///
/// The primary send already has one — `Message.deliveryStatus` plus `OutgoingWirePayloadStore` —
/// and this is deliberately not it. That store holds **ciphertext**, bound to the one ratchet it
/// was produced under, which is exactly what a copy for a different device cannot reuse. And the
/// unit differs: the primary send's queue asks "did this message reach the recipient", which is
/// already true here. The question left over is "did it reach *all* of their devices", and until
/// now nothing asked it.
///
/// This queue dissolves when §D lands. Once a message names its sending device on the wire the
/// primary send stops being a special copy, `MultiDeviceSendCoordinator` becomes a loop rather
/// than a path, and every copy is retried by the machinery that already retries the first one.
/// Written to be deleted.
///
/// ## What it stores, and what it deliberately does not
///
/// Identifiers only — never a payload. Storing the plaintext chunks would make retry trivial and
/// would put message bodies at rest in a messenger whose reason to exist is that they are not
/// readable there. Kept in `LocalRepositories.keyValue` since 2026-10-11 — `UserDefaults` on iOS as
/// before, the crate's encrypted `kv` on macOS, where `UserDefaults` is a plain file and these ids
/// say who one writes to. The retry rebuilds the payload from the persisted `Message` row the
/// same way `mirrorStoredResend` does, and inherits that path's one limitation: a media message's
/// wire plaintext is an album proto the model cannot reconstruct, so it cannot be retried. That is
/// pre-existing and is reported, not hidden — `reason=not_reconstructable` on the way out.
///
/// ## The owed set
///
/// `owedDeviceIds` empty means **re-plan from scratch**, not "nothing owed": it is the shape of a
/// bundle fetch that failed, where the call that would have named the devices is the one that
/// broke. Nothing was sent in that case, so re-running the whole fan-out is correct. A non-empty
/// set is the opposite situation — the plan succeeded and named devices, some of which threw — and
/// there the retry must touch only those, because re-sending to a device that already has its copy
/// puts two ciphertexts of one message through one ratchet and renders it twice.
struct FanoutRetryEntry: Codable, Equatable {
    let baseMessageId: String
    let recipientUserId: String
    let senderUserId: String
    var owedDeviceIds: [String]
    var attempts: Int
    var nextAttemptAt: Double
    let createdAt: Double

    var key: String { "\(baseMessageId)|\(recipientUserId)" }

    init(_ copy: OwedCopy) {
        baseMessageId = copy.baseMessageId
        recipientUserId = copy.recipientUserId
        senderUserId = copy.senderUserId
        owedDeviceIds = copy.owedDeviceIds
        attempts = Int(copy.attempts)
        nextAttemptAt = Double(copy.nextAttemptAtMs) / 1000
        createdAt = Double(copy.createdAtMs) / 1000
    }

    /// The v1 JSON's shape, and how a test builds one.
    init(
        baseMessageId: String, recipientUserId: String, senderUserId: String,
        owedDeviceIds: [String], attempts: Int, nextAttemptAt: Double, createdAt: Double
    ) {
        self.baseMessageId = baseMessageId
        self.recipientUserId = recipientUserId
        self.senderUserId = senderUserId
        self.owedDeviceIds = owedDeviceIds
        self.attempts = attempts
        self.nextAttemptAt = nextAttemptAt
        self.createdAt = createdAt
    }

    fileprivate var core: OwedCopy {
        OwedCopy(
            key: key,
            baseMessageId: baseMessageId,
            recipientUserId: recipientUserId,
            senderUserId: senderUserId,
            owedDeviceIds: owedDeviceIds,
            attempts: UInt32(max(0, attempts)),
            nextAttemptAtMs: Int64(nextAttemptAt * 1000),
            createdAtMs: Int64(createdAt * 1000)
        )
    }
}

/// The rule is the core's (construct-rules `fanout_retry`, `FanoutRetryState`), one for every
/// client: Android had its own copy until 2026-11-12 (todo 300). What stays here: where it is kept
/// and when the drain runs.
///
/// `@unchecked`: every load-modify-save of the kept state runs on `queue`; `store` is set once.
final class FanoutRetryQueue: @unchecked Sendable {

    static let shared = FanoutRetryQueue()

    private let store: () -> any KeyValueStore
    /// The core's CFE (`FanoutRetryState.toBytes`).
    static let storageKey = "construct.fanoutRetryQueue.v2"
    /// v1 kept the entries as JSON. Read once into the core's state, until `legacyJSONUntil`.
    static let legacyKey = "construct.fanoutRetryQueue.v1"
    /// 2027-01-31: after it `load` stops reading v1 JSON (rule 11); `FanoutRetryQueueTests` fails
    /// on that day.
    static let legacyJSONUntil = Date(timeIntervalSince1970: 1_801_353_600)
    private let queue = DispatchQueue(label: "construct.FanoutRetryQueue")

    /// Five, then the entry is dropped and counted (`fanout_retry::MAX_ATTEMPTS`).
    let maxAttempts = Int(fanoutRetryMaxAttempts())

    /// The app's store, resolved on each use so a test or the macOS switch can replace it.
    init() {
        self.store = { LocalRepositories.keyValue }
    }

    /// A queue over `defaults` — a test's own suite.
    convenience init(defaults: UserDefaults) {
        self.init(store: DefaultsKeyValueStore(defaults: defaults))
    }

    init(store: any KeyValueStore) {
        self.store = { store }
    }

    private static func ms(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }

    // MARK: - Writing

    /// Record that `owed` devices still need their copy. A repeated key merges; an empty `owed`
    /// means plan again and never widens a named set (the core's rule).
    func enqueue(
        baseMessageId: String,
        recipientUserId: String,
        senderUserId: String,
        owed: [String]
    ) {
        change { state in
            state.enqueue(
                baseMessageId: baseMessageId, recipientUserId: recipientUserId,
                senderUserId: senderUserId, owed: owed, nowMs: Self.ms(Date())
            )
        }
    }

    /// One attempt spent. Returns the entry's state afterwards, or `nil` once it is exhausted and
    /// has been removed — so the caller counts a give-up exactly once.
    @discardableResult
    func recordAttempt(key: String) -> FanoutRetryEntry? {
        change { $0.recordAttempt(key: key, nowMs: Self.ms(Date())) }.map(FanoutRetryEntry.init)
    }

    /// Narrow an entry to exactly the devices a retry just lost; nothing left removes it.
    func replaceOwed(key: String, owed: [String]) {
        change { $0.replaceOwed(key: key, owed: owed) }
    }

    func remove(key: String) {
        change { $0.remove(key: key) }
    }

    /// Every owed copy dropped — the queue was the last account's (`AuthViewModel`'s ownership
    /// gate). Nothing is retried for an identity that no longer signs in here.
    func removeAll() {
        change { $0.removeAll() }
    }

    // MARK: - Reading

    /// Entries whose backoff has elapsed, oldest first. Expired ones are dropped on the way past.
    func due(now: Date = Date()) -> [FanoutRetryEntry] {
        change { $0.due(nowMs: Self.ms(now)) }.map(FanoutRetryEntry.init)
    }

    /// When the next live entry comes due; nil when nothing is owed. What the drain is scheduled by.
    func nextDue(now: Date = Date()) -> Date? {
        queue.sync { load().nextDue(nowMs: Self.ms(now)) }
            .map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }

    func all() -> [FanoutRetryEntry] {
        queue.sync { load().all() }.map(FanoutRetryEntry.init)
    }

    // MARK: - Storage

    /// Load, change, save — under `queue`.
    private func change<T>(_ body: (FanoutRetryState) -> T) -> T {
        queue.sync {
            let state = load()
            let result = body(state)
            save(state)
            return result
        }
    }

    private func load() -> FanoutRetryState {
        if let kept = try? store().get(Self.storageKey) {
            return FanoutRetryState.fromBytes(kept: kept)
        }
        guard let v1 = try? store().get(Self.legacyKey) else { return FanoutRetryState() }
        // JSON by rule 6's exception — an earlier build's format, read once into the core's state.
        let entries = (try? JSONDecoder().decode([FanoutRetryEntry].self, from: v1)) ?? []
        let state = FanoutRetryState.restore(entries: entries.map(\.core))
        save(state)
        try? store().remove(Self.legacyKey)
        return state
    }

    private func save(_ state: FanoutRetryState) {
        do {
            guard !state.all().isEmpty else {
                try store().remove(Self.storageKey)
                return
            }
            try store().put(Self.storageKey, try state.toBytes())
        } catch {
            Log.error("FanoutRetryQueue: not saved — owed copies will not survive a restart: \(error)", category: "MultiDevice")
        }
    }
}
