//
//  GalleryPlaybackRateTests.swift
//  ConstructMessengerTests
//
//  The gallery's video speed menu: the three speeds, labelled without a trailing ".0".
//

import XCTest
@testable import Construct_Messenger

final class GalleryPlaybackRateTests: XCTestCase {
    func testTheSpeedsAreOneOneAndAHalfAndTwo() {
        XCTAssertEqual(GalleryVideoPage.rates, [1, 1.5, 2])
    }

    func testLabelsDropAWholeNumbersFraction() {
        XCTAssertEqual(GalleryVideoPage.label(for: 1), "1×")
        XCTAssertEqual(GalleryVideoPage.label(for: 2), "2×")
        XCTAssertTrue(GalleryVideoPage.label(for: 1.5).hasPrefix("1"), "1.5 or 1,5 by locale")
        XCTAssertTrue(GalleryVideoPage.label(for: 1.5).hasSuffix("5×"))
    }
}
