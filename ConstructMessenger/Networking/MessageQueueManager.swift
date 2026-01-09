//
//  MessageQueueManager.swift
//  Construct Messenger
//
//  Manages message queue for offline/online scenarios
//

import Foundation
import CoreData
import Combine
import os.log

/// Manages message queue and automatic retry logic for offline scenarios
class MessageQueueManager: ObservableObject {
    static let shared = MessageQueueManager()
    
    private let wsManager = WebSocketManager.shared
    private let networkManager = NetworkReachabilityManager.shared
    private var cancellables = Set<AnyCancellable>()
    private var checkTimer: Timer?
    
    // Track messages being sent to detect timeouts
    private var pendingSends: [String: Date] = [:] // messageId -> sendTimestamp
    private let pendingSendsQueue = DispatchQueue(label: "MessageQueueManager.pendingSends")
    
    private init() {
        setupSubscribers()
        startPeriodicCheck()
    }
    
    deinit {
        stopPeriodicCheck()
    }
    
    // MARK: - Setup
    
    private func setupSubscribers() {
        // Monitor network reachability
        networkManager.reachabilityPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isReachable in
                if isReachable {
                    Log.info("📡 Network available - checking for queued messages", category: "MessageQueue")
                    self?.processQueuedMessages()
                }
            }
            .store(in: &cancellables)
        
        // Monitor WebSocket connection
        wsManager.$isConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isConnected in
                if isConnected {
                    Log.info("🔌 WebSocket connected - processing queued messages", category: "MessageQueue")
                    self?.processQueuedMessages()
                }
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Message Tracking
    
    /// Mark a message as being sent (for timeout detection)
    func markMessageAsSending(_ messageId: String) {
        pendingSendsQueue.async { [weak self] in
            self?.pendingSends[messageId] = Date()
        }
    }
    
    /// Mark a message as successfully sent (remove from pending)
    func markMessageAsSent(_ messageId: String) {
        pendingSendsQueue.async { [weak self] in
            self?.pendingSends.removeValue(forKey: messageId)
        }
    }
    
    /// Mark a message as failed (remove from pending)
    func markMessageAsFailed(_ messageId: String) {
        pendingSendsQueue.async { [weak self] in
            self?.pendingSends.removeValue(forKey: messageId)
        }
    }
    
    // MARK: - Periodic Check
    
    private func startPeriodicCheck() {
        // Check every 5 seconds for stuck messages
        checkTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.checkForStuckMessages()
        }
        Log.info("⏰ Started periodic message queue check", category: "MessageQueue")
    }
    
    private func stopPeriodicCheck() {
        checkTimer?.invalidate()
        checkTimer = nil
    }
    
    /// Check for messages that have been stuck in sending state too long
    private func checkForStuckMessages() {
        guard let context = PersistenceController.shared.container.viewContext else { return }
        
        let timeout = APIConstants.messageSendTimeout
        
        // Check pending sends for timeouts
        pendingSendsQueue.async { [weak self] in
            guard let self = self else { return }
            let now = Date()
            let timedOutIds = self.pendingSends.compactMap { (messageId, timestamp) -> String? in
                if now.timeIntervalSince(timestamp) > timeout {
                    return messageId
                }
                return nil
            }
            
            if !timedOutIds.isEmpty {
                DispatchQueue.main.async {
                    self.handleTimedOutMessages(timedOutIds, context: context)
                }
            }
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
                        Log.warning("⏱️ Message \(message.id) stuck in sending state for \(Int(timeSinceSent))s, marking as queued", category: "MessageQueue")
                        message.deliveryStatus = .queued
                        // Remove from pending sends if present
                        self.markMessageAsFailed(message.id)
                        try? context.save()
                    }
                }
            }
            
            // Also check for messages in .sent state that might need retry (if no ACK received)
            // This handles cases where message was sent but ACK was lost
            let sentFetchRequest: NSFetchRequest<Message> = Message.fetchRequest()
            sentFetchRequest.predicate = NSPredicate(format: "deliveryStatusRaw == %d", DeliveryStatus.sent.rawValue)
            
            if let sentMessages = try? context.fetch(sentFetchRequest) {
                let now = Date()
                // Only check messages that are very old (more than 1 minute) - likely lost ACK
                let ackTimeout = APIConstants.messageAckTimeout * 4 // 4x timeout for sent messages
                for message in sentMessages {
                    let timeSinceSent = now.timeIntervalSince(message.timestamp)
                    if timeSinceSent > ackTimeout {
                        // This is likely a lost ACK, but we don't want to resend
                        // as the message might have been delivered. Just log it.
                        Log.debug("📨 Message \(message.id) in sent state for \(Int(timeSinceSent))s (likely delivered)", category: "MessageQueue")
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
                        Log.warning("⏱️ Message \(messageId) timed out, marking as queued", category: "MessageQueue")
                        message.deliveryStatus = .queued
                        self.markMessageAsFailed(messageId)
                    }
                }
            }
            
            try? context.save()
            
            // Try to resend if network is available
            if self.networkManager.isReachable && self.wsManager.isConnected {
                self.processQueuedMessages()
            }
        }
    }
    
    // MARK: - Process Queued Messages
    
    /// Process all queued messages (called when network/connection is restored)
    func processQueuedMessages() {
        guard networkManager.isReachable && wsManager.isConnected else {
            Log.debug("⏸️ Cannot process queued messages - network: \(networkManager.isReachable), ws: \(wsManager.isConnected)", category: "MessageQueue")
            return
        }
        
        guard let context = PersistenceController.shared.container.viewContext else { return }
        
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
        guard let context = PersistenceController.shared.container.viewContext else { return 0 }
        
        let fetchRequest: NSFetchRequest<Message> = Message.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "deliveryStatusRaw == %d", DeliveryStatus.queued.rawValue)
        
        return (try? context.count(for: fetchRequest)) ?? 0
    }
}

// MARK: - Notifications
extension Notification.Name {
    static let processQueuedMessages = Notification.Name("processQueuedMessages")
}
