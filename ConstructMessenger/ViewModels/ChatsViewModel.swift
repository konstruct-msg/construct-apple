//
//  ChatsViewModel.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import Foundation
import CoreData
#if canImport(UIKit)
import UIKit
#endif

@Observable
@MainActor
class ChatsViewModel {

    // MARK: - UI state

    var chatToOpen: String?
    var selectedTab: Int = 0
    var showNewChat: Bool = false
    var sidebarSearchFocused: Bool = false
    var totalUnreadCount: Int = 0
    var pendingDroppedImage: PlatformImage? = nil
    var pendingDroppedFileURL: URL? = nil

    // MARK: - Core dependencies

    private let streamManager: MessageStreamManager
    private let chatManagementService = ChatManagementService()
    private let streamLifecycle: StreamLifecycleCoordinator

    /// Observer for `.contactRequestAccepted` — see init for rationale.
    private var contactAcceptedObserver: NSObjectProtocol?

    // MARK: - Setup state

    private var viewContext: NSManagedObjectContext?
    private var didPerformFirstContextSetup = false

    // Persistent lastMessageId (survives app restart)
    private var lastMessageId: String? {
        didSet {
            if let id = lastMessageId {
                UserDefaults.standard.set(id, forKey: "construct.lastMessageId")
                Log.debug("Saved lastMessageId: \(id)", category: "ChatsViewModel")
            } else {
                UserDefaults.standard.removeObject(forKey: "construct.lastMessageId")
            }
        }
    }

    // MARK: - Init

    init() {
        let sm = MessageStreamManager.shared
        let controller = SessionLifecycleController.shared
        let lifecycle = StreamLifecycleCoordinator(streamManager: sm, sessionCoordinator: controller.coordinator)

        self.streamManager = sm
        self.streamLifecycle = lifecycle

        self.lastMessageId = UserDefaults.standard.string(forKey: "construct.lastMessageId")
        if let restored = lastMessageId {
            Log.info("Restored lastMessageId from UserDefaults: \(restored)", category: "ChatsViewModel")
        }

        controller.configure(streamManager: sm)

        controller.onEphemeralSubscriptionNeeded = { [weak lifecycle] userId in
            lifecycle?.addEphemeralSubscription(for: userId)
        }

        lifecycle.start()

        // When a contact request is accepted (search → request → accept), a new
        // contact appears but the message stream is still subscribed to the old
        // contact set captured at connect time, so the server delivers none of
        // the new contact's messages and no crypto session is prewarmed. The QR
        // path avoids this because `startChat` calls forceReconnect; the
        // contact-request path did not. Rebuild the subscription set (and prewarm)
        // on acceptance from either side. Posted by ContactRequestService
        // (sender reconcile) and ContactRequestsViewModel.accept (responder).
        contactAcceptedObserver = NotificationCenter.default.addObserver(
            forName: .contactRequestAccepted, object: nil, queue: nil
        ) { [weak lifecycle] _ in
            Task { @MainActor in lifecycle?.forceReconnect() }
        }
    }

    isolated deinit {
        if let obs = contactAcceptedObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        streamLifecycle.stop()
    }

    // MARK: - Context

    func setContext(_ context: NSManagedObjectContext) {
        if let existing = viewContext, existing === context { return }
        self.viewContext = context
        SessionLifecycleController.shared.setContext(context)
        chatManagementService.setContext(context)
        streamLifecycle.setContext(context)
        if !didPerformFirstContextSetup && streamManager.subscriptionUserIds.isEmpty {
            didPerformFirstContextSetup = true
            streamLifecycle.forceReconnect()
        }
        SessionHealingService.shared.restoreQueueState()
        PersistentACKStore.shared.pruneExpired(in: context)
        SessionHealingService.shared.pruneExpired(in: context)
    }

    // MARK: - Stream (pass-throughs for external callers)

    func startMessageStream() {
        streamLifecycle.startMessageStream()
    }

    func stopMessageStream() {
        streamLifecycle.stopMessageStream()
    }

    // MARK: - Chat operations

    func startChat(with user: PublicUserInfo) -> Chat? {
        let chat = chatManagementService.startChat(with: user)
        streamLifecycle.forceReconnect()
        if !CryptoManager.shared.hasSession(for: user.id) {
            CryptoManager.shared.clearArchivedSessions(for: user.id)
            SessionLifecycleController.shared.prewarmSessions(for: [user.id])
        }
        return chat
    }

    func sendEndSession(to userId: String, reason: String = "manual_reset") async throws {
        try await SessionLifecycleController.shared.sendEndSession(to: userId, reason: reason)
    }

    func sendEndSessionToAllContacts(reason: String = "logout") async {
        await SessionLifecycleController.shared.sendEndSessionToAllContacts(reason: reason)
    }

    func deleteChat(chat: Chat) {
        chatManagementService.deleteChat(chat)
    }

    func pruneContact(userId: String) {
        chatManagementService.pruneContact(userId: userId)
        streamLifecycle.forceReconnect()
    }

    func openOrCreateChat(with user: User) {
        selectedTab = 0
        if let existingChat = (user.chats as? Set<Chat>)?.first {
            chatToOpen = existingChat.id
            return
        }
        guard let context = viewContext else { return }
        let chat = Chat(context: context)
        chat.id = UUID().uuidString
        chat.otherUser = user
        chat.lastMessageTime = Date()
        do {
            try context.save()
            chatToOpen = chat.id
        } catch {
            Log.error("openOrCreateChat: failed to save: \(error)", category: "ChatsViewModel")
        }
    }

    func toggleMute(chat: Chat) {
        guard let context = viewContext else { return }
        chat.isMuted.toggle()
        context.saveAndLog()
        Log.info("Chat \(chat.id) isMuted=\(chat.isMuted)", category: "ChatsViewModel")
    }

    func deleteChatWithEndSession(chat: Chat) async {
        if let userId = chat.otherUser?.id {
            do {
                try await SessionLifecycleController.shared.sendEndSession(to: userId, reason: "chat_deleted")
            } catch {
                Log.error("END_SESSION failed before chat delete (continuing): \(error)", category: "ChatsViewModel")
            }
        }
        chatManagementService.deleteChat(chat)
        streamLifecycle.forceReconnect()
    }
}
