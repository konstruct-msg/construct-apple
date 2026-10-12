import XCTest
import CoreData
@testable import Construct_Messenger

final class IOSAuditFixesTests: XCTestCase {

    /// The ACK dedup cache lives in the orchestrator core (one cache, one durable store —
    /// decisions/one-ack-cache-one-durable-store.md), so any assertion about cache warming
    /// needs a real core. Without this these tests passed only when an alphabetically earlier
    /// suite happened to boot the shared `CryptoManager` first — green by test order, which is
    /// the same rot `CryptoCoreTestBootstrap` was written to prevent.
    @MainActor
    override func setUpWithError() throws {
        try CryptoCoreTestBootstrap.ensureCore(localUserId: "1a2b3c4d-0000-4000-8000-000000000001")
    }

    private func makeInMemoryContext() -> NSManagedObjectContext {
        PersistenceController(inMemory: true).container.viewContext
    }

    private func makeChat(in context: NSManagedObjectContext, userId: String) -> Chat {
        let user = User(context: context)
        user.id = userId
        user.username = "alice"
        user.displayName = "Alice"
        user.isContact = true
        user.addedAt = Date()

        let chat = Chat(context: context)
        chat.id = "chat-\(UUID().uuidString)"
        chat.otherUser = user
        return chat
    }

    private func makeIncomingMessage(id: String, from: String, to: String) -> ChatMessage {
        ChatMessage(
            id: id,
            from: from,
            to: to,
            timestamp: UInt64(Date().timeIntervalSince1970)
        )
    }

    func testSaveOrThrow_ThrowsAndRecordsFailureMetric_OnValidationError() {
        let context = makeInMemoryContext()
        PerformanceMetrics.shared.clearAll()

        _ = Message(context: context)

        XCTAssertThrowsError(try context.saveOrThrow(category: "IOSAuditFixesTests"))
        XCTAssertEqual(PerformanceMetrics.shared.count(event: .coreDataSaveFailed), 1)
    }

    func testMarkProcessedOrThrow_PersistsAckAndWarmsInMemoryCache_OnSuccess() throws {
        let container = PersistenceController(inMemory: true).container
        LocalRepositories.useProcessedMessagesForTesting(CoreDataProcessedMessageStore(container: container))
        defer { LocalRepositories.useProcessedMessagesForTesting(nil) }
        let context = container.viewContext
        let messageId = "ack-success-\(UUID().uuidString)"

        XCTAssertFalse(PersistentACKStore.shared.isProcessedInMemory(messageId))

        try PersistentACKStore.shared.markProcessedOrThrow(messageId, senderId: "sender-success")

        XCTAssertTrue(PersistentACKStore.shared.isProcessedInMemory(messageId))

        let fetch = ProcessedMessage.fetchRequest()
        fetch.predicate = NSPredicate(format: "messageId == %@", messageId)
        let records = try context.fetch(fetch)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.senderId, "sender-success")
    }

    /// The durable write fails — the store throws — and the cache is not warmed: a mark only the
    /// cache holds would turn a redelivery after a restart into a second message. The failure
    /// comes from the store, where a real one would.
    func testMarkProcessedOrThrow_DoesNotWarmInMemoryCache_WhenSaveFails() throws {
        LocalRepositories.useProcessedMessagesForTesting(FailingProcessedMessageStore())
        defer { LocalRepositories.useProcessedMessagesForTesting(nil) }
        let messageId = "ack-failure-\(UUID().uuidString)"

        XCTAssertThrowsError(
            try PersistentACKStore.shared.markProcessedOrThrow(messageId, senderId: "sender-failure")
        )

        XCTAssertFalse(PersistentACKStore.shared.isProcessedInMemory(messageId))
    }

    @MainActor
    func testMessageRouterPersistsAckAfterMessageSave_OnSuccess() throws {
        let container = PersistenceController(inMemory: true).container
        let context = container.viewContext
        // The message, its chat and its sender's contact are written through the repositories;
        // point them here.
        LocalRepositories.useMessagesForTesting(container)
        LocalRepositories.useChatsForTesting(container)
        LocalRepositories.useContactsForTesting(container)
        LocalRepositories.useProcessedMessagesForTesting(CoreDataProcessedMessageStore(container: container))
        defer {
            LocalRepositories.useProcessedMessagesForTesting(nil)
            LocalRepositories.useMessagesForTesting(nil)
            LocalRepositories.useChatsForTesting(nil)
            LocalRepositories.useContactsForTesting(nil)
        }
        let senderId = "router-success-sender"
        let recipientId = "router-success-recipient"
        let messageId = "router-success-\(UUID().uuidString)"
        let chat = makeChat(in: context, userId: senderId)
        try context.save()
        let message = makeIncomingMessage(id: messageId, from: senderId, to: recipientId)
        let router = MessageRouter()

        try router._testPersistRegularIncomingMessage(
            "hello from router test",
            message: message,
            from: senderId,
            in: context
        )

        let ackFetch = ProcessedMessage.fetchRequest()
        ackFetch.predicate = NSPredicate(format: "messageId == %@", messageId)
        XCTAssertEqual(try context.fetch(ackFetch).count, 1, "ACK must be persisted after message save succeeds")
        XCTAssertTrue(PersistentACKStore.shared.isProcessedInMemory(messageId), "ACK cache must be warmed after durable save")

        let msgFetch = Message.fetchRequest()
        msgFetch.predicate = NSPredicate(format: "id == %@", messageId.lowercased())
        let saved = try context.fetch(msgFetch)
        XCTAssertEqual(saved.count, 1, "Message must be persisted before ACK is claimed")
        XCTAssertEqual(saved.first?.chat?.id, chat.id, "the sender's chat is the one already held")
    }

    /// The message store refuses the write: no ACK is claimed. The failure comes from the store,
    /// where a real one would; until 2026-10-12 it came from a chat left unsaved in the test's
    /// context, which the router no longer holds.
    @MainActor
    func testMessageRouterDoesNotPersistAck_WhenMessageSaveFails() throws {
        let container = PersistenceController(inMemory: true).container
        LocalRepositories.useProcessedMessagesForTesting(CoreDataProcessedMessageStore(container: container))
        LocalRepositories.useChatsForTesting(container)
        LocalRepositories.useContactsForTesting(container)
        LocalRepositories.useMessagesForTesting(RefusingMessageStore())
        defer {
            LocalRepositories.useProcessedMessagesForTesting(nil)
            LocalRepositories.useChatsForTesting(nil)
            LocalRepositories.useContactsForTesting(nil)
            LocalRepositories.useMessagesForTesting(nil)
        }
        let context = container.viewContext
        let senderId = "router-failure-sender"
        let recipientId = "router-failure-recipient"
        let messageId = "router-failure-\(UUID().uuidString)"
        let message = makeIncomingMessage(id: messageId, from: senderId, to: recipientId)
        let router = MessageRouter()

        XCTAssertThrowsError(
            try router._testPersistRegularIncomingMessage(
                "this save should fail",
                message: message,
                from: senderId,
                in: context
            )
        )

        XCTAssertFalse(PersistentACKStore.shared.isProcessedInMemory(messageId))

        let ackFetch = ProcessedMessage.fetchRequest()
        ackFetch.predicate = NSPredicate(format: "messageId == %@", messageId)
        XCTAssertEqual(try context.fetch(ackFetch).count, 0)
    }
}

/// A durable store that never takes a write.
private struct FailingProcessedMessageStore: ProcessedMessageStore {
    struct Refused: Error {}
    func markProcessed(_ messageId: String, senderId: String, at date: Date) throws -> Bool { throw Refused() }
    func isProcessed(_ messageId: String) throws -> Bool { false }
    func forget(processedBefore date: Date) throws -> Int { 0 }
}

/// A message store that holds nothing and takes no write.
private struct RefusingMessageStore: MessageStore {
    struct Refused: Error {}
    func message(_ id: String) throws -> MessageRecord? { nil }
    func messages(inChat chatId: String, before: (orderKey: String, id: String)?, limit: Int) throws -> [MessageRecord] { [] }
    func messages(inChat chatId: String, from: (orderKey: String, id: String), limit: Int) throws -> [MessageRecord] { [] }
    func messageCount(inChat chatId: String) throws -> Int { 0 }
    func allMessages(after: (orderKey: String, id: String)?, limit: Int) throws -> [MessageRecord] { [] }
    func pendingSends(inChat chatId: String?, retryCeiling: Int16, limit: Int) throws -> [MessageRecord] { [] }
    func ownMessages(in status: DeliveryStatus, limit: Int) throws -> [MessageRecord] { [] }
    func changes() -> AsyncStream<Set<String>> { AsyncStream { $0.finish() } }
    func insert(_ message: MessageRecord, searchText: String?) throws -> Bool { throw Refused() }
    func insert(_ messages: [(message: MessageRecord, searchText: String?)]) throws -> Set<String> { throw Refused() }
    func edit(_ id: String, body: Data, searchText: String?, editedAt: Date) throws -> Bool { throw Refused() }
    func setBody(_ id: String, body: Data, searchText: String?) throws -> Bool { throw Refused() }
    func setDeliveryStatus(_ id: String, _ status: DeliveryStatus) throws -> Bool { throw Refused() }
    func applySessionArchive(_ id: String, maxRetries: Int16) throws -> DeliveryStatusTransition.ArchiveOutcome? { throw Refused() }
    func setRetryCount(_ id: String, _ count: Int16) throws -> Bool { throw Refused() }
    func incrementRetryCount(_ id: String) throws -> Int16? { throw Refused() }
    func setOrderKey(_ id: String, _ orderKey: String) throws -> Bool { throw Refused() }
    func setTranscript(_ id: String, text: String?, language: String?, generatedAt: Date?) throws -> Bool { throw Refused() }
    func delete(_ ids: Set<String>) throws { throw Refused() }
}
