//
//  PendingOrderSettlesTests.swift
//  ConstructMessengerTests
//
//  A message of ours the peer has received is not waiting for a position. On 2026-10-12 one was:
//  the receipt marked it delivered, then the send RPC failed (`clientIsStopped`), no acknowledgement
//  ever brought the server's key, and the row kept the `pending` key — below every later message,
//  for good, with the rest of the chat flowing past it.
//

import XCTest
import CoreData
@testable import Construct_Messenger

@MainActor
final class PendingOrderSettlesTests: XCTestCase {

    private var container: NSPersistentContainer!
    private var store: CoreDataMessageStore!
    private var chat: Chat!

    override func setUp() async throws {
        container = PersistenceController(inMemory: true).container
        store = CoreDataMessageStore(container: container)
        let context = container.viewContext
        let other = User(context: context)
        other.id = UUID().uuidString
        other.username = "annie"
        other.displayName = ""
        chat = Chat(context: context)
        chat.id = UUID().uuidString
        chat.otherUser = other
        try context.save()
    }

    /// Mutation: drop the `settleOrder` call from `markDelivered` — this reddens.
    func testAReceiptPutsAMessageLeftPendingAtItsOwnTime() throws {
        let mine = try add(sentByMe: true, at: 1_000, key: { ServerMessageOrder.pending(localMessageId: $0) }, status: .sending)
        let theirs = try add(sentByMe: false, at: 2_000, key: { ServerMessageOrder.local(timestamp: Date(timeIntervalSince1970: 2_000), messageId: $0) })
        XCTAssertEqual(try newest(), mine, "fixture: the pending row starts below the later one")

        StreamLifecycleCoordinator.markDelivered([mine], in: store)

        XCTAssertEqual(try newest(), theirs, "the later message is the newest once ours is settled")
        XCTAssertEqual(try store.message(mine)?.deliveryStatus, .delivered)
    }

    /// Mutation: move the `settleOrder` call below the `!= .delivered` guard — this reddens. A row
    /// already delivered and stuck is what the screenshot showed; the next receipt for it repairs it.
    func testARepeatedReceiptAlsoSettlesIt() throws {
        let mine = try add(sentByMe: true, at: 1_000, key: { ServerMessageOrder.pending(localMessageId: $0) }, status: .delivered)
        StreamLifecycleCoordinator.markDelivered([mine], in: store)
        XCTAssertFalse(ServerMessageOrder.isPending(try XCTUnwrap(store.message(mine)).orderKey))
    }

    /// Mutation: make `settleOrder` skip its `isPending` guard — this reddens. The server's key is
    /// the authority once it came; a receipt must not move the row back to the sender's clock.
    func testAReceiptLeavesTheServersKeyAlone() throws {
        let serverKey = try XCTUnwrap(ServerMessageOrder.key(serverTimestampMilliseconds: 5_000_000, sequence: 3))
        let mine = try add(sentByMe: true, at: 1_000, key: { _ in serverKey }, status: .sent)
        StreamLifecycleCoordinator.markDelivered([mine], in: store)
        XCTAssertEqual(try store.message(mine)?.orderKey, serverKey)
    }

    /// Mutation: drop the status clause from the repair's predicate — the waiting row is settled
    /// and this reddens.
    func testTheLaunchRepairSettlesOnlyWhatThePeerConfirmed() throws {
        let stuck = try add(sentByMe: true, at: 1_000, key: { ServerMessageOrder.pending(localMessageId: $0) }, status: .delivered)
        let waiting = try add(sentByMe: true, at: 1_500, key: { ServerMessageOrder.pending(localMessageId: $0) }, status: .sending)

        PersistenceController.settleDeliveredPendingRows(in: container.viewContext)

        XCTAssertEqual(
            try store.message(stuck)?.orderKey,
            ServerMessageOrder.local(timestamp: Date(timeIntervalSince1970: 1_000), messageId: stuck)
        )
        XCTAssertTrue(
            ServerMessageOrder.isPending(try XCTUnwrap(store.message(waiting)).orderKey),
            "a send still in flight keeps the bottom until its acknowledgement"
        )
    }

    func testOnlyAPendingKeyIsPending() {
        XCTAssertTrue(ServerMessageOrder.isPending(ServerMessageOrder.pending(localMessageId: "A")))
        XCTAssertFalse(ServerMessageOrder.isPending(ServerMessageOrder.local(timestamp: Date(), messageId: "A")))
    }

    // MARK: -

    private func newest() throws -> String? {
        try store.messages(inChat: chat.id, before: nil, limit: 1).last?.id
    }

    @discardableResult
    private func add(
        sentByMe: Bool, at seconds: TimeInterval, key: (String) -> String, status: DeliveryStatus = .delivered
    ) throws -> String {
        let context = container.viewContext
        let m = Message(context: context)
        m.id = UUID().uuidString.lowercased()
        m.chat = chat
        m.fromUserId = sentByMe ? "me" : "annie"
        m.toUserId = sentByMe ? "annie" : "me"
        m.timestamp = Date(timeIntervalSince1970: seconds)
        m.serverOrderKey = key(m.id)
        m.isSentByMe = sentByMe
        m.deliveryStatus = status
        m.retryCount = 0
        m.applyStoredEncryption(plaintext: "text", contactId: "annie")
        try context.save()
        return m.id
    }
}
