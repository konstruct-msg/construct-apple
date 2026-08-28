//
//  SelfAddressedResidueTests.swift
//  ConstructMessengerTests
//
//  The cleanup removes what the self-addressed path created and nothing else. The "nothing else"
//  half is the one worth testing: this runs unattended on every install.
//
//  Acceptance is mutation-based; each test names the mutation that must redden it.
//

import XCTest
import CoreData
import CryptoKit
@testable import Construct_Messenger

@MainActor
final class SelfAddressedResidueTests: XCTestCase {

    private let ourAccount = "ffeeddc6-14f2-4d02-a66a-caf0d8dfeda8"
    private let peerAccount = "7574fdec-2c1a-4a0f-9d3e-1b0b6f2c9a41"
    private var context: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        context = PersistenceController(inMemory: true).container.viewContext
    }

    override func tearDown() {
        context = nil
        super.tearDown()
    }

    @discardableResult
    private func makeUser(id: String, pinned: Bool) -> User {
        let user = User(context: context)
        user.id = id
        if pinned {
            user.knownIdentityKey = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        }
        return user
    }

    @discardableResult
    private func makeChat(with user: User, messages: Int) -> Chat {
        let chat = Chat(context: context)
        chat.id = UUID().uuidString
        chat.otherUser = user
        for _ in 0..<messages {
            let msg = Message(context: context)
            msg.id = UUID().uuidString
            msg.chat = chat
            msg.timestamp = Date()
        }
        return chat
    }

    private func count<T: NSManagedObject>(_ type: T.Type, _ entity: String) -> Int {
        let req = NSFetchRequest<NSFetchRequestResult>(entityName: entity)
        return (try? context.count(for: req)) ?? 0
    }

    // MARK: - What must go

    /// The chat in the list, and the transcript of reflected traffic under it.
    ///
    /// Mutation: drop the `Chat` deletion — this reddens.
    func testTheChatWithOurselvesAndItsMessagesAreRemoved() {
        let me = makeUser(id: ourAccount, pinned: false)
        makeChat(with: me, messages: 3)
        try? context.save()
        XCTAssertEqual(count(Chat.self, "Chat"), 1)
        XCTAssertEqual(count(Message.self, "Message"), 3)

        let outcome = SelfAddressedResidue.clearStoredRows(ourAccountId: ourAccount, in: context)

        XCTAssertEqual(outcome.chatsRemoved, 1)
        XCTAssertEqual(count(Chat.self, "Chat"), 0)
        XCTAssertEqual(count(Message.self, "Message"), 0, "messages cascade with the chat")
    }

    /// More than one was created — the stand produced two in the same second.
    ///
    /// Mutation: delete only the first match (`fetchLimit = 1`) — this reddens.
    func testEveryChatWithOurselvesIsRemoved() {
        let me = makeUser(id: ourAccount, pinned: false)
        makeChat(with: me, messages: 1)
        makeChat(with: me, messages: 1)
        try? context.save()

        let outcome = SelfAddressedResidue.clearStoredRows(ourAccountId: ourAccount, in: context)
        XCTAssertEqual(outcome.chatsRemoved, 2)
        XCTAssertEqual(count(Chat.self, "Chat"), 0)
    }

    /// The stray pin. It is not cosmetic: `identityKey(ofDevice:in:)` scans every row that holds
    /// one, so a key pinned on our own row can answer for a device it does not belong to.
    ///
    /// Mutation: leave `knownIdentityKey` alone — this reddens.
    func testThePinOnOurOwnRowIsCleared() {
        let me = makeUser(id: ourAccount, pinned: true)
        try? context.save()
        XCTAssertNotNil(me.knownIdentityKey)

        let outcome = SelfAddressedResidue.clearStoredRows(ourAccountId: ourAccount, in: context)

        XCTAssertTrue(outcome.pinCleared)
        XCTAssertNil(me.knownIdentityKey)
    }

    // MARK: - What must stay

    /// The local profile row is legitimate — `AuthViewModel.loadUserFromCoreData` creates it on
    /// purpose and the app reads its username and display name. Only the chat hanging off it is
    /// residue, and the `otherUser` relationship nullifies rather than cascades.
    ///
    /// Mutation: delete the `User` row along with the chat — this reddens, and on a device it
    /// would take the signed-in user's profile with it.
    func testOurOwnProfileRowSurvives() {
        let me = makeUser(id: ourAccount, pinned: true)
        me.username = "maxim"
        me.displayName = "Maxim"
        makeChat(with: me, messages: 2)
        try? context.save()

        SelfAddressedResidue.clearStoredRows(ourAccountId: ourAccount, in: context)

        let req = User.fetchRequest()
        req.predicate = NSPredicate(format: "id == %@", ourAccount)
        let survivor = try? context.fetch(req).first
        XCTAssertNotNil(survivor, "the local profile must not be deleted")
        XCTAssertEqual(survivor?.username, "maxim")
    }

    /// A real contact's chat, transcript and pinned key are untouched. This is the assertion that
    /// makes the cleanup safe to run unattended.
    ///
    /// Mutation: drop the `otherUser.id == ourAccountId` predicate, or clear the pin on every row
    /// rather than ours — either reddens.
    func testAContactIsLeftEntirelyAlone() {
        let me = makeUser(id: ourAccount, pinned: true)
        let peer = makeUser(id: peerAccount, pinned: true)
        let peerKey = peer.knownIdentityKey
        makeChat(with: me, messages: 1)
        makeChat(with: peer, messages: 4)
        try? context.save()

        let outcome = SelfAddressedResidue.clearStoredRows(ourAccountId: ourAccount, in: context)

        XCTAssertEqual(outcome.chatsRemoved, 1, "only the chat with ourselves")
        XCTAssertEqual(count(Chat.self, "Chat"), 1)
        XCTAssertEqual(count(Message.self, "Message"), 4, "the contact's transcript is intact")
        XCTAssertEqual(peer.knownIdentityKey, peerKey, "a contact's pinned key is not residue")
    }

    /// An account that never had a second device has nothing to clear, and the cleanup must say so
    /// rather than report work it did not do — the log line is how a device confirms it was clean.
    ///
    /// Mutation: return a non-empty outcome unconditionally — this reddens.
    func testACleanAccountReportsNothingRemoved() {
        makeUser(id: peerAccount, pinned: true)
        try? context.save()

        let outcome = SelfAddressedResidue.clearStoredRows(ourAccountId: ourAccount, in: context)
        XCTAssertTrue(outcome.isEmpty)
        XCTAssertEqual(outcome, SelfAddressedResidue.Outcome())
    }

    /// Running twice removes nothing the second time — the flag is an optimisation, not the thing
    /// that makes this safe.
    func testRunningTwiceIsRunningOnce() {
        let me = makeUser(id: ourAccount, pinned: true)
        makeChat(with: me, messages: 2)
        try? context.save()

        let first = SelfAddressedResidue.clearStoredRows(ourAccountId: ourAccount, in: context)
        let second = SelfAddressedResidue.clearStoredRows(ourAccountId: ourAccount, in: context)

        XCTAssertFalse(first.isEmpty)
        XCTAssertTrue(second.isEmpty)
    }

    /// No account id names nobody. Without this the predicate would match every row whose
    /// `otherUser.id` is empty.
    ///
    /// Mutation: drop the empty guard — this reddens.
    func testAnEmptyAccountIdClearsNothing() {
        let nameless = makeUser(id: "", pinned: true)
        makeChat(with: nameless, messages: 1)
        try? context.save()

        let outcome = SelfAddressedResidue.clearStoredRows(ourAccountId: "", in: context)
        XCTAssertTrue(outcome.isEmpty)
        XCTAssertEqual(count(Chat.self, "Chat"), 1)
    }

    // MARK: - The one-shot wrapper

    /// A launch where the store is not ready must not record the work as done — otherwise the
    /// cleanup retires on the one launch it could not run.
    ///
    /// Mutation: set the flag before the readiness guard — this reddens.
    func testAnUnreadyStoreDoesNotRetireTheCleanup() {
        let defaults = UserDefaults(suiteName: "residue.\(UUID().uuidString)")!
        let detached = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        XCTAssertNil(detached.persistentStoreCoordinator)

        SelfAddressedResidue.clearIfNeeded(
            ourAccountId: ourAccount, in: detached, defaults: defaults
        )
        XCTAssertFalse(
            defaults.bool(forKey: "construct.selfAddressedResidue.cleared.v1"),
            "an unrun cleanup must stay pending"
        )
    }
}
