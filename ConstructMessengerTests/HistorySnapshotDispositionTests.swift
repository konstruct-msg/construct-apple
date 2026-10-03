//
//  HistorySnapshotDispositionTests.swift
//  ConstructMessengerTests
//
//  The importer's own policy, one named test per mutation. The protocol's rules (manifest,
//  record order, phases, envelope ↔ manifest, the QR fingerprint) moved into construct-core
//  with their tests on 2026-09-29.
//

import XCTest
@testable import Construct_Messenger

final class HistorySnapshotDispositionTests: XCTestCase {

    /// Mutation: a live row with the same id is overwritten.
    func testExistingMessageIsKeepExisting() {
        XCTAssertEqual(HistorySnapshotDisposition.messageConflict(existing: true), .keepExisting)
        XCTAssertEqual(HistorySnapshotDisposition.messageConflict(existing: false), .insert)
    }

    /// Mutation: chat upsert uses Chat.id from the offering device.
    func testChatUpsertKeyIsOtherUserIdNeverChatId() {
        let peer = Data(repeating: 0xAB, count: 16)
        XCTAssertEqual(HistorySnapshotDisposition.chatUpsertKey(otherUserId: peer), peer)
    }

    /// Mutation: snapshot false clobbers a profile-true on the receiver.
    func testShareFlagDoesNotClobberTrue() {
        XCTAssertTrue(HistorySnapshotDisposition.contactShareFlag(snapshot: false, alreadyTrueOnReceiver: true))
        XCTAssertTrue(HistorySnapshotDisposition.contactShareFlag(snapshot: true, alreadyTrueOnReceiver: false))
        XCTAssertFalse(HistorySnapshotDisposition.contactShareFlag(snapshot: false, alreadyTrueOnReceiver: false))
    }

    /// Mutation: peer hint is accepted without derive_device_id.
    func testHintIdNotMatchingIdentityKeyIsRejected() {
        let key = Data(repeating: 0x11, count: 32)
        let derived = deriveDeviceId(identityPublicKey: key)
        XCTAssertTrue(HistorySnapshotDisposition.peerDeviceHintAcceptable(deviceId: derived, identityKey: key))
        XCTAssertFalse(
            HistorySnapshotDisposition.peerDeviceHintAcceptable(deviceId: String(repeating: "0", count: 32), identityKey: key)
        )
    }

    /// Mutation: ids are compared case-sensitively and a mixed-case UUID misses.
    func testMessageIdIsLowercased() {
        XCTAssertEqual(
            HistorySnapshotDisposition.lowercaseMessageId("AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"),
            "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        )
    }

    private let me = "11111111-1111-1111-1111-111111111111"
    private let peer = "22222222-2222-2222-2222-222222222222"

    /// Mutation: an unparseable `from` is dropped from the wire, so the receiver refuses the record
    /// and the whole phase ends. This is the row a real phone sent: received, `from` empty.
    func testReceivedRowWithEmptySenderNamesTheChatPeer() {
        let who = HistorySnapshotDisposition.participants(
            storedFrom: "", storedTo: me, isSentByMe: false, ownId: me, chatPeerId: peer
        )
        XCTAssertEqual(who.from, peer)
        XCTAssertEqual(who.to, me)
    }

    /// Mutation: the role is ignored and a sent row's missing sender is filled with the peer.
    func testSentRowWithDeviceIdAsSenderNamesUs() {
        let who = HistorySnapshotDisposition.participants(
            storedFrom: "6f5e37ac6f5e37ac6f5e37ac6f5e37ac", storedTo: peer,
            isSentByMe: true, ownId: me, chatPeerId: peer
        )
        XCTAssertEqual(who.from, me)
        XCTAssertEqual(who.to, peer)
    }

    /// Mutation: a stored value that parses is replaced by the role's guess.
    func testValidStoredIdsAreKept() {
        let other = "33333333-3333-3333-3333-333333333333"
        let who = HistorySnapshotDisposition.participants(
            storedFrom: other, storedTo: me, isSentByMe: false, ownId: me, chatPeerId: peer
        )
        XCTAssertEqual(who.from, other)
    }

    /// No peer known and the stored side unparseable: nothing to invent.
    func testNoPeerNoGuess() {
        let who = HistorySnapshotDisposition.participants(
            storedFrom: "", storedTo: me, isSentByMe: false, ownId: me, chatPeerId: nil
        )
        XCTAssertNil(who.from)
    }
}
