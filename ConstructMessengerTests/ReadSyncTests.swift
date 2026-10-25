import CoreData
import XCTest
@testable import Construct_Messenger

/// How far this account has read each chat, between its own devices only (TODO 152,
/// construct-docs decisions/read-state-syncs-between-own-devices.md, 2026-10-15). The rule is the
/// cross-client one in construct-protos `conformance/knst_read_markers.json`; Android reads the
/// same file.
@MainActor
final class ReadSyncTests: XCTestCase {

    // MARK: - Vectors

    private struct Vectors: Decodable {
        struct Marker: Decodable {
            let partner_user_id: String
            let last_read_message_id: String
            let last_read_sent_at_ms: UInt64
        }
        struct Decode: Decodable { let name: String; let payload: String; let markers: [Marker] }
        struct Apply: Decodable {
            let name: String; let held: [Pair]?; let marker: [Pair]; let from_own_account: Bool; let result: String
        }
        struct Covers: Decodable { let name: String; let boundary: [Pair]; let message: [Pair]; let read: Bool }
        /// `[sent_at_ms, message_id]` arrives as a mixed array.
        enum Pair: Decodable {
            case time(UInt64), id(String)
            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let t = try? c.decode(UInt64.self) { self = .time(t) } else { self = .id(try c.decode(String.self)) }
            }
        }
        let decode: [Decode]
        let apply: [Apply]
        let covers: [Covers]
    }

    private func vectors() throws -> Vectors {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ConstructMessenger/Networking/gRPC/Generated/conformance/knst_read_markers.json")
        let v = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
        XCTAssertFalse(v.decode.isEmpty || v.apply.isEmpty || v.covers.isEmpty, "vectors look truncated")
        return v
    }

    private func boundary(_ pair: [Vectors.Pair]) -> ReadSync.Boundary {
        guard case .time(let t) = pair[0], case .id(let id) = pair[1] else { fatalError("bad pair") }
        return ReadSync.Boundary(sentAtMs: t, messageId: id)
    }

    private func hex(_ s: String) -> Data {
        Data(stride(from: 0, to: s.count, by: 2).map { i -> UInt8 in
            let a = s.index(s.startIndex, offsetBy: i)
            return UInt8(s[a..<s.index(a, offsetBy: 2)], radix: 16)!
        })
    }

    /// Mutation: drop a field in `decode`, or encode in another order — this reddens.
    func testMarkersReadAsTheVectorsSay() throws {
        for c in try vectors().decode {
            let read = try XCTUnwrap(ReadSync.decode(hex(c.payload)), c.name)
            XCTAssertEqual(read.map(\.partner), c.markers.map { $0.partner_user_id }, c.name)
            XCTAssertEqual(read.map(\.boundary), c.markers.map {
                ReadSync.Boundary(sentAtMs: $0.last_read_sent_at_ms, messageId: $0.last_read_message_id)
            }, c.name)
            // What we write reads back the same.
            let written = Dictionary(uniqueKeysWithValues: read.map { ($0.partner, $0.boundary) })
            let again = try XCTUnwrap(ReadSync.encode(written).flatMap(ReadSync.decode))
            XCTAssertEqual(Dictionary(uniqueKeysWithValues: again.map { ($0.partner, $0.boundary) }), written, c.name)
        }
    }

    /// Mutation: compare ids the other way, or accept equal — this reddens.
    func testAMarkerMovesTheBoundaryAsTheVectorsSay() throws {
        for c in try vectors().apply {
            let outcome = ReadSync.outcome(
                of: boundary(c.marker), held: c.held.map(boundary), fromOwnAccount: c.from_own_account
            )
            XCTAssertEqual("\(outcome)", c.result, c.name)
        }
    }

    func testABoundaryCoversAsTheVectorsSay() throws {
        for c in try vectors().covers {
            XCTAssertEqual(ReadSync.covers(boundary(c.boundary), boundary(c.message)), c.read, c.name)
        }
    }

    /// The column in the cross-client table that says "never to or from a contact".
    func testOwnDevicesOnlyIsTheTables() throws {
        struct Table: Decodable { struct Row: Decodable { let value: Int; let own_devices_only: Bool }; let types: [Row] }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ConstructMessenger/Networking/gRPC/Generated/conformance/knst_content_types.json")
        let rows = try JSONDecoder().decode(Table.self, from: Data(contentsOf: url)).types
        XCTAssertTrue(rows.contains { $0.own_devices_only }, "the column is there")
        for row in rows {
            XCTAssertEqual(ContentTypeRouting.isOwnDevicesOnly(UInt8(row.value)), row.own_devices_only, "type \(row.value)")
        }
    }

    // MARK: - Applying

    private var container: NSPersistentContainer!
    private var defaultsSuite: String!

    override func setUp() async throws {
        try await super.setUp()
        container = PersistenceController(inMemory: true).container
        LocalRepositories.useChatsForTesting(container)
        LocalRepositories.useMessagesForTesting(container)
        defaultsSuite = "read-sync-\(UUID().uuidString)"
        LocalRepositories.useKeyValueForTesting(DefaultsKeyValueStore(defaults: UserDefaults(suiteName: defaultsSuite)!))
    }

    override func tearDown() async throws {
        LocalRepositories.useChatsForTesting(nil)
        LocalRepositories.useMessagesForTesting(nil)
        LocalRepositories.useKeyValueForTesting(nil)
        UserDefaults().removePersistentDomain(forName: defaultsSuite)
        try await super.tearDown()
    }

    private let partner = "14f28d31-0c4e-4b7a-9f3e-2a5d6c7b8e90"
    private let base = Date(timeIntervalSince1970: 1_760_500_000)

    /// A chat with five incoming messages a second apart, all unread. Returns the chat id and the
    /// messages' ids, oldest first.
    private func chatWithFiveUnread() throws -> (chatId: String, ids: [String]) {
        let ctx = container.viewContext
        let peer = User(context: ctx)
        peer.id = partner
        peer.username = ""
        peer.displayName = ""
        let chat = Chat(context: ctx)
        chat.id = UUID().uuidString
        chat.otherUser = peer
        chat.unreadCount = 5
        var ids: [String] = []
        for i in 0..<5 {
            let row = Message(context: ctx)
            row.id = UUID().uuidString.lowercased()
            row.chat = chat
            row.timestamp = base.addingTimeInterval(Double(i))
            row.serverOrderKey = ServerMessageOrder.local(timestamp: row.timestamp, messageId: row.id)
            row.isSentByMe = false
            row.fromUserId = partner
            row.toUserId = "me"
            row.applyStoredEncryption(plaintextData: Data("m\(i)".utf8), contactId: partner)
            ids.append(row.id)
        }
        try ctx.save()
        return (chat.id, ids)
    }

    private func marker(readUpTo index: Int, of ids: [String]) -> Data {
        ReadSync.encode([partner: ReadSync.Boundary(
            sentAtMs: UInt64(base.addingTimeInterval(Double(index)).timeIntervalSince1970 * 1000),
            messageId: ids[index]
        )])!
    }

    /// The Desktop's case: read up to the third message on the phone — two are left.
    /// Mutation: skip the `setUnread` — this reddens.
    func testAMarkerFromOurOtherDeviceLeavesOnlyTheRestUnread() throws {
        let (chatId, ids) = try chatWithFiveUnread()
        MessageRouter().applyReadMarkers(
            marker(readUpTo: 2, of: ids), myUserId: "me", fromOwnAccount: true, boundaries: ReadBoundaries()
        )
        XCTAssertEqual(try LocalRepositories.chats.chat(chatId)?.unreadCount, 2)
    }

    /// A contact cannot clear our unread count. Mutation: pass `true` on the contact path, or
    /// drop the own-account term from the rule — this reddens.
    func testAMarkerFromAContactChangesNothing() throws {
        let (chatId, ids) = try chatWithFiveUnread()
        let boundaries = ReadBoundaries()
        MessageRouter().applyReadMarkers(
            marker(readUpTo: 4, of: ids), myUserId: "me", fromOwnAccount: false, boundaries: boundaries
        )
        XCTAssertEqual(try LocalRepositories.chats.chat(chatId)?.unreadCount, 5)
        XCTAssertNil(boundaries.boundary(for: partner))
    }

    /// The same, the way a contact's frame really arrives: a control frame on the ordinary receive
    /// path. Mutation: apply it there as our own (`fromOwnAccount: true`) — this reddens.
    func testAReadSyncFrameFromAContactIsDropped() throws {
        let (chatId, ids) = try chatWithFiveUnread()
        LocalRepositories.useProcessedMessagesForTesting(CoreDataProcessedMessageStore(container: container))
        defer { LocalRepositories.useProcessedMessagesForTesting(nil) }
        let frame = CfeAction.controlFrameDecrypted(
            contactId: "0123456789abcdef0123456789abcdef", messageId: "m-contact",
            contentType: UInt8(Shared_Proto_Core_V1_ContentType.readSync.rawValue),
            body: marker(readUpTo: 4, of: ids)
        )
        MessageRouter().handleControlFrames(in: [frame], messageId: "m-contact", from: partner, in: container.viewContext)
        XCTAssertEqual(try LocalRepositories.chats.chat(chatId)?.unreadCount, 5)
        XCTAssertNil(ReadBoundaries.shared.boundary(for: partner), "nothing was filed either")
    }

    /// An older marker after a newer one does not bring messages back as unread.
    func testAnOlderMarkerDoesNotMoveTheBoundaryBack() throws {
        let (chatId, ids) = try chatWithFiveUnread()
        let boundaries = ReadBoundaries()
        MessageRouter().applyReadMarkers(marker(readUpTo: 3, of: ids), myUserId: "me", fromOwnAccount: true, boundaries: boundaries)
        MessageRouter().applyReadMarkers(marker(readUpTo: 1, of: ids), myUserId: "me", fromOwnAccount: true, boundaries: boundaries)
        XCTAssertEqual(try LocalRepositories.chats.chat(chatId)?.unreadCount, 1)
        XCTAssertEqual(boundaries.boundary(for: partner)?.messageId, ids[3])
    }

    // MARK: - Sending

    /// Reading goes out batched, not per read: two chats read, one payload, after the interval.
    /// Mutation: send from `noteRead` directly — this reddens.
    func testReadingIsSentOnceForEverythingPending() async throws {
        let outbox = ReadSyncOutbox()
        outbox.boundaries = ReadBoundaries()
        var sent: [Data] = []
        outbox.send = { sent.append($0); return true }
        outbox.noteRead(partner: "a", boundary: .init(sentAtMs: 1, messageId: "x"))
        outbox.noteRead(partner: "b", boundary: .init(sentAtMs: 2, messageId: "y"))
        // A send started on the read would be a task already: give it the chance to run.
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(sent.isEmpty, "nothing goes on a read")
        await outbox.flush()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(Set(try XCTUnwrap(ReadSync.decode(sent[0])).map(\.partner)), ["a", "b"])
        await outbox.flush()
        XCTAssertEqual(sent.count, 1, "nothing pending, nothing sent")
    }

    /// A send that did not go through keeps the markers: on 2026-10-15 the phone's first markers
    /// were cancelled on the way to the background and lost. Mutation: drop the put-back — this
    /// reddens.
    func testMarkersThatDidNotGoOutAreSentAgain() async throws {
        let outbox = ReadSyncOutbox()
        outbox.boundaries = ReadBoundaries()
        var attempts: [Data] = []
        var delivers = false
        outbox.send = { attempts.append($0); return delivers }
        outbox.noteRead(partner: "a", boundary: .init(sentAtMs: 1, messageId: "x"))
        await outbox.flush()
        XCTAssertTrue(outbox.hasPending, "the failed markers wait for another try")
        delivers = true
        await outbox.flush()
        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(try XCTUnwrap(attempts.last.flatMap(ReadSync.decode)).map(\.partner), ["a"])
        XCTAssertFalse(outbox.hasPending)
    }

    /// Reading what was already read sends nothing.
    func testReadingNothingNewSendsNothing() async {
        let outbox = ReadSyncOutbox()
        outbox.boundaries = ReadBoundaries()
        var sent = 0
        outbox.send = { _ in sent += 1; return true }
        outbox.noteRead(partner: "a", boundary: .init(sentAtMs: 5, messageId: "x"))
        await outbox.flush()
        outbox.noteRead(partner: "a", boundary: .init(sentAtMs: 5, messageId: "x"))
        outbox.noteRead(partner: "a", boundary: .init(sentAtMs: 4, messageId: "z"))
        await outbox.flush()
        XCTAssertEqual(sent, 1)
    }
}
