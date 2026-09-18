//
//  MediaAlbumGridLayoutTests.swift
//  ConstructMessengerTests
//
//  A 6-photo album (hero + 5 tail tiles) used to leave the last square hanging
//  in the left column next to empty space. A leftover last index is its own row
//  and the view draws that row full-width.
//

import XCTest
@testable import Construct_Messenger

final class MediaAlbumGridLayoutTests: XCTestCase {

    func testFivePhotoTailIsTwoPairs() {
        XCTAssertEqual(
            MediaAlbumGridLayout.tailRows(itemCount: 5, startingAt: 1),
            [[1, 2], [3, 4]]
        )
    }

    func testSixPhotoTailEndsOnASingleton() {
        XCTAssertEqual(
            MediaAlbumGridLayout.tailRows(itemCount: 6, startingAt: 1),
            [[1, 2], [3, 4], [5]]
        )
    }

    func testSevenPhotoTailIsThreePairs() {
        XCTAssertEqual(
            MediaAlbumGridLayout.tailRows(itemCount: 7, startingAt: 1),
            [[1, 2], [3, 4], [5, 6]]
        )
    }

    func testEmptyTailWhenThereIsOnlyTheHero() {
        XCTAssertEqual(MediaAlbumGridLayout.tailRows(itemCount: 1, startingAt: 1), [])
    }
}
