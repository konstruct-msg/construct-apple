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
        /// The full addresses, kept alongside the account-only arrays above so a test can assert
        /// *which space* the router named a peer in — the property whose absence let a device id
        /// ride a parameter called `userId` all the way into a key-service account lookup.
        var bundleAddresses: [PeerAddress] = []
        var endSessionAddresses: [PeerAddress] = []
        var healAddresses: [PeerAddress] = []

        func messageRouter(_ router: MessageRouter, needsPublicKeyBundle peer: PeerAddress, for message: ChatMessage) {
            bundleRequests.append(peer.account)
            bundleAddresses.append(peer)
        }
        func messageRouter(_ router: MessageRouter, needsEndSession peer: PeerAddress) {
            endSessionRequests.append(peer.account)
            endSessionAddresses.append(peer)
        }
        func messageRouter(_ router: MessageRouter, receivedEndSession peer: PeerAddress, timestamp: UInt64) {}
        func messageRouter(_ router: MessageRouter, isEndSessionStale peer: PeerAddress, timestamp: UInt64) -> Bool { false }
        func messageRouter(_ router: MessageRouter, isResetInitSuperseded peer: PeerAddress, timestamp: UInt64, initEphemeral: Data) -> Bool { false }
        func messageRouter(_ router: MessageRouter, didWinTieBreak peer: PeerAddress) {}
        func messageRouter(_ router: MessageRouter, needsSessionHeal peer: PeerAddress, failedMessage: ChatMessage) {
            healRequests.append(peer.account)
            healAddresses.append(peer)
        }
        func messageRouter(_ router: MessageRouter, didDecryptDeliveryReceipt messageIds: [String]) {}
        func messageRouter(_ router: MessageRouter, needsUsernameUpdate peer: PeerAddress) {}
    }

    // MARK: - Fixture

    private var context: NSManagedObjectContext!
    private var router: MessageRouter!
    private var delegate: RecordingDelegate!
    private var savedUserId: String?
    // ServerUserId space: everything handed to the session layer is a bare 36-char UUID.
    private let me = UUID().uuidString

    override func setUpWithError() throws {
        try super.setUpWithError()
        // MessageRouter reads AuthSessionManager.shared.currentUserId at the top of
        // routeIncomingMessage; set a known local id and restore it afterwards.
        savedUserId = AuthSessionManager.shared.currentUserId
        AuthSessionManager.shared.updateUserId(me)

        // routeIncomingMessage bails out immediately when the crypto core is absent
        // (`!CryptoManager.shared.isInitialized` → locked-device defer, ccd6ff3a). Without a
        // core every assertion below silently reads zero, which is how these tests rotted
        // undetected. Bootstrap a real core so the disposition wiring is actually reached.
        // Order matters: reloadCoreFromKeychain refuses to build a core until the local user
        // id is cached, since that id is the Double Ratchet AAD binding.
        if !CryptoManager.shared.isInitialized {
            CryptoManager.shared.setLocalUserId(me)
            _ = try CryptoManager.shared.generateRegistrationBundle()
            CryptoManager.shared.reloadCoreFromKeychain()
        }
        XCTAssertTrue(
            CryptoManager.shared.isInitialized,
            "Crypto core failed to bootstrap — MessageRouter would defer every incoming message and every assertion below would vacuously read zero"
        )

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
            ephemeralPublicKey: Data(repeating: 1, count: 32),
            messageNumber: msgNum,
            content: Data(repeating: 2, count: 48),
            suiteId: 1,
            timestamp: UInt64(Date().timeIntervalSince1970)
        )
    }

    // MARK: - MessageRouter disposition wiring

    func testFirstMessageUnknownPeer_QueuedOnce_BundleRequestedOnce() {
        let peer = UUID().uuidString

        router.routeIncomingMessage(incoming(from: peer, msgNum: 0), in: context)

        XCTAssertEqual(router.pendingQueue.count(for: peer), 1, "First message must be queued")
        XCTAssertEqual(delegate.bundleRequests, [peer], "Bundle must be requested exactly once")
        XCTAssertTrue(delegate.endSessionRequests.isEmpty)
    }

    func testBurstBeforeInit_AllQueued_BundleRequestedExactlyOnce() {
        let peer = UUID().uuidString

        router.routeIncomingMessage(incoming(from: peer, msgNum: 0), in: context)
        router.routeIncomingMessage(incoming(from: peer, msgNum: 1), in: context)
        router.routeIncomingMessage(incoming(from: peer, msgNum: 2), in: context)

        XCTAssertEqual(router.pendingQueue.count(for: peer), 3, "All three messages must be queued")
        XCTAssertEqual(delegate.bundleRequests.count, 1,
                       "incomingDisposition must start init exactly once for a burst (double-init guard)")
    }

    func testPqEpochLeftoverFirstMessage_RequestsEndSession_NotQueued() {
        let peer = UUID().uuidString
        var leftover = incoming(from: peer, msgNum: 0)
        leftover.pqMessageEpoch = 2

        // Same shape as the 2026-08-19 leftover: N=0, no OTPK, no KEM, PQ epoch 2.
        // Must NOT start a bundle fetch — that path called initReceivingSession, failed,
        // and cleared the queue, including any real handshake behind it.
        router.routeIncomingMessage(leftover, in: context)

        XCTAssertEqual(delegate.endSessionRequests, [peer], "Leftover first message must trigger END_SESSION")
        XCTAssertTrue(delegate.bundleRequests.isEmpty, "Must not fetch a bundle for a mid-session leftover")
        XCTAssertEqual(router.pendingQueue.count(for: peer), 0, "Must not queue an un-initialisable leftover")
    }

    func testMidRatchetFirstMessage_RequestsEndSession_NotQueued() {
        let peer = UUID().uuidString

        // No session AND messageNumber>0 as the first message: cannot init from a mid-ratchet
        // message → the protective guard asks the sender to restart (END_SESSION). It must NOT
        // start a bundle fetch and must NOT leave the message queued.
        router.routeIncomingMessage(incoming(from: peer, msgNum: 5), in: context)

        XCTAssertEqual(delegate.endSessionRequests, [peer], "Mid-ratchet first message must trigger END_SESSION")
        XCTAssertTrue(delegate.bundleRequests.isEmpty, "Must not fetch a bundle for a mid-ratchet first message")
        XCTAssertEqual(router.pendingQueue.count(for: peer), 0, "Must not queue an un-initialisable message")
    }

    func testDuplicateMessageId_NotEnqueuedTwice() {
        let peer = UUID().uuidString
        let dup = incoming(from: peer, msgNum: 0)

        router.routeIncomingMessage(dup, in: context)
        router.routeIncomingMessage(dup, in: context)

        XCTAssertEqual(router.pendingQueue.count(for: peer), 1, "Same message id must not be queued twice")
        XCTAssertEqual(delegate.bundleRequests.count, 1, "Duplicate must not re-request the bundle")
    }

    func testTwoPeers_Isolated() {
        let alice = UUID().uuidString
        let bob   = UUID().uuidString

        router.routeIncomingMessage(incoming(from: alice, msgNum: 0), in: context)
        router.routeIncomingMessage(incoming(from: bob, msgNum: 0), in: context)
        router.routeIncomingMessage(incoming(from: bob, msgNum: 1), in: context)

        XCTAssertEqual(router.pendingQueue.count(for: alice), 1)
        XCTAssertEqual(router.pendingQueue.count(for: bob), 2)
        XCTAssertEqual(delegate.bundleRequests.sorted(), [alice, bob].sorted(),
                       "Each peer starts its own init exactly once")
    }

    // MARK: - The identity space the delegate is named in

    /// Every address the router hands the delegate must carry an **account** in `account`.
    ///
    /// Devices 2026-09-01: the parameter was one `String` called `userId`, and on the paths the
    /// Rust orchestrator originated it held a device id. `SessionCoordinator` took it to
    /// `initializeSessionProactively` → `fetchPublicKeyWithRetry`, and the key service answered
    /// `notFound: "User or device not found"` three times per attempt, eight attempts per session.
    ///
    /// This drives the paths this suite can reach hermetically — the bundle request and the two
    /// END_SESSION guards. The core-originated `.sendEndSession` / `.fetchPublicKeyBundle` cases
    /// need a diverged ratchet and are covered by construction: both build their address as
    /// `PeerAddress(account: otherUserId, device: <the id the core named>)`, and `otherUserId` is
    /// the envelope's, which is what the assertion below pins for every other path here.
    func testEveryAddressHandedToTheDelegateNamesAnAccount() {
        // Two peers, because the two paths are mutually exclusive on one. A second message from
        // the *same* peer finds `isInitInFlight` true and is merely queued, so the END_SESSION
        // guard never runs — the first draft of this test did exactly that, and a mutation that
        // replaced the guard's address with our own device id left it green. The union was
        // non-empty (the bundle request was in it), which is precisely how a vacuous assertion
        // looks from the outside.
        let queued = UUID().uuidString    // msgNum 0, no session → bundle request
        let midRatchet = UUID().uuidString // msgNum 5, no session → END_SESSION, never queued

        router.routeIncomingMessage(incoming(from: queued, msgNum: 0), in: context)
        router.routeIncomingMessage(incoming(from: midRatchet, msgNum: 5), in: context)

        // Each source proved separately. A union guard cannot tell a driven path from a silent one.
        XCTAssertEqual(delegate.bundleAddresses.map(\.account), [queued],
                       "the bundle path did not run — everything below would read an empty list")
        XCTAssertEqual(delegate.endSessionAddresses.map(\.account), [midRatchet],
                       "the END_SESSION path did not run — everything below would read an empty list")

        for address in delegate.bundleAddresses + delegate.endSessionAddresses + delegate.healAddresses {
            XCTAssertFalse(
                SessionAddressing.isCryptoIdentity(address.account),
                "\(address) puts a device id where the key service reads an account UUID"
            )
        }
    }

    /// The other half of the same rule: an event that names no device must say so, rather than
    /// inventing one. Both guards here fire before any session exists, so there is no device to
    /// name — and `deviceOrPinned()` is where a caller that needs one asks for the pinned fallback
    /// explicitly, at the point where the fallback is the right answer.
    func testAGuardThatRunsBeforeAnySessionNamesNoDevice() {
        let peer = UUID().uuidString
        router.routeIncomingMessage(incoming(from: peer, msgNum: 5), in: context)

        XCTAssertEqual(delegate.endSessionAddresses.count, 1)
        XCTAssertNil(
            delegate.endSessionAddresses.first?.device,
            "a mid-ratchet message arrives with no session — nothing has named which device diverged"
        )
    }

    // MARK: - PendingSessionQueue invariants (effector drain/disposition rely on these)

    func testQueue_DrainIsFIFO_SoSkippingFirstDropsTheInitCarrier() {
        let q = PendingSessionQueue()
        let peer = UUID().uuidString
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
        let peer = UUID().uuidString
        _ = q.enqueue(incoming(from: peer, msgNum: 0), for: peer)
        _ = q.enqueue(incoming(from: peer, msgNum: 1), for: peer)

        q.remove(for: peer)

        XCTAssertEqual(q.count(for: peer), 0)
        XCTAssertTrue(q.drain(for: peer).isEmpty)
    }

    func testQueue_RespectsPerUserCap() {
        let q = PendingSessionQueue()
        let peer = UUID().uuidString
        // Cap is 100; the 101st enqueue is rejected (isInitInFlight stays meaningful).
        for i in 0..<100 {
            XCTAssertTrue(q.enqueue(incoming(from: peer, msgNum: UInt32(i)), for: peer))
        }
        XCTAssertFalse(q.enqueue(incoming(from: peer, msgNum: 100), for: peer),
                       "Queue must reject beyond its per-user cap")
        XCTAssertEqual(q.count(for: peer), 100)
    }
}
