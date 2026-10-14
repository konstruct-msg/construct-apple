//
//  InviteV5TTLTests.swift
//  ConstructMessengerTests
//
//  Created 2026-08-16.
//

import XCTest
@testable import Construct_Messenger

/// v5, the only invite version: a signed per-invite TTL and a signed account address.
///
/// Two failures are guarded against, and they fail in opposite directions.
///
/// The loud one: the canonical string. A field missing from it on one side reads as
/// `InvalidSignature` on the server and points at keys.
///
/// The quiet one: a field dropped between decode and the server, or between decode and the
/// contact. `addr` is the worst case — dropped, nothing fails at all: the contact is simply
/// written to by the server-assigned id forever.
final class InviteV5TTLTests: XCTestCase {

    private let jti  = "550e8400-e29b-41d4-a716-446655440000"
    private let user = "14f28d31-1234-4abc-8def-0123456789ab"
    private let dev  = "4e1f9dbe209c1bedb33ee32dda5a28f0"
    private let ts   = 1_738_156_800
    private let addr = Data(repeating: 0xAB, count: 32)

    private func invite(v: Int = 5, ttl: UInt32 = 300, un: String? = "alice", addr: Data? = nil) -> InviteObject {
        InviteObject(
            v: v,
            jti: jti,
            uuid: user,
            deviceId: dev,
            server: "konstruct.cc",
            ts: ts,
            sig: Data(repeating: 0xCD, count: 64).base64EncodedString(),
            un: un,
            ttl: ttl,
            addr: addr ?? self.addr
        )
    }

    // MARK: - The canonical string

    /// Must match `InviteToken::canonical_string` in crypto-agility. Spelled out literally
    /// rather than derived, because a test that builds the string the same way the code does
    /// cannot catch the code building it wrong.
    func testCanonicalEndsWithTTLThenAddress() throws {
        let c = try invite().canonicalString()
        XCTAssertEqual(
            c,
            "5|\(jti)|\(user)|\(dev)|konstruct.cc|\(ts)|alice|300|" + String(repeating: "ab", count: 32)
        )
    }

    func testCanonicalKeepsTheEmptyUsernameSlot() throws {
        let c = try invite(un: nil).canonicalString()
        XCTAssertTrue(c.hasPrefix("5|\(jti)|\(user)|\(dev)|konstruct.cc|\(ts)||300|"))
    }

    /// The address is signed: two invites that differ only in it sign different bytes.
    ///
    /// Mutation: drop `addr` from `canonicalString` — this reddens, and so does the vector.
    func testTheAddressIsSigned() throws {
        XCTAssertNotEqual(
            try invite().canonicalString(),
            try invite(addr: Data(repeating: 0xCD, count: 32)).canonicalString()
        )
    }

    /// Every other version is refused, older and newer alike.
    func testOnlyV5ProducesACanonicalString() {
        for v in [1, 2, 3, 4, 6] {
            XCTAssertThrowsError(try invite(v: v).canonicalString()) { error in
                guard case InviteValidationError.unsupportedVersion(let got) = error else {
                    return XCTFail("expected unsupportedVersion, got \(error)")
                }
                XCTAssertEqual(got, v)
            }
            XCTAssertThrowsError(try invite(v: v).validate())
        }
    }

    // MARK: - Validation, mirroring the server

    /// Rule 6: below one minute is refused before it is signed, rather than after the
    /// server refuses it.
    func testTTLBelowTheFloorIsRefused() {
        XCTAssertThrowsError(try invite(ttl: InviteConfig.minTTLSeconds - 1).validate())
        XCTAssertNoThrow(try invite(ttl: InviteConfig.minTTLSeconds).validate())
    }

    /// Rule 7: an overshoot is clamped, not rejected. Refusing it here while the server
    /// accepts-and-clamps would make the two disagree about the same token.
    func testATTLAboveTheServerMaximumIsAcceptedAndClamped() throws {
        let overshoot = UInt32(InviteConfig.ttlSeconds) + 10_000
        XCTAssertNoThrow(try invite(ttl: overshoot).validate())
        XCTAssertEqual(
            invite(ttl: overshoot).effectiveTTLSeconds,
            InviteConfig.ttlSeconds,
            "the server takes min(max, ttl); showing anything longer would outlive the truth"
        )
    }

    func testAnInviteLivesForItsStatedTTL() {
        XCTAssertEqual(invite(ttl: 300).effectiveTTLSeconds, 300)
    }

    /// Mutation: drop the length check in `validate` — this reddens.
    func testAnAddressThatIsNotAKeyIsRefused() {
        for count in [0, 31, 33] {
            XCTAssertThrowsError(try invite(addr: Data(repeating: 1, count: count)).validate()) { error in
                guard case InviteValidationError.invalidAddress = error else {
                    return XCTFail("expected invalidAddress, got \(error)")
                }
            }
        }
    }

    // MARK: - The binary container

    func testBinaryRoundTripCarriesTTLAndAddress() throws {
        let original = invite()
        let decoded = try InviteObject.decodeBinary(try original.encodeBinary())
        XCTAssertEqual(decoded, original)
    }

    func testBinarySurvivesTheTextBoundary() throws {
        let original = invite()
        XCTAssertEqual(try InviteObject.fromBase64(try original.toBase64URL()), original)
    }

    // MARK: - QR sitting

    /// The number that makes the QR's own TTL worth having: live codes in a sitting are
    /// TTL/rotation. At twelve hours that is 1440 and bulk revocation is unusable; at five
    /// minutes it is ten.
    func testAQRSittingStaysSmall() {
        let codes = Double(InviteConfig.qrTTLSeconds) / InviteConfig.qrRotateIntervalSeconds
        XCTAssertLessThanOrEqual(codes, 20)
        XCTAssertGreaterThanOrEqual(
            codes, 2,
            "a sitting must outlive at least one rotation, or a scanner one beat behind fails"
        )
    }

    func testQRTTLIsShorterThanTheLinkTTL() {
        XCTAssertLessThan(TimeInterval(InviteConfig.qrTTLSeconds), InviteConfig.ttlSeconds)
        XCTAssertGreaterThanOrEqual(InviteConfig.qrTTLSeconds, InviteConfig.minTTLSeconds)
    }

    // MARK: - The redeem boundary

    /// Every field the server rebuilds its canonical string from, checked across the
    /// AcceptInvite mapping — whichever goes missing produces a signature the server rejects
    /// and this device accepts. `addr` is also the field the server checks against the
    /// account's recovery key.
    ///
    /// Mutation: drop `token.addr = invite.addr` from `protoToken` — this reddens.
    func testEveryCanonicalFieldSurvivesTheAcceptInviteMapping() {
        let source = invite()
        let token = LinkParser.protoToken(from: source)

        XCTAssertEqual(token.v, 5)
        XCTAssertEqual(token.jti, source.jti)
        XCTAssertEqual(token.uuid, source.uuid)
        XCTAssertEqual(token.deviceID, source.deviceId)
        XCTAssertEqual(token.server, source.server)
        XCTAssertEqual(token.ts, Int64(source.ts))
        XCTAssertEqual(token.un, source.un)
        XCTAssertEqual(token.sig, source.sig)
        XCTAssertEqual(token.ttl, 300)
        XCTAssertEqual(token.addr, source.addr)
        XCTAssertTrue(token.ephPub.isEmpty, "the server refuses a v5 that carries one")
    }

    // MARK: - The journal

    func testAJournalledMintExpiresOnItsOwnTTLNotTheGlobalOne() {
        let now = Date()
        let qr = InviteIssuance.Mint(jti: "qr", at: now.addingTimeInterval(-600), ttl: 300)
        let link = InviteIssuance.Mint(jti: "link", at: now.addingTimeInterval(-600), ttl: nil)
        XCTAssertFalse(qr.isLive(at: now), "ten minutes is past a five-minute code")
        XCTAssertTrue(link.isLive(at: now), "and nowhere near a twelve-hour one")
    }

    /// Entries written before every invite stated a TTL decode with none and keep the life
    /// they had, so the stored journal needs no migration.
    func testAJournalWrittenBeforeV5StillDecodes() throws {
        let legacy = Data(#"[{"id":"\#(UUID().uuidString)","kind":"link","mints":[{"jti":"old","at":0}]}]"#.utf8)
        let acts = try JSONDecoder().decode([InviteIssuance].self, from: legacy)
        XCTAssertEqual(acts.first?.mints.first?.ttl, nil)
        XCTAssertEqual(acts.first?.mints.first?.livesFor, InviteConfig.ttlSeconds)
    }

    /// An act holding codes with different lives expires with the last one to die, which is
    /// not the same as the latest timestamp once a short code can be minted after a long one.
    func testAnActExpiresWithItsLongestLivedCode() {
        let start = Date()
        let act = InviteIssuance(kind: .qrSession, mints: [
            InviteIssuance.Mint(jti: "long",  at: start, ttl: nil),
            InviteIssuance.Mint(jti: "short", at: start.addingTimeInterval(60), ttl: 300),
        ])
        XCTAssertEqual(
            act.expiresAt().timeIntervalSince1970,
            start.addingTimeInterval(InviteConfig.ttlSeconds).timeIntervalSince1970,
            accuracy: 0.001
        )
    }
}
