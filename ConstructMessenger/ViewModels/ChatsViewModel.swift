//
//  ChatsViewModel.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import Foundation
import Combine
import CoreData

@MainActor
class ChatsViewModel: ObservableObject {
    private let wsManager = WebSocketManager.shared
    private var cancellables = Set<AnyCancellable>()
    private var viewContext: NSManagedObjectContext?

    // ✅ Store pending first messages from users we don't have sessions with yet
    private var pendingFirstMessages: [String: ChatMessage] = [:]  // [userId: firstMessage]
    
    // ✅ Chat ID to open programmatically (e.g., from deep link)
    @Published var chatToOpen: String?

    init() {
        setupSubscribers()
    }

    func setContext(_ context: NSManagedObjectContext) {
        self.viewContext = context
    }

    private func setupSubscribers() {
        wsManager.messagePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                self?.handleServerMessage(message)
            }
            .store(in: &cancellables)
    }

    // MARK: - Start Chat
    func startChat(with user: PublicUserInfo) -> Chat? {
        guard let context = viewContext else { return nil }

        let fetchRequest: NSFetchRequest<Chat> = Chat.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "otherUser.id == %@", user.id)

        if let existingChat = try? context.fetch(fetchRequest).first {
            return existingChat
        }

        // ✅ FIX: Check if User already exists before creating a new one
        let userFetchRequest: NSFetchRequest<User> = User.fetchRequest()
        userFetchRequest.predicate = NSPredicate(format: "id == %@", user.id)

        let dbUser: User
        if let existingUser = try? context.fetch(userFetchRequest).first {
            // Use existing user - update username and displayName if they changed
            existingUser.username = user.username
            existingUser.displayName = user.username
            dbUser = existingUser
            Log.debug("Using existing user: id=\(user.id), username=\(user.username), displayName=\(existingUser.displayName)", category: "ChatsViewModel")
        } else {
            // Create new user
            dbUser = User(context: context)
            dbUser.id = user.id
            dbUser.username = user.username
            dbUser.displayName = user.username
            Log.debug("Created new user: id=\(user.id), username=\(user.username), displayName=\(user.username)", category: "ChatsViewModel")
        }

        let chat = Chat(context: context)
        chat.id = UUID().uuidString
        chat.otherUser = dbUser

        do {
            try context.save()
            Log.debug("✅ Chat saved successfully", category: "ChatsViewModel")
            Log.debug("   chat.id = \(chat.id)", category: "ChatsViewModel")
            Log.debug("   chat.otherUser?.id = \(chat.otherUser?.id ?? "nil")", category: "ChatsViewModel")
            Log.debug("   chat.otherUser?.username = \(chat.otherUser?.username ?? "nil")", category: "ChatsViewModel")
            Log.debug("   chat.otherUser?.displayName = \(chat.otherUser?.displayName ?? "nil")", category: "ChatsViewModel")
        } catch {
            Log.error("❌ Failed to save chat: \(error)", category: "ChatsViewModel")
        }
        return chat
    }

    // MARK: - Delete Chat
    func deleteChat(chat: Chat) {
        guard let context = viewContext else { return }

        // ✅ CRITICAL FIX: Delete crypto session when deleting chat
        if let userId = chat.otherUser?.id {
            CryptoManager.shared.deleteSession(for: userId)
            Log.info("🗑️ Deleted crypto session for user: \(userId)", category: "ChatsViewModel")
        }

        context.delete(chat)
        try? context.save()
    }

    // MARK: - Handle Server Messages
    private func handleServerMessage(_ message: ServerMessage) {
        switch message {
        case .publicKeyBundle(let data):
            handlePublicKeyBundle(data)

        case .message(let msg):
            handleIncomingMessage(msg)

        default:
            break
        }
    }

    // MARK: - Handle Public Key Bundle (for receiving session initialization)
    private func handlePublicKeyBundle(_ data: PublicKeyBundleData) {
        Log.debug("📦 ChatsViewModel: Received publicKeyBundle for userId: \(data.userId), hasPendingMessage: \(pendingFirstMessages[data.userId] != nil)", category: "ChatsViewModel")

        // Check if we have a pending first message from this user
        guard let firstMessage = pendingFirstMessages[data.userId] else {
            // No pending message - this bundle was requested for outgoing session (handled in ChatViewModel)
            Log.debug("ChatsViewModel: No pending first message for \(data.userId) - assuming this is for ChatViewModel to handle", category: "ChatsViewModel")

            // Update username for existing user if found
            guard let context = viewContext else { return }
            let userFetch: NSFetchRequest<User> = User.fetchRequest()
            userFetch.predicate = NSPredicate(format: "id == %@", data.userId)
            if let existingUser = try? context.fetch(userFetch).first {
                existingUser.username = data.username
                existingUser.displayName = data.username
                try? context.save()
                Log.info("Updated username for user: \(data.username)", category: "ChatsViewModel")
            }
            return
        }

        Log.info("🔑 Received public key bundle for \(data.userId) - initializing receiving session", category: "ChatsViewModel")

        guard let context = viewContext else { return }
        guard let currentUserId = SessionManager.shared.currentUserId else { return }

        // Create bundle tuple
        let bundleWithSuite = (
            identityPublic: data.identityPublic,
            signedPrekeyPublic: data.signedPrekeyPublic,
            signature: data.signature,
            verifyingKey: data.verifyingKey,
            suiteId: "1"
        )

        do {
            // ✅ NEW API: Initialize receiving session returns decrypted first message
            // No need to call decryptMessage again!
            let decryptedContent = try CryptoManager.shared.initReceivingSession(
                for: data.userId,
                recipientBundle: bundleWithSuite,
                firstMessage: firstMessage
            )

            Log.info("✅ Receiving session initialized for \(data.userId), first message decrypted", category: "ChatsViewModel")

            // Find or create chat (chat was already created in handleIncomingMessage)
            let fetchRequest: NSFetchRequest<Chat> = Chat.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "otherUser.id == %@", data.userId)

            let chat: Chat
            if let existingChat = try? context.fetch(fetchRequest).first {
                // Update username for existing user (it was set to GUID in handleIncomingMessage)
                if let user = existingChat.otherUser {
                    let oldUsername = user.username
                    user.username = data.username
                    user.displayName = data.username
                    Log.info("🔄 Updating username from '\(oldUsername)' to '\(data.username)' for user \(data.userId)", category: "ChatsViewModel")
                    try? context.save()  // ✅ FIX: Save updated username
                    Log.info("✅ Updated username to: \(data.username), displayName: \(user.displayName)", category: "ChatsViewModel")
                } else {
                    Log.error("❌ Chat found but otherUser is nil for userId: \(data.userId)", category: "ChatsViewModel")
                }
                chat = existingChat
            } else {
                // This shouldn't happen since handleIncomingMessage creates the chat
                // But if it does, create it with correct username from the start

                // ✅ FIX: Check if User already exists before creating
                let userFetchRequest: NSFetchRequest<User> = User.fetchRequest()
                userFetchRequest.predicate = NSPredicate(format: "id == %@", data.userId)

                let dbUser: User
                if let existingUser = try? context.fetch(userFetchRequest).first {
                    existingUser.username = data.username
                    existingUser.displayName = data.username
                    dbUser = existingUser
                    Log.debug("Using existing user in fallback: id=\(data.userId), username=\(data.username)", category: "ChatsViewModel")
                } else {
                    let newUser = User(context: context)
                    newUser.id = data.userId
                    newUser.username = data.username
                    newUser.displayName = data.username
                    dbUser = newUser
                    Log.debug("Created new user in fallback: id=\(data.userId), username=\(data.username)", category: "ChatsViewModel")
                }

                let newChat = Chat(context: context)
                newChat.id = UUID().uuidString
                newChat.otherUser = dbUser
                chat = newChat
                Log.debug("⚠️ Chat didn't exist, created new one with username: \(data.username) (this shouldn't happen)", category: "ChatsViewModel")
            }

            // Save the message
            saveMessage(for: chat, with: firstMessage, decryptedContent: decryptedContent)

            chat.lastMessageText = decryptedContent
            chat.lastMessageTime = Date(timeIntervalSince1970: TimeInterval(firstMessage.timestamp))

            // Remove from pending
            pendingFirstMessages.removeValue(forKey: data.userId)

            Log.info("✅ First message from \(data.userId) decrypted and saved", category: "ChatsViewModel")

        } catch {
            Log.error("❌ Failed to initialize receiving session: \(error)", category: "ChatsViewModel")
            pendingFirstMessages.removeValue(forKey: data.userId)
        }
    }

    private func handleIncomingMessage(_ message: ChatMessage) {
        Log.debug("📨 ChatsViewModel: Incoming message \(message.id) from \(message.from)", category: "ChatsViewModel")

        guard let context = viewContext,
              let currentUserId = SessionManager.shared.currentUserId else { return }

        let otherUserId = message.from == currentUserId ? message.to : message.from

        let fetchRequest: NSFetchRequest<Chat> = Chat.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "otherUser.id == %@", otherUserId)

        let chat: Chat
        let isNewChat: Bool
        if let existingChat = try? context.fetch(fetchRequest).first {
            chat = existingChat
            isNewChat = false
        } else {
            // Create a new user with only the ID (no server-stored metadata)
            // Username will be updated when we receive publicKeyBundle

            // ✅ FIX: Check if User already exists before creating
            let userFetchRequest: NSFetchRequest<User> = User.fetchRequest()
            userFetchRequest.predicate = NSPredicate(format: "id == %@", otherUserId)

            let dbUser: User
            if let existingUser = try? context.fetch(userFetchRequest).first {
                // Use existing user (shouldn't happen, but safety check)
                dbUser = existingUser
                Log.debug("Using existing user in handleIncomingMessage: id=\(otherUserId)", category: "ChatsViewModel")
            } else {
                let newUser = User(context: context)
                newUser.id = otherUserId
                newUser.username = otherUserId  // Temporary: will be updated from publicKeyBundle
                newUser.displayName = otherUserId
                dbUser = newUser
                Log.debug("Created new user in handleIncomingMessage: id=\(otherUserId)", category: "ChatsViewModel")
            }
            // User display info is stored locally only, not fetched from server

            let newChat = Chat(context: context)
            newChat.id = UUID().uuidString
            newChat.otherUser = dbUser
            chat = newChat
            isNewChat = true

            // NOTE: If we received a message, session already exists.
            // Don't request public key here - it's for session initialization only!
        }

        // ✅ Check if we have a session for this user
        let hasSession = CryptoManager.shared.hasSession(for: otherUserId)

        let decryptedContent: String
        if !hasSession {
            // 🔑 First message from this user - need to initialize receiving session
            Log.info("📩 First message from \(otherUserId) - requesting public key bundle", category: "ChatsViewModel")

            // Store the first message temporarily
            pendingFirstMessages[otherUserId] = message

            // If we created a new chat, save it now so it appears in UI
            // Username will be updated when publicKeyBundle arrives
            if isNewChat {
                do {
                    try context.save()
                    Log.debug("✅ Saved new chat for \(otherUserId) (username will be updated when publicKeyBundle arrives)", category: "ChatsViewModel")
                } catch {
                    Log.error("❌ Failed to save new chat: \(error)", category: "ChatsViewModel")
                }
            }

            // Request sender's public key bundle from server
            wsManager.send(.getPublicKey(GetPublicKeyData(userId: otherUserId)))

            // Exit early - we'll process this message after receiving the public key bundle
            return
        } else {
            // ✅ Existing session - decrypt normally
            guard let content = try? CryptoManager.shared.decryptMessage(message) else {
                Log.error("❌ ChatsViewModel: Failed to decrypt incoming message \(message.id)", category: "ChatsViewModel")

                // ✅ Session was corrupted and auto-deleted by CryptoManager
                // Request fresh public key bundle to reinitialize
                Log.debug("🔄 Decryption failed, session was deleted. Requesting reinitialization...", category: "ChatsViewModel")
                wsManager.send(.getPublicKey(GetPublicKeyData(userId: otherUserId)))

                // Store the failed message to retry after reinitialization
                pendingFirstMessages[otherUserId] = message
                Log.info("📝 Message stored for retry after session reinitialization", category: "ChatsViewModel")

                return
            }
            decryptedContent = content
        }

        saveMessage(for: chat, with: message, decryptedContent: decryptedContent)

        chat.lastMessageText = decryptedContent
        chat.lastMessageTime = Date(timeIntervalSince1970: TimeInterval(message.timestamp))

        // ✅ REMOVED DUPLICATE: saveMessage() already calls context.save() internally
    }
    
    private func saveMessage(for chat: Chat, with messageData: ChatMessage, decryptedContent: String) {
        guard let context = viewContext else { return }

        let fetchRequest: NSFetchRequest<Message> = Message.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", messageData.id)

        if (try? context.fetch(fetchRequest).first) != nil {
            return // Already exists
        }

        let message = Message(context: context)
        message.id = messageData.id
        message.fromUserId = messageData.from
        message.toUserId = messageData.to
        message.encryptedContent = messageData.content
        message.decryptedContent = decryptedContent
        message.timestamp = Date(timeIntervalSince1970: TimeInterval(messageData.timestamp))
        message.isSentByMe = false
        message.deliveryStatus = .delivered
        message.retryCount = 0
        message.chat = chat

        do {
            try context.save()
        } catch {
            print("❌ ChatsViewModel: Failed to save message: \(error)")
        }
    }
}
