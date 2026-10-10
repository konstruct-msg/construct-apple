import XCTest
import CoreData
@testable import Construct_Messenger

@MainActor
final class MessageRetryManagerTests: XCTestCase {
    private var context: NSManagedObjectContext!
    private var chat: Chat!

    override func setUp() {
        super.setUp()
        let container = PersistenceController(inMemory: true).container
        context = container.viewContext
        // The manager writes through the repository (messages B2); point it here.
        LocalRepositories.useMessagesForTesting(container)
        chat = Chat(context: context)
        chat.id = UUID().uuidString
    }

    override func tearDown() {
        LocalRepositories.useMessagesForTesting(nil)
        chat = nil
        context = nil
        super.tearDown()
    }

    /// What the store holds for `message` — the manager writes there, not on the object it was given.
    private func stored(_ message: Message) -> MessageRecord? {
        try? LocalRepositories.messages.message(message.id)
    }

    func testPrepareMessagesForGlobalRetry_PreservesQueuedMessagesWithoutWirePayload() {
        let retryManager = MessageRetryManager.shared

        let sendable = makeMessage(
            id: "sendable-\(UUID().uuidString.lowercased())",
            status: .queued,
            retryCount: 1
        )
        let queuedMissingPayload = makeMessage(
            id: "queued-missing-\(UUID().uuidString.lowercased())",
            status: .queued,
            retryCount: 2
        )
        let failedMissingPayload = makeMessage(
            id: "failed-missing-\(UUID().uuidString.lowercased())",
            status: .failed,
            retryCount: 3
        )

        OutgoingWirePayloadStore.shared.saveChunk(
            baseMessageId: sendable.id,
            chunkMessageId: sendable.id,
            wirePayload: Data([0x01, 0x02, 0x03]),
            recipientDeviceId: nil
        )

        defer {
            OutgoingWirePayloadStore.shared.remove(baseMessageId: sendable.id)
            OutgoingWirePayloadStore.shared.remove(baseMessageId: queuedMissingPayload.id)
            OutgoingWirePayloadStore.shared.remove(baseMessageId: failedMissingPayload.id)
        }

        try! context.save()

        let pendingIds = retryManager.prepareMessagesForGlobalRetry(
            [sendable, queuedMissingPayload, failedMissingPayload],
            context: context
        )

        XCTAssertEqual(pendingIds, [sendable.id])
        XCTAssertEqual(stored(sendable)?.deliveryStatus, .sending)
        XCTAssertEqual(stored(sendable)?.retryCount, 2)

        XCTAssertEqual(stored(queuedMissingPayload)?.deliveryStatus, .queued)
        XCTAssertEqual(stored(queuedMissingPayload)?.retryCount, 2)

        XCTAssertEqual(stored(failedMissingPayload)?.deliveryStatus, .failed)
        XCTAssertEqual(stored(failedMissingPayload)?.retryCount, 3)
    }

    private func makeMessage(id: String, status: DeliveryStatus, retryCount: Int16) -> Message {
        let message = Message(context: context)
        message.id = id
        message.fromUserId = "me"
        message.toUserId = "peer"
        message.timestamp = Date()
        message.deliveryStatus = status
        message.retryCount = retryCount
        message.isSentByMe = true
        message.contentType = .regular
        message.encryptedContent = Data()
        message.decryptedContent = "hello"
        message.serverOrderKey = ServerMessageOrder.pending(localMessageId: id)
        message.chat = chat
        return message
    }
}
