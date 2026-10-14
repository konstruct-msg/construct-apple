//
//  ContactSearchTests.swift
//  ConstructMessengerTests
//
//  What a search in Synapses and the chat list finds among the people we already hold: a miss
//  here sends the Synapses search to the network for someone already on the screen.
//

import XCTest
@testable import Construct_Messenger

final class ContactSearchTests: XCTestCase {

    /// The name the user gave someone is what the cloud shows, and it is not a stored name.
    func testOurAliasFindsThem() {
        var contact = record(username: "kestrel", displayName: "Kestrel")
        contact.localAlias = "Mum"
        XCTAssertTrue(contact.matches(query: "mum"))
    }

    /// With no shared name the cloud shows a name generated from the id; it is searchable too.
    func testTheGeneratedNameFindsThem() {
        let contact = record(username: "", displayName: "")
        let shown = contact.resolvedDisplayName
        XCTAssertFalse(shown.isEmpty)
        XCTAssertTrue(contact.matches(query: shown))
    }

    /// The search prompt says "@alias": the `@` is not part of the username.
    func testAnAtBeforeTheUsernameStillFindsThem() {
        let contact = record(username: "kestrel", displayName: "Someone")
        XCTAssertTrue(contact.matches(query: "@kes"))
        XCTAssertTrue(contact.matches(query: "  @kestrel "))
        XCTAssertEqual(ContactName.handle("@@kestrel "), "kestrel")
    }

    /// The shared name still finds them while our alias is the one shown.
    func testTheSharedNameFindsThemUnderAnAlias() {
        var contact = record(username: "kestrel", displayName: "Anna Petrova")
        contact.localAlias = "Mum"
        XCTAssertTrue(contact.matches(query: "petrova"))
    }

    func testSomeoneElseIsNotFound() {
        let contact = record(username: "kestrel", displayName: "Anna")
        XCTAssertFalse(contact.matches(query: "boris"))
        XCTAssertFalse(contact.matches(query: "@"))
        XCTAssertFalse(contact.matches(query: "   "))
    }

    private func record(username: String, displayName: String) -> ContactRecord {
        ContactRecord(
            id: "0f6c2b2e-6a51-4f43-9d0e-7a1b2c3d4e5f", username: username, displayName: displayName,
            localAlias: nil, avatar: nil, knownIdentityKey: nil, accountAddress: nil,
            isContact: true, isBlocked: false, isSharingWithMe: false, amISharingWith: false,
            sharedWithMeAt: nil, addedAt: nil, ktStatus: .unverified, securityNotice: .none,
            profileEditedAtMs: 0, pendingAvatarRef: nil, pendingAvatarSince: nil
        )
    }
}
