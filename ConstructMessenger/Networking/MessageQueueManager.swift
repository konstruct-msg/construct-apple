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
            setupSubscribers()
            startPeriodicCheck()
            Log.info("📦 MessageQueueManager initialized", category: "MessageQueue")
        }
    }
    
    // MARK: - Setup
    
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
                Log.info("📡 Network available - checking for queued messages", category: "MessageQueue")
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
        Log.info("⏰ Started periodic message queue check", category: "MessageQueue")
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
            Log.info("⚠️ Core Data store coordinator unavailable, skipping stuck message check", category: "MessageQueue")
            return
        }
        
        let timeout = APIConstants.messageSendTimeout
        let now = Date()
        let timedOutIds = pendingSends.compactMap { (messageId, timestamp) -> String? in
            now.timeIntervalSince(timestamp) > timeout ? messageId : nil
        }
        if !timedOutIds.isEmpty {
            handleTimedOutMessages(timedOutIds, context: context)
        }
        
        // Check Core Data for messages stuck in .sending state
        context.perform {
            let fetchRequest: NSFetchRequest<Message> = Message.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "deliveryStatusRaw == %d", DeliveryStatus.sending.rawValue)
            
            if let stuckMessages = try? context.fetch(fetchRequest) {
                let now = Date()
                for message in stuckMessages {
                    // If message has been in sending state for more than timeout, mark as queued
                    let timeSinceSent = now.timeIntervalSince(message.timestamp)
                    if timeSinceSent > timeout {
                        Log.info("⏱️ Message \(message.id) stuck in sending state for \(Int(timeSinceSent))s, marking as queued", category: "MessageQueue")
                        message.deliveryStatus = .queued
                        do {
                            try context.save()
                        } catch {
                            Log.error("⚠️ MessageQueueManager: failed to save stuck-message status: \(error)", category: "MessageQueue")
                        }
                    }
                }
            }
        }
    }
    
    private func handleTimedOutMessages(_ messageIds: [String], context: NSManagedObjectContext) {
        context.perform {
            for messageId in messageIds {
                let fetchRequest: NSFetchRequest<Message> = Message.fetchRequest()
                fetchRequest.predicate = NSPredicate(format: "id == %@", messageId)
                
                if let message = try? context.fetch(fetchRequest).first {
                    if message.deliveryStatus == .sending {
                        Log.info("⏱️ Message \(messageId) timed out, marking as queued", category: "MessageQueue")
                        message.deliveryStatus = .queued
                        Task { @MainActor [weak self, messageId] in self?.markMessageAsFailed(messageId) }
                    }
                }
            }
            
            do {
                try context.save()
            } catch {
                Log.error("⚠️ MessageQueueManager: failed to save timed-out message statuses: \(error)", category: "MessageQueue")
            }
            // Try to resend if network is available (gRPC reconnects automatically)
            Task { @MainActor [weak self] in
                if self?.networkManager.isReachable == true { self?.processQueuedMessages() }
            }
        }
    }
    
    // MARK: - Process Queued Messages
    
    /// Process all queued messages (called when network is restored)
    func processQueuedMessages() {
        guard networkManager.isReachable else {
            Log.debug("⏸️ Cannot process queued messages - network not reachable", category: "MessageQueue")
            return
        }
        
        let context = PersistenceController.shared.container.viewContext
        guard context.persistentStoreCoordinator != nil else {
            Log.info("⚠️ Core Data store coordinator unavailable, cannot process queued messages", category: "MessageQueue")
            return
        }
        
        context.perform {
            let fetchRequest: NSFetchRequest<Message> = Message.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "deliveryStatusRaw == %d", DeliveryStatus.queued.rawValue)
            fetchRequest.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
            fetchRequest.fetchLimit = 10 // Process in batches
            
            guard let queuedMessages = try? context.fetch(fetchRequest), !queuedMessages.isEmpty else {
                return
            }
            
            Log.info("📤 Processing \(queuedMessages.count) queued messages", category: "MessageQueue")
            
            // Post notification for ViewModels to handle resending
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .processQueuedMessages,
                    object: nil,
                    userInfo: ["messageIds": queuedMessages.map { $0.id }]
                )
            }
        }
    }
    
    /// Get count of queued messages
    func getQueuedMessageCount() -> Int {
        let context = PersistenceController.shared.container.viewContext
        guard context.persistentStoreCoordinator != nil else {
            return 0
        }
        
        let fetchRequest: NSFetchRequest<Message> = Message.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "deliveryStatusRaw == %d", DeliveryStatus.queued.rawValue)
        
        return (try? context.count(for: fetchRequest)) ?? 0
    }
}

// MARK: - Notifications
extension Notification.Name {
    static let processQueuedMessages = Notification.Name("processQueuedMessages")
}
