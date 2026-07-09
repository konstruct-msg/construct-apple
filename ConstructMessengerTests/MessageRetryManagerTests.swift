//@testable import Construct_Messenger
//
//@MainActor
//final class MessageRetryManagerTests: XCTestCase {
//    private var context: NSManagedObjectContext!
//
//    override func setUp() {
//        super.setUp()
//        context = PersistenceController(inMemory: true).container.viewContext
//    }
//
//    override func tearDown() {
//        context = nil
//        super.tearDown()
//    }
//
//    func testPrepareMessagesForGlobalRetry_PreservesQueuedMessagesWithoutWirePayload() {
//        let retryManager = MessageRetryManager.shared
//
//        let sendable = makeMessage(
//            id: "sendable-\(UUID().uuidString.lowercased())",
//            status: .queued,
//            retryCount: 1
//        )
//        let queuedMissingPayload = makeMessage(
//            id: "queued-missing-\(UUID().uuidString.lowercased())",
//            status: .queued,
//            retryCount: 2
//        )
//        let failedMissingPayload = makeMessage(
//            id: "failed-missing-\(UUID().uuidString.lowercased())",
//            status: .failed,
//            retryCount: 3
//        )
//
//        OutgoingWirePayloadStore.shared.saveChunk(
//            baseMessageId: sendable.id,
//            chunkMessageId: sendable.id,
//            wirePayload: Data([0x01, 0x02, 0x03])
//        )
//
//        defer {
//            OutgoingWirePayloadStore.shared.remove(baseMessageId: sendable.id)
//            OutgoingWirePayloadStore.shared.remove(baseMessageId: queuedMissingPayload.id)
//            OutgoingWirePayloadStore.shared.remove(baseMessageId: failedMissingPayload.id)
//        }
//
//        let pendingIds = retryManager.prepareMessagesForGlobalRetry(
//            [sendable, queuedMissingPayload, failedMissingPayload],
//            context: context
//        )
//
//        XCTAssertEqual(pendingIds, [sendable.id])
//        XCTAssertEqual(sendable.deliveryStatus, .sending)
//        XCTAssertEqual(sendable.retryCount, 2)
//
//        XCTAssertEqual(queuedMissingPayload.deliveryStatus, .queued)
//        XCTAssertEqual(queuedMissingPayload.retryCount, 2)
//
//        XCTAssertEqual(failedMissingPayload.deliveryStatus, .failed)
//        XCTAssertEqual(failedMissingPayload.retryCount, 3)
//    }
//
//    private func makeMessage(id: String, status: DeliveryStatus, retryCount: Int16) -> Message {
//        let message = Message(context: context)
//        message.id = id
//        message.fromUserId = "me"
//        message.toUserId = "peer"
//        message.timestamp = Date()
//        message.deliveryStatus = status
//        message.retryCount = retryCount
//        message.isSentByMe = true
//        message.contentType = .regular
//        message.encryptedContent = Data()
//        message.decryptedContent = "hello"
//        return message
//    }
//}
