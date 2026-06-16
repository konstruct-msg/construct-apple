//
//  SessionQueueWiringTests.swift
//  ConstructMessengerTests
//
//  Phase 1.5 integration coverage for SESSION_COORDINATOR_REFACTOR_SPEC.
//
//  Closes the gap left by the pure-reducer unit tests: those prove SessionReducer's
//  decisions; these prove the *wiring* into the real pipeline. They drive the REAL
//  `MessageRouter` (no network, no Rust session) so that the production path
//  `routeIncomingMessage → handleFirstMessage → SessionReducer.incomingDisposition →
//  PendingSessionQueue + delegate` is exercised end to end, with a recording delegate
//  standing in for SessionCoordinator.
//
//  What is covered:
//   • First message from an unknown peer ⇒ queued once + exactly one bundle request.
//   • A burst before init ⇒ all queued, bundle requested exactly once (the double-init
//     guard, now expressed via incomingDisposition).
//   • A mid-ratchet (msgNum>0) first message ⇒ END_SESSION requested, NOT queued (the
//     protective guard survived the refactor).
//   • Same message id twice ⇒ deduplicated, no double enqueue.
//   • PendingSessionQueue FIFO/cap/remove — the invariants the effector's drain
//     (`skippingFirst`, which drops the already-decrypted init carrier) and the
//     disposition's `isInitInFlight` rely on.
//
//  Covered-by-construction (not reachable hermetically — needs the networked bundle fetch):
//  SessionCoordinator.perform → drainPendingQueue/removePendingMessages is a 5-line switch
//  over the effects asserted in SessionRaceConditionTests; its drain order rests on the
//  PendingSessionQueue FIFO pinned here.
//

import XCTest
import CoreData
@testable import Construct_Messenger

@MainActor
final class SessionQueueWiringTests: XCTestCase {

    // MARK: - Recording delegate (stands in for SessionCoordinator)

    private final class RecordingDelegate: MessageRouterDelegate {
        var bundleRequests: [String] = []
        var endSessionRequests: [String] = []
        var healRequests: [String] = []
        var receipts: [(ids: [String], to: String, status: Shared_Proto_Signaling_V1_ReceiptStatus)] = []

        func messageRouter(_ router: MessageRouter, needsPublicKeyBundle userId: String, for message: ChatMessage) {
            bundleRequests.append(userId)
        }
        func messageRouter(_ router: MessageRouter, needsEndSession userId: String) {
            endSessionRequests.append(userId)
        }
        func messageRouter(_ router: MessageRouter, receivedEndSession userId: String, timestamp: UInt64) {}
        func messageRouter(_ router: MessageRouter, isEndSessionStale userId: String, timestamp: UInt64) -> Bool { false }
        func messageRouter(_ router: MessageRouter, didWinTieBreak userId: String) {}
        func messageRouter(_ router: MessageRouter, needsSessionHeal userId: String, failedMessage: ChatMessage) {
            healRequests.append(userId)
        }
        func messageRouter(_ router: MessageRouter, needsReceipt messageIds: [String], to userId: String, status: Shared_Proto_Signaling_V1_ReceiptStatus) {
            receipts.append((messageIds, userId, status))
        }
        func messageRouter(_ router: MessageRouter, didDecryptDeliveryReceipt messageIds: [String]) {}
        func messageRouter(_ router: MessageRouter, needsUsernameUpdate userId: String) {}
    }

    // MARK: - Fixture

    private var context: NSManagedObjectContext!
    private var router: MessageRouter!
    private var delegate: RecordingDelegate!
    private var savedUserId: String?
    private let me = "me-\(UUID().uuidString)"

    override func setUp() {
        super.setUp()
        // MessageRouter reads AuthSessionManager.shared.currentUserId at the top of
        // routeIncomingMessage; set a known local id and restore it afterwards.
        savedUserId = AuthSessionManager.shared.currentUserId
        AuthSessionManager.shared.updateUserId(me)

        context = PersistenceController(inMemory: true).container.viewContext
        router = MessageRouter()
        router.setContext(context)
        delegate = RecordingDelegate()
        router.delegate = delegate
    }

    override func tearDown() {
        if let savedUserId, !savedUserId.isEmpty {
            AuthSessionManager.shared.updateUserId(savedUserId)
        }
        context = nil
        router = nil
        delegate = nil
        super.tearDown()
    }

    private func incoming(id: String = UUID().uuidString, from peer: String, msgNum: UInt32) -> ChatMessage {
        ChatMessage(
            id: id,
            from: peer,
            to: me,
            messageType: "DIRECT_MESSAGE",
            ephemeralPublicKey: Data(repeating: 1, count: 32),
            messageNumber: msgNum,
            content: Data(repeating: 2, count: 48),
            suiteId: 1,
            timestamp: UInt64(Date().timeIntervalSince1970)
        )
    }

    // MARK: - MessageRouter disposition wiring

    func testFirstMessageUnknownPeer_QueuedOnce_BundleRequestedOnce() {
        let peer = "peer-\(UUID().uuidString)"

        router.routeIncomingMessage(incoming(from: peer, msgNum: 0), in: context)

        XCTAssertEqual(router.pendingQueue.count(for: peer), 1, "First message must be queued")
        XCTAssertEqual(delegate.bundleRequests, [peer], "Bundle must be requested exactly once")
        XCTAssertTrue(delegate.endSessionRequests.isEmpty)
    }

    func testBurstBeforeInit_AllQueued_BundleRequestedExactlyOnce() {
        let peer = "peer-\(UUID().uuidString)"

        router.routeIncomingMessage(incoming(from: peer, msgNum: 0), in: context)
        router.routeIncomingMessage(incoming(from: peer, msgNum: 1), in: context)
        router.routeIncomingMessage(incoming(from: peer, msgNum: 2), in: context)

        XCTAssertEqual(router.pendingQueue.count(for: peer), 3, "All three messages must be queued")
        XCTAssertEqual(delegate.bundleRequests.count, 1,
                       "incomingDisposition must start init exactly once for a burst (double-init guard)")
    }

    func testMidRatchetFirstMessage_RequestsEndSession_NotQueued() {
        let peer = "peer-\(UUID().uuidString)"

        // No session AND messageNumber>0 as the first message: cannot init from a mid-ratchet
        // message → the protective guard asks the sender to restart (END_SESSION). It must NOT
        // start a bundle fetch and must NOT leave the message queued.
        router.routeIncomingMessage(incoming(from: peer, msgNum: 5), in: context)

        XCTAssertEqual(delegate.endSessionRequests, [peer], "Mid-ratchet first message must trigger END_SESSION")
        XCTAssertTrue(delegate.bundleRequests.isEmpty, "Must not fetch a bundle for a mid-ratchet first message")
        XCTAssertEqual(router.pendingQueue.count(for: peer), 0, "Must not queue an un-initialisable message")
    }

    func testDuplicateMessageId_NotEnqueuedTwice() {
        let peer = "peer-\(UUID().uuidString)"
        let dup = incoming(from: peer, msgNum: 0)

        router.routeIncomingMessage(dup, in: context)
        router.routeIncomingMessage(dup, in: context)

        XCTAssertEqual(router.pendingQueue.count(for: peer), 1, "Same message id must not be queued twice")
        XCTAssertEqual(delegate.bundleRequests.count, 1, "Duplicate must not re-request the bundle")
    }

    func testTwoPeers_Isolated() {
        let alice = "alice-\(UUID().uuidString)"
        let bob   = "bob-\(UUID().uuidString)"

        router.routeIncomingMessage(incoming(from: alice, msgNum: 0), in: context)
        router.routeIncomingMessage(incoming(from: bob, msgNum: 0), in: context)
        router.routeIncomingMessage(incoming(from: bob, msgNum: 1), in: context)

        XCTAssertEqual(router.pendingQueue.count(for: alice), 1)
        XCTAssertEqual(router.pendingQueue.count(for: bob), 2)
        XCTAssertEqual(delegate.bundleRequests.sorted(), [alice, bob].sorted(),
                       "Each peer starts its own init exactly once")
    }

    // MARK: - PendingSessionQueue invariants (effector drain/disposition rely on these)

    func testQueue_DrainIsFIFO_SoSkippingFirstDropsTheInitCarrier() {
        let q = PendingSessionQueue()
        let peer = "peer-\(UUID().uuidString)"
        let m0 = incoming(from: peer, msgNum: 0)   // the X3DH init carrier
        let m1 = incoming(from: peer, msgNum: 1)
        let m2 = incoming(from: peer, msgNum: 2)

        XCTAssertTrue(q.enqueue(m0, for: peer))
        XCTAssertTrue(q.enqueue(m1, for: peer))
        XCTAssertTrue(q.enqueue(m2, for: peer))

        let drained = q.drain(for: peer)
        XCTAssertEqual(drained.map(\.id), [m0.id, m1.id, m2.id], "drain must preserve enqueue (FIFO) order")
        // This is exactly what SessionCoordinator.drainPendingQueue(skippingFirst: true) processes:
        XCTAssertEqual(Array(drained.dropFirst()).map(\.id), [m1.id, m2.id],
                       "skippingFirst must drop the oldest message (the already-decrypted init carrier)")
        XCTAssertEqual(q.count(for: peer), 0, "drain must clear the queue")
    }

    func testQueue_RemoveClearsWithoutReturning() {
        let q = PendingSessionQueue()
        let peer = "peer-\(UUID().uuidString)"
        _ = q.enqueue(incoming(from: peer, msgNum: 0), for: peer)
        _ = q.enqueue(incoming(from: peer, msgNum: 1), for: peer)

        q.remove(for: peer)

        XCTAssertEqual(q.count(for: peer), 0)
        XCTAssertTrue(q.drain(for: peer).isEmpty)
    }

    func testQueue_RespectsPerUserCap() {
        let q = PendingSessionQueue()
        let peer = "peer-\(UUID().uuidString)"
        // Cap is 100; the 101st enqueue is rejected (isInitInFlight stays meaningful).
        for i in 0..<100 {
            XCTAssertTrue(q.enqueue(incoming(from: peer, msgNum: UInt32(i)), for: peer))
        }
        XCTAssertFalse(q.enqueue(incoming(from: peer, msgNum: 100), for: peer),
                       "Queue must reject beyond its per-user cap")
        XCTAssertEqual(q.count(for: peer), 100)
    }
}
