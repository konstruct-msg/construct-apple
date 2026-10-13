//
//  DeviceLinkCheckpointTests.swift
//  ConstructMessengerTests
//
//  The stream cursor a newly linked device starts from does not depend on whether history is
//  offered. Moved out of CTHFEnvelopeTests when the file envelope moved into the core.
//

import XCTest
@testable import Construct_Messenger

final class DeviceLinkCheckpointTests: XCTestCase {

    func testFinishLinkSourceAlwaysCheckpoints() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ConstructMessenger/ViewModels/DeviceLinkViewModel.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(src.contains("applyAccountOnlyCheckpoint"))
        XCTAssertFalse(
            src.contains("!DeviceLinkHistorySyncPolicy.isPostLinkEnabled"),
            "cursor must not be gated on the history offer flag"
        )
    }

    func testCheckpointValueIndependentOfHistoryFlag() {
        XCTAssertEqual(
            DeviceLinkStreamCursorPolicy.checkpointCursor(issuedAtSeconds: 1_700_000_000),
            "1700000000000-0"
        )
        XCTAssertFalse(DeviceLinkHistorySyncPolicy.isPostLinkEnabled)
        XCTAssertEqual(
            DeviceLinkStreamCursorPolicy.checkpointCursor(issuedAtSeconds: 1_700_000_000),
            "1700000000000-0",
            "cursor formula must not consult the history offer flag"
        )
    }
}

final class DeviceLinkHistoryOfferTests: XCTestCase {

    /// A build that offers a link offers the history with it. Both devices ask this, so the
    /// phone that sends and the Mac that receives agree whenever they are the same kind of build.
    ///
    /// Mutation: `isOffered` reads `isPostLinkEnabled` alone, as it effectively did in any build
    /// without `-DHISTORY_STAND` until 2026-10-13 — this reddens.
    func testABuildThatOffersALinkOffersTheHistory() {
        XCTAssertTrue(DeviceLinkOfferPolicy.isLinkingOffered, "the tests run in Debug, which offers a link")
        XCTAssertTrue(DeviceLinkHistorySyncPolicy.isOffered)
    }
}
