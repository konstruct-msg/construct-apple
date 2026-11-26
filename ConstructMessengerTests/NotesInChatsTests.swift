import XCTest
@testable import Construct_Messenger

/// Notes stand among the chats as one row, placed by the newest note as a chat is placed by its
/// last message (`ChatsListEntry.merged`, `NotesLatest.latest`).
final class NotesInChatsTests: XCTestCase {

    private func chat(_ id: String, at seconds: TimeInterval?, pinned: Bool = false) -> ChatRecord {
        ChatRecord(id: id, peerId: "peer-\(id)", lastMessageText: nil,
                   lastMessageTime: seconds.map(Date.init(timeIntervalSince1970:)),
                   isPinned: pinned, unreadCount: 0)
    }

    private func note(_ id: String, at seconds: TimeInterval, pinned: Bool = false) -> Note {
        Note(id: id, body: Data(), createdAt: Date(timeIntervalSince1970: seconds), isPinned: pinned)
    }

    /// The store's order: pinned first, then most recent, chats with no message last.
    private var chats: [ChatRecord] {
        [chat("P", at: 500, pinned: true), chat("A", at: 400), chat("B", at: 200), chat("C", at: nil)]
    }

    private func order(newest: Note?) -> [String] {
        ChatsListEntry.merged(chats, newestNote: newest).map { $0.id == ChatsListEntry.notesId ? "notes" : $0.id }
    }

    func testTheRowStandsByTheTimeOfTheNewestNote() {
        XCTAssertEqual(order(newest: note("n", at: 300)), ["P", "A", "notes", "B", "C"])
    }

    func testANoteNewerThanEveryChatComesRightAfterThePinned() {
        XCTAssertEqual(order(newest: note("n", at: 900)), ["P", "notes", "A", "B", "C"])
    }

    func testAnOldNoteStillComesBeforeChatsWithNoMessage() {
        XCTAssertEqual(order(newest: note("n", at: 100)), ["P", "A", "B", "notes", "C"])
    }

    func testWithNoNoteTheRowIsLast() {
        XCTAssertEqual(order(newest: nil), ["P", "A", "B", "C", "notes"])
    }

    func testTheRowIsThereWithNoChatAtAll() {
        XCTAssertEqual(ChatsListEntry.merged([], newestNote: nil).map(\.id), [ChatsListEntry.notesId])
    }

    // MARK: - The newest note

    func testTheNewestIsTheNewestUnpinnedOrAnOlderPinnedOne() throws {
        let store = PagedNotes([note("p-old", at: 50, pinned: true), note("u1", at: 300), note("u2", at: 200)])
        XCTAssertEqual(try NotesLatest.latest(in: store)?.id, "u1")
    }

    func testAPinnedNoteNewerThanTheRestIsTheNewest() throws {
        let store = PagedNotes([note("p-new", at: 900, pinned: true), note("u1", at: 300)])
        XCTAssertEqual(try NotesLatest.latest(in: store)?.id, "p-new")
    }

    func testPagesAreReadPastThePinnedNotes() throws {
        let store = PagedNotes([
            note("p1", at: 10, pinned: true), note("p2", at: 20, pinned: true), note("p3", at: 30, pinned: true),
            note("u1", at: 300), note("u2", at: 200),
        ])
        XCTAssertEqual(try NotesLatest.latest(in: store, page: 2)?.id, "u1")
        XCTAssertLessThanOrEqual(store.pagesRead, 2, "reading stops at the first unpinned note")
    }

    func testNoNoteIsNil() throws {
        XCTAssertNil(try NotesLatest.latest(in: PagedNotes([])))
    }
}

/// The store's paging: pinned first, each part newest first, `after` the last of the page before.
private final class PagedNotes: NotesStore, @unchecked Sendable {
    private let sorted: [Note]
    private(set) var pagesRead = 0

    init(_ notes: [Note]) {
        sorted = notes.sorted { a, b in
            a.isPinned != b.isPinned ? a.isPinned : a.createdAt > b.createdAt
        }
    }

    func notes(after: Note?, limit: Int) throws -> [Note] {
        pagesRead += 1
        let start = after.flatMap { last in sorted.firstIndex { $0.id == last.id }.map { $0 + 1 } } ?? 0
        return Array(sorted[start...].prefix(limit))
    }

    func search(_ query: String, limit: Int) throws -> [Note] { [] }
    func note(_ id: String) throws -> Note? { sorted.first { $0.id == id } }
    func heldMediaIds() throws -> Set<String> { [] }
    func changes() -> AsyncStream<Set<String>> { AsyncStream { $0.finish() } }
    func insert(_ note: Note) throws -> Bool { false }
    func edit(_ id: String, body: Data, editedAt: Date) throws -> [String]? { nil }
    func setPinned(_ id: String, _ pinned: Bool) throws -> Bool { false }
    func delete(_ ids: Set<String>) throws -> [String] { [] }
}
