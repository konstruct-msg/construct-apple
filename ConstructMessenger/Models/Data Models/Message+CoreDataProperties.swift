//
//  Message+CoreDataProperties.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import Foundation
import CoreData

// MARK: - Message Content Type Enum

/// Identifies the semantic type of a persisted message.
/// Stored as `contentTypeRaw` (Int16) in Core Data.
///
/// System messages (sessionPing, sessionReady, sessionReset) are ephemeral —
/// they are never saved to Core Data. This enum is used for regular messages
/// and serves as the foundation for the decrypt-on-display migration (Phase 3).
enum MessageContentType: Int16 {
    /// Standard E2EE text or media message.
    case regular      = 0
    /// Profile-sharing JSON payload (ephemeral, not persisted).
    case profileShare = 1
    /// Media attachment message.
    case media        = 2
    /// Session ping control signal (ephemeral, not persisted).
    case sessionPing  = 10
    /// Session-ready handshake confirmation (ephemeral, not persisted).
    case sessionReady = 11
    /// END_SESSION / session reset signal (ephemeral, not persisted).
    case sessionReset = 12

    /// Returns `true` for control signals that must never be saved to Core Data.
    var isEphemeral: Bool {
        switch self {
        case .sessionPing, .sessionReady, .sessionReset, .profileShare: return true
        case .regular, .media: return false
        }
    }

    /// Infer the content type from a decrypted plaintext string.
    /// Used as a fallback for messages in the DB that predate `contentTypeRaw`.
    static func infer(from plaintext: String) -> MessageContentType {
        if plaintext.hasPrefix("__session_ping") { return .sessionPing }
        if plaintext.hasPrefix("__session_ready") || plaintext.hasPrefix("session_ready_") { return .sessionReady }
        if plaintext.hasPrefix("__END_SESSION")
            || plaintext.hasPrefix("__session_reset_init") || plaintext.hasPrefix("session_reset_init_")
            || plaintext.hasPrefix("__binary_init_") { return .sessionReset }
        return .regular
    }

    /// Single source of truth for "this decrypted plaintext is an internal control
    /// signal that must NEVER render as a chat bubble". Covers every handshake/session
    /// marker emitted by current and legacy clients (with or without `__` framing).
    ///
    /// Prefix-on-`decryptedContent` Core Data predicates cannot enforce this: messages
    /// are encrypted at rest (`decryptedContent == nil`), so filtering must run on the
    /// decrypted `displayText` in Swift. Keep this list aligned with the discard checks
    /// in `MessageRouter` and `SessionCoordinator`.
    static func isControlPayload(_ plaintext: String) -> Bool {
        plaintext.hasPrefix("__session_ping")
            || plaintext.hasPrefix("__session_ready")
            || plaintext.hasPrefix("session_ready_")
            || plaintext.hasPrefix("__session_reset_init")
            || plaintext.hasPrefix("session_reset_init_")
            || plaintext.hasPrefix("__binary_init_")
            || plaintext.hasPrefix("__END_SESSION")
    }
}

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
    @NSManaged public var encryptedContent: Data
    @NSManaged public var decryptedContent: String?
    @NSManaged public var contentKeyRef: String?
    @NSManaged public var contentTypeRaw: Int16
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

    // Voice message transcript (on-device STT via WhisperKit)
    @NSManaged public var transcriptText: String?
    @NSManaged public var transcriptLanguage: String?
    @NSManaged public var transcriptGeneratedAt: Date?

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

    var contentType: MessageContentType {
        get { MessageContentType(rawValue: contentTypeRaw) ?? .regular }
        set { contentTypeRaw = newValue.rawValue }
    }

    // Helper для проверки возможности retry
    var canRetry: Bool {
        return deliveryStatus == .failed && retryCount < FeatureFlags.maxMessageRetryAttempts
    }
}

extension Message: Identifiable {

}
