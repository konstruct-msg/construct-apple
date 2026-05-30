//
//  MessageQueueManager.swift
//  Construct Messenger
//
//  Manages message queue for offline/online scenarios
//

import Foundation
import CoreData
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

    /// Reset any messages left in `sending` state from a previous app run.
    /// On force-quit the in-memory `pendingSends` is lost, so those messages
    /// would never time-out.  Resetting them to `queued` on startup guarantees
    /// they enter the normal retry pipeline.
    private func resetStuckSendingMessages() {
        let context = PersistenceController.shared.container.viewContext
        context.perform {
            let fetchRequest: NSFetchRequest<Message> = Message.fetchRequest()
            fetchRequest.predicate = NSPredicate(
                format: "deliveryStatusRaw == %d",
                DeliveryStatus.sending.rawValue
            )
            guard let stuck = try? context.fetch(fetchRequest), !stuck.isEmpty else { return }
            for message in stuck {
                message.deliveryStatus = .queued
            }
            do {
                try context.save()
                Log.info("Reset \(stuck.count) stuck-sending message(s) to queued on launch", category: "MessageQueue")
            } catch {
                Log.error("Failed to reset stuck-sending messages: \(error)", category: "MessageQueue")
            }
        }
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
        // Safety check: ensure Core Data is available
        let context = PersistenceController.shared.container.viewContext
        guard context.persistentStoreCoordinator != nil else {
            Log.info("Core Data store coordinator unavailable, skipping stuck message check", category: "MessageQueue")
            return
        }

        let timeout = APIConstants.messageSendTimeout
        let now = Date()

        // Source of truth for "how long have we been sending": `pendingSends`.
        // Do NOT infer from `Message.timestamp` - that is message creation time,
        // and using it here causes false timeouts and retry storms.
        let timedOutIds = pendingSends.compactMap { (messageId, startedAt) -> String? in
            now.timeIntervalSince(startedAt) > timeout ? messageId : nil
        }
        if !timedOutIds.isEmpty {
            handleTimedOutMessages(timedOutIds, context: context)
        }
    }

    private func handleTimedOutMessages(_ messageIds: [String], context: NSManagedObjectContext) {
        context.perform {
            for messageId in messageIds {
                let fetchRequest: NSFetchRequest<Message> = Message.fetchRequest()
                fetchRequest.predicate = NSPredicate(format: "id == %@", messageId)

                if let message = try? context.fetch(fetchRequest).first {
                    if message.deliveryStatus == .sending {
                        Log.info("Message \(messageId) timed out, marking as queued", category: "MessageQueue")
                        message.deliveryStatus = .queued
                        Task { @MainActor [weak self, messageId] in self?.markMessageAsFailed(messageId) }
                    }
                }
            }

            do {
                try context.save()
            } catch {
                Log.error("MessageQueueManager: failed to save timed-out message statuses: \(error)", category: "MessageQueue")
            }
            // Try to resend if network is available (gRPC reconnects automatically)
            Task { @MainActor [weak self] in
                if self?.networkManager.isReachable == true { self?.processQueuedMessages() }
            }
        }
    }

    // MARK: - Process Queued Messages

    /// Process all queued messages (called when network is restored).
    // NOTE: Uses viewContext because MessageRetryManager internally switches to MainActor
    // for Core Data operations. Full background-context migration requires refactoring
    // MessageRetryManager's MainActor.run { context.fetch } pattern first.
    func processQueuedMessages() {
        guard networkManager.isReachable else {
            Log.debug("Cannot process queued messages - network not reachable", category: "MessageQueue")
            return
        }
        guard let currentUserId = AuthSessionManager.shared.currentUserId else {
            Log.debug("Cannot process queued messages - no current user", category: "MessageQueue")
            return
        }
        MessageRetryManager.shared.processAllQueuedMessages(
            currentUserId: currentUserId,
            context: PersistenceController.shared.container.viewContext
        )
    }

    /// Get count of queued messages — uses async fetch on background context to avoid
    /// blocking the main thread with large Core Data queries.
    func getQueuedMessageCount() async -> Int {
        let context = PersistenceController.shared.container.newBackgroundContext()
        return await context.perform {
            guard context.persistentStoreCoordinator != nil else { return 0 }
            let fetchRequest: NSFetchRequest<Message> = Message.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "deliveryStatusRaw == %d", DeliveryStatus.queued.rawValue)
            return (try? context.count(for: fetchRequest)) ?? 0
        }
    }
}
