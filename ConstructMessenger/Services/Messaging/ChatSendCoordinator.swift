//
//  ChatSendCoordinator.swift
//  Construct Messenger
//

import Foundation
import CoreData
import GRPCCore
import SwiftProtobuf
#if canImport(UIKit)
import UIKit
#endif

struct QueuedMessage {
    let text: String
    let attachments: [MediaAttachment]
    let replyTo: Message?
    let timestamp: Date

    init(text: String, attachments: [MediaAttachment] = [], replyTo: Message? = nil) {
        self.text = text
        self.attachments = attachments
        self.replyTo = replyTo
        self.timestamp = Date()
    }
}

@MainActor
final class ChatSendCoordinator {

    // MARK: - Dependencies

    private let chat: Chat
    private let viewContext: NSManagedObjectContext
    private let sessionManager: ChatSessionManager
    private weak var viewModel: ChatViewModel?

    private let persistenceService = MessagePersistenceService()
    private let mediaUploadManager = MediaUploadManager()
    private let retryManager = MessageRetryManager.shared

    // MARK: - Send state

    private var queuedMessages: [QueuedMessage] = []

    private struct MediaUploadPayload {
        let attachments: [MediaAttachment]
        let fileURLs: [URL]
        let caption: String
        let replyTo: Message?
    }
    private var pendingMediaUploads: [String: MediaUploadPayload] = [:]

    // MARK: - Init

    init(
        chat: Chat,
        viewContext: NSManagedObjectContext,
        sessionManager: ChatSessionManager
    ) {
        self.chat = chat
        self.viewContext = viewContext
        self.sessionManager = sessionManager
    }

    func setViewModel(_ vm: ChatViewModel) {
        self.viewModel = vm

        sessionManager.onSessionReady = { [weak self] userId in
            Task { [weak self] in
                await self?.sendQueuedMessages(userId: userId)
            }
        }
        sessionManager.onSessionFailed = { [weak self] _, reason in
            self?.failQueuedMessages(reason: reason)
        }
    }

    // MARK: - Public send entry

    func sendMessage(
        text: String,
        attachments: [MediaAttachment] = [],
        fileURLs: [URL] = [],
        replyTo: Message? = nil,
        replyToContentOverride: String? = nil
    ) {
        Log.info("sendMessage called with \(attachments.count) images, \(fileURLs.count) files", category: "ChatViewModel")
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if attachments.isEmpty && fileURLs.isEmpty && text.count > MessageSizeLimits.maxTextCharacters {
            let chunks = MessageValidator.splitIntoChunks(text)
            Log.info("Long paste split into \(chunks.count) messages", category: "ChatViewModel")
            for (index, chunk) in chunks.enumerated() {
                sendMessage(
                    text: chunk,
                    replyTo: index == 0 ? replyTo : nil,
                    replyToContentOverride: index == 0 ? replyToContentOverride : nil
                )
            }
            return
        }
        guard let recipientId = chat.otherUser?.id else {
            Log.error("No recipient ID", category: "ChatViewModel")
            return
        }
        guard let currentUserId = AuthSessionManager.shared.currentUserId else {
            Log.error("No current user ID", category: "ChatViewModel")
            return
        }
        guard recipientId != currentUserId else {
            ErrorRouter.shared.report(.validation(.selfSend))
            Log.debug("Blocked attempt to send message to self", category: "ChatViewModel")
            return
        }

        let hasSession = CryptoManager.shared.hasSession(for: recipientId)

        if !hasSession {
            let queued = QueuedMessage(text: text, attachments: attachments, replyTo: replyTo)
            queuedMessages.append(queued)
            viewModel?.isInitializingSession = true
            Log.info("SESSION_STATE[queue_message]: userId=\(recipientId.prefix(8))..., queueSize=\(queuedMessages.count)", category: "SessionInit")
            Task { [weak self] in
                await self?.sessionManager.initializeSessionProactively(userId: recipientId)
            }
            return
        }

        if SessionConfirmationTracker.shared.isPending(recipientId) {
            let bufferedId = UUID().uuidString
            let stub = ChatMessage(
                id: bufferedId,
                from: currentUserId,
                to: recipientId,
                messageType: nil,
                ephemeralPublicKey: Data(),
                messageNumber: 0,
                content: Data(),
                suiteId: 0,
                timestamp: UInt64(Date().timeIntervalSince1970)
            )
            saveMessage(stub, decryptedContent: text, isSentByMe: true, status: .queued,
                        replyTo: replyTo, replyToContentOverride: replyToContentOverride, suiteId: 0)
            Log.info("SESSION_CONFIRM[buffered]: message \(bufferedId.prefix(8))… queued — waiting for RESPONDER session_ready from \(recipientId.prefix(8))…", category: "SessionConfirm")
            return
        }

        Log.info("Sending to: \(recipientId), from: \(currentUserId)", category: "ChatViewModel")
        Task { @MainActor [weak self] in
            guard let self else { return }
            let ok = await SessionActivityTracker.shared.preflight(for: recipientId)
            guard ok else {
                let queued = QueuedMessage(text: text, attachments: attachments, replyTo: replyTo)
                self.queuedMessages.append(queued)
                self.viewModel?.isInitializingSession = true
                Log.info("Pre-flight failed — message queued, triggering proactive reinit for \(recipientId.prefix(8))…", category: "ChatViewModel")
                await self.sessionManager.initializeSessionProactively(userId: recipientId)
                return
            }
            self.dispatchSend(
                text: text,
                attachments: attachments,
                fileURLs: fileURLs,
                replyTo: replyTo,
                replyToContentOverride: replyToContentOverride
            )
        }
    }

    // MARK: - Dispatch

    private func dispatchSend(
        text: String,
        attachments: [MediaAttachment],
        fileURLs: [URL],
        replyTo: Message?,
        replyToContentOverride: String?
    ) {
        if !fileURLs.isEmpty {
            do {
                try MessageValidator.validateMessage(text: text, fileURLs: fileURLs)
            } catch let error as MessageValidationError {
                ErrorRouter.shared.report(error)
                return
            } catch {
                ErrorRouter.shared.report(.unknown(error.userFacingMessage))
                return
            }
            sendFileMessage(fileURLs: fileURLs, caption: text, replyTo: replyTo, replyToContentOverride: replyToContentOverride)
            return
        }
        if !attachments.isEmpty {
            do {
                try MessageValidator.validateCaption(text)
            } catch let error as MessageValidationError {
                ErrorRouter.shared.report(error)
                return
            } catch {
                ErrorRouter.shared.report(.unknown(error.userFacingMessage))
                return
            }
            sendMediaMessage(attachments: attachments, caption: text, replyTo: replyTo, replyToContentOverride: replyToContentOverride)
            return
        }
        do {
            try MessageValidator.validateText(text)
        } catch let error as MessageValidationError {
            ErrorRouter.shared.report(error)
            return
        } catch {
            ErrorRouter.shared.report(.unknown(error.userFacingMessage))
            return
        }
        sendTextMessage(text: text, replyTo: replyTo, replyToContentOverride: replyToContentOverride)
    }

    // MARK: - Queue handling

    func sendQueuedMessages() {
        guard let recipientId = chat.otherUser?.id,
              let currentUserId = AuthSessionManager.shared.currentUserId else { return }
        retryManager.sendQueuedMessages(
            for: chat,
            recipientId: recipientId,
            currentUserId: currentUserId,
            context: viewContext
        )
    }

    private func sendQueuedMessages(userId: String) async {
        Log.info("SESSION_STATE[send_queued]: userId=\(userId.prefix(8))..., queueSize=\(queuedMessages.count)", category: "SessionInit")
        let messagesToSend = queuedMessages
        queuedMessages.removeAll()
        for queued in messagesToSend {
            Log.info("Sending queued message: \"\(queued.text.prefix(30))\"", category: "ChatViewModel")
            sendMessage(text: queued.text, attachments: queued.attachments, replyTo: queued.replyTo)
        }
    }

    private func failQueuedMessages(reason: String) {
        Log.error("Failing \(queuedMessages.count) queued messages: \(reason)", category: "ChatViewModel")
        guard !queuedMessages.isEmpty else { return }
        guard let currentUserId = AuthSessionManager.shared.currentUserId,
              let recipientId = chat.otherUser?.id else {
            queuedMessages.removeAll()
            return
        }
        for queued in queuedMessages {
            let msg = Message(context: viewContext)
            msg.id = UUID().uuidString
            msg.fromUserId = currentUserId
            msg.toUserId = recipientId
            msg.contentType = .regular
            msg.timestamp = queued.timestamp
            msg.deliveryStatus = .failed
            msg.isSentByMe = true
            msg.chat = chat
            msg.applyStoredEncryption(plaintext: queued.text, contactId: recipientId)
        }
        viewContext.saveAndLog()
        queuedMessages.removeAll()
    }

    // MARK: - Text message

    /// Build a QuotedMessage for a reply, or nil. Shared by text and media sends.
    func buildQuoted(replyTo: Message?, replyToContentOverride: String?) -> Shared_Proto_Messaging_V1_QuotedMessage? {
        guard let reply = replyTo else { return nil }
        var quoted = Shared_Proto_Messaging_V1_QuotedMessage()
        quoted.messageID = reply.id
        quoted.textPreview = replyToContentOverride ?? reply.displayText
        return quoted
    }

    /// - Parameter wirePlaintext: pre-serialized `MessageContent` for the wire (used by
    ///   media to send the binary `.mediaAlbum` proto). When nil, a `.text` MessageContent
    ///   is built from `text`. `text` is always what's stored locally (`decryptedContent`)
    ///   and synced to own devices — for media that's the local JSON.
    func sendTextMessage(
        text: String,
        replyTo: Message?,
        replyToContentOverride: String? = nil,
        localThumbnails: [Data] = [],
        wirePlaintext: Data? = nil
    ) {
        guard let recipientId = chat.otherUser?.id,
              let currentUserId = AuthSessionManager.shared.currentUserId else {
            viewModel?.isSending = false
            return
        }
        viewModel?.isSending = true
        do {
            let messageId = UUID().uuidString.lowercased()
            let plaintextData: Data
            if let wirePlaintext {
                plaintextData = wirePlaintext
            } else {
                var textMsg = Shared_Proto_Messaging_V1_TextMessage()
                textMsg.text = text
                if let quoted = buildQuoted(replyTo: replyTo, replyToContentOverride: replyToContentOverride) {
                    textMsg.quoted = quoted
                }
                var content = Shared_Proto_Messaging_V1_MessageContent()
                content.text = textMsg
                guard let d = try? content.serializedData(), !d.isEmpty else {
                    Log.error("Failed to serialize MessageContent proto", category: "ChatViewModel")
                    viewModel?.isSending = false
                    return
                }
                plaintextData = d
            }
            guard !plaintextData.isEmpty else {
                Log.error("Empty wire plaintext", category: "ChatViewModel")
                viewModel?.isSending = false
                return
            }
            let plan = ChunkedMessageSender.shared.buildPlan(
                plaintext: plaintextData,
                messageId: UUID(uuidString: messageId) ?? UUID()
            )
            guard !plan.payloads.isEmpty else {
                Log.error("Message too large to send", category: "ChatViewModel")
                viewModel?.isSending = false
                ErrorRouter.shared.report(.validation(.textTooLarge(currentSize: text.count, maxSize: MessageSizeLimits.maxTextCharacters)))
                return
            }
            let message = ChatMessage(
                id: messageId,
                from: currentUserId,
                to: recipientId,
                messageType: nil,
                ephemeralPublicKey: Data(),
                messageNumber: 0,
                content: Data(),
                suiteId: 0,
                timestamp: UInt64(Date().timeIntervalSince1970),
                oneTimePreKeyId: 0
            )
            Log.debug("Sending message with ID: \(messageId)", category: "ChatViewModel")
            saveMessage(message, decryptedContent: text, isSentByMe: true, status: .sending,
                        replyTo: replyTo, replyToContentOverride: replyToContentOverride,
                        localThumbnails: localThumbnails, suiteId: 0)

            Log.info("Sending message via gRPC (direct core path): \(messageId)", category: "ChatViewModel")
            Task { [weak self] in
                guard let self else { return }
                let jitterMs = TrafficProtectionService.shared.recommendedSendDelay(isHighPriority: true)
                if jitterMs > 0 {
                    try? await Task.sleep(for: .milliseconds(Int(jitterMs)))
                }
                do {
                    let recipientIdentityKey: Data? = await {
                        guard StealthPolicy.shared.shouldUseSealedSender() else { return nil }
                        if let k = self.sessionManager.cachedIdentityKey { return k }
                        return await self.fetchRecipientIdentityKeyForEdit(recipientId: recipientId, context: self.viewContext)
                    }()
                    let aggregated = try await OutboundMessagePipeline.shared.sendChunks(
                        plan: plan,
                        baseMessageId: messageId,
                        senderId: currentUserId,
                        recipientId: recipientId,
                        conversationId: ConversationId.direct(myUserId: currentUserId, theirUserId: recipientId),
                        timestamp: message.timestamp,
                        recipientIdentityKey: recipientIdentityKey
                    )
                    TrafficProtectionService.shared.recordRealMessageSent()
                    if let myDeviceId = AuthSessionManager.shared.currentDeviceId, !myDeviceId.isEmpty {
                        Task { [weak self] in
                            _ = self
                            await MultiDeviceSendCoordinator.shared.sendSenderSync(
                                plaintext: Data(text.utf8),
                                messageId: messageId,
                                originalRecipientUserId: recipientId,
                                senderUserId: currentUserId,
                                senderDeviceId: myDeviceId,
                                conversationId: ConversationId.direct(
                                    myUserId: currentUserId,
                                    theirUserId: recipientId
                                ),
                                timestamp: message.timestamp
                            )
                        }
                    }
                    let deliveryStatus: DeliveryStatus
                    let ecStr = aggregated.errorCode.isEmpty ? "" : " errorCode=\(aggregated.errorCode)"
                    let raStr = aggregated.retryAfterMs > 0 ? " retryAfterMs=\(aggregated.retryAfterMs)" : ""
                    let traceTag = aggregated.attemptId.isEmpty ? "" : " attemptId=\(aggregated.attemptId.prefix(8))"
                    switch aggregated.status.lowercased() {
                    case "delivered": deliveryStatus = .delivered
                    case "queued":    deliveryStatus = .queued
                    case "sent", "success": deliveryStatus = .sent
                    case "blocked":
                        deliveryStatus = .failed
                        self.viewModel?.blockedByRecipient = true
                        Log.error("Message blocked by recipient — suppressing retry for \(messageId)\(traceTag)", category: "ChatViewModel")
                    case "failed":
                        if aggregated.errorCode == "encryptionFailed" {
                            deliveryStatus = .failed
                            OutgoingWirePayloadStore.shared.remove(baseMessageId: messageId)
                            Log.error("encryptionFailed from server — triggering END_SESSION for \(self.chat.otherUser?.id.prefix(8) ?? "?")\(traceTag)", category: "ChatViewModel")
                            if let peerId = self.chat.otherUser?.id {
                                Task {
                                    try? await SessionLifecycleController.shared.sendEndSession(
                                        to: peerId,
                                        reason: "server_encryption_rejected"
                                    )
                                }
                            }
                        } else if aggregated.retryable {
                            deliveryStatus = .queued
                            Log.error("Server rejected message \(messageId): retryable=true\(ecStr)\(raStr)\(traceTag) — queued for retry", category: "ChatViewModel")
                        } else {
                            deliveryStatus = .failed
                            OutgoingWirePayloadStore.shared.remove(baseMessageId: messageId)
                            Log.error("Server rejected message \(messageId): retryable=false\(ecStr)\(traceTag)", category: "ChatViewModel")
                        }
                    default:
                        deliveryStatus = .sent
                        Log.info("Unknown server status: \(aggregated.status), using .sent\(traceTag)", category: "ChatViewModel")
                    }
                    Log.info("Updating message status from sending → \(deliveryStatus) for \(messageId)\(traceTag)", category: "ChatViewModel")
                    self.updateMessageStatus(messageId: messageId, status: deliveryStatus)
                    if deliveryStatus == .sent || deliveryStatus == .delivered {
                        OutgoingWirePayloadStore.shared.remove(baseMessageId: messageId)
                    }
                    Log.info("Message sent via gRPC: \(messageId) status=\(aggregated.status)\(ecStr)\(traceTag)", category: "ChatViewModel")
                    SessionActivityTracker.shared.recordActivity(for: recipientId)
                    self.viewModel?.isSending = false
                } catch {
                    let isRetryableTransportFailure: Bool = {
                        if let rpcError = error as? RPCError {
                            let code = String(describing: rpcError.code).lowercased()
                            return code == "deadlineexceeded" || code == "unavailable" || code == "cancelled"
                        }
                        if let networkError = error as? NetworkError {
                            switch networkError {
                            case .connectionFailed, .disconnected, .notConnected: return true
                            default: return false
                            }
                        }
                        return false
                    }()
                    if let networkError = error as? NetworkError,
                       case .serverError(let message, let responseBody) = networkError {
                        Log.error("Failed to send message via gRPC: \(message)\nResponse: \(responseBody ?? "empty")", category: "ChatViewModel")
                    } else if let rpcError = error as? RPCError {
                        Log.error("SendMessage gRPC error: code=\(rpcError.code), message=\(rpcError.message)", category: "ChatViewModel")
                    } else {
                        Log.error("Failed to send message: \(error)", category: "ChatViewModel")
                    }
                    if isRetryableTransportFailure {
                        Log.info("Transport failure — queueing \(messageId.prefix(8))… for safe retry", category: "ChatViewModel")
                        self.updateMessageStatus(messageId: messageId, status: .queued)
                    } else {
                        self.updateMessageStatus(messageId: messageId, status: .failed)
                        OutgoingWirePayloadStore.shared.remove(baseMessageId: messageId)
                        ErrorRouter.shared.report(error, recovery: { [weak self] in
                            self?.sendTextMessage(text: text, replyTo: replyTo, replyToContentOverride: replyToContentOverride, localThumbnails: localThumbnails)
                        })
                    }
                    self.viewModel?.isSending = false
                }
            }
        } catch {
            if case CryptoManagerError.coreNotInitialized = error {
                Log.error("coreNotInitialized in sendTextMessage — OrchestratorCore missing, not retrying", category: "ChatViewModel")
                ErrorRouter.shared.report(error)
                viewModel?.isSending = false
                return
            }
            Log.debug("Encryption failed, session was deleted. Reinitializing...", category: "ChatViewModel")
            guard let toUserId = chat.otherUser?.id else {
                ErrorRouter.shared.report(error)
                Log.error("Failed to encrypt message: \(error.localizedDescription)", category: "ChatViewModel")
                viewModel?.isSending = false
                return
            }
            viewModel?.isSessionReady = false
            let queued = QueuedMessage(text: text, attachments: [], replyTo: replyTo)
            queuedMessages.append(queued)
            viewModel?.isInitializingSession = true
            viewModel?.isSending = false
            Log.info("Message queued for retry after session reinitialization", category: "ChatViewModel")
            Task { [weak self] in await self?.sessionManager.initializeSessionProactively(userId: toUserId) }
        }
    }

    // MARK: - Media messages

    func sendMediaMessage(
        attachments: [MediaAttachment],
        caption: String,
        replyTo: Message?,
        replyToContentOverride: String? = nil
    ) {
        guard let recipientId = chat.otherUser?.id,
              let currentUserId = AuthSessionManager.shared.currentUserId else {
            Log.error("No recipient/user ID for media message", category: "ChatViewModel")
            ErrorRouter.shared.report(.unknown("Cannot send media: no recipient"))
            return
        }
        let placeholderId = UUID().uuidString
        let thumbnail: Data? = attachments.first?.displayImage.flatMap { MediaManager.shared.generateThumbnail(from: $0) }
        persistenceService.savePlaceholderMessage(
            id: placeholderId,
            fromUserId: currentUserId,
            toUserId: recipientId,
            caption: caption,
            thumbnail: thumbnail,
            replyTo: replyTo,
            replyToContentOverride: replyToContentOverride,
            chat: chat,
            in: viewContext
        )
        pendingMediaUploads[placeholderId] = MediaUploadPayload(
            attachments: attachments, fileURLs: [], caption: caption, replyTo: replyTo)
        viewModel?.isSending = true
        Log.info("Uploading \(attachments.count) image(s) (placeholder \(placeholderId.prefix(8))…)", category: "ChatViewModel")
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await mediaUploadManager.uploadMediaAndBuildContent(
                    attachments: attachments,
                    caption: caption,
                    recipientId: recipientId
                )
                pendingMediaUploads.removeValue(forKey: placeholderId)
                persistenceService.deleteMessage(id: placeholderId, in: viewContext, autoSave: false)
                // Binary wire: send the album as a protobuf `.mediaAlbum` MessageContent.
                // Local display stays the JSON (`result.messageContent`) so the view layer
                // and multi-device sync are unchanged.
                let wireContent = MediaWireCodec.albumContent(
                    mediaList: result.mediaList,
                    caption: caption,
                    quoted: buildQuoted(replyTo: replyTo, replyToContentOverride: replyToContentOverride)
                )
                let wirePlaintext = try? wireContent.serializedData()
                sendTextMessage(
                    text: result.messageContent,
                    replyTo: replyTo,
                    replyToContentOverride: replyToContentOverride,
                    localThumbnails: result.thumbnails,
                    wirePlaintext: wirePlaintext
                )
            } catch {
                Log.error("Media upload failed: \(error.localizedDescription) | raw: \(error)", category: "ChatViewModel")
                updateMessageStatus(messageId: placeholderId, status: .failed)
                ErrorRouter.shared.report(
                    AppError.mediaUploadFailed(error.localizedDescription),
                    recovery: { [weak self] in self?.retryMessage_byId(placeholderId) }
                )
                viewModel?.isSending = false
            }
        }
    }

    func sendVoiceMessage(url: URL, duration: TimeInterval, waveform: [Float]) {
        guard let recipientId = chat.otherUser?.id,
              let currentUserId = AuthSessionManager.shared.currentUserId else {
            Log.error("No recipient/user ID for voice message", category: "ChatViewModel")
            return
        }
        let placeholderId = UUID().uuidString
        persistenceService.saveVoicePlaceholderMessage(
            id: placeholderId,
            fromUserId: currentUserId,
            toUserId: recipientId,
            duration: duration,
            waveform: waveform,
            chat: chat,
            in: viewContext
        )
        viewModel?.isSending = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let voiceContent = try await MediaManager.shared.uploadAudio(url, duration: duration, waveform: waveform)
                let jsonData = try JSONEncoder().encode(voiceContent)
                guard let json = String(data: jsonData, encoding: .utf8) else {
                    throw MediaUploadError.uploadFailed("JSON encode failed")
                }
                try? FileManager.default.removeItem(at: url)
                persistenceService.deleteMessage(id: placeholderId, in: viewContext, autoSave: false)
                sendTextMessage(text: json, replyTo: nil)
            } catch {
                Log.error("Voice upload failed: \(error.localizedDescription)", category: "ChatViewModel")
                updateMessageStatus(messageId: placeholderId, status: .failed)
                ErrorRouter.shared.report(AppError.mediaUploadFailed(error.localizedDescription))
                viewModel?.isSending = false
            }
        }
    }

    private func sendFileMessage(
        fileURLs: [URL],
        caption: String,
        replyTo: Message?,
        replyToContentOverride: String? = nil
    ) {
        guard let recipientId = chat.otherUser?.id,
              let currentUserId = AuthSessionManager.shared.currentUserId else {
            viewModel?.isSending = false
            return
        }
        let placeholderId = UUID().uuidString
        persistenceService.savePlaceholderMessage(
            id: placeholderId,
            fromUserId: currentUserId,
            toUserId: recipientId,
            caption: caption.isEmpty ? (fileURLs.first?.lastPathComponent ?? "File") : caption,
            thumbnail: nil,
            replyTo: replyTo,
            replyToContentOverride: replyToContentOverride,
            chat: chat,
            in: viewContext
        )
        pendingMediaUploads[placeholderId] = MediaUploadPayload(
            attachments: [], fileURLs: fileURLs, caption: caption, replyTo: replyTo)
        viewModel?.isSending = true
        Log.info("Uploading \(fileURLs.count) file(s) (placeholder \(placeholderId.prefix(8))…)", category: "ChatViewModel")
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await mediaUploadManager.uploadFilesAndBuildContent(
                    urls: fileURLs,
                    caption: caption
                )
                pendingMediaUploads.removeValue(forKey: placeholderId)
                persistenceService.deleteMessage(id: placeholderId, in: viewContext, autoSave: false)
                sendTextMessage(text: result.messageContent, replyTo: replyTo, replyToContentOverride: replyToContentOverride)
            } catch {
                Log.error("File upload failed: \(error.localizedDescription)", category: "ChatViewModel")
                updateMessageStatus(messageId: placeholderId, status: .failed)
                ErrorRouter.shared.report(
                    AppError.mediaUploadFailed(error.localizedDescription),
                    recovery: { [weak self] in self?.retryMessage_byId(placeholderId) }
                )
                viewModel?.isSending = false
            }
        }
    }

    // MARK: - Edit

    func editMessage(_ message: Message, newText: String, editingBinding: @escaping () -> Void) {
        guard let recipientId = chat.otherUser?.id,
              let currentUserId = AuthSessionManager.shared.currentUserId else { return }
        let conversationId = ConversationId.direct(myUserId: currentUserId, theirUserId: recipientId)
        // For a media message, editing the caption must rebuild the album (binary wire +
        // local JSON) — sending plain text would replace the descriptor and destroy the media.
        // Read displayText here (current actor) before hopping onto the Task.
        let mediaEdit = MediaWireCodec.editedCaption(localJSON: message.displayText, newCaption: newText)
        Task { [weak self] in
            guard let self else { return }
            do {
                let localContent: String
                if let mediaEdit {
                    localContent = mediaEdit.localJSON
                } else {
                    localContent = newText
                }
                // Use modern edit (MessageContent.edit) so it goes through the normal send path
                // and can use stealth when enabled.
                var editMsg = Shared_Proto_Messaging_V1_EditMessage()
                editMsg.targetMessageID = message.id
                var textMsg = Shared_Proto_Messaging_V1_TextMessage()
                textMsg.text = newText
                editMsg.newText = textMsg
                var content = Shared_Proto_Messaging_V1_MessageContent()
                content.edit = editMsg
                guard let editPayload = try? content.serializedData() else {
                    ErrorRouter.shared.report(.unknown("Failed to serialize edit"))
                    return
                }

                let editActionId = UUID().uuidString.lowercased()
                let plan = ChunkedMessageSender.shared.buildPlan(plaintext: editPayload, messageId: UUID(uuidString: editActionId) ?? UUID())

                let recipientIdentityKey: Data? = StealthPolicy.shared.shouldUseSealedSender()
                    ? await fetchRecipientIdentityKeyForEdit(recipientId: recipientId, context: viewContext)
                    : nil

                _ = try await OutboundMessagePipeline.shared.sendChunks(
                    plan: plan,
                    baseMessageId: editActionId,
                    senderId: currentUserId,
                    recipientId: recipientId,
                    conversationId: conversationId,
                    timestamp: UInt64(Date().timeIntervalSince1970),
                    recipientIdentityKey: recipientIdentityKey
                )

                let editedDate = Date()
                persistenceService.updateMessageContent(
                    messageId: message.id,
                    newContent: localContent,
                    isEdited: true,
                    editedAt: editedDate,
                    in: viewContext
                )
                editingBinding()
            } catch {
                ErrorRouter.shared.report(.unknown(String(format: NSLocalizedString("edit_message_failed", comment: ""), error.localizedDescription)))
            }
        }
    }

    private func fetchRecipientIdentityKeyForEdit(recipientId: String, context: NSManagedObjectContext) async -> Data? {
        let req = User.fetchRequest()
        req.predicate = NSPredicate(format: "id == %@", recipientId)
        req.fetchLimit = 1
        do {
            return try context.fetch(req).first?.knownIdentityKey
        } catch {
            Log.error("Failed to load identity key for stealth edit to \(recipientId.prefix(8))…: \(error)", category: "ChatSendCoordinator")
            return nil
        }
    }

    // MARK: - Retry

    func retryMessage(_ message: Message) {
        if let payload = pendingMediaUploads[message.id] {
            pendingMediaUploads.removeValue(forKey: message.id)
            persistenceService.deleteMessage(id: message.id, in: viewContext)
            if !payload.attachments.isEmpty {
                sendMediaMessage(attachments: payload.attachments, caption: payload.caption, replyTo: payload.replyTo)
            } else {
                sendFileMessage(fileURLs: payload.fileURLs, caption: payload.caption, replyTo: payload.replyTo)
            }
            return
        }
        guard let recipientId = chat.otherUser?.id else {
            Log.error("No recipient ID for retry", category: "ChatViewModel")
            return
        }
        retryManager.retryMessage(
            message,
            recipientId: recipientId,
            context: viewContext,
            onError: { [weak self] error in
                guard let self else { return }
                if error == "payload_expired" {
                    let text = message.displayText
                    guard !text.isEmpty else { return }
                    Log.info("Retry: payload expired — sending '\(text.prefix(20))…' as fresh message", category: "ChatViewModel")
                    // Remove the orphaned failed placeholder before re-sending under a new
                    // message ID — otherwise the original lingers and the chat shows two
                    // bubbles for one delivered message (mirrors the media-retry path above).
                    self.persistenceService.deleteMessage(id: message.id, in: self.viewContext)
                    self.sendTextMessage(text: text, replyTo: nil)
                } else {
                    ErrorRouter.shared.report(.unknown(error))
                }
            }
        )
    }

    private func retryMessage_byId(_ messageId: String) {
        let fetchRequest = Message.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", messageId)
        fetchRequest.fetchLimit = 1
        guard let msg = try? viewContext.fetch(fetchRequest).first else { return }
        retryMessage(msg)
    }

    // MARK: - Persistence helpers

    private func saveMessage(
        _ message: ChatMessage,
        decryptedContent: String,
        isSentByMe: Bool,
        status: DeliveryStatus,
        replyTo: Message? = nil,
        replyToContentOverride: String? = nil,
        localThumbnails: [Data] = [],
        suiteId: UInt16
    ) {
        do {
            _ = try persistenceService.saveMessage(
                message,
                decryptedContent: decryptedContent,
                isSentByMe: isSentByMe,
                status: status,
                chat: chat,
                replyTo: replyTo,
                replyToContentOverride: replyToContentOverride,
                localThumbnails: localThumbnails,
                suiteId: suiteId,
                in: viewContext
            )
        } catch {
            Log.error("Failed to save message: \(error.localizedDescription)", category: "ChatViewModel")
        }
    }

    private func updateMessageStatus(messageId: String, status: DeliveryStatus) {
        persistenceService.updateMessageStatus(messageId: messageId, status: status, in: viewContext)
    }
}
