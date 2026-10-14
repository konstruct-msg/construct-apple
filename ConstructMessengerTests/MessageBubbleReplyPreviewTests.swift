//
//  MessageBubbleReplyPreviewTests.swift
//  ConstructMessengerTests
//

import XCTest
import SwiftUI
@testable import Construct_Messenger

#if canImport(UIKit)
import UIKit

final class MessageBubbleReplyPreviewTests: XCTestCase {
    @MainActor
    func testTwoLineReplyHasOneCompactInteractiveRow() {
        let host = UIHostingController(
            rootView: MessageBubbleReplyPreview(
                content: "Иногда когда нажимаешь на кнопку отправить закрывается клавиатура.",
                messageId: "original-message",
                onTap: {}
            )
        )

        let size = host.sizeThatFits(in: CGSize(width: 260, height: 1_000))

        XCTAssertGreaterThanOrEqual(size.height, CTLayout.hitTarget)
        XCTAssertLessThanOrEqual(size.height, CTLayout.hitTarget + 1)
    }
}
#endif

