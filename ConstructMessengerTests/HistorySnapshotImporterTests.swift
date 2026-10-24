//
//  HistorySnapshotImporterTests.swift
//  ConstructMessengerTests
//
//  Additive import through the core's projection and the repositories. A second pass must not
//  change row counts or bodies. Chat identity is other_user_id, never the offering device's
//  Chat.id. The merge rules themselves are tested in construct-core (history::project).
//
//  Everything is arranged and read through the repositories, so the same cases run on Core Data
//  and on the crate (`LocalStoreHistorySnapshotImporterTests`) — a Desktop that links to a phone
//  takes its history on the crate.
//

import CoreData
import SwiftProtobuf
import XCTest
@testable import Construct_Messenger

class HistorySnapshotImporterTests: XCTestCase {

    private var container: NSPersistentContainer!

    private let local = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    private let peer = "11111111-2222-4333-8444-555555555555"
    private let messageId = "cccccccc-dddd-4eee-8fff-000000000001"

    override func setUp() {
        super.setUp()
        installStores()
        MessageDisplayCache.shared.evictAll()
    }

    /// The repositories the importer writes through. Core Data here; the crate in the subclass.
    func installStores() {
        container = PersistenceController(inMemory: true).container
        LocalRepositories.usePeerDevicesForTesting(CoreDataPeerDeviceStore(container: container))
        LocalRepositories.useContactsForTesting(container)
        LocalRepositories.useChatsForTesting(container)
        LocalRepositories.useMessagesForTesting(container)
        LocalRepositories.useReactionsForTesting(container)
        LocalRepositories.useCallsForTesting(container)
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
        let body1 = try XCTUnwrap(fetchMessage(messageId)).body
        XCTAssertEqual(try counts(), Counts(people: 1, chats: 1, messages: 1))

        let second = try importAll(records)
        XCTAssertEqual(second.conflictKeepExisting, 1) // message
        XCTAssertEqual(try counts(), Counts(people: 1, chats: 1, messages: 1))
        XCTAssertEqual(try fetchMessage(messageId)?.body, body1)
    }

    // MARK: - Chat upsert

    /// A mute is not carried: no client reads one, and `ChatRecord` has no field for it.
    func testChatUpsertKeepsReceiverChatIdAndAppliesPin() throws {
        var user = ContactRecord.new(id: peer, isContact: true, addedAt: Date())
        user.displayName = "Peer"
        try LocalRepositories.contacts.insert(user)
        let existing = try LocalRepositories.chats.openChat(withPeer: peer, now: nil).chat

        var chat = Construct_Client_History_V1_HistoryChat()
        chat.otherUserID = try XCTUnwrap(HistoryAccountID.raw(peer))
        chat.isPinned = true
        chat.isMuted = true
        XCTAssertEqual(try importAll([record(HistoryRecordType.chat, try chat.serializedData())]).applied, 1)

        let chats = try LocalRepositories.chats.chats()
        XCTAssertEqual(chats.count, 1)
        XCTAssertEqual(chats[0].id, existing.id)
        XCTAssertTrue(chats[0].isPinned)
        XCTAssertEqual(chats[0].unreadCount, 0)
    }

    // MARK: - Conflict

    func testLiveMessageIsNotOverwritten() throws {
        try LocalRepositories.contacts.insert(.new(id: peer, isContact: true, addedAt: nil))
        let chat = try LocalRepositories.chats.openChat(withPeer: peer, now: nil).chat
        _ = try LocalRepositories.messages.insert(MessageRecord(
            id: messageId, chatId: chat.id, fromUserId: local, toUserId: peer, isSentByMe: true,
            timestamp: Date(), orderKey: "k1", body: LocalMessagePayload.encodeText("live body"),
            contentType: .regular, deliveryStatus: .sent, retryCount: 0, suiteId: 4, isEdited: false,
            editedAt: nil, replyToMessageId: nil, replyQuote: nil, transcript: nil,
            transcriptLanguage: nil, transcriptGeneratedAt: nil
        ), searchText: "live body")

        var msg = try textMessage(id: messageId, text: "snapshot body")
        msg.isSentByMe = true
        XCTAssertEqual(try importAll([record(HistoryRecordType.message, try msg.serializedData())]).conflictKeepExisting, 1)
        XCTAssertEqual(try payloadString(of: messageId), "live body")
    }

    // MARK: - Share flags

    func testShareFlagDoesNotClobberProfileTrue() throws {
        var user = ContactRecord.new(id: peer, isContact: true, addedAt: Date())
        user.username = ""
        user.displayName = "Peer"
        user.amISharingWith = true
        user.isSharingWithMe = true
        try LocalRepositories.contacts.insert(user)

        var contact = Construct_Client_History_V1_HistoryContact()
        contact.userID = try XCTUnwrap(HistoryAccountID.raw(peer))
        contact.displayName = "Offering name"
        contact.username = "offered"
        contact.amISharingWith = false
        contact.isSharingWithMe = false
        contact.isContact = false
        _ = try importAll([record(HistoryRecordType.contact, try contact.serializedData())])

        let row = try XCTUnwrap(LocalRepositories.contacts.contact(peer))
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
        XCTAssertEqual(try LocalRepositories.reactions.allReactions().count, 0)
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
        XCTAssertEqual(try LocalRepositories.reactions.allReactions().count, 1)
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
        let chat = try XCTUnwrap(LocalRepositories.chats.chats().first)
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
        try HistorySnapshotImporter(expectedUserId: local).importRecords(records)
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

    private struct Counts: Equatable {
        let people: Int
        let chats: Int
        let messages: Int
    }

    private func counts() throws -> Counts {
        Counts(
            people: try LocalRepositories.contacts.everyContact(except: nil).count,
            chats: try LocalRepositories.chats.chats().count,
            messages: try LocalRepositories.messages.allMessages(after: nil, limit: 1_000).count
        )
    }

    private func fetchMessage(_ id: String) throws -> MessageRecord? {
        try LocalRepositories.messages.message(id)
    }

    private func payloadString(of id: String) throws -> String? {
        try XCTUnwrap(fetchMessage(id)).payload.plainText
    }
}

/// The same cases on the crate: what a Desktop linked to a phone runs.
final class LocalStoreHistorySnapshotImporterTests: HistorySnapshotImporterTests {
    override func installStores() {
        LocalRepositories.useLocalStoreForTesting(.inMemoryForTesting())
    }

    override func tearDown() {
        LocalRepositories.useLocalStoreForTesting(nil)
        super.tearDown()
    }
}
