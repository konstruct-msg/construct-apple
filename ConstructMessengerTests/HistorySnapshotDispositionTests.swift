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
}
