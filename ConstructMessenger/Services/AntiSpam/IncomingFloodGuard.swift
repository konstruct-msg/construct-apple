//
//  IncomingFloodGuard.swift
//  Construct Messenger
//
//  Detects per-sender message bursts on the receiving side.
//  Runs entirely on-device; the attacker cannot bypass it by using a custom API client
//  because the protection is applied *after* the message reaches this device.
//

import Foundation
import Combine

// MARK: - FloodCheckResult

enum FloodCheckResult {
    /// Normal rate — allow notification and rendering.
    case normal
    /// Burst threshold crossed — first time for this sender.
    /// The caller should suppress the notification and post a one-time alert.
    case burstDetected(messageCount: Int)
    /// Sender is already suppressed; silently drop notification.
    case alreadySuppressed
}

// MARK: - IncomingFloodGuard

/// Detects per-sender incoming message bursts and lets the UI suppress
/// notifications for senders who are flooding this device.
///
/// Thread-safety: all mutations are protected by a serial queue.
final class IncomingFloodGuard {

    static let shared = IncomingFloodGuard()

    // MARK: - Configuration

    /// Sliding window length in seconds.
    let windowDuration: TimeInterval = 30
    /// Number of messages within the window that triggers a burst.
    let burstThreshold = 10

    // MARK: - State

    private var queue = DispatchQueue(label: "com.construct.floodguard", qos: .utility)
    /// In-memory sliding window per senderId.
    private var timestamps: [String: [Date]] = [:]

    /// Persisted set of sender IDs whose notifications are suppressed.
    private let suppressedKey = "com.construct.floodguard.suppressed"
    private var storedSuppressed: Set<String> = []

    /// Published so the UI can observe changes without polling.
    @Published private(set) var suppressedSenders: Set<String> = []

    private init() {
        let stored = UserDefaults.standard.stringArray(forKey: suppressedKey) ?? []
        storedSuppressed = Set(stored)
        suppressedSenders = storedSuppressed
    }

    // MARK: - Check (called for every incoming message, on background queue)

    /// Evaluate an incoming message from `senderId`.
    /// Must be called from a background thread; internally serialised.
    func check(senderId: String) -> FloodCheckResult {
        queue.sync {
            // Already suppressed — fast path
            if storedSuppressed.contains(senderId) {
                return .alreadySuppressed
            }

            let now = Date()
            var window = timestamps[senderId, default: []]
            window = window.filter { now.timeIntervalSince($0) < windowDuration }
            window.append(now)
            timestamps[senderId] = window

            if window.count >= burstThreshold {
                storedSuppressed.insert(senderId)
                persist()
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    suppressedSenders = storedSuppressed
                }
                return .burstDetected(messageCount: window.count)
            }

            return .normal
        }
    }

    // MARK: - User actions

    /// Manually suppress a sender (e.g. user tapped "Mute" from the alert).
    func suppress(senderId: String) {
        queue.async { [weak self] in
            guard let self else { return }
            storedSuppressed.insert(senderId)
            persist()
            DispatchQueue.main.async { self.suppressedSenders = self.storedSuppressed }
        }
    }

    /// Allow a sender through again (user tapped "Allow" in the chat banner).
    func unsuppress(senderId: String) {
        queue.async { [weak self] in
            guard let self else { return }
            storedSuppressed.remove(senderId)
            timestamps.removeValue(forKey: senderId)
            persist()
            DispatchQueue.main.async { self.suppressedSenders = self.storedSuppressed }
        }
    }

    func isSuppressed(_ senderId: String) -> Bool {
        queue.sync { storedSuppressed.contains(senderId) }
    }

    // MARK: - Persistence

    private func persist() {
        UserDefaults.standard.set(Array(storedSuppressed), forKey: suppressedKey)
    }
}
