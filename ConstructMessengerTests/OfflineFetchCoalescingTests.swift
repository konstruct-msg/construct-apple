//
//  OfflineFetchCoalescingTests.swift
//  ConstructMessengerTests
//
//  Build 585, device 6bf51980, the first seven seconds after launch:
//
//      Silent push received … 49
//      Starting quick message fetch  … 49
//      Offline fetch from cursor=1786093333419-0 … 49        (the same cursor, every time)
//      Processing 46…49 offline messages / Saved 0 new messages to Core Data … ×49
//
//      10:54:01 ×3   10:54:02 ×7   10:54:04 ×5   10:54:05 ×17   10:54:06 ×7
//      10:54:07 ×7   10:54:08 ×3
//
//  Strictly one fetch per push, seventeen in one second, ~2 300 routings for 47 distinct
//  messages, on a device already reporting thermal=serious. The existing "foreground
//  MessageStream is live" guard cannot help here: at launch the stream is not up yet, which is
//  precisely when iOS hands over the whole backlogged push queue.
//

import XCTest
@testable import Construct_Messenger

final class OfflineFetchCoalescingTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_786_100_041)

    // MARK: - The incident

    func testLaunchBurstOfFortyNinePushesCollapsesToTwoFetches() {
        // Push #1 starts a fetch; the other 48 arrive while it runs.
        var fetchStartedAt: Date?
        var inFlight = false
        var followUpRequested = false
        var fetchesStarted = 0

        for i in 0..<49 {
            let pushArrivedAt = t0.addingTimeInterval(Double(i) * 0.14)   // 49 pushes over ~7s
            switch OfflineFetchCoalescer.admit(
                pushArrivedAt: pushArrivedAt,
                lastFetchStartedAt: fetchStartedAt,
                isFetchInFlight: inFlight
            ) {
            case .start:
                fetchesStarted += 1
                fetchStartedAt = pushArrivedAt
                inFlight = true
            case .requestFollowUp:
                followUpRequested = true
            case .alreadyCovered:
                break
            }
        }

        // The burst is still running when the last push lands, so exactly one fetch has gone out
        // and exactly one follow-up is owed — no matter how many pushes arrived.
        XCTAssertEqual(fetchesStarted, 1)
        XCTAssertTrue(followUpRequested, "the follow-up is what carries the news of pushes 2…49")
    }

    // MARK: - Nothing may be dropped

    func testAPushArrivingAfterTheFetchStartedIsNotSilentlyIgnored() {
        // The distinction that keeps this from being a rate limiter: a fetch running since BEFORE
        // the push may predate the message the push announces.
        XCTAssertEqual(
            OfflineFetchCoalescer.admit(
                pushArrivedAt: t0.addingTimeInterval(5),
                lastFetchStartedAt: t0,
                isFetchInFlight: true
            ),
            .requestFollowUp
        )
    }

    func testAPushOlderThanTheRunningFetchIsCovered() {
        // The fetch asked the server a newer question than the event this push announced.
        XCTAssertEqual(
            OfflineFetchCoalescer.admit(
                pushArrivedAt: t0,
                lastFetchStartedAt: t0.addingTimeInterval(1),
                isFetchInFlight: true
            ),
            .alreadyCovered
        )
    }

    func testAPushOlderThanTheLastFinishedFetchIsCovered() {
        // Same reasoning once it has returned: nothing is owed.
        XCTAssertEqual(
            OfflineFetchCoalescer.admit(
                pushArrivedAt: t0,
                lastFetchStartedAt: t0.addingTimeInterval(1),
                isFetchInFlight: false
            ),
            .alreadyCovered
        )
    }

    func testAPushAfterTheLastFetchFinishedStartsAFreshOne() {
        // A quiet period then a new message: this must NOT be swallowed. No timer, no cooldown —
        // the only question is whether some fetch already asked on this push's behalf.
        XCTAssertEqual(
            OfflineFetchCoalescer.admit(
                pushArrivedAt: t0.addingTimeInterval(600),
                lastFetchStartedAt: t0,
                isFetchInFlight: false
            ),
            .start
        )
    }

    func testTheVeryFirstPushOfTheProcessStartsAFetch() {
        XCTAssertEqual(
            OfflineFetchCoalescer.admit(pushArrivedAt: t0, lastFetchStartedAt: nil, isFetchInFlight: false),
            .start
        )
    }

    func testASecondBurstAfterTheFollowUpIsStillAnswered() {
        // Pushes arriving during the follow-up must earn a third fetch, not be folded into a
        // follow-up that has already been consumed.
        let followUpStartedAt = t0.addingTimeInterval(10)
        XCTAssertEqual(
            OfflineFetchCoalescer.admit(
                pushArrivedAt: t0.addingTimeInterval(11),
                lastFetchStartedAt: followUpStartedAt,
                isFetchInFlight: true
            ),
            .requestFollowUp
        )
    }
}
