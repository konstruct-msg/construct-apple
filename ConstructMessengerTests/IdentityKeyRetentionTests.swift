//
//  IdentityKeyRetentionTests.swift
//  ConstructMessengerTests
//
//  A sealed send needs the peer's `knownIdentityKey`. Four sites hold that key and each
//  independently decides whether to keep it — and every one of them declines silently:
//
//    • KeyServiceClient.recordAndCheckHybrid   — writes on .verified/.degraded/identity-changed,
//                                                and `guard let user … else { return }`
//    • KeyServiceClient.updateContactKTStatus  — writes on .verified only, same silent guard
//    • ContactLinkService.pinKnownIdentityKey  — same silent guard
//    • ChatManagementService.startChat         — only when an invite carried a key
//
//  When none of them kept it, `recipientIdentityKey` returns nil and every sealed send to that
//  peer fails closed with `StealthDowngradeBlocked` — permanently, because nothing retries the
//  pin. That is TODO #45, and the reason it could not be attributed to a branch from a device log
//  is that the loss itself was never logged.
//
//  `rememberIdentityKeyIfUnknown` is the backstop, called on every accepted bundle fetch. These
//  tests pin what it must and must not do — in particular that it fills an absence and never
//  overrides a pin, since a changed key is a security event owned by the KT and invite paths.
//

import XCTest
import CoreData
@testable import Construct_Messenger

@MainActor
final class IdentityKeyRetentionTests: XCTestCase {

    private var container: NSPersistentContainer!
    private var context: NSManagedObjectContext { container.viewContext }

    private let peerId = "14f28d31-1234-4abc-8def-0123456789ab"
    private let fetchedKey = Data(repeating: 0xA1, count: 32)
    private let pinnedKey = Data(repeating: 0xB2, count: 32)

    override func setUp() {
        super.setUp()
        container = PersistenceController(inMemory: true).container
    }

    override func tearDown() {
        container = nil
        super.tearDown()
    }

    @discardableResult
    private func makeUser(id: String, key: Data? = nil, isContact: Bool = true) -> User {
        let user = User(context: context)
        user.id = id
        user.isBlocked = false
        user.isSharingWithMe = false
        user.amISharingWith = false
        user.isContact = isContact
        user.addedAt = Date()
        user.applyServerUsername(nil, userId: id)
        user.knownIdentityKey = key
        try? context.save()
        return user
    }

    private func storedKey(for id: String) -> Data? {
        let fetch = User.fetchRequest()
        fetch.predicate = NSPredicate(format: "id == %@", id)
        fetch.fetchLimit = 1
        return (try? context.fetch(fetch))?.first?.knownIdentityKey
    }

    // MARK: - The regression: a fetched key must not be dropped

    /// The defect. A contact whose bundle was fetched and accepted, but whose key none of the
    /// partial writers kept, could never be sealed to again.
    func testKeyIsKeptForAContactThatHasNone() {
        makeUser(id: peerId)
        XCTAssertNil(storedKey(for: peerId))

        ContactLinkService.shared.rememberIdentityKeyIfUnknown(
            userId: peerId, identityKey: fetchedKey, source: "test", context: context
        )

        XCTAssertEqual(storedKey(for: peerId), fetchedKey)
        XCTAssertNotNil(
            StealthSenderService.recipientIdentityKey(recipientId: peerId, context: context),
            "the send path must now be able to seal — that is the whole point"
        )
    }

    /// The other silent drop: no `User` row at all. Fetching a peer's prekey bundle means a session
    /// with them is being established, so the row is needed regardless.
    func testRowIsCreatedWhenMissing() {
        XCTAssertNil(storedKey(for: peerId))

        ContactLinkService.shared.rememberIdentityKeyIfUnknown(
            userId: peerId, identityKey: fetchedKey, source: "test", context: context
        )

        XCTAssertEqual(storedKey(for: peerId), fetchedKey)
    }

    /// A row created to hold a key is not the user adding a contact. It must not appear as one.
    func testCreatedRowIsNotMarkedAsAContact() {
        ContactLinkService.shared.rememberIdentityKeyIfUnknown(
            userId: peerId, identityKey: fetchedKey, source: "test", context: context
        )

        let fetch = User.fetchRequest()
        fetch.predicate = NSPredicate(format: "id == %@", peerId)
        let user = (try? context.fetch(fetch))?.first
        XCTAssertNotNil(user)
        XCTAssertFalse(user!.isContact, "fetching a bundle is not the user adding someone")
    }

    // MARK: - What it must never do

    /// A changed key is a security event owned by the KT path and the invite path, both of which
    /// raise `.keyChanged` and notify the user. A backstop that also overwrote would either raise
    /// the alarm twice or, worse, replace a pinned key without raising it at all.
    ///
    /// Mutation: drop the `guard existing.knownIdentityKey == nil` and this goes red.
    func testAnExistingPinIsNeverOverwritten() {
        makeUser(id: peerId, key: pinnedKey)

        ContactLinkService.shared.rememberIdentityKeyIfUnknown(
            userId: peerId, identityKey: fetchedKey, source: "test", context: context
        )

        XCTAssertEqual(
            storedKey(for: peerId), pinnedKey,
            "silently replacing a pinned identity key would defeat key-change detection"
        )
    }

    /// Re-pinning the same key is a no-op, not a rewrite — the ordinary case on every re-fetch.
    func testRepinningTheSameKeyChangesNothing() {
        makeUser(id: peerId, key: fetchedKey)

        ContactLinkService.shared.rememberIdentityKeyIfUnknown(
            userId: peerId, identityKey: fetchedKey, source: "test", context: context
        )

        XCTAssertEqual(storedKey(for: peerId), fetchedKey)
    }

    /// An empty key is not a key. Pinning it would make `recipientIdentityKey` return an
    /// unusable value instead of nil, turning a fail-closed refusal into a crash in
    /// `Curve25519.KeyAgreement.PublicKey(rawRepresentation:)` further down the send path.
    func testAnEmptyKeyIsNotPinned() {
        makeUser(id: peerId)

        ContactLinkService.shared.rememberIdentityKeyIfUnknown(
            userId: peerId, identityKey: Data(), source: "test", context: context
        )

        XCTAssertNil(storedKey(for: peerId))
    }

    /// An empty user id must not mint a row keyed on nothing.
    func testAnEmptyUserIdCreatesNoRow() {
        ContactLinkService.shared.rememberIdentityKeyIfUnknown(
            userId: "", identityKey: fetchedKey, source: "test", context: context
        )

        let fetch = User.fetchRequest()
        XCTAssertEqual((try? context.count(for: fetch)) ?? -1, 0)
    }

    /// One peer's key must not land on another's row.
    func testPinningIsKeyedToTheRightPeer() {
        let otherId = "99999999-0000-4abc-8def-0123456789ab"
        makeUser(id: peerId)
        makeUser(id: otherId)

        ContactLinkService.shared.rememberIdentityKeyIfUnknown(
            userId: peerId, identityKey: fetchedKey, source: "test", context: context
        )

        XCTAssertEqual(storedKey(for: peerId), fetchedKey)
        XCTAssertNil(storedKey(for: otherId))
    }

    // MARK: - The read side stays fail-closed

    /// The resolver must keep returning nil rather than inventing a key — the sealed paths depend
    /// on that to fail closed instead of sending identified.
    func testResolverStillReturnsNilWithNoRow() {
        XCTAssertNil(StealthSenderService.recipientIdentityKey(recipientId: peerId, context: context))
    }

    func testResolverStillReturnsNilForARowWithoutAKey() {
        makeUser(id: peerId)
        XCTAssertNil(StealthSenderService.recipientIdentityKey(recipientId: peerId, context: context))
    }
}
