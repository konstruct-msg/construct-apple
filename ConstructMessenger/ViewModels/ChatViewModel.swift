//
//  ChatViewModel.swift
//  Construct Messenger
//

import Foundation
import CoreData
#if canImport(UIKit)
import UIKit
#endif

@MainActor
@Observable
class ChatViewModel {

    // MARK: - UI state

    var messages: [Message] = []
    var isSending = false
    var isLoadingMore = false
    var hasMoreMessages = true
    var editingMessage: Message?
    /// Set by continuous voice playback to ask the view to scroll the now-playing
    /// message into view. The view scrolls on change, then resets it to nil.
    var voicePlaybackScrollTarget: String?
    var blockedByRecipient = false
    var isSessionReady = false
    var isInitializingSession = false

    // MARK: - Core

    let chat: Chat

    // MARK: - Coordinators

    private let messageStore: ChatMessageStore
    private let sessionManager: ChatSessionManager
    private let sendCoordinator: ChatSendCoordinator

    // MARK: - Subscribers

    private let connectionStatusManager = ConnectionStatusManager.shared
    private var observationTasks: [Task<Void, Never>] = []

    // MARK: - Lifecycle state

    private let instanceID = UUID()
    private var isSetupCalled = false

    // MARK: - Init

    init(chat: Chat, context: NSManagedObjectContext) {
        self.chat = chat

        let store = ChatMessageStore(chat: chat, viewContext: context)
        let manager = ChatSessionManager(chat: chat)
        let coordinator = ChatSendCoordinator(
            chat: chat,
            viewContext: context,
            sessionManager: manager
        )

        self.messageStore = store
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
            messageStore.setViewModel(self)
            sessionManager.setViewModel(self)
            sendCoordinator.setViewModel(self)
            messageStore.setup()
            sessionManager.checkExistingSession()
            setupSubscribers()
            InAppNotificationService.shared.registerActiveChat(chat.id, ownerID: instanceID)
            Log.debug("ChatViewModel initialized with viewContext", category: "ChatViewModel")
        }
        sessionManager.fetchRecipientPublicKey()
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
        replyTo: Message? = nil,
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

    func editMessage(_ message: Message, newText: String) {
        sendCoordinator.editMessage(message, newText: newText) { [weak self] in
            self?.editingMessage = nil
        }
    }

    func retryMessage(_ message: Message) {
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
            parseVoiceContent(from: $0.displayText)?.mediaId == finishedMediaId
        }) else { return }

        // First voice message strictly after the one that just finished.
        var nextMessage: Message?
        for message in messages[messages.index(after: idx)...] {
            if parseVoiceContent(from: message.displayText) != nil {
                nextMessage = message
                break
            }
        }
        guard let nextMessage,
              let next = parseVoiceContent(from: nextMessage.displayText) else { return }  // last voice → stop.

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

    func loadMoreMessages() {
        messageStore.loadMoreMessages()
    }

    func deleteMessage(_ message: Message) {
        messageStore.deleteMessage(message)
    }

    func deleteMessages(withIds messageIds: Set<String>) {
        messageStore.deleteMessages(withIds: messageIds)
    }
}
