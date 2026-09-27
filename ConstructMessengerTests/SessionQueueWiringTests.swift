//
//  SessionQueueWiringTests.swift
//  ConstructMessengerTests
//
//  Phase 1.5 integration coverage for SESSION_COORDINATOR_REFACTOR_SPEC.
//
//  The wiring of a message that arrives with no session: the REAL `MessageRouter` and the REAL
//  core, no network, a recording delegate standing in for SessionCoordinator.
//
//  Since 2026-09-26 the message waits in the **core's** queue, under the device its sender
//  certificate named (`decisions/first-contact-queue-keyed-by-claimed-device.md`); the router
//  keeps only its envelope and asks for the open. So the queue is read back from the core
//  (`pendingMessageCount(forDevice:)`), and the messages here carry what a sealed delivery
//  carries — a named device and a real wire payload. Without the payload the core answers
//  "malformed" and every assertion would read a path that production never takes.
//
//  What is covered:
//   • First message ⇒ queued once in the core under the named device + one bundle request.
//   • A burst before the open ⇒ all queued, bundle requested exactly once (the core's machine
//     answers the rest with `messageQueuedPendingInit`).
//   • A mid-ratchet or PQ-leftover first message with nothing opening ⇒ END_SESSION to the
//     named device, never queued.
//   • Same message id twice ⇒ queued once.
//   • A first message naming no device from an unknown peer ⇒ refused, not guessed.
//

import XCTest
import CoreData
@testable import Construct_Messenger

@MainActor
final class SessionQueueWiringTests: XCTestCase {

    // MARK: - Recording delegate (stands in for SessionCoordinator)

    private final class RecordingDelegate: MessageRouterDelegate {
        var openRequests: [String] = []
        var endSessionRequests: [String] = []
        /// The full addresses, kept alongside the account-only arrays above so a test can assert
        /// *which space* the router named a peer in — the property whose absence let a device id
        /// ride a parameter called `userId` all the way into a key-service account lookup.
        var openAddresses: [PeerAddress] = []
        var endSessionAddresses: [PeerAddress] = []
        var grantedEndSessionAddresses: [PeerAddress] = []

        func messageRouter(_ router: MessageRouter, canOpenReceiving peer: PeerAddress, for message: ChatMessage) {
            openRequests.append(peer.account)
            openAddresses.append(peer)
        }
        func messageRouter(_ router: MessageRouter, needsEndSession peer: PeerAddress) {
            endSessionRequests.append(peer.account)
            endSessionAddresses.append(peer)
        }
        func messageRouter(_ router: MessageRouter, coreGrantedEndSession peer: PeerAddress) {
            grantedEndSessionAddresses.append(peer)
        }
        func messageRouter(_ router: MessageRouter, receivedEndSession peer: PeerAddress, timestamp: UInt64) {}
        func messageRouter(_ router: MessageRouter, isEndSessionStale peer: PeerAddress, timestamp: UInt64) -> Bool { false }
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

    /// A device id in the crypto space, as a sender certificate names one.
    private func deviceId() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// What a sealed delivery hands the router: the sending device named, and the envelope's
    /// `encrypted_payload` as a real wire payload the core can parse (it will not decrypt — there
    /// is no session — but its header decides whether it can open one). A handshake message
    /// carries the ML-KEM ciphertext at any number, which is what makes it one; a mid-ratchet
    /// message carries none.
    private func incoming(
        id: String = UUID().uuidString,
        from peer: String,
        device: String?,
        msgNum: UInt32,
        handshake: Bool = true,
        pqEpoch: UInt32 = 0
    ) -> ChatMessage {
        var message = ChatMessage(
            id: id,
            from: peer,
            to: me,
            ephemeralPublicKey: Data(repeating: 1, count: 32),
            messageNumber: msgNum,
            content: Data(repeating: 2, count: 48),
            suiteId: 3,
            timestamp: UInt64(Date().timeIntervalSince1970)
        )
        message.pqMessageEpoch = pqEpoch
        message.senderDeviceId = device ?? ""
        // The parser fills this from the wire payload; the router classifies by it.
        let kem: [UInt8]? = handshake ? [UInt8](repeating: 7, count: 1088) : nil
        message.kemCiphertext = Data(kem ?? [])
        let wire = WirePayload(
            dhPublicKey: [UInt8](repeating: 1, count: 32),
            messageNumber: msgNum,
            oneTimePrekeyId: 0,
            kyberOtpkId: 0,
            previousChainLength: 0,
            suiteId: 3,
            kemCiphertext: kem,
            sealedBox: [UInt8](repeating: 2, count: 48),
            pqMessageEpoch: pqEpoch,
            pqRatchetField: []
        )
        message.rawPayload = Data((try? wirePayloadPack(payload: wire)) ?? [])
        XCTAssertFalse(message.rawPayload.isEmpty, "the fixture must carry a wire payload the core can parse")
        return message
    }

    private func queuedInCore(_ device: String) -> Int {
        CryptoManager.shared.pendingMessageCount(forDevice: device)
    }

    // MARK: - MessageRouter → core wiring

    func testFirstMessage_QueuedInTheCore_BundleRequestedOnce() {
        let peer = UUID().uuidString
        let device = deviceId()

        router.routeIncomingMessage(incoming(from: peer, device: device, msgNum: 0), in: context)

        XCTAssertEqual(queuedInCore(device), 1, "First message must wait in the core, under the named device")
        XCTAssertEqual(delegate.openAddresses, [PeerAddress(account: peer, device: device)],
                       "The open is asked for once, naming the account and the claimed device")
        XCTAssertTrue(delegate.endSessionRequests.isEmpty)
    }

    func testBurstBeforeTheOpen_AllQueued_BundleRequestedExactlyOnce() {
        let peer = UUID().uuidString
        let device = deviceId()

        router.routeIncomingMessage(incoming(from: peer, device: device, msgNum: 0), in: context)
        router.routeIncomingMessage(incoming(from: peer, device: device, msgNum: 1), in: context)
        router.routeIncomingMessage(incoming(from: peer, device: device, msgNum: 2), in: context)

        XCTAssertEqual(queuedInCore(device), 3, "All three wait behind the one open")
        XCTAssertEqual(delegate.openRequests.count, 1,
                       "The core's machine grants one open; the rest are queued behind it")
    }

    func testPqEpochLeftoverFirstMessage_RequestsEndSession_NotQueued() {
        let peer = UUID().uuidString
        let device = deviceId()

        // Same shape as the 2026-08-19 leftover: N=0, no OTPK, no KEM, PQ epoch 2. Opening from
        // it fails and costs a bundle fetch; only the peer can restart.
        router.routeIncomingMessage(incoming(from: peer, device: device, msgNum: 0, handshake: false, pqEpoch: 2), in: context)

        XCTAssertEqual(delegate.endSessionRequests, [peer], "Leftover first message must trigger END_SESSION")
        XCTAssertTrue(delegate.openRequests.isEmpty, "Must not fetch a bundle for a mid-session leftover")
        XCTAssertEqual(queuedInCore(device), 0, "Must not queue an un-initialisable leftover")
    }

    func testMidRatchetFirstMessage_RequestsEndSession_NotQueued() {
        let peer = UUID().uuidString
        let device = deviceId()

        router.routeIncomingMessage(incoming(from: peer, device: device, msgNum: 5, handshake: false), in: context)

        XCTAssertEqual(delegate.endSessionRequests, [peer], "Mid-ratchet first message must trigger END_SESSION")
        // An ask, not a grant: this guard runs before the core has decided anything, so the
        // coordinator must put it to the teardown window. Arriving as a grant would bypass it.
        XCTAssertTrue(delegate.grantedEndSessionAddresses.isEmpty,
                      "the app's own guard reached the coordinator as the core's grant")
        XCTAssertTrue(delegate.openRequests.isEmpty, "Must not fetch a bundle for a mid-ratchet first message")
        XCTAssertEqual(queuedInCore(device), 0, "Must not queue an un-initialisable message")
    }

    func testDuplicateMessageId_QueuedOnce() {
        let peer = UUID().uuidString
        let device = deviceId()
        let dup = incoming(from: peer, device: device, msgNum: 0)

        router.routeIncomingMessage(dup, in: context)
        router.routeIncomingMessage(dup, in: context)

        XCTAssertEqual(queuedInCore(device), 1, "Same message id must not be queued twice")
        XCTAssertEqual(delegate.openRequests.count, 1, "Duplicate must not re-request the bundle")
    }

    func testTwoPeers_Isolated() {
        let alice = UUID().uuidString, aliceDevice = deviceId()
        let bob = UUID().uuidString, bobDevice = deviceId()

        router.routeIncomingMessage(incoming(from: alice, device: aliceDevice, msgNum: 0), in: context)
        router.routeIncomingMessage(incoming(from: bob, device: bobDevice, msgNum: 0), in: context)
        router.routeIncomingMessage(incoming(from: bob, device: bobDevice, msgNum: 1), in: context)

        XCTAssertEqual(queuedInCore(aliceDevice), 1)
        XCTAssertEqual(queuedInCore(bobDevice), 2)
        XCTAssertEqual(delegate.openRequests.sorted(), [alice, bob].sorted(),
                       "Each peer starts its own open exactly once")
    }

    /// No certificate and no pinned device: the core's queue has no key, and the decision is to
    /// refuse rather than guess (Android's `discoverPeerDevices().first` is the guess it names).
    ///
    /// Mutation: fall through to the core with the account instead — this reddens.
    func testAFirstMessageNamingNoDeviceIsRefusedNotGuessed() {
        let peer = UUID().uuidString

        router.routeIncomingMessage(incoming(from: peer, device: nil, msgNum: 0), in: context)

        XCTAssertEqual(delegate.endSessionRequests, [peer], "the sender is asked to restart")
        XCTAssertTrue(delegate.openRequests.isEmpty, "no open is asked for a device nobody named")
        XCTAssertEqual(delegate.endSessionAddresses.first?.device, nil,
                       "the restart goes to the account — there is no device to name")
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

        router.routeIncomingMessage(incoming(from: queued, device: deviceId(), msgNum: 0), in: context)
        router.routeIncomingMessage(incoming(from: midRatchet, device: deviceId(), msgNum: 5, handshake: false), in: context)

        // Each source proved separately. A union guard cannot tell a driven path from a silent one.
        XCTAssertEqual(delegate.openAddresses.map(\.account), [queued],
                       "the bundle path did not run — everything below would read an empty list")
        XCTAssertEqual(delegate.endSessionAddresses.map(\.account), [midRatchet],
                       "the END_SESSION path did not run — everything below would read an empty list")

        for address in delegate.openAddresses + delegate.endSessionAddresses
            + delegate.grantedEndSessionAddresses {
            XCTAssertFalse(
                SessionAddressing.isCryptoIdentity(address.account),
                "\(address) puts a device id where the key service reads an account UUID"
            )
        }
    }

    /// The other half of the same rule: the device a guard names is the one the sender
    /// certificate named — the session out of sync is that device's, and the coordinator tears
    /// down the device it is given. Before the certificate named one, this pinned `nil`.
    func testAMidRatchetGuardNamesTheCertifiedDevice() {
        let peer = UUID().uuidString
        let device = deviceId()
        router.routeIncomingMessage(incoming(from: peer, device: device, msgNum: 5, handshake: false), in: context)

        XCTAssertEqual(delegate.endSessionAddresses.count, 1)
        XCTAssertEqual(delegate.endSessionAddresses.first?.device, device)
    }
}
