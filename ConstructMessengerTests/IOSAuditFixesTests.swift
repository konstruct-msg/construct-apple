import XCTest
import CoreData
@testable import Construct_Messenger

final class IOSAuditFixesTests: XCTestCase {
    private func makeInMemoryContext() -> NSManagedObjectContext {
        PersistenceController(inMemory: true).container.viewContext
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
}
