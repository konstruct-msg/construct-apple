//
//  MessageActionAvailabilityTests.swift
//  ConstructMessengerTests
//
//  Which context-menu actions a message may offer.
//
//  Copy, Quote & Reply and Edit all ask one question — is there text here a person can act on — and
//  the menu answered it three different ways. Edit was right and said why. Quote & Reply tested
//  media and file and forgot voice and profile. Copy tested nothing at all, so it appeared on every
//  message and put `displayText` on the clipboard — which, for a voice message, is the serialised
//  voice payload the bubble parses to find the audio, not a transcript.
//
//  Reported from device 2026-08-22: "невыполнимые действия на голосовом сообщении".
//
//  Acceptance is mutation-based; each test names the mutation that must redden it.
//

import XCTest
@testable import Construct_Messenger

final class MessageActionAvailabilityTests: XCTestCase {

    private typealias Parsing = MessageBubbleContentParsing

    private func actionable(
        profile: Bool = false, media: Bool = false, file: Bool = false, voice: Bool = false,
        text: String = "Что там за логика"
    ) -> Bool {
        Parsing.carriesActionableText(
            isProfile: profile, isMedia: media, isFile: file, isVoice: voice, text: text
        )
    }

    /// The defect. A voice message's payload is not text, so nothing that operates on text may be
    /// offered for it.
    ///
    /// Mutation: drop `!isVoice`.
    func testAVoiceMessageOffersNoTextActions() {
        XCTAssertFalse(actionable(voice: true, text: "{\"type\":\"voice\",\"mediaId\":\"…\"}"))
    }

    /// The one the old Quote & Reply gate also missed. A profile share renders as a card; its
    /// payload is a serialised contact.
    ///
    /// Mutation: drop `!isProfile`.
    func testAProfileShareOffersNoTextActions() {
        XCTAssertFalse(actionable(profile: true, text: "{\"type\":\"profile\"}"))
    }

    /// Media and file were already excluded from Quote & Reply and stay excluded — a caption is
    /// text to *edit*, which is why the edit gate is spelled out separately, but it is not text to
    /// copy or quote.
    ///
    /// Mutation: drop `!isMedia` or `!isFile`.
    func testMediaAndFilesOfferNoTextActions() {
        XCTAssertFalse(actionable(media: true))
        XCTAssertFalse(actionable(file: true))
    }

    /// And the case that must keep working: an ordinary message. Losing this is losing Copy and
    /// Quote & Reply from the whole app, which is the failure the fix must not become.
    ///
    /// Mutation: `return false`.
    func testAPlainTextMessageOffersThem() {
        XCTAssertTrue(actionable())
    }

    /// An empty body has nothing to copy even though it is text. This was the only condition the
    /// old Quote & Reply gate got right.
    ///
    /// Mutation: drop `!text.isEmpty`.
    func testAnEmptyBodyOffersNothing() {
        XCTAssertFalse(actionable(text: ""))
    }
}
