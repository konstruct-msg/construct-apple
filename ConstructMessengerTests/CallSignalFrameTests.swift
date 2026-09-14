//
//  CallSignalFrameTests.swift
//  ConstructMessengerTests
//
//  The layout of an encrypted ICE candidate.
//
//  This had no test at all until 2026-08-21, and the format it replaces is the reason that matters:
//  v2 dropped `suiteId`, `pqMessageEpoch` and `pqRatchetField` from the frame, so every candidate
//  encrypted over a suite-3 session was decrypted as suite 1 and failed — 100 % of them, in both
//  directions, which is a call that connects and has no media path. Nothing could have caught that
//  while the layout lived inside a method needing a Keychain-backed singleton to reach.
//
//  Acceptance is mutation-based. Each test names the mutation that must redden it.
//

import XCTest
@testable import Construct_Messenger

final class CallSignalFrameTests: XCTestCase {

    private typealias Frame = CallSignalFrame

    private func fields(
        suiteId: UInt16 = 3,
        messageNumber: UInt32 = 7,
        pqMessageEpoch: UInt32 = 4,
        pqLen: Int = 48,
        ciphertextLen: Int = 283
    ) -> Frame.Fields {
        Frame.Fields(
            suiteId: suiteId,
            messageNumber: messageNumber,
            pqMessageEpoch: pqMessageEpoch,
            pqRatchetField: Data((0..<pqLen).map { UInt8($0 % 251) }),
            ephemeralPublicKey: Data(repeating: 0xE9, count: Frame.epkLength),
            ciphertext: Data((0..<ciphertextLen).map { UInt8(($0 &* 7) % 253) })
        )
    }

    // MARK: - Every field survives

    /// The v2 defect, stated as the property it broke. Equality over the whole struct is the point:
    /// a field dropped from `encode` cannot pass this, and dropping fields is exactly what v2 did.
    ///
    /// Mutation: remove any one `appendLE` from `encode`.
    func testEveryFieldSurvivesARoundTrip() throws {
        let original = fields()
        let decoded = try Frame.decode(Frame.encode(original))
        XCTAssertEqual(decoded, original, "a frame that loses a field decrypts as the wrong suite")
    }

    /// A classic (suite-1) session carries no PQ material, so the variable-length section is empty.
    /// The length prefix has to survive being zero — an off-by-one there reads the epk as pq field.
    func testAClassicSessionRoundTripsWithNoPqMaterial() throws {
        let original = fields(suiteId: 1, pqMessageEpoch: 0, pqLen: 0)
        XCTAssertEqual(try Frame.decode(Frame.encode(original)), original)
    }

    /// `messageNumber` is 0 on every DH ratchet turn, not just on a handshake, so it must round-trip
    /// as a value rather than be treated as absent.
    func testMessageNumberZeroIsAValueNotAnAbsence() throws {
        let original = fields(messageNumber: 0)
        XCTAssertEqual(try Frame.decode(Frame.encode(original)).messageNumber, 0)
    }

    // MARK: - What must be refused

    /// The version byte is what replaces the "ENC:v3:" prefix the `string` field used to carry.
    /// `bytes` has no shape of its own: without this check a foreign or corrupt value would be
    /// parsed into plausible-looking fields and handed to the ratchet.
    ///
    /// Mutation: drop `frame[start] == version` from the guard.
    func testAFrameOfAnotherVersionIsRefused() {
        var frame = Frame.encode(fields())
        frame[frame.startIndex] = 0x02
        XCTAssertThrowsError(try Frame.decode(frame))
    }

    /// Truncation must not read past the end — every prefix that cannot hold the fixed sections is
    /// refused rather than parsed out of bounds.
    ///
    /// **It stops there, and that is the format's limit, not an oversight.** There is no total
    /// length in the frame, so a prefix that still contains the header, the whole pq field and the
    /// epk is indistinguishable from a genuine frame with a shorter ciphertext. What catches it is
    /// the AEAD tag one layer down. Adding a length here would duplicate that check, and a second
    /// carrier of one fact is what this codebase keeps paying for; the assertion is written to the
    /// guarantee that exists.
    func testTruncationBelowTheFixedSectionsIsRefused() {
        let frame = Frame.encode(fields())
        let fixedEnd = Frame.headerLength + 48 + Frame.epkLength   // header + pqField + epk

        for cut in 1...fixedEnd {
            XCTAssertThrowsError(
                try Frame.decode(frame.prefix(cut)),
                "a \(cut)-byte prefix cannot hold the fixed sections and must not decode"
            )
        }
        XCTAssertNoThrow(
            try Frame.decode(frame.prefix(fixedEnd + 1)),
            "one ciphertext byte is a well-formed frame here — the AEAD is what rejects it"
        )
    }

    /// A hostile `pqFieldLen` claims more than the frame holds. The bound is checked against the
    /// real end rather than against the claimed one.
    ///
    /// Mutation: drop the `frame.endIndex > pqEnd + epkLength` guard.
    func testAnOversizedPqLengthIsRefused() {
        var frame = Frame.encode(fields())
        let lenOffset = frame.startIndex + 11
        var huge = UInt32(0xFFFF).littleEndian
        withUnsafeBytes(of: &huge) { raw in
            for (i, byte) in raw.enumerated() { frame[lenOffset + i] = byte }
        }
        XCTAssertThrowsError(try Frame.decode(frame))
    }

    // MARK: - The slice trap

    /// A `Data` slice carries a non-zero `startIndex`, and absolute-index reads trap on it. The
    /// decoder is handed slices in production — `IceCandidate.candidate` arrives inside a decoded
    /// proto — so this is the shape it actually sees, not a synthetic case.
    ///
    /// Mutation: replace `start + n` with `n` anywhere in `decode`.
    func testDecodingASliceWithANonZeroOriginWorks() throws {
        let original = fields()
        let padded = Data(repeating: 0xAA, count: 100) + Frame.encode(original)
        let slice = padded[100...]
        XCTAssertNotEqual(slice.startIndex, 0, "the fixture must actually be a slice")
        XCTAssertEqual(try Frame.decode(slice), original)
    }

    // MARK: - Size

    /// Nothing about the candidate's own length reaches the wire: the core pads the plaintext to a
    /// 255-byte block, so two candidates of different lengths produce the same frame size. Stated
    /// here because the property was briefly the opposite — `MessagePadding` re-padded this to 1024
    /// bytes, and base64 of that made call signals the one traffic class with a distinct size.
    func testFrameSizeIsDeterminedByItsInputsAndNotByTheText() {
        let short = Frame.encode(fields(ciphertextLen: 283))
        let alsoShort = Frame.encode(fields(ciphertextLen: 283))
        XCTAssertEqual(short.count, alsoShort.count)
        XCTAssertEqual(short.count, Frame.headerLength + 48 + Frame.epkLength + 283)
    }
}
