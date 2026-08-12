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
        infer(from: Data(plaintext.utf8))
    }

    /// Infer type from stored/decrypted payload bytes (CTM1 or legacy UTF-8).
    static func infer(from data: Data) -> MessageContentType {
        switch LocalMessagePayload.decode(data) {
        // Keep media/profile as `.regular` so ChatMessageStore FRC (`contentTypeRaw == 0`) still
        // shows them. `.media` / `.profileShare` exist for future typed filtering — not used yet.
        case .mediaAlbum, .profileBinary:
            return .regular
        case .messageContent:
            return .regular
        case .text(let plaintext):
            return inferLegacyControl(plaintext)
        case .legacyUTF8(let raw):
            // A raw (non-CTM1) body is the only shape a leaked binary control payload can take,
            // and `SessionControl` is not a string, so the prefix list below is blind to it. That
            // blindness is not hypothetical: while the type lived on the envelope the string list
            // was a backstop; once ping/ready moved into the frame, a control payload that slipped
            // past dispatch had nothing left to catch it and rendered as a bubble. Ask the bytes.
            if let control = SessionControlCodec.decode(raw) {
                switch control.op {
                case .ping:  return .sessionPing
                case .ready: return .sessionReady
                default:     return .sessionReset
                }
            }
            return inferLegacyControl(String(data: raw, encoding: .utf8) ?? "")
        }
    }

    private static func inferLegacyControl(_ plaintext: String) -> MessageContentType {
        if plaintext.hasPrefix("__session_ping") { return .sessionPing }
        if plaintext.hasPrefix("__session_ready") || plaintext.hasPrefix("session_ready_") { return .sessionReady }
        if plaintext.hasPrefix("__END_SESSION")
            || plaintext.hasPrefix("__session_reset_init") || plaintext.hasPrefix("session_reset_init_")
            || plaintext.hasPrefix("__binary_init_") { return .sessionReset }
        // Legacy media / voice / file JSON remain `.regular` for FRC (contentTypeRaw == 0).
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
            // Legacy leak: chunked profile shares once decoded to this placeholder string and were
            // persisted as text. The decode bug is fixed (they now render as profiles), but already-
            // leaked rows must stay hidden. Match with/without framing underscores defensively.
            || plaintext == "__PROFILE_BINARY__"
            || plaintext == "PROFILE_BINARY"
    }
}

// MARK: - Delivery Status Enum
/// Rendering lives in `MessageBubbleRegularView.deliveryStatusView` and the labels in
/// `DeliveryStatus.a11yLabel` (`Localizable.strings`, `msg_status_*`). This enum deliberately
/// carries no `icon`/`iconColor`/`displayName`: it had all three, none had a caller, and all
/// three disagreed with what the view actually drew — `.sending` was documented as
/// `checkmark.circle` while the bubble drew a plain `circle`, and `.queued` as `tray` while it
/// drew `arrow.clockwise`. Unreferenced display properties read like documentation and rot
/// silently, because nothing exercises them. One place decides how a status looks.
enum DeliveryStatus: Int16 {
    case sending = 0           // Отправляется (локально)
    case sent = 1              // Отправлено на сервер, подтверждение получено
    /// Peer confirmed receipt via E2E delivery receipt (content_type=14), NOT the
    /// stream-cursor `ReceiptStatus.delivered` which only means "stop server redelivery".
    case delivered = 2
    /// Not sent yet, and something will try again: a send that timed out
    /// (`MessageQueueManager`), a message buffered until the peer's session is established
    /// (`ChatSendCoordinator`, waiting for `session_ready`), a server rejection flagged
    /// retryable, or a send interrupted by the app being killed (reset on launch).
    ///
    /// NOT "the recipient is offline" — that is what the comment here used to say, and it is
    /// what got published on the website's FAQ before anyone checked the call sites.
    case queued = 3
    /// Rejected for a reason a retry will not fix; nothing happens automatically.
    case failed = 4

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

    /// The delivery status, with the one rule that keeps ~30 uncoordinated writers honest:
    /// a status that says nothing about arrival may not overwrite one that does. The rule lives
    /// in the setter on purpose — auditing every call site is exactly what failed before
    /// (see `DeliveryStatusTransition` for the build-585 incident). A refused write is logged,
    /// never silent.
    var deliveryStatus: DeliveryStatus {
        get { DeliveryStatus(rawValue: deliveryStatusRaw) ?? .sending }
        set {
            let current = deliveryStatus
            guard let resolved = DeliveryStatusTransition.resolve(current: current, proposed: newValue) else {
                Log.info(
                    "Delivery status \(current) → \(newValue) refused for \(id.prefix(8))… — " +
                    "\(newValue) knows nothing about arrival and \(current) does",
                    category: "MessagePersistence"
                )
                return
            }
            deliveryStatusRaw = resolved.rawValue
        }
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
