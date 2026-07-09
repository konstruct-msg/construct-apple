//
//  ChatMessageStore.swift
//  Construct Messenger
//

import Foundation
import CoreData

@MainActor
final class ChatMessageStore: NSObject {

    // MARK: - Dependencies

    private let chat: Chat
    private let viewContext: NSManagedObjectContext
    private let persistenceService = MessagePersistenceService()
    private weak var viewModel: ChatViewModel?

    // MARK: - FRC state

    private var fetchedResultsController: NSFetchedResultsController<Message>?
    private var frcDebounceTask: Task<Void, Never>?
    private var oldestLoadedTimestamp: Date?
    private var allLoadedMessageIds: Set<String> = []

    private let initialMessageLimit = 30
    private let loadMoreBatchSize = 20

    /// Coarse Core Data pre-filter. Note: messages are encrypted at rest
    /// (`decryptedContent == nil`), so the `BEGINSWITH` clauses only catch legacy
    /// unencrypted rows. The authoritative guard is `contentTypeRaw == 0` (stamped at
    /// save time by `applyStoredEncryption`) plus the in-Swift `isControlArtifact` /
    /// `isServiceArtifact` filter applied to fetched rows, which decrypts `displayText`.
    static let controlMessageFilterPredicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
        NSPredicate(format: "contentTypeRaw == 0"),
        NSPredicate(format: "NOT (decryptedContent BEGINSWITH '__session_ready')"),
        NSPredicate(format: "NOT (decryptedContent BEGINSWITH 'session_ready_')"),
        NSPredicate(format: "NOT (decryptedContent BEGINSWITH '__session_ping')"),
        NSPredicate(format: "NOT (decryptedContent BEGINSWITH '__END_SESSION')"),
        NSPredicate(format: "NOT (decryptedContent BEGINSWITH '__binary_init_')")
    ])

    /// In-Swift backstop for rows the Core Data predicate cannot see through at-rest
    /// encryption. Drops any control/service payload that leaked into the transcript.
    private static func visible(_ messages: [Message]) -> [Message] {
        messages.filter { !$0.isControlArtifact && !$0.isServiceArtifact }
    }

    // MARK: - Init

    init(chat: Chat, viewContext: NSManagedObjectContext) {
        self.chat = chat
        self.viewContext = viewContext
    }

    func setViewModel(_ vm: ChatViewModel) {
        self.viewModel = vm
    }

    // MARK: - Setup

    func setup() {
        let fetchRequest = Message.fetchRequest()
        let chatPredicate = NSPredicate(format: "chat == %@", chat)
        fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            chatPredicate,
            ChatMessageStore.controlMessageFilterPredicate
        ])
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
        fetchRequest.fetchLimit = initialMessageLimit
        fetchedResultsController = NSFetchedResultsController(
            fetchRequest: fetchRequest,
            managedObjectContext: viewContext,
            sectionNameKeyPath: nil,
            cacheName: nil
        )
        fetchedResultsController?.delegate = self
        do {
            try fetchedResultsController?.performFetch()
            let fetched = ChatMessageStore.visible(fetchedResultsController?.fetchedObjects ?? [])
            let messages = Array(fetched.reversed())
            viewModel?.messages = messages
            oldestLoadedTimestamp = messages.first?.timestamp
            allLoadedMessageIds = Set(messages.map { $0.id })
            Log.debug("FRC initial fetch: \(messages.count) messages (reversed to oldest-first)", category: "ChatViewModel")
        } catch {
            Log.error("FRC fetch failed: \(error)", category: "ChatViewModel")
        }
    }

    // MARK: - Load more

    func loadMoreMessages() {
        guard let vm = viewModel else { return }
        guard !vm.isLoadingMore, vm.hasMoreMessages, let oldestTimestamp = oldestLoadedTimestamp else { return }
        vm.isLoadingMore = true
        Log.debug("Loading more messages before \(oldestTimestamp)", category: "ChatViewModel")
        let fetchRequest = Message.fetchRequest()
        let chatPredicate = NSPredicate(format: "chat == %@ AND timestamp < %@", chat, oldestTimestamp as NSDate)
        fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            chatPredicate,
            ChatMessageStore.controlMessageFilterPredicate
        ])
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
        fetchRequest.fetchLimit = loadMoreBatchSize
        if let fetched = try? viewContext.fetch(fetchRequest) {
            let newMessages = ChatMessageStore.visible(fetched).filter { !allLoadedMessageIds.contains($0.id) }
            if newMessages.isEmpty {
                vm.hasMoreMessages = false
                vm.isLoadingMore = false
                Log.debug("No more older messages to load", category: "ChatViewModel")
                return
            }
            vm.messages = newMessages + vm.messages
            oldestLoadedTimestamp = vm.messages.first?.timestamp
            allLoadedMessageIds.formUnion(Set(newMessages.map { $0.id }))
            checkIfHasMoreMessages()
            Log.debug("Loaded \(newMessages.count) more messages (total: \(vm.messages.count))", category: "ChatViewModel")
        } else {
            Log.error("Failed to fetch more messages", category: "ChatViewModel")
        }
        vm.isLoadingMore = false
    }

    private func checkIfHasMoreMessages() {
        guard let oldestTimestamp = oldestLoadedTimestamp else {
            viewModel?.hasMoreMessages = false
            return
        }
        let fetchRequest = Message.fetchRequest()
        let chatPredicate = NSPredicate(format: "chat == %@ AND timestamp < %@", chat, oldestTimestamp as NSDate)
        fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            chatPredicate,
            ChatMessageStore.controlMessageFilterPredicate
        ])
        fetchRequest.fetchLimit = 1
        viewModel?.hasMoreMessages = (try? viewContext.fetch(fetchRequest).first) != nil
    }

    // MARK: - Delete

    func deleteMessage(_ message: Message) {
        do {
            try persistenceService.deleteMessage(message, chat: chat, in: viewContext)
        } catch {
            Log.error("Failed to delete message: \(error)", category: "ChatViewModel")
        }
    }

    func deleteMessages(withIds messageIds: Set<String>) {
        do {
            try persistenceService.deleteMessages(withIds: messageIds, chat: chat, in: viewContext)
        } catch {
            Log.error("Failed to delete messages: \(error)", category: "ChatViewModel")
        }
    }

    // MARK: - FRC snapshot

    @MainActor
    private func applyFRCSnapshot(_ controller: NSFetchedResultsController<NSFetchRequestResult>) {
        guard let vm = viewModel else { return }
        guard !chat.isDeleted, chat.managedObjectContext != nil else {
            vm.messages = []
            return
        }
        func isValid(_ msg: Message) -> Bool {
            msg.managedObjectContext != nil && !msg.isDeleted
        }
        let fetchedMessages = ChatMessageStore.visible((controller.fetchedObjects as? [Message] ?? [])
            .filter { isValid($0) })
            .reversed() as [Message]
        let fetchedIds = Set(fetchedMessages.map { $0.id })
        let historicMessages = vm.messages.filter {
            isValid($0) && !fetchedIds.contains($0.id)
        }
        vm.messages = historicMessages + fetchedMessages
        Log.debug("FRC updated: \(fetchedMessages.count) recent + \(historicMessages.count) historic = \(vm.messages.count) total", category: "ChatViewModel")
        if let first = vm.messages.first, isValid(first) {
            oldestLoadedTimestamp = first.timestamp
        }
        allLoadedMessageIds = Set(vm.messages.compactMap { isValid($0) ? $0.id : nil })
    }
}

// MARK: - NSFetchedResultsControllerDelegate

extension ChatMessageStore: NSFetchedResultsControllerDelegate {
    nonisolated func controllerDidChangeContent(_ controller: NSFetchedResultsController<NSFetchRequestResult>) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.frcDebounceTask?.cancel()
            self.frcDebounceTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(40))
                guard !Task.isCancelled, let self else { return }
                self.applyFRCSnapshot(controller)
            }
        }
    }
}
