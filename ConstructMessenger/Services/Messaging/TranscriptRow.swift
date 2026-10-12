//
//  TranscriptRow.swift
//  Construct Messenger
//
//  One row of an open chat's transcript, as a value (local-store plan, lane C). It carries what a
//  row is — who, when, where in the order, its status — and no text: the body, the transcript and
//  the quote are read by id from `MessageDisplayCache` when a bubble shows them. A row held by the
//  screen therefore holds no message text, and leaving the app empties and zeroes that cache
//  (`UnsealedMemory`) as it did for the managed rows this replaces.
//

import Foundation

struct TranscriptRow: Equatable, Identifiable, Sendable, TranscriptGroupable {
    let id: String
    let chatId: String
    let fromUserId: String
    let toUserId: String
    let isSentByMe: Bool
    let timestamp: Date
    let orderKey: String
    let contentType: MessageContentType
    let deliveryStatus: DeliveryStatus
    let retryCount: Int16
    let suiteId: UInt16
    let isEdited: Bool
    let editedAt: Date?
    let replyToMessageId: String?
    let transcriptLanguage: String?
    let transcriptGeneratedAt: Date?
    /// Moves on every write the store reports for this row. A late body, an edit of the text or a
    /// transcript change no field above, and a bubble must still draw again — the row differs
    /// by this alone.
    let revision: Int

    /// `body`, `replyQuote` and `transcript` are left out on purpose: the text is read by id
    /// (see the file header).
    init(_ record: MessageRecord, revision: Int) {
        id = record.id
        chatId = record.chatId
        fromUserId = record.fromUserId
        toUserId = record.toUserId
        isSentByMe = record.isSentByMe
        timestamp = record.timestamp
        orderKey = record.orderKey
        contentType = record.contentType
        deliveryStatus = record.deliveryStatus
        retryCount = record.retryCount
        suiteId = record.suiteId
        isEdited = record.isEdited
        editedAt = record.editedAt
        replyToMessageId = record.replyToMessageId
        transcriptLanguage = record.transcriptLanguage
        transcriptGeneratedAt = record.transcriptGeneratedAt
        self.revision = revision
    }

    var peerId: String { isSentByMe ? toUserId : fromUserId }
    var safeTimestamp: Date { timestamp }

    var canRetry: Bool {
        deliveryStatus == .failed && retryCount < FeatureFlags.maxMessageRetryAttempts
    }

    // MARK: - Text, read when shown

    private var payload: LocalMessagePayload { MessageDisplayCache.shared.payload(messageId: id) }

    /// The body as the bubble parsers read it — `Message.legacyBody`, which says why it is not
    /// for a person to read.
    var legacyBody: String { payload.displayString }
    /// The words in the message, or a media message's caption; what is shown, copied and quoted.
    var readableText: String { payload.readableText }
    /// The text of a text message, or nil — the only thing that may be sent again as text.
    var plainText: String? { payload.plainText }
    /// What the chat list shows for this row.
    var previewText: String { payload.previewHint }
    var stickerReference: StickerReference? { payload.stickerReference }
    /// The message has a body to show — a row stored undecryptable has none until it is read late.
    var hasDecryptedContent: Bool { !MessageDisplayCache.shared.payloadData(messageId: id).isEmpty }

    var transcript: String? { MessageDisplayCache.shared.text(.transcript, messageId: id) }
    /// The reply's quote in its stored form (`ReplyPreviewPayload`), or nil for no reply.
    var replyQuote: String? { MessageDisplayCache.shared.text(.replyQuote, messageId: id) }

    // MARK: - Never a bubble

    /// A session-control signal that leaked into the transcript — `Message.isControlArtifact`.
    var isControlArtifact: Bool {
        contentType.isEphemeral || MessageContentType.isControlPayload(legacyBody)
    }

    /// A delivery receipt persisted as text by an old build — `Message.isServiceArtifact`.
    var isServiceArtifact: Bool {
        MessageContentType.isLegacyDeliveryReceipt(legacyBody)
    }
}
