//
//  InviteV5TTLTests.swift
//  ConstructMessengerTests
//
//  Created 2026-08-16.
//

import XCTest
@testable import Construct_Messenger

/// v5: a signed, per-invite TTL, so a QR stops inheriting the link's twelve hours.
///
/// Two failures are being guarded against, and they fail in opposite directions.
///
/// The loud one: the canonical string. It used to end in a `default:` carrying the v4
/// shape, so a v5 token would have been signed over a string with no `ttl` — and the
/// resulting error, once the server built the string *with* `ttl`, reads `InvalidSignature`
/// and points at keys.
///
/// The quiet one: a `ttl` dropped somewhere between decode and the server. Everything looks
/// right on this device — the invite verifies locally, because both sides of the local
/// comparison lost the same field.
final class InviteV5TTLTests: XCTestCase {

    private let jti  = "550e8400-e29b-41d4-a716-446655440000"
    private let user = "14f28d31-1234-4abc-8def-0123456789ab"
    private let dev  = "4e1f9dbe209c1bedb33ee32dda5a28f0"
    private let ts   = 1_738_156_800

    private func invite(v: Int, ttl: UInt32?, un: String? = "alice") -> InviteObject {
        InviteObject(
            v: v,
            jti: jti,
            uuid: user,
            deviceId: dev,
            server: "konstruct.cc",
            ephKey: v <= 3 ? Data(repeating: 0xAB, count: 32).base64EncodedString() : "",
            ts: ts,
            sig: Data(repeating: 0xCD, count: 64).base64EncodedString(),
            un: un,
            ttl: ttl
        )
    }

    // MARK: - The canonical string

    /// Must match `InviteToken::canonical_string` in crypto-agility, which appends `ttl`
    /// after `username`. Spelled out literally rather than derived, because a test that
    /// builds the string the same way the code does cannot catch the code building it wrong.
    func testV5CanonicalEndsWithTTL() throws {
        let c = try invite(v: 5, ttl: 300).canonicalString()
        XCTAssertEqual(
            c,
            "5|\(jti)|\(user)|\(dev)|konstruct.cc|\(ts)|alice|300"
        )
    }

    func testV5CanonicalKeepsTheEmptyUsernameSlot() throws {
        let c = try invite(v: 5, ttl: 300, un: nil).canonicalString()
        XCTAssertEqual(c, "5|\(jti)|\(user)|\(dev)|konstruct.cc|\(ts)||300")
    }

    /// v4 bytes must not move. Anything in flight was signed over this exact shape.
    func testV4CanonicalIsUntouchedByV5() throws {
        let c = try invite(v: 4, ttl: nil).canonicalString()
        XCTAssertEqual(c, "4|\(jti)|\(user)|\(dev)|konstruct.cc|\(ts)|alice")
        XCTAssertFalse(c.hasSuffix("|300"))
    }

    /// The regression this file is named for. `default:` used to return the v4 shape for
    /// every version above 4 — silently, and only on this side.
    func testAnUnknownVersionRefusesToProduceACanonicalString() {
        XCTAssertThrowsError(try invite(v: 6, ttl: 300).canonicalString()) { error in
            guard case InviteValidationError.unsupportedVersion(let v) = error else {
                return XCTFail("expected unsupportedVersion, got \(error)")
            }
            XCTAssertEqual(v, 6)
        }
    }

    /// A v5 that lost its `ttl` must not fall back to the v4 string, which would verify
    /// locally and fail on the server.
    func testAV5WithoutTTLCannotBeSigned() {
        XCTAssertThrowsError(try invite(v: 5, ttl: nil).canonicalString()) { error in
            guard case InviteValidationError.missingTTL = error else {
                return XCTFail("expected missingTTL, got \(error)")
            }
        }
    }

    // MARK: - Validation, mirroring the server

    func testV5RequiresATTL() {
        XCTAssertThrowsError(try invite(v: 5, ttl: nil).validate())
    }

    /// Rule 6: below one minute is refused before it is signed, rather than after the
    /// server refuses it.
    func testTTLBelowTheFloorIsRefused() {
        XCTAssertThrowsError(try invite(v: 5, ttl: InviteConfig.minTTLSeconds - 1).validate())
        XCTAssertNoThrow(try invite(v: 5, ttl: InviteConfig.minTTLSeconds).validate())
    }

    /// Rule 7: an overshoot is clamped, not rejected. Refusing it here while the server
    /// accepts-and-clamps would make the two disagree about the same token.
    func testATTLAboveTheServerMaximumIsAcceptedAndClamped() throws {
        let overshoot = UInt32(InviteConfig.ttlSeconds) + 10_000
        XCTAssertNoThrow(try invite(v: 5, ttl: overshoot).validate())
        XCTAssertEqual(
            invite(v: 5, ttl: overshoot).effectiveTTLSeconds,
            InviteConfig.ttlSeconds,
            "the server takes min(max, ttl); showing anything longer would outlive the truth"
        )
    }

    func testAPreV5InviteMustNotCarryATTL() {
        XCTAssertThrowsError(try invite(v: 4, ttl: 300).validate())
    }

    func testAPreV5InviteGetsTheGlobalTTL() {
        XCTAssertEqual(invite(v: 4, ttl: nil).effectiveTTLSeconds, InviteConfig.ttlSeconds)
    }

    func testAV5InviteLivesForItsStatedTTL() {
        XCTAssertEqual(invite(v: 5, ttl: 300).effectiveTTLSeconds, 300)
    }

    // MARK: - The binary container

    func testV5BinaryRoundTripCarriesTheTTL() throws {
        let original = invite(v: 5, ttl: 300)
        let decoded = try InviteObject.decodeBinary(try original.encodeBinary())
        XCTAssertEqual(decoded.ttl, 300)
        XCTAssertEqual(try decoded.canonicalString(), try original.canonicalString())
    }

    /// Presence is decided by the version, so a v5 blob is exactly four bytes longer than
    /// the same invite at v4 — no flag byte, nothing else moved.
    func testV5CostsFourBytesOverV4() throws {
        let v4 = try invite(v: 4, ttl: nil).encodeBinary()
        let v5 = try invite(v: 5, ttl: 300).encodeBinary()
        XCTAssertEqual(v5.count - v4.count, 4)
    }

    func testV5BinarySurvivesTheTextBoundary() throws {
        let original = invite(v: 5, ttl: 300)
        let decoded = try InviteObject.fromBase64(try original.toBase64URL())
        XCTAssertEqual(decoded.ttl, 300)
    }

    // MARK: - Rollout

    /// Reading a version ships before writing it. If this ever reads `false` while
    /// `inviteV5Minting` is off, this build mints something its own peers refuse.
    func testThisBuildReadsV5() {
        XCTAssertTrue(InviteConfig.supportedVersions.contains(5))
    }

    /// The flag is the only thing that decides which version is minted — so that turning it
    /// on is one edit, and leaving it off cannot half-apply.
    func testMintedVersionFollowsTheFlag() {
        XCTAssertEqual(
            InviteConfig.currentVersion,
            FeatureFlags.inviteV5Minting ? 5 : 4
        )
        XCTAssertEqual(
            InviteConfig.carriesTTL(version: InviteConfig.currentVersion),
            FeatureFlags.inviteV5Minting
        )
    }

    /// The number that makes the QR change worth doing: live codes in a sitting are
    /// TTL/rotation. At twelve hours that is 1440 and bulk revocation is unusable; at five
    /// minutes it is ten.
    func testAQRSittingStaysSmallOnceItHasItsOwnTTL() {
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

    /// The quiet failure named at the top of this file. `ttl` was droppable from the
    /// AcceptInvite mapping with the entire suite still green, because the mapping lived as
    /// twelve assignments inside a 90-line networking method that no test could reach.
    ///
    /// Every field the server rebuilds its canonical string from is checked here, not just
    /// the new one: whichever of them goes missing next produces the same symptom — a
    /// signature the server rejects and this device accepts.
    func testEveryCanonicalFieldSurvivesTheAcceptInviteMapping() {
        let source = invite(v: 5, ttl: 300)
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
        XCTAssertTrue(token.hasTtl)
    }

    /// A v4 invite must arrive with no `ttl` at all. Sending 0 or 43200 "to be safe" would
    /// make the server build a v5-shaped string for a v4 token.
    func testAV4InviteCarriesNoTTLAcrossTheBoundary() {
        let token = LinkParser.protoToken(from: invite(v: 4, ttl: nil))
        XCTAssertFalse(token.hasTtl)
    }

    // MARK: - The journal

    func testAJournalledMintExpiresOnItsOwnTTLNotTheGlobalOne() {
        let now = Date()
        let qr = InviteIssuance.Mint(jti: "qr", at: now.addingTimeInterval(-600), ttl: 300)
        let link = InviteIssuance.Mint(jti: "link", at: now.addingTimeInterval(-600), ttl: nil)
        XCTAssertFalse(qr.isLive(at: now), "ten minutes is past a five-minute code")
        XCTAssertTrue(link.isLive(at: now), "and nowhere near a twelve-hour one")
    }

    /// Entries written before v5 decode with no `ttl` and keep the life they had, so the
    /// stored journal needs no migration.
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
