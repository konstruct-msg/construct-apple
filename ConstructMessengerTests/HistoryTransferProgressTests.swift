//
//  HistoryTransferProgressTests.swift
//  ConstructMessengerTests
//
//  The media phase's amount and time left (2026-10-30: 49 files took 40 s with nothing on screen
//  to say how long).
//

import SwiftProtobuf
import XCTest
@testable import Construct_Messenger

final class HistoryTransferProgressTests: XCTestCase {

    // MARK: - Time left

    func testNoEstimateBeforeTwoSeconds() {
        XCTAssertNil(HistoryTransferProgress.secondsLeft(done: 50, total: 100, elapsed: 1.9))
    }

    func testNoEstimateBeforeThreePercent() {
        XCTAssertNil(HistoryTransferProgress.secondsLeft(done: 2, total: 100, elapsed: 10))
    }

    func testNoEstimateWhenDoneOrEmpty() {
        XCTAssertNil(HistoryTransferProgress.secondsLeft(done: 100, total: 100, elapsed: 10))
        XCTAssertNil(HistoryTransferProgress.secondsLeft(done: 0, total: 0, elapsed: 10))
    }

    func testEstimateIsTheRateSoFar() throws {
        // A quarter in 10 s: three quarters left take 30 s.
        let left = try XCTUnwrap(HistoryTransferProgress.secondsLeft(done: 25, total: 100, elapsed: 10))
        XCTAssertEqual(left, 30, accuracy: 0.001)
    }

    func testSecondsRoundUpToFive() {
        XCTAssertEqual(HistoryTransferProgress.timeLeft(seconds: 1).value, 5)
        XCTAssertEqual(HistoryTransferProgress.timeLeft(seconds: 21).value, 25)
        XCTAssertEqual(HistoryTransferProgress.timeLeft(seconds: 25).value, 25)
        XCTAssertEqual(HistoryTransferProgress.timeLeft(seconds: 59).key, "history_sync_eta_seconds")
    }

    func testMinutesFromSixtySecondsRoundUp() {
        XCTAssertEqual(HistoryTransferProgress.timeLeft(seconds: 60).key, "history_sync_eta_minutes")
        XCTAssertEqual(HistoryTransferProgress.timeLeft(seconds: 61).value, 2)
        XCTAssertEqual(HistoryTransferProgress.timeLeft(seconds: 120).value, 2)
    }

    // MARK: - Receiving side

    func testReceiverReadsTotalFromManifestAndSumsBytes() throws {
        var m = Construct_Client_History_V1_HistoryManifest()
        m.phase = 2
        m.mediaByteCount = 4096
        let events: [HistoryEvent] = [
            .record(recordType: HistoryRecordType.manifest, proto: try m.serializedData()),
            .mediaBytes(data: Data(count: 100)),
            .mediaBytes(data: Data(count: 28)),
        ]
        XCTAssertEqual(HistoryCoreStream.progressEvents(in: events), [.mediaTotal(4096), .mediaBytes(128)])
    }

    func testReceiverIgnoresManifestWithoutMedia() throws {
        let m = Construct_Client_History_V1_HistoryManifest()
        let events: [HistoryEvent] = [.record(recordType: HistoryRecordType.manifest, proto: try m.serializedData())]
        XCTAssertEqual(HistoryCoreStream.progressEvents(in: events), [])
    }

    // MARK: - What the screen sees

    @MainActor
    func testScreenMovesPerPercentAndReachesTheEnd() throws {
        let coordinator = HistoryTransferCoordinator()
        coordinator.note(.mediaTotal(1000))
        coordinator.note(.mediaBytes(5))
        XCTAssertEqual(coordinator.progress?.doneBytes, 0, "under one percent is not shown yet")
        coordinator.note(.mediaBytes(5))
        XCTAssertEqual(coordinator.progress?.doneBytes, 10)
        coordinator.note(.mediaBytes(985))
        XCTAssertEqual(coordinator.progress?.doneBytes, 995)
        coordinator.note(.mediaBytes(5))
        XCTAssertEqual(try XCTUnwrap(coordinator.progress).fraction, 1)
    }

    @MainActor
    func testBytesBeforeATotalAreDropped() {
        let coordinator = HistoryTransferCoordinator()
        coordinator.note(.mediaBytes(500))
        XCTAssertNil(coordinator.progress)
    }
}
