//
//  NearbyHandshakeFrameTests.swift
//  ConstructMessengerTests
//
//  Regression tests for the pre-auth crash in the Nearby transfer handshake.
//
//  The sender's opening frame is parsed BEFORE the PIN-HMAC exchange, so every byte
//  in it comes from any peer that can reach the Bonjour service. The receiver used to
//  narrow the announced payload length with `Int(UInt64(...))`, which traps above
//  `Int.max` — a 46-byte frame with `payloadLen = 0xFFFF_FFFF_FFFF_FFFF` crashed the
//  app outright, unauthenticated, from anywhere on the local network.
//
//  See sessions/2026-07-28-ios-appstore-security-stability-audit.md.
//

import XCTest
@testable import Construct_Messenger

@MainActor
final class NearbyHandshakeFrameTests: XCTestCase {

    private typealias Frame = NearbyTransferService.HandshakeFrame

    // MARK: - Helpers

    /// Builds a wire frame: [4]"CTT1" ‖ [1]version ‖ [32]senderPub ‖ [1]type ‖ [8]payloadLen LE
    private func makeFrame(
        magic: String = "CTT1",
        version: UInt8 = 0x01,
        senderPub: Data = Data(repeating: 0xAB, count: 32),
        type: UInt8 = 0x01,
        payloadLength: UInt64 = 1234
    ) -> Data {
        var frame = Data(magic.utf8)
        frame.append(version)
        frame.append(senderPub)
        frame.append(type)
        withUnsafeBytes(of: payloadLength.littleEndian) { frame.append(contentsOf: $0) }
        return frame
    }

    private func assertMalformed(
        _ frame: Data,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try Frame.parse(frame), message, file: file, line: line) { error in
            XCTAssertEqual(
                error as? NearbyTransferError, .malformedFrame,
                "\(message): expected .malformedFrame, got \(error)",
                file: file, line: line
            )
        }
    }

    // MARK: - The regression

    /// THE bug: an unauthenticated peer announcing a length above `Int.max` must be
    /// rejected, not trap the process.
    func testAnnouncedLengthAboveIntMaxIsRejectedNotFatal() throws {
        assertMalformed(
            makeFrame(payloadLength: UInt64.max),
            "UInt64.max payload length"
        )
        assertMalformed(
            makeFrame(payloadLength: UInt64(Int.max) + 1),
            "Int.max + 1 payload length"
        )
        assertMalformed(
            makeFrame(payloadLength: 0x8000_0000_0000_0000),
            "high-bit-set payload length"
        )
    }

    func testAnnouncedLengthIsBoundedWellBelowIntMax() {
        assertMalformed(
            makeFrame(payloadLength: Frame.maxPayloadBytes + 1),
            "one byte over the cap"
        )
    }

    func testAnnouncedLengthAtCapIsAccepted() throws {
        let frame = try Frame.parse(makeFrame(payloadLength: Frame.maxPayloadBytes))
        XCTAssertEqual(frame.payloadLength, Int(Frame.maxPayloadBytes))
    }

    // MARK: - Happy path

    func testValidFrameParses() throws {
        let pub = Data((0..<32).map { UInt8($0) })
        let frame = try Frame.parse(makeFrame(senderPub: pub, type: 0x02, payloadLength: 987_654))

        XCTAssertEqual(frame.senderPub, pub)
        XCTAssertEqual(frame.type, .historySync)
        XCTAssertEqual(frame.payloadLength, 987_654)
    }

    func testHistorySyncSkipFrameParsesAsControlTransfer() throws {
        let frame = try Frame.parse(makeFrame(type: 0x03, payloadLength: 0))

        XCTAssertEqual(frame.type, .historySyncSkipped)
        XCTAssertEqual(frame.payloadLength, 0)
    }

    func testHistorySyncSkipFromPhoneFinishesReceiverWithoutStagingPayload() {
        XCTAssertEqual(
            NearbyReceiveCompletionDisposition.decide(
                isHistorySyncMode: true,
                transferType: .historySyncSkipped
            ),
            .finishWithoutHistory
        )
    }

    func testHistorySyncSkipControlDoesNotBypassManualBackupImportValidation() {
        XCTAssertEqual(
            NearbyReceiveCompletionDisposition.decide(
                isHistorySyncMode: false,
                transferType: .historySyncSkipped
            ),
            .stagePayload
        )
    }

    func testZeroLengthPayloadIsAccepted() throws {
        XCTAssertEqual(try Frame.parse(makeFrame(payloadLength: 0)).payloadLength, 0)
    }

    // MARK: - Field validation

    func testRejectsBadMagic() {
        assertMalformed(makeFrame(magic: "XXXX"), "wrong magic")
    }

    func testRejectsUnknownVersion() {
        assertMalformed(makeFrame(version: 0x02), "unknown version")
        assertMalformed(makeFrame(version: 0x00), "zero version")
    }

    func testRejectsUnknownTransferType() {
        assertMalformed(makeFrame(type: 0x00), "type 0x00")
        assertMalformed(makeFrame(type: 0xFF), "type 0xFF")
    }

    func testRejectsWrongFrameLength() {
        assertMalformed(Data(), "empty frame")
        assertMalformed(makeFrame().dropLast(), "one byte short")
        assertMalformed(makeFrame() + Data([0x00]), "one byte long")
        assertMalformed(Data(repeating: 0, count: 45), "45 zero bytes")
    }

    // MARK: - Index origin

    /// `Data` slices carry absolute indices, so a parser that assumes a zero origin traps on
    /// its first subscript. `receiveExact` currently returns a fresh `Data`, but the parser
    /// must not depend on that.
    func testParsesFrameDeliveredAsNonZeroOriginSlice() throws {
        let padded = Data(repeating: 0xFF, count: 100) + makeFrame(payloadLength: 4242)
        let slice = padded[100...]

        XCTAssertNotEqual(slice.startIndex, 0, "precondition: slice must have a non-zero origin")
        XCTAssertEqual(try Frame.parse(slice).payloadLength, 4242)
    }

    func testRejectsOversizedLengthEvenWhenDeliveredAsSlice() {
        let padded = Data(repeating: 0xFF, count: 7) + makeFrame(payloadLength: UInt64.max)
        assertMalformed(padded[7...], "UInt64.max in a non-zero-origin slice")
    }
}
