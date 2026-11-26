import XCTest
@testable import Construct_Messenger

/// Mutations: drop the height term (landscape iPhone gets a code it cannot show whole); drop the
/// floor (a short window gets an unreadable code); drop the width term; forget the paper.
final class QRCodeSizeTests: XCTestCase {
    func testPortraitIsSetByWidth() {
        XCTAssertEqual(QRCodeSize.standard(in: 402, visibleHeight: 760), 402 * 0.8)
        XCTAssertEqual(QRCodeSize.standard(in: 1000, visibleHeight: 1200), QRCodeSize.maximum)
    }

    func testLandscapeFitsTheVisibleHeightWithItsPaper() {
        let side = QRCodeSize.standard(in: 874, visibleHeight: 310)
        XCTAssertLessThanOrEqual(side + 2 * QRCodeSize.padding, 310)
        XCTAssertLessThan(side, QRCodeSize.maximum)
    }

    func testATinyWindowKeepsAReadableCode() {
        XCTAssertEqual(QRCodeSize.standard(in: 874, visibleHeight: 120), QRCodeSize.minimum)
    }

    func testUnknownHeightIsTheOldRule() {
        XCTAssertEqual(QRCodeSize.standard(in: 300), 240)
    }
}
