//
//  ChatViewModel.swift
//  Construct Messenger
//

import Foundation
import CoreData

@MainActor
@Observable
class ChatViewModel {

    // MARK: - UI state

    /// The open transcript, oldest first, one observed entry a row — what a list renders from
    /// (`TranscriptWindow.entries`).
    var entries: [TranscriptEntry] { transcript.entries }
    /// The rows, read once: observes every entry, so never what a list renders from.
    var messages: [TranscriptRow] { transcript.rows }
    var isLoadingMore: Bool { transcript.isLoadingMore }
    var hasMoreMessages: Bool { transcript.hasMore }
    var editingMessage: TranscriptRow?
    /// Set by continuous voice playback to ask the view to scroll the now-playing
    /// message into view. The view scrolls on change, then resets it to nil.
    var voicePlaybackScrollTarget: String?
    var isSessionReady = false
    var isInitializingSession = false

    // MARK: - Core

    let conversation: Conversation

    // MARK: - Coordinators

    private let transcript: TranscriptWindow
    private let viewContext: NSManagedObjectContext
    private let sessionManager: ChatSessionManager
    private let sendCoordinator: ChatSendCoordinator

    // MARK: - Subscribers

    private let connectionStatusManager = ConnectionStatusManager.shared
    private var observationTasks: [Task<Void, Never>] = []

    // MARK: - Lifecycle state

    private let instanceID = UUID()
    private var isSetupCalled = false

    // MARK: - Init

    init(conversation: Conversation, context: NSManagedObjectContext) {
        self.conversation = conversation

        let transcript = TranscriptWindow(chatId: conversation.chatId)
        let manager = ChatSessionManager(peerId: conversation.peerId)
        let coordinator = ChatSendCoordinator(
            conversation: conversation,
            viewContext: context,
            sessionManager: manager
        )

        self.transcript = transcript
        self.viewContext = context
        self.sessionManager = manager
        self.sendCoordinator = coordinator
    }

    isolated deinit {
        observationTasks.forEach { $0.cancel() }
        InAppNotificationService.shared.unregisterActiveChat(ownerID: instanceID)
        Log.debug("ChatViewModel deinitialized", category: "ChatViewModel")
    }

    // MARK: - View lifecycle

    func onViewAppear() {
        if !isSetupCalled {
            isSetupCalled = true
            sessionManager.setViewModel(self)
            sendCoordinator.setViewModel(self)
            transcript.start()
            sessionManager.checkExistingSession()
            setupSubscribers()
            InAppNotificationService.shared.registerActiveChat(conversation.chatId, ownerID: instanceID)
            Log.debug("ChatViewModel initialized with viewContext", category: "ChatViewModel")
        }
        sessionManager.fetchRecipientPublicKey()
    }

    func onPreviewAppear() {
        guard !isSetupCalled else { return }
        isSetupCalled = true
        transcript.start()
        Log.debug("ChatViewModel preview initialized with sample messages", category: "ChatViewModel")
    }

    // MARK: - Connection subscribers

    private func setupSubscribers() {
        let connTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = self.connectionStatusManager.connectionStatus
                    } onChange: {
                        continuation.resume()
                    }
                }
                guard !Task.isCancelled else { break }
                if self.connectionStatusManager.connectionStatus == .connected {
                    Log.info("Network connected - processing queued messages", category: "ChatViewModel")
                    self.sendCoordinator.sendQueuedMessages()
                    if !self.isSessionReady {
                        Log.info("Network recovered — retrying session init", category: "ChatViewModel")
                        self.sessionManager.fetchRecipientPublicKey()
                    }
                }
            }
        }
        observationTasks.append(connTask)
    }

    // MARK: - Send

    func sendMessage(
        text: String,
        attachments: [MediaAttachment] = [],
        fileURLs: [URL] = [],
        replyTo: TranscriptRow? = nil,
        replyToContentOverride: String? = nil
    ) {
        sendCoordinator.sendMessage(
            text: text,
            attachments: attachments,
            fileURLs: fileURLs,
            replyTo: replyTo,
            replyToContentOverride: replyToContentOverride
        )
    }

    func sendVoiceMessage(url: URL, duration: TimeInterval, waveform: [Float]) {
        sendCoordinator.sendVoiceMessage(url: url, duration: duration, waveform: waveform)
    }

    /// Sends forwarded content here, as this chat's own messages (`ForwardItem`).
    func forward(_ items: [ForwardItem]) async -> [ChatSendCoordinator.ForwardFailure] {
        await sendCoordinator.forward(items)
    }

    func sendSticker(_ ref: StickerReference, replyTo: TranscriptRow? = nil) {
        sendCoordinator.sendSticker(ref, replyTo: replyTo)
    }

    func editMessage(_ message: TranscriptRow, newText: String) {
        sendCoordinator.editMessage(message, newText: newText) { [weak self] in
            self?.editingMessage = nil
        }
    }

    func sendReaction(_ message: TranscriptRow, emoji: String = ReactionReducer.likeEmoji) {
        sendCoordinator.sendReaction(message, emoji: emoji)
    }

    func retryMessage(_ message: TranscriptRow) {
        sendCoordinator.retryMessage(message)
    }

    // MARK: - Continuous voice playback

    /// AppStorage key for the "play voice messages continuously" toggle (default off).
    static let continuousVoicePlaybackKey = "continuousVoicePlayback"

    /// Called when a voice message finishes playing. When continuous playback is enabled,
    /// auto-advances to the **next** voice message in chronological order (older → newer).
    /// `messages` is sorted ascending (oldest first), so we scan forward from the finished
    /// message; if there is no later voice message, playback simply stops — it never loops
    /// back to the start of the chat.
    func playNextVoiceIfContinuous(after finishedMediaId: String) {
        guard UserDefaults.standard.bool(forKey: Self.continuousVoicePlaybackKey) else { return }
        guard let idx = messages.firstIndex(where: {
            parseVoiceContent(from: $0.legacyBody)?.mediaId == finishedMediaId
        }) else { return }

        // First voice message strictly after the one that just finished.
        var nextMessage: TranscriptRow?
        for message in messages[messages.index(after: idx)...] {
            if parseVoiceContent(from: message.legacyBody) != nil {
                nextMessage = message
                break
            }
        }
        guard let nextMessage,
              let next = parseVoiceContent(from: nextMessage.legacyBody) else { return }  // last voice → stop.

        // Follow playback: ask the view to scroll the now-playing message into view.
        voicePlaybackScrollTarget = nextMessage.id

        Task {
            do {
                let data = try await MediaManager.shared.downloadAndDecryptMedia(
                    mediaId: next.mediaId,
                    mediaUrl: next.mediaUrl,
                    mediaKey: next.mediaKey
                )
                AudioPlayerService.shared.togglePlay(mediaId: next.mediaId, data: data)
            } catch {
                Log.error("Continuous voice playback failed: \(error.localizedDescription)", category: "ChatViewModel")
            }
        }
    }

    // MARK: - Messages

    /// `trigger` says who asked; the view keeps `.indicatorAppeared` out of opening and of
    /// following the bottom (`ChatScrollManager.shouldLoadOlderHistory`), so the metric below is the
    /// residual gauge — it should tick only on a real near-top scroll or a short-window fill.
    func loadMoreMessages(trigger: LoadMoreTrigger = .user) {
        guard !isLoadingMore, hasMoreMessages else { return }
        if trigger == .indicatorAppeared {
            PerformanceMetrics.shared.record(.loadMoreUnprompted, label: String(messages.count))
        }
        transcript.loadMore()
    }

    func deleteMessage(_ message: TranscriptRow) {
        deleteMessages(withIds: [message.id])
    }

    func deleteMessages(withIds messageIds: Set<String>) {
        do {
            try MessagePersistenceService().deleteMessages(
                withIds: messageIds, chatId: conversation.chatId, in: viewContext
            )
        } catch {
            Log.error("Failed to delete messages: \(error)", category: "ChatViewModel")
        }
    }
}
