//
//  HistorySnapshotEncoderTests.swift
//  ConstructMessengerTests
//
//  Encoder fixtures from spec §2. Output is wire plaintext, never CTM1,
//  never the named omissions.
//

import CoreData
import SwiftProtobuf
import XCTest
@testable import Construct_Messenger

/// `@MainActor` because every test here works on `container.viewContext`, which belongs to the
/// main queue. Without it the `async` test bodies ran on a cooperative-pool thread and fetched and
/// saved that context off its queue; Core Data answers that with whatever the main queue happens
/// to be doing at the moment — Cocoa 133010 "references outside of their own stores", or
/// "_referenceData64 only defined for abstract class" on a temporary object id. That was TODO 120:
/// it failed in full runs, where the main queue was busy, and passed alone.
@MainActor
final class HistorySnapshotEncoderTests: XCTestCase {

    private var container: NSPersistentContainer!
    /// Mutation: drop `@MainActor` from the class — every test fails here instead of one in
    /// several full runs failing somewhere inside Core Data.
    private var context: NSManagedObjectContext {
        XCTAssertTrue(Thread.isMainThread, "viewContext used off the main queue — see the class comment")
        return container.viewContext
    }

    private let local = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    private let peer = "11111111-2222-4333-8444-555555555555"
    private let leakSession = "SESSION-ID-MUST-NOT-LEAK"
    private let leakPublicKey = "PUBLIC-KEY-MUST-NOT-LEAK"
    private let leakIdentity = Data(repeating: 0xAB, count: 32)

    private var identity: HistorySnapshotIdentity {
        HistorySnapshotIdentity(
            userId: local,
            sourceDeviceId: String(repeating: "ab", count: 16),
            snapshotId: Data(repeating: 0xAA, count: 16),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            appVersion: "test"
        )
    }

    override func setUp() {
        super.setUp()
        container = PersistenceController(inMemory: true).container
        LocalRepositories.usePeerDevicesForTesting(CoreDataPeerDeviceStore(container: container))
        MessageDisplayCache.shared.evictAll()
    }

    override func tearDown() {
        LocalRepositories.usePeerDevicesForTesting(nil)
        MessageDisplayCache.shared.evictAll()
        container = nil
        super.tearDown()
    }

    // MARK: - Five fixture rows

    func testFiveFixtureRowsAreClassified() async throws {
        try seedFiveFixtures()
        let encoder = HistorySnapshotEncoder(identity: identity)
        let records = try await collect(encoder.encodeTranscript(context: context)).records
        let messages = records.compactMap { rec -> Construct_Client_History_V1_HistoryMessage? in
            if case .message(let m) = rec { return m }
            return nil
        }
        XCTAssertEqual(messages.count, 2, "normal + legacy text; the other three are skipped")
        XCTAssertEqual(encoder.counters.messageControlSkipped, 1)
        XCTAssertEqual(encoder.counters.messageUndecryptable, 1)
        XCTAssertEqual(encoder.counters.messageLegacyUnconvertible, 1)

        let texts = messages.compactMap { msg -> String? in
            guard case .messageContent(let content)? = msg.body,
                  case .text(let t)? = content.content else { return nil }
            return t.text
        }
        XCTAssertTrue(texts.contains("normal"))
        XCTAssertTrue(texts.contains("legacy text"))
    }

    func testEmittedBytesContainNoCTM1AndNoOmittedSecrets() async throws {
        try seedFiveFixtures()
        let encoder = HistorySnapshotEncoder(identity: identity)
        let records = try await collect(encoder.encodeTranscript(context: context)).records
        // What reaches the core: each record's protobuf bytes.
        let bytes = try records.map { try $0.wire().proto }.reduce(Data(), +)
        XCTAssertNil(bytes.range(of: Data("CTM1".utf8)), "wire body is proto, not the iOS envelope")
        XCTAssertNil(bytes.range(of: Data(leakSession.utf8)))
        XCTAssertNil(bytes.range(of: Data(leakPublicKey.utf8)))
        XCTAssertNil(bytes.range(of: leakIdentity))
    }

    func testPhase1StreamHasNoMediaBlob() async throws {
        try seedFiveFixtures()
        let encoder = HistorySnapshotEncoder(identity: identity)
        let out = try await collect(encoder.encodeTranscript(context: context))
        XCTAssertTrue(out.records.contains { if case .manifest = $0 { return true }; return false })
        XCTAssertEqual(out.media, [])
    }

    func testPhase2StreamIsManifestMediaEnd() async throws {
        let mediaId = "hist-enc-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: MediaManager.onDiskURL(for: mediaId)) }
        XCTAssertTrue(MediaManager.importHistoryBlob(Data("tiny".utf8), mediaId: mediaId))
        try seedAlbumMessage(mediaId: mediaId)

        let encoder = HistorySnapshotEncoder(identity: identity)
        let out = try await collect(encoder.encodeMedia(context: context))
        guard case .manifest(let manifest) = out.records.first else {
            return XCTFail("phase 2 must start with a manifest")
        }
        XCTAssertEqual(manifest.phase, 2)
        XCTAssertEqual(out.records.count, 1, "phase 2 carries no transcript record")
        XCTAssertEqual(out.media, [mediaId], "the media file, by reference")
    }

    func testOversizedMediaIsCountedAndStreamCompletes() async throws {
        let mediaId = "hist-huge-\(UUID().uuidString)"
        let url = MediaManager.onDiskURL(for: mediaId)
        defer { try? FileManager.default.removeItem(at: url) }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: historyMaxBlobBytes() + 1)
        try handle.close()

        try seedAlbumMessage(mediaId: mediaId)
        let encoder = HistorySnapshotEncoder(identity: identity)
        let out = try await collect(encoder.encodeMedia(context: context))
        XCTAssertEqual(encoder.counters.mediaTooLarge, 1)
        XCTAssertEqual(out.media, [], "left out, not sent to fail the stream")
    }

    func testRoundTripEncodeImportEncode() async throws {
        let mediaId = "hist-rt-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: MediaManager.onDiskURL(for: mediaId)) }
        XCTAssertTrue(MediaManager.importHistoryBlob(Data("photo".utf8), mediaId: mediaId))

        try seedRoundTripStore(mediaId: mediaId)
        let encoderA = HistorySnapshotEncoder(identity: identity)
        let fromA = try await collect(encoderA.encodeAll(context: context))

        let storeB = PersistenceController(inMemory: true).container
        let contextB = storeB.viewContext
        // Device B's own peer-device table, or B would re-encode A's hints and prove nothing.
        LocalRepositories.usePeerDevicesForTesting(CoreDataPeerDeviceStore(container: storeB))
        _ = try HistorySnapshotImporter().importRecords(fromA.records, expectedUserId: local, in: contextB)

        let encoderB = HistorySnapshotEncoder(identity: identity)
        let fromB = try await collect(encoderB.encodeAll(context: contextB))

        XCTAssertEqual(try fingerprints(fromA.records), try fingerprints(fromB.records))
        XCTAssertEqual(fromA.media, fromB.media)
    }

    // MARK: - Seeds

    private func seedFiveFixtures() throws {
        let user = seedPeer(leaking: true)
        let chat = Chat(context: context)
        chat.id = UUID().uuidString
        chat.otherUser = user
        chat.sessionId = leakSession
        chat.unreadCount = 9

        insertMessage(id: "ctrl-\(UUID().uuidString)", chat: chat, decrypted: "__session_ready")
        insertUndecryptable(id: "undec-\(UUID().uuidString)", chat: chat)
        insertMessage(id: "leg-\(UUID().uuidString)", chat: chat, decrypted: "legacy text")
        insertMessage(id: "bad-\(UUID().uuidString)", chat: chat, decrypted: "{\"type\":\"not_a_wire_shape\"}")
        insertNormal(id: "ok-\(UUID().uuidString)", chat: chat, text: "normal")
        try context.save()
    }

    private func seedAlbumMessage(mediaId: String) throws {
        let user = seedPeer(leaking: false)
        let chat = Chat(context: context)
        chat.id = UUID().uuidString
        chat.otherUser = user

        var item = Shared_Proto_Messaging_V1_MediaMessage()
        item.mediaID = mediaId
        item.mimeType = "image/jpeg"
        var album = Shared_Proto_Messaging_V1_MediaAlbumMessage()
        album.items = [item]
        let stored = LocalMessagePayload.encodeMediaAlbum(album)

        let msg = Message(context: context)
        msg.id = UUID().uuidString.lowercased()
        msg.fromUserId = peer
        msg.toUserId = local
        msg.timestamp = Date()
        msg.isSentByMe = false
        msg.retryCount = 0
        msg.chat = chat
        msg.encryptedContent = Data()
        msg.applyStoredEncryption(plaintextData: stored, contactId: peer)
        try context.save()
    }

    private func seedRoundTripStore(mediaId: String) throws {
        let user = seedPeer(leaking: false)
        user.displayName = "Peer"
        user.username = "peer"
        user.isContact = true
        user.amISharingWith = true

        let chat = Chat(context: context)
        chat.id = UUID().uuidString
        chat.otherUser = user
        chat.isPinned = true
        chat.isMuted = true

        let msgId = "dddddddd-eeee-4fff-8000-111111111111"
        insertNormal(id: msgId, chat: chat, text: "round-trip")

        var item = Shared_Proto_Messaging_V1_MediaMessage()
        item.mediaID = mediaId
        item.mimeType = "image/jpeg"
        var album = Shared_Proto_Messaging_V1_MediaAlbumMessage()
        album.items = [item]
        let stored = LocalMessagePayload.encodeMediaAlbum(album)
        let mediaMsg = Message(context: context)
        mediaMsg.id = "dddddddd-eeee-4fff-8000-222222222222"
        mediaMsg.fromUserId = peer
        mediaMsg.toUserId = local
        mediaMsg.timestamp = Date(timeIntervalSince1970: 1_700_000_001)
        mediaMsg.isSentByMe = false
        mediaMsg.retryCount = 0
        mediaMsg.chat = chat
        mediaMsg.encryptedContent = Data()
        mediaMsg.applyStoredEncryption(plaintextData: stored, contactId: peer)

        let reaction = Reaction(context: context)
        reaction.targetMessageId = msgId
        reaction.reactorUserId = peer
        reaction.emoji = "🔥"
        reaction.timestampMs = 1_700_000_000_500

        let key = Data(repeating: 0x11, count: 32)
        _ = try LocalRepositories.peerDevices.record([PeerDeviceRecord(
            deviceId: deriveDeviceId(identityPublicKey: key), accountId: peer,
            identityKey: key, firstSeenAt: Date(timeIntervalSince1970: 1_700_000_000)
        )])

        _ = CTCallRecord.create(
            id: "call-1",
            peerUserId: peer,
            peerName: "should-not-travel",
            direction: .outgoing,
            status: .completed,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_030),
            durationSeconds: 30,
            in: context
        )
        try context.save()
    }

    @discardableResult
    private func seedPeer(leaking: Bool) -> User {
        let user = User(context: context)
        user.id = peer
        user.username = leaking ? "leaky" : "peer"
        user.displayName = "Peer"
        user.isContact = true
        user.addedAt = Date(timeIntervalSince1970: 1_700_000_000)
        if leaking {
            user.knownIdentityKey = leakIdentity
            user.publicKey = leakPublicKey
        }
        return user
    }

    private func insertMessage(id: String, chat: Chat, decrypted: String) {
        let msg = Message(context: context)
        msg.id = id
        msg.fromUserId = peer
        msg.toUserId = local
        msg.timestamp = Date()
        msg.isSentByMe = false
        msg.retryCount = 0
        msg.chat = chat
        msg.contentTypeRaw = 0
        msg.encryptedContent = Data()
        msg.decryptedContent = decrypted
        msg.contentKeyRef = nil
    }

    private func insertUndecryptable(id: String, chat: Chat) {
        let msg = Message(context: context)
        msg.id = id
        msg.fromUserId = peer
        msg.toUserId = local
        msg.timestamp = Date()
        msg.isSentByMe = false
        msg.retryCount = 0
        msg.chat = chat
        msg.encryptedContent = Data([0xDE, 0xAD, 0xBE, 0xEF])
        msg.contentKeyRef = "missing-key"
        msg.decryptedContent = nil
    }

    private func insertNormal(id: String, chat: Chat, text: String) {
        var body = Shared_Proto_Messaging_V1_TextMessage()
        body.text = text
        var content = Shared_Proto_Messaging_V1_MessageContent()
        content.text = body
        let stored = LocalMessagePayload.storagePayload(forWireContent: content)
        let msg = Message(context: context)
        msg.id = id
        msg.fromUserId = local
        msg.toUserId = peer
        msg.timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        msg.isSentByMe = true
        msg.retryCount = 0
        msg.chat = chat
        msg.encryptedContent = Data()
        msg.applyStoredEncryption(plaintextData: stored, contactId: peer)
    }

    /// The encoder's output split: transcript records, and media files by id.
    private func collect(
        _ stream: AsyncThrowingStream<HistoryOutbound, Error>
    ) async throws -> (records: [HistoryRecord], media: [String]) {
        var records: [HistoryRecord] = []
        var media: [String] = []
        for try await item in stream {
            switch item {
            case .record(let r): records.append(r)
            case .media(let id, _): media.append(id)
            }
        }
        return (records, media)
    }

    /// Manifest snapshot_id / created_at stay; compare everything else by type+id.
    private func fingerprints(_ records: [HistoryRecord]) throws -> [String: Data] {
        var map: [String: Data] = [:]
        for rec in records {
            switch rec {
            case .manifest:
                break
            case .contact(let c):
                map["c:\(HistoryAccountID.dashed(c.userID) ?? "")"] = try c.serializedData()
            case .chat(let c):
                map["h:\(HistoryAccountID.dashed(c.otherUserID) ?? "")"] = try c.serializedData()
            case .message(let m):
                map["m:\(m.id)"] = try m.serializedData()
            case .reaction(let r):
                map["r:\(r.targetMessageID):\(HistoryAccountID.dashed(r.reactorUserID) ?? "")"] = try r.serializedData()
            case .peerDevice(let p):
                map["p:\(p.deviceID)"] = try p.serializedData()
            case .call(let c):
                map["k:\(c.id)"] = try c.serializedData()
            case .skipped(let type):
                map["s:\(type)"] = Data()
            }
        }
        return map
    }
}
