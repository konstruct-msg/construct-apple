//
//  SenderSyncOpensTheDeviceItNamesTests.swift
//  Construct Messenger
//
//  A SENDER_SYNC names the device that wrote it, and only that session is tried (todo/254). Real
//  core, real keys. Whether a copy was opened shows in the ratchet: a message that was read cannot
//  be read a second time, and one that was refused still can.
//

import XCTest
import CoreData
@testable import Construct_Messenger

@MainActor
final class SenderSyncOpensTheDeviceItNamesTests: XCTestCase {
    private let me = "e7a4e3d2-0000-4000-8000-0000000000aa"
    private let contactAccount = "e7a4e3d2-0000-4000-8000-0000000000bb"

    private var mine: OrchestratorCore!
    private var mineId = ""
    private var coreBefore: OrchestratorCore?
    private var savedUserId: String?
    private var router: MessageRouter!
    private var context: NSManagedObjectContext!

    override func setUp() async throws {
        try await super.setUp()
        savedUserId = AuthSessionManager.shared.currentUserId
        AuthSessionManager.shared.updateUserId(me)
        (mine, mineId) = try makeTestDevice()
        TestCertificateServer.shared.trust(in: mine)
        coreBefore = CryptoManager.shared.orchestratorCore
        CryptoManager.shared.orchestratorCore = mine

        let container = PersistenceController(inMemory: true).container
        LocalRepositories.useProcessedMessagesForTesting(CoreDataProcessedMessageStore(container: container))
        LocalRepositories.usePeerDevicesForTesting(CoreDataPeerDeviceStore(container: container))
        LocalRepositories.useContactsForTesting(container)
        LocalRepositories.useChatsForTesting(container)
        LocalRepositories.useMessagesForTesting(container)
        context = container.viewContext
        router = MessageRouter()
        router.setContext(context)
    }

    override func tearDown() async throws {
        CryptoManager.shared.orchestratorCore = coreBefore
        LocalRepositories.useProcessedMessagesForTesting(nil)
        LocalRepositories.usePeerDevicesForTesting(nil)
        LocalRepositories.useContactsForTesting(nil)
        LocalRepositories.useChatsForTesting(nil)
        LocalRepositories.useMessagesForTesting(nil)
        if let savedUserId, !savedUserId.isEmpty {
            AuthSessionManager.shared.updateUserId(savedUserId)
        }
        try await super.tearDown()
    }

    // MARK: - On the real core

    /// The control: without it every "not opened" below would pass on a handler that opens nothing.
    func testACopyFromTheDeviceItNamesIsRead() throws {
        let sibling = try deviceWithSession()
        let wire = try sibling.core.encryptToWire(contactId: mineId, plaintext: Data("copy".utf8))
        let message = try copy(wire, certifiedBy: sibling.core, account: me)
        // `routeIncomingMessage` claims a copy before it calls the handler.
        PersistentACKStore.shared.markProcessed(message.id, senderId: message.from)

        router.handleSenderSync(message, in: context)

        XCTAssertThrowsError(
            try mine.decryptWirePayload(contactId: sibling.id, wirePayload: wire),
            "read by the handler, so it cannot be read again"
        )
    }

    /// A server signs certificates and nothing checks the signature on an existing session, so it
    /// can hand back a contact's message as a copy naming the contact's device. Read that way the
    /// contact's profile or card is applied as our own.
    func testACopyNamingAContactsDeviceIsNotRead() throws {
        let contact = try deviceWithSession()
        _ = try LocalRepositories.peerDevices.record([PeerDeviceRecord(
            deviceId: contact.id,
            accountId: contactAccount,
            identityKey: Data(repeating: 7, count: 32),
            firstSeenAt: Date()
        )])
        let wire = try contact.core.encryptToWire(contactId: mineId, plaintext: Data("theirs".utf8))

        router.handleSenderSync(
            try copy(wire, certifiedBy: contact.core, account: me), in: context
        )

        XCTAssertEqual(
            try mine.decryptWirePayload(contactId: contact.id, wirePayload: wire).plaintext,
            Data("theirs".utf8),
            "the message is still the contact's to read"
        )
    }

    func testACopyCertifiedForAnotherAccountIsNotRead() throws {
        let sibling = try deviceWithSession()
        let wire = try sibling.core.encryptToWire(contactId: mineId, plaintext: Data("copy".utf8))

        router.handleSenderSync(
            try copy(wire, certifiedBy: sibling.core, account: contactAccount), in: context
        )

        XCTAssertEqual(
            try mine.decryptWirePayload(contactId: sibling.id, wirePayload: wire).plaintext,
            Data("copy".utf8)
        )
    }

    /// Nothing says which session it belongs to, so none is tried, and the drop is counted.
    func testACopyWithoutACertificateIsDroppedAndCounted() throws {
        let sibling = try deviceWithSession()
        let wire = try sibling.core.encryptToWire(contactId: mineId, plaintext: Data("copy".utf8))
        let before = PerformanceMetrics.shared.count(event: .senderSyncUnroutable)

        router.handleSenderSync(syncMessage(wire, certificate: nil), in: context)

        XCTAssertEqual(PerformanceMetrics.shared.count(event: .senderSyncUnroutable), before + 1)
        XCTAssertEqual(
            try mine.decryptWirePayload(contactId: sibling.id, wirePayload: wire).plaintext,
            Data("copy".utf8)
        )
    }

    /// The named session is the only one tried: another sibling's session is not walked to.
    func testACopyNamingOneSiblingIsNotReadByAnother() throws {
        let named = try deviceWithSession()
        let writer = try deviceWithSession()
        let wire = try writer.core.encryptToWire(contactId: mineId, plaintext: Data("copy".utf8))
        let before = PerformanceMetrics.shared.count(event: .senderSyncUnroutable)

        router.handleSenderSync(
            try copy(wire, certifiedBy: named.core, account: me), in: context
        )

        XCTAssertEqual(PerformanceMetrics.shared.count(event: .senderSyncUnroutable), before + 1)
        XCTAssertEqual(
            try mine.decryptWirePayload(contactId: writer.id, wirePayload: wire).plaintext,
            Data("copy".utf8)
        )
    }

    /// A sibling's first message opens from the certificate it carries. The app hands the core the
    /// server's keys before it opens, so the test server's key has to be among them.
    func testAFirstCopyOpensTheSessionItNames() throws {
        let trustedBefore = UserDefaults.standard.data(forKey: VeilCertFetcher.cachedBundleSigningKeyKey)
        UserDefaults.standard.set(TestCertificateServer.shared.verifyingKey, forKey: VeilCertFetcher.cachedBundleSigningKeyKey)
        defer { UserDefaults.standard.set(trustedBefore, forKey: VeilCertFetcher.cachedBundleSigningKeyKey) }
        let (sibling, siblingId) = try makeTestDevice()
        _ = try sibling.initSession(contactId: mineId, recipientBundle: try mine.pqxdhTestBundle())
        let wire = try sibling.encryptToWire(contactId: mineId, plaintext: Data("first".utf8))

        router.handleSenderSync(
            try copy(wire, certifiedBy: sibling, account: me), in: context
        )

        XCTAssertTrue(mine.hasSession(contactId: siblingId))
    }

    // MARK: - The sending side

    /// No certificate, no copy, and the ratchet has not moved for one that never went.
    func testASenderAsksForItsCertificateBeforeItEncrypts() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("ConstructMessenger/Services/Messaging/MultiDeviceSendCoordinator.swift"),
            encoding: .utf8
        )
        let function = try XCTUnwrap(source.range(of: "private func sendToDevice("))
        let body = source[function.lowerBound...]
        let certificate = try XCTUnwrap(body.range(of: "try await StealthSenderService.shared.getSenderCertificate()"))
        let encrypt = try XCTUnwrap(body.range(of: "OutboundSessionService.shared.encryptOutgoing("))
        XCTAssertLessThan(certificate.lowerBound, encrypt.lowerBound)
    }

    // MARK: - The decision

    private func origin(
        account: String?, device: String?, recordedUnder: String? = nil
    ) -> SenderSyncOrigin {
        SenderSyncOrigin.of(
            certifiedAccount: account,
            device: device,
            myUserId: me,
            myDeviceId: "this-device",
            accountOfDevice: { _ in recordedUnder }
        )
    }

    func testOurAccountAndAnotherDeviceIsThatDevice() {
        XCTAssertEqual(origin(account: me, device: "sibling"), .device("sibling"))
        XCTAssertEqual(origin(account: me, device: "sibling", recordedUnder: me), .device("sibling"))
    }

    func testNoCertificateNamesNobody() {
        XCTAssertEqual(origin(account: nil, device: nil), .unnamed)
        XCTAssertEqual(origin(account: me, device: ""), .unnamed)
    }

    func testAnotherAccountIsNotOurs() {
        XCTAssertEqual(origin(account: contactAccount, device: "sibling"), .notOurs)
    }

    func testADeviceRecordedUnderAnotherAccountIsNotOurs() {
        XCTAssertEqual(origin(account: me, device: "contact", recordedUnder: contactAccount), .notOurs)
    }

    func testThisDeviceIsNotASibling() {
        XCTAssertEqual(origin(account: me, device: "this-device"), .notOurs)
    }

    // MARK: - Helpers

    /// A device whose messages to `mine` carry no handshake header any more: both sides have spoken.
    private func deviceWithSession() throws -> (core: OrchestratorCore, id: String) {
        let (peer, peerId) = try makeTestDevice()
        _ = try peer.initSession(contactId: mineId, recipientBundle: try mine.pqxdhTestBundle())
        let first = try peer.encryptToWire(contactId: mineId, plaintext: Data("first".utf8))
        _ = try mine.pqxdhTestReceive(from: peer, first: first)
        let reply = try mine.encryptToWire(contactId: peerId, plaintext: Data("reply".utf8))
        _ = try peer.decryptWirePayload(contactId: mineId, wirePayload: reply)
        return (peer, peerId)
    }

    private func copy(_ wire: Data, certifiedBy device: OrchestratorCore, account: String) throws -> ChatMessage {
        syncMessage(wire, certificate: try TestCertificateServer.shared.certificate(for: device, account: account))
    }

    private func syncMessage(_ wire: Data, certificate: SenderCertificate?) -> ChatMessage {
        ChatMessage(
            id: UUID().uuidString,
            from: me,
            to: me,
            timestamp: UInt64(Date().timeIntervalSince1970),
            contentType: Shared_Proto_Core_V1_ContentType.senderSync.byte,
            senderDeviceId: certificate?.deviceId ?? "",
            senderCertificate: certificate,
            rawPayload: wire
        )
    }
}
