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
/// would put message bodies in `UserDefaults` in a messenger whose reason to exist is that they
/// are not readable at rest. The retry rebuilds the payload from the persisted `Message` row the
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
}

final class FanoutRetryQueue {

    static let shared = FanoutRetryQueue()

    private let defaults: UserDefaults
    private let storageKey = "construct.fanoutRetryQueue.v1"
    private let queue = DispatchQueue(label: "construct.FanoutRetryQueue")

    /// Matches `OutgoingWirePayloadStore.entryTtl`. A copy owed for longer than a day is not worth
    /// delivering: the recipient device has almost certainly healed by other means, and the
    /// transcript gap it would fill is now old enough that arriving out of order is its own defect.
    private let entryTtl: TimeInterval = 24 * 60 * 60

    /// Five, then the entry is dropped and counted. The cap exists because a device that is
    /// permanently unreachable — revoked, wiped, never coming back — is indistinguishable here
    /// from one that is briefly offline, and retrying it forever would burn a one-time pre-key per
    /// attempt against an account that has none to spare.
    let maxAttempts = 5

    private let baseBackoff: TimeInterval = 30
    private let maxBackoff: TimeInterval = 3600

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Writing

    /// Record that `owed` devices still need their copy.
    ///
    /// Merging rather than replacing on a repeated key: two chunks of one message can fail
    /// independently, and the second enqueue must not erase what the first recorded. `createdAt`
    /// is kept from the earlier entry so a message cannot extend its own TTL by failing again.
    ///
    /// An empty `owed` on an entry that already names devices is **not** widened back to a
    /// re-plan: the named set is more precise, and losing it would re-send to devices that
    /// already have the message.
    func enqueue(
        baseMessageId: String,
        recipientUserId: String,
        senderUserId: String,
        owed: [String]
    ) {
        guard !baseMessageId.isEmpty, !recipientUserId.isEmpty else { return }
        queue.sync {
            var all = load()
            let key = "\(baseMessageId)|\(recipientUserId)"
            if let index = all.firstIndex(where: { $0.key == key }) {
                var merged = all[index]
                if !owed.isEmpty {
                    merged.owedDeviceIds = Array(Set(merged.owedDeviceIds).union(owed)).sorted()
                }
                all[index] = merged
            } else {
                all.append(FanoutRetryEntry(
                    baseMessageId: baseMessageId,
                    recipientUserId: recipientUserId,
                    senderUserId: senderUserId,
                    owedDeviceIds: owed.sorted(),
                    attempts: 0,
                    nextAttemptAt: Date().timeIntervalSince1970 + baseBackoff,
                    createdAt: Date().timeIntervalSince1970
                ))
            }
            save(all)
        }
    }

    /// One attempt spent. Returns the entry's state afterwards, or `nil` once it is exhausted and
    /// has been removed — so the caller counts a give-up exactly once.
    @discardableResult
    func recordAttempt(key: String) -> FanoutRetryEntry? {
        queue.sync {
            var all = load()
            guard let index = all.firstIndex(where: { $0.key == key }) else { return nil }
            var entry = all[index]
            entry.attempts += 1
            guard entry.attempts < maxAttempts else {
                all.remove(at: index)
                save(all)
                return nil
            }
            let backoff = min(baseBackoff * pow(2, Double(entry.attempts)), maxBackoff)
            entry.nextAttemptAt = Date().timeIntervalSince1970 + backoff
            all[index] = entry
            save(all)
            return entry
        }
    }

    /// Narrow an entry to exactly the devices a retry just lost.
    ///
    /// Distinct from `enqueue`, which unions, and the difference is a duplicate copy: a re-plan
    /// entry (`owed` empty) that reaches one device and loses another must come out of the attempt
    /// naming only the one it lost. Unioning would leave it empty — still a re-plan — and the next
    /// pass would send a second ciphertext of one message to the device that already has it.
    ///
    /// Only the drain calls this, and only for an entry it is holding; an empty `owed` here would
    /// mean "re-plan again", so the caller removes the entry instead when nothing is left.
    func replaceOwed(key: String, owed: [String]) {
        queue.sync {
            var all = load()
            guard let index = all.firstIndex(where: { $0.key == key }) else { return }
            all[index].owedDeviceIds = owed.sorted()
            save(all)
        }
    }

    func remove(key: String) {
        queue.sync {
            var all = load()
            all.removeAll { $0.key == key }
            save(all)
        }
    }

    // MARK: - Reading

    /// Entries whose backoff has elapsed, oldest first. Expired ones are dropped on the way past —
    /// the TTL is enforced on read so a queue nobody drains cannot grow without bound.
    func due(now: Date = Date()) -> [FanoutRetryEntry] {
        queue.sync {
            let t = now.timeIntervalSince1970
            let live = load().filter { t - $0.createdAt < entryTtl }
            save(live)
            return live.filter { $0.nextAttemptAt <= t }.sorted { $0.createdAt < $1.createdAt }
        }
    }

    func all() -> [FanoutRetryEntry] {
        queue.sync { load() }
    }

    // MARK: - Storage

    private func load() -> [FanoutRetryEntry] {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([FanoutRetryEntry].self, from: data)
        else { return [] }
        return decoded
    }

    private func save(_ entries: [FanoutRetryEntry]) {
        guard !entries.isEmpty else {
            defaults.removeObject(forKey: storageKey)
            return
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
