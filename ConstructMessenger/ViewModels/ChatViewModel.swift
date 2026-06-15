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

    // MARK: - Connection + engine subscribers

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

        let contactId = chat.otherUser?.id ?? ""
        guard !contactId.isEmpty else { return }
        let engineSessionTask = Task { [weak self] in
            let notifications = NotificationCenter.default.notifications(named: .engineSessionEstablished)
            for await notification in notifications {
                guard !Task.isCancelled, let self else { return }
                guard let peerId = notification.userInfo?["contactId"] as? String,
                      peerId == contactId else { continue }
                self.isSessionReady = true
                Log.info("Engine session established for \(peerId.prefix(8))…", category: "ChatViewModel")
            }
        }
        observationTasks.append(engineSessionTask)
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
