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
}
