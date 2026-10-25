import XCTest
@testable import Construct_Messenger

/// `PreKeyRotationService.gate` decides and claims a rotation in one step under the service's lock.
/// Until 2026-10-25 the check and the claim were separate reads of plain properties, so two
/// callers off the main actor could both start a rotation.
final class PreKeyRotationGateTests: XCTestCase {

    typealias Service = PreKeyRotationService

    func testADueRotationIsClaimedAndASecondCallerFindsItBusy() {
        var state = Service.RetryState()
        XCTAssertEqual(Service.gate(&state, isDue: true, now: 1_000), .claimed)
        XCTAssertTrue(state.isRotating)
        XCTAssertEqual(state.lastAttemptAt, 1_000)

        XCTAssertEqual(Service.gate(&state, isDue: true, now: 1_001), .busy)
        XCTAssertEqual(state.lastAttemptAt, 1_000, "a busy answer must not move the attempt time")
    }

    func testARotationThatIsNotDueClearsThePendingRetry() {
        var state = Service.RetryState(hasPendingRetry: true, isRotating: false, lastAttemptAt: 0)
        XCTAssertEqual(Service.gate(&state, isDue: false, now: 1_000), .notDue)
        XCTAssertFalse(state.hasPendingRetry)
        XCTAssertFalse(state.isRotating)
    }

    func testARetryInsideTheIntervalIsThrottledAndClaimsNothing() {
        var state = Service.RetryState(hasPendingRetry: true, isRotating: false, lastAttemptAt: 1_000)
        XCTAssertEqual(Service.gate(&state, isDue: true, now: 1_030), .throttled(remaining: Service.retryIntervalSeconds - 30))
        XCTAssertFalse(state.isRotating)

        let later = 1_000 + Service.retryIntervalSeconds
        XCTAssertEqual(Service.gate(&state, isDue: true, now: later), .claimed)
    }
}
