//
//  SenderSyncRoutingTests.swift
//  ConstructMessengerTests
//
//  SENDER_SYNC is the copy of an outgoing message a device sends to the sender's own other
//  devices. Placing it needs one fact the envelope cannot supply — who the other party of the
//  conversation is — because on the wire the sender and the recipient are both the local user.
//
//  It used to be read from `Envelope.conversation_id`, which the server blanks on delivery on
//  purpose ("server-visible metadata must not carry E2E semantics"). So every SENDER_SYNC was
//  unroutable since the feature shipped: observed 2026-08-05, and again 2026-08-17, three of
//  three in one session. The partner id now rides inside the ciphertext.
//
//  Acceptance is mutation-based; each test names the mutation that must redden it.
//

import XCTest
@testable import Construct_Messenger

final class SenderSyncRoutingTests: XCTestCase {

    private let partner = "7574fdec-ca31-44ac-9d43-0e6e870fe4d5"

    // MARK: - The round trip

    /// The whole point: what goes on before chunking comes off after reassembly, and the content
    /// behind it is untouched.
    ///
    /// Mutation: drop the header in `encoded()` — the partner is gone and the copy is unplaceable
    /// again, which is the state this replaces.
    func testPartnerSurvivesTheRoundTrip() throws {
        let content = Data("the message body".utf8)
        let header = try XCTUnwrap(SenderSyncRouting(partnerUserId: partner).encoded())

        let split = try XCTUnwrap(SenderSyncRouting.decode(prefixOf: header + content))

        XCTAssertEqual(split.routing.partnerUserId, partner)
        XCTAssertEqual(split.remainder, content, "the content must come out byte-for-byte")
    }

    /// The header is fixed width, so a body that happens to start with plausible bytes cannot
    /// shift where the content begins.
    func testHeaderIsExactlyTwentyBytes() throws {
        let header = try XCTUnwrap(SenderSyncRouting(partnerUserId: partner).encoded())
        XCTAssertEqual(header.count, SenderSyncRouting.headerSize)
        XCTAssertEqual(header.count, 20)
    }

    /// An empty message body is still a valid framing — nothing about the header depends on what
    /// follows it.
    func testEmptyContentStillYieldsTheRouting() throws {
        let header = try XCTUnwrap(SenderSyncRouting(partnerUserId: partner).encoded())
        let split = try XCTUnwrap(SenderSyncRouting.decode(prefixOf: header))
        XCTAssertEqual(split.routing.partnerUserId, partner)
        XCTAssertTrue(split.remainder.isEmpty)
    }

    // MARK: - What must not be mistaken for a header

    /// A sender running a build from before this change sends the content with no header. That
    /// must read as "no routing", not as a header made of the first 20 bytes of the message —
    /// which would both invent a partner and eat the start of the text.
    ///
    /// Mutation: return a routing value instead of nil when the magic is absent.
    func testContentWithoutAHeaderIsNotDecodedAsOne() {
        let legacy = Data("KNST-ish bytes that are really just the message".utf8)
        XCTAssertNil(
            SenderSyncRouting.decode(prefixOf: legacy),
            "an old sender's payload must fall through to the unroutable path, not be truncated"
        )
    }

    /// Too short to hold a header, and the magic is absent as well.
    func testShortPayloadIsNotDecodedAsAHeader() {
        XCTAssertNil(SenderSyncRouting.decode(prefixOf: Data("SSR1".utf8)))
        XCTAssertNil(SenderSyncRouting.decode(prefixOf: Data()))
    }

    /// Right magic, zeroed id — what damaged bytes decode to. Routing every damaged sync into one
    /// phantom conversation is worse than dropping it, because the conversation looks real.
    ///
    /// Mutation: remove the all-zero check.
    func testAllZeroPartnerIsRejected() {
        var framed = Data(SenderSyncRouting.magic)
        framed.append(Data(repeating: 0, count: 16))
        framed.append(Data("body".utf8))
        XCTAssertNil(SenderSyncRouting.decode(prefixOf: framed))
    }

    // MARK: - What cannot be encoded

    /// A partner id that is not a UUID yields no header rather than a malformed one: a bad header
    /// would be stripped as if valid and would take the first bytes of the message with it.
    ///
    /// Mutation: encode a zero UUID instead of returning nil — the send then looks fine and the
    /// receiver silently loses 20 bytes off the front of every message.
    func testNonUuidPartnerYieldsNoHeader() {
        XCTAssertNil(SenderSyncRouting(partnerUserId: "annie").encoded())
        XCTAssertNil(SenderSyncRouting(partnerUserId: "").encoded())
    }

    /// Case and formatting of the incoming id must not change what is carried: the id is compared
    /// against Core Data rows, and two spellings of one user are two conversations.
    func testPartnerIsNormalisedToLowercase() throws {
        let header = try XCTUnwrap(SenderSyncRouting(partnerUserId: partner.uppercased()).encoded())
        let split = try XCTUnwrap(SenderSyncRouting.decode(prefixOf: header))
        XCTAssertEqual(split.routing.partnerUserId, partner)
    }
}
