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
        /// The full addresses, kept alongside the account-only arrays above so a test can assert
        /// *which space* the router named a peer in — the property whose absence let a device id
        /// ride a parameter called `userId` all the way into a key-service account lookup.
        var openAddresses: [PeerAddress] = []
        var decryptionErrorAddresses: [PeerAddress] = []

        func messageRouter(_ router: MessageRouter, canOpenReceiving peer: PeerAddress, for message: ChatMessage) {
            openRequests.append(peer.account)
            openAddresses.append(peer)
        }
        func messageRouter(_ router: MessageRouter, receivedDecryptionError peer: PeerAddress, payload: Data, opened: Bool) {
            decryptionErrorAddresses.append(peer)
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
        let message = ChatMessage(
            id: id,
            from: peer,
            to: me,
            timestamp: UInt64(Date().timeIntervalSince1970),
            senderDeviceId: device ?? "",
            rawPayload: handBuiltWirePayload(
                messageNumber: msgNum,
                suiteId: 4,
                kemCiphertext: handshake ? [UInt8](repeating: 7, count: 1088) : nil,
                pqMessageEpoch: pqEpoch
            )
        )
        XCTAssertNotNil(message.wire, "the fixture must carry a wire payload the core can parse")
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

    /// No session and no handshake header: nothing can open from it, so it is neither queued nor
    /// opened. It goes to the core, which answers it as unread — a decryption error to its writer
    /// when the message is sealed; these fixtures carry no certificate, so none is built — and it
    /// is recorded, not held. Until 2026-09-27 this app answered it before the core, with an
    /// END_SESSION (`decisions/sessions-renew-by-sending.md`).
    ///
    /// Mutation: enqueue on "no session" regardless of the header — this reddens.
    func testAHeaderlessMessageWithNoSessionIsAnsweredNotQueued() {
        for (msgNum, epoch) in [(UInt32(5), UInt32(0)), (0, 2)] {  // mid-ratchet; the 2026-08-19 leftover
            let peer = UUID().uuidString
            let device = deviceId()
            let message = incoming(from: peer, device: device, msgNum: msgNum, handshake: false, pqEpoch: epoch)

            router.routeIncomingMessage(message, in: context)

            XCTAssertFalse(delegate.openRequests.contains(peer), "nothing opens from a message with no header")
            XCTAssertEqual(queuedInCore(device), 0, "a message nothing can open is not queued")
            XCTAssertTrue(PersistentACKStore.shared.isProcessed(message.id, in: context),
                          "answered and recorded, not held for a redelivery that reads the same")
        }
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

        let message = incoming(from: peer, device: nil, msgNum: 0)
        router.routeIncomingMessage(message, in: context)

        XCTAssertTrue(delegate.openRequests.isEmpty, "no open is asked for a device nobody named")
        XCTAssertTrue(PersistentACKStore.shared.isProcessed(message.id, in: context), "refused and recorded")
    }

    // MARK: - The identity space the delegate is named in

    /// Every address the router hands the delegate must carry an **account** in `account`.
    ///
    /// Devices 2026-09-01: the parameter was one `String` called `userId`, and on the paths the
    /// Rust orchestrator originated it held a device id. `SessionCoordinator` took it to
    /// `initializeSessionProactively` → `fetchPublicKeyWithRetry`, and the key service answered
    /// `notFound: "User or device not found"` three times per attempt, eight attempts per session.
    ///
    /// This drives the path this suite can reach hermetically — the open request. The END_SESSION
    /// guards it also drove went on 2026-09-27; the one other address the router hands over now,
    /// `receivedDecryptionError`, is built the same way, from the envelope's account.
    func testEveryAddressHandedToTheDelegateNamesAnAccount() {
        let queued = UUID().uuidString
        router.routeIncomingMessage(incoming(from: queued, device: deviceId(), msgNum: 0), in: context)

        XCTAssertEqual(delegate.openAddresses.map(\.account), [queued],
                       "the open path did not run — everything below would read an empty list")
        for address in delegate.openAddresses + delegate.decryptionErrorAddresses {
            XCTAssertFalse(
                SessionAddressing.isCryptoIdentity(address.account),
                "\(address) puts a device id where the key service reads an account UUID"
            )
        }
    }

}
