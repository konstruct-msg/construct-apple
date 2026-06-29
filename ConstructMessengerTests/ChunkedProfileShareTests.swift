//
//  ChunkedProfileShareTests.swift
//  Construct MessengerTests
//
//  Regression for the "PROFILE_BINARY" leak: a profile share is always sent via
//  ChunkedMessageSender (KNST-framed even for a single chunk), so on receive it goes
//  through the reassembler. The reassembler must surface it as `.profile(Data)` — NOT as a
//  `.legacy("__PROFILE_BINARY__")` placeholder string that would render as a text bubble.
//  See sessions/2026-06-25-profile-share-binary-leak.md.
//

import XCTest
@testable import Construct_Messenger

@MainActor
final class ChunkedProfileShareTests: XCTestCase {

    private func makeProfile(displayName: String = "Аня") -> ProfileShareData {
        ProfileShareData(
            displayName: displayName,
            avatarMediaId: "media-abc123",
            avatarMediaUrl: "https://media.example/abc123",
            avatarMediaKey: Data(repeating: 0x42, count: 32),
            avatarMediaType: "image/jpeg",
            timestamp: 1_750_000_000
        )
    }

    /// Binary round-trip sanity: toBinaryData → fromBinaryData preserves the fields.
    func testProfileBinaryRoundTrip() throws {
        let profile = makeProfile(displayName: "MAX")
        let bytes = profile.toBinaryData()
        let decoded = try XCTUnwrap(ProfileShareData.fromBinaryData(bytes), "binary profile must decode")
        XCTAssertEqual(decoded.displayName, "MAX")
        XCTAssertEqual(decoded.avatarMediaId, "media-abc123")
        XCTAssertEqual(decoded.avatarMediaType, "image/jpeg")
    }

    /// The core regression: a KNST-framed profile (exactly what ChunkedMessageSender puts on the
    /// wire) must reassemble to `.profile`, never to a `.legacy` placeholder string.
    func testFramedProfileReassemblesAsProfileNotLegacy() throws {
        let profile = makeProfile(displayName: "Аня")
        let payload = profile.toBinaryData()

        // Frame exactly as the sender does.
        let frames = ChunkedMessageCodec.encodeChunks(plaintext: payload, messageId: UUID())
        XCTAssertEqual(frames.count, 1, "a small profile is a single chunk")

        let reassembler = ChunkedMessageReassembler()
        let result = reassembler.process(data: frames[0])

        switch result {
        case .profile(let data):
            let decoded = try XCTUnwrap(ProfileShareData.fromBinaryData(data), "profile bytes must decode")
            XCTAssertEqual(decoded.displayName, "Аня")
            XCTAssertEqual(decoded.avatarMediaId, "media-abc123")
        case .legacy(let text):
            XCTFail("profile leaked as legacy text: \(text)")
        default:
            XCTFail("expected .profile, got \(result)")
        }
    }

    /// The leaked placeholder must be recognised as a control artifact so any already-persisted
    /// rows stay hidden by the display/store filters.
    func testProfileBinaryPlaceholderIsControlArtifact() {
        XCTAssertTrue(MessageContentType.isControlPayload("__PROFILE_BINARY__"))
        XCTAssertTrue(MessageContentType.isControlPayload("PROFILE_BINARY"))
        XCTAssertFalse(MessageContentType.isControlPayload("hello"))
    }
}
