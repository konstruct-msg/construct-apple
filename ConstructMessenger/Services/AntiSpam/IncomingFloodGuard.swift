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
/// A burst is counted by when the **server** queued each message, not by when this device got to
/// it. Until 2026-10-15 it counted arrivals by `Date()`, so a mailbox drained at launch — a second
/// device back after a day — was ten messages in a second from every busy chat, and each of those
/// people was muted for good. Backlog is not a flood; a live flood is queued now.
///
/// Suppression lasts while the flood does: it lapses after `quietPeriod` with no live message from
/// that sender, and lives in memory only. It used to be persisted and never lifted on its own, so a
/// false alarm muted a contact until someone found the banner in their chat.
///
/// Thread-safety: all mutations are protected by a serial queue.
final class IncomingFloodGuard: ObservableObject, @unchecked Sendable {  // state behind `queue`; `suppressedSenders` written on main

    static let shared = IncomingFloodGuard()

    // MARK: - Configuration

    /// Sliding window length in seconds.
    let windowDuration: TimeInterval = 30
    /// Number of messages within the window that triggers a burst.
    let burstThreshold = 10
    /// How long a suppression outlives the last live message of the flood.
    let quietPeriod: TimeInterval = 5 * 60

    // MARK: - State

    private var queue = DispatchQueue(label: "com.construct.floodguard", qos: .utility)
    /// Server queue times of the recent live messages, per senderId.
    private var timestamps: [String: [Date]] = [:]
    /// Suppressed senders and when each suppression lapses.
    private var suppressedUntil: [String: Date] = [:]

    /// Published so the UI can observe changes without polling.
    @Published private(set) var suppressedSenders: Set<String> = []

    /// Where suppressions were persisted until 2026-10-15; cleared once, they were false alarms
    /// from launch backlogs as often as not.
    static let legacySuppressedKey = "com.construct.floodguard.suppressed"

    init(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: Self.legacySuppressedKey)
    }

    // MARK: - Check (called for every incoming message, on background queue)

    /// Evaluate an incoming message from `senderId` that the server queued at `queuedAt` (nil when
    /// the envelope carried no server position: counted as live).
    func check(senderId: String, queuedAt: Date?, now: Date = Date()) -> FloodCheckResult {
        let result: FloodCheckResult = queue.sync {
            lapse(now: now)
            let at = min(queuedAt ?? now, now)
            let live = now.timeIntervalSince(at) < windowDuration

            if let until = suppressedUntil[senderId] {
                if live { suppressedUntil[senderId] = max(until, now.addingTimeInterval(quietPeriod)) }
                return .alreadySuppressed
            }
            guard live else { return .normal }

            var window = timestamps[senderId, default: []]
            window = window.filter { now.timeIntervalSince($0) < windowDuration }
            window.append(at)
            timestamps[senderId] = window

            if window.count >= burstThreshold {
                suppressedUntil[senderId] = now.addingTimeInterval(quietPeriod)
                timestamps.removeValue(forKey: senderId)
                publish()
                return .burstDetected(messageCount: window.count)
            }
            return .normal
        }
        if case .burstDetected = result { scheduleLapse() }
        return result
    }

    // MARK: - User actions

    /// Allow a sender through again (user tapped "Allow" in the chat banner).
    func unsuppress(senderId: String) {
        queue.async { [weak self] in
            guard let self else { return }
            suppressedUntil.removeValue(forKey: senderId)
            timestamps.removeValue(forKey: senderId)
            publish()
        }
    }

    func isSuppressed(_ senderId: String, now: Date = Date()) -> Bool {
        queue.sync {
            lapse(now: now)
            return suppressedUntil[senderId] != nil
        }
    }

    // MARK: - Lapse

    /// Drops suppressions whose flood has gone quiet. Call on `queue`.
    private func lapse(now: Date) {
        let before = suppressedUntil.count
        suppressedUntil = suppressedUntil.filter { $0.value > now }
        if suppressedUntil.count != before { publish() }
    }

    /// The banner should leave when the suppression lapses, whether or not another message comes.
    private func scheduleLapse() {
        queue.asyncAfter(deadline: .now() + quietPeriod + 1) { [weak self] in
            guard let self else { return }
            lapse(now: Date())
            if !suppressedUntil.isEmpty { scheduleLapse() }
        }
    }

    /// Call on `queue`.
    private func publish() {
        let current = Set(suppressedUntil.keys)
        DispatchQueue.main.async { [weak self] in self?.suppressedSenders = current }
    }
}
