//
//  VoiceReplyQuoteTests.swift
//  ConstructMessengerTests
//
//  A voice note can be a reply (`VoiceMessage.quoted`, field 7). Until 2026-10-19 the field did
//  not exist: a voice reply — to a video note, to another voice note — went out without its
//  quote, and the receiver's bubble had no strip to jump back from.
//

import SwiftProtobuf
import XCTest
@testable import Construct_Messenger

final class VoiceReplyQuoteTests: XCTestCase {

    private let voice = VoiceMessageContent(
        type: "voice", mediaId: "m1", mediaUrl: "https://media.invalid/m1",
        mediaKey: Data(repeating: 7, count: 32), mediaType: "audio/m4a", size: 1200,
        duration: 3, waveform: [0.1, 0.5, 0.9], hash: "00ff"
    )

    private func assembled(_ content: Shared_Proto_Messaging_V1_MessageContent)
        -> (String, Shared_Proto_Messaging_V1_QuotedMessage?)?
    {
        guard case .assembled(let text, let quoted, _, _, _) = ChunkedMessageReassembler.shared
            .decodeAssembled(try! content.serializedData(), e2eMessageId: nil)
        else { return nil }
        return (text, quoted)
    }

    /// Mutation: drop `v.quoted = quoted` in the codec, or read `nil` for `.voice` in the
    /// reassembler — the quote is gone on arrival.
    func testAVoiceReplyArrivesWithItsQuote() throws {
        var quoted = Shared_Proto_Messaging_V1_QuotedMessage()
        quoted.messageID = "8a0c1f6e-0000-0000-0000-000000000002"
        quoted.mediaType = .video
        let content = MediaWireCodec.voiceMessageContent(from: voice, quoted: quoted)

        let (text, received) = try XCTUnwrap(assembled(content))
        XCTAssertNotNil(parseVoiceContent(from: text), "still a voice bubble")
        XCTAssertEqual(received?.messageID, quoted.messageID)
        XCTAssertEqual(received?.mediaType, .video)
    }

    func testAVoiceNoteThatIsNotAReplyCarriesNoQuote() throws {
        let content = MediaWireCodec.voiceMessageContent(from: voice)
        XCTAssertFalse(content.voice.hasQuoted)
        XCTAssertNil(try XCTUnwrap(assembled(content)).1)
    }
}
