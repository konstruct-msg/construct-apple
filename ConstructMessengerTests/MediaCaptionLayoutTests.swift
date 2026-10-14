//
//  MediaCaptionLayoutTests.swift
//  ConstructMessengerTests
//
//  Photo captions used to accept the transcript row's compressed one-line height, producing an
//  ellipsis even though the full caption was present in the decrypted payload.
//

import XCTest
import SwiftUI
@testable import Construct_Messenger

#if canImport(UIKit)
import UIKit

@MainActor
final class MediaCaptionLayoutTests: XCTestCase {

    func testLongCaptionGrowsBeyondOneLine() {
        let width: CGFloat = 260
        let short = measuredHeight(for: "Короткая подпись", width: width)
        let long = measuredHeight(
            for: "Вот всё равно чтобы отправить нужно сначала внимательно проверить длинную подпись к фотографии",
            width: width,
            proposedHeight: short
        )

        XCTAssertGreaterThan(long, short * 1.5)
    }

    private func measuredHeight(
        for caption: String,
        width: CGFloat,
        proposedHeight: CGFloat = 1_000
    ) -> CGFloat {
        let host = UIHostingController(
            rootView: MediaCaptionText(caption: caption).frame(width: width)
        )
        return host.sizeThatFits(in: CGSize(width: width, height: proposedHeight)).height
    }
}
#endif
