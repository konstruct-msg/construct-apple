import XCTest
import CoreData
@testable import Construct_Messenger

final class IOSAuditFixesTests: XCTestCase {
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
            messageType: nil,
            ephemeralPublicKey: Data(),
            messageNumber: 1,
            content: Data(),
            suiteId: 1,
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
        let context = makeInMemoryContext()
        let messageId = "ack-success-\(UUID().uuidString)"

        XCTAssertFalse(PersistentACKStore.shared.isProcessedInMemory(messageId))

        try PersistentACKStore.shared.markProcessedOrThrow(messageId, senderId: "sender-success", in: context)

        XCTAssertTrue(PersistentACKStore.shared.isProcessedInMemory(messageId))

        let fetch = ProcessedMessage.fetchRequest()
        fetch.predicate = NSPredicate(format: "messageId == %@", messageId)
        let records = try context.fetch(fetch)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.senderId, "sender-success")
    }

    func testMarkProcessedOrThrow_DoesNotWarmInMemoryCache_WhenSaveFails() throws {
        let context = makeInMemoryContext()
        let messageId = "ack-failure-\(UUID().uuidString)"

        _ = Message(context: context)

        XCTAssertThrowsError(
            try PersistentACKStore.shared.markProcessedOrThrow(messageId, senderId: "sender-failure", in: context)
        )

        XCTAssertFalse(PersistentACKStore.shared.isProcessedInMemory(messageId))

        let fetch = ProcessedMessage.fetchRequest()
        fetch.predicate = NSPredicate(format: "messageId == %@", messageId)
        let records = try context.fetch(fetch)
        XCTAssertTrue(records.isEmpty)
    }

    @MainActor
    func testMessageRouterPersistsAckAfterMessageSave_OnSuccess() throws {
        let context = makeInMemoryContext()
        let senderId = "router-success-sender"
        let recipientId = "router-success-recipient"
        let messageId = "router-success-\(UUID().uuidString)"
        let chat = makeChat(in: context, userId: senderId)
        let message = makeIncomingMessage(id: messageId, from: senderId, to: recipientId)
        let router = MessageRouter()

        try router._testPersistRegularIncomingMessage(
            "hello from router test",
            message: message,
            from: senderId,
            chat: chat,
            in: context
        )

        let ackFetch = ProcessedMessage.fetchRequest()
        ackFetch.predicate = NSPredicate(format: "messageId == %@", messageId)
        XCTAssertEqual(try context.fetch(ackFetch).count, 1, "ACK must be persisted after message save succeeds")
        XCTAssertTrue(PersistentACKStore.shared.isProcessedInMemory(messageId), "ACK cache must be warmed after durable save")

        let msgFetch = Message.fetchRequest()
        msgFetch.predicate = NSPredicate(format: "id == %@", messageId.lowercased())
        XCTAssertEqual(try context.fetch(msgFetch).count, 1, "Message must be persisted before ACK is claimed")
    }

    @MainActor
    func testMessageRouterDoesNotPersistAck_WhenMessageSaveFails() throws {
        let context = makeInMemoryContext()
        let senderId = "router-failure-sender"
        let recipientId = "router-failure-recipient"
        let messageId = "router-failure-\(UUID().uuidString)"
        let chat = makeChat(in: context, userId: senderId)
        let message = makeIncomingMessage(id: messageId, from: senderId, to: recipientId)
        let router = MessageRouter()

        _ = Message(context: context)

        XCTAssertThrowsError(
            try router._testPersistRegularIncomingMessage(
                "this save should fail",
                message: message,
                from: senderId,
                chat: chat,
                in: context
            )
        )

        XCTAssertFalse(PersistentACKStore.shared.isProcessedInMemory(messageId))

        let ackFetch = ProcessedMessage.fetchRequest()
        ackFetch.predicate = NSPredicate(format: "messageId == %@", messageId)
        XCTAssertEqual(try context.fetch(ackFetch).count, 0)
    }
}
