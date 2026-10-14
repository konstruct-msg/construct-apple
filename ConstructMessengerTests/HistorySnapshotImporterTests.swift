//
//  HistorySnapshotImporterTests.swift
//  ConstructMessengerTests
//
//  Additive import through the core's projection and the repositories. A second pass must not
//  change row counts or bodies. Chat identity is other_user_id, never the offering device's
//  Chat.id. The merge rules themselves are tested in construct-core (history::project).
//

import CoreData
import SwiftProtobuf
import XCTest
@testable import Construct_Messenger

final class HistorySnapshotImporterTests: XCTestCase {

    private var container: NSPersistentContainer!
    private var context: NSManagedObjectContext { container.viewContext }

    private let local = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    private let peer = "11111111-2222-4333-8444-555555555555"
    private let messageId = "cccccccc-dddd-4eee-8fff-000000000001"

    override func setUp() {
        super.setUp()
        container = PersistenceController(inMemory: true).container
        LocalRepositories.usePeerDevicesForTesting(CoreDataPeerDeviceStore(container: container))
        LocalRepositories.useContactsForTesting(container)
        LocalRepositories.useChatsForTesting(container)
        LocalRepositories.useMessagesForTesting(container)
        LocalRepositories.useReactionsForTesting(container)
        LocalRepositories.useCallsForTesting(container)
        MessageDisplayCache.shared.evictAll()
    }

    override func tearDown() {
        LocalRepositories.usePeerDevicesForTesting(nil)
        LocalRepositories.useContactsForTesting(nil)
        LocalRepositories.useChatsForTesting(nil)
        LocalRepositories.useMessagesForTesting(nil)
        LocalRepositories.useReactionsForTesting(nil)
        LocalRepositories.useCallsForTesting(nil)
        MessageDisplayCache.shared.evictAll()
        container = nil
        super.tearDown()
    }

    // MARK: - Twice

    func testImportTwiceLeavesRowCountsAndBodiesIdentical() throws {
        let records = try transcript(text: "hello snapshot")
        let first = try importAll(records)
        XCTAssertEqual(first.applied, 3) // contact + chat + message
        let body1 = try XCTUnwrap(payload(of: messageId))
        let users1 = try count("User")
        let chats1 = try count("Chat")
        let messages1 = try count("Message")

        let second = try importAll(records)
        XCTAssertEqual(second.conflictKeepExisting, 1) // message
        XCTAssertEqual(try count("User"), users1)
        XCTAssertEqual(try count("Chat"), chats1)
        XCTAssertEqual(try count("Message"), messages1)
        XCTAssertEqual(try payload(of: messageId), body1)
    }

    // MARK: - Chat upsert

    func testChatUpsertKeepsReceiverChatIdAndAppliesPin() throws {
        let user = User(context: context)
        user.id = peer
        user.username = ""
        user.displayName = "Peer"
        user.isContact = true
        user.addedAt = Date()
        let existing = Chat(context: context)
        existing.id = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        existing.otherUser = user
        existing.isPinned = false
        existing.isMuted = false
        existing.unreadCount = 0
        try context.save()

        var chat = Construct_Client_History_V1_HistoryChat()
        chat.otherUserID = try XCTUnwrap(HistoryAccountID.raw(peer))
        chat.isPinned = true
        chat.isMuted = true
        XCTAssertEqual(try importAll([record(HistoryRecordType.chat, try chat.serializedData())]).applied, 1)
        context.refreshAllObjects()

        let chats = try context.fetch(Chat.fetchRequest())
        XCTAssertEqual(chats.count, 1)
        XCTAssertEqual(chats[0].id, "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
        XCTAssertTrue(chats[0].isPinned)
        XCTAssertFalse(chats[0].isMuted, "a mute is not carried: no client reads one")
        XCTAssertEqual(chats[0].unreadCount, 0)
        XCTAssertNil(chats[0].sessionId)
    }

    // MARK: - Conflict

    func testLiveMessageIsNotOverwritten() throws {
        try LocalRepositories.contacts.insert(.new(id: peer, isContact: true, addedAt: nil))
        _ = try LocalRepositories.chats.openChat(withPeer: peer, now: nil)
        let live = Message(context: context)
        live.id = messageId
        live.fromUserId = local
        live.toUserId = peer
        live.timestamp = Date()
        live.isSentByMe = true
        live.retryCount = 0
        live.encryptedContent = Data()
        live.applyStoredEncryption(plaintext: "live body", contactId: peer)
        try context.save()

        var msg = try textMessage(id: messageId, text: "snapshot body")
        msg.isSentByMe = true
        XCTAssertEqual(try importAll([record(HistoryRecordType.message, try msg.serializedData())]).conflictKeepExisting, 1)
        XCTAssertEqual(try payloadString(of: messageId), "live body")
    }

    // MARK: - Share flags

    func testShareFlagDoesNotClobberProfileTrue() throws {
        let user = User(context: context)
        user.id = peer
        user.username = ""
        user.displayName = "Peer"
        user.amISharingWith = true
        user.isSharingWithMe = true
        user.isContact = true
        user.addedAt = Date()
        try context.save()

        var contact = Construct_Client_History_V1_HistoryContact()
        contact.userID = try XCTUnwrap(HistoryAccountID.raw(peer))
        contact.displayName = "Offering name"
        contact.username = "offered"
        contact.amISharingWith = false
        contact.isSharingWithMe = false
        contact.isContact = false
        _ = try importAll([record(HistoryRecordType.contact, try contact.serializedData())])
        context.refreshAllObjects()

        let row = try XCTUnwrap(context.fetch(User.fetchRequest()).first { $0.id == peer })
        XCTAssertTrue(row.amISharingWith)
        XCTAssertTrue(row.isSharingWithMe)
        XCTAssertTrue(row.isContact)
        XCTAssertEqual(row.displayName, "Peer")
        // Mutation: skip writing the merged row back — the empty username stays empty.
        XCTAssertEqual(row.username, "offered", "an empty field is filled")
    }

    // MARK: - Hint / media / reaction

    func testBadPeerHintIsDropped() throws {
        var hint = Construct_Client_History_V1_HistoryPeerDevice()
        hint.accountID = try XCTUnwrap(HistoryAccountID.raw(peer))
        hint.deviceID = String(repeating: "0", count: 32)
        hint.identityKey = Data(repeating: 0x11, count: 32)
        XCTAssertEqual(try importAll([record(HistoryRecordType.peer, try hint.serializedData())]).skipped[.hintDroppedBadId], 1)
        XCTAssertEqual(try LocalRepositories.peerDevices.allDevices().count, 0)
    }

    func testMediaAlreadyPresentIsNotRewritten() throws {
        let mediaId = "hist-media-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: MediaManager.onDiskURL(for: mediaId)) }
        XCTAssertTrue(MediaManager.importHistoryBlob(Data("first".utf8), mediaId: mediaId))

        let sink = HistoryMediaSink()
        XCTAssertEqual(try sink.start(mediaId: mediaId), .skipped(.mediaAlreadyPresent))
        try sink.append(Data("second".utf8))
        XCTAssertEqual(try sink.end(), .ignored)
        XCTAssertEqual(MediaManager.loadOnDisk(mediaId: mediaId), Data("first".utf8))
    }

    func testReactionWithoutTargetIsSkipped() throws {
        var reaction = Construct_Client_History_V1_HistoryReaction()
        reaction.targetMessageID = messageId
        reaction.reactorUserID = try XCTUnwrap(HistoryAccountID.raw(peer))
        reaction.emoji = "🔥"
        reaction.timestampMs = 1
        XCTAssertEqual(
            try importAll([record(HistoryRecordType.reaction, try reaction.serializedData())]).skipped[.reactionTargetMissing], 1
        )
        XCTAssertEqual(try context.fetch(Reaction.fetchRequest()).count, 0)
    }

    /// A reaction in the same stream as its message lands: the messages waiting are written
    /// before the reaction asks for its target. Mutation: drop `writePending()` before a
    /// reaction — it is skipped as targetless.
    func testAReactionAfterItsMessageInOneStreamLands() throws {
        var reaction = Construct_Client_History_V1_HistoryReaction()
        reaction.targetMessageID = messageId
        reaction.reactorUserID = try XCTUnwrap(HistoryAccountID.raw(peer))
        reaction.emoji = "🔥"
        reaction.timestampMs = 1
        var records = try transcript(text: "x")
        records.append(record(HistoryRecordType.reaction, try reaction.serializedData()))
        let summary = try importAll(records)
        XCTAssertNil(summary.skipped[.reactionTargetMissing])
        XCTAssertEqual(try context.fetch(Reaction.fetchRequest()).count, 1)
    }

    /// The chat's preview moves to the newest message imported, whatever the order. Mutation:
    /// keep the first message of the batch — the older one is the preview.
    func testThePreviewIsTheNewestImportedMessage() throws {
        var newer = try textMessage(id: "cccccccc-dddd-4eee-8fff-000000000002", text: "newer")
        newer.timestampUnixMs = 1_700_000_900_000
        var older = try textMessage(id: "cccccccc-dddd-4eee-8fff-000000000003", text: "older")
        older.timestampUnixMs = 1_700_000_100_000
        var records = Array(try transcript(text: "first").dropLast())
        // The older first: "the first of the batch" and "the newest" must not be the same one.
        records.append(record(HistoryRecordType.message, try older.serializedData()))
        records.append(record(HistoryRecordType.message, try newer.serializedData()))
        _ = try importAll(records)
        let chat = try XCTUnwrap(context.fetch(Chat.fetchRequest()).first)
        XCTAssertEqual(chat.lastMessageText, "newer")
    }

    func testOwnImportedMessageIsSentNotDelivered() throws {
        _ = try importAll(try transcript(text: "own"))
        let row = try XCTUnwrap(fetchMessage(messageId))
        XCTAssertEqual(row.deliveryStatus, .sent)
        XCTAssertNotEqual(row.deliveryStatus, .sending)
    }

    // MARK: - Source / entity list

    func testImporterSourceDoesNotMentionForbiddenCarriers() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ConstructMessenger/Services/HistorySync/HistorySnapshotImporter.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        for needle in ["import_session", "StreamCursorStore", "pending_restore", "wipeLocalStoreContents"] {
            XCTAssertFalse(source.contains(needle), needle)
        }
    }

    func testImportedEntitiesAreInUserDataEntityNames() {
        for name in ["Message", "Chat", "User", "Reaction", "PeerDevice", "CallRecord"] {
            XCTAssertTrue(
                AuthViewModel.userDataEntityNames.contains(name),
                "\(name) is written by the importer and must be wiped with the account"
            )
        }
    }

    // MARK: - Builders

    private func transcript(text: String) throws -> [HistoryRecord] {
        var manifest = Construct_Client_History_V1_HistoryManifest()
        manifest.formatVersion = 1
        manifest.phase = 1
        manifest.userID = try XCTUnwrap(HistoryAccountID.raw(local))
        manifest.snapshotID = Data(repeating: 0xAA, count: 16)

        var contact = Construct_Client_History_V1_HistoryContact()
        contact.userID = try XCTUnwrap(HistoryAccountID.raw(peer))
        contact.displayName = "Peer"
        contact.isContact = true

        var chat = Construct_Client_History_V1_HistoryChat()
        chat.otherUserID = try XCTUnwrap(HistoryAccountID.raw(peer))

        var msg = try textMessage(id: messageId, text: text)
        msg.isSentByMe = true

        return [
            .manifest(manifest),
            record(HistoryRecordType.contact, try contact.serializedData()),
            record(HistoryRecordType.chat, try chat.serializedData()),
            record(HistoryRecordType.message, try msg.serializedData()),
        ]
    }

    private func record(_ type: UInt8, _ proto: Data) -> HistoryRecord {
        .transcript(type: type, proto: proto)
    }

    private func importAll(_ records: [HistoryRecord]) throws -> HistoryImportSummary {
        let summary = try HistorySnapshotImporter(expectedUserId: local).importRecords(records)
        context.refreshAllObjects()
        return summary
    }

    private func textMessage(id: String, text: String) throws -> Construct_Client_History_V1_HistoryMessage {
        var body = Shared_Proto_Messaging_V1_TextMessage()
        body.text = text
        var content = Shared_Proto_Messaging_V1_MessageContent()
        content.text = body
        var msg = Construct_Client_History_V1_HistoryMessage()
        msg.id = id
        msg.fromUserID = try XCTUnwrap(HistoryAccountID.raw(local))
        msg.toUserID = try XCTUnwrap(HistoryAccountID.raw(peer))
        msg.timestampUnixMs = 1_700_000_000_000
        msg.body = .messageContent(content)
        return msg
    }

    private func count(_ entity: String) throws -> Int {
        let req = NSFetchRequest<NSFetchRequestResult>(entityName: entity)
        return try context.count(for: req)
    }

    private func fetchMessage(_ id: String) throws -> Construct_Messenger.Message? {
        let req = Message.fetchRequest()
        req.predicate = NSPredicate(format: "id == %@", id)
        req.fetchLimit = 1
        return try context.fetch(req).first
    }

    private func payload(of id: String) throws -> Data {
        MessageDisplayCache.shared.payloadData(for: try XCTUnwrap(fetchMessage(id)))
    }

    private func payloadString(of id: String) throws -> String {
        try XCTUnwrap(fetchMessage(id)).legacyBody
    }
}
