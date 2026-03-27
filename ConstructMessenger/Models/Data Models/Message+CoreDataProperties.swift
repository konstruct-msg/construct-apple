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
    case sending = 0           // Отправляется (локально)
    case sent = 1              // Отправлено на сервер, подтверждение получено
    case delivered = 2         // Доставлено получателю (HMAC-SHA256 ACK received)
    case queued = 3            // В очереди (получатель offline)
    case failed = 4            // Ошибка отправки

    var displayName: String {
        switch self {
        case .sending: return "Sending"
        case .sent: return "Sent to server"           // Сервер подтвердил получение
        case .delivered: return "Delivered"           // Получатель подтвердил доставку (через HMAC-SHA256)
        case .queued: return "Queued locally"         // В локальной очереди
        case .failed: return "Failed"
        }
    }

    var icon: String {
        switch self {
        case .sending: return "checkmark.circle"           // Серый пустой круг с галочкой
        case .sent: return "checkmark.circle.fill"         // Серый заполненный круг с галочкой
        case .delivered: return "checkmark.circle.fill"    // Зелёный заполненный (в UI)
        case .queued: return "tray"
        case .failed: return "exclamationmark.circle.fill"
        }
    }
    
    var iconColor: String {
        switch self {
        case .sending: return "gray"
        case .sent: return "gray"
        case .delivered: return "green"
        case .queued: return "orange"
        case .failed: return "red"
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
    @NSManaged public var suiteId: UInt16
    @NSManaged public var timestamp: Date
    @NSManaged public var isSentByMe: Bool
    @NSManaged public var deliveryStatusRaw: Int16
    @NSManaged public var retryCount: Int16
    @NSManaged public var replyToMessageId: String?
    @NSManaged public var replyToContent: String?
    @NSManaged public var isEdited: Bool
    @NSManaged public var editedAt: Date?
    @NSManaged public var chat: Chat?

    /// Safe accessor for `timestamp` — guards against nil NSDate bridging crash
    /// which can occur when optimistically-inserted messages are not yet fully persisted.
    var safeTimestamp: Date {
        (value(forKey: "timestamp") as? Date) ?? Date()
    }

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
