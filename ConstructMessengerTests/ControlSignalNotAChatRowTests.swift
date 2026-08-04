//
//  ControlSignalNotAChatRowTests.swift
//  ConstructMessengerTests
//
//  A handshake ping must never become a chat bubble.
//
//  It did. When ping/ready moved into KNST byte 5 (`cf157f64`) the envelope started carrying
//  `.unspecified` for them — the point of the change, since the server should learn nothing. But
//  `SessionCoordinator.saveMessage`, the session-init persistence path, still asked the envelope
//  what the message was. It got "ordinary message" for every ping and persisted the binary
//  `SessionControl` payload as a row. `MessageRouter` was updated to read the frame; this second
//  dispatch site was not, and nothing failed — the same one-fact-two-carriers shape the frame move
//  was supposed to end.
//
//  Two independent defences, because one of them had been silently load-bearing: the type must be
//  readable from the frame when the envelope says nothing, and a control payload that reaches
//  storage anyway must still be classified as control rather than text.
//

import XCTest
@testable import Construct_Messenger

final class ControlSignalNotAChatRowTests: XCTestCase {

    private func pingFrame(nonce: String = UUID().uuidString) -> Data {
        ChunkedMessageCodec.frameWhole(
            SessionControlCodec.encodePayload(op: .ping, nonce: nonce),
            contentType: 25,
            messageId: UUID()
        )
    }

    /// The regression itself: envelope says nothing, frame says ping. Reading the envelope alone
    /// yields no op, which is exactly how the payload reached the transcript.
    func testPingIsRecognisableFromTheFrameWhenTheEnvelopeSaysNothing() throws {
        let control = try XCTUnwrap(ChunkedMessageCodec.controlFrame(pingFrame()),
                                    "a single-chunk control frame must parse")
        XCTAssertEqual(SessionControlCodec.op(forContentType: Int(control.contentType)), .ping,
                       "the frame carries the type now — this is the only place it can be read")
        XCTAssertNil(SessionControlCodec.op(forContentType: 0),
                     "the envelope is .unspecified on purpose; a site that asks only it sees an ordinary message")
    }

    /// `ready` travels the same way, and would have leaked identically.
    func testReadyIsRecognisableFromTheFrame() throws {
        let frame = ChunkedMessageCodec.frameWhole(
            SessionControlCodec.encodePayload(op: .ready, nonce: "n"),
            contentType: 26,
            messageId: UUID()
        )
        let control = try XCTUnwrap(ChunkedMessageCodec.controlFrame(frame))
        XCTAssertEqual(SessionControlCodec.op(forContentType: Int(control.contentType)), .ready)
    }

    /// Second line of defence. The at-rest classifier used to recognise control payloads by their
    /// magic-string prefixes; `SessionControl` is not a string, so once the strings were gone it
    /// was blind. A leaked ping was therefore stamped `.regular` and rendered.
    func testBinaryControlPayloadIsClassifiedAsControlNotText() {
        let ping = SessionControlCodec.encodePayload(op: .ping, nonce: UUID().uuidString)
        XCTAssertEqual(MessageContentType.infer(from: ping), .sessionPing,
                       "a bare SessionControl body must never be stamped .regular — .regular renders")

        let ready = SessionControlCodec.encodePayload(op: .ready, nonce: "n")
        XCTAssertEqual(MessageContentType.infer(from: ready), .sessionReady)
    }

    /// And the classifier must not start eating ordinary messages: `.regular` is what makes a
    /// message visible, so a false positive here silently deletes user text from the transcript.
    /// That is a worse failure than the leak it guards against.
    func testOrdinaryTextIsStillRegular() {
        for text in ["Привет", "hello", "9", "", "{\"type\":\"voice\"}", String(repeating: "a", count: 500)] {
            XCTAssertEqual(MessageContentType.infer(from: Data(text.utf8)), .regular,
                           "\(text.prefix(20)) must stay visible")
        }
    }

    /// A CTM1-wrapped text body whose bytes happen to look protobuf-ish must also stay visible —
    /// the binary check is deliberately confined to raw, unwrapped bodies.
    func testWrappedTextIsNeverMistakenForControl() {
        let wrapped = LocalMessagePayload.encodeText("\u{08}\u{01}\u{12}$not-a-control-signal")
        XCTAssertEqual(MessageContentType.infer(from: wrapped), .regular)
    }
}
