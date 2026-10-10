//
//  HistorySnapshotDispositionTests.swift
//  ConstructMessengerTests
//
//  The id and participant rules a pre-CTM1 row's export needs, one named test per mutation. The
//  import policy moved into construct-core (history::project) with its tests on 2026-10-10; the
//  protocol's rules on 2026-09-29.
//

import XCTest
@testable import Construct_Messenger

final class HistorySnapshotDispositionTests: XCTestCase {

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
