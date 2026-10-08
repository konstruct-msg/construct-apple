//
//  ChatActionTests.swift
//  ConstructMessengerTests
//
//  What the chat header's menu offers.
//

import XCTest
@testable import Construct_Messenger

final class ChatActionTests: XCTestCase {
    func testWhatIsOffered() {
        XCTAssertEqual(ChatAction.available(canCall: false, videoEnabled: true), [.search])
        XCTAssertEqual(ChatAction.available(canCall: true, videoEnabled: false), [.search, .call])
        XCTAssertEqual(ChatAction.available(canCall: true, videoEnabled: true), [.search, .call, .videoCall])
    }
}
