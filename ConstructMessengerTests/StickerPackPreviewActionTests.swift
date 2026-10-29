//
//  StickerPackPreviewActionTests.swift
//  ConstructMessengerTests
//
//  A tap on a sticker in the transcript opens its pack, and the pack's sheet offers Add or
//  Remove. Both decisions are pure: what a tap does, and what the sheet's button says.
//

import XCTest
@testable import Construct_Messenger

final class StickerPackPreviewActionTests: XCTestCase {

    private let ref = StickerReference(pack: StickerPackID(Data(repeating: 0x5A, count: 32))!, index: 2, emoji: "🙂")!

    /// Mutation: return `.none` for a sticker — the tap does nothing again (2026-10-28).
    func testATapOnAStickerOpensItsPack() {
        XCTAssertEqual(BubbleTapAction.of(isEditMode: false, sticker: ref), .openPack(ref))
        XCTAssertEqual(BubbleTapAction.of(isEditMode: false, sticker: nil), .none)
    }

    /// Selecting messages wins: a sticker is selected like any other row.
    func testInSelectModeATapSelectsEvenASticker() {
        XCTAssertEqual(BubbleTapAction.of(isEditMode: true, sticker: ref), .select)
        XCTAssertEqual(BubbleTapAction.of(isEditMode: true, sticker: nil), .select)
    }

    func testThePresentPackOffersAddOrRemove() {
        XCTAssertEqual(StickerPackPreviewAction.of(present: true, installed: false, fetchFinished: true), .add)
        XCTAssertEqual(StickerPackPreviewAction.of(present: true, installed: true, fetchFinished: true), .remove)
    }

    /// An absent pack is loading until the fetch ends, then unavailable — never Add for a pack
    /// that is not on the device.
    func testAnAbsentPackIsLoadingThenUnavailable() {
        XCTAssertEqual(StickerPackPreviewAction.of(present: false, installed: false, fetchFinished: false), .loading)
        XCTAssertEqual(StickerPackPreviewAction.of(present: false, installed: true, fetchFinished: true), .unavailable)
    }
}
