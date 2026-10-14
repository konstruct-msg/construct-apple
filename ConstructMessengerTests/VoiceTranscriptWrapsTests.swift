//
//  VoiceTranscriptWrapsTests.swift
//  ConstructMessengerTests
//
//  2026-09-24, device: a ten-second voice note transcribed to a full sentence and the bubble
//  showed "Привет как дела у меня всё как о…". The text was whole; the layout cut it.
//
//  The transcript is an eager `VStack` inside a hosting view sized by its intrinsic content size
//  (`ChatTranscriptScrollView`). A transcript arrives after its row was measured, so for at least
//  one pass the stack is laid out in the old height — and a stack short of height compresses the
//  most compressible child, which is a `Text` with no vertical fixed size. The message text has
//  carried `.fixedSize(horizontal: false, vertical: true)` for exactly this; the transcript did not.
//

import XCTest
import SwiftUI
@testable import Construct_Messenger

@MainActor
final class VoiceTranscriptWrapsTests: XCTestCase {

    private static let width: CGFloat = 390

    private func row(transcript: String) -> some View {
        let content = VoiceMessageContent(
            type: "voice", mediaId: "t", mediaUrl: "x", mediaKey: Data([1]),
            mediaType: "audio/m4a", size: 1, duration: 10,
            waveform: Array(repeating: 0.5, count: 100), hash: ""
        )
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                VoiceMessageBubbleView(
                    voiceContent: content, isSentByMe: false, deliveryStatus: .delivered,
                    onRetry: nil, transcript: transcript
                )
                .frame(maxWidth: ChatUIConstants.Bubble.maxWidth)
                Spacer(minLength: ChatUIConstants.Bubble.sideGutter)
            }
        }
    }

    private func height(_ transcript: String, proposing proposed: CGFloat = .greatestFiniteMagnitude) -> CGFloat {
        UIHostingController(rootView: row(transcript: transcript))
            .sizeThatFits(in: CGSize(width: Self.width, height: proposed)).height
    }

    /// Mutation: remove `.fixedSize(horizontal: false, vertical: true)` from the transcript text —
    /// this reddens: the stack takes the stale height and the transcript is cut to fit it.
    func testATranscriptLaidOutInAStaleHeightKeepsItsLines() {
        let long = String(repeating: "Привет как дела у меня всё как обычно ", count: 4)
        let stale = height("Привет")
        let whole = height(long)
        XCTAssertGreaterThan(whole - stale, 20, "the premise: the long transcript needs more lines")

        let laidOutShort = height(long, proposing: stale)
        XCTAssertEqual(laidOutShort, whole, accuracy: 1,
                       "the transcript was compressed into the height measured before it arrived")
    }
}
