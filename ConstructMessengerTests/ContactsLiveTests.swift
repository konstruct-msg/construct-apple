//
//  ContactsLiveTests.swift
//  ConstructMessengerTests
//
//  What the screens read contacts from, and the change feed under it: a write is seen whichever
//  context made it, a screen's contact follows it, and a replaced store leaves nothing behind.
//

import CoreData
import XCTest
@testable import Construct_Messenger

@MainActor
final class ContactsLiveTests: XCTestCase {

    private var container: NSPersistentContainer!
    private var store: CoreDataContactStore!

    override func setUp() {
        super.setUp()
        container = PersistenceController(inMemory: true).container
        store = CoreDataContactStore(container: container)
    }

    override func tearDown() {
        store = nil
        container = nil
        super.tearDown()
    }

    private func seed(_ id: String, name: String) throws {
        let context = container.viewContext
        let user = User(context: context)
        user.id = id
        user.username = ""
        user.displayName = name
        try context.save()
    }

    /// Waits for `condition` on the main actor, which is where the feed's changes land.
    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), "not reached in 2 s", file: file, line: line)
    }

    /// A write through the repository and a save of the view context are both seen. Mutation:
    /// filter the feed to the repository's own contexts — the second save goes unseen.
    func testTheFeedSeesEverySaveOnTheStore() async throws {
        var seen = Set<String>()
        let changes = store.changes()
        let reading = Task { for await ids in changes { seen.formUnion(ids) } }
        defer { reading.cancel() }

        try store.insert(.new(id: "via-repo", isContact: true, addedAt: nil))
        try seed("via-view-context", name: "V")
        await eventually { seen.isSuperset(of: ["via-repo", "via-view-context"]) }
    }

    /// Another store's saves are not this one's. Mutation: drop the coordinator check.
    func testTheFeedIgnoresAnotherStore() async throws {
        var seen = Set<String>()
        let changes = store.changes()
        let reading = Task { for await ids in changes { seen.formUnion(ids) } }
        defer { reading.cancel() }

        let other = PersistenceController(inMemory: true).container
        let user = User(context: other.viewContext)
        user.id = "elsewhere"; user.username = ""; user.displayName = ""
        try other.viewContext.save()
        try store.insert(.new(id: "here", isContact: true, addedAt: nil))
        await eventually { seen.contains("here") }
        XCTAssertFalse(seen.contains("elsewhere"))
    }

    /// A screen's contact follows a write. Mutation: drop the `revision += 1` in `refresh` — the
    /// cache updates and nothing redraws, which this sees as an unmoved revision.
    func testAContactOnScreenFollowsAWrite() async throws {
        try seed("a", name: "Ada")
        let live = ContactsLive(store: store)
        XCTAssertEqual(live.contact("a")?.displayName, "Ada")
        let before = live.revision

        try store.setNames("a", username: "", displayName: "Ada Two")
        await eventually { live.revision > before }
        XCTAssertEqual(live.contact("a")?.displayName, "Ada Two")
    }

    /// A row that did not exist when first asked for appears once written.
    func testAContactWrittenAfterTheFirstAskAppears() async throws {
        let live = ContactsLive(store: store)
        XCTAssertNil(live.contact("late"))
        try store.insert(.new(id: "late", isContact: true, addedAt: nil))
        await eventually { live.contact("late") != nil }
    }

    /// Sign-out or a wipe replaces the store; what was held is forgotten. Mutation: drop the
    /// `.localStoreReplaced` observer — the old account's contact keeps showing.
    func testAReplacedStoreForgetsWhatWasHeld() async throws {
        try seed("a", name: "Ada")
        let live = ContactsLive(store: store)
        XCTAssertNotNil(live.contact("a"))

        // Gone the way a replaced store loses its rows: no save the feed would see.
        let req = NSBatchDeleteRequest(fetchRequest: User.fetchRequest())
        try container.persistentStoreCoordinator.execute(req, with: container.viewContext)

        let before = live.revision
        NotificationCenter.default.post(name: .localStoreReplaced, object: nil)
        await eventually { live.revision > before }
        XCTAssertNil(live.contact("a"))
    }
}
