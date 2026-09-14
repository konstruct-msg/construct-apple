//
//  BinaryParserOriginTests.swift
//  ConstructMessengerTests
//
//  Regression tests for the Data index-origin trap in the binary parsers that take
//  peer-controlled input.
//
//  `Data` slices carry ABSOLUTE indices: `bigData[100...]` has `startIndex == 100`. A parser
//  that counts offsets from 0, bounds-checks against `count`, and calls `subdata(in:)` — which
//  also takes absolute indices — traps on its first subscript when handed such a slice. The
//  These parsers now normalise the origin on
//  entry so they cannot depend on how the caller happened to build the Data.
//
//  See sessions/2026-07-28-ios-appstore-security-stability-audit.md.
//

import XCTest
@testable import Construct_Messenger

final class BinaryParserOriginTests: XCTestCase {

    // MARK: - Helpers

    private func sampleProfile() -> ProfileShareData {
        ProfileShareData(
            displayName: "Alice Example",
            avatarMediaId: "media-123",
            avatarMediaUrl: "https://example.invalid/a.jpg",
            avatarMediaKey: Data(repeating: 0x5A, count: 32),
            avatarMediaType: "image/jpeg",
            timestamp: 1_753_700_000
        )
    }

    /// Wraps `data` so it comes back as a slice with a non-zero `startIndex`.
    private func asSlice(_ data: Data, pad: Int) -> Data {
        let padded = Data(repeating: 0xFF, count: pad) + data
        let slice = padded[pad...]
        XCTAssertEqual(slice.startIndex, pad, "precondition: slice must carry a non-zero origin")
        return slice
    }

    // MARK: - ProfileShareData

    func testProfileShareRoundTripsFromZeroOriginData() throws {
        let original = sampleProfile()
        let decoded = try XCTUnwrap(ProfileShareData.fromBinaryData(original.toBinaryData()))

        XCTAssertEqual(decoded.displayName, original.displayName)
        XCTAssertEqual(decoded.avatarMediaId, original.avatarMediaId)
        XCTAssertEqual(decoded.avatarMediaUrl, original.avatarMediaUrl)
        XCTAssertEqual(decoded.avatarMediaKey, original.avatarMediaKey)
        XCTAssertEqual(decoded.avatarMediaType, original.avatarMediaType)
        XCTAssertEqual(decoded.timestamp, original.timestamp)
    }

    /// THE regression: the same bytes delivered as a non-zero-origin slice must decode
    /// identically instead of trapping.
    func testProfileShareRoundTripsFromNonZeroOriginSlice() throws {
        let original = sampleProfile()
        let sliced = asSlice(original.toBinaryData(), pad: 137)

        let decoded = try XCTUnwrap(ProfileShareData.fromBinaryData(sliced))
        XCTAssertEqual(decoded.displayName, original.displayName)
        XCTAssertEqual(decoded.avatarMediaKey, original.avatarMediaKey)
        XCTAssertEqual(decoded.timestamp, original.timestamp)
    }

    func testProfileShareRejectsTruncatedInput() {
        let full = sampleProfile().toBinaryData()
        // Every proper prefix is either rejected or decodes without trapping; the point is that
        // none of them crash the parser.
        for cut in stride(from: 1, to: full.count, by: 3) {
            _ = ProfileShareData.fromBinaryData(full.prefix(cut))
        }
        XCTAssertNil(ProfileShareData.fromBinaryData(Data()))
        XCTAssertNil(ProfileShareData.fromBinaryData(Data([0x01])), "version byte only")
    }

    func testProfileShareRejectsWrongVersionByte() {
        var wrong = sampleProfile().toBinaryData()
        wrong[0] = 0x02
        XCTAssertNil(ProfileShareData.fromBinaryData(wrong))
    }

    /// An oversized length prefix must be rejected by the bounds check, not read past the end.
    func testProfileShareRejectsOversizedLengthPrefix() {
        var hostile = Data([0x01])                       // version
        hostile.append(contentsOf: [0xFF, 0xFF])         // displayName length = 65535
        hostile.append(contentsOf: [0x41, 0x42, 0x43])   // …but only 3 bytes follow
        XCTAssertNil(ProfileShareData.fromBinaryData(hostile))
    }

    // MARK: - InviteObject binary reader

    func testInviteDecodesFromNonZeroOriginSlice() throws {
        let original = sampleInvite()
        let sliced = asSlice(try original.encodeBinary(), pad: 64)

        let decoded = try InviteObject.decodeBinary(sliced)
        XCTAssertEqual(try decoded.canonicalString(), try original.canonicalString())
    }

    func testInviteRejectsTruncatedSliceWithoutTrapping() throws {
        let sliced = asSlice(try sampleInvite().encodeBinary(), pad: 11)
        XCTAssertThrowsError(try InviteObject.decodeBinary(sliced.dropLast(4)))
    }

    private func sampleInvite() -> InviteObject {
        InviteObject(
            v: 4,
            jti: "550e8400-e29b-41d4-a716-446655440000",
            uuid: "14f28d31-1234-4abc-8def-0123456789ab",
            deviceId: "4e1f9dbe209c1bedb33ee32dda5a28f0",
            server: "konstruct.cc",
            ephKey: "",
            ts: 1_738_156_800,
            sig: Data(repeating: 0xCD, count: 64).base64EncodedString(),
            un: "alice",
            ttl: nil
        )
    }
}
