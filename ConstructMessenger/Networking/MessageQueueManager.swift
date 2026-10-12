//
//  MessageQueueManager.swift
//  Construct Messenger
//
//  Manages message queue for offline/online scenarios
//

import Foundation
import os.log

@MainActor
@Observable
class MessageQueueManager {
    static let shared = MessageQueueManager()

    private let networkManager = NetworkReachabilityManager.shared
    private var reachabilityTask: Task<Void, Never>?
    private var checkTimer: Timer?

    private var pendingSends: [String: Date] = [:]

    private init() {
        // Skip setup in preview mode
        if !PreviewDetector.isRunningInPreview {
            resetStuckSendingMessages()
            setupSubscribers()
            startPeriodicCheck()
            Log.info("MessageQueueManager initialized", category: "MessageQueue")
        }
    }

    // MARK: - Setup

    /// A `.sending` row at launch belongs to a process that is gone: `pendingSends` does not
    /// survive it, so the live timeout never sees the row. A real message is marked `.failed`,
    /// which the retry fetch already selects. An upload placeholder is retired instead — writing
    /// `.queued` here is how its sentinel JSON became a text message.
    ///
    /// No age threshold. The owner is this process, and every `.sending` row it does not have in
    /// `pendingSends` is already orphaned. Waiting N minutes would leave a kill from a few seconds
    /// ago spinning until a later launch.
    private func resetStuckSendingMessages() {
        let ceiling = Int16(clamping: FeatureFlags.maxMessageRetryAttempts)
        // On the main actor, as every send that registers in `pendingSends` is: none lands
        // between this read and the writes below.
        let owned = Set(pendingSends.keys)
        guard let stuck = try? LocalRepositories.messages.ownMessages(in: .sending, limit: .max),
              !stuck.isEmpty else { return }
        var failed = 0
        var retired = 0
        for message in stuck {
            let disposition = StuckSend.disposition(
                statusIsSending: message.deliveryStatus == .sending,
                ownedByThisProcess: owned.contains(message.id),
                bodyIsUploadSentinel: UploadPlaceholderBody.isSentinel(message.payload.displayString)
            )
            guard let stored = StuckSend.write(
                disposition: disposition,
                retryCount: message.retryCount,
                retryCeiling: ceiling
            ) else { continue }
            // Through the repository (messages B2): the status under the store's rule, then
            // the retry budget.
            _ = try? LocalRepositories.messages.setDeliveryStatus(message.id, stored.status)
            _ = try? LocalRepositories.messages.setRetryCount(message.id, stored.retryCount)
            switch disposition {
            case .leave: break
            case .failForRetry: failed += 1
            case .retirePlaceholder: retired += 1
            }
        }
        guard failed > 0 || retired > 0 else { return }
        Log.info(
            "Orphaned sends: \(failed) marked failed for retry, \(retired) upload placeholder(s) retired",
            category: "MessageQueue"
        )
    }

    private func setupSubscribers() {
        // Monitor network reachability using @Observable tracking
        reachabilityTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = self.networkManager.isReachable
                    } onChange: {
                        continuation.resume()
                    }
                }
                guard !Task.isCancelled, self.networkManager.isReachable else { continue }
                Log.info("Network available - checking for queued messages", category: "MessageQueue")
                self.processQueuedMessages()
            }
        }
    }

    // MARK: - Message Tracking

    func markMessageAsSending(_ messageId: String) {
        pendingSends[messageId] = Date()
    }

    func markMessageAsSent(_ messageId: String) {
        pendingSends.removeValue(forKey: messageId)
    }

    func markMessageAsFailed(_ messageId: String) {
        pendingSends.removeValue(forKey: messageId)
    }

    // MARK: - Periodic Check

    private func startPeriodicCheck() {
        // Check every 5 seconds for stuck messages
        checkTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkForStuckMessages() }
        }
        Log.info("Started periodic message queue check", category: "MessageQueue")
    }

    private func stopPeriodicCheck() {
        checkTimer?.invalidate()
        checkTimer = nil
    }

    /// Check for messages that have been stuck in sending state too long
    private func checkForStuckMessages() {
        let timeout = APIConstants.messageSendTimeout
        let now = Date()

        // Source of truth for "how long have we been sending": `pendingSends`.
        // Do NOT infer from `Message.timestamp` - that is message creation time,
        // and using it here causes false timeouts and retry storms.
        let timedOutIds = pendingSends.compactMap { (messageId, startedAt) -> String? in
            now.timeIntervalSince(startedAt) > timeout ? messageId : nil
        }
        if !timedOutIds.isEmpty {
            handleTimedOutMessages(timedOutIds)
        }
    }

    private func handleTimedOutMessages(_ messageIds: [String]) {
        for messageId in messageIds {
            // Read and written through the repository (messages B2).
            if (try? LocalRepositories.messages.message(messageId))?.deliveryStatus == .sending {
                Log.info("Message \(messageId) timed out, marking as queued", category: "MessageQueue")
                _ = try? LocalRepositories.messages.setDeliveryStatus(messageId, .queued)
                markMessageAsFailed(messageId)
            }
        }
        // Try to resend if network is available (gRPC reconnects automatically)
        if networkManager.isReachable { processQueuedMessages() }
    }

    // MARK: - Process Queued Messages

    /// Process all queued messages (called when network is restored).
    func processQueuedMessages() {
        guard networkManager.isReachable else {
            Log.debug("Cannot process queued messages - network not reachable", category: "MessageQueue")
            return
        }
        guard let currentUserId = AuthSessionManager.shared.currentUserId else {
            Log.debug("Cannot process queued messages - no current user", category: "MessageQueue")
            return
        }
        MessageRetryManager.shared.processAllQueuedMessages(currentUserId: currentUserId)
        // The second queue, and a different question. The one above asks whether a message reached
        // the recipient; this one asks whether it reached all of their devices, which a message
        // marked `sent` can still fail. Before 2026-08-31 nothing asked it: a device skipped by a
        // failed fan-out stayed skipped, because the send that would have covered it had already
        // reported success. See §C of the multi-device plan.
        Task { @MainActor in
            await MultiDeviceSendCoordinator.shared.drainRetryQueue(currentUserId: currentUserId)
        }
    }
}
