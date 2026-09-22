//
//  ChatTopChromeTests.swift
//  ConstructMessengerTests
//

import XCTest
@testable import Construct_Messenger

final class ChatTopChromeTests: XCTestCase {
    func testSearchReplacesNavigationInTheTopChromeSlot() {
        XCTAssertEqual(ChatTopChromeMode.resolve(isSearchActive: false), .navigation)
        XCTAssertEqual(ChatTopChromeMode.resolve(isSearchActive: true), .search)
    }
}

