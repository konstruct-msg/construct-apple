//
//  Message+CoreDataProperties.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import Foundation
import CoreData

// MARK: - Delivery Status Enum
enum DeliveryStatus: Int16 {
    case sending = 0      // Отправляется (локально)
    case sent = 1         // Отправлено на сервер
    case delivered = 2    // Доставлено получателю (online)
    case queued = 3       // В очереди (получатель offline)
    case failed = 4       // Ошибка отправки

    var displayName: String {
        switch self {
        case .sending: return "Sending"
        case .sent: return "Sent to server"  // На сервере, получатель может быть оффлайн
        case .delivered: return "Delivered"  // Доставлено получателю
        case .queued: return "Queued locally"  // В локальной очереди
        case .failed: return "Failed"
        }
    }

    var icon: String {
        switch self {
        case .sending: return "clock"
        case .sent: return "checkmark"  // Один чекмарк - на сервере
        case .delivered: return "checkmark.circle.fill"  // Два чекмарка в UI - доставлено получателю
        case .queued: return "tray"
        case .failed: return "exclamationmark.circle.fill"
        }
    }
}

extension Message {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<Message> {
        return NSFetchRequest<Message>(entityName: "Message")
    }

    @NSManaged public var id: String
    @NSManaged public var fromUserId: String
    @NSManaged public var toUserId: String
    @NSManaged public var encryptedContent: String
    @NSManaged public var decryptedContent: String?
    @NSManaged public var timestamp: Date
    @NSManaged public var isSentByMe: Bool
    @NSManaged public var deliveryStatusRaw: Int16
    @NSManaged public var retryCount: Int16
    @NSManaged public var replyToMessageId: String?
    @NSManaged public var replyToContent: String?
    @NSManaged public var chat: Chat?

    // Computed property для удобства
    var deliveryStatus: DeliveryStatus {
        get { DeliveryStatus(rawValue: deliveryStatusRaw) ?? .sending }
        set { deliveryStatusRaw = newValue.rawValue }
    }

    // Helper для проверки возможности retry
    var canRetry: Bool {
        return deliveryStatus == .failed && retryCount < FeatureFlags.maxMessageRetryAttempts
    }
}

extension Message: Identifiable {

}
