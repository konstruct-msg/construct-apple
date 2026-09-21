//
//  ReplyPreviewPayloadTests.swift
//  ConstructMessengerTests
//
//  A quoted attachment is a display projection, not a second carrier for its transport
//  descriptor. Voice replies once placed the complete JSON — including the media server URL —
//  into the visible reply strip and into QuotedMessage.text_preview.
//

import XCTest
@testable import Construct_Messenger

final class ReplyPreviewPayloadTests: XCTestCase {

    func testVoiceReplyCarriesTypeWithoutTransportDescriptor() throws {
        let voice = VoiceMessageContent(
            type: "voice",
            mediaId: "voice-id",
            mediaUrl: "grpc://media.example.test/files/voice-id",
            mediaKey: Data(repeating: 0xA5, count: 32),
            mediaType: "audio/m4a",
            size: 42,
            duration: 3.5,
            waveform: [0.1, 0.8],
            hash: "secret-hash"
        )
        let raw = String(decoding: try JSONEncoder().encode(voice), as: UTF8.self)

        let preview = try XCTUnwrap(ReplyPreviewPayload.projecting(originalContent: raw))
        XCTAssertEqual(preview.kind, .audio)
        XCTAssertNil(preview.text)

        let stored = try XCTUnwrap(preview.storedContent)
        XCTAssertFalse(stored.contains("grpc://"))
        XCTAssertFalse(stored.contains("voice-id"))
        XCTAssertFalse(stored.contains("secret-hash"))

        var quoted = Shared_Proto_Messaging_V1_QuotedMessage()
        preview.apply(to: &quoted)
        XCTAssertEqual(quoted.mediaType, .audio)
        XCTAssertFalse(quoted.hasTextPreview)
    }

    func testLegacyVoicePayloadIsSanitisedOnReceipt() throws {
        let voice = VoiceMessageContent(
            type: "voice",
            mediaId: "legacy-id",
            mediaUrl: "grpc://legacy.example.test/media",
            mediaKey: Data(repeating: 0x5A, count: 32),
            mediaType: "audio/m4a",
            size: 7,
            duration: 1,
            waveform: [],
            hash: "legacy-hash"
        )
        let raw = String(decoding: try JSONEncoder().encode(voice), as: UTF8.self)

        let preview = try XCTUnwrap(
            ReplyPreviewPayload.receiving(textPreview: raw, mediaType: nil)
        )

        XCTAssertEqual(preview.kind, .audio)
        XCTAssertNil(preview.text)
        XCTAssertFalse(try XCTUnwrap(preview.storedContent).contains("grpc://"))
    }

    func testTypedQuoteOverrideCannotReintroduceVoiceDescriptor() throws {
        let voice = VoiceMessageContent(
            type: "voice",
            mediaId: "override-id",
            mediaUrl: "grpc://override.example.test/media",
            mediaKey: Data(repeating: 0x11, count: 32),
            mediaType: "audio/m4a",
            size: 9,
            duration: 2,
            waveform: [],
            hash: "override-hash"
        )
        let raw = String(decoding: try JSONEncoder().encode(voice), as: UTF8.self)

        let preview = try XCTUnwrap(
            ReplyPreviewPayload.projecting(originalContent: raw, textOverride: raw)
        )

        XCTAssertEqual(preview.kind, .audio)
        XCTAssertNil(preview.text)
        XCTAssertFalse(try XCTUnwrap(preview.storedContent).contains("grpc://"))
    }

    func testMediaCaptionIsTheOnlyTextProjectedFromDescriptor() throws {
        let caption = String(repeating: "подпись ", count: 35)
        let raw = """
        {"type":"media","caption":"\(caption)","media":[{"mediaId":"photo-id","mediaUrl":"grpc://media.example.test/photo","mediaKey":"c2VjcmV0","mediaType":"image/jpeg","hash":"photo-hash"}]}
        """

        let preview = try XCTUnwrap(ReplyPreviewPayload.projecting(originalContent: raw))

        XCTAssertEqual(preview.kind, .image)
        XCTAssertEqual(preview.text?.count, ReplyPreviewPayload.maxWireTextCharacters)
        XCTAssertFalse(try XCTUnwrap(preview.storedContent).contains("grpc://"))
        XCTAssertFalse(try XCTUnwrap(preview.storedContent).contains("photo-id"))
    }

    func testPlainTextStaysPlainAndIsBoundedForWirePreview() throws {
        let original = String(repeating: "x", count: ReplyPreviewPayload.maxWireTextCharacters + 20)

        let preview = try XCTUnwrap(ReplyPreviewPayload.projecting(originalContent: original))

        XCTAssertEqual(preview.kind, .text)
        XCTAssertEqual(preview.text?.count, ReplyPreviewPayload.maxWireTextCharacters)
        XCTAssertEqual(preview.storedContent, preview.text)
    }

    func testSafeStructuredPreviewRoundTrips() throws {
        let original = """
        {"type":"media","caption":"field caption","media":[{"mediaId":"id","mediaUrl":"grpc://host/file","mediaKey":"a2V5","mediaType":"video/mp4","hash":"hash"}]}
        """
        let projected = try XCTUnwrap(ReplyPreviewPayload.projecting(originalContent: original))
        let decoded = ReplyPreviewPayload.fromStoredContent(projected.storedContent)

        XCTAssertEqual(decoded, projected)
    }
}
