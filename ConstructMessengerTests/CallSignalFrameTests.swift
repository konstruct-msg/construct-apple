//
//  CallSignalFrameTests.swift
//  ConstructMessengerTests
//
//  The layout of an encrypted ICE candidate: a version byte and the core's wire payload.
//
//  Every layout before v4 failed by dropping fields. v2 dropped `suiteId`, `pqMessageEpoch` and
//  `pqRatchetField`, so every candidate over a suite-3 session failed — 100 % of them, both
//  directions, a call with no media path. v3 dropped the PN field and had no room for the
//  responder's answer to the initiator's KEM identity key. v4 lists no fields: the payload is the
//  core's, and these tests check that it passes through untouched.
//
//  Acceptance is mutation-based. Each test names the mutation that must redden it.
//

import XCTest
@testable import Construct_Messenger

final class CallSignalFrameTests: XCTestCase {

    private typealias Frame = CallSignalFrame

    /// A payload the core packed: a responder's reply, which carries the answer to the initiator's
    /// KEM identity key — the field v3 had no room for.
    private func realPayload() throws -> Data {
        let (alice, aliceId) = try makeTestDevice()
        let (bob, bobId) = try makeTestDevice()
        _ = try alice.initSession(contactId: bobId, recipientBundle: try bob.pqxdhTestBundle())
        let first = try alice.encryptToWire(contactId: bobId, plaintext: Data("offer".utf8))
        _ = try bob.pqxdhTestReceive(from: alice, first: first)
        return try bob.encryptToWire(contactId: aliceId, plaintext: Data("candidate".utf8))
    }

    /// The payload comes back byte for byte, so every field the core wrote reaches the core.
    ///
    /// Mutation: have `encode` or `decode` rebuild the payload from anything but its bytes.
    func testThePayloadSurvivesByteForByte() throws {
        let payload = try realPayload()
        XCTAssertNotNil(
            try wirePayloadUnpack(data: [UInt8](payload)).identityProofCiphertext,
            "the fixture must carry the answer to the KEM identity key"
        )
        XCTAssertEqual(try Frame.decode(Frame.encode(wirePayload: payload)), payload)
    }

    /// `bytes` has no shape of its own: without the version check a foreign or older frame would
    /// be handed to the core as a payload. A v3 frame from an older build is refused here.
    ///
    /// Mutation: drop `frame[frame.startIndex] == version` from the guard.
    func testAFrameOfAnotherVersionIsRefused() throws {
        var frame = Frame.encode(wirePayload: try realPayload())
        frame[frame.startIndex] = 0x03
        XCTAssertThrowsError(try Frame.decode(frame))
    }

    /// A version byte and nothing after it carries no payload.
    ///
    /// Mutation: relax `frame.count > 1`.
    func testAnEmptyFrameIsRefused() {
        XCTAssertThrowsError(try Frame.decode(Data()))
        XCTAssertThrowsError(try Frame.decode(Data([Frame.version])))
    }

    /// A `Data` slice carries a non-zero `startIndex`, and absolute-index reads trap on it. The
    /// decoder is handed slices in production — `IceCandidate.candidate` arrives inside a decoded
    /// proto.
    ///
    /// Mutation: read `frame[0]` instead of `frame[frame.startIndex]`.
    func testDecodingASliceWithANonZeroOriginWorks() throws {
        let payload = try realPayload()
        let padded = Data(repeating: 0xAA, count: 100) + Frame.encode(wirePayload: payload)
        let slice = padded[100...]
        XCTAssertNotEqual(slice.startIndex, 0, "the fixture must actually be a slice")
        XCTAssertEqual(try Frame.decode(slice), payload)
    }
}
