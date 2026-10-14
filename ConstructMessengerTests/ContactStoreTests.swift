//
//  ContactStoreTests.swift
//  ConstructMessengerTests
//
//  What any `ContactStore` / `OwnProfileStore` must answer, written against the protocols and run
//  on both implementations — Core Data here, `LocalStore` in the subclass below
//  (LOCAL_STORE_MIGRATION_PLAN step 3). What only Core Data has — its columns, the `User` object,
//  the chat cascade through its relationships — is `CoreDataContactStoreTests`.
//

import CoreData
import XCTest
@testable import Construct_Messenger

class ContactStoreTests: XCTestCase {

    typealias Store = any ContactStore & OwnProfileStore

    func makeStore() -> Store {
        CoreDataContactStore(container: PersistenceController(inMemory: true).container)
    }

    private var store: Store!

    override func setUp() {
        super.setUp()
        store = makeStore()
    }

    override func tearDown() {
        store = nil
        super.tearDown()
    }

    private func record(_ id: String) -> ContactRecord {
        var r = ContactRecord.new(id: id, isContact: true, addedAt: Date(timeIntervalSince1970: 50))
        r.username = "ada"; r.displayName = "Ada"; r.localAlias = "A"; r.avatar = Data([1])
        r.knownIdentityKey = Data([2]); r.accountAddress = Data([3]); r.amISharingWith = true
        r.pendingAvatarRef = Data([4]); r.pendingAvatarSince = Date(timeIntervalSince1970: 60)
        return r
    }

    /// A row holding every field, none of them at its default.
    private func full(_ id: String) -> ContactRecord {
        var r = record(id)
        r.isBlocked = true; r.isSharingWithMe = true
        r.sharedWithMeAt = Date(timeIntervalSince1970: 1_000)
        r.ktStatus = .failed; r.securityNotice = .addressChanged; r.profileEditedAtMs = 7
        return r
    }

    @discardableResult
    private func seed(_ id: String, configure: (inout ContactRecord) -> Void = { _ in }) throws -> ContactRecord {
        var row = ContactRecord.new(id: id, isContact: false, addedAt: nil)
        configure(&row)
        XCTAssertTrue(try store.insert(row))
        return row
    }

    /// Every field the record carries reads back as written. Mutation: drop or swap one field in
    /// either direction of the implementation's mapping — the record reads back different.
    func testARowReadsBackWhole() throws {
        try store.insert(full("a"))
        XCTAssertEqual(try store.contact("a"), full("a"))
        XCTAssertNil(try store.contact("nobody"))
    }

    /// Mutation: answer `isBlocked` from the row's existence — every known row reads as blocked.
    func testOnlyABlockedRowIsBlocked() throws {
        try seed("blocked") { $0.isBlocked = true }
        try seed("open")
        XCTAssertTrue(try store.isBlocked("blocked"))
        XCTAssertFalse(try store.isBlocked("open"))
        XCTAssertFalse(try store.isBlocked("nobody"))
    }

    /// A row a client holds for its own account is left out; everything else is listed, contacts
    /// or not, by id. Mutation: drop the `except` term — our profile is encoded into history as a
    /// contact.
    func testEveryContactIsEveryoneButUs() throws {
        try seed("me")
        try seed("z") { $0.isContact = true }
        try seed("k")
        XCTAssertEqual(try store.everyContact(except: "me").map(\.id), ["k", "z"])
    }

    func testContactsAreTheRowsMarkedAsContactsById() throws {
        try seed("z") { $0.isContact = true; $0.displayName = "Aaron" }
        try seed("k")
        try seed("b") { $0.isContact = true; $0.displayName = "Zed" }
        XCTAssertEqual(try store.contacts().map(\.id), ["b", "z"])
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

    func testOurProfileIsReadForOurAccountOnly() throws {
        let me = OwnProfileRecord(accountId: "me", username: "max", displayName: "Max", avatar: Data([5]), profileEditedAtMs: 3)
        try store.save(me)
        XCTAssertEqual(try store.profile(accountId: "me"), me)
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

    /// The screens redraw from this (`ContactsLive`). Mutation: drop the feed's yield — nothing
    /// is heard.
    func testAWriteIsHeardByIdOnTheChangeStream() async throws {
        let heard = expectation(description: "the write is heard")
        let changes = store.changes()
        let listener = Task {
            for await ids in changes where ids.contains("heard") {
                heard.fulfill()
                return
            }
        }
        try seed("heard")
        await fulfillment(of: [heard], timeout: 5)
        listener.cancel()
    }

    // MARK: - Writes

    /// An insert adds a row whole and never replaces one. Mutation: drop the existence check —
    /// a second insert overwrites what the field writes put there.
    func testInsertAddsWholeAndNeverReplaces() throws {
        XCTAssertTrue(try store.insert(record("a")))
        XCTAssertEqual(try store.contact("a"), record("a"))
        XCTAssertTrue(try store.setAlias("a", "Mine"))
        var other = record("a")
        other.displayName = "Someone else"
        XCTAssertFalse(try store.insert(other))
        XCTAssertEqual(try store.contact("a")?.displayName, "Ada")
        XCTAssertEqual(try store.contact("a")?.localAlias, "Mine")
    }

    /// Mutation: make `replace` an upsert — the row nobody holds appears.
    func testReplaceWritesEveryFieldOfAHeldRowAndCreatesNone() throws {
        try store.insert(.new(id: "a", isContact: false, addedAt: nil))
        XCTAssertTrue(try store.replace(full("a")))
        XCTAssertEqual(try store.contact("a"), full("a"))
        XCTAssertFalse(try store.replace(full("gone")))
        XCTAssertNil(try store.contact("gone"))
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

    // MARK: - Avatar (TODO 139)

    /// A download finishing after a newer profile named another avatar must not land. Mutation:
    /// drop the `pendingAvatarRef == expected` condition — A's late download replaces the avatar
    /// and ends B's wait.
    func testAnAvatarLandsOnlyWhileItIsTheOneWaiting() throws {
        try store.insert(.new(id: "a", isContact: true, addedAt: nil))
        try store.setAvatarKeepingPending("a", Data([0]))
        let a = Data([0xA]), b = Data([0xB])
        let sinceB = Date(timeIntervalSince1970: 200)
        XCTAssertTrue(try store.setPendingAvatar("a", ref: a, since: Date(timeIntervalSince1970: 100)))
        XCTAssertTrue(try store.setPendingAvatar("a", ref: b, since: sinceB))

        XCTAssertFalse(try store.completePendingAvatar("a", expected: a, avatar: Data([1])))
        var row = try XCTUnwrap(store.contact("a"))
        XCTAssertEqual(row.avatar, Data([0]))
        XCTAssertEqual(row.pendingAvatarRef, b)
        XCTAssertEqual(row.pendingAvatarSince, sinceB)

        XCTAssertTrue(try store.completePendingAvatar("a", expected: b, avatar: Data([2])))
        row = try XCTUnwrap(store.contact("a"))
        XCTAssertEqual(row.avatar, Data([2]))
        XCTAssertNil(row.pendingAvatarRef)
        XCTAssertNil(row.pendingAvatarSince)

        XCTAssertFalse(try store.completePendingAvatar("nobody", expected: b, avatar: Data([2])))
        XCTAssertNil(try store.contact("nobody"))
    }

    /// Mutation: drop the condition from `dropPendingAvatar` — another download's failure ends
    /// the wait for the avatar announced after it.
    func testDroppingAnotherReferenceChangesNothing() throws {
        try store.insert(.new(id: "a", isContact: true, addedAt: nil))
        try store.setAvatarKeepingPending("a", Data([0]))
        try store.setPendingAvatar("a", ref: Data([0xB]), since: Date(timeIntervalSince1970: 200))

        XCTAssertFalse(try store.dropPendingAvatar("a", expected: Data([0xA])))
        XCTAssertEqual(try store.contact("a")?.pendingAvatarRef, Data([0xB]))

        XCTAssertTrue(try store.dropPendingAvatar("a", expected: Data([0xB])))
        let row = try XCTUnwrap(store.contact("a"))
        XCTAssertNil(row.pendingAvatarRef)
        XCTAssertNil(row.pendingAvatarSince)
        XCTAssertEqual(row.avatar, Data([0]), "the avatar shown stays")
    }

    /// Mutation: clear the wait in `setAvatarKeepingPending`, or the avatar in `setPendingAvatar`.
    func testAnAvatarAndAnAnnouncementEachLeaveTheOtherAlone() throws {
        try store.insert(.new(id: "a", isContact: true, addedAt: nil))
        let since = Date(timeIntervalSince1970: 300)
        try store.setPendingAvatar("a", ref: Data([0xC]), since: since)
        XCTAssertTrue(try store.setAvatarKeepingPending("a", Data([3])))
        var row = try XCTUnwrap(store.contact("a"))
        XCTAssertEqual(row.pendingAvatarRef, Data([0xC]))
        XCTAssertEqual(row.pendingAvatarSince, since)

        XCTAssertTrue(try store.setPendingAvatar("a", ref: Data([0xD]), since: since))
        row = try XCTUnwrap(store.contact("a"))
        XCTAssertEqual(row.avatar, Data([3]))
        XCTAssertEqual(row.pendingAvatarRef, Data([0xD]))

        XCTAssertFalse(try store.setPendingAvatar("nobody", ref: Data([1]), since: since))
        XCTAssertFalse(try store.setAvatarKeepingPending("nobody", Data([1])))
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
        XCTAssertNotEqual(try store.contact("me")?.isContact, true)
        XCTAssertFalse(try store.contacts().contains { $0.id == "me" })
    }

    func testADeleteSaysWhetherThereWasARow() throws {
        try store.insert(.new(id: "gone", isContact: true, addedAt: nil))
        XCTAssertTrue(try store.delete("gone"))
        XCTAssertNil(try store.contact("gone"))
        XCTAssertFalse(try store.delete("gone"), "a second delete finds nothing")
    }
}

/// The same cases on the crate.
final class LocalStoreContactStoreTests: ContactStoreTests {
    override func makeStore() -> Store {
        LocalStoreContactStore(session: .inMemoryForTesting())
    }
}

/// What only the Core Data implementation has: its columns, the `User` object screens still
/// hold, and the chat cascade through its relationships (the crate's is `delete_contact`, tested
/// there).
final class CoreDataContactStoreTests: XCTestCase {

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
    }

    /// The record names a person the way a `User` does — one rule, not two. Mutation: let
    /// `ContactRecord.resolvedDisplayName` skip the alias.
    func testTheNameShownIsTheSameAsTheRows() throws {
        let row = try seed("b") { $0.username = "bea"; $0.displayName = "Bea"; $0.localAlias = "Mum" }
        XCTAssertEqual(try store.contact("b")?.resolvedDisplayName, row.resolvedDisplayName)
        XCTAssertEqual(try store.contact("b")?.resolvedDisplayName, "Mum")
    }

    /// Our profile is our row in the same table here.
    func testOurProfileIsOurRow() throws {
        try seed("me") { $0.username = "max"; $0.displayName = "Max"; $0.avatarData = Data([5]); $0.profileEditedAtMs = 3 }
        XCTAssertEqual(try store.profile(accountId: "me"), OwnProfileRecord(
            accountId: "me", username: "max", displayName: "Max", avatar: Data([5]), profileEditedAtMs: 3
        ))
    }

    /// The row, its chat and the chat's messages; another contact's chat stays. Mutation: delete
    /// only the `User` with `chats` set to nullify — the chat stays.
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
        XCTAssertNil(try chats.chat(gone.id))
        XCTAssertEqual(try chats.chat(kept.id)?.peerId, "kept")
        context.refreshAllObjects()
        XCTAssertEqual(try context.count(for: Message.fetchRequest()), 0)
    }
}
