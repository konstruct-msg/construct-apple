//
//  LocalStoreImportTests.swift
//  ConstructMessengerTests
//
//  The one-time move of an iOS install from Core Data to `construct.db` (LOCAL_STORE_MIGRATION_PLAN
//  step 4). Every domain is seeded on an in-memory Core Data container, imported into an
//  in-memory store, and read back through the store's own repositories.
//

import XCTest
import CoreData
@testable import Construct_Messenger

final class LocalStoreImportTests: XCTestCase {

    private var container: NSPersistentContainer!
    private var defaults: UserDefaults!
    private var suite: String!
    private var chunkRoot: URL!
    private var source: LocalRepositories.Backing!
    private var session: LocalStoreSession!
    private var destination: LocalRepositories.Backing!

    /// Sub-millisecond on purpose: Core Data keeps it, the store does not, and the check must
    /// not call that a lost row.
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000.123456)

    override func setUpWithError() throws {
        container = PersistenceController(inMemory: true).container
        suite = "LocalStoreImportTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        chunkRoot = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let contacts = CoreDataContactStore(container: container)
        source = LocalRepositories.Backing(
            peerDevices: CoreDataPeerDeviceStore(container: container),
            serverMessageIds: CoreDataServerMessageIdStore(container: container),
            contacts: contacts, ownProfile: contacts,
            chats: CoreDataChatStore(container: container),
            messages: CoreDataMessageStore(container: container),
            reactions: CoreDataReactionStore(container: container),
            processedMessages: CoreDataProcessedMessageStore(container: container),
            calls: CoreDataCallStore(container: container),
            pendingChunks: FilePendingChunkStore(root: chunkRoot),
            keyValue: DefaultsKeyValueStore(defaults: defaults),
            issuedInvites: DefaultsIssuedInviteStore(defaults: defaults)
        )
        session = LocalStoreSession.inMemoryForTesting()
        destination = .localStore(session)
    }

    override func tearDownWithError() throws {
        UserDefaults().removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: chunkRoot)
    }

    private func contact(_ id: String, isContact: Bool = true) -> ContactRecord {
        ContactRecord(
            id: id, username: "u-\(id)", displayName: "Name \(id)", localAlias: "alias",
            avatar: Data([1, 2]), knownIdentityKey: Data(repeating: 7, count: 32), accountAddress: Data([3]),
            isContact: isContact, isBlocked: false, isSharingWithMe: true, amISharingWith: true,
            sharedWithMeAt: t0, addedAt: t0, ktStatus: .verified, securityNotice: .addressChanged,
            profileEditedAtMs: 42, pendingAvatarRef: nil, pendingAvatarSince: nil
        )
    }

    private func message(_ i: Int, chat: String, peer: String) -> MessageRecord {
        MessageRecord(
            id: String(format: "00000000-0000-0000-0000-%012d", i), chatId: chat,
            fromUserId: i.isMultiple(of: 2) ? "me" : peer, toUserId: i.isMultiple(of: 2) ? peer : "me",
            isSentByMe: i.isMultiple(of: 2), timestamp: t0.addingTimeInterval(Double(i)),
            orderKey: String(format: "k%08d", i), body: LocalMessagePayload.encodeText("message \(i)"),
            contentType: .regular, deliveryStatus: i.isMultiple(of: 3) ? .sent : .delivered,
            retryCount: Int16(i % 2), suiteId: 4, isEdited: i == 5, editedAt: i == 5 ? t0 : nil,
            replyToMessageId: nil, replyQuote: nil, transcript: nil, transcriptLanguage: nil,
            transcriptGeneratedAt: nil
        )
    }

    /// More messages than one page, in two chats, plus a row in every other domain.
    private func seed(messages count: Int = 450) throws -> LocalStoreImport.Extras {
        try source.ownProfile.save(OwnProfileRecord(accountId: "me", username: "me", displayName: "Me", avatar: Data([9]), profileEditedAtMs: 7))
        try source.contacts.insert(contact("peer-a"))
        try source.contacts.insert(contact("peer-b", isContact: false))
        _ = try source.peerDevices.record([PeerDeviceRecord(deviceId: "dev-a", accountId: "peer-a", identityKey: Data(repeating: 1, count: 32), firstSeenAt: t0)])
        let chatA = ChatRecord(id: "chat-a", peerId: "peer-a", lastMessageText: "hi", lastMessageTime: t0, isPinned: true, unreadCount: 3)
        let chatB = ChatRecord(id: "chat-b", peerId: "peer-b", lastMessageText: nil, lastMessageTime: nil, isPinned: false, unreadCount: 0)
        try source.chats.insert(chatA)
        try source.chats.insert(chatB)
        try source.messages.insert((0..<count).map {
            (message: message($0, chat: $0 < count / 2 ? "chat-a" : "chat-b", peer: $0 < count / 2 ? "peer-a" : "peer-b"), searchText: nil)
        })
        try source.reactions.upsert(ReactionRecord(targetMessageId: message(1, chat: "", peer: "").id, reactorUserId: "peer-a", emoji: "🔥", timestampMs: 5, receivedAt: t0))
        try source.calls.upsert(CallRecord(id: "call-1", peerUserId: "peer-a", peerName: "A", direction: .incoming, status: .completed, startedAt: t0, endedAt: t0.addingTimeInterval(60), durationSeconds: 60))
        _ = try source.processedMessages.markProcessed("processed-1", senderId: "peer-a", at: t0)
        try source.serverMessageIds.record(serverId: "SERVER-1", localId: "LOCAL-1", at: t0)
        _ = try source.pendingChunks.add(PendingChunkRecord(senderId: "peer-a", messageId: "6f9619ff-8b86-d011-b42d-00cf4fc964ff", chunkIndex: 0, totalChunks: 2, plaintextLength: 8, contentType: 1, payload: Data([4, 4]), receivedAt: t0))
        try source.keyValue.put(FanoutRetryQueue.storageKey, Data("[]".utf8))
        try source.issuedInvites.record(IssuedInviteRecord(jti: "jti-1", kind: "qr", issuedAt: t0, ttlSeconds: 600, sitting: "s"))
        return LocalStoreImport.coreDataExtras(container, ownAccountId: "me")
    }

    func testEveryDomainArrivesAndTheStoreIsMarkedComplete() throws {
        let extras = try seed()
        XCTAssertFalse(LocalStoreImport.isComplete(destination))

        var reported: [Double] = []
        let counts = try LocalStoreImport.run(from: source, extras: extras, into: destination) { reported.append($0) }

        XCTAssertEqual(counts, LocalStoreImport.Counts(
            contacts: 2, peerDevices: 1, chats: 2, messages: 450, reactions: 1, calls: 1,
            processed: 1, serverIds: 1, pendingChunks: 1, keyValues: 1, invites: 1, ownProfile: true
        ))
        XCTAssertTrue(LocalStoreImport.isComplete(destination))
        XCTAssertEqual(reported.first, 0)
        XCTAssertEqual(reported.last, 1)

        // Read back through the store's repositories, the way the app will.
        XCTAssertEqual(try destination.chats.chat("chat-a")?.unreadCount, 3, "unread and pin come as they were")
        XCTAssertEqual(try destination.chats.chat("chat-a")?.isPinned, true)
        XCTAssertEqual(try destination.messages.message(message(5, chat: "", peer: "").id)?.isEdited, true)
        XCTAssertEqual(try destination.messages.message(message(3, chat: "", peer: "").id)?.deliveryStatus, .sent,
                       "a status is copied as it was, not replayed through the live write path")
        XCTAssertTrue(try destination.processedMessages.isProcessed("processed-1"),
                      "without it an import would process again what was already processed")
        XCTAssertEqual(try destination.serverMessageIds.localId(forServerId: "server-1"), "local-1")
        XCTAssertEqual(try destination.contacts.contact("peer-b")?.isContact, false)
        XCTAssertEqual(try destination.ownProfile.profile(accountId: "me")?.displayName, "Me")
        XCTAssertNil(try destination.contacts.contact("me"), "our own profile is not a contact in the store")
        XCTAssertNotNil(try destination.keyValue.get(FanoutRetryQueue.storageKey))
    }

    /// The search index is filled from the body, as the receive path fills it.
    func testImportedMessagesAreSearchable() throws {
        _ = try LocalStoreImport.run(from: source, extras: try seed(messages: 10), into: destination)
        XCTAssertFalse(try session.store.search(query: "message", limit: 50).isEmpty)
    }

    /// A row the copy did not carry — here one written to the source while the import runs,
    /// which the launch gate exists to prevent — is caught by the read-back, and the store is not
    /// marked complete: the next launch wipes it and tries again instead of running on it.
    func testARowTheCopyMissedFailsTheCheckAndLeavesTheStoreUnmarked() throws {
        let extras = try seed(messages: 450)
        var wrote = false
        XCTAssertThrowsError(try LocalStoreImport.run(from: source, extras: extras, into: destination) { done in
            // After the first page, not at 0: that is reported before anything is copied.
            guard done > 0, !wrote else { return }
            wrote = true
            // Ordered before the cursor: the copy has already passed where it belongs.
            var late = self.message(9_999, chat: "chat-a", peer: "peer-a")
            late = MessageRecord(
                id: late.id, chatId: late.chatId, fromUserId: late.fromUserId, toUserId: late.toUserId,
                isSentByMe: late.isSentByMe, timestamp: late.timestamp, orderKey: "a-first", body: late.body,
                contentType: late.contentType, deliveryStatus: late.deliveryStatus, retryCount: 0, suiteId: 4,
                isEdited: false, editedAt: nil, replyToMessageId: nil, replyQuote: nil, transcript: nil,
                transcriptLanguage: nil, transcriptGeneratedAt: nil
            )
            _ = try? self.source.messages.insert(late, searchText: nil)
        }) {
            guard case LocalStoreImport.Failure.mismatch = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertFalse(LocalStoreImport.isComplete(destination))
    }

    /// An empty install imports nothing and is still marked — no screen on a fresh install.
    func testAnEmptySourceIsMarkedComplete() throws {
        let counts = try LocalStoreImport.run(
            from: source, extras: LocalStoreImport.coreDataExtras(container, ownAccountId: nil), into: destination
        )
        XCTAssertEqual(counts, LocalStoreImport.Counts())
        XCTAssertTrue(LocalStoreImport.isComplete(destination))
    }
}
