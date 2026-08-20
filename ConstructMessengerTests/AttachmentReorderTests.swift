//
//  AttachmentReorderTests.swift
//  Construct MessengerTests
//
//  Queue order is album order on the wire, so a drag that lands wrong is a message
//  that reads wrong.
//

import XCTest
@testable import Construct_Messenger

final class AttachmentReorderTests: XCTestCase {

    // MARK: - Where a drag lands

    func testADragWithinTheStripLandsWhereItWasDropped() {
        XCTAssertEqual(MessageInputAttachmentStore.clampedDestination(2, count: 5), 2)
        XCTAssertEqual(MessageInputAttachmentStore.clampedDestination(0, count: 5), 0)
    }

    /// Overshooting the end means "put it last" — that is what the gesture looked like.
    /// The classic failure is clamping to `count`, which is a valid insertion index for an
    /// append but one past the last slot for a move, and silently drops the item off the end.
    func testOvershootingTheEndMeansLast() {
        XCTAssertEqual(MessageInputAttachmentStore.clampedDestination(9, count: 5), 4)
        XCTAssertEqual(MessageInputAttachmentStore.clampedDestination(5, count: 5), 4)
    }

    func testDraggingPastTheStartMeansFirst() {
        XCTAssertEqual(MessageInputAttachmentStore.clampedDestination(-3, count: 5), 0)
    }

    /// A single item cannot go anywhere, and an empty strip has no slot at all. Both must
    /// produce a valid index rather than a negative one.
    func testDegenerateStripsStayInBounds() {
        XCTAssertEqual(MessageInputAttachmentStore.clampedDestination(3, count: 1), 0)
        XCTAssertEqual(MessageInputAttachmentStore.clampedDestination(0, count: 0), 0)
        XCTAssertEqual(MessageInputAttachmentStore.clampedDestination(-1, count: 0), 0)
    }

    // MARK: - The move itself

    @MainActor
    func testMovingForwardKeepsEveryItem() {
        let store = MessageInputAttachmentStore()
        let items = Self.attachments(4)
        store.appendAttachments(items)

        store.moveAttachment(from: 0, to: 2)

        XCTAssertEqual(store.selectedAttachments.map(\.id),
                       [items[1].id, items[2].id, items[0].id, items[3].id])
    }

    @MainActor
    func testMovingBackwardKeepsEveryItem() {
        let store = MessageInputAttachmentStore()
        let items = Self.attachments(4)
        store.appendAttachments(items)

        store.moveAttachment(from: 3, to: 1)

        XCTAssertEqual(store.selectedAttachments.map(\.id),
                       [items[0].id, items[3].id, items[1].id, items[2].id])
    }

    @MainActor
    func testAMoveThatGoesNowhereChangesNothing() {
        let store = MessageInputAttachmentStore()
        let items = Self.attachments(3)
        store.appendAttachments(items)

        store.moveAttachment(from: 1, to: 1)

        XCTAssertEqual(store.selectedAttachments.map(\.id), items.map(\.id))
    }

    /// A gesture can outlive the item it lifted — the remove button sits on the same thumb.
    /// An out-of-range source must be ignored, not trap.
    @MainActor
    func testAMoveFromAnIndexThatNoLongerExistsIsIgnored() {
        let store = MessageInputAttachmentStore()
        let items = Self.attachments(2)
        store.appendAttachments(items)

        store.moveAttachment(from: 7, to: 0)

        XCTAssertEqual(store.selectedAttachments.map(\.id), items.map(\.id))
    }

    @MainActor
    func testDraggingOffTheEndParksTheItemLast() {
        let store = MessageInputAttachmentStore()
        let items = Self.attachments(3)
        store.appendAttachments(items)

        store.moveAttachment(from: 0, to: 99)

        XCTAssertEqual(store.selectedAttachments.map(\.id),
                       [items[1].id, items[2].id, items[0].id])
    }

    // MARK: - Helpers

    /// Identity is `MediaAttachment.id`, not a payload field. The struct has no natural name,
    /// and asserting on images would test the renderer rather than the order.
    private static func attachments(_ count: Int) -> [MediaAttachment] {
        (0..<count).map { i in
            MediaAttachment(
                originalData: Data([UInt8(i)]),
                mimeType: "image/png",
                displayImage: nil
            )
        }
    }
}
