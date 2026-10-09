//
//  ContactStoreTests.swift
//  ConstructMessengerTests
//
//  What any `ContactStore` / `OwnProfileStore` must answer. Run against Core Data today; the
//  `LocalStore` implementation (LOCAL_STORE_MIGRATION_PLAN step 3) runs the same cases. Rows are
//  seeded as Core Data writes them now, since the writes move behind the seam in the next step.
//

import CoreData
import XCTest
@testable import Construct_Messenger

final class ContactStoreTests: XCTestCase {

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

    @discardableResult
    private func seed(_ id: String, configure: (User) -> Void = { _ in }) throws -> User {
        let context = container.viewContext
        let user = User(context: context)
        user.id = id
        user.username = ""
        user.displayName = ""
        configure(user)
        try context.save()
        return user
    }

    /// Every field the record carries comes from its column. Mutation: map one field from the
    /// wrong attribute in `ContactRecord(row:)` — the record reads back different.
    func testARowReadsBackWhole() throws {
        let at = Date(timeIntervalSince1970: 1_000)
        try seed("a") {
            $0.username = "ada"; $0.displayName = "Ada"; $0.localAlias = "A"
            $0.avatarData = Data([1]); $0.knownIdentityKey = Data([2]); $0.accountAddress = Data([3])
            $0.isContact = true; $0.isBlocked = true; $0.isSharingWithMe = true; $0.amISharingWith = true
            $0.sharedWithMeAt = at; $0.addedAt = at.addingTimeInterval(1)
            $0.ktStatus = .failed; $0.securityNotice = .addressChanged; $0.profileEditedAtMs = 7
            $0.pendingAvatarRef = Data([4]); $0.pendingAvatarSince = at.addingTimeInterval(2)
        }
        XCTAssertEqual(try store.contact("a"), ContactRecord(
            id: "a", username: "ada", displayName: "Ada", localAlias: "A", avatar: Data([1]),
            knownIdentityKey: Data([2]), accountAddress: Data([3]), isContact: true, isBlocked: true,
            isSharingWithMe: true, amISharingWith: true, sharedWithMeAt: at,
            addedAt: at.addingTimeInterval(1), ktStatus: .failed, securityNotice: .addressChanged,
            profileEditedAtMs: 7, pendingAvatarRef: Data([4]),
            pendingAvatarSince: at.addingTimeInterval(2)
        ))
        XCTAssertNil(try store.contact("nobody"))
    }

    /// The record names a person the way a `User` does — one rule, not two. Mutation: let
    /// `ContactRecord.resolvedDisplayName` skip the alias.
    func testTheNameShownIsTheSameAsTheRows() throws {
        let row = try seed("b") { $0.username = "bea"; $0.displayName = "Bea"; $0.localAlias = "Mum" }
        XCTAssertEqual(try store.contact("b")?.resolvedDisplayName, row.resolvedDisplayName)
        XCTAssertEqual(try store.contact("b")?.resolvedDisplayName, "Mum")
    }

    /// Mutation: drop `isBlocked == YES` from the count — every known row reads as blocked.
    func testOnlyABlockedRowIsBlocked() throws {
        try seed("blocked") { $0.isBlocked = true }
        try seed("open")
        XCTAssertTrue(try store.isBlocked("blocked"))
        XCTAssertFalse(try store.isBlocked("open"))
        XCTAssertFalse(try store.isBlocked("nobody"))
    }

    /// Our own row is not a contact, and everything else is listed, contacts or not, by id.
    /// Mutation: drop the `id != own` term — our profile is encoded into history as a contact.
    func testEveryContactIsEveryoneButUs() throws {
        try seed("me")
        try seed("z") { $0.isContact = true }
        try seed("k") { $0.isContact = false }
        XCTAssertEqual(try store.everyContact(except: "me").map(\.id), ["k", "z"])
    }

    /// Mutation: drop the `amISharingWith` term — the rebroadcast goes to everyone.
    func testSharingIsWhomWeShareWithButNeverUs() throws {
        try seed("me") { $0.amISharingWith = true }
        try seed("s") { $0.amISharingWith = true }
        try seed("n")
        XCTAssertEqual(try store.sharingWith(except: "me"), ["s"])
    }

    /// A row with an empty key pins nothing. Mutation: drop the emptiness check — an empty key
    /// derives to a device id of its own and answers for it.
    func testPinsAreTheRowsThatHoldAKey() throws {
        try seed("p") { $0.knownIdentityKey = Data([9, 9]) }
        try seed("e") { $0.knownIdentityKey = Data() }
        try seed("none")
        XCTAssertEqual(try store.identityKeyPins(), [IdentityKeyPin(contactId: "p", key: Data([9, 9]))])
    }

    func testOurProfileIsOurRow() throws {
        try seed("me") { $0.username = "max"; $0.displayName = "Max"; $0.avatarData = Data([5]); $0.profileEditedAtMs = 3 }
        XCTAssertEqual(try store.profile(accountId: "me"), OwnProfileRecord(
            accountId: "me", username: "max", displayName: "Max", avatar: Data([5]), profileEditedAtMs: 3
        ))
        XCTAssertNil(try store.profile(accountId: ""))
        XCTAssertNil(try store.profile(accountId: "someone"))
    }

    /// Reads come off any thread: the store never borrows a caller's context.
    func testAnswersOffTheMainThread() throws {
        try seed("bg") { $0.isBlocked = true }
        let done = expectation(description: "read")
        let store = self.store!
        DispatchQueue.global().async {
            XCTAssertEqual(try? store.isBlocked("bg"), true)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    // MARK: - Writes

    private func record(_ id: String) -> ContactRecord {
        var r = ContactRecord.new(id: id, isContact: true, addedAt: Date(timeIntervalSince1970: 50))
        r.username = "ada"; r.displayName = "Ada"; r.localAlias = "A"; r.avatar = Data([1])
        r.knownIdentityKey = Data([2]); r.accountAddress = Data([3]); r.amISharingWith = true
        r.pendingAvatarRef = Data([4]); r.pendingAvatarSince = Date(timeIntervalSince1970: 60)
        return r
    }

    /// An insert adds a row whole and never replaces one. Mutation: drop the existence check —
    /// a second insert overwrites what the field writes put there.
    func testInsertAddsWholeAndNeverReplaces() throws {
        XCTAssertTrue(try store.insert(record("a")))
        XCTAssertEqual(try store.contact("a"), record("a"))
        var other = record("a")
        other.displayName = "Someone else"
        XCTAssertFalse(try store.insert(other))
        XCTAssertEqual(try store.contact("a")?.displayName, "Ada")
    }

    /// Each write changes its fields and nothing else. Mutation: write a field outside the named
    /// set in any of them — the row reads back different.
    func testEachWriteChangesOnlyItsFields() throws {
        try store.insert(record("a"))
        var expected = record("a")
        try store.setBlocked("a", true); expected.isBlocked = true
        try store.setAlias("a", nil); expected.localAlias = nil
        try store.setSharingWith("a", false); expected.amISharingWith = false
        try store.setIdentityKey("a", Data([5])); expected.knownIdentityKey = Data([5])
        try store.setKTStatus("a", .failed); expected.ktStatus = .failed
        try store.setAccountAddress("a", nil); expected.accountAddress = nil
        try store.setSecurityNotice("a", .addressChanged); expected.securityNotice = .addressChanged
        try store.setNames("a", username: "ada2", displayName: "Ada Two")
        expected.username = "ada2"; expected.displayName = "Ada Two"
        try store.setAvatar("a", Data([6]), pendingRef: nil, pendingSince: nil)
        expected.avatar = Data([6]); expected.pendingAvatarRef = nil; expected.pendingAvatarSince = nil
        XCTAssertEqual(try store.contact("a"), expected)
    }

    func testASharedProfileIsAppliedWhole() throws {
        try store.insert(.new(id: "a", isContact: true, addedAt: nil))
        let at = Date(timeIntervalSince1970: 100)
        try store.applySharedProfile("a", displayName: "Ada", sharedWithMeAt: at, profileEditedAtMs: 200)
        let read = try XCTUnwrap(store.contact("a"))
        XCTAssertTrue(read.isSharingWithMe)
        XCTAssertEqual(read.displayName, "Ada")
        XCTAssertEqual(read.sharedWithMeAt, at)
        XCTAssertEqual(read.profileEditedAtMs, 200)
    }

    /// Marking keeps the date first added. Mutation: assign `addedAt` unconditionally.
    func testMarkingAContactKeepsWhenItWasAdded() throws {
        try store.insert(.new(id: "kept", isContact: false, addedAt: Date(timeIntervalSince1970: 5)))
        try store.insert(.new(id: "fresh", isContact: false, addedAt: nil))
        try store.markContact("kept", addedAt: Date(timeIntervalSince1970: 99))
        try store.markContact("fresh", addedAt: Date(timeIntervalSince1970: 99))
        XCTAssertEqual(try store.contact("kept")?.addedAt, Date(timeIntervalSince1970: 5))
        XCTAssertEqual(try store.contact("kept")?.isContact, true)
        XCTAssertEqual(try store.contact("fresh")?.addedAt, Date(timeIntervalSince1970: 99))
    }

    /// A write to no row says so and creates none. Mutation: create the row in `update`.
    func testAWriteToNoRowIsReportedAndCreatesNothing() throws {
        XCTAssertFalse(try store.setBlocked("nobody", true))
        XCTAssertNil(try store.contact("nobody"))
    }

    func testPendingAvatarsAreTheRowsWaitingForOne() throws {
        try store.insert(record("p"))
        try store.insert(.new(id: "n", isContact: true, addedAt: nil))
        XCTAssertEqual(try store.contactsWithPendingAvatar().map(\.id), ["p"])
    }

    /// Our profile: created when absent, replaced when present, and never a contact.
    func testOurProfileIsSavedAsOneRow() throws {
        var me = OwnProfileRecord(accountId: "me", username: "max", displayName: "Max", avatar: nil, profileEditedAtMs: 1)
        try store.save(me)
        me.displayName = "Maxim"
        me.markEdited(now: Date(timeIntervalSince1970: 2))
        try store.save(me)
        XCTAssertEqual(try store.profile(accountId: "me"), me)
        XCTAssertEqual(try store.profile(accountId: "me")?.profileEditedAtMs, 2000)
        XCTAssertEqual(try store.contact("me")?.isContact, false)
    }

    /// The crate's `delete_contact`: the row, its chat and the chat's messages; another contact's
    /// chat stays. Mutation: delete only the `User` with `chats` set to nullify — the chat stays.
    func testDeletingAContactTakesItsChatAndMessages() throws {
        try store.insert(.new(id: "gone", isContact: true, addedAt: nil))
        try store.insert(.new(id: "kept", isContact: true, addedAt: nil))
        let chats = CoreDataChatStore(container: container)
        let gone = try chats.openChat(withPeer: "gone").chat
        let kept = try chats.openChat(withPeer: "kept").chat
        let context = container.viewContext
        let message = PreviewHelpers.createSampleMessage(
            context: context, chat: try Chat.row(gone.id, in: context), isSentByMe: false, text: "hi"
        )
        message.fromUserId = "gone"
        message.toUserId = "me"
        try context.save()

        XCTAssertTrue(try store.delete("gone"))
        XCTAssertNil(try store.contact("gone"))
        XCTAssertNil(try chats.chat(gone.id))
        XCTAssertEqual(try chats.chat(kept.id)?.peerId, "kept")
        context.refreshAllObjects()
        XCTAssertEqual(try context.count(for: Message.fetchRequest()), 0)
        XCTAssertFalse(try store.delete("gone"), "a second delete finds nothing")
    }
}
