//
//  StickerPackRowActionTests.swift
//  ConstructMessengerTests
//
//  "Add stickers" opens every pack in one sheet; each row's button is a pure decision.
//

import XCTest
@testable import Construct_Messenger

final class StickerPackRowActionTests: XCTestCase {

    /// An installed pack offers Remove, whatever the catalog's flags say about it.
    func testAnInstalledPackOffersRemove() {
        XCTAssertEqual(StickerPackRowAction.of(installed: true, installing: false, failed: false), .remove)
        XCTAssertEqual(StickerPackRowAction.of(installed: true, installing: true, failed: true), .remove)
    }

    func testACatalogPackOffersGet() {
        XCTAssertEqual(StickerPackRowAction.of(installed: false, installing: false, failed: false), .get)
    }

    /// An install in flight shows progress, not a button a second tap could hit — even when the
    /// previous attempt failed.
    func testAnInstallInFlightShowsProgress() {
        XCTAssertEqual(StickerPackRowAction.of(installed: false, installing: true, failed: false), .installing)
        XCTAssertEqual(StickerPackRowAction.of(installed: false, installing: true, failed: true), .installing)
    }

    func testAFailedInstallOffersRetry() {
        XCTAssertEqual(StickerPackRowAction.of(installed: false, installing: false, failed: true), .retry)
    }
}
