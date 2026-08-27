//
//  InviteSystemCompletionTests.swift
//  ConstructMessengerTests
//
//  Closing coverage for INVITE_SYSTEM_IMPROVEMENT_PLAN implementable surface:
//  v4 codec, canonical strings, fingerprint, TOFU pin, call gate, config.
//

import XCTest
import CoreData
import CryptoKit
@testable import Construct_Messenger

@MainActor
final class InviteSystemCompletionTests: XCTestCase {

    // MARK: - Fixtures

    private var container: NSPersistentContainer!

    override func setUp() {
        super.setUp()
        container = PersistenceController(inMemory: true).container
    }

    override func tearDown() {
        container = nil
        super.tearDown()
    }

    private func validSig() -> String {
        Data(repeating: 0xCD, count: 64).base64EncodedString()
    }

    private func validEph() -> String {
        Data(repeating: 0xAB, count: 32).base64EncodedString()
    }

    private func sampleV4(un: String? = nil, ts: Int = 1_738_156_800) -> InviteObject {
        InviteObject(
            v: 4,
            jti: "550e8400-e29b-41d4-a716-446655440000",
            uuid: "14f28d31-1234-4abc-8def-0123456789ab",
            deviceId: "4e1f9dbe209c1bedb33ee32dda5a28f0",
            server: "konstruct.cc",
            ephKey: "",
            ts: ts,
            sig: validSig(),
            un: un,
            ttl: nil
        )
    }

    private func sampleV3() -> InviteObject {
        InviteObject(
            v: 3,
            jti: "550e8400-e29b-41d4-a716-446655440000",
            uuid: "14f28d31-1234-4abc-8def-0123456789ab",
            deviceId: "4e1f9dbe209c1bedb33ee32dda5a28f0",
            server: "konstruct.cc",
            ephKey: validEph(),
            ts: 1_738_156_800,
            sig: validSig(),
            un: "alice",
            ttl: nil
        )
    }

    // MARK: - Config / version

    func testCurrentVersionIsV4() {
        XCTAssertEqual(InviteConfig.currentVersion, 4)
        XCTAssertTrue(InviteConfig.supportedVersions.contains(4))
        XCTAssertFalse(InviteConfig.carriesEphKey(version: 4))
        XCTAssertTrue(InviteConfig.carriesEphKey(version: 3))
    }

    /// `ttlDescription` is interpolated straight into user-facing copy ("Одноразовая
    /// ссылка, действует %@"). `DateComponentsFormatter.string(from:)` returns an
    /// Optional, and the `?? ""` behind it would turn a nil into a sentence that just
    /// stops — visible to the user, invisible to the compiler.
    ///
    /// NOT COVERED: MultiInviteView itself. That every tap of [ещё одна] yields a
    /// *distinct* invite rests on `UUID()` inside `InviteGenerator.generate`, which needs
    /// a signing key from `CryptoManager.shared.orchestratorCore` and so cannot be reached
    /// from here. On device the answer is five different `jti=` prefixes in the
    /// "Generated invite v4" log lines.
    func testTTLDescriptionIsNeverEmpty() {
        XCTAssertFalse(
            InviteConfig.ttlDescription.isEmpty,
            "UI copy interpolates this — an empty value ships a sentence with a hole in it."
        )
    }

    /// Rotation is what makes "show my QR to several people" work: an invite is burned by
    /// its first redeemer and the sender never learns it happened, so the second scanner of
    /// a static code is told the invite is already used.
    ///
    /// It was deleted on 2026-08-13 alongside the TTL change, on the reasoning that at 12
    /// hours each rotation mints another long-lived capability. That traded a working
    /// scenario for a threat that does not scale — a screenshot captures one code either
    /// way. [[decisions/invite-two-modes-deferred]] had already recorded rotation as
    /// load-bearing for personal-invite mode. Restored the same day; this test exists so
    /// the next person to find it wasteful reads the reason first.
    func testQRRotatesFastEnoughForSequentialScanners() {
        XCTAssertGreaterThan(InviteConfig.qrRotateIntervalSeconds, 0, "Rotation removed — the second person to scan the same screen will be told the invite is already used.")
        XCTAssertLessThanOrEqual(
            InviteConfig.qrRotateIntervalSeconds, 60,
            "Rotation slower than a minute stops covering the case it exists for: people scanning one after another."
        )
        XCTAssertLessThan(InviteConfig.qrRotateIntervalSeconds, InviteConfig.ttlSeconds)
    }

    /// The invite TTL has three carriers: this constant, `INVITE_TTL_SECONDS` in
    /// construct-server (`crates/crypto-agility/src/invites.rs`), and the burn-row
    /// retention derived from it. They are two languages in two repositories, so no
    /// build can compare them.
    ///
    /// This is therefore a **ratchet, not a proof**. It fails when the client number
    /// moves, and its message is the instruction to move the other two. It CANNOT tell
    /// you the server was redeployed with the new value — the symptom of that gap is a
    /// redeem rejected as "expired" on a link the sender's app still shows as live, and
    /// the only place that answer exists is the identity-service log line
    /// `Invite validation failed … error=Expired`.
    ///
    /// 2026-08-13: 300 → 43200. Five minutes meant a copied link expired in the
    /// clipboard before the recipient opened it; the QR, rotated every 30s and scanned
    /// on the spot, never hit it. That asymmetry read as "links are broken".
    func testInviteTTLMatchesServerConstant() {
        XCTAssertEqual(
            InviteConfig.ttlSeconds, 43_200,
            "Client invite TTL changed. construct-server INVITE_TTL_SECONDS (and the "
                + "INVITE_BURN_RETENTION_SECONDS derived from it) must move with it — the "
                + "server checks expiry first, so a client-only change is invisible."
        )
    }

    /// Guards the arithmetic in `isExpired`, not the policy: a sign error or a
    /// seconds/minutes mixup inside it survives the pin above, because that one only
    /// compares the constant to itself.
    ///
    /// The second half is the case that must NOT fire. A rule that expires invites can
    /// misfire, and rejecting a still-valid invite is worse than the bug it fixes: the
    /// sender sees a live code and the recipient is told to ask for a new one.
    func testInviteIsLiveJustInsideTTLAndDeadJustOutside() {
        let now = Date().timeIntervalSince1970

        let almostExpired = sampleV4(ts: Int(now - InviteConfig.ttlSeconds + 60))
        XCTAssertFalse(
            almostExpired.isExpired(),
            "An invite one minute short of the TTL is still live — rejecting it strands a "
                + "sender whose code is visibly counting down."
        )

        let justExpired = sampleV4(ts: Int(now - InviteConfig.ttlSeconds - 60))
        XCTAssertTrue(justExpired.isExpired())
    }

    // MARK: - Canonical string (signing surface)

    func testCanonicalV4HasNoEphKey() throws {
        let c = try sampleV4(un: "bob").canonicalString()
        XCTAssertEqual(
            c,
            "4|550e8400-e29b-41d4-a716-446655440000|14f28d31-1234-4abc-8def-0123456789ab|4e1f9dbe209c1bedb33ee32dda5a28f0|konstruct.cc|1738156800|bob"
        )
        XCTAssertFalse(c.contains(validEph().prefix(8)))
    }

    func testCanonicalV3StillHasEphKey() throws {
        let c = try sampleV3().canonicalString()
        XCTAssertTrue(c.contains(validEph()))
        XCTAssertTrue(c.hasPrefix("3|"))
        XCTAssertTrue(c.hasSuffix("|alice"))
    }

    func testCanonicalV4EmptyUn() throws {
        let c = try sampleV4(un: nil).canonicalString()
        XCTAssertTrue(c.hasSuffix("|"))
    }

    // MARK: - Validate

    func testV4RejectsNonEmptyEph() {
        let base = sampleV4()
        let invite = InviteObject(
            v: 4,
            jti: base.jti,
            uuid: base.uuid,
            deviceId: base.deviceId,
            server: base.server,
            ephKey: validEph(),
            ts: base.ts,
            sig: validSig(),
            un: nil,
            ttl: nil
        )
        XCTAssertThrowsError(try invite.validate())
    }

    func testV4RejectsBadDeviceId() {
        let invite = InviteObject(
            v: 4,
            jti: sampleV4().jti,
            uuid: sampleV4().uuid,
            deviceId: "not-hex",
            server: "konstruct.cc",
            ephKey: "",
            ts: 1_738_156_800,
            sig: validSig(),
            un: nil,
            ttl: nil
        )
        XCTAssertThrowsError(try invite.validate())
    }

    func testExpiry() {
        let past = sampleV4(ts: 1_000_000_000) // 2001
        XCTAssertTrue(past.isExpired(ttl: 300))
        let now = Int(Date().timeIntervalSince1970)
        let fresh = sampleV4(ts: now)
        XCTAssertFalse(fresh.isExpired(ttl: 300))
    }

    // MARK: - Binary dual-read

    func testBase64URLRoundTripStableCanonical() throws {
        let original = sampleV4(un: "carol")
        let wire = try original.toBase64URL()
        XCTAssertFalse(wire.contains("+"))
        XCTAssertFalse(wire.contains("/"))
        XCTAssertFalse(wire.contains("="))
        let decoded = try InviteObject.fromBase64(wire)
        XCTAssertEqual(try decoded.canonicalString(), try original.canonicalString())
    }

    func testLegacyJSONStillDecodable() throws {
        let v3 = sampleV3()
        let json = try JSONEncoder().encode(v3)
        let decoded = try InviteObject.decodePayload(json)
        XCTAssertEqual(decoded.v, 3)
        XCTAssertEqual(decoded.un, "alice")
    }

    func testTruncatedBinaryFails() {
        var bytes = try! sampleV4().encodeBinary()
        bytes = bytes.prefix(10)
        XCTAssertThrowsError(try InviteObject.decodeBinary(Data(bytes)))
    }

    // MARK: - Identity fingerprint (thread 5.3)

    func testFingerprintFormat() {
        let key = Data(repeating: 0x42, count: 32)
        let fp = IdentityFingerprint.short(from: key)
        XCTAssertNotNil(fp)
        // 4 groups of 4 hex chars
        let parts = fp!.split(separator: " ").map(String.init)
        XCTAssertEqual(parts.count, 4)
        for p in parts {
            XCTAssertEqual(p.count, 4)
            XCTAssertEqual(p, p.uppercased())
        }
    }

    func testFingerprintDeterministicAndDiffers() {
        let a = Data(repeating: 0x01, count: 32)
        let b = Data(repeating: 0x02, count: 32)
        XCTAssertEqual(IdentityFingerprint.short(from: a), IdentityFingerprint.short(from: a))
        XCTAssertNotEqual(IdentityFingerprint.short(from: a), IdentityFingerprint.short(from: b))
    }

    func testFingerprintEmptyKey() {
        XCTAssertNil(IdentityFingerprint.short(from: Data()))
    }

    func testFingerprintCompact() {
        let key = Data(repeating: 0xAA, count: 32)
        let compact = IdentityFingerprint.compact(from: key)
        XCTAssertEqual(compact?.count, 16)
        XCTAssertFalse(compact!.contains(" "))
    }

    // MARK: - Safety number (two-party)

    /// The view's own implementation was deleted on 2026-08-27; this now exercises the core's,
    /// which is the only one. Shape and symmetry stay here; the values live in
    /// `SafetyNumberConformanceTests` against the cross-client vectors.
    func testSafetyNumberSymmetric() {
        let a = "4e1f9dbe209c1bedb33ee32dda5a28f0"
        let b = "abcdef0123456789abcdef0123456789"
        let ab = computeSafetyNumber(myDeviceId: a, theirDeviceId: b)
        let ba = computeSafetyNumber(myDeviceId: b, theirDeviceId: a)
        XCTAssertEqual(ab, ba)
        XCTAssertNotNil(ab)
        // 12 groups of 5 digits
        let groups = (ab ?? "").split(separator: " ")
        XCTAssertEqual(groups.count, 12)
    }

    // MARK: - ContactPolicy / TOFU pin

    func testPinThenChangeMarksKeyChanged() {
        let ctx = container.viewContext
        let id = "14f28d31-aaaa-4abc-8def-0123456789ab"
        let k1 = Data(repeating: 0x11, count: 32)
        let k2 = Data(repeating: 0x22, count: 32)

        let user = User(context: ctx)
        user.id = id
        user.username = ""
        user.displayName = "T"
        user.isContact = true
        user.isBlocked = false
        user.isSharingWithMe = false
        user.amISharingWith = false
        user.addedAt = Date()
        try! ctx.save()

        ContactLinkService.shared.pinKnownIdentityKey(on: user, identityKey: k1)
        XCTAssertEqual(user.knownIdentityKey, k1)
        XCTAssertNotEqual(user.ktStatus, .keyChanged)

        ContactLinkService.shared.pinKnownIdentityKey(on: user, identityKey: k2)
        XCTAssertEqual(user.knownIdentityKey, k2)
        XCTAssertEqual(user.ktStatus, .keyChanged)
    }

    func testApplyInviteRedeemSetsContactAndPin() throws {
        let ctx = container.viewContext
        let id = "14f28d31-bbbb-4abc-8def-0123456789ab"
        let key = Data(repeating: 0x33, count: 32)
        let info = ContactInfo(
            userId: id,
            deviceId: "4e1f9dbe209c1bedb33ee32dda5a28f0",
            username: id, // placeholder → should not store as username
            ephemeralKey: nil,
            isDynamic: true,
            identityPublicKey: key
        )
        let user = try ContactLinkService.shared.applyInviteRedeem(info, context: ctx)
        XCTAssertTrue(user.isContact)
        XCTAssertEqual(user.knownIdentityKey, key)
        // Username placeholder stripped
        XCTAssertTrue(user.username.isEmpty || user.username != id)
    }

    func testCallableContactAfterRedeem() throws {
        let ctx = container.viewContext
        let id = "14f28d31-cccc-4abc-8def-0123456789ab"
        let info = ContactInfo(
            userId: id,
            deviceId: nil,
            username: "dave",
            ephemeralKey: nil,
            isDynamic: true,
            identityPublicKey: Data(repeating: 0x44, count: 32)
        )
        _ = try ContactLinkService.shared.applyInviteRedeem(info, context: ctx)
        XCTAssertTrue(ContactPolicy.isCallableContact(id, in: ctx))
    }

    // MARK: - Latin-1 QR recovery + magic

    func testCompactBinaryMagicIsCIv1() throws {
        let data = try sampleV4().encodeBinary()
        XCTAssertTrue(InviteObject.isCompactBinary(data))
        XCTAssertEqual(Data(data.prefix(4)), InviteObject.binaryMagic)
    }

    func testLatin1RoundTripPreservesMagic() throws {
        let binary = try sampleV4().encodeBinary()
        let latin1 = String(binary.map { Character(UnicodeScalar($0)) })
        let recovered = InviteBinaryCodec.dataFromLatin1QRString(latin1)
        XCTAssertEqual(recovered, binary)
    }
}
