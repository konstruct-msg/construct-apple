import Foundation
import CoreData
import os.log

/// Service responsible for message persistence in Core Data
@MainActor
class MessagePersistenceService {
    
    // MARK: - Save Message
    
    /// Save or update a message in Core Data
    /// - Parameters:
    ///   - message: Chat message from network
    ///   - decryptedContent: Decrypted message text
    ///   - isSentByMe: Whether current user sent this message
    ///   - status: Delivery status
    ///   - chatId: The chat it belongs to
    ///   - replyTo: Optional reply-to message
    ///   - localThumbnails: Optional thumbnails for media messages
    ///   - suiteId: Crypto suite ID
    ///   - context: Managed object context
    /// - Returns: True if this was a new message, false if updating existing
    func saveMessage(
        _ message: ChatMessage,
        decryptedContent: String,
        isSentByMe: Bool,
        status: DeliveryStatus,
        chatId: String,
        replyTo: TranscriptRow? = nil,
        replyToContentOverride: String? = nil,
        localThumbnails: [Data] = [],
        suiteId: UInt16,
        /// Optional CTM1 / binary local payload (E1). When nil, stores UTF-8 of `decryptedContent`.
        storagePayload: Data? = nil,
        in context: NSManagedObjectContext
    ) throws -> Bool {
        Log.debug("Saving message \(message.id), isSentByMe: \(isSentByMe), status: \(status)", category: "MessagePersistence")

        let payload = storagePayload ?? Data(decryptedContent.utf8)
        let previewText: String = {
            if storagePayload != nil {
                return LocalMessagePayload.decode(payload).previewHint
            }
            return decryptedContent
        }()
        
        let messageTimestamp = Date(timeIntervalSince1970: TimeInterval(message.timestamp))
        let store = LocalRepositories.messages

        if let existing = try store.message(message.id) {
            Log.debug("Updating existing message \(message.id)", category: "MessagePersistence")
            try store.setDeliveryStatus(existing.id, status)
            if let serverOrderKey = message.serverOrderKey {
                try store.setOrderKey(existing.id, serverOrderKey)
            }
            // Recover a previously undecryptable message: if the sender re-sent the same
            // message (same UUID) after a session heal, update the content so the "unavailable"
            // bubble is replaced with the actual text — a body read late, not an edit.
            if existing.body.isEmpty, !payload.isEmpty,
               try store.setBody(existing.id, body: payload, searchText: LocalMessagePayload.decode(payload).plainText) {
                Log.info("Recovered undecryptable message \(message.id.prefix(8))… — content now available", category: "MessagePersistence")
                // Update chat preview if this was the last message showing "unavailable"
                Self.advancePreview(ofChat: chatId, text: previewText, at: existing.timestamp)
            }
            return false
        }

        Log.debug("Creating new message \(message.id)", category: "MessagePersistence")
        let id = message.id.lowercased()
        // Store all thumbnails indexed for multi-image messages
        for (index, thumb) in localThumbnails.enumerated() {
            MediaManager.shared.storeThumbnail(thumb, for: message.id, at: index)
        }
        let record = MessageRecord(
            id: id, chatId: chatId, fromUserId: message.from, toUserId: message.to,
            isSentByMe: isSentByMe, timestamp: messageTimestamp,
            orderKey: message.serverOrderKey
                ?? (isSentByMe
                    ? ServerMessageOrder.pending(localMessageId: id)
                    : ServerMessageOrder.local(timestamp: messageTimestamp, messageId: id)),
            body: payload, contentType: .regular, deliveryStatus: status, retryCount: 0,
            suiteId: suiteId, isEdited: false, editedAt: nil,
            replyToMessageId: replyTo?.id.lowercased(),
            replyQuote: replyTo.flatMap {
                ReplyPreviewPayload.projecting(
                    originalContent: $0.legacyBody, textOverride: replyToContentOverride
                )?.storedContent
            },
            transcript: nil, transcriptLanguage: nil, transcriptGeneratedAt: nil
        )
        // Saved synchronously, through the repository: a deferred write risks the message being
        // lost if the app is backgrounded or killed before it runs.
        let isNewMessage = try store.insert(record, searchText: LocalMessagePayload.decode(payload).plainText)
        if isNewMessage {
            if !isSentByMe { Self.incrementUnread(ofChat: chatId) }
            Self.advancePreview(ofChat: chatId, text: previewText, at: messageTimestamp)
        }

        Log.debug("Message saved to Core Data", category: "MessagePersistence")
        return isNewMessage
    }

    /// Attach the server's authoritative order to an optimistic local row after SendMessage ACK.
    /// The display timestamp remains untouched: it is the time the user composed the message.
    func updateServerOrder(
        messageId: String,
        serverOrderKey: String,
        in context: NSManagedObjectContext
    ) {
        do {
            if try LocalRepositories.messages.message(messageId) == nil {
                Log.error("Cannot find message to update server order: \(messageId)", category: "MessagePersistence")
                return
            }
            try LocalRepositories.messages.setOrderKey(messageId, serverOrderKey)
        } catch {
            Log.error("Server order of \(messageId.prefix(8))… not written: \(error)", category: "MessagePersistence")
        }
    }
    
    // MARK: - Update Message Status
    
    /// Update delivery status of an existing message
    /// - Parameters:
    ///   - messageId: Message ID
    ///   - status: New delivery status
    ///   - context: Managed object context
    func updateMessageContent(
        messageId: String,
        newContent: String,
        isEdited: Bool,
        editedAt: Date,
        storagePayload: Data? = nil,
        in context: NSManagedObjectContext
    ) {
        let body = storagePayload ?? Data(newContent.utf8)
        do {
            // `isEdited` is always true at the callers; an edit marks the message, as the crate's does.
            if try !LocalRepositories.messages.edit(
                messageId, body: body, searchText: LocalMessagePayload.decode(body).plainText, editedAt: editedAt
            ) {
                Log.error("Cannot find message to update content: \(messageId)", category: "MessagePersistence")
            }
        } catch {
            Log.error("Content of \(messageId.prefix(8))… not written: \(error)", category: "MessagePersistence")
        }
    }

    // MARK: - Upload Placeholder

    /// One cell of an upload placeholder: the locally generated thumbnail (when the source
    /// produced one) and the source MIME type, so a video renders as a video cell rather
    /// than an empty photo cell while it uploads.
    struct UploadPlaceholderItem {
        let thumbnail: Data?
        let mimeType: String?
        /// So a video note's placeholder is already the note bubble, not a photo-sized cell.
        let presentation: MediaPresentation?
        /// A file being sent: its row in the placeholder, by name and size, as the file bubble
        /// will show it. Until 2026-10-06 a set of files was one empty photo cell (TODO 10).
        let fileName: String?
        let fileSize: Int?

        init(thumbnail: Data? = nil, mimeType: String? = nil, presentation: MediaPresentation? = nil) {
            self.thumbnail = thumbnail
            self.mimeType = mimeType
            self.presentation = presentation
            self.fileName = nil
            self.fileSize = nil
        }

        init(fileName: String, fileSize: Int?) {
            self.thumbnail = nil
            self.mimeType = nil
            self.presentation = nil
            self.fileName = fileName
            self.fileSize = fileSize
        }
    }

    /// The sentinel a placeholder row stores: every entry flagged `_placeholder`, so
    /// `parseMediaContent` returns it, `MediaMessageView` draws the upload state, and
    /// `UploadPlaceholderBody.isSentinel` keeps the retry path from sending it as text.
    nonisolated static func placeholderBody(caption: String, items: [UploadPlaceholderItem]) -> String {
        let entries = (items.isEmpty ? [UploadPlaceholderItem()] : items).map { item -> String in
            if let name = item.fileName {
                let size = item.fileSize.map { #","size":\#($0)"# } ?? ""
                return #"{"_placeholder":true,"fileName":\#(Self.jsonStringLiteral(name))\#(size)}"#
            }
            guard let mime = item.mimeType, !mime.isEmpty else { return #"{"_placeholder":true}"# }
            let presentation = item.presentation.map {
                #","\#(MediaPresentation.jsonKey)":\#(Self.jsonStringLiteral($0.rawValue))"#
            } ?? ""
            return #"{"_placeholder":true,"mediaType":\#(Self.jsonStringLiteral(mime))\#(presentation)}"#
        }
        return """
        {"type":"media","caption":\(Self.jsonStringLiteral(caption)),"media":[\(entries.joined(separator: ","))]}
        """
    }

    /// Save a "pending upload" placeholder that shows the local thumbnail while media is
    /// being uploaded to the server.  The placeholder carries a special sentinel JSON so
    /// `parseMediaContent` renders it as a media bubble (with local thumbnail) rather than
    /// a raw-text bubble.  Call `deleteMessage` on success and `updateMessageStatus(.failed)`
    /// on failure so the existing retry flow can kick in.
    ///
    /// - Parameter items: one entry per attachment being uploaded, so an album shows the
    ///   grid it will become instead of a single cell that then multiplies. Files pass one
    ///   `init(fileName:fileSize:)` item each.
    func savePlaceholderMessage(
        id: String,
        fromUserId: String,
        toUserId: String,
        caption: String,
        items: [UploadPlaceholderItem],
        replyTo: TranscriptRow?,
        replyToContentOverride: String? = nil,
        chatId: String,
        in context: NSManagedObjectContext
    ) {
        // The gallery (`ChatView.mediaMessages`) skips this row too, by the same flag.
        let placeholderJson = Self.placeholderBody(caption: caption, items: items)

        let now = Date()
        let rowId = id.lowercased()
        for (index, item) in items.enumerated() {
            if let thumb = item.thumbnail {
                MediaManager.shared.storeThumbnail(thumb, for: id, at: index)
            }
        }
        // `contentType` MUST stay `.regular`: `ChatMessageStore`'s FRC filters the transcript on
        // `contentTypeRaw == 0`, so a `.media` row is fetched by nothing and the bubble never
        // appears — the upload ran invisibly and the media only showed up once the real
        // (`.regular`) message replaced the placeholder. `MessageContentType.infer` deliberately
        // maps media payloads to `.regular` for the same reason.
        insertOwn(MessageRecord(
            id: rowId, chatId: chatId, fromUserId: fromUserId, toUserId: toUserId, isSentByMe: true,
            timestamp: now, orderKey: ServerMessageOrder.pending(localMessageId: rowId),
            body: Data(placeholderJson.utf8), contentType: .regular, deliveryStatus: .sending,
            retryCount: 0, suiteId: 0, isEdited: false, editedAt: nil,
            replyToMessageId: replyTo?.id.lowercased(),
            replyQuote: replyTo.flatMap {
                ReplyPreviewPayload.projecting(originalContent: $0.legacyBody, textOverride: replyToContentOverride)?.storedContent
            },
            transcript: nil, transcriptLanguage: nil, transcriptGeneratedAt: nil
        ))

        // Update chat metadata so the preview row shows something sensible.
        let preview = !caption.isEmpty ? caption
            : (items.first?.fileName.map { "📎 \($0)" } ?? "📷 " + NSLocalizedString("photo", comment: ""))
        Self.advancePreview(ofChat: chatId, text: preview, at: now)

        Log.debug("Saved upload placeholder \(id.prefix(8))…", category: "MessagePersistence")
    }

    /// Save a voice-upload placeholder so the voice UI appears immediately while upload is in progress.
    /// Uses `type: "voice"` JSON so `parseVoiceContent` routes it to `VoiceMessageBubbleView`
    /// instead of the generic `MediaMessageView` (which shows a broken-image error on failure).
    func saveVoicePlaceholderMessage(
        id: String,
        fromUserId: String,
        toUserId: String,
        duration: TimeInterval,
        waveform: [Float],
        chatId: String,
        in context: NSManagedObjectContext
    ) {
        let waveformJson = waveform.map { String(format: "%.4f", $0) }.joined(separator: ",")
        // `_uploading` is the flag `UploadPlaceholderBody.isSentinel` reads. A finished voice
        // message does not carry it, and must not: retry would then refuse the row.
        let placeholderJson = """
        {"type":"voice","mediaId":"","mediaUrl":"","mediaKey":"","mediaType":"audio/m4a","size":0,"duration":\(duration),"waveform":[\(waveformJson)],"hash":"","_uploading":true}
        """

        let now = Date()
        // `.regular` for the same reason as the media placeholder above — the transcript FRC only
        // fetches `contentTypeRaw == 0`. The id keeps its case: the upload tracks it as given.
        insertOwn(MessageRecord(
            id: id, chatId: chatId, fromUserId: fromUserId, toUserId: toUserId, isSentByMe: true,
            timestamp: now, orderKey: ServerMessageOrder.pending(localMessageId: id),
            body: Data(placeholderJson.utf8), contentType: .regular, deliveryStatus: .sending,
            retryCount: 0, suiteId: 0, isEdited: false, editedAt: nil, replyToMessageId: nil,
            replyQuote: nil, transcript: nil, transcriptLanguage: nil, transcriptGeneratedAt: nil
        ))

        Self.advancePreview(ofChat: chatId, text: NSLocalizedString("voice_message", comment: ""), at: now)

        Log.debug("Saved voice upload placeholder \(id.prefix(8))…", category: "MessagePersistence")
    }

    /// Delete a placeholder (or any) message by ID — used after upload succeeds so the
    /// real sent message can take its place.
    /// Delete a message by ID.
    ///
    /// Pass `autoSave: false` when you intend to batch this with another
    /// Core Data write (e.g., deleting a placeholder then inserting the real
    /// message).  The caller is then responsible for calling
    /// `context.saveAndLog()` once all changes are staged.
    func deleteMessage(id: String, in context: NSManagedObjectContext, autoSave: Bool = true) {
        // Through the repository, which saves at once: `autoSave: false` no longer batches.
        do {
            try LocalRepositories.messages.delete([id])
            Log.debug("Deleted placeholder \(id.prefix(8))…", category: "MessagePersistence")
        } catch {
            Log.error("Placeholder \(id.prefix(8))… not deleted: \(error)", category: "MessagePersistence")
        }
    }

    /// A message of our own, written whole through the repository; a failure is logged, as the
    /// placeholders' `saveAndLog` did.
    private func insertOwn(_ record: MessageRecord) {
        do {
            try LocalRepositories.messages.insert(record, searchText: nil)
        } catch {
            Log.error("Message \(record.id.prefix(8))… not saved: \(error)", category: "MessagePersistence")
        }
    }

    // MARK: - Update Status

    func updateMessageStatus(
        messageId: String,
        status: DeliveryStatus,
        in context: NSManagedObjectContext
    ) {
        do {
            guard try LocalRepositories.messages.message(messageId) != nil else {
                Log.error("Message not found: \(messageId)", category: "MessagePersistence")
                return
            }
            // The store refuses a status weaker than the one held (`DeliveryStatusTransition`).
            try LocalRepositories.messages.setDeliveryStatus(messageId, status)
        } catch {
            Log.error("Status of \(messageId.prefix(8))… not written: \(error)", category: "MessagePersistence")
        }

        // Keep MessageQueueManager's in-memory timers in sync so we don't
        // incorrectly time out messages based on Core Data timestamps.
        switch status {
        case .sending:
            MessageQueueManager.shared.markMessageAsSending(messageId)
        case .sent, .delivered:
            MessageQueueManager.shared.markMessageAsSent(messageId)
        case .queued:
            MessageQueueManager.shared.markMessageAsFailed(messageId)
        case .failed:
            MessageQueueManager.shared.markMessageAsFailed(messageId)
        }
        
        Log.debug("Updated message status to \(status) for \(messageId)", category: "MessagePersistence")
    }
    
    // MARK: - Chat Metadata

    // The chat's list row — preview and unread count — is written through `ChatStore`, after the
    // message's own save, and never in the message's context (LOCAL_STORE_MIGRATION_PLAN, chats
    // B2). The crate writes them the same way: `insert_message`, then `advance_chat_preview`, two
    // statements. The message path names a chat by its id; linking a row to its chat is
    // `CoreDataMessageStore`'s.

    /// Move the list's preview to this message, unless the one shown is newer.
    nonisolated static func advancePreview(ofChat chatId: String, text: String, at time: Date) {
        do {
            if try !LocalRepositories.chats.advancePreview(chatId, text: Chat.formatPreviewText(text), time: time) {
                Log.debug("Preview of \(chatId.prefix(8))… not advanced — a newer one is shown", category: "MessagePersistence")
            }
        } catch {
            Log.error("Preview of \(chatId.prefix(8))… not written: \(error)", category: "MessagePersistence")
        }
    }

    /// Set the preview whatever it was — recomputed from the messages left; nil when none is.
    nonisolated static func setPreview(ofChat chatId: String, text: String?, at time: Date?) {
        do {
            try LocalRepositories.chats.setPreview(chatId, text: text.map(Chat.formatPreviewText), time: time)
        } catch {
            Log.error("Preview of \(chatId.prefix(8))… not set: \(error)", category: "MessagePersistence")
        }
    }

    nonisolated static func incrementUnread(ofChat chatId: String) {
        do {
            try LocalRepositories.chats.incrementUnread(chatId)
        } catch {
            Log.error("Unread of \(chatId.prefix(8))… not counted: \(error)", category: "MessagePersistence")
        }
    }

    /// Align the chat's list line with its newest message a list may show — a regular message
    /// that is not a leaked control or service row — or clear it when there is none. Returns
    /// whether it wrote. The self-heal for a preview a writer missed or a stamp frozen in the
    /// future, and the first preview of a chat a history import wrote messages into.
    @discardableResult
    nonisolated static func reconcilePreview(
        ofChat chat: ChatRecord, store: any MessageStore = LocalRepositories.messages
    ) -> Bool {
        let newest = newestListed(inChat: chat.id, store: store)
        guard let newest else {
            guard chat.lastMessageText != nil || chat.lastMessageTime != nil else { return false }
            setPreview(ofChat: chat.id, text: nil, at: nil)
            return true
        }
        let preview = newest.payload.previewHint
        if let current = chat.lastMessageTime,
           abs(current.timeIntervalSince(newest.timestamp)) < 0.5,
           (chat.lastMessageText ?? "") == Chat.formatPreviewText(preview) {
            return false
        }
        setPreview(ofChat: chat.id, text: preview, at: newest.timestamp)
        Log.debug("Preview reconciled for \(chat.id.prefix(8))… ts=\(newest.timestamp)", category: "Chat")
        return true
    }

    /// Pages back from the newest until a row qualifies; a run of leaked rows at the tip does not
    /// pin the line.
    private nonisolated static func newestListed(inChat chatId: String, store: any MessageStore) -> MessageRecord? {
        let page = 8
        var before: (orderKey: String, id: String)?
        while let rows = try? store.messages(inChat: chatId, before: before, limit: page), !rows.isEmpty {
            if let shown = rows.last(where: { row in
                guard row.contentType == .regular, !row.contentType.isEphemeral else { return false }
                let text = row.payload.displayString
                return !MessageContentType.isControlPayload(text) && !MessageContentType.isLegacyDeliveryReceipt(text)
            }) {
                return shown
            }
            guard rows.count == page, let oldest = rows.first else { return nil }
            before = (oldest.orderKey, oldest.id)
        }
        return nil
    }

    // MARK: - Message Deletion
    
    /// Delete messages by id, through the repository, then recompute the chat's preview from what
    /// is left. The view context drops the rows when it merges the repository's save.
    func deleteMessages(withIds messageIds: Set<String>, chatId: String, in context: NSManagedObjectContext) throws {
        guard !messageIds.isEmpty else { return }
        Log.debug("Deleting \(messageIds.count) messages", category: "MessagePersistenceService")
        try LocalRepositories.messages.delete(messageIds)
        Log.info("\(messageIds.count) message(s) deleted", category: "MessagePersistenceService")
        try updateChatMetadataAfterDeletion(chatId: chatId, in: context)
    }
    
    // MARK: - Chat Metadata Update
    /// Update chat metadata after message deletion
    /// - Parameters:
    ///   - chatId: The chat to update
    ///   - context: Managed object context
    func updateChatMetadataAfterDeletion(
        chatId: String,
        in context: NSManagedObjectContext
    ) throws {
        // Recomputed from what survives — this is the one case that may move backwards.
        let newest = try LocalRepositories.messages.messages(inChat: chatId, before: nil, limit: 1).last
        let text = newest.map { LocalMessagePayload.decode($0.body).previewHint }
        Self.setPreview(ofChat: chatId, text: text, at: newest?.timestamp)
        Log.debug("Updated chat metadata after deletion", category: "MessagePersistence")
    }

    // MARK: - Private Helpers

    /// A JSON string literal for `s`, by the JSON encoder — every control character escaped. The
    /// hand-rolled version escaped four characters; a file name with a tab broke the placeholder's
    /// JSON, and a body that does not parse is drawn as text.
    nonisolated private static func jsonStringLiteral(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: s, options: .fragmentsAllowed),
              let literal = String(data: data, encoding: .utf8) else { return "\"\"" }
        return literal
    }
}
