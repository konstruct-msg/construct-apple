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
